#!/usr/bin/env bash
set -e

REPO="https://raw.githubusercontent.com/axlaser/claude-status-line/master/linux"
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
printf "\n  ${DIM}Linux Installer${RESET}\n"
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
echo ""

# --- Package manager detection & jq install ---
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    elif command -v apk &>/dev/null; then
        echo "apk"
    else
        echo ""
    fi
}

install_jq() {  # apk: Alpine containers often run as root without sudo
    local mgr=$1
    case "$mgr" in
        apt)    sudo apt-get update && sudo apt-get install -y jq ;;
        dnf)    sudo dnf install -y jq ;;
        pacman) sudo pacman -S --noconfirm jq ;;
        zypper) sudo zypper install -y jq ;;
        apk)    if command -v sudo &>/dev/null; then sudo apk add jq; else apk add jq; fi ;;
    esac
}

# --- Check for jq ---
step "Checking dependencies"
if command -v jq &>/dev/null; then
    ok "jq found ($(jq --version 2>/dev/null))"
else
    warn "jq is required but not installed"
    echo ""
    PKG_MGR=$(detect_pkg_manager)
    if [[ -n "$PKG_MGR" ]]; then
        read -rp "  ${YELLOW}${BOLD} ?${RESET} Install jq via ${PKG_MGR}? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            install_jq "$PKG_MGR"
            ok "jq installed"
        else
            err "Please install jq manually: https://jqlang.github.io/jq/download/"
            exit 1
        fi
    else
        err "No supported package manager found"
        info "Install jq manually: https://jqlang.github.io/jq/download/"
        exit 1
    fi
fi
echo ""

# --- Install the script ---
# Prefer sibling statusline.sh when run from a clone; else fetch via temp+mv so a failed curl can't leave a half-written script.
step "Installing status line script"
mkdir -p "$CLAUDE_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/statusline.sh" ]; then
    cp "$SCRIPT_DIR/statusline.sh" "$SCRIPT_PATH"
    ok "Copied from local repo"
else
    tmp=$(mktemp "$CLAUDE_DIR/statusline.XXXXXX")
    curl -fsSL "$REPO/statusline.sh" -o "$tmp" && mv "$tmp" "$SCRIPT_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Downloaded from GitHub"
fi
chmod +x "$SCRIPT_PATH"
info "$SCRIPT_PATH"
echo ""

# --- Configure settings.json ---
# /dev/tty so read works when install.sh is piped via curl.
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
