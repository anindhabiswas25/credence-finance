//! Credence AuctionMath: the auction half of the Risk Engine split (Build Guide §8.9, R-24).
//!
//! The full Risk Engine does not fit one Stylus code fragment (ArbOS 40), so it is split in two programs behind the
//! one Solidity `IRiskEngine` (contracts/src/risk/RiskEngineRouter.sol, ADR-0108): the PricingEngine
//! (stylus/risk-engine: scenario sets, σ, params, safe LTV, Bell, premium) and this program: the joint stress
//! columns with the capacity math (F-4.4, R-13) and the pure liquidation math (F-4.5). σ, κ, u_max and K come from
//! the PricingEngine through the router; only the router (`owner`) writes the joint columns.
//! All math is `credence-risk-core`, so results are bit-identical to native (stylus/risk-engine-diff).
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use alloy_primitives::{Address, FixedBytes, U256};
use alloy_sol_types::sol;
use credence_risk_core as rc;
use stylus_sdk::{crypto::keccak, prelude::*, storage::*};

sol! {
    #[derive(Debug)]
    error Unauthorized();
    #[derive(Debug)]
    error UnknownSet(bytes32 assetId, uint8 closureType);
    #[derive(Debug)]
    error MathError(uint8 code);

    event JointColumnUpdated(bytes32 asset, bytes32 hash);
}

/// Every revert of AuctionMath (a subset of the `IRiskEngine` errors, same selectors).
#[derive(SolidityError, Debug)]
pub enum AuctionError {
    Unauthorized(Unauthorized),
    UnknownSet(UnknownSet),
    MathError(MathError),
}

impl From<rc::MathError> for AuctionError {
    fn from(e: rc::MathError) -> Self {
        AuctionError::MathError(MathError { code: e.code() })
    }
}

#[storage]
#[entrypoint]
pub struct AuctionMath {
    owner: StorageAddress, // the RiskEngineRouter
    // per asset: the K joint stress weekends, 16 × int16 per word, weekend order (R-13)
    joint_words: StorageMap<FixedBytes<32>, StorageVec<StorageU256>>,
    joint_hash: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
}

#[public]
impl AuctionMath {
    #[constructor]
    pub fn constructor(&mut self, owner: Address) {
        self.owner.set(owner);
    }

    /// onlyOwner (the router, itself onlyTimelock). K values, weekend order; `k` = RiskParams.kStress.
    pub fn set_joint_column(
        &mut self,
        asset_id: FixedBytes<32>,
        packed_z: Vec<U256>,
        k: u32,
    ) -> Result<(), AuctionError> {
        if self.vm().msg_sender() != self.owner.get() {
            return Err(AuctionError::Unauthorized(Unauthorized {}));
        }
        if k == 0 || packed_z.len() != (k as usize).div_ceil(16) {
            return Err(rc::MathError::InvalidInput.into());
        }
        let mut words = self.joint_words.setter(asset_id);
        words.erase();
        let mut payload = Vec::with_capacity(packed_z.len() * 32);
        for w in &packed_z {
            words.push(*w);
            payload.extend_from_slice(&w.to_be_bytes::<32>());
        }
        let hash = keccak(&payload);
        self.joint_hash.setter(asset_id).set(hash);
        self.vm().log(JointColumnUpdated {
            asset: asset_id,
            hash,
        });
        Ok(())
    }

    /// keccak256 of the stored joint column (== `columnHashes[i]` of the ADR-0106 joint file).
    pub fn joint_hash(&self, asset_id: FixedBytes<32>) -> FixedBytes<32> {
        self.joint_hash.get(asset_id)
    }

    pub fn owner(&self) -> Address {
        self.owner.get()
    }

    /// Per-weekend loss of one covered position over the asset's joint column (F-4.4), 4 × uint64 per word.
    pub fn cover_loss_vector(
        &self,
        asset_id: FixedBytes<32>,
        sigma: U256,
        kappa: U256,
        k: u32,
        collateral_value: U256,
        debt_projected: U256,
    ) -> Result<Vec<U256>, AuctionError> {
        let joint = self.joint(asset_id, k)?;
        let lv = rc::loss_vector(
            &rc::SliceZ(&joint),
            collateral_value,
            debt_projected,
            sigma,
            U256::ZERO,
            kappa,
        )?;
        Ok(rc::fixed::pack_u64(&lv))
    }

