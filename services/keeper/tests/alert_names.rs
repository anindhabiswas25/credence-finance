//! Every keeper / relayer metric that an alert rule or a dashboard queries is one the service registers.
//! `credence-common`'s registry prefixes every name with `credence_`; the S2–S4 rules queried the bare
//! `keeper_…` / `relayer_…` names, so no keeper or relayer alert could fire (found in the S4 scenario run).
use std::collections::BTreeSet;

const METRICS: &[(&str, &str)] = &[
    ("keeper", include_str!("../src/metrics.rs")),
    ("relayer", include_str!("../../relayer/src/metrics.rs")),
];

fn queried(text: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let b = text.as_bytes();
    for svc in ["keeper", "relayer"] {
        let pat = format!("credence_{svc}_");
        let mut i = 0;
        while let Some(off) = text[i..].find(&pat) {
            let s = i + off;
            let mut e = s + pat.len();
            while e < b.len()
                && (b[e].is_ascii_lowercase() || b[e].is_ascii_digit() || b[e] == b'_')
            {
                e += 1;
            }
            out.insert(text[s..e].to_owned());
            i = e;
        }
    }
    out
}

/// The name as registered (without the `credence_` prefix), and without the series suffixes Prometheus adds.
fn registered(name: &str) -> String {
    let n = name.trim_start_matches("credence_");
    for suf in ["_bucket", "_count", "_sum"] {
        if let Some(x) = n.strip_suffix(suf) {
            return x.to_owned();
        }
    }
    n.to_owned()
}

#[test]
fn rules_and_dashboards_query_registered_names() {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../infra");
    let mut files = vec![format!("{root}/prometheus/alerts.yml")];
    for e in std::fs::read_dir(format!("{root}/grafana/dashboards")).unwrap() {
        files.push(e.unwrap().path().display().to_string());
    }
    let mut missing = Vec::new();
    for f in &files {
        let text = std::fs::read_to_string(f).unwrap();
        for name in queried(&text) {
            let reg = registered(&name);
            let svc = if reg.starts_with("keeper_") {
                "keeper"
            } else {
                "relayer"
            };
            let src = METRICS.iter().find(|(s, _)| *s == svc).unwrap().1;
            if !src.contains(&format!("\"{reg}\"")) {
                missing.push(format!("{f}: {name}"));
            }
        }
        // a bare name (no `credence_` prefix) never matches an exported series
        for svc in ["keeper", "relayer"] {
            for (i, _) in text.match_indices(&format!("{svc}_")) {
                let before = &text[..i];
                assert!(
                    before.ends_with("credence_")
                        || !before.ends_with(|c: char| !c.is_ascii_alphanumeric()
                            && c != '_'
                            && c != '-'),
                    "{f}: bare {svc}_ metric name at byte {i}"
                );
            }
        }
    }
    assert!(
        missing.is_empty(),
        "queried but not registered: {missing:#?}"
    );
}
