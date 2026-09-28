//! Credence Risk Engine: Stylus contract, a thin wrapper over `credence-risk-core` plus storage
//! (Build Guide §8.9).
//!
//! The PricingEngine half of the Risk Engine split (R-24, ADR-0108): scenario sets, σ and params, `safeLtv`,
//! `bellStatus`, `quoteCover`, and their writers / views. The second program (stylus/auction-math) holds the joint
//! stress columns, the capacity math (`coverLossVector`, `poolCapacity`) and the auction math (`liquidationLot`,
//! `precloseLot`, `clear`). Both sit behind the one Solidity `IRiskEngine` (contracts/src/risk/RiskEngineRouter.sol). Storage for scenario sets, joint stress columns and σ; the timelock and
//! sigma-oracle gates, including the σ rate limit (R-15: up any amount, down at most 10%/day, never below the
//! floor). Scenario sets are read from storage lazily (one SLOAD per 16 values), so `quoteCover` only touches the
//! loss tail (R-14).
//!
//! Holds no funds, has no discretionary admin, and is a pure function of its storage and inputs. All math is
//! `credence-risk-core`, so native and on-chain results are bit-identical (proved by `stylus/risk-engine-diff`).
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use alloy_primitives::{Address, FixedBytes, U256, U32, U64};
use alloy_sol_types::sol;
use core::cell::Cell;
use credence_risk_core as rc;
use stylus_sdk::{crypto::keccak, prelude::*, storage::*};

sol! {
    /// Mirrors `RiskParams` in contracts/src/libraries/Types.sol.
    #[derive(Debug, PartialEq, Eq, AbiType)]
    struct RiskParams {
        uint64 alpha;
        uint64 kappa;
        uint64 theta;
        uint64 costOfCap;
        uint64 eta;
        uint64 beta;
        uint64 uMax;
        uint64 minPremium;
        uint32 kStress;
    }

    #[derive(Debug)]
    error Unauthorized();
    #[derive(Debug)]
    error NotSorted();
    #[derive(Debug)]
    error UnknownSet(bytes32 assetId, uint8 closureType);
    #[derive(Debug)]
    error SigmaDropTooFast(uint256 current, uint256 proposed, uint256 minAllowed);
    #[derive(Debug)]
    error SigmaBelowFloor(uint256 floor, uint256 proposed);
    #[derive(Debug)]
    error MathError(uint8 code);

    event ScenarioSetUpdated(bytes32 asset, uint8 closureType, bytes32 hash, uint32 n);
    event SigmaUpdated(bytes32 asset, uint8 closureType, uint256 sigma);
    event SigmaFloorSet(bytes32 asset, uint8 closureType, uint256 floor);
    event ParamsUpdated(RiskParams p);
}

/// Every revert of the engine, ABI-compatible with `IRiskEngine`.
#[derive(SolidityError, Debug)]
pub enum EngineError {
    Unauthorized(Unauthorized),
    NotSorted(NotSorted),
    UnknownSet(UnknownSet),
    SigmaDropTooFast(SigmaDropTooFast),
    SigmaBelowFloor(SigmaBelowFloor),
    MathError(MathError),
}

impl From<rc::MathError> for EngineError {
    fn from(e: rc::MathError) -> Self {
        EngineError::MathError(MathError { code: e.code() })
    }
}

#[storage]
pub struct StorageParams {
    alpha: StorageU64,
    kappa: StorageU64,
    theta: StorageU64,
    cost_of_cap: StorageU64,
    eta: StorageU64,
    beta: StorageU64,
    u_max: StorageU64,
    min_premium: StorageU64,
    k_stress: StorageU32,
}

#[storage]
#[entrypoint]
pub struct RiskEngine {
    timelock: StorageAddress,
    sigma_oracle: StorageAddress,
    // key = keccak256(abi.encodePacked(assetId, closureType))
    set_words: StorageMap<FixedBytes<32>, StorageVec<StorageU256>>, // sorted z, 16 × int16 per word
    set_len: StorageMap<FixedBytes<32>, StorageU32>,
    set_hash: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
    sigma: StorageMap<FixedBytes<32>, StorageU256>,
    sigma_floor: StorageMap<FixedBytes<32>, StorageU256>,
    sigma_at: StorageMap<FixedBytes<32>, StorageU64>,
    params: StorageParams,
}

/// A stored scenario set read lazily: one SLOAD per word of 16 values, the last word cached.
struct StoredZ<'a> {
    words: StorageGuard<'a, StorageVec<StorageU256>>,
    n: u32,
    cache: Cell<(u32, U256)>,
}

