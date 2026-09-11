//! Integration tests: real work over the warm build, so `cargo test` is a
//! meaningful, separately-timed step (not a no-op).

use bench_rust_build::{drive, interesting, make_item, run_round, Config};

fn small() -> Config {
    Config {
        items: 200,
        rounds: 2,
    }
}

#[test]
fn labels_match_the_documented_pattern() {
    assert!(interesting("cold-cache-0001"));
    assert!(interesting("warm-boot-9999"));
    assert!(!interesting("hot-cache-0001"));
    assert!(!interesting("cold-cache-1"));
    assert!(!interesting(""));
}

#[test]
fn items_round_trip_through_json() {
    let item = make_item(3, 42);
    let json = serde_json::to_string(&item).unwrap();
    let back: bench_rust_build::Item = serde_json::from_str(&json).unwrap();
    assert_eq!(item, back);
}

#[test]
fn a_round_selects_exactly_the_cold_items() {
    // items are alternating cold-cache/warm-boot, all matching the pattern;
    // "selected" counts matches, so every item is selected.
    let cfg = small();
    let selected = run_round(&cfg, 0).unwrap();
    assert_eq!(selected, cfg.items as usize);
}

#[tokio::test]
async fn the_tokio_runtime_drives_all_rounds() {
    let cfg = small();
    let selected = drive(cfg.clone()).await.unwrap();
    assert_eq!(selected, cfg.items as usize * cfg.rounds as usize);
}

#[test]
fn config_defaults_are_sane() {
    let cfg = Config::default();
    assert!(cfg.items > 0);
    assert!(cfg.rounds > 0);
}
