#!/usr/bin/env python3
"""compare.py — median/p95 table per step per platform, from collected runs.

Reads results/<platform>/<run-id>.json files (produced by scripts/collect.sh).
python3 stdlib only.

Usage:
    scripts/compare.py [--push-times FILE]

Output:
    - per step x platform: n, median, p95 of duration_ms (status ok only;
      "fail"/"skipped" counted separately and shown)
    - for metric-bearing steps (value field: probe-*), median of the value
    - with --push-times: push -> job-start latency per platform, where push
      timestamps come from FILE: {"<platform>/<run-id>": "<iso8601>", ...}
      (see README "push->job-start" for where each timestamp comes from)

Percentiles: linear interpolation between order statistics (the method numpy
percentile uses), reported at p50 (median) and p95.
"""

import argparse
import json
import sys
from pathlib import Path

RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"
JOB_START_STEP = "job-start"
DURATION_UNITS = {"duration_ms": "ms"}


def percentile(sorted_vals, q):
    """Linear-interpolation percentile. sorted_vals non-empty, q in [0,100]."""
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = (len(sorted_vals) - 1) * q / 100.0
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = pos - lo
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * frac


def fmt_ms(v):
    return f"{v / 1000.0:8.2f}s" if v >= 1000 else f"{v:8.0f}ms"


def fmt_v(v):
    if v is None:
        return "    null"
    return f"{v:8.1f}"


def load_platforms():
    platforms = {}
    if not RESULTS_DIR.is_dir():
        return platforms
    for pdir in sorted(RESULTS_DIR.iterdir()):
        if not pdir.is_dir():
            continue
        runs = []
        for rfile in sorted(pdir.glob("*.json")):
            try:
                with open(rfile, encoding="utf-8") as fh:
                    runs.append(json.load(fh))
            except (json.JSONDecodeError, OSError) as exc:
                print(f"compare: skipping unreadable {rfile}: {exc}", file=sys.stderr)
        if runs:
            platforms[pdir.name] = runs
    return platforms


def parse_iso(ts):
    from datetime import datetime, timezone

    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--push-times", metavar="FILE",
                    help="JSON map of '<platform>/<run-id>' -> push ISO timestamp")
    args = ap.parse_args()

    platforms = load_platforms()
    if not platforms:
        print("compare: no collected results under results/ — run scripts/collect.sh first")
        return 1

    # step -> platform -> list of (record); plus counters
    steps = {}
    for platform, runs in platforms.items():
        for run in runs:
            for rec in run:
                step = rec.get("step", "?")
                steps.setdefault(step, {}).setdefault(platform, []).append(rec)

    step_names = sorted(steps)
    plat_names = sorted(platforms)

    header = f"{'step':<22}" + "".join(f"{p:>26}" for p in plat_names)
    sub = f"{'':<22}" + "".join(f"{'n / median / p95':>26}" for p in plat_names)
    print(header)
    print(sub)
    print("-" * len(header))

    for step in step_names:
        row = f"{step:<22}"
        for plat in plat_names:
            recs = steps[step].get(plat, [])
            durs = sorted(r["duration_ms"] for r in recs
                          if r.get("status") == "ok" and isinstance(r.get("duration_ms"), (int, float)))
            n_skipped = sum(1 for r in recs if r.get("status") == "skipped")
            n_fail = sum(1 for r in recs if r.get("status") == "fail")
            cell = f"{len(durs):>3} /"
            if durs:
                cell += f" {fmt_ms(percentile(durs, 50))} / {fmt_ms(percentile(durs, 95))}"
            else:
                cell += "        - /        -"
            if n_skipped:
                cell += f" (+{n_skipped}skip)"
            if n_fail:
                cell += f" (+{n_fail}FAIL)"
            row += f"{cell:>26}"
        print(row)

    # Metric-bearing steps: median of value.
    metric_steps = [s for s in step_names
                    if any("value" in r for recs in steps[s].values() for r in recs)]
    if metric_steps:
        print()
        print(f"{'metric (median value)':<22}" + "".join(f"{p:>26}" for p in plat_names))
        print("-" * len(header))
        for step in metric_steps:
            row = f"{step:<22}"
            unit = ""
            for plat in plat_names:
                recs = [r for r in steps[step].get(plat, []) if "value" in r]
                nums = sorted(r["value"] for r in recs
                              if isinstance(r.get("value"), (int, float)))
                strs = [r["value"] for r in recs if isinstance(r.get("value"), str)]
                if nums:
                    unit = next((r.get("unit", "") for r in recs if r.get("unit")), "")
                    cell = f"{percentile(nums, 50):.1f} {unit}"
                elif strs:
                    # categorical metric (e.g. fs type): show the most common value
                    cell = max(set(strs), key=strs.count)[:16]
                else:
                    cell = "null"
                row += f"{cell:>26}"
            print(row)

    # push -> job-start latency.
    if args.push_times:
        print()
        try:
            with open(args.push_times, encoding="utf-8") as fh:
                push_times = json.load(fh)
        except (json.JSONDecodeError, OSError) as exc:
            print(f"compare: cannot read --push-times: {exc}", file=sys.stderr)
            return 1
        row = f"{'push->job-start':<22}"
        for plat in plat_names:
            lat = []
            for run in platforms[plat]:
                run_id = next((r.get("run_id") for r in run if r.get("run_id")), None)
                key = f"{plat}/{run_id}"
                if key not in push_times:
                    continue
                mark = next((r for r in run if r.get("step") == JOB_START_STEP), None)
                if not mark:
                    continue
                try:
                    delta = (parse_iso(mark["start"]) - parse_iso(push_times[key])).total_seconds() * 1000
                except (ValueError, KeyError):
                    continue
                if delta >= 0:
                    lat.append(delta)
            cell = f"{len(lat):>3} /"
            cell += (f" {fmt_ms(percentile(sorted(lat), 50))} / {fmt_ms(percentile(sorted(lat), 95))}"
                     if lat else "        - /        -")
            row += f"{cell:>26}"
        print(row + "   (cross-clock; see README caveats)")

    print()
    print("durations = emitted end-start per step; percentiles linear-interpolated;")
    print("report n>=10 per platform before trusting any comparison (README: variance).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
