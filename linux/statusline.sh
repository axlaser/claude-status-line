#!/usr/bin/env bash
# Claude Code statusLine for Linux: reads JSON on stdin, emits a box.

# @parity:constant CACHE_VERSION=2
CACHE_VERSION="2"

if ! command -v jq &>/dev/null; then
    printf '\033[31m[statusline: jq not found — install via your package manager]\033[0m'
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

# --- Debug logging ---
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
# Position note: windows/statusline.ps1 relocated its json-extract block to
# after the output-cache check (deferred-parse optimization, PowerShell-specific
# -- see docs/performance.md). The marker names still pair across platforms;
# the position deliberately does not.
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
    local _st_s="${2//[$'\x01'-$'\x1f'$'\x7f']/ }"
    _st_s="${_st_s//'|'/ }"
    _st_s="${_st_s#"${_st_s%%[! ]*}"}"
    _st_s="${_st_s%"${_st_s##*[! ]}"}"
    printf -v "$1" '%s' "$_st_s"
}
# @parity:sanitize-title-end

# Fork-free dirname/basename (POSIX semantics over /-separated paths): the
# subagents-dir path is rebuilt from the transcript path on every tick, and
# the external binaries cost a process each. Out-variable first, data after,
# same convention as the render helpers below.
sl_dirname() {  # out-var, path
    local _dn_p="$2"
    _dn_p="${_dn_p%"${_dn_p##*[!/]}"}"    # strip trailing slashes
    if [[ -z "$_dn_p" ]]; then
        # "" -> "."; "//" (exactly two slashes) stays "//" per GNU's
        # double-slash root; any other all-slashes run ("/", "///") -> "/"
        if [[ "$2" == '//' ]]; then printf -v "$1" '%s' '//'
        elif [[ -n "$2" ]]; then printf -v "$1" '%s' '/'
        else printf -v "$1" '%s' '.'; fi
        return
    fi
    if [[ "$_dn_p" != */* ]]; then printf -v "$1" '%s' '.'; return; fi
    _dn_p="${_dn_p%/*}"                    # drop the last component
    _dn_p="${_dn_p%"${_dn_p##*[!/]}"}"    # strip the separator run before it
    [[ -z "$_dn_p" && "$2" == //[!/]* ]] && _dn_p='//'   # "//x" -> "//" (GNU)
    printf -v "$1" '%s' "${_dn_p:-/}"
}

sl_basename() {  # out-var, path, optional suffix (not stripped when it is the whole name)
    local _bn_p="$2" _bn_s="${3-}"
    _bn_p="${_bn_p%"${_bn_p##*[!/]}"}"    # strip trailing slashes
    if [[ -z "$_bn_p" ]]; then
        # "" -> ""; "//" (exactly two slashes) stays "//" per GNU; any other
        # all-slashes run -> "/"
        if [[ "$2" == '//' ]]; then printf -v "$1" '%s' '//'
        elif [[ -n "$2" ]]; then printf -v "$1" '%s' '/'
        else printf -v "$1" '%s' ''; fi
        return
    fi
    _bn_p="${_bn_p##*/}"
    [[ -n "$_bn_s" && "$_bn_p" == *"$_bn_s" && "$_bn_p" != "$_bn_s" ]] && _bn_p="${_bn_p%"$_bn_s"}"
    printf -v "$1" '%s' "$_bn_p"
}

# --- Idle-state fast path ---
_oc_path="${TMPDIR:-/tmp}/statusline-oc-${J_SESSION_ID//[^a-zA-Z0-9_-]/}.txt"
_oc_now=${EPOCHSECONDS:-$(date +%s)}
_oc_gidx="${J_GIT_CWD:-.}/.git/index"
_oc_sdir=""
if [[ -n "$J_TRANSCRIPT_PATH" ]]; then
    sl_dirname _oc_pdir "$J_TRANSCRIPT_PATH"
    sl_basename _oc_pbase "$J_TRANSCRIPT_PATH" .jsonl
    _oc_sdir="${_oc_pdir}/${_oc_pbase}/subagents"
fi
# Feed content+freshness and the learned-map mtime join the key so subagent
# tier switches and learned window changes invalidate the render cache. The
# handler rewrites the feed file every tick, so keying on its mtime would
# defeat the output cache; mtime feeds only the freshness flag.
_oc_feed="${TMPDIR:-/tmp}/statusline-tasks-${J_SESSION_ID//[^a-zA-Z0-9_-]/}.json"
# @parity:cache FEED_TTL=10
FEED_TTL=10
MODEL_WINDOWS_PATH="$HOME/.claude/statusline-model-windows.json"
# One batched stat over every cache-key path that exists, results mapped back
# BY NAME: the mtime is the last space-separated token, everything before it
# is the path as we passed it (paths may contain spaces, never newlines --
# they come from the newline-split jq extraction). A path missing from the
# output -- vanished between the existence test and the stat -- degrades to
# the same empty value the old per-file call produced. The format flag is
# deliberately per-platform (GNU `-c '%n %Y'` here, BSD `-f '%N %m'` on macOS).
_oc_tmt="" _oc_gmt="" _oc_smt="" _oc_fmt="" _oc_mwmt=""
_oc_stat_paths=()
[[ -n "$J_TRANSCRIPT_PATH" && -f "$J_TRANSCRIPT_PATH" ]] && _oc_stat_paths+=("$J_TRANSCRIPT_PATH")
[[ -f "$_oc_gidx" ]] && _oc_stat_paths+=("$_oc_gidx")
[[ -n "$_oc_sdir" && -d "$_oc_sdir" ]] && _oc_stat_paths+=("$_oc_sdir")
[[ -f "$_oc_feed" ]] && _oc_stat_paths+=("$_oc_feed")
[[ -f "$MODEL_WINDOWS_PATH" ]] && _oc_stat_paths+=("$MODEL_WINDOWS_PATH")
if (( ${#_oc_stat_paths[@]} > 0 )); then
    _oc_stat_hits=0
    while IFS= read -r _oc_line; do
        [[ "$_oc_line" == *' '* ]] || continue
        _oc_val="${_oc_line##* }"
        [[ "$_oc_val" =~ ^[0-9]+$ ]] || continue
        case "${_oc_line% *}" in
            "$J_TRANSCRIPT_PATH")  _oc_tmt="$_oc_val";  _oc_stat_hits=$(( _oc_stat_hits + 1 )) ;;
            "$_oc_gidx")           _oc_gmt="$_oc_val";  _oc_stat_hits=$(( _oc_stat_hits + 1 )) ;;
            "$_oc_sdir")           _oc_smt="$_oc_val";  _oc_stat_hits=$(( _oc_stat_hits + 1 )) ;;
            "$_oc_feed")           _oc_fmt="$_oc_val";  _oc_stat_hits=$(( _oc_stat_hits + 1 )) ;;
            "$MODEL_WINDOWS_PATH") _oc_mwmt="$_oc_val"; _oc_stat_hits=$(( _oc_stat_hits + 1 )) ;;
        esac
    done < <(stat -c '%n %Y' "${_oc_stat_paths[@]}" 2>/dev/null)
    (( _oc_stat_hits == ${#_oc_stat_paths[@]} )) || log_msg "oc stat: mapped ${_oc_stat_hits}/${#_oc_stat_paths[@]} path(s)"
fi
_oc_ffresh=0
_oc_fjson=""
if [[ "$_oc_fmt" =~ ^[0-9]+$ ]] && (( _oc_now - _oc_fmt <= FEED_TTL )); then
    _oc_ffresh=1
    # Handler writes compact single-line JSON; the builtin read avoids a cat
    # fork on this every-tick path. Command group silences a redirect-open
    # failure if the file vanishes between the stat and the read.
    sl_trusted_file "$_oc_feed" && { IFS= read -r _oc_fjson < "$_oc_feed"; } 2>/dev/null
fi
# @parity:cache OUTPUT_BUCKET=5
read -r _oc_key _ < <(printf '%s' "${raw}|${_oc_tmt}|${_oc_gmt}|${_oc_smt}|${_oc_ffresh}|${_oc_fjson}|${_oc_mwmt}|$(( _oc_now / 5 ))" | sha256sum 2>/dev/null)

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

# Pure render helpers below return via `printf -v` into a caller-named
# out-variable (always $1, data args after it) instead of echoing into a $( )
# command substitution -- every substitution forks a subshell, and these run on
# every tick and every subagent row. The format string is always a fixed
# literal; untrusted data is only ever a %s/%d argument, never the format.
# Each helper's locals carry a unique short prefix (_ft_, _dn_, ...) that no
# other helper reuses: printf -v "$1" writes into whatever name the caller
# passed, and a same-named local in scope would shadow it and silently drop
# the caller's write.
format_tokens() {  # 1234567 -> "1.2M"; "0" for empty
    local _ft_n=$2
    [[ -z "$_ft_n" || "$_ft_n" == "0" ]] && { printf -v "$1" '%s' '0'; return; }
    if (( _ft_n >= 1000000 )); then
        printf -v "$1" '%d.%dM' "$(( _ft_n / 1000000 ))" "$(( (_ft_n % 1000000) / 100000 ))"
    elif (( _ft_n >= 1000 )); then
        printf -v "$1" '%d.%dK' "$(( _ft_n / 1000 ))" "$(( (_ft_n % 1000) / 100 ))"
    else
        printf -v "$1" '%d' "$_ft_n"
    fi
}

pct_color_for() {  # context percentage -> threshold color
    local _pc_pct=${2:-0}
# @parity:threshold CONTEXT_CRIT=85
# @parity:threshold CONTEXT_WARN=60
    if   (( _pc_pct >= 85 )); then printf -v "$1" '%s' "$RED"
    elif (( _pc_pct >= 60 )); then printf -v "$1" '%s' "$YELLOW"
    else                           printf -v "$1" '%s' "$GREEN"
    fi
}

effort_color_for() {  # reasoning effort level -> ladder color
    # Shared by the model row and every subagent row so the two can never drift.
    # Unknown values (including the integer form agent frontmatter allows) fall
    # through to WHITE rather than being rejected.
# @parity:effort-ladder-begin
    # Lowercased before matching so this agrees with PowerShell's switch, which is
    # case-insensitive by default (same idiom as sa_status_is_active).
    case "${2,,}" in
        low)    printf -v "$1" '%s' "$GRAY" ;;
        medium) printf -v "$1" '%s' "$WHITE" ;;
        high)   printf -v "$1" '%s' "$CYAN" ;;
        xhigh)  printf -v "$1" '%s' "$YELLOW" ;;
        max)    printf -v "$1" '%s' "$RED" ;;
        *)      printf -v "$1" '%s' "$WHITE" ;;
    esac
