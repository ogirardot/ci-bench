#!/usr/bin/env bash
# emit_timing.sh — sourced by every benchmark step (CI and local).
#
# Emits ONE JSON line per step to $GITHUB_WORKSPACE/results.jsonl (falling back
# to ./results.jsonl). Schema:
#   {"step": <name>, "platform": <github|rickub|local>, "run_id": <id>,
#    "start": <iso8601>, "end": <iso8601>, "status": <ok|fail|skipped>,
#    "duration_ms": <int>,                       # convenience, = end - start
#    "value": <json>, "unit": <string>, "reason": <string>}   # optional extras
#
# Public API:
#   bench_step  STEP CMD [ARGS...]   run CMD, record ok/fail (compound bodies:
#                                    bench_step x bash -c '...; ...')
#   bench_skip  STEP REASON          record a skipped step (e.g. no docker)
#   bench_metric STEP VALUE UNIT     record a measurement now (value is raw JSON:
#                                    number, "string", or null)
#   bench_mark  STEP                 zero-duration marker (e.g. job-start)
#
# Determined at source time (env overrides win):
#   BENCH_PLATFORM  github | rickub | local      (default: inferred)
#   BENCH_RUN_ID    stable identifier for the whole run (default: GITHUB_RUN_ID,
#                   else local-<utcstamp>-<pid>)
#
# This file sets NO shell options on purpose: it is sourced into the caller's
# shell and must not change its behaviour.

# --- clock helpers -----------------------------------------------------------
# Prefer GNU date's %N (all Linux CI guests); BSD date (macOS) prints a literal
# "N" which the regex rejects; then python3; then whole-second granularity.
_bench_now_iso() {
    local t
    t=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || true)
    # A valid timestamp contains no "N"; BSD date prints a literal one for %3N.
    case $t in
        *N*) ;; # %3N unsupported (BSD date) — fall through
        *) printf '%s\n' "$t"; return 0 ;;
    esac
    t=$(python3 -c 'import datetime
print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z")' 2>/dev/null || true)
    case $t in
        2[0-9][0-9][0-9]-*) printf '%s\n' "$t"; return 0 ;;
    esac
    date -u +%Y-%m-%dT%H:%M:%S.000Z
}

_bench_iso_to_ms() { # ISO (above format) -> epoch ms; python3 when available
    python3 - "$1" <<'PY' 2>/dev/null || printf '%s\n' "$(_bench_iso_to_ms_shell "$1")"
import sys, datetime
s = sys.argv[1]
print(int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc).timestamp() * 1000))
PY
}

_bench_iso_to_ms_shell() { # fallback: second granularity (documented coarser)
    local s=${1%%.*}
    date -u -j -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null \
        || date -u -d "$s" +%s 2>/dev/null \
        || printf '0\n'
}

# --- identity ----------------------------------------------------------------
_bench_platform() {
    if [ -n "${BENCH_PLATFORM:-}" ]; then
        printf '%s\n' "$BENCH_PLATFORM"
    elif [ -n "${GITHUB_SERVER_URL:-}" ]; then
        case $GITHUB_SERVER_URL in
            *github.com*) printf 'github\n' ;;
            *)            printf 'rickub\n' ;;
        esac
    else
        printf 'local\n'
    fi
}

_bench_run_id() {
    if [ -n "${BENCH_RUN_ID:-}" ]; then printf '%s\n' "$BENCH_RUN_ID"
    elif [ -n "${GITHUB_RUN_ID:-}" ]; then
        printf '%s-attempt%s\n' "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT:-1}"
    else
        printf 'local-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
    fi
}

# --- record emission ---------------------------------------------------------
_bench_results_file() {
    local dir=${GITHUB_WORKSPACE:-$PWD}
    printf '%s/results.jsonl\n' "$dir"
}

_bench_esc() { # minimal JSON string escaping (control chars flattened)
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

# _bench_emit STEP STATUS START END [VALUE UNIT REASON]
_bench_emit() {
    local step=$1 status=$2 start=$3 end=$4 value=${5-} unit=${6-} reason=${7-}
    local line f dur_ms
    f=$(_bench_results_file)
    dur_ms=$(( $(_bench_iso_to_ms "$end") - $(_bench_iso_to_ms "$start") ))
    [ "$dur_ms" -lt 0 ] && dur_ms=0
    line='{"step": "'$(_bench_esc "$step")'"'
    line+=', "platform": "'$(_bench_esc "$(_bench_platform)")'"'
    line+=', "run_id": "'$(_bench_esc "$(_bench_run_id)")'"'
    line+=', "start": "'$(_bench_esc "$start")'"'
    line+=', "end": "'$(_bench_esc "$end")'"'
    line+=', "status": "'$(_bench_esc "$status")'"'
    line+=', "duration_ms": '"$dur_ms"
    [ -n "$value" ] && line+=', "value": '"$value"
    [ -n "$unit" ] && line+=', "unit": "'$(_bench_esc "$unit")'"'
    [ -n "$reason" ] && line+=', "reason": "'$(_bench_esc "$reason")'"'
    line+='}'
    printf '%s\n' "$line" >>"$f"
}

# --- public API --------------------------------------------------------------
bench_step() { # STEP CMD [ARGS...]
    # Records ok/fail AND propagates the command's exit code, so a failed
    # workload fails the CI step (not silently recorded as a red data point).
    local step=$1; shift
    local start end status rc
    start=$(_bench_now_iso)
    rc=0
    "$@" || rc=$?
    [ "$rc" -eq 0 ] && status=ok || status=fail
    end=$(_bench_now_iso)
    _bench_emit "$step" "$status" "$start" "$end"
    return "$rc"
}

bench_skip() { # STEP REASON
    local now=$(_bench_now_iso)
    _bench_emit "$1" skipped "$now" "$now" '' '' "$2"
}

bench_metric() { # STEP VALUE UNIT   (VALUE is raw JSON: 123, "ext4", null)
    local now=$(_bench_now_iso)
    _bench_emit "$1" ok "$now" "$now" "$2" "$3"
}

bench_mark() { # STEP
    local now=$(_bench_now_iso)
    _bench_emit "$1" ok "$now" "$now"
}
