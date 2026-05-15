#!/usr/bin/env bash
# Claude Code statusLine script for macOS.

if ! command -v jq &>/dev/null; then
    printf '\033[31m[statusline: jq not found — run: brew install jq]\033[0m'
    exit 0
fi

# --- ANSI ---
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

# --- Debug log ---
LOG_PATH="$HOME/.claude/statusline-debug.log"
log_msg() {  # errors swallowed so logging never breaks the status line
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH" 2>/dev/null
}
log_msg "=== invoked, BASH_VERSION=$BASH_VERSION PID=$$ ==="

# --- Read stdin ---
raw=$(cat)
log_msg "stdin bytes=${#raw}"
log_msg "stdin head: ${raw:0:400}"

if ! printf '%s' "$raw" | jq -e '.' &>/dev/null; then
    log_msg "READ/PARSE FAILED"
    printf '%s' "${RED}[statusline: bad JSON]${RESET}"
    exit 0
fi
log_msg "json parse: OK"

# --- Helpers ---
jval() {  # jq path with fallback; treats null/empty as missing
    local result
    result=$(printf '%s' "$raw" | jq -r "$1 // empty" 2>/dev/null)
    if [[ -z "$result" || "$result" == "null" ]]; then
        printf '%s' "${2:-}"
    else
        printf '%s' "$result"
    fi
}

format_tokens() {  # 1234567 -> "1.2M"
    local n=$1
    [[ -z "$n" ]] && { printf '0'; return; }
    if (( n >= 1000000 )); then
        awk "BEGIN { printf \"%.1fM\", $n / 1000000.0 }"
    elif (( n >= 1000 )); then
        awk "BEGIN { printf \"%.1fK\", $n / 1000.0 }"
    else
        printf '%d' "$n"
    fi
}

