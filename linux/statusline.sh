#!/usr/bin/env bash
# Claude Code statusLine script for Linux (bash/zsh)
# Receives JSON on stdin from Claude Code, emits UTF-8 lines.

# ── Dependency check ──────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    printf '\033[31m[statusline: jq not found — install via your package manager]\033[0m'
    exit 0
fi

# ── ANSI helpers ──────────────────────────────────────────────────────────────
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

# ── Debug logging ─────────────────────────────────────────────────────────────
LOG_PATH="$HOME/.claude/statusline-debug.log"
log_msg() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH" 2>/dev/null
}
log_msg "=== invoked, BASH_VERSION=$BASH_VERSION PID=$$ ==="

# ── Read stdin ────────────────────────────────────────────────────────────────
raw=$(cat)
log_msg "stdin bytes=${#raw}"
log_msg "stdin head: ${raw:0:400}"

if ! printf '%s' "$raw" | jq -e '.' &>/dev/null; then
    log_msg "READ/PARSE FAILED"
    printf '%s' "${RED}[statusline: bad JSON]${RESET}"
    exit 0
fi
log_msg "json parse: OK"

# ── Helper: safe jq access ───────────────────────────────────────────────────
jval() {
    local result
    result=$(printf '%s' "$raw" | jq -r "$1 // empty" 2>/dev/null)
    if [[ -z "$result" || "$result" == "null" ]]; then
        printf '%s' "${2:-}"
    else
        printf '%s' "$result"
    fi
}

# ── Helper: human-readable token count (e.g. 1234567 → "1.2M") ───────────────
format_tokens() {
    local n=$1
    [[ -z "$n" || "$n" == "0" ]] && return
    if (( n >= 1000000 )); then
        awk "BEGIN { printf \"%.1fM\", $n / 1000000.0 }"
    elif (( n >= 1000 )); then
        awk "BEGIN { printf \"%.1fK\", $n / 1000.0 }"
    else
        printf '%d' "$n"
    fi
}

# ── Helper: strip ANSI for visible-width calculation ─────────────────────────
get_vis() {
    local stripped
    stripped=$(printf '%s' "$1" | perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g')
    printf '%d' "${#stripped}"
}

# ── Helper: repeat a character N times ────────────────────────────────────────
repeat_char() {
    local ch="$1" count="$2" out=""
    for ((i = 0; i < count; i++)); do out+="$ch"; done
    printf '%s' "$out"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. CWD — shortened relative to $HOME
# ═══════════════════════════════════════════════════════════════════════════════
session_id=$(jval '.session_id')
cwd=$(jval '.workspace.current_dir')
[[ -z "$cwd" ]] && cwd=$(jval '.cwd')
[[ -z "$cwd" ]] && cwd="$PWD"

if [[ "$cwd" == "$HOME"* ]]; then
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

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Model + Context window %
# ═══════════════════════════════════════════════════════════════════════════════
model_display=$(jval '.model.display_name')

model_short="$model_display"
if [[ -n "$model_short" ]]; then
    model_short="${model_short#Claude }"
    model_short="${model_short:0:24}"
else
    model_short="unknown"
fi

ctx_size=$(jval '.context_window.context_window_size')
used_pct=$(jval '.context_window.used_percentage')

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
    pct_int=$(printf '%.0f' "$used_pct")
    if (( pct_int >= 85 )); then   pct_color="$RED"
    elif (( pct_int >= 60 )); then pct_color="$YELLOW"
    else                           pct_color="$GREEN"
    fi
fi

model_part="${MAGENTA}${model_short}${RESET}"

# ═══════════════════════════════════════════════════════════════════════════════
# 2b. Context bar — colored progress bar for context-window usage
# ═══════════════════════════════════════════════════════════════════════════════
ctx_bar_part=""
if [[ -n "$pct_int" ]]; then
    bar_width=30
    filled=$(awk "BEGIN { v = $used_pct; if (v<0) v=0; if (v>100) v=100; printf \"%d\", int($bar_width * v / 100 + 0.5) }")
    (( filled > bar_width )) && filled=$bar_width
    (( filled < 0 )) && filled=0
    empty_count=$((bar_width - filled))

    filled_chars=$(repeat_char "█" "$filled")
    empty_chars=$(repeat_char "░" "$empty_count")
    bar="${pct_color}${filled_chars}${RESET}${GRAY}${empty_chars}${RESET}"

    token_suffix=""
    if [[ -n "$ctx_size" ]]; then
        used_tokens=$(awk "BEGIN { v=$used_pct; if(v<0)v=0; if(v>100)v=100; printf \"%d\", int($ctx_size * v / 100) }")
        if (( used_tokens >= 1000000 )); then
            used_lbl=$(awk "BEGIN { printf \"%.1fM\", $used_tokens / 1000000.0 }")
        elif (( used_tokens >= 1000 )); then
            used_lbl=$(awk "BEGIN { printf \"%.0fK\", $used_tokens / 1000.0 }")
        else
            used_lbl="$used_tokens"
        fi
        token_suffix=" ${GRAY}·${RESET} ${WHITE}${used_lbl}${RESET}${GRAY}/${ctx_label}${RESET}"
    fi

    ctx_bar_part="${bar} ${pct_color}${pct_int}%${RESET}${token_suffix}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Reasoning effort level
# ═══════════════════════════════════════════════════════════════════════════════
effort_level=$(jval '.effort.level')
effort_part=""
if [[ -n "$effort_level" ]]; then
    case "$effort_level" in
        low)    effort_color="$GRAY" ;;
        medium) effort_color="$WHITE" ;;
        high)   effort_color="$CYAN" ;;
        xhigh)  effort_color="$YELLOW" ;;
        max)    effort_color="$RED" ;;
        *)      effort_color="$WHITE" ;;
    esac
    effort_part="${effort_color}${effort_level} effort${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Git status — branch + diff stats + untracked count
