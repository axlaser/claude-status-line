#!/usr/bin/env bash
# Claude Code statusLine script for macOS.

# @parity:constant CACHE_VERSION=1
CACHE_VERSION="1"

if ! command -v jq &>/dev/null; then
    printf '\033[31m[statusline: jq not found — run: brew install jq]\033[0m'
    exit 0
fi

# @parity:colors-begin
ESC=$'\033'
RESET="${ESC}[0m"
DIM="${ESC}[2m"
BOLD="${ESC}[1m"
CYAN="${ESC}[36m"
MAGENTA="${ESC}[35m"
YELLOW="${ESC}[33m"
GREEN="${ESC}[32m"
RED="${ESC}[31m"
BLUE="${ESC}[34m"
WHITE="${ESC}[37m"
GRAY="${ESC}[90m"
BAR_EMPTY="${ESC}[38;5;242m"
# @parity:colors-end

# --- Debug log ---
LOG_PATH="$HOME/.claude/statusline-debug.log"
log_msg() {
    [[ -n "$STATUSLINE_DEBUG" ]] || return 0
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH" 2>/dev/null
}
log_msg "=== invoked, BASH_VERSION=$BASH_VERSION PID=$$ ==="

# --- Read stdin ---
raw=$(cat)
log_msg "stdin bytes=${#raw}"
log_msg "stdin head: ${raw:0:400}"