# @parity:effort-ladder-end
}

render_bar() {  # pct color -> filled/empty bar over bar_width cells
    local _rb_pct=${2:-0} _rb_color=$3 _rb_filled _rb_fill _rb_empty
    (( _rb_pct < 0 )) && _rb_pct=0
    (( _rb_pct > 100 )) && _rb_pct=100
    _rb_filled=$(( (bar_width * _rb_pct + 50) / 100 ))
    repeat_char _rb_fill "█" "$_rb_filled"
    repeat_char _rb_empty "░" "$(( bar_width - _rb_filled ))"
    printf -v "$1" '%s' "${_rb_color}${_rb_fill}${RESET}${BAR_EMPTY}${_rb_empty}${RESET}"
}

normalize_model_id() {  # strip trailing -YYYYMMDD date suffix
    local _nm_id="$2"
    [[ "$_nm_id" =~ -[0-9]{8}$ ]] && _nm_id="${_nm_id%-*}"
    printf -v "$1" '%s' "$_nm_id"
}

# @parity:base-id-begin
# Same-model comparison ONLY -- never a storage key and never a resolver-tier input.
# normalize_model_id is deliberately left narrow: its output is the learned map's key
# AND the string the variant-marker tier matches on, so teaching it to strip "[1m]"
# would rewrite every stored key and make that tier unreachable.
model_base_id() {
    local _mb_b
    normalize_model_id _mb_b "$2"
    _mb_b="${_mb_b%\[1m\]}"
    _mb_b="${_mb_b%-1m}"
    printf -v "$1" '%s' "${_mb_b,,}"
}
# @parity:base-id-end

prettify_model_id() {  # claude-sonnet-5 -> "Sonnet 5"; unknown -> cleaned id
    local _pm_id
    normalize_model_id _pm_id "$2"
    _pm_id="${_pm_id#claude-}"
    if [[ "$_pm_id" =~ ^(fable|opus|sonnet|haiku)-([0-9]+(-[0-9]+)*) ]]; then
        local _pm_fam="${BASH_REMATCH[1]}" _pm_ver="${BASH_REMATCH[2]//-/.}"
        printf -v "$1" '%s %s' "${_pm_fam^}" "$_pm_ver"
    else
        printf -v "$1" '%s' "$_pm_id"
    fi
}

# @parity:seed-table-begin
# Known model->window seeds; keys are normalized ids (date suffix stripped,
# claude- prefix tolerated). Unlisted ids fall through to the resolver tiers.
seed_window_for_model() {  # normalized model id -> window size or ""
    case "${2#claude-}" in
        fable-5|opus-4-8|opus-4-7|opus-4-6|sonnet-5|sonnet-4-6) printf -v "$1" '%s' 1000000 ;;
        haiku-4-5|sonnet-4-5|opus-4-5)                          printf -v "$1" '%s' 200000  ;;
        *)                                                      printf -v "$1" '%s' ''      ;;
    esac
}
# @parity:seed-table-end

