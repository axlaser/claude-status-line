#!/usr/bin/env bash
# Unified notification hub for Linux.
# Usage: notify.sh <event> [value]

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

# --- Load config ---
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
play_sound() {
    local file="/usr/share/sounds/freedesktop/stereo/$1"
    if [ -f "$file" ]; then
        if command -v paplay &>/dev/null; then
            paplay "$file" 2>/dev/null
        elif command -v aplay &>/dev/null; then
            aplay "$file" 2>/dev/null
        else
            printf '\a'
        fi
    else
        printf '\a'
    fi
}

if [[ "$SOUND" == true ]]; then
    case "$EVENT" in
        permission)       play_sound "bell.oga" & ;;
        stop)             play_sound "complete.oga" & ;;
        compaction_start) play_sound "bell.oga" & ;;
        compaction_done)  play_sound "complete.oga" & ;;
        rate_limit)       play_sound "dialog-warning.oga" & ;;
        context_high)     play_sound "dialog-warning.oga" & ;;
    esac
    log_msg "sound dispatched"
fi

# --- Visual dispatch (notify-send) ---
if [[ "$VISUAL" == true ]]; then
    if ! command -v notify-send &>/dev/null; then
        log_msg "notify-send not found, skipping visual"
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
                notify-send "Claude Code" "$MSG" --urgency=normal --icon="$ICON" 2>/dev/null
            else
                notify-send "Claude Code" "$MSG" --urgency=normal 2>/dev/null
            fi
            log_msg "visual dispatched: $MSG"
        fi
    fi
fi

exit 0