impl rc::ZSource for StoredZ<'_> {
    fn len(&self) -> u32 {
        self.n
    }
    fn z(&self, i: u32) -> i16 {
        let w = i / 16;
        let (cw, cv) = self.cache.get();
        let word = if cw == w {
            cv
        } else {
            let v = self.words.get(w as usize).unwrap_or_default();
            self.cache.set((w, v));
            v
        };
        rc::fixed::unpack_i16(word, (i % 16) as usize)
    }
}

/// Storage key of an (asset, closure type) pair.
pub fn set_key(asset_id: FixedBytes<32>, closure_type: u8) -> FixedBytes<32> {
    let mut b = [0u8; 33];
    b[..32].copy_from_slice(asset_id.as_slice());
    b[32] = closure_type;
    keccak(b)
}

fn u64_of(x: U64) -> U256 {
    U256::from(x.to::<u64>())
}

#[public]
impl RiskEngine {
    #[constructor]
    pub fn constructor(&mut self, timelock: Address, sigma_oracle: Address) {
        self.timelock.set(timelock);
        self.sigma_oracle.set(sigma_oracle);
    }

    // ───────────────────────────── closure risk ─────────────────────────────

    /// F-4.2: min(maxLtv, (1 + σ·z_{i*}/1000 − d)(1 − κ)) at i* = ⌈α·N⌉ − 1 of the stored set.
    pub fn safe_ltv(
        &self,
        asset_id: FixedBytes<32>,
        closure_type: u8,
        max_ltv: U256,
        dividend: U256,
    ) -> Result<U256, EngineError> {
        let key = set_key(asset_id, closure_type);
        let n = self.set_len.get(key).to::<u32>();
        if n == 0 {
            return Err(EngineError::UnknownSet(UnknownSet {
                assetId: asset_id,
                closureType: closure_type,
            }));
        }
        let alpha = u64_of(self.params.alpha.get());
        let kappa = u64_of(self.params.kappa.get());
        let idx = rc::quantile_index(n, alpha)?;
        let z = self.read_z(key, idx);
        let sigma = self.sigma.get(key);
        Ok(rc::safe_ltv(z, sigma, dividend, kappa, max_ltv)?)
    }

    /// Bell status for the closure (F-4.2 at the stored set): (status, cureRepay, cureCollateralValue).
    #[allow(clippy::too_many_arguments)]
    pub fn bell_status(
        &self,
        asset_id: FixedBytes<32>,
        closure_type: u8,
        collateral_value: U256,
        debt_projected: U256,
        max_ltv: U256,
        dividend: U256,
        covered: bool,
    ) -> Result<(u8, U256, U256), EngineError> {
        let safe = self.safe_ltv(asset_id, closure_type, max_ltv, dividend)?;
        let b = rc::bell_status(collateral_value, debt_projected, safe, covered)?;
        Ok((b.status, b.cure_repay, b.cure_collateral_value))
    }

    /// Gap Cover quote (F-4.3, R-22 zero price floor): (premium, expectedLoss, expectedShortfall), loan units.
    pub fn quote_cover(
        &self,
        asset_id: FixedBytes<32>,
        closure_type: u8,
        closure_days: u16,
        collateral_value: U256,
        debt_projected: U256,
        util_after: U256,
    ) -> Result<(U256, U256, U256), EngineError> {
        let key = set_key(asset_id, closure_type);
        let set = self.stored_set(key, asset_id, closure_type)?;
        let p = &self.params;
        let q = rc::quote_cover(
            &set,
            &rc::PremiumParams {
                sigma: self.sigma.get(key),
                dividend: U256::ZERO,
                kappa: u64_of(p.kappa.get()),
                collateral_value,
                debt_projected,
                closure_days,
                util_after,
                theta: u64_of(p.theta.get()),
                cost_of_cap: u64_of(p.cost_of_cap.get()),
                eta: u64_of(p.eta.get()),
                beta: u64_of(p.beta.get()),
                min_premium: u64_of(p.min_premium.get()),
            },
        )?;
        Ok((q.premium, q.expected_loss, q.expected_shortfall))
    }

    // ───────────────────────────── writers ─────────────────────────────

