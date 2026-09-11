//! Thin CLI wrapper so the workload is runnable as a binary, not just a lib.

use clap::Parser;

use bench_rust_build::{run, Config};

fn main() -> anyhow::Result<()> {
    let cfg = Config::parse();
    let selected = run(cfg.clone())?;
    println!(
        "items/round={} rounds={} selected={}",
        cfg.items, cfg.rounds, selected
    );
    Ok(())
}
