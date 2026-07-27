#!/usr/bin/env bash
# Paired script-vs-binary measurement for macOS and Linux (U6, U13; R38).
# The functional twin of measure.ps1.
#
# Produces the end-to-end fresh-process medians R38 requires before a
# component's scripts are deleted, for the script and the binary, on one host,
# with their runs interleaved.
#
# docs/performance.md §3 governs the method and this file implements it
# literally:
#
#   - One fresh process per probe. The hot cost is process creation, and a warm
#     loop understates it by up to 100x -- production spawns a new interpreter
#     every tick, so the harness must too.
#   - Median of >= 7 runs, with the host and interpreter versions recorded
#     beside the numbers.
#   - Interleaved, because a machine that gets busier halfway through would
#     otherwise charge the whole drift to whichever variant ran second.
#   - Isolated HOME and TMPDIR, so a probe cannot read or write the real profile
#     and cannot race a live session over a shared state file.
#
# Like the capture harness this is a development tool, not a runtime script: it
# fails loudly. A measurement that silently measured nothing is worse than no
# measurement, because the number still looks like evidence.
#
# Usage:
#   tests/harness/measure.sh --component subagent [--runs 11] [--json out.json]

set -uo pipefail

# EPOCHREALTIME is bash 5.0+, and it is the only timestamp source here that
# costs no fork. `date +%s%N` is not portable to macOS and every external timer
# would add its own process-creation cost to the very thing being measured.
if [[ -z ${EPOCHREALTIME:-} ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
        if [[ -x $candidate ]] && "$candidate" -c '[[ ${BASH_VERSINFO[0]} -ge 5 ]]' 2>/dev/null; then
            exec "$candidate" "$0" "$@"
        fi
    done
    echo "measure: needs bash 5+ for a fork-free timer (EPOCHREALTIME)" >&2
    exit 1
fi

# EPOCHREALTIME is formatted with the locale's decimal separator, so a comma
# locale would hand the arithmetic below `1767225600,123456` and the split on
# `.` would silently yield the whole string as seconds and no microseconds.
export LC_ALL=C

HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *)      echo "measure: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac

fail() { echo "measure: $*" >&2; exit 1; }

# The export above is for THIS script's arithmetic and must not reach the
# variants. Under a non-UTF-8 locale bash indexes by byte, so `get_vis` walks
# three elements per bar cell instead of one -- measuring work no user with a
# UTF-8 terminal performs, on the one component whose render loop dominates its
# tick. Both variants get the same locale, so the pair stays fair either way;
# the point is that it is the locale users actually run under.
UTF8_LOCALE=""
for _loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 UTF-8; do
    if LC_ALL="$_loc" "${BASH:-bash}" -c '[[ ${#1} -eq 1 ]]' _ "█" 2>/dev/null; then
        UTF8_LOCALE=$_loc
        break
    fi
done
[[ -n $UTF8_LOCALE ]] || fail "no UTF-8 locale found; the timing would not describe a real tick"
unset _loc

COMPONENT=subagent
RUNS=11
PAYLOAD=""
BINARY=""
JSON_OUT=""
RUNNER_LABEL="${MEASURE_RUNNER:-}"
RUNNER_IMAGE="${MEASURE_IMAGE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --component) COMPONENT="${2:?}"; shift 2 ;;
        --runs)      RUNS="${2:?}"; shift 2 ;;
        --payload)   PAYLOAD="${2:?}"; shift 2 ;;
        --binary)    BINARY="${2:?}"; shift 2 ;;
        --json)      JSON_OUT="${2:?}"; shift 2 ;;
        *)           fail "unknown argument: $1" ;;
    esac
done

[[ $COMPONENT == subagent ]] || fail "unknown component '$COMPONENT'"
(( RUNS >= 7 )) || fail "R38 and docs/performance.md §3 require at least 7 runs; got $RUNS"

SCRIPT="$REPO_ROOT/$PLATFORM/subagent-statusline.sh"
[[ -n $PAYLOAD ]] || PAYLOAD="$REPO_ROOT/tests/harness/payloads/tasks-feed.json"
[[ -n $BINARY ]]  || BINARY="$REPO_ROOT/target/release/claude-statusline"
SUBCOMMAND=subagent
FEED_NAME=statusline-tasks-fixture-session-0001.json

for required in "$SCRIPT" "$PAYLOAD" "$BINARY"; do
    [[ -e $required ]] || fail "missing $required (build the release binary first: cargo build --release)"
done
command -v jq >/dev/null 2>&1 || fail "the script variant needs jq"

# ---------------------------------------------------------------------------
# Isolated roots
# ---------------------------------------------------------------------------

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/statusline-measure-XXXXXX") || fail "cannot create a scratch root"
mkdir -p "$ROOT/home/.claude" "$ROOT/tmp"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

export HOME="$ROOT/home"
export TMPDIR="$ROOT/tmp"
# Both variants pay for debug logging or neither does. Leaving it set from the
# ambient shell would charge one side an extra file append per tick.
unset STATUSLINE_DEBUG