    /// onlyTimelock. Stores an ascending set (16 × int16 per word) and keccak256 of the packed words.
    pub fn set_scenario_set(
        &mut self,
        asset_id: FixedBytes<32>,
        closure_type: u8,
        packed_sorted_z: Vec<U256>,
        n: u32,
    ) -> Result<(), EngineError> {
        self.only_timelock()?;
        let src = rc::PackedZ::new(&packed_sorted_z, n)?;
        if n == 0 || packed_sorted_z.len() != (n as usize).div_ceil(16) {
            return Err(rc::MathError::InvalidInput.into());
        }
        if !rc::is_sorted(&src) {
            return Err(EngineError::NotSorted(NotSorted {}));
        }
        let key = set_key(asset_id, closure_type);
        let mut words = self.set_words.setter(key);
        words.erase();
        let mut payload = Vec::with_capacity(packed_sorted_z.len() * 32);
        for w in &packed_sorted_z {
            words.push(*w);
            payload.extend_from_slice(&w.to_be_bytes::<32>());
        }
        let hash = keccak(&payload);
        self.set_len.setter(key).set(U32::from(n));
        self.set_hash.setter(key).set(hash);
        self.vm().log(ScenarioSetUpdated {
            asset: asset_id,
            closureType: closure_type,
            hash,
            n,
        });
        Ok(())
    }

    /// onlyTimelock.
    pub fn set_params(&mut self, p: RiskParams) -> Result<(), EngineError> {
        self.only_timelock()?;
        let wad = 1_000_000_000_000_000_000u64;
        if p.alpha == 0 || p.alpha > wad || p.kappa >= wad || p.beta > wad || p.uMax > wad {
            return Err(rc::MathError::InvalidInput.into());
        }
        self.params.alpha.set(U64::from(p.alpha));
        self.params.kappa.set(U64::from(p.kappa));
        self.params.theta.set(U64::from(p.theta));
        self.params.cost_of_cap.set(U64::from(p.costOfCap));
        self.params.eta.set(U64::from(p.eta));
        self.params.beta.set(U64::from(p.beta));
        self.params.u_max.set(U64::from(p.uMax));
        self.params.min_premium.set(U64::from(p.minPremium));
        self.params.k_stress.set(U32::from(p.kStress));
        self.vm().log(ParamsUpdated { p });
        Ok(())
    }

    /// onlyTimelock.
    pub fn set_sigma_floor(
        &mut self,
        asset_id: FixedBytes<32>,
        closure_type: u8,
        floor: U256,
    ) -> Result<(), EngineError> {
        self.only_timelock()?;
        let key = set_key(asset_id, closure_type);
        self.sigma_floor.setter(key).set(floor);
        self.vm().log(SigmaFloorSet {
            asset: asset_id,
            closureType: closure_type,
            floor,
        });
        Ok(())
    }

    /// onlySigmaOracle. Up any amount; down at most 10%/day (compounded over whole days); never below the floor.
    pub fn update_sigma(
        &mut self,
        asset_id: FixedBytes<32>,
        closure_type: u8,
        new_sigma: U256,
    ) -> Result<(), EngineError> {
        if self.vm().msg_sender() != self.sigma_oracle.get() {
            return Err(EngineError::Unauthorized(Unauthorized {}));
        }
        let key = set_key(asset_id, closure_type);
        let floor = self.sigma_floor.get(key);
        if new_sigma < floor {
            return Err(EngineError::SigmaBelowFloor(SigmaBelowFloor {
                floor,
                proposed: new_sigma,
            }));
        }
        let cur = self.sigma.get(key);
        let now = self.vm().block_timestamp();
        let days = rc::elapsed_days(self.sigma_at.get(key).to::<u64>(), now);
        let min_allowed = rc::sigma_min_allowed(cur, days)?;
        if new_sigma < min_allowed {
            return Err(EngineError::SigmaDropTooFast(SigmaDropTooFast {
                current: cur,
                proposed: new_sigma,
                minAllowed: min_allowed,
            }));
        }
        self.sigma.setter(key).set(new_sigma);
        self.sigma_at.setter(key).set(U64::from(now));
        self.vm().log(SigmaUpdated {
            asset: asset_id,
            closureType: closure_type,
            sigma: new_sigma,
        });
        Ok(())
    }

    // ───────────────────────────── views ─────────────────────────────

    pub fn sigma(&self, asset_id: FixedBytes<32>, closure_type: u8) -> U256 {
        self.sigma.get(set_key(asset_id, closure_type))
    }

    pub fn params(&self) -> RiskParams {
        RiskParams {
            alpha: self.params.alpha.get().to::<u64>(),
            kappa: self.params.kappa.get().to::<u64>(),
            theta: self.params.theta.get().to::<u64>(),
            costOfCap: self.params.cost_of_cap.get().to::<u64>(),
            eta: self.params.eta.get().to::<u64>(),
            beta: self.params.beta.get().to::<u64>(),
            uMax: self.params.u_max.get().to::<u64>(),
            minPremium: self.params.min_premium.get().to::<u64>(),
            kStress: self.params.k_stress.get().to::<u32>(),
        }
    }