sa_ctx_for_model() {  # tiered: session -> learned map -> seed table -> 1m marker -> 200K default
    local norm win="" _sa_base _sa_session_base
    normalize_model_id norm "$1"
    # Session inheritance leads: a subagent running the session's own model has the
    # session's window, which is live truth for this session -- it outranks a learned
    # entry, which is a historical observation that may have come from elsewhere or
    # been wrong when written. Compared on base ids so "[1m]" and the bare id match;
    # norm keeps its suffix for the marker tier below. Skipped entirely when the
    # session window is missing or non-positive, so nothing new can fail here.
    if [[ -n "$1" && -n "$J_MODEL_ID" && "$J_CTX_SIZE" =~ ^[0-9]+$ && "$J_CTX_SIZE" -gt 0 ]]; then
        model_base_id _sa_base "$1"
        model_base_id _sa_session_base "$J_MODEL_ID"
        if [[ "$_sa_base" == "$_sa_session_base" ]]; then
            log_msg "sa ctx: ${norm} -> ${J_CTX_SIZE} (session)"
            echo "$J_CTX_SIZE"
            return
        fi
    fi
    [[ -n "$norm" ]] && win="${MODEL_WINDOWS_MAP[$norm]:-}"
    if [[ "$win" =~ ^[0-9]+$ ]]; then
        log_msg "sa ctx: ${norm} -> ${win} (learned)"
        echo "$win"
        return
    fi
    seed_window_for_model win "$norm"
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
    local _gv_s="$2"
    _gv_s="${_gv_s//$'\033'\[*([0-9;])m/}"
    if [[ "$_gv_s" != *[![:ascii:]]* ]]; then
        printf -v "$1" '%d' "${#_gv_s}"
        return
    fi
    local _gv_n=${#_gv_s} _gv_w=0 _gv_i _gv_cp
    for ((_gv_i = 0; _gv_i < _gv_n; _gv_i++)); do
        printf -v _gv_cp '%d' "'${_gv_s:_gv_i:1}" 2>/dev/null || _gv_cp=0
        if (( (_gv_cp >= 0x1100 && _gv_cp <= 0x115F) || (_gv_cp >= 0x2E80 && _gv_cp <= 0xA4CF) ||
              (_gv_cp >= 0xAC00 && _gv_cp <= 0xD7A3) || (_gv_cp >= 0xF900 && _gv_cp <= 0xFAFF) ||
              (_gv_cp >= 0xFE30 && _gv_cp <= 0xFE4F) || (_gv_cp >= 0xFF00 && _gv_cp <= 0xFF60) ||
              (_gv_cp >= 0xFFE0 && _gv_cp <= 0xFFE6) || _gv_cp >= 0x1F000 )); then
            _gv_w=$(( _gv_w + 2 ))
        else
            _gv_w=$(( _gv_w + 1 ))
        fi
    done
    printf -v "$1" '%d' "$_gv_w"
}

repeat_char() {
    local _rc_pad=''
    (( ${3:-0} > 0 )) && printf -v _rc_pad '%*s' "$3" ''
    printf -v "$1" '%s' "${_rc_pad// /$2}"
}

# --- 1. CWD --- shorten under $HOME to ~/..., else .../parent/leaf
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

# --- 2. Model + context % --- thresholds 60/85 match the bar colors
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
    pct_color_for pct_color "$pct_int"
fi

model_part="${MAGENTA}${model_short}${RESET}"

# --- 2b. Context bar --- always rendered; missing used_pct -> 0%, missing ctx_size -> no token label
bar_width=30
bar_used_pct="${used_pct:-0}"
bar_pct_int="${pct_int:-0}"
bar_color="${pct_color}"
[[ -z "$pct_int" ]] && bar_color="$GREEN"
bar_pct_clamped="${bar_used_pct%.*}"
[[ -z "$bar_pct_clamped" ]] && bar_pct_clamped=0
(( bar_pct_clamped < 0 )) && bar_pct_clamped=0
(( bar_pct_clamped > 100 )) && bar_pct_clamped=100
render_bar bar "$bar_pct_clamped" "$bar_color"

token_suffix=""
if [[ -n "$ctx_size" ]]; then
    # Prefer total_input_tokens; ctx_size * used_percentage rounds to 10K steps on 1M windows.
    total_input_tokens="$J_TOTAL_INPUT_TOKENS"
    if [[ -n "$total_input_tokens" ]]; then
        used_tokens="$total_input_tokens"
    else
        used_tokens=$(( ctx_size * bar_pct_clamped / 100 ))
    fi
    format_tokens used_lbl "$used_tokens"
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
    normalize_model_id _mw_key "$J_MODEL_ID"
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
    effort_color_for _effort_color "$effort_level"
    effort_part="${_effort_color}${effort_level} effort${RESET}"
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
    git_index_mt=$(stat -c %Y "$git_index" 2>/dev/null || echo 0)
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
            gc_file_age=$(( _oc_now - $(stat -c %Y "$git_cache_path" 2>/dev/null || echo 0) ))
            # @parity:cache GIT_TTL=5
            if (( gc_file_age < 5 )); then
                branch="$gc_branch"; insertions="$gc_ins"; deletions="$gc_del"; untracked="$gc_unt"
                ahead="${gc_ahead:-0}"; behind="${gc_behind:-0}"; stash="${gc_stash:-0}"
                git_use_cache=true
            fi
        fi
    fi

    if [[ "$git_use_cache" != true ]]; then
        # One porcelain-v2 call covers branch, ahead/behind, stash, and untracked
        # (git >= 2.15 for --show-stash; on older git the call fails and the git
        # segment renders empty via the existing degradation path).
        branch=""
        head_oid=""
        v2_status=$(git --no-optional-locks -C "$git_cwd" status --porcelain=v2 --branch --show-stash 2>/dev/null) || v2_status=""
        if [[ -n "$v2_status" ]]; then
            while IFS= read -r v2_line; do
                case "$v2_line" in
                    '? '*) untracked=$(( untracked + 1 )) ;;
                    '# branch.head '*) branch="${v2_line#'# branch.head '}" ;;
                    '# branch.oid '*)  head_oid="${v2_line#'# branch.oid '}" ;;
                    '# branch.ab '*)
                        ab_rest="${v2_line#'# branch.ab '}"
                        ahead="${ab_rest%% *}"; ahead="${ahead#+}"
                        behind="${ab_rest##* }"; behind="${behind#-}"
                        ;;
                    '# stash '*) stash="${v2_line#'# stash '}" ;;
                esac
            done <<< "$v2_status"
            # Validate numerics before they reach arithmetic/render.
            [[ "$ahead"  =~ ^[0-9]+$ ]] || ahead=0
            [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
            [[ "$stash"  =~ ^[0-9]+$ ]] || stash=0
        fi
        if [[ "$branch" == "(detached)" ]]; then
            # Ask git for the abbreviation so the hash length always matches what
            # git would print (it lengthens abbreviations for uniqueness).
            branch=$(git --no-optional-locks -C "$git_cwd" rev-parse --short HEAD 2>/dev/null) || branch=""
            [[ -z "$branch" ]] && branch="HEAD"
        elif [[ "$head_oid" == "(initial)" ]]; then
            # Unborn HEAD: keep this platform's existing behaviour — no git segment
            # (Windows renders the literal 'HEAD') — do not reconcile.
            branch=""
        fi
        if [[ -n "$branch" ]]; then
            diff_stat=$(git --no-optional-locks -C "$git_cwd" diff --shortstat HEAD 2>/dev/null)
            if [[ -n "$diff_stat" ]]; then
                [[ "$diff_stat" =~ ([0-9]+)\ insertion ]] && insertions="${BASH_REMATCH[1]}"
                [[ "$diff_stat" =~ ([0-9]+)\ deletion ]]  && deletions="${BASH_REMATCH[1]}"
            fi
        fi
        sl_write_ok "$git_cache_path" && printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' "$git_index_mt" "$branch" "$insertions" "$deletions" "$untracked" "$ahead" "$behind" "$stash" > "$git_cache_path" 2>/dev/null
    fi
fi

# Scrub control/escape bytes from the branch (its cached value is plantable via
# statusline-git-*), mirroring the subagent render-sink scrub, before it renders.
sa_sanitize_title branch "$branch"
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

# --- 5. Cost + duration ---
format_cost() {  # out-fmt-var, out-gt-var, raw cost string -> "$X.YYYY" + 1/0 for > 0.50
    # bash printf %f both parses and renders under the active locale; pin
    # LC_ALL=C for the conversion and restore it (assignment or unset) so a
    # comma-decimal locale can neither misparse the input nor render a comma.
    # Deliberately not `local LC_ALL`: old bash does not reliably re-run
    # setlocale when a local locale variable goes out of scope.
    local _fc_restore=0 _fc_saved=""
    [[ -n "${LC_ALL+x}" ]] && { _fc_restore=1; _fc_saved="$LC_ALL"; }
    LC_ALL=C
    local _fc_num _fc_int _fc_frac="" _fc_gt=0
    # awk-style numeric coercion: longest numeric prefix, garbage -> 0. Keeps
    # printf off invalid input, which would write to stderr.
    if [[ "$3" =~ ^[[:space:]]*([+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?) ]]; then
        _fc_num="${BASH_REMATCH[1]}"
    else
        _fc_num=0
    fi
    printf -v "$1" '$%.4f' "$_fc_num"
# @parity:threshold COST_WARN=0.50
    # Scaled compare on the exact decimal digits (no float compare): > 0.50
    # means a nonzero integer part, or a fraction above "5 then any nonzero".
    # Exponent forms are normalized through %.10f first (still C locale).
    [[ "$_fc_num" == *[eE]* ]] && printf -v _fc_num '%.10f' "$_fc_num"
    if [[ "$_fc_num" != -* ]]; then
        _fc_num="${_fc_num#+}"
        _fc_int="${_fc_num%%.*}"
        [[ "$_fc_num" == *.* ]] && _fc_frac="${_fc_num#*.}"
        if [[ "$_fc_int" == *[1-9]* ]]; then
            _fc_gt=1
        else
            case "${_fc_frac:0:1}" in
                [6-9]) _fc_gt=1 ;;
                5)     [[ "${_fc_frac:1}" == *[1-9]* ]] && _fc_gt=1 ;;
            esac
        fi
    fi
    printf -v "$2" '%s' "$_fc_gt"
    if (( _fc_restore )); then LC_ALL="$_fc_saved"; else unset LC_ALL; fi
}

