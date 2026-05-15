#!/usr/bin/env bash
set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_PATH="$CLAUDE_DIR/statusline.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

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

# --- Header ---
echo ""
printf "  ${DIM}claude-status-line · Uninstaller${RESET}\n"
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
echo ""

# --- Remove the script ---
step "Removing status line script"
if [ -f "$SCRIPT_PATH" ]; then
    rm "$SCRIPT_PATH"
    ok "Deleted $SCRIPT_PATH"
else
    warn "Script not found (already removed?)"
fi
echo ""

# --- Remove from settings.json ---
step "Updating Claude Code settings"
if [ -f "$SETTINGS_PATH" ]; then
    if command -v jq &>/dev/null; then
        if jq -e '.statusLine' "$SETTINGS_PATH" &>/dev/null; then
            tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
            if jq 'del(.statusLine)' "$SETTINGS_PATH" > "$tmp"; then
                mv "$tmp" "$SETTINGS_PATH"
                ok "Removed statusLine from settings.json"
            else
                rm -f "$tmp"
                warn "Failed to update settings.json — remove the \"statusLine\" key manually"
            fi
        else
            warn "No statusLine config found in settings.json"
        fi
    else
        warn "jq not installed — please remove the \"statusLine\" key from settings.json manually"
        info "$SETTINGS_PATH"
    fi
else
    warn "settings.json not found"
fi

# --- Done ---
echo ""
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to use the default status bar.\n"
echo ""
