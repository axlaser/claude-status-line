#!/usr/bin/env bash
# Refresh statusline git cache after file-modifying tool uses.
# Called by Claude Code PostToolUse hook with event JSON on stdin.
event=$(cat 2>/dev/null) || exit 0
tool_name=$(printf '%s' "$event" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool_name" in
    Edit|Write|MultiEdit|Bash|NotebookEdit) ;;
    *) exit 0 ;;
esac
session_id=$(printf '%s' "$event" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$session_id" ]] && exit 0
safe_id="${session_id//[^a-zA-Z0-9_-]/}"
tmpdir="${TMPDIR:-/tmp}"
rm -f "${tmpdir}/statusline-git-${safe_id}.txt"
rm -f "${tmpdir}/statusline-oc-${safe_id}.txt"
