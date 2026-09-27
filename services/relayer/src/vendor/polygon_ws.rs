//! Polygon.io / Massive stocks stream (`wss://socket.polygon.io/stocks`, real time on Stocks Advanced
//! or Business; `wss://delayed.polygon.io/stocks` is 15-minute delayed and must not feed LIVE).
//!
//! ```text
//! ← [{"ev":"status","status":"connected","message":"Connected Successfully"}]
//! → {"action":"auth","params":"<key>"}          ← [{"ev":"status","status":"auth_success",…}]
//! → {"action":"subscribe","params":"T.NVDA,Q.NVDA,LULD.NVDA"}
//!                                                ← [{"ev":"status","status":"success","message":"subscribed to: T.NVDA"}]
//! ← [{"ev":"T","sym":…,"x":12,"p":…,"s":…,"c":[0,12],"t":<SIP ms>,"pt":<participant ms>,"z":3}, …]
//! ← [{"ev":"Q","sym":…,"bp":…,"ap":…,"t":…,"pt":…}]
//! ← [{"ev":"LULD","T":…,"h":…,"l":…,"i":[16],"t":…}]
//! ```
//!
//! LULD indicators 17 (trading halt) and 18 (resumption) are published for Nasdaq-listed symbols only
//! (Massive docs); other halts still come from the Nasdaq Trader feed through the REST path. Timestamps
//! are documented as ms but LULD samples carry ns, so every timestamp goes through [`to_ns`].

use super::{
    polygon::{to_trade, RawTrade, SipCodes},
    stream::{to_ns, Control, StreamMsg, StreamProtocol},
    Quote,
};
use crate::{asset::Plan, price::wad_from_f64};
use serde::Deserialize;
use std::collections::HashMap;

pub const LULD_HALT: u32 = 17;
pub const LULD_RESUME: u32 = 18;

pub struct PolygonStream {
    pub url: String,
    pub api_key: String,
    pub conditions: HashMap<u32, SipCodes>,
    pub plans: HashMap<String, Plan>,
}

#[derive(Deserialize)]
struct Ev {
    ev: String,
    // status
    status: Option<String>,
    message: Option<String>,
    // T / Q
    sym: Option<String>,
    x: Option<u32>,
    p: Option<f64>,
    s: Option<f64>,
    #[serde(default)]
    c: serde_json::Value, // [int] on trades, int on quotes
    t: Option<u64>,
    pt: Option<u64>,
    z: Option<u8>,
    bp: Option<f64>,
    ap: Option<f64>,
    // LULD
    #[serde(rename = "T")]
    ticker: Option<String>,
    h: Option<f64>,
    l: Option<f64>,
    #[serde(default)]
    i: serde_json::Value,
}

pub fn parse_frame(
    text: &str,
    conditions: &HashMap<u32, SipCodes>,
    plans: &HashMap<String, Plan>,
) -> Vec<StreamMsg> {
    let Ok(items) = serde_json::from_str::<Vec<Ev>>(text) else {
        return vec![StreamMsg::Control(Control::Info(format!(
            "unparsed frame: {}",
            text.chars().take(120).collect::<String>()
        )))];
    };
    let mut out = Vec::with_capacity(items.len());
    for e in items {
        match e.ev.as_str() {
            "status" => {
                let msg = e.message.unwrap_or_default();
                out.push(StreamMsg::Control(match e.status.as_deref() {
                    Some("connected") => Control::Connected,
                    Some("auth_success") => Control::Authenticated,
                    Some("success") if msg.starts_with("subscribed to") => Control::Subscribed,
                    Some("auth_failed") | Some("auth_timeout") | Some("max_connections") => {
                        Control::Rejected(format!(
                            "polygon {}: {msg}",
                            e.status.unwrap_or_default()
                        ))
                    }
                    // e.g. "error" with "not authorized for T.*" when the plan lacks real-time data
                    Some("error") if msg.contains("not authorized") || msg.contains("plan") => {
                        Control::Rejected(format!("polygon error: {msg}"))
                    }
                    other => Control::Info(format!("{}: {msg}", other.unwrap_or_default())),
                }));
            }
            "T" => {
                let (Some(sym), Some(x), Some(p), Some(t)) = (e.sym, e.x, e.p, e.t) else {
                    continue;
                };
                let conds: Vec<u32> = serde_json::from_value(e.c).unwrap_or_default();
                let plan = plans.get(&sym).copied().unwrap_or(Plan::Cta);
                let raw = RawTrade::from_ws(
                    conds,
                    x,
                    p,
                    e.s.unwrap_or(0.0),
                    to_ns(t),
                    e.pt.map(to_ns),
                    e.z,
                );
                if let Some(tr) = to_trade(&raw, conditions, plan) {
                    out.push(StreamMsg::Trade(sym, tr));
                }
            }
            "Q" => {
                let (Some(sym), Some(bp), Some(ap), Some(t)) = (e.sym, e.bp, e.ap, e.t) else {
                    continue; // one-sided quote: no mid
                };
                if let (Ok(b), Ok(a)) = (wad_from_f64(bp), wad_from_f64(ap)) {
                    out.push(StreamMsg::Quote(
                        sym,
                        Quote {
                            bid_wad: b,
                            ask_wad: a,
                            ts_ns: to_ns(e.pt.unwrap_or(t)),
                        },
                    ));
                }
            }
            "LULD" => {
                let Some(sym) = e.ticker else { continue };
                let ind: Vec<u32> = serde_json::from_value(e.i).unwrap_or_default();
                if ind.contains(&LULD_HALT) {
                    out.push(StreamMsg::Status {
                        symbol: sym.clone(),
                        halted: true,
                        reason: Some("LULD trading halt (indicator 17)".into()),
                    });
                } else if ind.contains(&LULD_RESUME) {
                    out.push(StreamMsg::Status {
                        symbol: sym.clone(),
                        halted: false,
                        reason: Some("LULD resumption (indicator 18)".into()),
                    });
                }
                if let (Some(h), Some(l)) = (e.h, e.l) {
                    if let (Ok(up), Ok(down)) = (wad_from_f64(h), wad_from_f64(l)) {
                        out.push(StreamMsg::Luld {
                            symbol: sym,
                            up_wad: up,
                            down_wad: down,
                        });
                    }
                }
            }
            _ => {}
        }
    }
    out
}

