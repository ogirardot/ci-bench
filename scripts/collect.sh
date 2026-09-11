#!/usr/bin/env bash
# collect.sh — gather one run's results.jsonl into the results tree.
#
#   scripts/collect.sh PLATFORM RUN_ID SRC [SRC...]
#
#   PLATFORM  github | rickub | local
#   RUN_ID    the run's identifier (bench run_id / artifact run number)
#   SRC       one or more results.jsonl files (e.g. a downloaded artifact,
#             extracted anywhere; multiple are concatenated in order)
#
# Output: results/<platform>/<run-id>.json — a JSON array of the run's records,
# normalized (blank lines dropped). Refuses to overwrite an existing file: two
# collected runs with the same id are almost certainly a copy/paste mistake.

set -euo pipefail

usage() {
    sed -n '2,12p' "$0" >&2
    exit 2
}

[ $# -ge 3 ] || usage

platform=$1
run_id=$2
shift 2

out="results/$platform/$run_id.json"
if [ -e "$out" ]; then
    echo "collect: refusing to overwrite $out (delete it first if intentional)" >&2
    exit 1
fi

mkdir -p "results/$platform"

# Concatenate the sources, drop blanks, and re-emit as a JSON array via
# python3 (stdlib) so the output is valid JSON even from partial files.
python3 - "$out" "$@" <<'PY'
import json, sys

out_path, sources = sys.argv[1], sys.argv[2:]
records = []
for src in sources:
    with open(src, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # A torn last line (job killed mid-write): keep it out but say so.
                print(f"collect: skipping unparseable line in {src}: {line[:80]!r}", file=sys.stderr)
if not records:
    sys.exit(f"collect: no records found in {sources}")
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(records, fh, indent=1)
    fh.write("\n")
print(f"collect: {len(records)} records -> {out_path}")
PY
