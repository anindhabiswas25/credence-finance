//! Assets as configured in `ASSETS=NVDA:XNAS,AAPL:XNAS,…,SPY:ARCX` (§12.1). The id is
//! `keccak256("<TICKER>:<MIC>")` (§7.5); the MIC is the primary listing exchange, which is where the
//! official opening and closing auction prints come from.

use alloy::primitives::{keccak256, B256};
use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct Asset {
    pub symbol: String,
    /// Primary listing exchange MIC (XNAS, XNYS, ARCX, …).
    pub listing: String,
    pub id: B256,
}

impl Asset {
    pub fn parse(spec: &str) -> Result<Self> {
        let Some((symbol, listing)) = spec.trim().split_once(':') else {
            bail!("asset {spec:?} must be TICKER:MIC");
        };
        let (symbol, listing) = (symbol.trim().to_uppercase(), listing.trim().to_uppercase());
        if symbol.is_empty() || !symbol.chars().all(|c| c.is_ascii_alphanumeric() || c == '.') {
            bail!("bad ticker in {spec:?}");
        }
        if !matches!(listing.as_str(), "XNAS" | "XNYS" | "ARCX" | "XASE" | "BATS") {
            bail!("unsupported listing venue {listing} in {spec:?}");
        }
        let id = keccak256(format!("{symbol}:{listing}"));
        Ok(Self { symbol, listing, id })
    }

    pub fn parse_list(list: &[String]) -> Result<Vec<Self>> {
        let v: Vec<Self> = list.iter().map(|s| Self::parse(s)).collect::<Result<_>>()?;
        if v.is_empty() {
            bail!("ASSETS is empty");
        }
        Ok(v)
    }

    /// SIP tape: Nasdaq-listed → UTP (tape C); NYSE, Arca, American, Cboe → CTA (tape A/B).
    pub fn plan(&self) -> Plan {
        if self.listing == "XNAS" {
            Plan::Utp
        } else {
            Plan::Cta
        }
    }
}

/// The SIP plan whose sale-condition codes apply to a trade.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Plan {
    Cta,
    Utp,
}

impl Plan {
    /// From a tape letter (A/B → CTA, C → UTP) or Polygon's tape number (1/2 → CTA, 3 → UTP).
    pub fn from_tape(t: &str) -> Option<Self> {
        match t {
            "A" | "B" | "1" | "2" => Some(Self::Cta),
            "C" | "3" => Some(Self::Utp),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_hashes() {
        let a = Asset::parse("nvda:xnas").unwrap();
        assert_eq!(a.symbol, "NVDA");
        assert_eq!(a.id, keccak256("NVDA:XNAS"));
        assert_eq!(a.plan(), Plan::Utp);
        assert_eq!(Asset::parse("SPY:ARCX").unwrap().plan(), Plan::Cta);
        assert!(Asset::parse("NVDA").is_err());
        assert!(Asset::parse("NVDA:XLON").is_err());
    }
}
