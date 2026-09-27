//! Alpaca real-time stock stream (`wss://stream.data.alpaca.markets/v2/{iex|sip}`).
//!
//! ```text
//! → {"action":"auth","key":…,"secret":…}          ← [{"T":"success","msg":"connected"}]
//!                                                  ← [{"T":"success","msg":"authenticated"}]
//! → {"action":"subscribe","trades":[…],"quotes":[…],"statuses":[…],"lulds":[…]}
//!                                                  ← [{"T":"subscription",…}]
//! ← [{"T":"t","S":"AAPL","x":"V","p":…,"s":…,"c":["@"],"t":"RFC 3339 ns","z":"C"}, …]
//! ← [{"T":"q","S":…,"bp":…,"ap":…,"t":…}]  [{"T":"s","S":…,"sc":"H","sm":…,"rc":…,"rm":…}]
//! ← [{"T":"l","S":…,"u":…,"d":…,"i":…}]    [{"T":"error","code":406,"msg":"connection limit exceeded"}]
//! ```
//!
//! Trading-status codes: CTA tapes A/B `2` halt, `3` resume; UTP tape C `H` halt, `P` volatility (LULD)
//! pause, `Q` quotation resumption (trading still halted), `T` trading resumption. The other CTA codes
//! (5–9, A–F) are imbalance / indication messages and do not change the halt state.

use super::{
    alpaca::{to_trade, ts_ns, RawQuote, RawTrade},
    stream::{Control, StreamMsg, StreamProtocol},
    Quote,
};
use crate::{asset::Plan, price::wad_from_f64};
use serde::Deserialize;
use std::collections::HashMap;

pub struct AlpacaStream {
    pub url: String,
    pub key_id: String,
    pub secret: String,
    /// Listing plan per symbol (used when a trade has no tape).
    pub plans: HashMap<String, Plan>,
}

impl AlpacaStream {
    /// `base` is `wss://stream.data.alpaca.markets/v2`; `feed` is `iex` or `sip`.
    pub fn new(
        base: &str,
        feed: &str,
        key_id: String,
        secret: String,
        plans: HashMap<String, Plan>,
    ) -> Self {
        Self {
            url: format!("{}/{}", base.trim_end_matches('/'), feed),
            key_id,
            secret,
            plans,
        }
    }
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(rename = "T")]
    kind: String,
    #[serde(rename = "S")]
    symbol: Option<String>,
    msg: Option<String>,
    code: Option<i64>,
    // status
    sc: Option<String>,
    sm: Option<String>,
    rm: Option<String>,
    // luld
    u: Option<f64>,
    d: Option<f64>,
}

/// Errors after which retrying soon is pointless: auth failed (402), auth timeout (404), symbol
/// limit (405), connection limit (406), insufficient subscription (409), and 401 not authenticated.
fn fatal(code: i64) -> bool {
    matches!(code, 401 | 402 | 404 | 405 | 406 | 409)
}

pub fn status_halted(code: &str) -> Option<bool> {
    match code {
        "2" | "H" | "P" | "Q" => Some(true),
        "3" | "T" => Some(false),
        _ => None,
    }
}

pub fn parse_frame(text: &str, plans: &HashMap<String, Plan>) -> Vec<StreamMsg> {
    let Ok(items) = serde_json::from_str::<Vec<serde_json::Value>>(text) else {
        return vec![StreamMsg::Control(Control::Info(format!(
            "unparsed frame: {}",
            text.chars().take(120).collect::<String>()
        )))];
    };
    let mut out = Vec::with_capacity(items.len());
    for v in items {
        let Ok(e) = serde_json::from_value::<Envelope>(v.clone()) else {
            continue;
        };
        let plan_of = |s: &str| plans.get(s).copied().unwrap_or(Plan::Cta);
        match e.kind.as_str() {
            "success" => match e.msg.as_deref() {
                Some("authenticated") => out.push(StreamMsg::Control(Control::Authenticated)),
                Some("connected") => out.push(StreamMsg::Control(Control::Connected)),
                other => out.push(StreamMsg::Control(Control::Info(
                    other.unwrap_or_default().into(),
                ))),
            },
            "subscription" => out.push(StreamMsg::Control(Control::Subscribed)),
            "error" => {
                let why = format!(
                    "alpaca {}: {}",
                    e.code.unwrap_or(0),
                    e.msg.unwrap_or_default()
                );
                out.push(StreamMsg::Control(if e.code.is_some_and(fatal) {
                    Control::Rejected(why)
                } else {
                    Control::Info(why)
                }));
            }
            "t" => {
                let Some(sym) = e.symbol else { continue };
                if let Some(t) = serde_json::from_value::<RawTrade>(v)
                    .ok()
                    .and_then(|r| to_trade(&r, plan_of(&sym)))
                {
                    out.push(StreamMsg::Trade(sym, t));
                }
            }
            "q" => {
                let Some(sym) = e.symbol else { continue };
                let Ok(q) = serde_json::from_value::<RawQuote>(v) else {
                    continue;
                };
                if let (Ok(b), Ok(a), Some(t)) =
                    (wad_from_f64(q.bp), wad_from_f64(q.ap), ts_ns(&q.t))
                {
                    out.push(StreamMsg::Quote(
                        sym,
                        Quote {
                            bid_wad: b,
                            ask_wad: a,
                            ts_ns: t,
                        },
                    ));
                }
            }
            "s" => {
                let (Some(sym), Some(sc)) = (e.symbol, e.sc) else {
                    continue;
                };
                if let Some(halted) = status_halted(&sc) {
                    let reason = [e.sm, e.rm]
                        .into_iter()
                        .flatten()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(": ");
                    out.push(StreamMsg::Status {
                        symbol: sym,
                        halted,
                        reason: (!reason.is_empty()).then_some(reason),
                    });
                }
            }
            "l" => {
                let (Some(sym), Some(u), Some(d)) = (e.symbol, e.u, e.d) else {
                    continue;
                };
                if let (Ok(up), Ok(down)) = (wad_from_f64(u), wad_from_f64(d)) {
                    out.push(StreamMsg::Luld {
                        symbol: sym,
                        up_wad: up,
                        down_wad: down,
                    });
                }
            }
            _ => {}
        }
    }
    out
}