cost_part=""
total_cost="$J_TOTAL_COST"
[[ -z "$total_cost" ]] && total_cost="$J_TOTAL_COST_LEGACY"

if [[ -n "$total_cost" ]]; then
    format_cost cost_fmt cost_gt "$total_cost"
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
# Cached by mtime in $TMPDIR. Even on cache miss we read previous values to
# keep working_start_out_tokens stable and compute deltas.
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

    transcript_mt=$(stat -c %Y "$transcript_path" 2>/dev/null || echo 0)
    transcript_sz=$(stat -c %s "$transcript_path" 2>/dev/null || echo 0)
    use_cache=false
    prev_working_start=-1
    prev_in=0
    prev_cache_write=0
    prev_cache_read=0
    prev_out=0
    c_v2_ok=false

    if [[ -n "$cache_path" ]] && sl_trusted_file "$cache_path"; then  # read prev even on miss (for deltas + working_start)
        IFS='|' read -r c_ver c_mt c_sz c_msg c_idle c_in c_out c_wstart c_cwrite c_cread c_din c_dout c_dcw c_dcr c_off c_sum c_extra < "$cache_path"
        # Validate all numeric cache fields to prevent arithmetic injection.
        # Digit runs are length-bounded ({1,18}) so a planted value cannot
        # wrap 64-bit bash arithmetic (2^63 digits would pass an unbounded
        # match, wrap negative, and defeat the offset<=size bound below).
        [[ "$c_in" =~ ^-?[0-9]{1,18}$ ]] || c_in=0
        [[ "$c_out" =~ ^-?[0-9]{1,18}$ ]] || c_out=0
        [[ "$c_wstart" =~ ^-?[0-9]{1,18}$ ]] || c_wstart=-1
        [[ "$c_cwrite" =~ ^-?[0-9]{1,18}$ ]] || c_cwrite=0
        [[ "$c_cread" =~ ^-?[0-9]{1,18}$ ]] || c_cread=0
        [[ "$c_din" =~ ^-?[0-9]{1,18}$ ]] || c_din=0
        [[ "$c_dout" =~ ^-?[0-9]{1,18}$ ]] || c_dout=0
        [[ "$c_dcw" =~ ^-?[0-9]{1,18}$ ]] || c_dcw=0
        [[ "$c_dcr" =~ ^-?[0-9]{1,18}$ ]] || c_dcr=0
        [[ -n "$c_wstart" ]] && prev_working_start="$c_wstart"
        [[ -n "$c_in" ]] && prev_in="$c_in"
        [[ -n "$c_out" ]] && prev_out="$c_out"
        [[ -n "$c_cwrite" ]] && prev_cache_write="$c_cwrite"
        [[ -n "$c_cread" ]] && prev_cache_read="$c_cread"

        # Strict v2 structural validation: exactly 16 fields, integer offset
        # within [0, stored size], 64-hex head checksum (case-normalized). Any
        # failure -> untrusted record -> full-rescan miss. Gates both the cache
        # hit and the incremental-scan path.
        # Field map -- @parity:cache TRANSCRIPT_RECORD=v2/16-fields:
        # ver|mt|sz|msg|idle|in|out|wstart|cwrite|cread|din|dout|dcw|dcr|offset|headsum
        c_sum="${c_sum,,}"
        if [[ "$c_ver" == "$CACHE_VERSION" && -z "$c_extra" && "$c_msg" =~ ^[0-9]{1,9}$ && \
              ( "$c_idle" == "true" || "$c_idle" == "false" ) && "$c_sz" =~ ^[0-9]{1,18}$ && \
              "$c_off" =~ ^[0-9]{1,18}$ && "$c_sum" =~ ^[0-9a-f]{64}$ ]] && (( c_off <= c_sz )); then
            c_v2_ok=true
        else
            log_msg "transcript cache: record failed v2 validation -> full rescan"
        fi

        if [[ "$c_v2_ok" == true && "$c_mt" == "$transcript_mt" && "$c_sz" == "$transcript_sz" ]]; then
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
            # Single awk pass: counts real user messages, sums all token fields,
            # and decides idle-vs-working from the last real entry (synthetic
            # lines -- isMeta / <command-name> / <local-command-* / toolUseResult
            # -- do not vote; without that filter the detector stays stuck on
            # "working" after slash commands). Token values are extracted with
            # index()/substr() instead of copy+sub+sub regex chains; the LAST
            # "key": occurrence wins, with the same whitespace tolerance the old
            # greedy regexes had.
            # Incremental parse (v2 record): a trusted record whose stored head
            # checksum still matches lets the scan start at the stored byte
            # offset and accumulate onto the cached totals. Stored size > current
            # size (truncation) or a head mismatch (rewrite) forces a full
            # rescan. awk runs under LC_ALL=C so length() counts bytes --
            # offsets must stay byte-accurate on multibyte transcripts -- and a
            # trailing line without a newline is left unconsumed (gated on
            # total) for the next tick to re-read.
            scan_start=0
            scan_len=-1            # <0 -> no byte gating (size unknown)
            scan_init_idle=true
            scan_base_msg=0 scan_base_in=0 scan_base_cw=0 scan_base_cr=0 scan_base_out=0
            cmp_sum="" cmp_len=-1
            sz_ok=false
            [[ "$transcript_sz" =~ ^[0-9]+$ ]] && { sz_ok=true; scan_len="$transcript_sz"; }
            if [[ "$c_v2_ok" == true && "$sz_ok" == true ]] && (( c_sz <= transcript_sz && c_off <= transcript_sz )); then
                # The stored checksum covers min(4096, stored size) bytes; hash
                # the same span of the current file for the comparison.
                cmp_len=$(( c_sz < 4096 ? c_sz : 4096 ))
                read -r cmp_sum _ < <(head -c "$cmp_len" "$transcript_path" 2>/dev/null | sha256sum 2>/dev/null)
                if [[ -n "$cmp_sum" && "$cmp_sum" == "$c_sum" ]]; then
                    # Incremental: consume only bytes appended after the stored
                    # offset, on top of the cached totals; the cached verdict
                    # carries unless the delta contains a voting line.
                    scan_start="$c_off"
                    scan_len=$(( transcript_sz - c_off ))
                    scan_init_idle="$c_idle"
                    scan_base_msg="$c_msg"
                    scan_base_in="$prev_in"
                    scan_base_cw="$prev_cache_write"
                    scan_base_cr="$prev_cache_read"
                    scan_base_out="$prev_out"
                    log_msg "transcript: incremental from offset=$c_off (+$scan_len bytes)"
                else
                    log_msg "transcript: head checksum mismatch -> full rescan"
                fi
            elif [[ "$c_v2_ok" == true ]]; then
                log_msg "transcript: stored size/offset beyond current size -> full rescan"
            fi
            sl_awk_prog='
                function wskip(s, p, n) {  # first non-whitespace position at/after p
                    while (p <= n && index(" \t\n\r\f\v", substr(s, p, 1)) > 0) p++
                    return p
                }
                function tok(s, k,   n, off, i, p, c, v) {
                    # digits after the LAST `key\s*:\s*` occurrence ("" -> 0)
                    v = ""; n = length(s); off = 0
                    i = index(s, k)
                    while (i > 0) {
                        off += i
                        p = wskip(s, off + length(k), n)
                        if (substr(s, p, 1) == ":") {
                            p = wskip(s, p + 1, n)
                            v = ""
                            while (p <= n) {
                                c = substr(s, p, 1)
                                if (index("0123456789", c) == 0) break
                                v = v c; p++
                            }
                        }
                        i = index(substr(s, off + 1), k)
                    }
                    return v + 0
                }
                {
                    # Byte accounting: a line is consumed only when it fits inside
                    # the sampled size (total); the first line that does not fit is
                    # a torn or racing tail and stops consumption for the rest of
                    # the scan so the offset always covers an unbroken prefix.
                    if (total >= 0) {
                        rec = length($0) + 1
                        if (stop || pos + rec > total) { stop = 1; next }
                        pos += rec
                    } else pos += length($0) + 1
                }
                /"type"[[:space:]]*:[[:space:]]*"user"/ {
                    if ($0 !~ /"toolUseResult"/ &&
                        $0 !~ /"isMeta"[[:space:]]*:[[:space:]]*true/ &&
                        $0 !~ /<command-name>/ &&
                        $0 !~ /<local-command-stdout>/) mc++
                }
                /"type"[[:space:]]*:[[:space:]]*"assistant"/ {
                    if ((v = tok($0, "\"input_tokens\"")) > 0) inp += v
                    if ((v = tok($0, "\"cache_creation_input_tokens\"")) > 0) cw += v
                    if ((v = tok($0, "\"cache_read_input_tokens\"")) > 0) cr += v
                    if ((v = tok($0, "\"output_tokens\"")) > 0) out += v
                }
                $0 !~ /"isMeta"/ && $0 !~ /<command-name>/ &&
                $0 !~ /<local-command-/ && $0 !~ /toolUseResult/ {
                    # Last surviving entry votes -- the forward equivalent of the
                    # old reverse scan, keeping its bash-glob semantics exactly:
                    # no colon required after "type", isMeta filtered whatever
                    # its value, filters tested before entry type.
                    if ($0 ~ /"type".*"assistant"/) {
                        if ($0 ~ /"stop_reason".*"end_turn"/) idle = "true"
                        else idle = "false"
                    } else if ($0 ~ /"type".*"user"/) {
                        if ($0 ~ /Request interrupted by user/) idle = "true"
                        else idle = "false"
                    }
                }
                END {
                    # No voting entry in the scanned span -> the caller-provided
                    # verdict (cached on incremental, idle default on full) holds.
                    if (idle == "") idle = initidle
                    print mc+0, inp+0, cw+0, cr+0, out+0, idle, pos+0
                }
            '
            if (( scan_start > 0 )); then
                read -r a_mc a_in a_cw a_cr a_out a_idle a_pos < <(
                    tail -c +"$(( scan_start + 1 ))" "$transcript_path" 2>/dev/null |
                        LC_ALL=C awk -v total="$scan_len" -v initidle="$scan_init_idle" "$sl_awk_prog" 2>/dev/null
                )
            else
                read -r a_mc a_in a_cw a_cr a_out a_idle a_pos < <(
                    LC_ALL=C awk -v total="$scan_len" -v initidle="$scan_init_idle" "$sl_awk_prog" "$transcript_path" 2>/dev/null
                )
            fi
            [[ "$a_mc" =~ ^[0-9]+$ ]] || a_mc=0
            [[ "$a_in" =~ ^[0-9]+$ ]] || a_in=0
            [[ "$a_cw" =~ ^[0-9]+$ ]] || a_cw=0
            [[ "$a_cr" =~ ^[0-9]+$ ]] || a_cr=0
            [[ "$a_out" =~ ^[0-9]+$ ]] || a_out=0
            [[ "$a_idle" == "true" || "$a_idle" == "false" ]] || a_idle="$scan_init_idle"
            [[ "$a_pos" =~ ^[0-9]+$ ]] || a_pos=0
            msg_count=$(( scan_base_msg + a_mc ))
            session_in_tokens=$(( scan_base_in + a_in ))
            session_cache_write_tokens=$(( scan_base_cw + a_cw ))
            session_cache_read_tokens=$(( scan_base_cr + a_cr ))
            session_out_tokens=$(( scan_base_out + a_out ))
            claude_is_idle="$a_idle"
            new_offset=$(( scan_start + a_pos ))

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
                # Head checksum for the new record: min(4096, current size)
                # bytes, reusing this tick's comparison hash when it already
                # covers the same span. An unknown size stores an empty checksum,
                # which fails v2 validation next tick -> full rescan (safe).
                head_sum=""
                if [[ "$sz_ok" == true ]]; then
                    store_len=$(( transcript_sz < 4096 ? transcript_sz : 4096 ))
                    if [[ -n "$cmp_sum" && "$cmp_len" == "$store_len" ]]; then
                        head_sum="$cmp_sum"
                    else
                        read -r head_sum _ < <(head -c "$store_len" "$transcript_path" 2>/dev/null | sha256sum 2>/dev/null)
                    fi
                fi
                printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
                    "$CACHE_VERSION" "$transcript_mt" "$transcript_sz" "$msg_count" "$claude_is_idle" \
                    "$session_in_tokens" "$session_out_tokens" \
                    "$working_start_out_tokens" "$session_cache_write_tokens" \
                    "$session_cache_read_tokens" "$delta_in" "$delta_out" \
                    "$delta_cache_write" "$delta_cache_read" \
                    "$new_offset" "$head_sum" > "$cache_path" 2>/dev/null
            fi
        fi
    fi
