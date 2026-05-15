#!/usr/bin/env bash
# Installs statusline.sh into ~/.claude and registers it in settings.json.
set -e

REPO="https://raw.githubusercontent.com/axlaser/claude-status-line/master/macos"
CLAUDE_DIR="$HOME/.claude"
SCRIPT_PATH="$CLAUDE_DIR/statusline.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

# --- Helpers ---
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
GRAY=$'\033[90m'
WHITE=$'\033[37m'

step() { printf "  ${CYAN}${BOLD}>>>${RESET} %s\n" "$1"; }
ok()   { printf "  ${GREEN}${BOLD} +${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}${BOLD} !${RESET} %s\n" "$1"; }
err()  { printf "  ${RED}${BOLD} x${RESET} %s\n" "$1"; }
info() { printf "  ${DIM}   %s${RESET}\n" "$1"; }

# --- Header ---
echo ""
cat <<'BANNER'
 @@@@@@@  @@@        @@@@@@   @@@  @@@  @@@@@@@   @@@@@@@@
@@@@@@@@  @@@       @@@@@@@@  @@@  @@@  @@@@@@@@  @@@@@@@@
!@@       @@!       @@!  @@@  @@!  @@@  @@!  @@@  @@!
!@!       !@!       !@!  @!@  !@!  @!@  !@!  @!@  !@!
!@!       @!!       @!@!@!@!  @!@  !@!  @!@  !@!  @!!!:!
!!!       !!!       !!!@!!!!  !@!  !!!  !@!  !!!  !!!!!:
:!!       !!:       !!:  !!!  !!:  !!!  !!:  !!!  !!:
:!:        :!:      :!:  !:!  :!:  !:!  :!:  !:!  :!:
 ::: :::   :: ::::  ::   :::  ::::: ::   :::: ::   :: ::::
 :: :: :  : :: : :   :   : :   : :  :   :: :  :   : :: ::

 @@@@@@   @@@@@@@   @@@@@@   @@@@@@@  @@@  @@@   @@@@@@
@@@@@@@   @@@@@@@  @@@@@@@@  @@@@@@@  @@@  @@@  @@@@@@@
!@@         @@!    @@!  @@@    @@!    @@!  @@@  !@@
!@!         !@!    !@!  @!@    !@!    !@!  @!@  !@!
!!@@!!      @!!    @!@!@!@!    @!!    @!@  !@!  !!@@!!
 !!@!!!     !!!    !!!@!!!!    !!!    !@!  !!!   !!@!!!
     !:!    !!:    !!:  !!!    !!:    !!:  !!!       !:!
    !:!     :!:    :!:  !:!    :!:    :!:  !:!      !:!
:::: ::      ::    ::   :::     ::    ::::: ::  :::: ::
 :: : :       :      :   : :     :      : :  :   :: : :

@@@       @@@  @@@  @@@  @@@@@@@@
@@@       @@@  @@@@ @@@  @@@@@@@@
@@!       @@!  @@!@!@@@  @@!
!@!       !@!  !@!!@!@!  !@!
@!!       !!@  @!@ !!@!  @!!!:!
!!!       !!!  !@!  !!!  !!!!!:
!!:       !!:  !!:  !!!  !!:
 :!:      :!:  :!:  !:!  :!:
 :: ::::   ::   ::   ::   :: ::::
: :: : :  :    ::    :   : :: ::
BANNER
printf "\n  ${DIM}macOS Installer${RESET}\n"
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
echo ""

# --- Dependency check ---
step "Checking dependencies"
if command -v jq &>/dev/null; then
    ok "jq found ($(jq --version 2>/dev/null))"
else
    warn "jq is required but not installed"
    echo ""
    if command -v brew &>/dev/null; then
        read -rp "  ${YELLOW}${BOLD} ?${RESET} Install jq via Homebrew? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            brew install jq
            ok "jq installed"
        else
            err "Please install jq manually: https://jqlang.github.io/jq/download/"
            exit 1
        fi
    else
        err "Install jq: https://jqlang.github.io/jq/download/"
        info "Or install Homebrew first: https://brew.sh"
        exit 1
    fi
fi
echo ""

# --- Install the script ---
step "Installing status line script"
mkdir -p "$CLAUDE_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/statusline.sh" ]; then
    cp "$SCRIPT_DIR/statusline.sh" "$SCRIPT_PATH"
    ok "Copied from local repo"
else
    tmp=$(mktemp "$CLAUDE_DIR/statusline.XXXXXX")
    # Atomic rename so a failed curl never leaves a broken script.
    curl -fsSL "$REPO/statusline.sh" -o "$tmp" && mv "$tmp" "$SCRIPT_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Downloaded from GitHub"
fi
chmod +x "$SCRIPT_PATH"
info "$SCRIPT_PATH"
echo ""

# --- Configure settings.json ---
step "Configuring Claude Code settings"
STATUSLINE_ENTRY='{"statusLine":{"type":"command","command":"~/.claude/statusline.sh","refreshInterval":1}}'

if [ -f "$SETTINGS_PATH" ]; then
    if jq -e '.statusLine' "$SETTINGS_PATH" &>/dev/null; then
        echo ""
        read -rp "  ${YELLOW}${BOLD} ?${RESET} Existing statusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            warn "Skipped settings update"
            info "Script was installed but not configured"
            echo ""
            exit 0
        fi
    fi
    tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
    if jq --argjson entry "$STATUSLINE_ENTRY" '. + $entry' "$SETTINGS_PATH" > "$tmp"; then
        mv "$tmp" "$SETTINGS_PATH"
        ok "Updated settings.json"
    else
        rm -f "$tmp"
        err "Failed to update settings.json (jq error)"
        exit 1
    fi
else
    echo "$STATUSLINE_ENTRY" | jq '.' > "$SETTINGS_PATH"
    ok "Created settings.json"
fi
info "$SETTINGS_PATH"

# --- Done ---
echo ""
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate.\n"
echo ""