    /// Capacity check (F-4.4, R-13): (ok, utilAfter, worstLoss).
    #[allow(clippy::too_many_arguments)]
    pub fn pool_capacity(
        &self,
        packed_current: Vec<U256>,
        packed_add: Vec<U256>,
        unc_assets: Vec<FixedBytes<32>>,
        unc_sigmas: Vec<U256>,
        unc_collateral_value: Vec<U256>,
        unc_safe_ltv: Vec<U256>,
        equity: U256,
        kappa: U256,
        u_max: U256,
        k: u32,
    ) -> Result<(bool, U256, U256), AuctionError> {
        let m = unc_assets.len();
        if unc_sigmas.len() != m || unc_collateral_value.len() != m || unc_safe_ltv.len() != m {
            return Err(rc::MathError::InvalidInput.into());
        }
        let mut joints = Vec::with_capacity(m);
        for a in &unc_assets {
            joints.push(self.joint(*a, k)?);
        }
        let slices: Vec<rc::SliceZ<'_>> = joints.iter().map(|j| rc::SliceZ(j)).collect();
        let mut unc = Vec::with_capacity(m);
        for i in 0..m {
            unc.push(rc::UncoveredMarket {
                joint: &slices[i],
                sigma: unc_sigmas[i],
                dividend: U256::ZERO,
                collateral_value: unc_collateral_value[i],
                safe_ltv: unc_safe_ltv[i],
            });
        }
        let r = rc::pool_capacity(&packed_current, &packed_add, k, &unc, kappa, equity, u_max)?;
        Ok((r.ok, r.util_after, r.worst_loss))
    }
    /// F-4.5a lot, sized at the reserve price, health measured at `hf_price`.
    #[allow(clippy::too_many_arguments)]
    pub fn liquidation_lot(
        debt: U256,
        qty: U256,
        sizing_price: U256,
        hf_price: U256,
        lt: U256,
        h_star: U256,
        lambda: U256,
        coll_dec: u8,
        loan_dec: u8,
    ) -> Result<U256, AuctionError> {
        Ok(rc::liquidation_lot(
            debt,
            qty,
            sizing_price,
            hf_price,
            lt,
            h_star,
            lambda,
            coll_dec,
            loan_dec,
        )?)
    }

    /// F-4.5b pre-close lot (R-06), sized at R_pre down to `target_ltv`.
    #[allow(clippy::too_many_arguments)]
    pub fn preclose_lot(
        debt: U256,
        qty: U256,
        valuation: U256,
        reserve: U256,
        target_ltv: U256,
        lambda_pre: U256,
        coll_dec: u8,
        loan_dec: u8,
    ) -> Result<U256, AuctionError> {
        Ok(rc::preclose_lot(
            debt, qty, valuation, reserve, target_ltv, lambda_pre, coll_dec, loan_dec,
        )?)
    }

    /// F-4.5c uniform-price clearing with pro-rata ties (R-05).
    pub fn clear(
        qtys: Vec<U256>,
        prices: Vec<U256>,
        tie_keys: Vec<FixedBytes<32>>,
        lot: U256,
        reserve: U256,
    ) -> Result<(U256, Vec<U256>, U256), AuctionError> {
        let r = rc::clear(&qtys, &prices, &tie_keys, lot, reserve)?;
        Ok((r.p_star, r.fills, r.q_pool))
    }
}