fi

format_bucket() {  # label, value, delta, idle_color, active_color [, arrow]
    local _fb_label="$2" _fb_value="$3" _fb_delta="$4" _fb_idle_color="$5" _fb_active_color="$6" _fb_arrow="$7"
    local _fb_lbl _fb_d_lbl _fb_arrow_part=""
    format_tokens _fb_lbl "$_fb_value"
    format_tokens _fb_d_lbl "$_fb_delta"
    [[ -z "$_fb_d_lbl" ]] && _fb_d_lbl="0"
    [[ -n "$_fb_arrow" ]] && _fb_arrow_part="${GRAY}${_fb_arrow}${RESET}"
    if (( _fb_delta > 0 )); then
        printf -v "$1" '%s' "${_fb_active_color}${BOLD}${_fb_label}${RESET}${_fb_arrow_part} ${_fb_active_color}${_fb_lbl}${RESET} ${GREEN}(+${_fb_d_lbl})${RESET}"
    else
        printf -v "$1" '%s' "${DIM}${_fb_label}${RESET}${_fb_arrow_part} ${_fb_idle_color}${_fb_lbl}${RESET} ${DIM}(+${_fb_d_lbl})${RESET}"
    fi
}

# Tokens row -- always render; zero values get the dim "(+0)" idle styling.
row_sep=" ${GRAY}·${RESET} "
format_bucket tokens_part "in" "$session_in_tokens" "$delta_in" "$CYAN" "$CYAN"
format_bucket _bucket "cache" "$session_cache_write_tokens" "$delta_cache_write" "$GRAY" "$YELLOW" "↑"
tokens_part+="${row_sep}${_bucket}"
format_bucket _bucket "cache" "$session_cache_read_tokens" "$delta_cache_read" "$GRAY" "$CYAN" "↓"
tokens_part+="${row_sep}${_bucket}"
format_bucket _bucket "out" "$session_out_tokens" "$delta_out" "$MAGENTA" "$MAGENTA"
tokens_part+="${row_sep}${_bucket}"

