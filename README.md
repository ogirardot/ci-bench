# ci-bench — the CI race

An identical, pinned workload pushed to **GitHub Actions** and **rickub CI**
(Firecracker microVM fleet), raced to answer: who starts jobs faster, whose
steps run faster, and what the runner hardware itself is worth?

Everything here is bash + python3 stdlib. No package installs, no external
services beyond the two CI platforms themselves.

## Layout

    .github/workflows/bench.yml    GitHub side of the race
    .rickub/workflows/bench.yml    rickub side (same steps, same order)
    workloads/rust-build/          pinned Cargo project (cold/warm/test)
    workloads/docker-build/        digest-pinned multi-stage Dockerfile
    workloads/probe/probe.sh       runner capability probe (cpu/disk/fs)
    scripts/emit_timing.sh         sourced by steps; one JSON line per step
    scripts/collect.sh             results.jsonl -> results/<platform>/<run>.json
    scripts/compare.py             median/p95 table per step per platform
    Makefile                       bootstrap / run-local / collect / compare

Why two workflow files and not one: rickub reads `.rickub/workflows/` as its
SOLE workflow source when that directory exists and ignores
`.github/workflows/` entirely, while GitHub only ever reads `.github/`. One
repo therefore carries one file per platform and neither platform sees the
other's copy. The two files run the same steps in the same order; the only
differences are `BENCH_PLATFORM`, `runs-on:` (see *Known asymmetries*), and
comments.

## The workload (identical on both platforms)

| step            | what it does                                                             |
|-----------------|--------------------------------------------------------------------------|
| `job-start`     | zero-duration marker emitted by the first step after checkout             |
| `rust-cold-build` | `rm -rf target && cargo build` — full crate download + compile          |
| `rust-warm-build` | immediate second `cargo build` — incremental no-op rebuild             |
| `rust-test`     | `cargo test` (5 real tests) over the warm build                           |
| `docker-build`  | multi-stage `docker build` (alpine:3.20 pinned by digest) + `docker run` |
| `probe-*`       | cpu loop, 2 GiB sequential write/read to `$RUNNER_TEMP`, fs type + free  |

Pins: Rust toolchain 1.85.0 (`workloads/rust-build/rust-toolchain.toml`), the
full dependency tree (`workloads/rust-build/Cargo.lock`, generated offline
against a real cargo registry cache, versions exact-pinned in `Cargo.toml`
with `=`), Docker base `alpine:3.20@sha256:d9e853e87e...` (the digest rickub
itself pins for its CI images). The workload is not bit-frozen against
`apk`/crates.io mirrors moving — see *Variance pitfalls*.

### Cold vs warm — definitions

Both platforms give every job a **fresh machine** (GitHub hosted runners;
rickub boots a new Firecracker microVM with a read-only rootfs and a fresh
scratch disk). Therefore:

- **cold** = the FIRST `cargo build` in a job: crates.io fetch + full compile
  of the transitive tree. Never accelerated by any cache (there is no
  `actions/cache` and no cargo cache persistence — on purpose).
- **warm** = the SECOND `cargo build` in the SAME job: `target/` exists, the
  no-op incremental path (metadata checks + link of nothing).
- Docker build is always cold (no image cache survives the machine).
- A "cold docker" vs "warm docker" axis would need an in-job second build of
  the same Dockerfile; not in scope for v1.

## Metrics — exact clock boundaries

All records are JSON lines in `results.jsonl`:

    {"step": "...", "platform": "...", "run_id": "...",
     "start": "2026-09-11T12:34:56.789Z", "end": "2026-09-11T12:35:40.123Z",
     "status": "ok|fail|skipped", "duration_ms": 43334,
     "value": <optional measurement>, "unit": "...", "reason": "..."}

`start`/`end` are guest wall clock, UTC, millisecond precision (GNU `date
%3N`; python3 fallback on BSD; whole-second last resort — the fallback in use
is visible in the timestamps themselves: `.000Z` means coarse).

1. **push→job-start** = `start` of the `job-start` record − **push timestamp
   from the platform API** (not from the guest).
   - GitHub: `gh api repos/:o/:r/actions/runs/<run_id>` → `created_at`
     (when the push event was accepted server-side). Alternative, fully
     server-side cross-check: `run_started_at − created_at` (queue +
     provisioning, no guest clock involved).
   - rickub: the run's created/queued timestamp from its CI API for the same
     commit.
   - CAVEAT: this metric subtracts a **server-side** timestamp from a
     **guest-side** timestamp. Guest clock skew shifts both platforms' numbers
     unpredictably (NTP inside a just-booted microVM can be off by seconds).
     Treat it as indicative; prefer the server-side-only variant above when
     the two disagree, and record both when possible.
2. **per-step duration** = `end − start` of the step's record, from the same
   guest clock, so skew cancels. Millisecond precision.
3. **end-to-end pipeline time** (two views):
   - job execution = last record's `end` − `job-start` record's `start`;
   - run wall clock = last record's `end` − push timestamp (carries the same
     cross-clock caveat as metric 1).
4. **cold vs warm cache** = `rust-cold-build` vs `rust-warm-build` durations
   as defined above.
5. **disk-write throughput** = `probe-write` value (MB/s, 2 GiB `dd
   bs=1M count=2048` to the job scratch dir, then removed); `probe-read` is
   the same file read back (warm page cache — still comparable across
   platforms); `probe-cpu` is shell-loop kops/s; `probe-fs-type`/`probe-fs-free`
   describe the filesystem the runner gave the job.

