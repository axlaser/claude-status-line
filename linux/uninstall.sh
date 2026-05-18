#!/usr/bin/env bash
set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_PATH="$CLAUDE_DIR/statusline.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
NOTIFY_PATH="$CLAUDE_DIR/notify.sh"
GIT_REFRESH_PATH="$CLAUDE_DIR/git-refresh.sh"

# --- Colors & output helpers ---
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
GRAY=$'\033[90m'

step() { printf "  ${CYAN}${BOLD}>>>${RESET} %s\n" "$1"; }
ok()   { printf "  ${GREEN}${BOLD} +${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}${BOLD} !${RESET} %s\n" "$1"; }
info() { printf "  ${DIM}   %s${RESET}\n" "$1"; }
file_bytes() { wc -c < "$1" | tr -d ' '; }
human_size() {
    local b=$1
    if (( b >= 1048576 )); then awk -v b="$b" 'BEGIN{printf "%.1f MB",b/1048576}'
    elif (( b >= 1024 )); then awk -v b="$b" 'BEGIN{printf "%.1f KB",b/1024}'
    else printf "%d B" "$b"; fi
}

# --- Header ---
echo ""
printf "  ${DIM}claude-status-line · Uninstaller${RESET}\n"
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
echo ""

# --- Remove the script ---
step "Removing status line script"
if [ -f "$SCRIPT_PATH" ]; then
    _sz=$(human_size $(file_bytes "$SCRIPT_PATH"))
    rm "$SCRIPT_PATH"
    ok "Deleted $SCRIPT_PATH ($_sz)"
else
    warn "Script not found (already removed?)"
fi
echo ""

# --- Remove from settings.json ---
step "Updating Claude Code settings"
if [ -f "$SETTINGS_PATH" ]; then
    if command -v jq &>/dev/null; then
        tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
        if jq 'del(.statusLine)' "$SETTINGS_PATH" > "$tmp"; then
            mv "$tmp" "$SETTINGS_PATH"
            ok "Removed statusLine from settings.json"
        else
            rm -f "$tmp"
            warn "Failed to update settings.json — remove the \"statusLine\" key manually"
        fi
    else
        warn "jq not installed — please remove the \"statusLine\" key from settings.json manually"
        info "$SETTINGS_PATH"
    fi
else
    warn "settings.json not found"
fi

# --- Remove notification script ---
echo ""
step "Removing notification script"
if [ -f "$NOTIFY_PATH" ]; then
    _sz=$(human_size $(file_bytes "$NOTIFY_PATH"))
    rm "$NOTIFY_PATH"
    ok "Deleted $NOTIFY_PATH ($_sz)"
else
    info "Notification script not found (not installed)"
fi

# --- Remove git-refresh script ---
if [ -f "$GIT_REFRESH_PATH" ]; then
    _sz=$(human_size $(file_bytes "$GIT_REFRESH_PATH"))
    rm "$GIT_REFRESH_PATH"
    ok "Deleted $GIT_REFRESH_PATH ($_sz)"
else
    info "Git-refresh script not found (not installed)"
fi

# --- Remove notification hooks ---
if [ -f "$SETTINGS_PATH" ] && command -v jq &>/dev/null; then
    if jq -e '
      (.hooks.PermissionRequest // []) + (.hooks.Stop // []) | any(any(.hooks[]?; .command? | contains("notify.sh")))
    ' "$SETTINGS_PATH" &>/dev/null; then
        echo ""
        step "Removing notification hooks"
        tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
        if jq '
          (if .hooks.PermissionRequest then
            .hooks.PermissionRequest |= [.[] | select(any(.hooks[]?; .command? | contains("notify.sh")) | not)]
          else . end) |
          (if .hooks.Stop then
            .hooks.Stop |= [.[] | select(any(.hooks[]?; .command? | contains("notify.sh")) | not)]
          else . end) |
          (if .hooks then .hooks |= with_entries(select(.value | length > 0)) else . end) |
          (if .hooks and (.hooks | keys | length == 0) then del(.hooks) else . end)
        ' "$SETTINGS_PATH" > "$tmp"; then
            mv "$tmp" "$SETTINGS_PATH"
            ok "Removed notification hooks from settings.json"
        else
            rm -f "$tmp"
            warn "Failed to update settings.json — remove notification hooks manually"
        fi
    fi
fi

# --- Remove PostToolUse git-refresh hook ---
if [ -f "$SETTINGS_PATH" ] && command -v jq &>/dev/null; then
    if jq -e '
      (.hooks.PostToolUse // []) | any(any(.hooks[]?; .command? | contains("git-refresh.sh")))
    ' "$SETTINGS_PATH" &>/dev/null; then
        echo ""
        step "Removing git-refresh hook"
        tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
        if jq '
          (if .hooks.PostToolUse then
            .hooks.PostToolUse |= [.[] | select(any(.hooks[]?; .command? | contains("git-refresh.sh")) | not)]
          else . end) |
          (if .hooks then .hooks |= with_entries(select(.value | length > 0)) else . end) |
          (if .hooks and (.hooks | keys | length == 0) then del(.hooks) else . end)
        ' "$SETTINGS_PATH" > "$tmp"; then
            mv "$tmp" "$SETTINGS_PATH"
            ok "Removed PostToolUse hook from settings.json"
        else
            rm -f "$tmp"
            warn "Failed to update settings.json — remove PostToolUse hook manually"
        fi
    fi
fi

# --- Clean up temp state files ---
echo ""
step "Cleaning up temporary files"
removed=0
for f in "${TMPDIR:-/tmp}"/statusline-cache-*.txt; do
    [ -f "$f" ] || continue
    _sz=$(human_size $(file_bytes "$f"))
    rm -f "$f"
    ok "Deleted $f ($_sz)"
    removed=$((removed + 1))
done
if [ -f "$HOME/.claude/statusline-debug.log" ]; then
    _sz=$(human_size $(file_bytes "$HOME/.claude/statusline-debug.log"))
    rm -f "$HOME/.claude/statusline-debug.log"
    ok "Deleted $HOME/.claude/statusline-debug.log ($_sz)"
    removed=$((removed + 1))
fi
if (( removed == 0 )); then
    info "No temporary state files found"
fi

# --- Done ---
echo ""
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to use the default status bar.\n"
echo ""
