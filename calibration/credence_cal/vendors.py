"""Vendor adapters for daily official open/close plus corporate actions (ADR-0201).

Every adapter returns the same normalised frame, one row per session the vendor reports:

    date (YYYY-MM-DD, exchange date) · open · high · low · close · volume   (raw, unadjusted)
    split_ratio   new shares per old share, effective at this date's open (1.0 on other days)
    dividend      cash per share going ex at this date's open (0.0 on other days)

Keys are read from the repo-root `.env` and never logged.
"""

from __future__ import annotations

import time
from collections import defaultdict

import httpx
import pandas as pd

COLUMNS = ["date", "open", "high", "low", "close", "volume", "split_ratio", "dividend"]


def _get(client: httpx.Client, url: str, params: dict, headers: dict | None = None, tries: int = 6) -> dict:
    for attempt in range(tries):
        r = client.get(url, params=params, headers=headers, timeout=60)
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(min(60, 2 ** attempt * 2))
            continue
        r.raise_for_status()
        return r.json()
    r.raise_for_status()
    raise RuntimeError(f"{url}: gave up after {tries} tries")


def _finish(bars: pd.DataFrame, splits: dict[str, float], divs: dict[str, float]) -> pd.DataFrame:
    bars = bars.sort_values("date").drop_duplicates("date", keep="last").reset_index(drop=True)
    bars["split_ratio"] = bars["date"].map(splits).fillna(1.0).astype(float)
    bars["dividend"] = bars["date"].map(divs).fillna(0.0).astype(float)
    return bars[COLUMNS]


class Alpaca:
    """Alpaca Market Data v2, SIP daily bars (history from 2016-01-04 on every plan) and v1 corporate
    actions. Daily-bar open/close are the consolidated official open/close (cross-checked against
    Polygon's `/v1/open-close`, see `crosscheck`)."""

    name = "alpaca"
    BASE = "https://data.alpaca.markets"

    def __init__(self, env: dict[str, str]):
        self.h = {"APCA-API-KEY-ID": env["ALPACA_API_KEY_ID"], "APCA-API-SECRET-KEY": env["ALPACA_API_SECRET_KEY"]}
        self.c = httpx.Client()

    def daily(self, symbol: str, start: str, end: str) -> pd.DataFrame:
        rows, token = [], None
        while True:
            p = {"timeframe": "1Day", "start": start, "end": end, "feed": "sip", "adjustment": "raw", "limit": 10000}
            if token:
                p["page_token"] = token
            j = _get(self.c, f"{self.BASE}/v2/stocks/{symbol}/bars", p, self.h)
            for b in j.get("bars") or []:
                # Daily bars are stamped at 00:00 America/New_York expressed in UTC (04:00Z or 05:00Z).
                d = pd.Timestamp(b["t"]).tz_convert("America/New_York").strftime("%Y-%m-%d")
                rows.append({"date": d, "open": float(b["o"]), "high": float(b["h"]), "low": float(b["l"]),
                             "close": float(b["c"]), "volume": float(b["v"])})
            token = j.get("next_page_token")
            if not token:
                break
        bars = pd.DataFrame(rows, columns=COLUMNS[:6])
        splits, divs = self.actions(symbol, start, end)
        return _finish(bars, splits, divs)

    def actions(self, symbol: str, start: str, end: str) -> tuple[dict[str, float], dict[str, float]]:
        splits: dict[str, float] = defaultdict(lambda: 1.0)
        divs: dict[str, float] = defaultdict(float)
        # The endpoint caps the date range, so walk it a year at a time.
        y0, y1 = int(start[:4]), int(end[:4])
        for y in range(y0, y1 + 1):
            s, e = max(start, f"{y}-01-01"), min(end, f"{y}-12-31")
            token = None
            while True:
                p = {"symbols": symbol, "types": "forward_split,reverse_split,cash_dividend,stock_dividend",
                     "start": s, "end": e, "limit": 1000}
                if token:
                    p["page_token"] = token
                j = _get(self.c, f"{self.BASE}/v1/corporate-actions", p, self.h)
                ca = j.get("corporate_actions") or {}
                for kind in ("forward_splits", "reverse_splits"):
                    for a in ca.get(kind, []):
                        splits[a["ex_date"]] *= float(a["new_rate"]) / float(a["old_rate"])
                for a in ca.get("stock_dividends", []):
                    splits[a["ex_date"]] *= 1.0 + float(a["rate"])
                for a in ca.get("cash_dividends", []):
                    divs[a["ex_date"]] += float(a["rate"])
                token = j.get("next_page_token")
                if not token:
                    break
        return dict(splits), dict(divs)


class Tiingo:
    """Tiingo EOD (30+ years; the recommended licensed source, ADR-0201). `splitFactor` is new/old
    shares on the ex-date and `divCash` the cash dividend going ex that day."""

    name = "tiingo"
    BASE = "https://api.tiingo.com/tiingo/daily"

    def __init__(self, env: dict[str, str]):
        self.token = env["TIINGO_API_KEY"]
        self.c = httpx.Client()

    def daily(self, symbol: str, start: str, end: str) -> pd.DataFrame:
        j = _get(self.c, f"{self.BASE}/{symbol}/prices",
                 {"startDate": start, "endDate": end, "format": "json", "resampleFreq": "daily"},
                 {"Authorization": f"Token {self.token}"})
        rows, splits, divs = [], {}, {}
        for b in j:
            d = b["date"][:10]
            rows.append({"date": d, "open": float(b["open"]), "high": float(b["high"]), "low": float(b["low"]),
                         "close": float(b["close"]), "volume": float(b["volume"])})
            if float(b.get("splitFactor") or 1.0) != 1.0:
                splits[d] = float(b["splitFactor"])
            if float(b.get("divCash") or 0.0) != 0.0:
                divs[d] = float(b["divCash"])
        return _finish(pd.DataFrame(rows, columns=COLUMNS[:6]), splits, divs)


class Polygon:
    """Polygon/Massive: used only to cross-check a sample of official open/close prints and the split
    history (Basic plan: 2 years of prices, 5 requests/minute)."""

    name = "polygon"
    BASE = "https://api.polygon.io"

    def __init__(self, env: dict[str, str]):
        self.key = env["POLYGON_API_KEY"]
        self.c = httpx.Client()
        self._last = 0.0

    def _throttled(self, url: str, params: dict) -> dict:
        wait = 12.5 - (time.monotonic() - self._last)
        if wait > 0:
            time.sleep(wait)
        self._last = time.monotonic()
        return _get(self.c, url, {**params, "apiKey": self.key})

    def open_close(self, symbol: str, date: str) -> dict:
        return self._throttled(f"{self.BASE}/v1/open-close/{symbol}/{date}", {"adjusted": "false"})

    def splits(self, symbol: str) -> list[dict]:
        return self._throttled(f"{self.BASE}/v3/reference/splits", {"ticker": symbol, "limit": 1000}).get("results", [])


VENDORS = {"alpaca": Alpaca, "tiingo": Tiingo}
