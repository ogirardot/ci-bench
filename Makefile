# ci-bench — cross-platform CI race benchmark (rickub CI vs GitHub Actions).
# bash + python3(stdlib) only; everything degrades gracefully.

SHELL := /usr/bin/env bash

PLATFORM ?= local
RUN_ID   ?= local-$(shell date -u +%Y%m%dT%H%M%SZ)

.PHONY: bootstrap run-local collect compare clean

## bootstrap — make scripts executable and create results/ (safe to re-run)
bootstrap:
	chmod +x scripts/*.sh workloads/probe/probe.sh
	mkdir -p results

## run-local — run the benchmark step sequence on THIS machine (smoke-test /
## local baseline). Emits ./results.jsonl, mirroring the CI step order.
run-local: bootstrap
	rm -f results.jsonl
	set -euo pipefail; \
	export BENCH_RUN_ID="$(RUN_ID)"; \
	source scripts/emit_timing.sh; \
	bench_mark job-start; \
	if command -v cargo >/dev/null 2>&1; then \
	  bench_step rust-cold-build bash -ec \
	    'rm -rf workloads/rust-build/target && cargo build --manifest-path workloads/rust-build/Cargo.toml'; \
	  bench_step rust-warm-build cargo build --manifest-path workloads/rust-build/Cargo.toml; \
	  bench_step rust-test cargo test --manifest-path workloads/rust-build/Cargo.toml; \
	else \
	  bench_skip rust-cold-build "cargo not found"; \
	  bench_skip rust-warm-build "cargo not found"; \
	  bench_skip rust-test "cargo not found"; \
	fi; \
	if command -v docker >/dev/null 2>&1; then \
	  bench_step docker-build bash -ec \
	    'docker build -t ci-bench:docker workloads/docker-build && docker run --rm ci-bench:docker'; \
	else \
	  bench_skip docker-build "docker not found"; \
	fi; \
	bash workloads/probe/probe.sh; \
	cat results.jsonl

## collect — fold a results.jsonl into the results tree:
##   make collect PLATFORM=github RUN_ID=<id> SRC=/path/to/results.jsonl
collect:
	@test -n "$(SRC)" || { echo "usage: make collect PLATFORM=<p> RUN_ID=<id> SRC=<results.jsonl>"; exit 2; }
	scripts/collect.sh "$(PLATFORM)" "$(RUN_ID)" "$(SRC)"

## compare — median/p95 table from everything collected so far
compare:
	python3 scripts/compare.py

## clean — drop local run outputs (not the collected results/ tree)
clean:
	rm -f results.jsonl
	rm -rf workloads/rust-build/target
