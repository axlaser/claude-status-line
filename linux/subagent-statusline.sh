#!/usr/bin/env bash
# Tee Claude Code's subagentStatusLine tasks payload to a session-scoped state file.
# Called by Claude Code once per refresh tick with all visible tasks as JSON on stdin.
# Prints nothing to stdout (output would override the default agent-panel rendering).
# Always exits 0 (silent degradation).

LOG_PATH="$HOME/.claude/statusline-debug.log"

log_msg() {
    [[ -n "$STATUSLINE_DEBUG" ]] || return 0
    printf '[%s] subagent-statusline: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH" 2>/dev/null
}

[[ -t 0 ]] && exit 0
input=$(cat 2>/dev/null) || exit 0
[[ -z "$input" ]] && exit 0

log_msg "payload: $input"

command -v jq &>/dev/null || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$session_id" ]] && exit 0

safe_id="${session_id//[^a-zA-Z0-9_-]/}"
[[ -z "$safe_id" ]] && exit 0

# Keep only the per-task fields the statusline reader consumes; drop absent ones
# (model/contextWindowSize are omitted until Claude Code >= v2.1.205 resolves them).
state_json=$(printf '%s' "$input" | jq -c '{tasks: [(.tasks // [])[] | select(type == "object") | {id, name, type, description, status, model, contextWindowSize, tokenCount, startTime} | with_entries(select(.value != null))]}' 2>/dev/null)
[[ -z "$state_json" ]] && exit 0

# Atomic write: temp file in the same directory, then rename, so a concurrent
# statusline refresh never reads a torn file.
state_path="${TMPDIR:-/tmp}/statusline-tasks-${safe_id}.json"
tmp_path="${state_path}.tmp.$$"
if printf '%s' "$state_json" > "$tmp_path" 2>/dev/null; then
    mv -f "$tmp_path" "$state_path" 2>/dev/null || rm -f "$tmp_path" 2>/dev/null
else
    rm -f "$tmp_path" 2>/dev/null
fi

exit 0