# Status (idle/working) for the model row.
if [[ "$claude_is_idle" == true ]]; then
    status_dot="${GREEN}●${RESET}"
    status_label="${WHITE}ready${RESET}"
    status_part="${status_dot}  ${status_label}"
else
    status_dot="${YELLOW}○${RESET}"
    status_label="${YELLOW}working${RESET}"
    status_part="${status_dot}  ${status_label}"
fi

# Message count for the cost row.
msg_part=""
if [[ -n "$msg_count" && "$msg_count" -gt 0 ]] 2>/dev/null; then
    msg_label="messages"
    (( msg_count == 1 )) && msg_label="message"
    msg_part="${WHITE}${msg_count}${RESET} ${DIM}${msg_label}${RESET}"
fi

# --- 6. Rate limits (5h + 7d) ---
format_duration() {  # secs -> 45m / 2h / 2h30m / 3d / 3d4h
    local _fd_secs=$2
    printf -v "$1" '%s' ''
    (( _fd_secs <= 0 )) && return
    if (( _fd_secs < 3600 )); then
        printf -v "$1" '%dm' "$(( _fd_secs / 60 ))"
    elif (( _fd_secs < 86400 )); then
        local _fd_h=$(( _fd_secs / 3600 ))
        local _fd_m=$(( (_fd_secs - _fd_h * 3600) / 60 ))
        if (( _fd_m == 0 )); then printf -v "$1" '%dh' "$_fd_h"; else printf -v "$1" '%dh%dm' "$_fd_h" "$_fd_m"; fi
    else
        local _fd_d=$(( _fd_secs / 86400 ))
        local _fd_h=$(( (_fd_secs - _fd_d * 86400) / 3600 ))
        if (( _fd_h == 0 )); then printf -v "$1" '%dd' "$_fd_d"; else printf -v "$1" '%dd%dh' "$_fd_d" "$_fd_h"; fi
    fi
}