run_script() { LC_ALL="$UTF8_LOCALE" "$SCRIPT" < "$PAYLOAD" >/dev/null 2>&1; }
run_binary() { LC_ALL="$UTF8_LOCALE" "$BINARY" "$SUBCOMMAND" < "$PAYLOAD" >/dev/null 2>&1; }

# Each variant is proven to do its work before anything is timed. A probe that
# silently no-opped -- a missing dependency, a changed payload contract -- would
# otherwise be reported as a spectacular speed-up.
for variant in script binary; do
    rm -f "$TMPDIR/$FEED_NAME"
    "run_$variant"
    [[ -s "$TMPDIR/$FEED_NAME" ]] ||
        fail "the $variant variant wrote no feed -- refusing to report a measurement of nothing"
done

probe() {
    local start end
    start=$EPOCHREALTIME
    "$1"
    end=$EPOCHREALTIME
    # Fixed-point rather than floating point: EPOCHREALTIME is `seconds.micros`
    # and bash has no float arithmetic, so both halves are folded into integer
    # microseconds before subtracting.
    local s_int=${start%.*} s_frac=${start#*.}
    local e_int=${end%.*}   e_frac=${end#*.}
    echo $(( (e_int * 1000000 + 10#$e_frac) - (s_int * 1000000 + 10#$s_frac) ))
}

script_times=()
binary_times=()
for (( i = 0; i < RUNS; i++ )); do
    script_times+=("$(probe run_script)")
    binary_times+=("$(probe run_binary)")
done

median() {
    local sorted n
    mapfile -t sorted < <(printf '%s\n' "$@" | sort -n)
    n=${#sorted[@]}
    if (( n % 2 == 1 )); then
        echo "${sorted[(n - 1) / 2]}"
    else
        echo $(( (sorted[n / 2 - 1] + sorted[n / 2]) / 2 ))
    fi
}
minimum() { printf '%s\n' "$@" | sort -n | head -1; }
maximum() { printf '%s\n' "$@" | sort -n | tail -1; }
ms() { awk -v us="$1" 'BEGIN { printf "%.1f", us / 1000 }'; }

script_median=$(median "${script_times[@]}")
binary_median=$(median "${binary_times[@]}")
delta=$(awk -v a="$script_median" -v b="$binary_median" 'BEGIN { if (a > 0) printf "%.1f", (b - a) / a * 100; else print "0.0" }')

host="$(uname -srm); bash ${BASH_VERSION}; jq $(jq --version 2>/dev/null)"
commit=$(git -C "$REPO_ROOT" rev-parse HEAD)

echo
echo "component:  $COMPONENT"
echo "platform:   $PLATFORM"
echo "host:       $host"
[[ -n $RUNNER_LABEL ]] && echo "runner:     $RUNNER_LABEL"
[[ -n $RUNNER_IMAGE ]] && echo "image:      $RUNNER_IMAGE"
echo "commit:     $commit"
echo "runs:       $RUNS interleaved pairs"
echo
printf 'script  median %7s ms   (min %7s  max %7s)\n' \
    "$(ms "$script_median")" "$(ms "$(minimum "${script_times[@]}")")" "$(ms "$(maximum "${script_times[@]}")")"
printf 'binary  median %7s ms   (min %7s  max %7s)\n' \
    "$(ms "$binary_median")" "$(ms "$(minimum "${binary_times[@]}")")" "$(ms "$(maximum "${binary_times[@]}")")"
printf 'delta          %7s %%\n' "$delta"

if [[ -n $JSON_OUT ]]; then
    jq -n \
        --arg component "$COMPONENT" \
        --arg platform "$PLATFORM" \
        --arg host "$host" \
        --arg runner "$RUNNER_LABEL" \
        --arg image "$RUNNER_IMAGE" \
        --arg commit "$commit" \
        --arg payload "${PAYLOAD#"$REPO_ROOT"/}" \
        --argjson runs "$RUNS" \
        --argjson script_median "$(ms "$script_median")" \
        --argjson script_min "$(ms "$(minimum "${script_times[@]}")")" \
        --argjson script_max "$(ms "$(maximum "${script_times[@]}")")" \
        --argjson binary_median "$(ms "$binary_median")" \
        --argjson binary_min "$(ms "$(minimum "${binary_times[@]}")")" \
        --argjson binary_max "$(ms "$(maximum "${binary_times[@]}")")" \
        --argjson delta "$delta" \
        '{schema: 1, component: $component, platform: $platform, host_class: "hosted runner",
          host: $host, runner: $runner, image: $image, commit: $commit, payload: $payload, runs: $runs,
          script_ms: {median: $script_median, min: $script_min, max: $script_max},
          binary_ms: {median: $binary_median, min: $binary_min, max: $binary_max},
          delta_pct: $delta}' > "$JSON_OUT"
    echo "wrote $JSON_OUT"
fi
