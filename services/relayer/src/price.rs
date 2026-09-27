//! Exact price arithmetic in WAD (1e18 USD per share, §7.1). Vendor prices arrive as JSON numbers;
//! they are converted through their shortest decimal representation, so `161.2958` becomes exactly
//! `161_295_800_000_000_000_000`, never a binary-float neighbour.

use anyhow::{anyhow, bail, Result};

pub const WAD: u128 = 1_000_000_000_000_000_000;
/// Parts per million, the unit for every tolerance in the relayer.
pub const PPM: u128 = 1_000_000;

/// Parse a non-negative decimal string ("161.2958", "1e-3", "180") into WAD, rounding half-up past
/// 18 decimals.
pub fn wad_from_decimal(s: &str) -> Result<u128> {
    let s = s.trim();
    if s.is_empty() || s.starts_with('-') {
        bail!("not a non-negative decimal: {s:?}");
    }
    let (mantissa, exp) = match s.find(['e', 'E']) {
        Some(i) => (
            &s[..i],
            s[i + 1..]
                .parse::<i32>()
                .map_err(|_| anyhow!("bad exponent in {s:?}"))?,
        ),
        None => (s, 0),
    };
    let (int, frac) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    if !int.chars().chain(frac.chars()).all(|c| c.is_ascii_digit())
        || (int.is_empty() && frac.is_empty())
    {
        bail!("not a decimal: {s:?}");
    }
    let digits: String = format!("{int}{frac}");
    // value = digits × 10^(exp − frac.len()); WAD = value × 10^18
    let shift = exp - frac.len() as i32 + 18;
    let digits = digits.trim_start_matches('0');
    if digits.is_empty() {
        return Ok(0);
    }
    if shift >= 0 {
        let base: u128 = digits
            .parse()
            .map_err(|_| anyhow!("price too large: {s:?}"))?;
        let mul = 10u128
            .checked_pow(shift as u32)
            .ok_or_else(|| anyhow!("price too large: {s:?}"))?;
        base.checked_mul(mul)
            .ok_or_else(|| anyhow!("price too large: {s:?}"))
    } else {
        let cut = (-shift) as usize;
        if cut > digits.len() {
            return Ok(0); // below 0.1 wei of WAD
        }
        let (keep, drop) = digits.split_at(digits.len() - cut);
        let mut v: u128 = if keep.is_empty() {
            0
        } else {
            keep.parse().map_err(|_| anyhow!("price too large"))?
        };
        if drop.as_bytes()[0] >= b'5' {
            v += 1;
        }
        Ok(v)
    }
}

/// WAD from a JSON float via its shortest round-trip decimal form.
pub fn wad_from_f64(p: f64) -> Result<u128> {
    if !p.is_finite() || p < 0.0 {
        bail!("bad price {p}");
    }
    wad_from_decimal(&format!("{p}"))
}

/// |a − b| / min(a, b) in ppm (u128::MAX if either is zero).
pub fn rel_diff_ppm(a: u128, b: u128) -> u128 {
    let lo = a.min(b);
    if lo == 0 {
        return u128::MAX;
    }
    let diff = a.abs_diff(b);
    // diff × 1e6 fits: prices are < 1e30 WAD in any sane market
    diff.saturating_mul(PPM) / lo
}

/// |p − reference| / reference in ppm.
pub fn deviation_ppm(p: u128, reference: u128) -> u128 {
    if reference == 0 {
        return u128::MAX;
    }
    p.abs_diff(reference).saturating_mul(PPM) / reference
}

/// Display helper: WAD → "123.456789" (6 dp, truncated).
pub fn fmt_wad(w: u128) -> String {
    format!("{}.{:06}", w / WAD, (w % WAD) / 1_000_000_000_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimal_to_wad_is_exact() {
        assert_eq!(
            wad_from_decimal("161.2958").unwrap(),
            161_295_800_000_000_000_000
        );
        assert_eq!(wad_from_decimal("180").unwrap(), 180 * WAD);
        assert_eq!(wad_from_decimal("0.0001").unwrap(), 100_000_000_000_000);
        assert_eq!(wad_from_decimal("1.5e2").unwrap(), 150 * WAD);
        assert_eq!(wad_from_decimal("1e-18").unwrap(), 1);
        assert_eq!(wad_from_decimal("0.0000000000000000015").unwrap(), 2);
        assert_eq!(wad_from_decimal("0.0000000000000000014").unwrap(), 1);
        assert_eq!(wad_from_decimal("0").unwrap(), 0);
        assert!(wad_from_decimal("-1").is_err());
        assert!(wad_from_decimal("abc").is_err());
        assert!(wad_from_decimal("").is_err());
    }

    #[test]
    fn f64_goes_through_shortest_repr() {
        assert_eq!(wad_from_f64(161.2958).unwrap(), 161_295_800_000_000_000_000);
        assert_eq!(wad_from_f64(0.1 + 0.2).unwrap(), 300_000_000_000_000_040); // 0.30000000000000004
        assert_eq!(wad_from_f64(174.0).unwrap(), 174 * WAD);
        assert!(wad_from_f64(f64::NAN).is_err());
    }

    #[test]
    fn relative_differences() {
        assert_eq!(rel_diff_ppm(100 * WAD, 101 * WAD), 10_000);
        assert_eq!(rel_diff_ppm(101 * WAD, 100 * WAD), 10_000);
        assert_eq!(deviation_ppm(1001 * WAD / 10, 100 * WAD), 1_000);
        assert_eq!(rel_diff_ppm(0, 1), u128::MAX);
        assert_eq!(fmt_wad(161_295_800_000_000_000_000), "161.295800");
    }
}
