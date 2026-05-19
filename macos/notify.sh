#!/usr/bin/env bash
# Unified notification hub — dispatches sound and visual alerts per event config.
# Usage: notify.sh <event> [value]
# Always exits 0 (silent degradation).

EVENT="${1:-}"
VALUE="${2:-}"
[[ -z "$EVENT" ]] && exit 0

STDIN=""
if [[ "$EVENT" == "permission" ]] && ! [ -t 0 ]; then
    STDIN=$(cat)
fi

CONFIG_PATH="$HOME/.claude/notify-config.json"
LOG_PATH="$HOME/.claude/statusline-debug.log"

log_msg() {
    [[ -n "$STATUSLINE_DEBUG" ]] || return 0
    printf '[%s] notify: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH" 2>/dev/null
}

log_msg "event=$EVENT value=$VALUE"

# --- Load config (missing file = defaults) ---
SOUND=true
VISUAL=true

if [[ -f "$CONFIG_PATH" ]] && command -v jq &>/dev/null; then
    cfg_sound=$(jq -r --arg e "$EVENT" '.[$e].sound // true' "$CONFIG_PATH" 2>/dev/null)
    cfg_visual=$(jq -r --arg e "$EVENT" '.[$e].visual // true' "$CONFIG_PATH" 2>/dev/null)
    [[ "$cfg_sound" == "false" ]] && SOUND=false
    [[ "$cfg_visual" == "false" ]] && VISUAL=false
    log_msg "config loaded: sound=$SOUND visual=$VISUAL"
else
    log_msg "no config or no jq, using defaults"
fi

# --- Sound dispatch ---
if [[ "$SOUND" == true ]]; then
    case "$EVENT" in
        permission)       afplay /System/Library/Sounds/Tink.aiff 2>/dev/null & ;;
        stop)             afplay /System/Library/Sounds/Glass.aiff 2>/dev/null & ;;
        compaction_start) afplay /System/Library/Sounds/Tink.aiff 2>/dev/null & ;;
        compaction_done)  afplay /System/Library/Sounds/Glass.aiff 2>/dev/null & ;;
        rate_limit)       afplay /System/Library/Sounds/Sosumi.aiff 2>/dev/null & ;;
        context_high)     afplay /System/Library/Sounds/Sosumi.aiff 2>/dev/null & ;;
    esac
    log_msg "sound dispatched"
fi

# --- Visual dispatch (terminal-notifier) ---
if [[ "$VISUAL" == true ]]; then
    if ! command -v terminal-notifier &>/dev/null; then
        log_msg "terminal-notifier not found, skipping visual"
    else
        case "$EVENT" in
            permission)
                MSG="Waiting for permission"
                if [[ -n "$STDIN" ]] && command -v jq &>/dev/null; then
                    _tool=$(printf '%s' "$STDIN" | jq -r '.tool_name // empty' 2>/dev/null)
                    if [[ -n "$_tool" ]]; then
                        _detail=""
                        case "$_tool" in
                            Bash)  _detail=$(printf '%s' "$STDIN" | jq -r '.tool_input.command // empty' 2>/dev/null) ;;
                            Edit|Write|Read) _detail=$(printf '%s' "$STDIN" | jq -r '.tool_input.file_path // empty' 2>/dev/null) ;;
                        esac
                        if [[ -n "$_detail" ]]; then
                            _detail="${_detail:0:80}"
                            MSG="${_tool}: ${_detail}"
                        else
                            MSG="${_tool}"
                        fi
                    fi
                fi
                ;;
            stop)             MSG="Task complete" ;;
            compaction_start) MSG="Compacting context..." ;;
            compaction_done)  MSG="Context compacted" ;;
            rate_limit)       MSG="Rate limit at ${VALUE}%" ;;
            context_high)     MSG="Context window at ${VALUE}%" ;;
            *)                MSG="" ;;
        esac
        if [[ -n "$MSG" ]]; then
            ICON="$HOME/.claude/claude-icon.png"
            if [[ -f "$ICON" ]]; then
                terminal-notifier -title "Claude Code" -message "$MSG" -appIcon "$ICON" -contentImage "$ICON" 2>/dev/null
            else
                terminal-notifier -title "Claude Code" -message "$MSG" 2>/dev/null
            fi
            log_msg "visual dispatched: $MSG"
        fi
    fi
fi

exit 0