Anything unavailable degrades to `"value": null` or a `skipped` record; the
job itself never fails from the probe, and absent docker skips
`docker-build` with a recorded reason.

## Running the race

### One round

1. Push the same commit to both remotes (e.g. an empty commit:
   `git commit --allow-empty -m "bench round N"`; or use
   `workflow_dispatch` on both — but record the dispatch time as the "push"
   timestamp then).
2. When both runs finish, download `results.jsonl` from each:
   - GitHub: `gh run download <run-id> -n bench-results` (or the run page);
   - rickub: the run's artifacts panel.
3. Collect:
   ```
   scripts/collect.sh github  <run-id> /path/to/github-results/results.jsonl
   scripts/collect.sh rickub <run-id> /path/to/rickub-results/results.jsonl
   ```
4. Record the push timestamps (server-side, per platform API) into a
   `push-times.json` map `"github/<run-id>": "<iso>"` if you want the
   push→job-start row.

### Interleaving (mandatory)

Run rounds **alternating platforms** — G, R, G, R, … — at least **10 rounds
per platform**, serialized (never two benchmark runs in flight at once: on
rickub your own queued job would inflate the other platform's queue metric).
Cloud CI variance across hours and neighbours is well documented; a single
run is noise. Alternation decorrelates the two platforms from time-of-day
effects (fleet load, mirror warmth, co-tenants). Optionally discard round 1
per platform as image/toolchain warmup for the *operators*, not the runners.

### Reporting

```
python3 scripts/compare.py [--push-times push-times.json]
```

Median (p50) and p95 per step per platform, linear-interpolated percentiles
(the numpy method) over `ok` records only; `skipped`/`fail` counts are shown
next to each cell so a platform quietly skipping docker is visible. The
table prints n per cell — do not compare anything with n < 10.

### Local smoke run

`make run-local` executes the same step sequence on your machine (macOS
works: the emitter falls back to python3 for millisecond timestamps and the
probe degrades gracefully). Collect with
`make collect PLATFORM=local RUN_ID=<id> SRC=results.jsonl`.

## Known variance pitfalls

- **Cross-clock subtraction** (push→job-start): server vs guest clock skew;
  prefer server-side-only `run_started_at − created_at` as cross-check.
- **Queue contamination**: rickub queues runs; benchmark rounds must be
  serialized or you measure your own backlog. Same for GitHub concurrency
  groups (none set here, on purpose).
- **Runner placement**: GitHub assigns runners across regions/hosts;
  crates.io and the Alpine mirror are at different RTTs from each placement.
  Only medians over many rounds are meaningful.
- **Floating package indexes**: `apk add build-base` in the docker workload
  floats with the mirror; crate downloads float with crates.io. A changed
  upstream version shifts a cold build by minutes. If a round's cold build
  moves >2x the running median, check upstream before believing it.
- **Toolchain download**: 1.85.0 is rustup-installed at job start on both
  platforms (inside the timed cold-build step? No — rustup resolves it when
  `cargo` first runs, so it IS inside the cold-build timing; identical on
  both platforms by construction).
- **Warm build is nearly zero**: it measures scheduler/link noise; treat p95,
  not median, as the signal.
- **probe-read is page-cache warm** by design (comparable, not absolute).
- **vCPU asymmetry**: rickub `large` = 4 vCPU / 8 GiB vs GitHub ubuntu-latest
  4 vCPU / 16 GiB. See below.

## Known asymmetries (decisions to revisit)

1. **Runner class**: the rickub workflow uses `runs-on: large` for vCPU parity
   with GitHub's ubuntu-latest. `ubuntu-latest` on rickub (2 vCPU / 4 GiB) is
   the "as-consumed, 1x minutes" alternative. This is a user decision.
2. **Where the repo lives**: needs one GitHub repo and one rickub repo (or the
   same repo mirrored to both forges). Not created by this scaffold — no
   network was touched.
3. **push-times.json**: the push timestamp per run is currently recorded by
   the operator from each platform's API; automating it needs API tokens on
   both sides.

## Degrade behaviour

| missing thing | behaviour                                            |
|---------------|------------------------------------------------------|
| docker        | `docker-build` step records `skipped` with reason    |
| cargo         | (local runs) rust steps record `skipped`             |
| GNU date      | python3 millis fallback, then whole-second `.000Z`   |
| dd / stat / df| probe records `null` values, job stays green         |
| python3       | emitter falls back to whole-second timestamps        |

## Real-world tier (added round 12+)

Alongside the synthetic micro-workloads, the bench builds four notorious OSS
projects at pinned tags, cloned/downloaded inside the timed window:

| step | project | pin | toolchain |
|---|---|---|---|
| `rust-ripgrep` | BurntSushi/ripgrep | 15.2.0 | cargo |
| `cpp-sqlite` | SQLite amalgamation | 3.45.1 (sqlite.org 2024 tarball) | gcc/make |
| `node-typescript` | microsoft/TypeScript | v5.9.3 (5.x line — 7.x is the Go rewrite) | node/npm |
| `java-guava` | google/guava | v33.7.1 | maven |

ClickHouse is deliberately absent: a full build needs dozens of cores and
~100 GB of disk, which no shared-runner tier (ours or GitHub's) provides — a
ClickHouse-scale tier needs a dedicated runner class, not a benchmark step.
SQLite's amalgamation is the C/C++ stand-in: a real configure+make of one of
the most deployed codebases on earth, reproducible from a pinned tarball.