# ═══════════════════════════════════════════════════════════════════════════════
git_part=""
git_cwd=$(jval '.workspace.current_dir')
[[ -z "$git_cwd" ]] && git_cwd="$PWD"

git_dir="${git_cwd}/.git"
branch=""
insertions=0
deletions=0
untracked=0

if [[ -d "$git_dir" ]]; then
    branch=$(git --no-optional-locks -C "$git_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    if [[ -n "$branch" ]]; then
        diff_stat=$(git --no-optional-locks -C "$git_cwd" diff --shortstat HEAD 2>/dev/null)
        if [[ -n "$diff_stat" ]]; then
            [[ "$diff_stat" =~ ([0-9]+)\ insertion ]] && insertions="${BASH_REMATCH[1]}"
            [[ "$diff_stat" =~ ([0-9]+)\ deletion ]]  && deletions="${BASH_REMATCH[1]}"
        fi
        untracked=$(git --no-optional-locks -C "$git_cwd" status --porcelain 2>/dev/null | grep -c '^??' || true)
    fi
fi

if [[ -n "$branch" ]]; then
    is_dirty=false
    (( insertions > 0 || deletions > 0 || untracked > 0 )) && is_dirty=true
    if $is_dirty; then branch_color="$YELLOW"; else branch_color="$GREEN"; fi

    git_part="${branch_color}${branch}${RESET}"
    (( insertions > 0 )) && git_part+=" ${GREEN}+${insertions}${RESET}"
    (( deletions > 0 ))  && git_part+=" ${RED}-${deletions}${RESET}"
    (( untracked > 0 ))  && git_part+=" ${GRAY}~${untracked}${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Cost + Duration
# ═══════════════════════════════════════════════════════════════════════════════
cost_part=""
total_cost=$(jval '.cost.total_cost_usd')
[[ -z "$total_cost" ]] && total_cost=$(jval '.total_cost_usd')

if [[ -n "$total_cost" ]]; then
    cost_fmt=$(awk "BEGIN { printf \"\\$%.4f\", $total_cost }")
    cost_gt=$(awk "BEGIN { print ($total_cost > 0.50) ? 1 : 0 }")
    if (( cost_gt )); then cost_color="$YELLOW"; else cost_color="$GREEN"; fi
    cost_part="${cost_color}${cost_fmt}${RESET}"
fi

duration_ms=$(jval '.cost.total_duration_ms')
[[ -z "$duration_ms" ]] && duration_ms=$(jval '.total_duration_ms')
[[ -z "$duration_ms" ]] && duration_ms=$(jval '.duration_ms')

if [[ -n "$duration_ms" ]]; then
    secs=$((${duration_ms%.*} / 1000))
    if (( secs >= 3600 )); then
        d_str="$((secs / 3600))h$(printf '%02d' $(( (secs % 3600) / 60 )))m"
    elif (( secs >= 60 )); then
        d_str="$((secs / 60))m$(printf '%02d' $((secs % 60)))s"
    else
        d_str="${secs}s"
    fi
    duration_part="${WHITE}${d_str}${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 5b/5c. Transcript-derived data: message count, idle/working, cumulative tokens
# ═══════════════════════════════════════════════════════════════════════════════
msg_count=""
claude_is_idle=true
session_in_tokens=0
session_cache_write_tokens=0
session_cache_read_tokens=0
session_out_tokens=0
has_session_tokens=false
working_start_out_tokens=-1
delta_in=0
delta_cache_write=0
delta_cache_read=0
delta_out=0

transcript_path=$(jval '.transcript_path')

if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    cache_path=""
    [[ -n "$session_id" ]] && cache_path="${TMPDIR:-/tmp}/statusline-cache-${session_id}.txt"

    transcript_mt=$(stat -c %Y "$transcript_path" 2>/dev/null || echo 0)
    use_cache=false
    prev_working_start=-1
    prev_in=0
    prev_cache_write=0
    prev_cache_read=0
    prev_out=0

    # Read previous cache (even on miss) to preserve workingStartOutTokens and compute deltas
    if [[ -n "$cache_path" && -f "$cache_path" ]]; then
        IFS='|' read -r c_mt c_msg c_idle c_in c_out c_has c_wstart c_cwrite c_cread c_din c_dout c_dcw c_dcr < "$cache_path"
        [[ -n "$c_wstart" ]] && prev_working_start="$c_wstart"
        [[ -n "$c_in" ]] && prev_in="$c_in"
        [[ -n "$c_out" ]] && prev_out="$c_out"
        [[ -n "$c_cwrite" ]] && prev_cache_write="$c_cwrite"
        [[ -n "$c_cread" ]] && prev_cache_read="$c_cread"

        if [[ -n "$c_dcr" && "$c_mt" == "$transcript_mt" ]]; then
            msg_count="$c_msg"
            claude_is_idle="$c_idle"
            session_in_tokens="$c_in"
            session_out_tokens="$c_out"
            has_session_tokens="$c_has"
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
            # Message count: real user messages minus synthetic ones
            total_user=$(grep -cE '"type"[[:space:]]*:[[:space:]]*"user"' "$transcript_path" 2>/dev/null || true)
            tool_results=$(grep -c '"toolUseResult"' "$transcript_path" 2>/dev/null || true)
            meta_users=$(grep -cE '"isMeta"[[:space:]]*:[[:space:]]*true' "$transcript_path" 2>/dev/null || true)
            slash_users=$(grep -c '<command-name>' "$transcript_path" 2>/dev/null || true)
            msg_count=$(( total_user - tool_results - meta_users - slash_users ))
            (( msg_count < 0 )) && msg_count=0

            # Idle vs working: scan from end
            claude_is_idle=true
            while IFS= read -r ln; do
                [[ "$ln" == *"toolUseResult"* ]] && continue
                [[ "$ln" == *'"isMeta"'* ]] && continue
                [[ "$ln" == *'<command-name>'* ]] && continue
                if [[ "$ln" == *'"type"'*'"assistant"'* ]]; then
                    if [[ "$ln" == *'"stop_reason"'*'"end_turn"'* ]]; then
                        claude_is_idle=true
                    else
                        claude_is_idle=false
                    fi
                    break
                fi
                if [[ "$ln" == *'"type"'*'"user"'* ]]; then
                    claude_is_idle=false
                    break
                fi
            done < <(tac "$transcript_path" 2>/dev/null)

            # Cumulative tokens via awk (much faster than bash loop for large files)
            read -r session_in_tokens session_cache_write_tokens session_cache_read_tokens session_out_tokens has_any < <(
                awk '
                    /"type"[[:space:]]*:[[:space:]]*"assistant"/ {
                        found = 1
                        s = $0
                        t = s; sub(/.*"input_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) inp += t+0
                        t = s; sub(/.*"cache_creation_input_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) cw += t+0
                        t = s; sub(/.*"cache_read_input_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) cr += t+0
                        t = s; sub(/.*"output_tokens"[[:space:]]*:[[:space:]]*/, "", t); sub(/[^0-9].*/, "", t); if (t+0 > 0) out += t+0
                    }
                    END { print inp+0, cw+0, cr+0, out+0, (found ? "true" : "false") }
                ' "$transcript_path" 2>/dev/null
            )
            has_session_tokens="$has_any"

            # Compute deltas from previous cached values
            delta_in=$(( session_in_tokens - prev_in ))
            delta_out=$(( session_out_tokens - prev_out ))
            delta_cache_write=$(( session_cache_write_tokens - prev_cache_write ))
            delta_cache_read=$(( session_cache_read_tokens - prev_cache_read ))
            (( delta_in < 0 )) && delta_in=0
            (( delta_out < 0 )) && delta_out=0
            (( delta_cache_write < 0 )) && delta_cache_write=0
            (( delta_cache_read < 0 )) && delta_cache_read=0

            # Working start tokens
            if [[ "$claude_is_idle" == true ]]; then
                working_start_out_tokens=-1
            elif (( prev_working_start >= 0 )); then
                working_start_out_tokens=$prev_working_start
            else
                working_start_out_tokens=$session_out_tokens
            fi

            # Write cache (13 fields)
            if [[ -n "$cache_path" ]]; then
                printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
                    "$transcript_mt" "$msg_count" "$claude_is_idle" \
                    "$session_in_tokens" "$session_out_tokens" "$has_session_tokens" \
                    "$working_start_out_tokens" "$session_cache_write_tokens" \
                    "$session_cache_read_tokens" "$delta_in" "$delta_out" \
                    "$delta_cache_write" "$delta_cache_read" > "$cache_path" 2>/dev/null
            fi
        fi
    fi
fi

# Helper: format a token bucket with optional delta
# Args: label, value, delta, idle_color, active_color [, arrow]
format_bucket() {
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

# Tokens row
tokens_part=""
if [[ "$has_session_tokens" == true ]]; then
    row_sep="  ${GRAY}·${RESET}  "
    tokens_part=$(format_bucket "in" "$session_in_tokens" "$delta_in" "$CYAN" "$CYAN")
    tokens_part+="${row_sep}$(format_bucket "cache" "$session_cache_write_tokens" "$delta_cache_write" "$GRAY" "$YELLOW" "↑")"
    tokens_part+="${row_sep}$(format_bucket "cache" "$session_cache_read_tokens" "$delta_cache_read" "$GRAY" "$CYAN" "↓")"
    tokens_part+="${row_sep}$(format_bucket "out" "$session_out_tokens" "$delta_out" "$MAGENTA" "$MAGENTA")"
fi

# Status (idle/working) — shown on model row
if [[ "$claude_is_idle" == true ]]; then
    status_dot="${GREEN}●${RESET}"
    status_label="${WHITE}ready${RESET}"
    status_part="${status_dot}  ${status_label}"
else
    status_dot="${YELLOW}○${RESET}"
    status_label="${YELLOW}working${RESET}"
    status_part="${status_dot}  ${status_label}"
    if (( working_start_out_tokens >= 0 && session_out_tokens > working_start_out_tokens )); then
        delta=$(( session_out_tokens - working_start_out_tokens ))
        delta_label=$(format_tokens "$delta")
        status_part+="  ${GRAY}·${RESET}  ${CYAN}+${delta_label}${RESET} ${DIM}tokens${RESET}"
    fi
fi

# Message count — shown on cost row
msg_part=""
if [[ -n "$msg_count" && "$msg_count" -gt 0 ]] 2>/dev/null; then
    msg_label="messages"
    (( msg_count == 1 )) && msg_label="message"
    msg_part="${WHITE}${msg_count}${RESET} ${DIM}${msg_label}${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 6. Rate limits (5h + 7d)
# ═══════════════════════════════════════════════════════════════════════════════
format_duration() {
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

format_window() {
    local label=$1 pct_val=$2 resets_at=$3 window_secs=$4
    [[ -z "$pct_val" ]] && return

    local pct
    pct=$(printf '%.0f' "$pct_val")
    local pct_color
    if (( pct >= 80 )); then     pct_color="$RED"
    elif (( pct >= 50 )); then   pct_color="$YELLOW"
    else                         pct_color="$GREEN"
    fi

    local burn_part="" reset_part=""
    if [[ -n "$resets_at" ]]; then
        local now
        now=$(date +%s)
        local remaining=$(( ${resets_at%.*} - now ))
        if (( remaining > 0 && remaining <= window_secs )); then
            local delta
            delta=$(awk "BEGIN { printf \"%.0f\", $pct - ($window_secs - $remaining) * 100.0 / $window_secs }")
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
five_pct=$(jval '.rate_limits.five_hour.used_percentage')
five_res=$(jval '.rate_limits.five_hour.resets_at')
seven_pct=$(jval '.rate_limits.seven_day.used_percentage')
seven_res=$(jval '.rate_limits.seven_day.resets_at')

if [[ -n "$five_pct" || -n "$seven_pct" ]]; then
    parts_5h=$(format_window '5h' "$five_pct" "$five_res" 18000)
    parts_7d=$(format_window '7d' "$seven_pct" "$seven_res" 604800)
    rate_part=""
    [[ -n "$parts_5h" ]] && rate_part="$parts_5h"
    if [[ -n "$parts_7d" ]]; then
        [[ -n "$rate_part" ]] && rate_part+="  ${GRAY}·${RESET}  "
        rate_part+="$parts_7d"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 7. Agent / subagent status
# ═══════════════════════════════════════════════════════════════════════════════
agent_part=""
agent_name=$(jval '.agent.name')
if [[ -n "$agent_name" ]]; then
    agent_part="${BLUE}${BOLD}${agent_name}${RESET}"
    agent_compact=""
    local_sep="  ${GRAY}·${RESET}  "
    if [[ -n "$pct_int" ]]; then
        agent_compact+="${local_sep}${pct_color}${pct_int}%${RESET}"
    fi
    agent_in=$(jval '.context_window.current_usage.input_tokens')
    agent_out=$(jval '.context_window.current_usage.output_tokens')
    in_fmt=$(format_tokens "${agent_in:-0}")
    out_fmt=$(format_tokens "${agent_out:-0}")
    [[ -z "$in_fmt" ]] && in_fmt="0"
    [[ -z "$out_fmt" ]] && out_fmt="0"
    agent_compact+="${local_sep}${DIM}in${RESET} ${WHITE}${in_fmt}${RESET}  ${DIM}out${RESET} ${WHITE}${out_fmt}${RESET}"
    agent_part+="  ${agent_compact}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Assemble — full box with labeled rows grouped into sections
# ═══════════════════════════════════════════════════════════════════════════════

LABEL_W=7

# Compose merged rows
row_sep="  ${GRAY}·${RESET}  "

model_row="$model_part"
[[ -n "$effort_part" ]] && model_row+="${row_sep}${effort_part}"
[[ -n "$status_part" ]] && model_row+="${row_sep}${status_part}"

cost_row=""
parts=()
[[ -n "$cost_part" ]] && parts+=("$cost_part")
[[ -n "$msg_part" ]] && parts+=("$msg_part")
[[ -n "$duration_part" ]] && parts+=("$duration_part")
for ((j=0; j<${#parts[@]}; j++)); do
    (( j > 0 )) && cost_row+="${row_sep}"
    cost_row+="${parts[$j]}"
done

# Merge path + git into one row
path_row="$cwd_part"
if [[ -n "$git_part" ]]; then
    path_row+="${row_sep}${DIM}on${RESET} ${git_part}"
fi

# Row specs: section, label, content
declare -a row_sections=() row_labels=() row_contents=() rows=() row_secs=()

row_sections+=(0); row_labels+=("repo");    row_contents+=("$path_row")
row_sections+=(0); row_labels+=("agent");   row_contents+=("$agent_part")
row_sections+=(1); row_labels+=("model");   row_contents+=("$model_row")
row_sections+=(1); row_labels+=("context"); row_contents+=("$ctx_bar_part")
row_sections+=(1); row_labels+=("tokens");  row_contents+=("$tokens_part")
row_sections+=(1); row_labels+=("cost");    row_contents+=("$cost_row")
row_sections+=(1); row_labels+=("limits");  row_contents+=("$rate_part")

# Build rows with labels — skip empty content
for i in "${!row_sections[@]}"; do
    content="${row_contents[$i]}"
    [[ -z "$content" ]] && continue

    label="${row_labels[$i]}"
    while (( ${#label} < LABEL_W )); do label+=" "; done

    inner=" ${DIM}${label}${RESET} ${GRAY}│${RESET}  ${content} "
    rows+=("$inner")
    row_secs+=("${row_sections[$i]}")
done

# Find max visible width
max_inner=30
for r in "${rows[@]}"; do
    vl=$(get_vis "$r")
    (( vl > max_inner )) && max_inner=$vl
done

# Build horizontal rules
heavy_horiz=$(repeat_char "━" "$max_inner")
top_rule="${GRAY}┏${heavy_horiz}┓${RESET}"
sec_div_rule="${GRAY}┣${heavy_horiz}┫${RESET}"
bot_rule="${GRAY}┗${heavy_horiz}┛${RESET}"

# Inter-row divider with cross junction
left_dash_count=$((LABEL_W + 1))
right_dash_count=$((max_inner - LABEL_W - 4))
(( right_dash_count < 1 )) && right_dash_count=1
left_dashes=$(repeat_char "─" "$left_dash_count")
right_dashes=$(repeat_char "─" "$right_dash_count")
row_div_rule="${GRAY}┃${RESET} ${GRAY}${left_dashes}${RESET}${GRAY}┼${RESET}${GRAY}${right_dashes}${RESET} ${GRAY}┃${RESET}"

# Emit output
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

log_msg "about to write: chars=${#output}"
printf '%s' "$output"
log_msg "stdout write: OK"
