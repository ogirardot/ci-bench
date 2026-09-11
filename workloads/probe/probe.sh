#!/usr/bin/env bash
# probe.sh — deterministic runner-capability probe. Every measurement degrades
# to a "null" value (still a recorded line) when a tool is missing; the job
# NEVER fails from the probe itself.
#
# Measurements:
#   probe-cpu       single-core shell-arithmetic loop throughput (kops/s over a
#                   fixed 1,000,000-iteration loop)
#   probe-write     sequential write throughput (dd 2 GiB to the job scratch
#                   dir, then removed)
#   probe-read      sequential read throughput of that same file
#   probe-fs-type   filesystem type of the scratch dir
#   probe-fs-free   free space of the scratch dir (MB)
#
# Usage: run from the repo root (the scripts/ dir next to workloads/):
#   bash workloads/probe/probe.sh

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/emit_timing.sh"

# Scratch dir: the runner's temp when we have one, else mktemp -d.
PROBE_DIR=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
mkdir -p "$PROBE_DIR" 2>/dev/null || PROBE_DIR=$(mktemp -d)
PROBE_BIN=$PROBE_DIR/probe.bin

now_s() { # fractional seconds, best available clock
    local t
    t=$(date -u +%s.%N 2>/dev/null || true)
    case $t in
        *N) t=$(python3 -c 'import time; print(f"{time.time():.6f}")' 2>/dev/null || echo '') ;;
    esac
    [ -n "$t" ] || t=$(date +%s).000
    printf '%s\n' "$t"
}

probe_cpu() {
    if ! command -v python3 >/dev/null 2>&1 && ! command -v bc >/dev/null 2>&1; then
        bench_metric probe-cpu null kops_per_s   # no fractional clock available
        return 0
    fi
    local iters=1000000 t0 t1 elapsed
    t0=$(now_s)
    local i=0
    while [ "$i" -lt "$iters" ]; do
        i=$((i + 1))
    done
    t1=$(now_s)
    if command -v python3 >/dev/null 2>&1; then
        elapsed=$(python3 -c "print(f'{$t1 - $t0:.6f}')")
    else
        elapsed=$(echo "$t1 - $t0" | bc -l)
    fi
    bench_metric probe-cpu "$(python3 -c "print(f'{$iters / $elapsed / 1000:.2f}')" 2>/dev/null \
        || echo "$iters $elapsed" | awk '{printf "%.2f", $1 / $2 / 1000}')" kops_per_s
}

# Parse the "bytes ... copied/transferred in N s" line dd writes to stderr.
# GNU: "X bytes (...) copied, 3.123 s, ...". BSD: "X bytes transferred in
# 3.123456 secs". Prints "BYTES SECONDS" on stdout, nothing when unmatched.
# ERE (-E) because BSD sed has no BRE alternation.
parse_dd() {
    sed -nE 's/^([0-9]+) bytes.*[ ,] ?([0-9.]+) s.*/\1 \2/p'
}

probe_write() {
    command -v dd >/dev/null 2>&1 || { bench_metric probe-write null MB_per_s; return 0; }
    local out
    out=$(dd if=/dev/zero of="$PROBE_BIN" bs=1M count=2048 2>&1) || true
    local parsed
    parsed=$(printf '%s\n' "$out" | parse_dd)
    if [ -z "$parsed" ]; then
        bench_metric probe-write null MB_per_s
        return 0
    fi
    set -- $parsed
    bench_metric probe-write "$(awk -v b="$1" -v s="$2" 'BEGIN { printf "%.1f", b / s / 1000000 }')" MB_per_s
}

probe_read() {
    if [ ! -f "$PROBE_BIN" ]; then
        bench_metric probe-read null MB_per_s   # write probe never produced it
        return 0
    fi
    command -v dd >/dev/null 2>&1 || { bench_metric probe-read null MB_per_s; return 0; }
    # Drop the page cache when we can (best effort, usually not permitted);
    # otherwise this measures warm cache — still comparable across platforms.
    sync 2>/dev/null || true
    local out
    out=$(dd if="$PROBE_BIN" of=/dev/null bs=1M 2>&1) || true
    local parsed
    parsed=$(printf '%s\n' "$out" | parse_dd)
    if [ -z "$parsed" ]; then
        bench_metric probe-read null MB_per_s
        return 0
    fi
    set -- $parsed
    bench_metric probe-read "$(awk -v b="$1" -v s="$2" 'BEGIN { printf "%.1f", b / s / 1000000 }')" MB_per_s
}

probe_fs() {
    # Filesystem type: GNU stat -f -c %T, BSD stat -f %T, else null.
    local fstype=null
    if stat -f -c %T "$PROBE_DIR" >/dev/null 2>&1; then
        fstype='"'$(stat -f -c %T "$PROBE_DIR" 2>/dev/null)'"'
    elif stat -f %T "$PROBE_DIR" >/dev/null 2>&1; then
        fstype='"'$(stat -f %T "$PROBE_DIR" 2>/dev/null | tr -d '"')'"'
    fi
    bench_metric probe-fs-type "$fstype" fstype

    # Free space in MB via df -k (POSIX), else null.
    if command -v df >/dev/null 2>&1; then
        local free_kb
        free_kb=$(df -Pk "$PROBE_DIR" 2>/dev/null | awk 'NR==2 {print $4}') || free_kb=''
        case $free_kb in
            ''|*[!0-9]*) bench_metric probe-fs-free null MB ;;
            *) bench_metric probe-fs-free "$((free_kb / 1024))" MB ;;
        esac
    else
        bench_metric probe-fs-free null MB
    fi
}

probe_cpu
probe_write
probe_read
rm -f "$PROBE_BIN" 2>/dev/null || true
probe_fs

exit 0
