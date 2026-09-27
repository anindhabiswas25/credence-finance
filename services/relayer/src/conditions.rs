//! Trade-condition filtering for LIVE prices (§10.1: "consolidated last sale, filtered to
//! regular-session eligible trade conditions").
//!
//! Classification works on the SIP sale-condition codes of the CTA and UTP plans, the codes Alpaca
//! returns directly and that Polygon maps its numeric ids to (`/v3/reference/conditions`
//! `sip_mapping`). A trade is regular-eligible only if **every** condition on it updates the
//! consolidated last sale. Anything unknown is ineligible (fail closed).

use crate::asset::Plan;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TradeClass {
    /// Updates the consolidated last sale during the regular session.
    pub regular: bool,
    /// Usable as an extended-hours print (Form T / extended-hours trades, plus regular-eligible ones).
    pub extended: bool,
    /// Market Center Official Open (reported by the listing market).
    pub official_open: bool,
    /// Market Center Official Close.
    pub official_close: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Code {
    /// Updates last sale.
    Eligible,
    /// Extended-hours trade (Form T): not a regular print, fine for EXTENDED.
    FormT,
    OfficialOpen,
    OfficialClose,
    /// Never a LIVE print: average price, cash, next day, odd lot, out of sequence, contingent, …
    Ineligible,
}

fn code(plan: Plan, c: &str) -> Code {
    use Code::*;
    match (plan, c) {
        // regular way
        (_, "" | " " | "@") => Eligible,
        // official market-center prints: reference prints, they do not update the consolidated last
        (_, "Q") => OfficialOpen,
        (_, "M") => OfficialClose,
        // extended hours (Form T)
        (_, "T") => FormT,
        // eligible modifiers common to both plans
        (_, "E" | "F" | "K" | "L" | "O" | "S" | "X" | "Y" | "1" | "5" | "6" | "A" | "D") => {
            Eligible
        }
        // "B": UTP Bunched Trade (eligible) vs CTA Average Price Trade (ineligible)
        (Plan::Utp, "B") => Eligible,
        (Plan::Cta, "B") => Ineligible,
        // "I": CTA CAP Election / UTP Odd Lot — treated as odd lot on both (odd lots never update last)
        (_, "I") => Ineligible,
        (_, "C" | "G" | "H" | "N" | "P" | "R" | "U" | "V" | "W" | "Z" | "4" | "7" | "8" | "9") => {
            Ineligible
        }
        _ => Ineligible,
    }
}

/// Classify one trade from its SIP condition codes.
pub fn classify(plan: Plan, conditions: &[String]) -> TradeClass {
    let codes: Vec<Code> = conditions.iter().map(|c| code(plan, c.trim())).collect();
    let official_open = codes.contains(&Code::OfficialOpen);
    let official_close = codes.contains(&Code::OfficialClose);
    let any_bad = codes.iter().any(|c| {
        matches!(
            c,
            Code::Ineligible | Code::OfficialOpen | Code::OfficialClose
        )
    });
    let form_t = codes.contains(&Code::FormT);
    TradeClass {
        regular: !any_bad && !form_t,
        extended: !any_bad,
        official_open,
        official_close,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn regular_way_trades_are_eligible() {
        assert!(classify(Plan::Utp, &c(&["@"])).regular);
        assert!(classify(Plan::Cta, &c(&[])).regular);
        assert!(classify(Plan::Utp, &c(&["@", "F"])).regular); // intermarket sweep
        assert!(classify(Plan::Cta, &c(&["@", "O"])).regular); // opening trade
        assert!(classify(Plan::Utp, &c(&["@", "6"])).regular); // closing print
    }

    #[test]
    fn odd_lots_and_derived_prints_are_rejected() {
        for codes in [
            &["@", "I"][..],
            &["W"],
            &["C"],
            &["N"],
            &["P"],
            &["Z"],
            &["4"],
            &["7"],
            &["V"],
            &["H"],
        ] {
            let k = classify(Plan::Utp, &c(codes));
            assert!(!k.regular && !k.extended, "{codes:?}");
        }
        assert!(
            !classify(Plan::Cta, &c(&["B"])).regular,
            "CTA B = average price"
        );
        assert!(classify(Plan::Utp, &c(&["B"])).regular, "UTP B = bunched");
    }

    #[test]
    fn form_t_is_extended_only() {
        let k = classify(Plan::Utp, &c(&["@", "T"]));
        assert!(!k.regular);
        assert!(k.extended);
        let k = classify(Plan::Utp, &c(&["@", "T", "I"]));
        assert!(!k.extended, "odd-lot Form T");
    }

    #[test]
    fn official_prints_are_flagged_but_not_live() {
        let o = classify(Plan::Utp, &c(&["Q"]));
        assert!(o.official_open && !o.regular);
        let m = classify(Plan::Cta, &c(&["M"]));
        assert!(m.official_close && !m.regular);
    }

    #[test]
    fn unknown_codes_fail_closed() {
        assert!(!classify(Plan::Utp, &c(&["?"])).regular);
        assert!(!classify(Plan::Cta, &c(&["@", "%"])).extended);
    }
}