impl AuctionMath {
    /// The asset's joint column, unpacked (K values). A missing or stale-length column is `UnknownSet(asset, 0)`.
    fn joint(&self, asset_id: FixedBytes<32>, k: u32) -> Result<Vec<i16>, AuctionError> {
        let k = k as usize;
        let words = self.joint_words.getter(asset_id);
        if k == 0 || words.len() != k.div_ceil(16) {
            return Err(AuctionError::UnknownSet(UnknownSet {
                assetId: asset_id,
                closureType: 0,
            }));
        }
        let mut z = Vec::with_capacity(k);
        for w in 0..words.len() {
            let word = words.get(w).unwrap_or_default();
            for lane in 0..16 {
                if z.len() == k {
                    break;
                }
                z.push(rc::fixed::unpack_i16(word, lane));
            }
        }
        Ok(z)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::testing::*;

    const WAD: u64 = 1_000_000_000_000_000_000;

    #[test]
    fn matches_core() {
        let x = AuctionMath::liquidation_lot(
            U256::from(13_500_000_000u64),
            U256::from(100u64) * U256::from(WAD),
            U256::from(153_648u64) * U256::from(WAD) / U256::from(1000u64),
            U256::from(158_400u64) * U256::from(WAD) / U256::from(1000u64),
            U256::from(8 * WAD / 10),
            U256::from(11 * WAD / 10),
            U256::from(3 * WAD / 100),
            18,
            6,
        )
        .unwrap();
        assert!(x.to_string().starts_with("585131"));
        let (p, fills, q_pool) = AuctionMath::clear(
            vec![U256::from(300u64), U256::from(300u64)],
            vec![U256::from(12440u64), U256::from(12411u64)],
            vec![FixedBytes::repeat_byte(1), FixedBytes::repeat_byte(2)],
            U256::from(500u64),
            U256::from(12222u64),
        )
        .unwrap();
        assert_eq!(
            (p, fills, q_pool),
            (
                U256::from(12411u64),
                vec![U256::from(300u64), U256::from(200u64)],
                U256::ZERO
            )
        );
        assert!(matches!(
            AuctionMath::preclose_lot(
                U256::ZERO,
                U256::from(1u8),
                U256::ZERO,
                U256::ZERO,
                U256::from(2 * WAD),
                U256::ZERO,
                18,
                6
            ),
            Err(AuctionError::MathError(MathError { code: 3 }))
        ));
    }

    #[test]
    fn capacity_matches_core() {
        let vm = TestVM::default();
        let router = Address::repeat_byte(0x42);
        let mut e = AuctionMath::from(&vm);
        e.constructor(router);
        let asset = FixedBytes::repeat_byte(3);
        let joint: Vec<i16> = (0..256).map(|j| ((j * 131) % 9001) as i16 - 7000).collect();
        let packed_z = rc::fixed::pack_i16(&joint);
        assert!(matches!(
            e.set_joint_column(asset, packed_z.clone(), 256),
            Err(AuctionError::Unauthorized(_))
        ));
        vm.set_sender(router);
        assert!(matches!(
            e.set_joint_column(asset, packed_z[..10].to_vec(), 256),
            Err(AuctionError::MathError(_))
        ));
        e.set_joint_column(asset, packed_z.clone(), 256).unwrap();
        let mut bytes = Vec::new();
        for w in &packed_z {
            bytes.extend_from_slice(&w.to_be_bytes::<32>());
        }
        assert_eq!(e.joint_hash(asset), keccak(&bytes));

        let w = |x: u64| U256::from(x);
        let (sigma, kappa) = (w(45 * (WAD / 1000)), w(3 * WAD / 100));
        let (c, d) = (w(90_000_000_000), w(67_028_990_000));
        let lv = rc::loss_vector(&rc::SliceZ(&joint), c, d, sigma, U256::ZERO, kappa).unwrap();
        let packed = rc::fixed::pack_u64(&lv);
        assert_eq!(
            e.cover_loss_vector(asset, sigma, kappa, 256, c, d).unwrap(),
            packed
        );
        let safe = w(712_580_117_506_000_000);
        let r = rc::pool_capacity(
            &packed,
            &packed,
            256,
            &[rc::UncoveredMarket {
                joint: &rc::SliceZ(&joint),
                sigma,
                dividend: U256::ZERO,
                collateral_value: w(50_000_000_000),
                safe_ltv: safe,
            }],
            kappa,
            w(40_000_000_000),
            w(WAD / 2),
        )
        .unwrap();
        assert_eq!(
            e.pool_capacity(
                packed.clone(),
                packed.clone(),
                vec![asset],
                vec![sigma],
                vec![w(50_000_000_000)],
                vec![safe],
                w(40_000_000_000),
                kappa,
                w(WAD / 2),
                256
            )
            .unwrap(),
            (r.ok, r.util_after, r.worst_loss)
        );
        assert!(matches!(
            e.cover_loss_vector(FixedBytes::repeat_byte(9), sigma, kappa, 256, c, d),
            Err(AuctionError::UnknownSet(_))
        ));
        assert!(matches!(
            e.cover_loss_vector(asset, sigma, kappa, 512, c, d),
            Err(AuctionError::UnknownSet(_))
        ));
    }
}