get_vis() {  # visible width (strips ANSI) — for box padding
    local stripped
    stripped=$(printf '%s' "$1" | perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g')
    printf '%d' "${#stripped}"
}

repeat_char() {  # multi-byte safe char repeat
    local ch="$1" count="$2" out=""
    for ((i = 0; i < count; i++)); do out+="$ch"; done
    printf '%s' "$out"
}

# --- 1. CWD ---
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

# --- 2. Model + Context window % ---
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

# --- 2b. Context bar ---
# Always rendered (missing used_pct -> 0%, missing ctx_size -> no token label)
# so a fresh session shows an empty bar instead of an empty row.
bar_width=30
bar_used_pct="${used_pct:-0}"
bar_pct_int="${pct_int:-0}"
bar_color="${pct_color}"
[[ -z "$pct_int" ]] && bar_color="$GREEN"
filled=$(awk "BEGIN { v = $bar_used_pct; if (v<0) v=0; if (v>100) v=100; printf \"%d\", int($bar_width * v / 100 + 0.5) }")
(( filled > bar_width )) && filled=$bar_width
(( filled < 0 )) && filled=0
empty_count=$((bar_width - filled))

filled_chars=$(repeat_char "█" "$filled")
empty_chars=$(repeat_char "░" "$empty_count")
bar="${bar_color}${filled_chars}${RESET}${GRAY}${empty_chars}${RESET}"

token_suffix=""
if [[ -n "$ctx_size" ]]; then
    # Prefer total_input_tokens — used_percentage is rounded so derived counts jump in 10K steps on 1M windows.
    total_input_tokens=$(jval '.context_window.total_input_tokens')
    if [[ -n "$total_input_tokens" ]]; then
        used_tokens="$total_input_tokens"
    else
        used_tokens=$(awk "BEGIN { v=$bar_used_pct; if(v<0)v=0; if(v>100)v=100; printf \"%d\", int($ctx_size * v / 100) }")
    fi
    if (( used_tokens >= 1000000 )); then
        used_lbl=$(awk "BEGIN { printf \"%.1fM\", $used_tokens / 1000000.0 }")
    elif (( used_tokens >= 1000 )); then
        used_lbl=$(awk "BEGIN { printf \"%.1fK\", $used_tokens / 1000.0 }")
    else
        used_lbl="$used_tokens"
    fi
    token_suffix=" ${GRAY}·${RESET} ${WHITE}${used_lbl}${RESET}${GRAY}/${ctx_label}${RESET}"
fi

ctx_bar_part="${bar} ${bar_color}${bar_pct_int}%${RESET}${token_suffix}"

# --- 3. Reasoning effort ---
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

# --- 4. Git status ---
# --no-optional-locks avoids contention with concurrent git ops in the user's terminal.
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

# --- 5. Cost + Duration ---
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

# --- 5b/5c. Transcript-derived: messages, idle/working, cumulative tokens ---
# Cached by transcript mtime so big sessions don't slow refresh; cache also
# stashes prior token totals for per-refresh delta computation.
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

    transcript_mt=$(stat -f %m "$transcript_path" 2>/dev/null || echo 0)
    use_cache=false
    prev_working_start=-1
    prev_in=0
    prev_cache_write=0
    prev_cache_read=0
    prev_out=0

    # Read prior cache even on miss — needed for workingStart + deltas.
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
            # Filter per-line (chained grep -v) instead of summing counters — the
            # marker strings can co-occur on the same line, causing over-subtraction.
            msg_count=$(grep -E '"type"[[:space:]]*:[[:space:]]*"user"' "$transcript_path" 2>/dev/null \
                | grep -v '"toolUseResult"' \
                | grep -Ev '"isMeta"[[:space:]]*:[[:space:]]*true' \
                | grep -v '<command-name>' \
                | grep -v '<local-command-stdout>' \
                | wc -l | tr -d ' ')
            [[ -z "$msg_count" ]] && msg_count=0

            # Scan from end (tail -r = macOS tac), skip synthetic entries — without
            # filtering <local-command-*> the detector stays stuck on "working" after /effort.
            claude_is_idle=true
            while IFS= read -r ln; do
                [[ "$ln" == *"toolUseResult"* ]] && continue
                [[ "$ln" == *'"isMeta"'* ]] && continue
                [[ "$ln" == *'<command-name>'* ]] && continue
                [[ "$ln" == *'<local-command-'* ]] && continue
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
            done < <(tail -r "$transcript_path" 2>/dev/null)

            # awk pass is much faster than bash loop on large transcripts.
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

            if [[ -n "$cache_path" ]]; then  # 13 fields
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
row_sep="  ${GRAY}·${RESET}  "
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
    if (( working_start_out_tokens >= 0 && session_out_tokens > working_start_out_tokens )); then
        delta=$(( session_out_tokens - working_start_out_tokens ))
        delta_label=$(format_tokens "$delta")
        status_part+="  ${GRAY}·${RESET}  ${CYAN}+${delta_label}${RESET} ${DIM}tokens${RESET}"
    fi
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

# --- 7. Agent status ---
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

# --- 7b. Subagent context ---
# One row per active Task-tool subagent (last assistant stop_reason != end_turn).
# Transcripts: <project>/<sessionId>/subagents/agent-*.jsonl + sibling .meta.json.
declare -a subagent_contents=()
if [[ -n "$session_id" && -n "$transcript_path" ]]; then
    project_dir=$(dirname "$transcript_path")
    session_base=$(basename "$transcript_path" .jsonl)
    subagents_dir="$project_dir/$session_base/subagents"
    if [[ -d "$subagents_dir" ]]; then
        for sa_file in "$subagents_dir"/agent-*.jsonl; do
            [[ -f "$sa_file" ]] || continue

            sa_last=$(jq -c 'select(.type == "assistant")' "$sa_file" 2>/dev/null | tail -1)
            [[ -z "$sa_last" ]] && continue
            sa_fields=$(printf '%s' "$sa_last" | jq -r '"\(.message.stop_reason // "")|\(.message.usage.input_tokens // 0)|\(.message.usage.cache_creation_input_tokens // 0)|\(.message.usage.cache_read_input_tokens // 0)|\(.message.model // "")"' 2>/dev/null)
            [[ -z "$sa_fields" ]] && continue
            IFS='|' read -r sa_sr sa_in sa_cw sa_cr sa_model <<< "$sa_fields"

            [[ "$sa_sr" == "end_turn" ]] && continue

            sa_used=$((sa_in + sa_cw + sa_cr))

            sa_ctx_size=200000
            case "$sa_model" in
                *"[1m]"*|*"-1m"*) sa_ctx_size=1000000 ;;
            esac

            sa_base=$(basename "$sa_file" .jsonl)
            sa_meta="$subagents_dir/${sa_base}.meta.json"
            agent_display="${sa_base#agent-}"
            if [[ -f "$sa_meta" ]]; then
                meta_type=$(jq -r '.agentType // ""' "$sa_meta" 2>/dev/null)
                [[ -n "$meta_type" ]] && agent_display="$meta_type"
            fi

            sa_pct_raw=$(awk "BEGIN { p = $sa_used * 100.0 / $sa_ctx_size; if (p<0) p=0; if (p>100) p=100; print p }")
            sa_pct_int=$(printf '%.0f' "$sa_pct_raw")
            if   (( sa_pct_int >= 85 )); then sa_color="$RED"
            elif (( sa_pct_int >= 60 )); then sa_color="$YELLOW"
            else                              sa_color="$GREEN"
            fi
            sa_filled=$(awk "BEGIN { printf \"%d\", int($bar_width * $sa_pct_raw / 100 + 0.5) }")
            (( sa_filled > bar_width )) && sa_filled=$bar_width
            (( sa_filled < 0 )) && sa_filled=0
            sa_empty=$((bar_width - sa_filled))
            sa_filled_chars=$(repeat_char "█" "$sa_filled")
            sa_empty_chars=$(repeat_char "░" "$sa_empty")
            sa_bar="${sa_color}${sa_filled_chars}${RESET}${GRAY}${sa_empty_chars}${RESET}"

            if   (( sa_used >= 1000000 )); then sa_used_lbl=$(awk "BEGIN { printf \"%.1fM\", $sa_used / 1000000.0 }")
            elif (( sa_used >= 1000 )); then    sa_used_lbl=$(awk "BEGIN { printf \"%.1fK\", $sa_used / 1000.0 }")
            else                                sa_used_lbl="$sa_used"
            fi
            if (( sa_ctx_size >= 1000000 )); then
                sa_ctx_lbl=$(awk "BEGIN { printf \"%.0fM\", $sa_ctx_size / 1000000.0 }")
            else
                sa_ctx_lbl=$(awk "BEGIN { printf \"%.0fK\", $sa_ctx_size / 1000.0 }")
            fi

            sa_sep="  ${GRAY}·${RESET}  "
            sa_working="${YELLOW}○ working${RESET}"
            sa_content="${sa_bar} ${sa_color}${sa_pct_int}%${RESET}${sa_sep}${WHITE}${sa_used_lbl}${RESET}${GRAY}/${sa_ctx_lbl}${RESET}${sa_sep}${BLUE}${agent_display}${RESET}${sa_sep}${sa_working}"
            subagent_contents+=("$sa_content")
        done
    fi
fi

# --- Assemble ---
# Two sections separated by heavy divider; thin ┼ between rows within a section.
LABEL_W=7
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
for sa_content in "${subagent_contents[@]}"; do
    row_sections+=(1); row_labels+=("agent"); row_contents+=("$sa_content")
done
row_sections+=(1); row_labels+=("tokens");  row_contents+=("$tokens_part")
row_sections+=(1); row_labels+=("cost");    row_contents+=("$cost_row")
row_sections+=(1); row_labels+=("limits");  row_contents+=("$rate_part")

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

log_msg "about to write: chars=${#output}"
printf '%s' "$output"
log_msg "stdout write: OK"