# @parity:json-extract-begin
# Single jq pass: the in-filter type check replaces the old standalone
# validity probe (one process spawn per refresh instead of two). Parse
# errors and non-object input both yield zero output lines.
mapfile -t _jf < <(printf '%s' "$raw" | jq -r 'if type != "object" then error("not a JSON object") else [
    (.session_id // ""),
    (.workspace.current_dir // ""),
    (.cwd // ""),
    (.model.display_name // ""),
    (.context_window.context_window_size // ""),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // ""),
    (.effort.level // ""),
    (.workspace.current_dir // ""),
    (.cost.total_cost_usd // ""),
    (.total_cost_usd // ""),
    (.cost.total_duration_ms // ""),
    (.total_duration_ms // ""),
    (.duration_ms // ""),
    (.transcript_path // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.agent.name // ""),
    (.context_window.current_usage.input_tokens // ""),
    (.context_window.current_usage.output_tokens // ""),
    (.model.id // "")
] | .[] end' 2>/dev/null)
if (( ${#_jf[@]} == 0 )); then
    log_msg "READ/PARSE FAILED"
    printf '%s' "${RED}[statusline: bad JSON]${RESET}"
    exit 0
fi
log_msg "json parse: OK"
J_SESSION_ID="${_jf[0]}"
J_CWD="${_jf[1]}"
J_CWD_FALLBACK="${_jf[2]}"
J_MODEL_DISPLAY="${_jf[3]}"
J_CTX_SIZE="${_jf[4]}"
J_USED_PCT="${_jf[5]}"
J_TOTAL_INPUT_TOKENS="${_jf[6]}"
J_EFFORT_LEVEL="${_jf[7]}"
J_GIT_CWD="${_jf[8]}"
J_TOTAL_COST="${_jf[9]}"
J_TOTAL_COST_LEGACY="${_jf[10]}"
J_DURATION_MS="${_jf[11]}"
J_DURATION_MS_L1="${_jf[12]}"
J_DURATION_MS_L2="${_jf[13]}"
J_TRANSCRIPT_PATH="${_jf[14]}"
J_RATE_5H_PCT="${_jf[15]}"
J_RATE_5H_RESETS="${_jf[16]}"
J_RATE_7D_PCT="${_jf[17]}"
J_RATE_7D_RESETS="${_jf[18]}"
J_AGENT_NAME="${_jf[19]}"
J_AGENT_IN="${_jf[20]}"
J_AGENT_OUT="${_jf[21]}"
J_MODEL_ID="${_jf[22]}"
# @parity:json-extract-end

# @parity:temp-guards-begin
# Trust boundary for predictable temp files (shared /tmp on Linux; per-user dirs
# on macOS/Windows). Read only a regular file we own that is not a symlink; on
# write, skip (never follow) a planted symlink or foreign-owned target,
# re-testing after the unlink since a foreign-owned entry cannot be removed
# under a sticky dir. Applied to every statusline-* cache/state file we touch.
sl_trusted_file() { [[ -f "$1" && ! -L "$1" && -O "$1" ]]; }
sl_write_ok() {
    local f="$1"
    [[ -L "$f" || ( -e "$f" && ! -O "$f" ) ]] && rm -f "$f" 2>/dev/null
    [[ ! -L "$f" && ( ! -e "$f" || -O "$f" ) ]]
}
# @parity:temp-guards-end

# @parity:sanitize-title-begin
# Shared field sanitizer (subagent render sink, git-branch render, fallback meta
# reads). Defined early so the git block — which runs before the subagent
# helpers — can call it.
sa_sanitize_title() {  # replace "|" and control chars with spaces, trim -> "" when blank
    local s="${1//[$'\x01'-$'\x1f'$'\x7f']/ }"
    s="${s//'|'/ }"
    s="${s#"${s%%[! ]*}"}"
    s="${s%"${s##*[! ]}"}"
    printf '%s' "$s"
}
# @parity:sanitize-title-end

# --- Idle-state fast path ---
_oc_path="${TMPDIR:-/tmp}/statusline-oc-${J_SESSION_ID//[^a-zA-Z0-9_-]/}.txt"
_oc_tmt=""
[[ -n "$J_TRANSCRIPT_PATH" && -f "$J_TRANSCRIPT_PATH" ]] && _oc_tmt=$(stat -f %m "$J_TRANSCRIPT_PATH" 2>/dev/null)
_oc_now=$(date +%s)
_oc_gmt=""
_oc_gidx="${J_GIT_CWD:-.}/.git/index"
[[ -f "$_oc_gidx" ]] && _oc_gmt=$(stat -f %m "$_oc_gidx" 2>/dev/null)
_oc_smt=""
if [[ -n "$J_TRANSCRIPT_PATH" ]]; then
    _oc_sdir="$(dirname "$J_TRANSCRIPT_PATH")/$(basename "$J_TRANSCRIPT_PATH" .jsonl)/subagents"
    [[ -d "$_oc_sdir" ]] && _oc_smt=$(stat -f %m "$_oc_sdir" 2>/dev/null)
fi
# Feed content+freshness and the learned-map mtime join the key so subagent
# tier switches and learned window changes invalidate the render cache. The
# handler rewrites the feed file every tick, so keying on its mtime would
# defeat the output cache; mtime feeds only the freshness flag.
_oc_feed="${TMPDIR:-/tmp}/statusline-tasks-${J_SESSION_ID//[^a-zA-Z0-9_-]/}.json"
# @parity:cache FEED_TTL=10
FEED_TTL=10
_oc_fmt=""
[[ -f "$_oc_feed" ]] && _oc_fmt=$(stat -f %m "$_oc_feed" 2>/dev/null)
_oc_ffresh=0
_oc_fjson=""
if [[ "$_oc_fmt" =~ ^[0-9]+$ ]] && (( _oc_now - _oc_fmt <= FEED_TTL )); then
    _oc_ffresh=1
    # Handler writes compact single-line JSON; the builtin read avoids a cat
    # fork on this every-tick path. Command group silences a redirect-open
    # failure if the file vanishes between the stat and the read.
    sl_trusted_file "$_oc_feed" && { IFS= read -r _oc_fjson < "$_oc_feed"; } 2>/dev/null
fi
MODEL_WINDOWS_PATH="$HOME/.claude/statusline-model-windows.json"
_oc_mwmt=""
[[ -f "$MODEL_WINDOWS_PATH" ]] && _oc_mwmt=$(stat -f %m "$MODEL_WINDOWS_PATH" 2>/dev/null)
# @parity:cache OUTPUT_BUCKET=5
_oc_key=$(printf '%s' "${raw}|${_oc_tmt}|${_oc_gmt}|${_oc_smt}|${_oc_ffresh}|${_oc_fjson}|${_oc_mwmt}|$(( _oc_now / 5 ))" | shasum -a 256 | cut -d' ' -f1)

if [[ -n "$J_SESSION_ID" ]] && sl_trusted_file "$_oc_path"; then
    # Command group so a redirect-open failure (git-refresh hook may delete the
    # file between -f and read) is silenced; a trailing 2>/dev/null on the bare
    # read does not cover the redirect itself.
    _oc_cached_key=""
    { IFS= read -r _oc_cached_key < "$_oc_path"; } 2>/dev/null
    if [[ "$_oc_cached_key" == "$_oc_key" ]]; then
        tail -n +2 "$_oc_path" 2>/dev/null && exit 0
    fi
fi

format_tokens() {  # 1234567 -> "1.2M"
    local n=$1
    [[ -z "$n" || "$n" == "0" ]] && { printf '0'; return; }
    if (( n >= 1000000 )); then
        local whole=$((n / 1000000)) frac=$(( (n % 1000000) / 100000 ))
        printf '%d.%dM' "$whole" "$frac"
    elif (( n >= 1000 )); then
        local whole=$((n / 1000)) frac=$(( (n % 1000) / 100 ))
        printf '%d.%dK' "$whole" "$frac"
    else
        printf '%d' "$n"
    fi
}

pct_color_for() {  # context percentage -> threshold color
    local pct=${1:-0}
# @parity:threshold CONTEXT_CRIT=85
# @parity:threshold CONTEXT_WARN=60
    if   (( pct >= 85 )); then printf '%s' "$RED"
    elif (( pct >= 60 )); then printf '%s' "$YELLOW"
    else                       printf '%s' "$GREEN"
    fi
}

effort_color_for() {  # reasoning effort level -> ladder color
    # Shared by the model row and every subagent row so the two can never drift.
    # Unknown values (including the integer form agent frontmatter allows) fall
    # through to WHITE rather than being rejected.
# @parity:effort-ladder-begin
    case "${1:-}" in
        low)    printf '%s' "$GRAY" ;;
        medium) printf '%s' "$WHITE" ;;
        high)   printf '%s' "$CYAN" ;;
        xhigh)  printf '%s' "$YELLOW" ;;
        max)    printf '%s' "$RED" ;;
        *)      printf '%s' "$WHITE" ;;
    esac
# @parity:effort-ladder-end
}

render_bar() {  # pct color -> filled/empty bar over bar_width cells
    local pct=${1:-0} color=$2 filled
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    filled=$(( (bar_width * pct + 50) / 100 ))
    printf '%s' "${color}$(repeat_char "█" "$filled")${RESET}${BAR_EMPTY}$(repeat_char "░" "$((bar_width - filled))")${RESET}"
}

normalize_model_id() {  # strip trailing -YYYYMMDD date suffix
    local id="$1"
    [[ "$id" =~ -[0-9]{8}$ ]] && id="${id%-*}"
    printf '%s' "$id"
}

prettify_model_id() {  # claude-sonnet-5 -> "Sonnet 5"; unknown -> cleaned id
    local id
    id=$(normalize_model_id "$1")
    id="${id#claude-}"
    if [[ "$id" =~ ^(fable|opus|sonnet|haiku)-([0-9]+(-[0-9]+)*) ]]; then
        local fam="${BASH_REMATCH[1]}" ver="${BASH_REMATCH[2]//-/.}"
        printf '%s %s' "${fam^}" "$ver"
    else
        printf '%s' "$id"
    fi
}

# @parity:seed-table-begin
# Known model->window seeds; keys are normalized ids (date suffix stripped,
# claude- prefix tolerated). Unlisted ids fall through to the resolver tiers.
seed_window_for_model() {  # normalized model id -> window size or ""
    case "${1#claude-}" in
        fable-5|opus-4-8|opus-4-7|opus-4-6|sonnet-5|sonnet-4-6) echo 1000000 ;;
        haiku-4-5|sonnet-4-5|opus-4-5)                          echo 200000  ;;
        *)                                                      echo ""      ;;
    esac
}
# @parity:seed-table-end

sa_ctx_for_model() {  # tiered: learned map -> seed table -> 1m marker -> 200K default
    local norm win=""
    norm=$(normalize_model_id "$1")
    [[ -n "$norm" ]] && win="${MODEL_WINDOWS_MAP[$norm]:-}"
    if [[ "$win" =~ ^[0-9]+$ ]]; then
        log_msg "sa ctx: ${norm} -> ${win} (learned)"
        echo "$win"
        return
    fi
    win=$(seed_window_for_model "$norm")
    if [[ -n "$win" ]]; then
        log_msg "sa ctx: ${norm} -> ${win} (seed)"
        echo "$win"
        return
    fi
    case "$norm" in
        *\[1m\]*|*-1m*)
            log_msg "sa ctx: ${norm} -> 1000000 (marker)"
            echo 1000000
            return ;;
    esac
    log_msg "sa ctx: ${norm} -> 200000 (default)"
    echo 200000
}

shopt -s extglob
get_vis() {  # visible terminal cells: ANSI stripped; CJK/emoji count as 2
    local s="$1"
    s="${s//$'\033'\[*([0-9;])m/}"
    if [[ "$s" != *[![:ascii:]]* ]]; then
        printf '%d' "${#s}"
        return
    fi
    local n=${#s} w=0 i cp
    for ((i = 0; i < n; i++)); do
        printf -v cp '%d' "'${s:i:1}" 2>/dev/null || cp=0
        if (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) ||
              (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) ||
              (cp >= 0xFE30 && cp <= 0xFE4F) || (cp >= 0xFF00 && cp <= 0xFF60) ||
              (cp >= 0xFFE0 && cp <= 0xFFE6) || cp >= 0x1F000 )); then
            w=$((w + 2))
        else
            w=$((w + 1))
        fi
    done
    printf '%d' "$w"
}

repeat_char() {  # multi-byte safe char repeat
    local ch="$1" count="$2" out=""
    for ((i = 0; i < count; i++)); do out+="$ch"; done
    printf '%s' "$out"
}

# --- 1. CWD ---
session_id="$J_SESSION_ID"
cwd="$J_CWD"
[[ -z "$cwd" ]] && cwd="$J_CWD_FALLBACK"
[[ -z "$cwd" ]] && cwd="$PWD"

if [[ "$cwd" == "$HOME" || "$cwd" == "$HOME"/* ]]; then
    cwd="~${cwd#"$HOME"}"
else
    IFS='/' read -ra parts <<< "$cwd"
    non_empty=()
    for p in "${parts[@]}"; do [[ -n "$p" ]] && non_empty+=("$p"); done
    if (( ${#non_empty[@]} > 2 )); then
        cwd=".../${non_empty[$((${#non_empty[@]}-2))]}/${non_empty[$((${#non_empty[@]}-1))]}"
    fi
fi
cwd_part="${CYAN}${cwd}${RESET}"

# --- 2. Model + Context window % ---
model_display="$J_MODEL_DISPLAY"

model_short="$model_display"
if [[ -n "$model_short" ]]; then
    model_short="${model_short#Claude }"
    model_short="${model_short:0:24}"
else
    model_short="unknown"
fi

ctx_size="$J_CTX_SIZE"
[[ "$ctx_size" =~ ^[0-9]+$ ]] || ctx_size=""
used_pct="$J_USED_PCT"

ctx_label=""
if [[ -n "$ctx_size" ]]; then
    ctx_k=$((ctx_size / 1000))
    if (( ctx_k >= 1000 )); then
        ctx_label="$((ctx_k / 1000))M"
    else
        ctx_label="${ctx_k}K"
    fi
fi

pct_int=""
pct_color="$WHITE"
if [[ -n "$used_pct" ]]; then
    pct_int=$(printf '%.0f' "$used_pct" 2>/dev/null)
    pct_color=$(pct_color_for "$pct_int")
fi

model_part="${MAGENTA}${model_short}${RESET}"

# --- 2b. Context bar ---
# Always rendered (missing used_pct -> 0%, missing ctx_size -> no token label)
# so a fresh session shows an empty bar instead of an empty row.
bar_width=30
bar_used_pct="${used_pct:-0}"
bar_pct_int="${pct_int:-0}"
bar_color="${pct_color}"
[[ -z "$pct_int" ]] && bar_color="$GREEN"
bar_pct_clamped="${bar_used_pct%.*}"
[[ -z "$bar_pct_clamped" ]] && bar_pct_clamped=0
(( bar_pct_clamped < 0 )) && bar_pct_clamped=0
(( bar_pct_clamped > 100 )) && bar_pct_clamped=100
bar=$(render_bar "$bar_pct_clamped" "$bar_color")

token_suffix=""
if [[ -n "$ctx_size" ]]; then
    # Prefer total_input_tokens — used_percentage is rounded so derived counts jump in 10K steps on 1M windows.
    total_input_tokens="$J_TOTAL_INPUT_TOKENS"
    if [[ -n "$total_input_tokens" ]]; then
        used_tokens="$total_input_tokens"
    else
        used_tokens=$(( ctx_size * bar_pct_clamped / 100 ))
    fi
    used_lbl=$(format_tokens "$used_tokens")
    token_suffix=" ${GRAY}·${RESET} ${WHITE}${used_lbl}${RESET}${GRAY}/${ctx_label}${RESET}"
fi

ctx_bar_part="${bar} ${bar_color}${bar_pct_int}%${RESET}${token_suffix}"

# --- 2c. Learned model->window map ---
# Persist the main session's model->window pair so subagent rows can resolve
# real denominators later. Multi-writer file: atomic mktemp+mv, skip when the
# entry already matches (no mtime churn). All failures are silent.
# One jq pass validates and flattens the map straight into an associative
# array so per-subagent lookups don't fork jq; a non-object file yields no
# entries (silent degradation to the seed table).
declare -A MODEL_WINDOWS_MAP=()
if [[ -f "$MODEL_WINDOWS_PATH" ]]; then
    while IFS=$'\t' read -r _mw_k _mw_v; do
        [[ -n "$_mw_k" ]] && MODEL_WINDOWS_MAP["$_mw_k"]="$_mw_v"
    done < <(jq -r 'if type == "object" then to_entries[] | "\(.key)\t\(.value)" else empty end' "$MODEL_WINDOWS_PATH" 2>/dev/null)
fi
if [[ -n "$J_MODEL_ID" && -n "$ctx_size" ]]; then
    _mw_key=$(normalize_model_id "$J_MODEL_ID")
    if [[ -n "$_mw_key" && "${MODEL_WINDOWS_MAP[$_mw_key]:-}" != "$ctx_size" ]]; then
        # Rare write path: re-read the file for the merge base (also picks up
        # entries a concurrent session wrote since the map was flattened above).
        _mw_base=""
        [[ -f "$MODEL_WINDOWS_PATH" ]] && _mw_base=$(jq -c 'if type == "object" then . else empty end' "$MODEL_WINDOWS_PATH" 2>/dev/null)
        [[ -z "$_mw_base" ]] && _mw_base="{}"
        _mw_merged=$(printf '%s' "$_mw_base" | jq -c --arg m "$_mw_key" --argjson w "$ctx_size" '. + {($m): $w}' 2>/dev/null)
        if [[ -n "$_mw_merged" ]]; then
            mkdir -p "${MODEL_WINDOWS_PATH%/*}" 2>/dev/null
            _mw_tmp=$(mktemp "${MODEL_WINDOWS_PATH}.XXXXXX" 2>/dev/null) || _mw_tmp=""
            if [[ -n "$_mw_tmp" ]] && printf '%s\n' "$_mw_merged" > "$_mw_tmp" 2>/dev/null && mv -f "$_mw_tmp" "$MODEL_WINDOWS_PATH" 2>/dev/null; then
                MODEL_WINDOWS_MAP["$_mw_key"]="$ctx_size"
                log_msg "model-windows: learned ${_mw_key}=${ctx_size}"
            else
                [[ -n "$_mw_tmp" ]] && rm -f "$_mw_tmp" 2>/dev/null
            fi
        fi
    fi
fi

# --- 3. Reasoning effort ---
effort_level="$J_EFFORT_LEVEL"
effort_part=""
if [[ -n "$effort_level" ]]; then
    effort_part="$(effort_color_for "$effort_level")${effort_level} effort${RESET}"
fi

# --- 4. Git status ---
git_part=""
git_cwd="$J_GIT_CWD"
[[ -z "$git_cwd" ]] && git_cwd="$PWD"

branch=""
insertions=0
deletions=0
untracked=0
ahead=0
behind=0
stash=0

git_index="$git_cwd/.git/index"
if [[ -f "$git_index" ]]; then
    git_index_mt=$(stat -f %m "$git_index" 2>/dev/null || echo 0)
    git_cache_path="${TMPDIR:-/tmp}/statusline-git-${session_id//[^a-zA-Z0-9_-]/}.txt"
    git_use_cache=false

    if sl_trusted_file "$git_cache_path"; then
        gc_mt=""
        { IFS=$'\x1f' read -r gc_mt gc_branch gc_ins gc_del gc_unt gc_ahead gc_behind gc_stash < "$git_cache_path"; } 2>/dev/null
        # Validate numerics so a torn/corrupt cache write can't reach arithmetic.
        [[ "$gc_ins" =~ ^[0-9]+$ ]] || gc_ins=0
        [[ "$gc_del" =~ ^[0-9]+$ ]] || gc_del=0
        [[ "$gc_unt" =~ ^[0-9]+$ ]] || gc_unt=0
        [[ "$gc_ahead" =~ ^[0-9]+$ ]] || gc_ahead=0
        [[ "$gc_behind" =~ ^[0-9]+$ ]] || gc_behind=0
        [[ "$gc_stash" =~ ^[0-9]+$ ]] || gc_stash=0
        if [[ "$gc_mt" == "$git_index_mt" ]]; then
            gc_file_age=$(( _oc_now - $(stat -f %m "$git_cache_path" 2>/dev/null || echo 0) ))
# @parity:cache GIT_TTL=5
            if (( gc_file_age < 5 )); then
                branch="$gc_branch"; insertions="$gc_ins"; deletions="$gc_del"; untracked="$gc_unt"
                ahead="${gc_ahead:-0}"; behind="${gc_behind:-0}"; stash="${gc_stash:-0}"
                git_use_cache=true
            fi
        fi
    fi

    if [[ "$git_use_cache" != true ]]; then
        if git --no-optional-locks -C "$git_cwd" rev-parse --is-inside-work-tree &>/dev/null; then
            branch=$(git --no-optional-locks -C "$git_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
            if [[ "$branch" == "HEAD" ]]; then
                branch=$(git --no-optional-locks -C "$git_cwd" rev-parse --short HEAD 2>/dev/null) || branch="HEAD"
            fi
            if [[ -n "$branch" ]]; then
                diff_stat=$(git --no-optional-locks -C "$git_cwd" diff --shortstat HEAD 2>/dev/null)
                if [[ -n "$diff_stat" ]]; then
                    [[ "$diff_stat" =~ ([0-9]+)\ insertion ]] && insertions="${BASH_REMATCH[1]}"
                    [[ "$diff_stat" =~ ([0-9]+)\ deletion ]]  && deletions="${BASH_REMATCH[1]}"
                fi
                untracked=$(git --no-optional-locks -C "$git_cwd" status --porcelain 2>/dev/null | grep -c '^??' || true)
                ab_count=$(git --no-optional-locks -C "$git_cwd" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
                if [[ -n "$ab_count" ]]; then
                    read -r ahead behind <<< "$ab_count"
                fi
                stash=$(git --no-optional-locks -C "$git_cwd" stash list 2>/dev/null | wc -l)
                stash=$(( stash + 0 ))
            fi
        fi
        sl_write_ok "$git_cache_path" && printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' "$git_index_mt" "$branch" "$insertions" "$deletions" "$untracked" "$ahead" "$behind" "$stash" > "$git_cache_path" 2>/dev/null
    fi
fi

# Scrub control/escape bytes from the branch (its cached value is plantable via
# statusline-git-*), mirroring the subagent render-sink scrub, before it renders.
branch=$(sa_sanitize_title "$branch")
if [[ -n "$branch" ]]; then
    is_dirty=false
    (( insertions > 0 || deletions > 0 || untracked > 0 )) && is_dirty=true
    if $is_dirty; then branch_color="$YELLOW"; else branch_color="$GREEN"; fi
    git_part="${branch_color}${branch}${RESET}"
    (( ahead > 0 ))      && git_part+=" ${CYAN}↑${ahead}${RESET}"
    (( behind > 0 ))     && git_part+=" ${MAGENTA}↓${behind}${RESET}"
    (( insertions > 0 )) && git_part+=" ${GREEN}+${insertions}${RESET}"
    (( deletions > 0 ))  && git_part+=" ${RED}-${deletions}${RESET}"
    (( untracked > 0 ))  && git_part+=" ${GRAY}~${untracked}${RESET}"
    (( stash > 0 ))      && git_part+=" ${DIM}⊟${stash}${RESET}"
fi

# --- 5. Cost + Duration ---
cost_part=""
total_cost="$J_TOTAL_COST"
[[ -z "$total_cost" ]] && total_cost="$J_TOTAL_COST_LEGACY"

if [[ -n "$total_cost" ]]; then
    cost_fmt=$(awk -v c="$total_cost" 'BEGIN { printf "$%.4f", c }')
# @parity:threshold COST_WARN=0.50
    cost_gt=$(awk -v c="$total_cost" 'BEGIN { print (c > 0.50) ? 1 : 0 }')
    if (( cost_gt )); then cost_color="$YELLOW"; else cost_color="$GREEN"; fi
    cost_part="${cost_color}${cost_fmt}${RESET}"
fi

duration_ms="$J_DURATION_MS"
[[ -z "$duration_ms" ]] && duration_ms="$J_DURATION_MS_L1"
[[ -z "$duration_ms" ]] && duration_ms="$J_DURATION_MS_L2"

if [[ -n "$duration_ms" ]]; then
    secs=$(( ${duration_ms%.*} / 1000 ))
    [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
    if (( secs >= 3600 )); then
        d_str="$((secs / 3600))h$(printf '%02d' $(( (secs % 3600) / 60 )))m"
    elif (( secs >= 60 )); then
        d_str="$((secs / 60))m$(printf '%02d' $((secs % 60)))s"
    else
        d_str="${secs}s"
    fi
    duration_part="${WHITE}${d_str}${RESET}"
fi

# --- 5b/5c. Transcript-derived: messages, idle/working, cumulative tokens ---
# Cached by transcript mtime so big sessions don't slow refresh; cache also
# stashes prior token totals for per-refresh delta computation.
msg_count=""
claude_is_idle=true
session_in_tokens=0
session_cache_write_tokens=0
session_cache_read_tokens=0
session_out_tokens=0
working_start_out_tokens=-1
delta_in=0
delta_cache_write=0
delta_cache_read=0
delta_out=0

transcript_path="$J_TRANSCRIPT_PATH"

if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    cache_path=""
    [[ -n "$session_id" ]] && cache_path="${TMPDIR:-/tmp}/statusline-cache-${session_id//[^a-zA-Z0-9_-]/}.txt"

    transcript_mt=$(stat -f %m "$transcript_path" 2>/dev/null || echo 0)
    transcript_sz=$(stat -f %z "$transcript_path" 2>/dev/null || echo 0)
    use_cache=false
    prev_working_start=-1
    prev_in=0
    prev_cache_write=0
    prev_cache_read=0
    prev_out=0

    # Read prior cache even on miss — needed for workingStart + deltas.
    if [[ -n "$cache_path" ]] && sl_trusted_file "$cache_path"; then
        IFS='|' read -r c_ver c_mt c_sz c_msg c_idle c_in c_out c_wstart c_cwrite c_cread c_din c_dout c_dcw c_dcr < "$cache_path"
        # Validate all numeric cache fields to prevent arithmetic injection
        [[ "$c_in" =~ ^-?[0-9]+$ ]] || c_in=0
        [[ "$c_out" =~ ^-?[0-9]+$ ]] || c_out=0
        [[ "$c_wstart" =~ ^-?[0-9]+$ ]] || c_wstart=-1
        [[ "$c_cwrite" =~ ^-?[0-9]+$ ]] || c_cwrite=0
        [[ "$c_cread" =~ ^-?[0-9]+$ ]] || c_cread=0
        [[ "$c_din" =~ ^-?[0-9]+$ ]] || c_din=0
        [[ "$c_dout" =~ ^-?[0-9]+$ ]] || c_dout=0
        [[ "$c_dcw" =~ ^-?[0-9]+$ ]] || c_dcw=0
        [[ "$c_dcr" =~ ^-?[0-9]+$ ]] || c_dcr=0
        [[ -n "$c_wstart" ]] && prev_working_start="$c_wstart"
        [[ -n "$c_in" ]] && prev_in="$c_in"
        [[ -n "$c_out" ]] && prev_out="$c_out"
        [[ -n "$c_cwrite" ]] && prev_cache_write="$c_cwrite"
        [[ -n "$c_cread" ]] && prev_cache_read="$c_cread"

        if [[ "$c_ver" == "$CACHE_VERSION" && -n "$c_dcr" && "$c_mt" == "$transcript_mt" && "$c_sz" == "$transcript_sz" ]]; then
            msg_count="$c_msg"
            claude_is_idle="$c_idle"
            session_in_tokens="$c_in"
            session_out_tokens="$c_out"
            working_start_out_tokens="$prev_working_start"
            session_cache_write_tokens="$c_cwrite"
            session_cache_read_tokens="$c_cread"
            delta_in="$c_din"
            delta_out="$c_dout"
            delta_cache_write="$c_dcw"
            delta_cache_read="$c_dcr"
            use_cache=true
        fi
    fi

    if [[ "$use_cache" != true ]]; then
        if [[ -s "$transcript_path" ]]; then
            # Single awk pass counts real user messages and sums all token fields.
            read -r msg_count session_in_tokens session_cache_write_tokens session_cache_read_tokens session_out_tokens < <(
                awk '
                    /"type"[[:space:]]*:[[:space:]]*"user"/ {
                        if ($0 !~ /"toolUseResult"/ &&
                            $0 !~ /"isMeta"[[:space:]]*:[[:space:]]*true/ &&
                            $0 !~ /<command-name>/ &&
                            $0 !~ /<local-command-stdout>/) mc++
                    }
                    /"type"[[:space:]]*:[[:space:]]*"assistant"/ {
                        s = $0
                        t = s; sub(/.*"input_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) inp += t+0
                        t = s; sub(/.*"cache_creation_input_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) cw += t+0
                        t = s; sub(/.*"cache_read_input_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) cr += t+0
                        t = s; sub(/.*"output_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) out += t+0
                    }
                    END { print mc+0, inp+0, cw+0, cr+0, out+0 }
                ' "$transcript_path" 2>/dev/null
            )
            [[ -z "$msg_count" ]] && msg_count=0

            # Scan from end (tail -r with tac fallback for GNU coreutils), skip synthetic entries — without
            # filtering <local-command-*> the detector stays stuck on "working" after /effort.
            claude_is_idle=true
            while IFS= read -r ln; do
                [[ "$ln" == *'"isMeta"'* ]] && continue
                [[ "$ln" == *'<command-name>'* ]] && continue
                [[ "$ln" == *'<local-command-'* ]] && continue
                [[ "$ln" == *"toolUseResult"* ]] && continue
                if [[ "$ln" == *'"type"'*'"assistant"'* ]]; then
                    if [[ "$ln" == *'"stop_reason"'*'"end_turn"'* ]]; then
                        claude_is_idle=true
                    else
                        claude_is_idle=false
                    fi
                    break
                fi
                if [[ "$ln" == *'"type"'*'"user"'* ]]; then
                    if [[ "$ln" == *'Request interrupted by user'* ]]; then
                        claude_is_idle=true
                    else
                        claude_is_idle=false
                    fi
                    break
                fi
            done < <(tail -r "$transcript_path" 2>/dev/null || tac "$transcript_path" 2>/dev/null)

            delta_in=$(( session_in_tokens - prev_in ))
            delta_out=$(( session_out_tokens - prev_out ))
            delta_cache_write=$(( session_cache_write_tokens - prev_cache_write ))
            delta_cache_read=$(( session_cache_read_tokens - prev_cache_read ))
            (( delta_in < 0 )) && delta_in=0
            (( delta_out < 0 )) && delta_out=0
            (( delta_cache_write < 0 )) && delta_cache_write=0
            (( delta_cache_read < 0 )) && delta_cache_read=0

            if [[ "$claude_is_idle" == true ]]; then
                working_start_out_tokens=-1
            elif (( prev_working_start >= 0 )); then
                working_start_out_tokens=$prev_working_start
            else
                working_start_out_tokens=$session_out_tokens
            fi

            if [[ -n "$cache_path" ]] && sl_write_ok "$cache_path"; then
                printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
                    "$CACHE_VERSION" "$transcript_mt" "$transcript_sz" "$msg_count" "$claude_is_idle" \
                    "$session_in_tokens" "$session_out_tokens" \
                    "$working_start_out_tokens" "$session_cache_write_tokens" \
                    "$session_cache_read_tokens" "$delta_in" "$delta_out" \
                    "$delta_cache_write" "$delta_cache_read" > "$cache_path" 2>/dev/null
            fi
        fi
    fi
fi

format_bucket() {  # label value delta idle_color active_color [arrow] -> "label N (+delta)"
    local label="$1" value="$2" delta="$3" idle_color="$4" active_color="$5" arrow="$6"
    local lbl d_lbl arrow_part=""
    lbl=$(format_tokens "$value")
    d_lbl=$(format_tokens "$delta")
    [[ -z "$d_lbl" ]] && d_lbl="0"
    [[ -n "$arrow" ]] && arrow_part="${GRAY}${arrow}${RESET}"
    if (( delta > 0 )); then
        printf '%s' "${active_color}${BOLD}${label}${RESET}${arrow_part} ${active_color}${lbl}${RESET} ${GREEN}(+${d_lbl})${RESET}"
    else
        printf '%s' "${DIM}${label}${RESET}${arrow_part} ${idle_color}${lbl}${RESET} ${DIM}(+${d_lbl})${RESET}"
    fi
}

# Tokens row — always render (dim "(+0)" when idle).
row_sep=" ${GRAY}·${RESET} "
tokens_part=$(format_bucket "in" "$session_in_tokens" "$delta_in" "$CYAN" "$CYAN")
tokens_part+="${row_sep}$(format_bucket "cache" "$session_cache_write_tokens" "$delta_cache_write" "$GRAY" "$YELLOW" "↑")"
tokens_part+="${row_sep}$(format_bucket "cache" "$session_cache_read_tokens" "$delta_cache_read" "$GRAY" "$CYAN" "↓")"
tokens_part+="${row_sep}$(format_bucket "out" "$session_out_tokens" "$delta_out" "$MAGENTA" "$MAGENTA")"

# Status (idle/working) — rendered on model row
if [[ "$claude_is_idle" == true ]]; then
    status_dot="${GREEN}●${RESET}"
    status_label="${WHITE}ready${RESET}"
    status_part="${status_dot}  ${status_label}"
else
    status_dot="${YELLOW}○${RESET}"
    status_label="${YELLOW}working${RESET}"
    status_part="${status_dot}  ${status_label}"
fi

# Message count — rendered on cost row
msg_part=""
if [[ -n "$msg_count" && "$msg_count" -gt 0 ]] 2>/dev/null; then
    msg_label="messages"
    (( msg_count == 1 )) && msg_label="message"
    msg_part="${WHITE}${msg_count}${RESET} ${DIM}${msg_label}${RESET}"
fi

# --- 6. Rate limits (5h + 7d) ---
# Burn-rate arrow compares actual % vs linear "expected %" for elapsed time.
format_duration() {  # seconds -> "5m", "2h15m", "1d3h"
    local secs=$1
    (( secs <= 0 )) && return
    if (( secs < 3600 )); then
        printf '%dm' $((secs / 60))
    elif (( secs < 86400 )); then
        local h=$((secs / 3600))
        local m=$(( (secs - h * 3600) / 60 ))
        if (( m == 0 )); then printf '%dh' "$h"; else printf '%dh%dm' "$h" "$m"; fi
    else
        local d=$((secs / 86400))
        local h=$(( (secs - d * 86400) / 3600 ))
        if (( h == 0 )); then printf '%dd' "$d"; else printf '%dd%dh' "$d" "$h"; fi
    fi
}

format_window() {  # label pct resets_at window_secs -> "5h 42% ⇡3% (1h)"
    local label=$1 pct_val=$2 resets_at=$3 window_secs=$4
    [[ -z "$pct_val" ]] && return

    local pct
    pct=$(printf '%.0f' "$pct_val" 2>/dev/null)
    local pct_color
    if (( pct >= 80 )); then     pct_color="$RED"
    elif (( pct >= 50 )); then   pct_color="$YELLOW"
    else                         pct_color="$GREEN"
    fi

    local burn_part="" reset_part=""
    if [[ -n "$resets_at" && "${resets_at%.*}" =~ ^[0-9]+$ ]]; then
        local now
        now=$(date +%s)
        local remaining=$(( ${resets_at%.*} - now ))
        if (( remaining > 0 && remaining <= window_secs )); then
            local expected_pct=$(( (window_secs - remaining) * 100 / window_secs ))
            local delta=$(( ${pct%.*} - expected_pct ))
            local abs_delta=${delta#-}
            if (( abs_delta >= 1 )); then
                if (( delta > 0 )); then
                    burn_part=" ${RED}⇡${abs_delta}%${RESET}"
                else
                    burn_part=" ${GREEN}⇣${abs_delta}%${RESET}"
                fi
            fi
            local r_lbl
            r_lbl=$(format_duration "$remaining")
            [[ -n "$r_lbl" ]] && reset_part=" ${GRAY}(${r_lbl})${RESET}"
        fi
    fi

    printf '%s' "${DIM}${label}${RESET} ${pct_color}${pct}%${RESET}${burn_part}${reset_part}"
}

rate_part=""
five_pct="$J_RATE_5H_PCT"
five_res="$J_RATE_5H_RESETS"
seven_pct="$J_RATE_7D_PCT"
seven_res="$J_RATE_7D_RESETS"

if [[ -n "$five_pct" || -n "$seven_pct" ]]; then
    parts_5h=$(format_window '5h' "$five_pct" "$five_res" 18000)
    parts_7d=$(format_window '7d' "$seven_pct" "$seven_res" 604800)
    rate_part=""
    [[ -n "$parts_5h" ]] && rate_part="$parts_5h"
    if [[ -n "$parts_7d" ]]; then
        [[ -n "$rate_part" ]] && rate_part+=" ${GRAY}·${RESET} "
        rate_part+="$parts_7d"
    fi
fi

# --- 7. Agent status ---
agent_part=""
agent_name="$J_AGENT_NAME"
if [[ -n "$agent_name" ]]; then
    agent_part="${BLUE}${BOLD}${agent_name}${RESET}"
    agent_compact=""
    local_sep=" ${GRAY}·${RESET} "
    if [[ -n "$pct_int" ]]; then
        agent_compact="${pct_color}${pct_int}%${RESET}${local_sep}"
    fi
    agent_in="$J_AGENT_IN"
    agent_out="$J_AGENT_OUT"
    in_fmt=$(format_tokens "${agent_in:-0}")
    out_fmt=$(format_tokens "${agent_out:-0}")
    [[ -z "$in_fmt" ]] && in_fmt="0"
    [[ -z "$out_fmt" ]] && out_fmt="0"
    agent_compact+="${DIM}in${RESET} ${WHITE}${in_fmt}${RESET}  ${DIM}out${RESET} ${WHITE}${out_fmt}${RESET}"
    agent_part+="${local_sep}${agent_compact}"
fi

# --- 7b. Subagent context ---
# One row per Task-tool subagent. Rows come from ONE tier per refresh: the
# tasks-feed state file when fresh (mtime within FEED_TTL), else per-agent
# transcript parsing. Tiers are never merged. A done signal (feed: non-active
# status or task gone; fallback: terminal stop_reason) stamps done_ts into the
# per-agent session cache; the row lingers green for DONE_LINGER seconds.
# FEED_TTL is defined with the output-cache key inputs above.
# @parity:threshold DONE_LINGER=30
DONE_LINGER=30

sa_status_is_active() {  # feed statuses that mean "done" — single place to adjust
    # Deny-list polarity: an unknown status means "working" (fail open to
    # visible), matching the fallback tier's terminal-stop-reason check; a
    # genuinely completed task that leaves the feed is still caught by the
    # disappeared-task done signal below.
    case "${1,,}" in
        completed|complete|done|finished|failed|cancelled|canceled|killed|stopped|error) return 1 ;;
        *)                                                                               return 0 ;;
    esac
}

build_sa_row() {  # used ctx_size model_id display state(working|done) effort -> appends row
    local sa_used="$1" sa_ctx_size="$2" sa_model="$3" sa_disp="$4" sa_state="$5" sa_effort="$6"
    [[ "$sa_used" =~ ^[0-9]+$ ]] || sa_used=0
    { [[ "$sa_ctx_size" =~ ^[0-9]+$ ]] && (( sa_ctx_size > 0 )); } || sa_ctx_size=200000
    # Render-sink scrub: strip control/escape bytes from the three untrusted display
    # fields so no source path (feed-live, feed-read-back, transcript-fallback) can
    # emit a terminal escape planted via a cache file. The sink scrubs only the
    # fields it names, so a newly added field inherits nothing automatically.
    sa_model=$(sa_sanitize_title "$sa_model")
    sa_disp=$(sa_sanitize_title "$sa_disp")
    # Bounded here rather than at ingest so every source path is capped, including
    # a record written by an older version. No real level exceeds 6 characters, so
    # this never truncates a legitimate value.
    sa_effort=$(sa_sanitize_title "$sa_effort")
    sa_effort="${sa_effort:0:16}"

    # Bar/pct clamp at 100%; the token label keeps the raw used value.
    local sa_pct_int=$(( sa_used * 100 / sa_ctx_size ))
    (( sa_pct_int < 0 )) && sa_pct_int=0
    (( sa_pct_int > 100 )) && sa_pct_int=100
    local sa_color sa_bar
    sa_color=$(pct_color_for "$sa_pct_int")
    sa_bar=$(render_bar "$sa_pct_int" "$sa_color")

    local sa_used_lbl sa_ctx_k sa_ctx_lbl
    sa_used_lbl=$(format_tokens "$sa_used")
    sa_ctx_k=$((sa_ctx_size / 1000))
    if (( sa_ctx_k >= 1000 )); then sa_ctx_lbl="$((sa_ctx_k / 1000))M"
    else                            sa_ctx_lbl="${sa_ctx_k}K"
    fi

    # Compact single-space separators — same segment style as the context bar.
    local sa_sep=" ${GRAY}·${RESET} "
    local sa_row="${sa_bar} ${sa_color}${sa_pct_int}%${RESET}${sa_sep}${WHITE}${sa_used_lbl}${RESET}${GRAY}/${sa_ctx_lbl}${RESET}"
    [[ -n "$sa_model" ]] && sa_row+="${sa_sep}${MAGENTA}$(prettify_model_id "$sa_model")${RESET}"
    # Present only when the feed reported an override; absence is meaningful, so
    # nothing is inferred from the session's own effort here.
    [[ -n "$sa_effort" ]] && sa_row+="${sa_sep}$(effort_color_for "$sa_effort")${sa_effort} effort${RESET}"
    (( ${#sa_disp} > 40 )) && sa_disp="${sa_disp:0:39}…"
    [[ -n "$sa_disp" ]] && sa_row+="${sa_sep}${BLUE}${sa_disp}${RESET}"
    if [[ "$sa_state" == "done" ]]; then
        sa_row+="${sa_sep}${GREEN}✓ done${RESET}"
    else
        sa_row+="${sa_sep}${YELLOW}○ working${RESET}"
    fi
    subagent_contents+=("$sa_row")
}

declare -a subagent_contents=()
sa_now=$(date +%s)
sa_sid_safe="${session_id//[^a-zA-Z0-9_-]/}"
feed_tier=false

if [[ -n "$sa_sid_safe" && "$_oc_ffresh" == "1" ]]; then
    # Parse the same content the output-cache key hashed, so the render always
    # matches its key even if the handler rewrote the file mid-refresh.
    feed_ok=$(printf '%s' "$_oc_fjson" | jq -r 'if type == "object" and ((.tasks // []) | type == "array") then "ok" else empty end' 2>/dev/null)
    if [[ "$feed_ok" == "ok" ]]; then
        feed_tier=true
        declare -a feed_candidates=()
        feed_seen_ids=$'\n'
        # Display resolution lives in the jq extraction (description -> type ->
        # name, first non-blank after sanitizing "|"/control chars to spaces),
        # so a hostile title can't corrupt the \x1f record join or "|" caches.
        # effort is scrubbed in the same place and for the same reason: a shell-level
        # sanitizer would run only after the read below has already split the record,
        # so a 0x1f byte or newline in the value would shift every field after it.
        # It is appended last in the tuple, never inserted mid-record.
        while IFS=$'\x1f' read -r ft_id ft_disp ft_status ft_model ft_win ft_tok ft_start ft_effort; do
            [[ -z "${ft_id}${ft_disp}${ft_status}${ft_model}" ]] && continue
            ft_id_safe="${ft_id//[^a-zA-Z0-9_-]/}"
            [[ -n "$ft_id_safe" ]] && feed_seen_ids+="${ft_id_safe}"$'\n'
            [[ "$ft_tok" =~ ^[0-9]+$ ]] || ft_tok=0
            # Task window when present, else the tiered resolver (absent model -> 200K).
            if [[ "$ft_win" =~ ^[0-9]+$ ]] && (( ft_win > 0 )); then
                ft_ctx="$ft_win"
            else
                ft_ctx=$(sa_ctx_for_model "$ft_model")
            fi
            ft_cache=""
            [[ -n "$ft_id_safe" ]] && ft_cache="${TMPDIR:-/tmp}/statusline-sa-${sa_sid_safe}-task-${ft_id_safe}.txt"
            ft_done=""
            if sa_status_is_active "$ft_status"; then
                ft_state="working"
            else
                ft_state="done"
                ft_prev_done=""
                if [[ -n "$ft_cache" ]] && sl_trusted_file "$ft_cache"; then
                    { IFS='|' read -r _fc1 _fc2 _fc3 _fc4 ft_prev_done _fc6 < "$ft_cache"; } 2>/dev/null
                fi
                [[ "$ft_prev_done" =~ ^[0-9]+$ ]] && ft_done="$ft_prev_done"
                [[ -z "$ft_done" ]] && ft_done="$sa_now"
            fi
            [[ -n "$ft_cache" ]] && sl_write_ok "$ft_cache" && printf '%s|%s|%s|%s|%s|%s' "$ft_tok" "$ft_ctx" "$ft_model" "$ft_disp" "$ft_done" "$ft_start" > "$ft_cache" 2>/dev/null
            [[ "$ft_state" == "done" ]] && (( sa_now - ft_done > DONE_LINGER )) && continue
            feed_candidates+=("${ft_start}"$'\x1f'"${ft_id}"$'\x1f'"${ft_tok}"$'\x1f'"${ft_ctx}"$'\x1f'"${ft_model}"$'\x1f'"${ft_disp}"$'\x1f'"${ft_state}"$'\x1f'"${ft_effort}")
        done < <(printf '%s' "$_oc_fjson" | jq -r '(.tasks // [])[] | select(type == "object") | [((.id // "") | tostring), (first([.description, .type, .name][] | (. // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ") | gsub("^ +| +$"; "") | select(. != "")) // ""), ((.status // "") | tostring), ((.model // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")), ((.contextWindowSize // "") | tostring), ((.tokenCount // 0) | tostring), ((.startTime // "") | tostring), ((.effort // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " "))] | join("\u001f")' 2>/dev/null)

        # A cached task id missing from a fresh feed is a done signal: stamp
        # done_ts on first observation, linger, then drop the cache entry.
        for fc_file in "${TMPDIR:-/tmp}/statusline-sa-${sa_sid_safe}-task-"*.txt; do
            sl_trusted_file "$fc_file" || continue
            fc_id="${fc_file##*-task-}"
            fc_id="${fc_id%.txt}"
            [[ "$feed_seen_ids" == *$'\n'"${fc_id}"$'\n'* ]] && continue
            fc_used=""; fc_win=""; fc_model=""; fc_disp=""; fc_done=""; fc_start=""
            { IFS='|' read -r fc_used fc_win fc_model fc_disp fc_done fc_start < "$fc_file"; } 2>/dev/null
            if [[ ! "$fc_done" =~ ^[0-9]+$ ]]; then
                fc_done="$sa_now"
                printf '%s|%s|%s|%s|%s|%s' "$fc_used" "$fc_win" "$fc_model" "$fc_disp" "$fc_done" "$fc_start" > "$fc_file" 2>/dev/null
            fi
            if (( sa_now - fc_done > DONE_LINGER )); then
                rm -f "$fc_file" 2>/dev/null
                continue
            fi
            feed_candidates+=("${fc_start}"$'\x1f'"${fc_id}"$'\x1f'"${fc_used}"$'\x1f'"${fc_win}"$'\x1f'"${fc_model}"$'\x1f'"${fc_disp}"$'\x1f'"done")
        done

        log_msg "subagents: feed tier, ${#feed_candidates[@]} row(s)"
        if (( ${#feed_candidates[@]} > 0 )); then
            # Deterministic order: startTime (ISO string sort), tiebreak id.
            while IFS=$'\x1f' read -r fr_start fr_id fr_used fr_ctx fr_model fr_disp fr_state fr_effort; do
                [[ -z "$fr_state" ]] && continue
                build_sa_row "$fr_used" "$fr_ctx" "$fr_model" "$fr_disp" "$fr_state" "$fr_effort"
            done < <(printf '%s\n' "${feed_candidates[@]}" | LC_ALL=C sort)
        fi
    fi
fi

# Fallback tier: per-agent transcripts under
# <project>/<sessionId>/subagents/agent-*.jsonl (+ sibling .meta.json).
if [[ "$feed_tier" != true && -n "$session_id" && -n "$transcript_path" ]]; then
    project_dir=$(dirname "$transcript_path")
    session_base=$(basename "$transcript_path" .jsonl)
    subagents_dir="$project_dir/$session_base/subagents"
    if [[ -d "$subagents_dir" ]]; then
        log_msg "subagents: fallback tier (feed absent/stale)"
        for sa_file in "$subagents_dir"/agent-*.jsonl; do
            [[ -f "$sa_file" ]] || continue

            sa_mt=$(stat -f %m "$sa_file" 2>/dev/null || echo 0)
            sa_age=$(( sa_now - sa_mt ))
            (( sa_age > 180 )) && continue

            sa_base=$(basename "$sa_file" .jsonl)
            sa_cache_path="${TMPDIR:-/tmp}/statusline-sa-${sa_sid_safe}-${sa_base}.txt"
            sa_use_cache=false
            sa_cache_dirty=false
            sa_done=""
            sa_prev_done=""

            if sl_trusted_file "$sa_cache_path"; then
                sc_mt=""; sc_sr=""; sc_in=""; sc_cw=""; sc_cr=""; sc_model=""; sc_display=""; sc_done=""
                { IFS='|' read -r sc_mt sc_sr sc_in sc_cw sc_cr sc_model sc_display sc_done < "$sa_cache_path"; } 2>/dev/null
                [[ "$sc_done" =~ ^[0-9]+$ ]] && sa_prev_done="$sc_done"
                if [[ "$sc_mt" == "$sa_mt" ]]; then
                    sa_sr="$sc_sr"; sa_in="$sc_in"; sa_cw="$sc_cw"; sa_cr="$sc_cr"
                    sa_model="$sc_model"; agent_display="$sc_display"; sa_done="$sa_prev_done"
                    sa_use_cache=true
                fi
            fi

            if [[ "$sa_use_cache" != true ]]; then
                # No assistant message yet -> zeros and no model id; the row
                # renders without the model segment for this refresh.
                sa_sr=""; sa_in=0; sa_cw=0; sa_cr=0; sa_model=""
                sa_last=$(jq -c 'select(.type == "assistant")' "$sa_file" 2>/dev/null | tail -1)
                if [[ -n "$sa_last" ]]; then
                    sa_fields=$(printf '%s' "$sa_last" | jq -r '"\(.message.stop_reason // "")|\(.message.usage.input_tokens // 0)|\(.message.usage.cache_creation_input_tokens // 0)|\(.message.usage.cache_read_input_tokens // 0)|\(.message.model // "")"' 2>/dev/null)
                    [[ -n "$sa_fields" ]] && IFS='|' read -r sa_sr sa_in sa_cw sa_cr sa_model <<< "$sa_fields"
                fi

                agent_display="${sa_base#agent-}"
                sa_meta="$subagents_dir/${sa_base}.meta.json"
                if [[ -f "$sa_meta" ]]; then
                    # Title chain: meta description -> agentType -> filename id
                    # (already set); each candidate sanitized before the blank test.
                    # Control chars are stripped inside jq like the feed tier: a raw
                    # NUL surviving into $(...) makes bash 4+ warn on stderr.
                    meta_desc=$(sa_sanitize_title "$(jq -r '(.description // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")' "$sa_meta" 2>/dev/null)")
                    if [[ -n "$meta_desc" ]]; then
                        agent_display="$meta_desc"
                    else
                        meta_type=$(sa_sanitize_title "$(jq -r '(.agentType // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")' "$sa_meta" 2>/dev/null)")
                        [[ -n "$meta_type" ]] && agent_display="$meta_type"
                    fi
                fi

                sa_done="$sa_prev_done"
                sa_cache_dirty=true
            fi
            [[ "$sa_in" =~ ^[0-9]+$ ]] || sa_in=0
            [[ "$sa_cw" =~ ^[0-9]+$ ]] || sa_cw=0
            [[ "$sa_cr" =~ ^[0-9]+$ ]] || sa_cr=0

            # Any terminal stop reason is a done signal; tool_use/pause_turn
            # (and no assistant message yet) mean working.
            case "$sa_sr" in
                end_turn|max_tokens|refusal|model_context_window_exceeded|stop_sequence) sa_state="done" ;;
                *)                                                                      sa_state="working" ;;
            esac
            if [[ "$sa_state" == "done" ]]; then
                if [[ -z "$sa_done" ]]; then
                    sa_done="$sa_now"
                    sa_cache_dirty=true
                fi
            else
                [[ -n "$sa_done" ]] && sa_cache_dirty=true
                sa_done=""
            fi

            [[ "$sa_cache_dirty" == true ]] && sl_write_ok "$sa_cache_path" && printf '%s|%s|%s|%s|%s|%s|%s|%s' "$sa_mt" "$sa_sr" "$sa_in" "$sa_cw" "$sa_cr" "$sa_model" "$agent_display" "$sa_done" > "$sa_cache_path" 2>/dev/null

            [[ "$sa_state" == "done" ]] && (( sa_now - sa_done > DONE_LINGER )) && continue

            build_sa_row "$((sa_in + sa_cw + sa_cr))" "$(sa_ctx_for_model "$sa_model")" "$sa_model" "$agent_display" "$sa_state"
        done
    fi
fi

# --- Assemble ---
# Two sections separated by heavy divider; thin ┼ between rows within a section.
# @parity:constant LABEL_W=7
LABEL_W=7

model_row="$model_part"
[[ -n "$effort_part" ]] && model_row+="${row_sep}${effort_part}"
[[ -n "$status_part" ]] && model_row+="${row_sep}${status_part}"

cost_row=""
parts=()
[[ -n "$cost_part" ]] && parts+=("$cost_part")
[[ -n "$msg_part" ]] && parts+=("$msg_part")
[[ -n "$duration_part" ]] && parts+=("$duration_part")
[[ -n "$rate_part" ]] && parts+=("$rate_part")
for ((j=0; j<${#parts[@]}; j++)); do
    (( j > 0 )) && cost_row+="${row_sep}"
    cost_row+="${parts[$j]}"
done

path_row="$cwd_part"
path_label="project"
if [[ -n "$git_part" ]]; then
    path_row+="${row_sep}${DIM}on${RESET} ${git_part}"
    path_label="repo"
fi

# Row specs: section index, label, content.
declare -a row_sections=() row_labels=() row_contents=() rows=() row_secs=()

row_sections+=(0); row_labels+=("$path_label"); row_contents+=("$path_row")
row_sections+=(0); row_labels+=("agent");   row_contents+=("$agent_part")
row_sections+=(1); row_labels+=("model");   row_contents+=("$model_row")
row_sections+=(1); row_labels+=("context"); row_contents+=("$ctx_bar_part")
row_sections+=(1); row_labels+=("tokens");  row_contents+=("$tokens_part")
for sa_content in "${subagent_contents[@]}"; do
    row_sections+=(1); row_labels+=("agent"); row_contents+=("$sa_content")
done
row_sections+=(1); row_labels+=("cost");    row_contents+=("$cost_row")

for i in "${!row_sections[@]}"; do
    content="${row_contents[$i]}"
    [[ -z "$content" ]] && continue

    label="${row_labels[$i]}"
    while (( ${#label} < LABEL_W )); do label+=" "; done

    inner=" ${DIM}${label}${RESET} ${GRAY}│${RESET}  ${content} "
    rows+=("$inner")
    row_secs+=("${row_sections[$i]}")
done

max_inner=30
for r in "${rows[@]}"; do
    vl=$(get_vis "$r")
    (( vl > max_inner )) && max_inner=$vl
done

heavy_horiz=$(repeat_char "━" "$max_inner")
top_rule="${GRAY}┏${heavy_horiz}┓${RESET}"
sec_div_rule="${GRAY}┣${heavy_horiz}┫${RESET}"
bot_rule="${GRAY}┗${heavy_horiz}┛${RESET}"

left_dash_count=$((LABEL_W + 1))
right_dash_count=$((max_inner - LABEL_W - 4))
(( right_dash_count < 1 )) && right_dash_count=1
left_dashes=$(repeat_char "─" "$left_dash_count")
right_dashes=$(repeat_char "─" "$right_dash_count")
row_div_rule="${GRAY}┃${RESET} ${GRAY}${left_dashes}${RESET}${GRAY}┼${RESET}${GRAY}${right_dashes}${RESET} ${GRAY}┃${RESET}"

output="$top_rule"
prev_sec=-1
first=true

for i in "${!rows[@]}"; do
    if [[ "$first" != true ]]; then
        if [[ "${row_secs[$i]}" != "$prev_sec" ]]; then
            output+=$'\n'"$sec_div_rule"
        else
            output+=$'\n'"$row_div_rule"
        fi
    fi
    first=false
    prev_sec="${row_secs[$i]}"

    r="${rows[$i]}"
    vis_len=$(get_vis "$r")
    pad_count=$((max_inner - vis_len))
    (( pad_count < 0 )) && pad_count=0
    padding=$(repeat_char " " "$pad_count")

    output+=$'\n'"${GRAY}┃${RESET}${r}${padding}${GRAY}┃${RESET}"
done

output+=$'\n'"$bot_rule"

# --- Threshold notifications ---
if [[ -n "$J_SESSION_ID" ]]; then
    _notify_state="${TMPDIR:-/tmp}/statusline-notify-${J_SESSION_ID//[^a-zA-Z0-9_-]/}.json"
    _ns_ctx=false _ns_rate=false _ns_rate_resets=""

    if sl_trusted_file "$_notify_state" && command -v jq &>/dev/null; then
        _ns_ctx=$(jq -r '.notified_context_high // false' "$_notify_state" 2>/dev/null)
        _ns_rate=$(jq -r '.notified_rate_limit // false' "$_notify_state" 2>/dev/null)
        _ns_rate_resets=$(jq -r '.last_rate_resets_at // ""' "$_notify_state" 2>/dev/null)
    fi

    _ctx_thresh=70 _rate_thresh=80
    if [[ -f "$HOME/.claude/notify-config.json" ]] && command -v jq &>/dev/null; then
        _ct=$(jq -r '.context_high.threshold // 70' "$HOME/.claude/notify-config.json" 2>/dev/null)
        _rt=$(jq -r '.rate_limit.threshold // 80' "$HOME/.claude/notify-config.json" 2>/dev/null)
        [[ "$_ct" =~ ^[0-9]+$ ]] && _ctx_thresh=$_ct
        [[ "$_rt" =~ ^[0-9]+$ ]] && _rate_thresh=$_rt
    fi

    _ctx_pct="${pct_int:-0}"
    _rate_max=0
    [[ -n "$five_pct" ]] && { _fp=${five_pct%.*}; (( _fp > _rate_max )) && _rate_max=$_fp; }
    [[ -n "$seven_pct" ]] && { _sp=${seven_pct%.*}; (( _sp > _rate_max )) && _rate_max=$_sp; }

    _rate_resets_now="${J_RATE_5H_RESETS}"
    [[ -n "$seven_pct" && -n "$five_pct" ]] && { _sp=${seven_pct%.*}; _fp=${five_pct%.*}; (( _sp > _fp )) && _rate_resets_now="${J_RATE_7D_RESETS}"; }
    [[ -z "$five_pct" && -n "$seven_pct" ]] && _rate_resets_now="${J_RATE_7D_RESETS}"

    _ns_changed=false
    NOTIFY_SCRIPT="$HOME/.claude/notify.sh"

    if (( _ctx_pct >= _ctx_thresh )) && [[ "$_ns_ctx" != "true" ]]; then
        [[ -x "$NOTIFY_SCRIPT" ]] && "$NOTIFY_SCRIPT" context_high "$_ctx_pct" &
        _ns_ctx=true; _ns_changed=true
        log_msg "notify: context_high fired at ${_ctx_pct}%"
    elif (( _ctx_pct < _ctx_thresh )) && [[ "$_ns_ctx" == "true" ]]; then
        _ns_ctx=false; _ns_changed=true
        log_msg "notify: context_high reset (${_ctx_pct}% < ${_ctx_thresh}%)"
    fi

    if [[ "$_rate_resets_now" != "$_ns_rate_resets" ]]; then
        _ns_rate=false; _ns_changed=true
        log_msg "notify: rate_limit reset (resets_at changed)"
    fi
    if (( _rate_max >= _rate_thresh )) && [[ "$_ns_rate" != "true" ]]; then
        [[ -x "$NOTIFY_SCRIPT" ]] && "$NOTIFY_SCRIPT" rate_limit "$_rate_max" &
        _ns_rate=true; _ns_changed=true
        log_msg "notify: rate_limit fired at ${_rate_max}%"
    fi

    if [[ "$_ns_changed" == true ]] && sl_write_ok "$_notify_state"; then
        printf '{"notified_context_high":%s,"notified_rate_limit":%s,"last_rate_resets_at":"%s"}' \
            "$_ns_ctx" "$_ns_rate" "$_rate_resets_now" > "$_notify_state" 2>/dev/null
    fi
fi

log_msg "about to write: chars=${#output}"
if [[ -n "$J_SESSION_ID" ]] && sl_write_ok "$_oc_path"; then
    printf '%s\n%s' "$_oc_key" "$output" > "$_oc_path" 2>/dev/null
fi
printf '%s' "$output"
log_msg "stdout write: OK"
exit 0
