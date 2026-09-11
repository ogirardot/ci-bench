//! bench-rust-build: the workload behind the ci-bench "rust build" steps.
//!
//! It deliberately touches every pinned dependency (serde + serde_json, tokio,
//! clap, regex, anyhow) so a cold `cargo build` actually compiles the full
//! transitive tree, and `cargo test` does real work on top of the warm build.

use anyhow::Result;
use clap::Parser;
use serde::{Deserialize, Serialize};

/// Tunable workload parameters (parsing exercises clap's derive machinery).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
#[command(name = "bench-rust-build", about = "ci-bench synthetic workload")]
pub struct Config {
    /// Number of synthetic work items per round.
    #[arg(long, default_value_t = 5000)]
    pub items: u32,

    /// Rounds to run.
    #[arg(long, default_value_t = 4)]
    pub rounds: u32,
}

impl Default for Config {
    fn default() -> Self {
        Self::parse_from(["bench-rust-build"])
    }
}

/// A synthetic work item; JSON round-tripping exercises serde on a non-trivial
/// type (string + vec + float + u64).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: u64,
    pub label: String,
    pub tags: Vec<String>,
    pub score: f64,
}

/// The label pattern that marks an item "interesting" (exercises regex).
pub const LABEL_PATTERN: &str = r"^(cold|warm)-(cache|boot)-[0-9]{4}$";

/// Matches labels against [`LABEL_PATTERN`].
pub fn interesting(label: &str) -> bool {
    // Compiled per call on purpose: the regex crate's compile path is part of
    // the exercised cost, and the workload is small enough that it stays cheap.
    let re = regex::Regex::new(LABEL_PATTERN).expect("static pattern compiles");
    re.is_match(label)
}

/// Builds one synthetic item.
pub fn make_item(round: u32, i: u32) -> Item {
    let kind = if i % 2 == 0 { "cold-cache" } else { "warm-boot" };
    Item {
        id: (u64::from(round) << 32) | u64::from(i),
        label: format!("{kind}-{:04}", i % 10_000),
        tags: vec!["bench".to_string(), "ci-race".to_string()],
        score: f64::from(i) * 0.5,
    }
}

/// One round of synthetic work: build items, JSON round-trip each, select on a
/// regex. Returns the number of selected items.
pub fn run_round(cfg: &Config, round: u32) -> Result<usize> {
    let mut selected = 0usize;
    for i in 0..cfg.items {
        let item = make_item(round, i);
        let json = serde_json::to_string(&item)?;
        let back: Item = serde_json::from_str(&json)?;
        debug_assert_eq!(back, item);
        if interesting(&back.label) {
            selected += 1;
        }
    }
    Ok(selected)
}

/// Tokio entry point: rounds on a multi-threaded runtime, briefly yielding
/// between rounds so the scheduler paths are exercised too.
pub async fn drive(cfg: Config) -> Result<usize> {
    let mut total = 0usize;
    for r in 0..cfg.rounds {
        total += run_round(&cfg, r)?;
        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    }
    Ok(total)
}

/// Synchronous entry point for the binary.
pub fn run(cfg: Config) -> Result<usize> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .build()?;
    rt.block_on(drive(cfg))
}
