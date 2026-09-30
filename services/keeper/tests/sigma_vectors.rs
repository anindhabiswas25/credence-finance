//! QE σ vectors (`calibration/docs/sigma-vectors.json`, spec `calibration/docs/sigma.md` v1): J7 must
//! reproduce every block exactly (floats compared bit for bit, WADs as integers).

use std::path::PathBuf;

use chrono::NaiveDate;
use credence_keeper::sigma::{
    classify, gap_return, submit_wad, AssetSigma, Gap, SigmaState, Snapshot, TYPES,
};
use credence_risk_core::U256;
use serde_json::Value;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn vectors() -> Value {
    let p = repo().join("calibration/docs/sigma-vectors.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

fn f(v: &Value) -> f64 {
    v.as_str().unwrap().parse().unwrap()
}

fn w(v: &Value) -> U256 {
    v.as_str().unwrap().parse().unwrap()
}

fn date(v: &Value) -> NaiveDate {
    v.as_str().unwrap().parse().unwrap()
}

#[test]
fn constants_match_the_spec() {
    let v = vectors();
    assert_eq!(v["spec"], "calibration/docs/sigma.md");
    assert_eq!(f(&v["constants"]["lambda"]), credence_keeper::sigma::LAM);
    assert_eq!(f(&v["constants"]["w"]), credence_keeper::sigma::W);
}

#[test]
fn gap_return_is_bit_exact() {
    let v = vectors();
    let cases = v["gapReturn"].as_array().unwrap();
    assert!(!cases.is_empty());
    for c in cases {
        let r = gap_return(
            f(&c["prevClose"]),
            f(&c["open"]),
            f(&c["split"]),
            f(&c["dividend"]),
        );
        assert_eq!(r.to_bits(), f(&c["r"]).to_bits(), "{c}");
    }
}

#[test]
fn classify_matches() {
    let v = vectors();
    for c in v["classify"].as_array().unwrap() {
        let t = classify(date(&c["prevSession"]), date(&c["session"])).unwrap();
        assert_eq!(t as u64, c["closureType"].as_u64().unwrap(), "{c}");
    }
}

#[test]
fn keeper_resume_k1_to_k3_is_bit_exact() {
    let v = vectors();
    let cases = v["keeperResume"].as_array().unwrap();
    assert_eq!(cases.len(), 3);
    for case in cases {
        let mut s = SigmaState {
            v: [
                f(&case["v0"]["1"]),
                f(&case["v0"]["2"]),
                f(&case["v0"]["3"]),
            ],
            rho2: [f(&case["rho2"]["2"]), f(&case["rho2"]["3"])],
        };
        let steps = case["steps"].as_array().unwrap();
        assert_eq!(steps.len(), 40);
        for (i, step) in steps.iter().enumerate() {
            s.apply(step["type"].as_u64().unwrap() as u8, f(&step["r"]));
            for t in TYPES {
                let k = t.to_string();
                assert_eq!(
                    s.v[t as usize - 1].to_bits(),
                    f(&step["v"][&k]).to_bits(),
                    "{} step {} v[{t}]",
                    case["id"],
                    i + 1
                );
                assert_eq!(
                    s.model_wad(t),
                    w(&step["sigmaWad"][&k]),
                    "{} step {} σ[{t}]",
                    case["id"],
                    i + 1
                );
            }
        }
    }
}

#[test]
fn publish_rule_matches() {
    let v = vectors();
    for c in v["publish"].as_array().unwrap() {
        let got = submit_wad(
            w(&c["modelWad"]),
            w(&c["floorWad"]),
            w(&c["currentWad"]),
            c["days"].as_u64().unwrap(),
        )
        .unwrap();
        assert_eq!(got, w(&c["submitWad"]), "{c}");
    }
}

/// The resume snapshot is self-consistent: its floored σ at `asOf` is `max(toWad(σ(v)), floor)`.
#[test]
fn snapshot_resumes_to_its_own_sigma() {
    let snap =
        Snapshot::load(&repo().join("calibration/out/sigma/sigma-ea391d6a1d0303cd.json")).unwrap();
    assert_eq!(snap.data_grade, "free-2016");
    assert_eq!(snap.assets.len(), 8); // the testnet six (+ GOOGL, AMZN since cb15c51) and COIN, SPY
    for a in &snap.assets {
        for t in TYPES {
            let i = t as usize - 1;
            assert_eq!(
                a.state.model_wad(t).max(a.floor_wad[i]),
                a.seed_wad[i],
                "{} type {t}",
                a.symbol
            );
            // Seeding a fresh engine (current = 0) submits exactly the snapshot σ.
            assert_eq!(a.submit(t, U256::ZERO, 0).unwrap(), a.seed_wad[i]);
        }
    }
}

/// Resuming ignores gaps inside the snapshot, applies later ones in session order, and matches a
/// direct replay of the same steps.
#[test]
fn resume_applies_only_gaps_after_as_of_in_order() {
    let snap =
        Snapshot::load(&repo().join("calibration/out/sigma/sigma-ea391d6a1d0303cd.json")).unwrap();
    let base: AssetSigma = snap
        .assets
        .iter()
        .find(|a| a.symbol == "NVDA")
        .unwrap()
        .clone();
    let d = |s: &str| s.parse::<NaiveDate>().unwrap();
    let gaps = vec![
        Gap {
            session: d("2026-09-30"),
            closure_type: 1,
            r: -0.004,
        },
        Gap {
            session: d("2026-09-25"),
            closure_type: 1,
            r: 0.5,
        }, // already in the snapshot
        Gap {
            session: d("2026-09-28"),
            closure_type: 2,
            r: 0.012,
        },
        Gap {
            session: d("2026-09-29"),
            closure_type: 1,
            r: 0.021,
        },
    ];
    let mut a = base.clone();
    assert_eq!(a.resume(&gaps).unwrap(), 3);
    assert_eq!(a.as_of, d("2026-09-30"));
    let mut direct = base.state;
    direct.apply(2, 0.012);
    direct.apply(1, 0.021);
    direct.apply(1, -0.004);
    assert_eq!(a.state, direct);
    // Idempotent: re-running with the same gaps applies nothing.
    assert_eq!(a.resume(&gaps).unwrap(), 0);
    // Two gaps into one session is a data error.
    let mut b = base.clone();
    let dup = vec![gaps[0].clone(), gaps[0].clone()];
    assert!(b.resume(&dup).is_err());
}

/// J7 plan: never below the engine's 10%/day limit or the floor, skips days already published.
#[test]
fn plan_respects_rate_limit_floor_and_idempotency() {
    use credence_keeper::sigma_job::{as_of_day, plan, OnChainSigma};
    let snap =
        Snapshot::load(&repo().join("calibration/out/sigma/sigma-ea391d6a1d0303cd.json")).unwrap();
    let mut a = snap
        .assets
        .iter()
        .find(|a| a.symbol == "TSLA")
        .unwrap()
        .clone();
    let session: NaiveDate = "2026-09-28".parse().unwrap();
    let now = 1_790_640_000u64;
    let high = a.seed_wad[0] * U256::from(3u64); // engine currently far above the model
    let chain = [
        OnChainSigma {
            current: high,
            sigma_at: Some(now - 86_400 - 60),
            last_as_of_day: 0,
        }, // 1 day old
        OnChainSigma {
            current: U256::ZERO,
            sigma_at: None,
            last_as_of_day: 0,
        }, // never set
        OnChainSigma {
            current: a.seed_wad[2],
            sigma_at: Some(now - 3_600),
            last_as_of_day: as_of_day(session),
        }, // done today
    ];
    let gaps = vec![Gap {
        session,
        closure_type: 2,
        r: 0.031,
    }];
    let out = plan(&mut a, &gaps, &chain, session, now, 7).unwrap();
    assert_eq!(out.len(), 2, "type 3 already has today's asOfDay");
    let ov = &out[0];
    assert_eq!(ov.days, 1);
    assert_eq!(
        ov.update.sigma,
        credence_risk_core::sigma_min_allowed(high, 1).unwrap()
    ); // −10% max
    let wk = &out[1];
    assert_eq!(wk.update.sigma, wk.model.max(wk.floor));
    assert_eq!(wk.update.asOfDay, as_of_day(session));
}