# Render one window. Burn arrow: usage % vs on-pace % (elapsed/window).
# Up = burning faster than reset; tiny diffs (<1%) are hidden.
format_window() {
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
        now=${EPOCHSECONDS:-$(date +%s)}
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
            format_duration r_lbl "$remaining"
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

# --- 7. Agent / subagent status ---
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
    format_tokens in_fmt "${agent_in:-0}"
    format_tokens out_fmt "${agent_out:-0}"
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
    sa_sanitize_title sa_model "$sa_model"
    sa_sanitize_title sa_disp "$sa_disp"
    # Bounded here rather than at ingest so every source path is capped, including
    # a record written by an older version. No real level exceeds 6 characters, so
    # this never truncates a legitimate value.
    sa_sanitize_title sa_effort "$sa_effort"
    sa_effort="${sa_effort:0:16}"

    # Bar/pct clamp at 100%; the token label keeps the raw used value.
    local sa_pct_int=$(( sa_used * 100 / sa_ctx_size ))
    (( sa_pct_int < 0 )) && sa_pct_int=0
    (( sa_pct_int > 100 )) && sa_pct_int=100
    local sa_color sa_bar
    pct_color_for sa_color "$sa_pct_int"
    render_bar sa_bar "$sa_pct_int" "$sa_color"

    local sa_used_lbl sa_ctx_k sa_ctx_lbl sa_model_pretty sa_effort_color
    format_tokens sa_used_lbl "$sa_used"
    sa_ctx_k=$((sa_ctx_size / 1000))
    if (( sa_ctx_k >= 1000 )); then sa_ctx_lbl="$((sa_ctx_k / 1000))M"
    else                            sa_ctx_lbl="${sa_ctx_k}K"
    fi

    # Compact single-space separators — same segment style as the context bar.
    local sa_sep=" ${GRAY}·${RESET} "
    local sa_row="${sa_bar} ${sa_color}${sa_pct_int}%${RESET}${sa_sep}${WHITE}${sa_used_lbl}${RESET}${GRAY}/${sa_ctx_lbl}${RESET}"
    if [[ -n "$sa_model" ]]; then
        prettify_model_id sa_model_pretty "$sa_model"
        sa_row+="${sa_sep}${MAGENTA}${sa_model_pretty}${RESET}"
    fi
    # Present only when the feed reported an override; absence is meaningful, so
    # nothing is inferred from the session's own effort here.
    if [[ -n "$sa_effort" ]]; then
        effort_color_for sa_effort_color "$sa_effort"
        sa_row+="${sa_sep}${sa_effort_color}${sa_effort} effort${RESET}"
    fi
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
sa_now=${EPOCHSECONDS:-$(date +%s)}
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
            [[ -n "$ft_cache" ]] && sl_write_ok "$ft_cache" && printf '%s|%s|%s|%s|%s|%s|%s' "$ft_tok" "$ft_ctx" "$ft_model" "$ft_disp" "$ft_done" "$ft_start" "$ft_effort" > "$ft_cache" 2>/dev/null
            [[ "$ft_state" == "done" ]] && (( sa_now - ft_done > DONE_LINGER )) && continue
            feed_candidates+=("${ft_start}"$'\x1f'"${ft_id}"$'\x1f'"${ft_tok}"$'\x1f'"${ft_ctx}"$'\x1f'"${ft_model}"$'\x1f'"${ft_disp}"$'\x1f'"${ft_state}"$'\x1f'"${ft_effort}")
        done < <(printf '%s' "$_oc_fjson" | jq -r '(.tasks // [])[] | select(type == "object") | [((.id // "") | tostring), (first([.description, .type, .name][] | (. // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ") | gsub("^ +| +$"; "") | select(. != "")) // ""), ((.status // "") | tostring), ((.model // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")), ((.contextWindowSize // "") | tostring), ((.tokenCount // 0) | tostring), ((.startTime // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")), ((.effort // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " "))] | join("\u001f")' 2>/dev/null)

        # A cached task id missing from a fresh feed is a done signal: stamp
        # done_ts on first observation, linger, then drop the cache entry.
        for fc_file in "${TMPDIR:-/tmp}/statusline-sa-${sa_sid_safe}-task-"*.txt; do
            sl_trusted_file "$fc_file" || continue
            fc_id="${fc_file##*-task-}"
            fc_id="${fc_id%.txt}"
            [[ "$feed_seen_ids" == *$'\n'"${fc_id}"$'\n'* ]] && continue
            # Pre-clear every field: the read below can fail after sl_trusted_file
            # already passed, and a variable left unset would inherit the previous
            # iteration's cache file, attributing one task's effort to another.
            fc_used=""; fc_win=""; fc_model=""; fc_disp=""; fc_done=""; fc_start=""; fc_effort=""
            { IFS='|' read -r fc_used fc_win fc_model fc_disp fc_done fc_start fc_effort < "$fc_file"; } 2>/dev/null
            if [[ ! "$fc_done" =~ ^[0-9]+$ ]]; then
                fc_done="$sa_now"
                printf '%s|%s|%s|%s|%s|%s|%s' "$fc_used" "$fc_win" "$fc_model" "$fc_disp" "$fc_done" "$fc_start" "$fc_effort" > "$fc_file" 2>/dev/null
            fi
            if (( sa_now - fc_done > DONE_LINGER )); then
                rm -f "$fc_file" 2>/dev/null
                continue
            fi
            feed_candidates+=("${fc_start}"$'\x1f'"${fc_id}"$'\x1f'"${fc_used}"$'\x1f'"${fc_win}"$'\x1f'"${fc_model}"$'\x1f'"${fc_disp}"$'\x1f'"done"$'\x1f'"${fc_effort}")
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
    sl_dirname project_dir "$transcript_path"
    sl_basename session_base "$transcript_path" .jsonl
    subagents_dir="$project_dir/$session_base/subagents"
    if [[ -d "$subagents_dir" ]]; then
        log_msg "subagents: fallback tier (feed absent/stale)"
        for sa_file in "$subagents_dir"/agent-*.jsonl; do
            [[ -f "$sa_file" ]] || continue

            sa_mt=$(stat -c %Y "$sa_file" 2>/dev/null || echo 0)
            sa_age=$(( sa_now - sa_mt ))
            (( sa_age > 180 )) && continue

            sl_basename sa_base "$sa_file" .jsonl
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
                    meta_desc=$(jq -r '(.description // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")' "$sa_meta" 2>/dev/null)
                    sa_sanitize_title meta_desc "$meta_desc"
                    if [[ -n "$meta_desc" ]]; then
                        agent_display="$meta_desc"
                    else
                        meta_type=$(jq -r '(.agentType // "") | tostring | gsub("[\\x00-\\x1f\\x7f|]"; " ")' "$sa_meta" 2>/dev/null)
                        sa_sanitize_title meta_type "$meta_type"
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

# --- Assemble box ---
# (section, label, content) tuples. Empty content is skipped; sections are split by ┣┫.
# @parity:constant LABEL_W=7
LABEL_W=7

# Compose merged rows

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

# 30 = bar width, the minimum row width.
max_inner=30
# Visible widths are computed once here and reused by the padding pass below.
declare -a row_vis=()
for r in "${rows[@]}"; do
    get_vis vl "$r"
    row_vis+=("$vl")
    (( vl > max_inner )) && max_inner=$vl
done

repeat_char heavy_horiz "━" "$max_inner"
top_rule="${GRAY}┏${heavy_horiz}┓${RESET}"
sec_div_rule="${GRAY}┣${heavy_horiz}┫${RESET}"
bot_rule="${GRAY}┗${heavy_horiz}┛${RESET}"

left_dash_count=$((LABEL_W + 1))
right_dash_count=$((max_inner - LABEL_W - 4))
(( right_dash_count < 1 )) && right_dash_count=1
repeat_char left_dashes "─" "$left_dash_count"
repeat_char right_dashes "─" "$right_dash_count"
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
    vis_len="${row_vis[$i]}"
    pad_count=$((max_inner - vis_len))
    (( pad_count < 0 )) && pad_count=0
    repeat_char padding " " "$pad_count"

    output+=$'\n'"${GRAY}┃${RESET}${r}${padding}${GRAY}┃${RESET}"
done

output+=$'\n'"$bot_rule"

# --- Threshold notifications ---
if [[ -n "$J_SESSION_ID" ]]; then
    _notify_state="${TMPDIR:-/tmp}/statusline-notify-${J_SESSION_ID//[^a-zA-Z0-9_-]/}.json"
    _ns_ctx=false _ns_rate=false _ns_rate_resets="" _ns_usable=true

    if sl_trusted_file "$_notify_state" && command -v jq &>/dev/null; then
        # One jq pass emits all three latch fields as a single US-delimited
        # record (control chars scrubbed jq-side so an embedded 0x1f or
        # newline cannot shift fields -- the feed-tier record convention),
        # consumed by one read. A non-object or unparseable file emits
        # nothing, leaving every field blank like the old per-field calls.
        { IFS=$'\x1f' read -r _ns_ctx _ns_rate _ns_rate_resets < <(jq -r 'if type != "object" then error("not a JSON object") else [((.notified_context_high // false) | tostring | gsub("[\\x00-\\x1f\\x7f]"; " ")), ((.notified_rate_limit // false) | tostring | gsub("[\\x00-\\x1f\\x7f]"; " ")), ((.last_rate_resets_at // "") | tostring | gsub("[\\x00-\\x1f\\x7f]"; " "))] | join("\u001f") end' "$_notify_state" 2>/dev/null); } 2>/dev/null
        # Fail closed when the file exists but cannot be parsed: a torn read leaves
        # these empty, and empty != "true", so the latches would look like "never
        # notified" and re-fire the alert on every refresh while the collision lasts.
        # Skip notifying this refresh instead; the next one reads a whole file.
        [[ "$_ns_ctx" == "true" || "$_ns_ctx" == "false" ]] || _ns_usable=false
    fi

    _ctx_thresh=70 _rate_thresh=80
    if [[ -f "$HOME/.claude/notify-config.json" ]] && command -v jq &>/dev/null; then
        # Same single-record shape for the two thresholds. The `?` keeps a
        # per-field error (e.g. .context_high is a number) scoped to that
        # field -- the old per-call layout defaulted only the broken field,
        # and one shared call must not widen that blast radius.
        { IFS=$'\x1f' read -r _ct _rt < <(jq -r 'if type != "object" then error("not a JSON object") else [((.context_high.threshold? // 70) | tostring | gsub("[\\x00-\\x1f\\x7f]"; " ")), ((.rate_limit.threshold? // 80) | tostring | gsub("[\\x00-\\x1f\\x7f]"; " "))] | join("\u001f") end' "$HOME/.claude/notify-config.json" 2>/dev/null); } 2>/dev/null
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

    if [[ "$_ns_usable" == true ]] && (( _ctx_pct >= _ctx_thresh )) && [[ "$_ns_ctx" != "true" ]]; then
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
    if [[ "$_ns_usable" == true ]] && (( _rate_max >= _rate_thresh )) && [[ "$_ns_rate" != "true" ]]; then
        [[ -x "$NOTIFY_SCRIPT" ]] && "$NOTIFY_SCRIPT" rate_limit "$_rate_max" &
        _ns_rate=true; _ns_changed=true
        log_msg "notify: rate_limit fired at ${_rate_max}%"
    fi

    if [[ "$_ns_usable" == true && "$_ns_changed" == true ]] && sl_write_ok "$_notify_state"; then
        # Atomic write: temp file then rename, so a concurrent refresh never observes
        # a truncated latch file. A plain redirect truncates in place, which left the
        # file momentarily empty on every refresh (mirrors subagent-statusline.sh).
        _ns_tmp="${_notify_state}.tmp.$$"
        if printf '{"notified_context_high":%s,"notified_rate_limit":%s,"last_rate_resets_at":"%s"}' \
            "$_ns_ctx" "$_ns_rate" "$_rate_resets_now" > "$_ns_tmp" 2>/dev/null; then
            mv -f "$_ns_tmp" "$_notify_state" 2>/dev/null || rm -f "$_ns_tmp" 2>/dev/null
        else
            rm -f "$_ns_tmp" 2>/dev/null
        fi
    fi
fi

log_msg "about to write: chars=${#output}"
if [[ -n "$J_SESSION_ID" ]] && sl_write_ok "$_oc_path"; then
    printf '%s\n%s' "$_oc_key" "$output" > "$_oc_path" 2>/dev/null
fi
printf '%s' "$output"
log_msg "stdout write: OK"
exit 0