impl StreamProtocol for PolygonStream {
    fn vendor(&self) -> &'static str {
        "polygon"
    }
    fn url(&self) -> String {
        self.url.clone()
    }
    fn auth(&self) -> Option<String> {
        Some(serde_json::json!({"action": "auth", "params": self.api_key}).to_string())
    }
    fn subscribe(&self, symbols: &[String]) -> String {
        let params: Vec<String> = symbols
            .iter()
            .flat_map(|s| [format!("T.{s}"), format!("Q.{s}"), format!("LULD.{s}")])
            .collect();
        serde_json::json!({"action": "subscribe", "params": params.join(",")}).to_string()
    }
    fn parse(&self, text: &str) -> Vec<StreamMsg> {
        parse_frame(text, &self.conditions, &self.plans)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{conditions::classify, price::WAD, vendor::polygon::builtin_conditions};

    fn all() -> Vec<StreamMsg> {
        let body = std::fs::read_to_string(format!(
            "{}/tests/fixtures/polygon/stream_session.jsonl",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        let plans = HashMap::from([("NVDA".to_string(), Plan::Utp)]);
        body.lines()
            .filter(|l| !l.trim().is_empty())
            .flat_map(|l| parse_frame(l, &builtin_conditions(), &plans))
            .collect()
    }

    #[test]
    fn control_flow() {
        let m = all();
        assert_eq!(m[0], StreamMsg::Control(Control::Connected));
        assert_eq!(m[1], StreamMsg::Control(Control::Authenticated));
        assert_eq!(m[2], StreamMsg::Control(Control::Subscribed));
        assert!(
            matches!(m.last(), Some(StreamMsg::Control(Control::Rejected(w))) if w.contains("not authorized"))
        );
    }

    #[test]
    fn trades_use_participant_time_and_sip_codes() {
        let m = all();
        let trades: Vec<_> = m
            .iter()
            .filter_map(|x| match x {
                StreamMsg::Trade(_, t) => Some(t.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(trades.len(), 2);
        let t = &trades[0];
        assert_eq!(t.price_wad, 18_012 * WAD / 100);
        assert_eq!(t.ts_ns, 1_790_366_700_101_000_000, "participant ms → ns");
        assert_eq!(t.exchange, "XNAS");
        assert_eq!(t.plan, Plan::Utp);
        assert!(classify(t.plan, &t.conditions).regular);
        // the opening cross print: condition 16 (Q) from the listing exchange
        assert!(classify(trades[1].plan, &trades[1].conditions).official_open);
    }

    #[test]
    fn quotes_and_luld() {
        let m = all();
        let q = m
            .iter()
            .find_map(|x| match x {
                StreamMsg::Quote(_, q) => Some(q.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            (q.bid_wad, q.ask_wad),
            (18_011 * WAD / 100, 18_013 * WAD / 100)
        );
        assert_eq!(
            m.iter()
                .filter(|x| matches!(x, StreamMsg::Quote(..)))
                .count(),
            1,
            "one-sided quote skipped"
        );
        let st: Vec<bool> = m
            .iter()
            .filter_map(|x| match x {
                StreamMsg::Status { halted, .. } => Some(*halted),
                _ => None,
            })
            .collect();
        assert_eq!(st, vec![true, false]);
        assert_eq!(
            m.iter()
                .filter(|x| matches!(x, StreamMsg::Luld { .. }))
                .count(),
            3
        );
    }

    #[test]
    fn subscribe_params() {
        let s = PolygonStream {
            url: String::new(),
            api_key: "k".into(),
            conditions: HashMap::new(),
            plans: HashMap::new(),
        };
        let v: serde_json::Value =
            serde_json::from_str(&s.subscribe(&["NVDA".into(), "SPY".into()])).unwrap();
        assert_eq!(v["params"], "T.NVDA,Q.NVDA,LULD.NVDA,T.SPY,Q.SPY,LULD.SPY");
    }
}