    pub fn scenario_hash(&self, asset_id: FixedBytes<32>, closure_type: u8) -> FixedBytes<32> {
        self.set_hash.get(set_key(asset_id, closure_type))
    }

    /// When σ of (asset, type) was last written (unix seconds; 0 = never). Keeper J7 uses it for the rate limit.
    pub fn sigma_at(&self, asset_id: FixedBytes<32>, closure_type: u8) -> u64 {
        self.sigma_at
            .get(set_key(asset_id, closure_type))
            .to::<u64>()
    }

    pub fn timelock(&self) -> Address {
        self.timelock.get()
    }

    pub fn sigma_oracle(&self) -> Address {
        self.sigma_oracle.get()
    }
}

impl RiskEngine {
    fn only_timelock(&self) -> Result<(), EngineError> {
        if self.vm().msg_sender() != self.timelock.get() {
            return Err(EngineError::Unauthorized(Unauthorized {}));
        }
        Ok(())
    }

    fn stored_set(
        &self,
        key: FixedBytes<32>,
        asset_id: FixedBytes<32>,
        closure_type: u8,
    ) -> Result<StoredZ<'_>, EngineError> {
        let n = self.set_len.get(key).to::<u32>();
        if n == 0 {
            return Err(EngineError::UnknownSet(UnknownSet {
                assetId: asset_id,
                closureType: closure_type,
            }));
        }
        Ok(StoredZ {
            words: self.set_words.getter(key),
            n,
            cache: Cell::new((u32::MAX, U256::ZERO)),
        })
    }

    /// One SLOAD: the word holding z_idx.
    fn read_z(&self, key: FixedBytes<32>, idx: u32) -> i16 {
        let word = self
            .set_words
            .getter(key)
            .get(idx as usize / 16)
            .unwrap_or_default();
        rc::fixed::unpack_i16(word, idx as usize % 16)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::testing::*;

    const WAD: u64 = 1_000_000_000_000_000_000;

    fn setup() -> (TestVM, RiskEngine, Address, Address) {
        let vm = TestVM::default();
        let timelock = Address::repeat_byte(0x71);
        let oracle = Address::repeat_byte(0x51);
        let mut e = RiskEngine::from(&vm);
        e.constructor(timelock, oracle);
        (vm, e, timelock, oracle)
    }

    fn params() -> RiskParams {
        RiskParams {
            alpha: WAD / 1000,
            kappa: 3 * WAD / 100,
            theta: WAD,
            costOfCap: 15 * WAD / 100,
            eta: 4 * WAD,
            beta: 975 * (WAD / 1000),
            uMax: WAD / 2,
            minPremium: 500_000,
            kStress: 256,
        }
    }

    #[test]
    fn safe_ltv_matches_core_and_gates() {
        let (vm, mut e, timelock, oracle) = setup();
        let asset = FixedBytes::repeat_byte(7);
        // 1000 scenarios: the quantile (i* = 0) is -5897
        let mut set: Vec<i16> = (0..1000).map(|i| -5897 + i as i16 * 10).collect();
        set.sort();
        let packed = rc::fixed::pack_i16(&set);

        assert!(matches!(
            e.set_params(params()),
            Err(EngineError::Unauthorized(_))
        ));
        vm.set_sender(timelock);
        e.set_params(params()).unwrap();
        assert_eq!(e.params(), params());
        assert!(matches!(
            e.safe_ltv(asset, 2, U256::from(WAD), U256::ZERO),
            Err(EngineError::UnknownSet(_))
        ));
        let mut unsorted = set.clone();
        unsorted.swap(0, 1);
        assert!(matches!(
            e.set_scenario_set(asset, 2, rc::fixed::pack_i16(&unsorted), 1000),
            Err(EngineError::NotSorted(_))
        ));
        e.set_scenario_set(asset, 2, packed.clone(), 1000).unwrap();
        assert_ne!(e.scenario_hash(asset, 2), FixedBytes::ZERO);

        vm.set_sender(oracle);
        let sigma = U256::from(4 * WAD / 100);
        e.update_sigma(asset, 2, sigma).unwrap();
        let got = e
            .safe_ltv(asset, 2, U256::from(3 * WAD / 4), U256::ZERO)
            .unwrap();
        let want = rc::safe_ltv(
            -5897,
            sigma,
            U256::ZERO,
            U256::from(3 * WAD / 100),
            U256::from(3 * WAD / 4),
        )
        .unwrap();
        assert_eq!(got, want);
    }

    #[test]
    fn sigma_rate_limit() {
        let (vm, mut e, timelock, oracle) = setup();
        let asset = FixedBytes::repeat_byte(9);
        vm.set_sender(timelock);
        e.set_sigma_floor(asset, 1, U256::from(WAD / 100)).unwrap();
        vm.set_sender(Address::repeat_byte(0x99));
        assert!(matches!(
            e.update_sigma(asset, 1, U256::from(WAD)),
            Err(EngineError::Unauthorized(_))
        ));
        vm.set_sender(oracle);
        assert!(matches!(
            e.update_sigma(asset, 1, U256::from(WAD / 200)),
            Err(EngineError::SigmaBelowFloor(_))
        ));
        vm.set_block_timestamp(1_000_000);
        e.update_sigma(asset, 1, U256::from(WAD / 10)).unwrap(); // 10%
                                                                 // same day: cannot go down at all; can go up any amount
        assert!(matches!(
            e.update_sigma(asset, 1, U256::from(WAD / 10 - 1)),
            Err(EngineError::SigmaDropTooFast(_))
        ));
        e.update_sigma(asset, 1, U256::from(WAD / 5)).unwrap(); // 20%
                                                                // one day later: down to 90% allowed, not below
        vm.set_block_timestamp(1_000_000 + 86_400);
        assert!(matches!(
            e.update_sigma(asset, 1, U256::from(WAD * 18 / 100 - 1)),
            Err(EngineError::SigmaDropTooFast(_))
        ));
        e.update_sigma(asset, 1, U256::from(WAD * 18 / 100))
            .unwrap();
        assert_eq!(e.sigma(asset, 1), U256::from(WAD * 18 / 100));
    }

    /// Loads a set (N = 1000) and σ for `asset`, WEEKEND.
    fn loaded() -> (TestVM, RiskEngine, FixedBytes<32>, Vec<i16>, U256) {
        let (vm, mut e, timelock, oracle) = setup();
        let asset = FixedBytes::repeat_byte(3);
        vm.set_sender(timelock);
        e.set_params(params()).unwrap();
        let mut set: Vec<i16> = (0..1000)
            .map(|i| ((i * 7919) % 12001) as i16 - 9000)
            .collect();
        set.sort();
        e.set_scenario_set(asset, 2, rc::fixed::pack_i16(&set), 1000)
            .unwrap();
        vm.set_sender(oracle);
        let sigma = U256::from(45 * (WAD / 1000));
        vm.set_block_timestamp(7_000);
        e.update_sigma(asset, 2, sigma).unwrap();
        (vm, e, asset, set, sigma)
    }

    #[test]
    fn closure_functions_match_core() {
        let (_vm, e, asset, set, sigma) = loaded();
        let p = params();
        let w = |x: u64| U256::from(x);
        assert_eq!(e.sigma_at(asset, 2), 7_000);
        let (c, d) = (w(90_000_000_000), w(67_028_990_000));
        let safe = rc::safe_ltv_from_set(
            &rc::SliceZ(&set),
            w(p.alpha),
            sigma,
            U256::ZERO,
            w(p.kappa),
            w(3 * WAD / 4),
        )
        .unwrap();
        let b = rc::bell_status(c, d, safe, false).unwrap();
        assert_eq!(
            e.bell_status(asset, 2, c, d, w(3 * WAD / 4), U256::ZERO, false)
                .unwrap(),
            (b.status, b.cure_repay, b.cure_collateral_value)
        );

        let q = rc::quote_cover(
            &rc::SliceZ(&set),
            &rc::PremiumParams {
                sigma,
                dividend: U256::ZERO,
                kappa: w(p.kappa),
                collateral_value: c,
                debt_projected: d,
                closure_days: 3,
                util_after: w(WAD / 5),
                theta: w(p.theta),
                cost_of_cap: w(p.costOfCap),
                eta: w(p.eta),
                beta: w(p.beta),
                min_premium: w(p.minPremium),
            },
        )
        .unwrap();
        assert_eq!(
            e.quote_cover(asset, 2, 3, c, d, w(WAD / 5)).unwrap(),
            (q.premium, q.expected_loss, q.expected_shortfall)
        );

        // unknown set
        let other = FixedBytes::repeat_byte(4);
        assert!(matches!(
            e.quote_cover(other, 2, 3, c, d, U256::ZERO),
            Err(EngineError::UnknownSet(_))
        ));
    }
}