impl StreamProtocol for AlpacaStream {
    fn vendor(&self) -> &'static str {
        "alpaca"
    }
    fn url(&self) -> String {
        self.url.clone()
    }
    fn auth(&self) -> Option<String> {
        Some(
            serde_json::json!({"action": "auth", "key": self.key_id, "secret": self.secret})
                .to_string(),
        )
    }
    fn subscribe(&self, symbols: &[String]) -> String {
        serde_json::json!({
            "action": "subscribe",
            "trades": symbols, "quotes": symbols, "statuses": symbols, "lulds": symbols,
        })
        .to_string()
    }
    fn parse(&self, text: &str) -> Vec<StreamMsg> {
        parse_frame(text, &self.plans)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::price::WAD;

    fn fixture() -> String {
        std::fs::read_to_string(format!(
            "{}/tests/fixtures/alpaca/stream_session.jsonl",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    fn all() -> Vec<StreamMsg> {
        let plans = HashMap::from([("AAPL".to_string(), Plan::Utp)]);
        fixture()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .flat_map(|l| parse_frame(l, &plans))
            .collect()
    }

    #[test]
    fn control_flow() {
        let m = all();
        assert_eq!(m[0], StreamMsg::Control(Control::Connected));
        assert_eq!(m[1], StreamMsg::Control(Control::Authenticated));
        assert_eq!(m[2], StreamMsg::Control(Control::Subscribed));
        assert!(
            matches!(m.last(), Some(StreamMsg::Control(Control::Rejected(w))) if w.contains("406"))
        );
    }

    #[test]
    fn trades_quotes_status_luld() {
        let m = all();
        let t = m
            .iter()
            .find_map(|x| match x {
                StreamMsg::Trade(s, t) if s == "AAPL" => Some(t.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(t.price_wad, 22_634 * WAD / 100);
        assert_eq!(t.exchange, "IEXG");
        assert_eq!(t.plan, Plan::Utp, "tape C");
        assert_eq!(t.ts_ns, 1_790_366_700_123_456_789);
        assert_eq!(t.conditions, vec!["@"]);
        let q = m
            .iter()
            .find_map(|x| match x {
                StreamMsg::Quote(_, q) => Some(q.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            (q.bid_wad, q.ask_wad),
            (22_633 * WAD / 100, 22_635 * WAD / 100)
        );
        let st: Vec<(bool, Option<String>)> = m
            .iter()
            .filter_map(|x| match x {
                StreamMsg::Status { halted, reason, .. } => Some((*halted, reason.clone())),
                _ => None,
            })
            .collect();
        assert_eq!(st.len(), 2, "imbalance code 7 is not a status change");
        assert!(st[0].0 && st[0].1.as_deref().unwrap().contains("LULD"));
        assert!(!st[1].0);
        assert!(m
            .iter()
            .any(|x| matches!(x, StreamMsg::Luld { up_wad, .. } if *up_wad == 23_766 * WAD / 100)));
    }

    #[test]
    fn status_codes() {
        for (c, h) in [
            ("H", Some(true)),
            ("P", Some(true)),
            ("2", Some(true)),
            ("Q", Some(true)),
            ("T", Some(false)),
            ("3", Some(false)),
            ("7", None),
        ] {
            assert_eq!(status_halted(c), h, "{c}");
        }
    }

    #[test]
    fn subscribe_lists_every_channel() {
        let s = AlpacaStream::new("wss://x/v2/", "sip", "k".into(), "s".into(), HashMap::new());
        assert_eq!(s.url, "wss://x/v2/sip");
        let v: serde_json::Value = serde_json::from_str(&s.subscribe(&["NVDA".into()])).unwrap();
        for ch in ["trades", "quotes", "statuses", "lulds"] {
            assert_eq!(v[ch][0], "NVDA");
        }
    }
}
