#!/usr/bin/env bash
# Installs statusline.sh into ~/.claude and registers it in settings.json.
set -e

REPO="https://raw.githubusercontent.com/axlaser/claude-status-line/master/macos"
CLAUDE_DIR="$HOME/.claude"
SCRIPT_PATH="$CLAUDE_DIR/statusline.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
NOTIFY_PATH="$CLAUDE_DIR/notify.sh"
GIT_REFRESH_PATH="$CLAUDE_DIR/git-refresh.sh"

# --- Helpers ---
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
err()  { printf "  ${RED}${BOLD} x${RESET} %s\n" "$1"; }
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

# --- Check for terminal-notifier ---
step "Checking for terminal-notifier"
if command -v terminal-notifier &>/dev/null; then
    ok "terminal-notifier found"
else
    warn "terminal-notifier not installed (needed for visual notifications)"
    echo ""
    if command -v brew &>/dev/null; then
        read -rp "  ${YELLOW}${BOLD} ?${RESET} Install terminal-notifier via Homebrew? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            brew install terminal-notifier
            ok "terminal-notifier installed"
        else
            info "Visual notifications will be disabled (sound-only)"
        fi
    else
        info "Install manually: brew install terminal-notifier"
        info "Visual notifications will be disabled until installed"
    fi
fi
echo ""

# --- Install the script ---
step "Installing status line script"
mkdir -p "$CLAUDE_DIR"
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/statusline.sh" ]]; then
    tmp=$(mktemp "$CLAUDE_DIR/statusline.XXXXXX")
    cp "$SCRIPT_DIR/statusline.sh" "$tmp" && mv "$tmp" "$SCRIPT_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Copied from local repo"
else
    tmp=$(mktemp "$CLAUDE_DIR/statusline.XXXXXX")
    curl -fsSL "$REPO/statusline.sh" -o "$tmp" && mv "$tmp" "$SCRIPT_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Downloaded from GitHub"
fi
chmod +x "$SCRIPT_PATH"
info "$SCRIPT_PATH ($(human_size $(file_bytes "$SCRIPT_PATH")))"
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
    tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
    if echo "$STATUSLINE_ENTRY" | jq '.' > "$tmp"; then
        mv "$tmp" "$SETTINGS_PATH"
        ok "Created settings.json"
    else
        rm -f "$tmp"
        err "Failed to create settings.json (jq error)"
        exit 1
    fi
fi
info "$SETTINGS_PATH"

# --- Install git-refresh hook script ---
echo ""
step "Installing git-refresh hook"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/git-refresh.sh" ]]; then
    tmp=$(mktemp "$CLAUDE_DIR/git-refresh.XXXXXX")
    cp "$SCRIPT_DIR/git-refresh.sh" "$tmp" && mv "$tmp" "$GIT_REFRESH_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Copied from local repo"
else
    tmp=$(mktemp "$CLAUDE_DIR/git-refresh.XXXXXX")
    curl -fsSL "$REPO/git-refresh.sh" -o "$tmp" && mv "$tmp" "$GIT_REFRESH_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Downloaded from GitHub"
fi
chmod +x "$GIT_REFRESH_PATH"
info "$GIT_REFRESH_PATH ($(human_size $(file_bytes "$GIT_REFRESH_PATH")))"

# --- Register PostToolUse hook for git refresh ---
echo ""
step "Live git status"
info "Keeps git diff/untracked counts up to date as files change."
if [ -f "$SETTINGS_PATH" ] && jq -e '
  (.hooks.PostToolUse // []) | any(any(.hooks[]?; .command? | contains("git-refresh.sh")))
' "$SETTINGS_PATH" &>/dev/null; then
    ok "Already configured"
else
    tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
    if jq '
      .hooks = (.hooks // {}) |
      .hooks.PostToolUse = (
        [(.hooks.PostToolUse // [])[] | select(any(.hooks[]?; .command? | contains("git-refresh.sh")) | not)]
        + [{"matcher":"Edit|Write|MultiEdit|Bash|NotebookEdit","hooks":[{"type":"command","command":"~/.claude/git-refresh.sh","async":true}]}]
      )
    ' "$SETTINGS_PATH" > "$tmp"; then
        mv "$tmp" "$SETTINGS_PATH"
        ok "PostToolUse hook enabled"
    else
        rm -f "$tmp"
        warn "Failed to configure hook (jq error)"
    fi
fi

# --- Install notification script ---
echo ""
step "Installing notification script"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/notify.sh" ]]; then
    tmp=$(mktemp "$CLAUDE_DIR/notify.XXXXXX")
    cp "$SCRIPT_DIR/notify.sh" "$tmp" && mv "$tmp" "$NOTIFY_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Copied from local repo"
else
    tmp=$(mktemp "$CLAUDE_DIR/notify.XXXXXX")
    curl -fsSL "$REPO/notify.sh" -o "$tmp" && mv "$tmp" "$NOTIFY_PATH" || { rm -f "$tmp"; exit 1; }
    ok "Downloaded from GitHub"
fi
chmod +x "$NOTIFY_PATH"
info "$NOTIFY_PATH ($(human_size $(file_bytes "$NOTIFY_PATH")))"

# --- Install notification icon ---
ICON_PATH="$CLAUDE_DIR/claude-icon.png"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../assets/claude-icon.png" ]]; then
    cp "$SCRIPT_DIR/../assets/claude-icon.png" "$ICON_PATH" 2>/dev/null && ok "Icon installed" || true
else
    tmp=$(mktemp "$CLAUDE_DIR/icon.XXXXXX")
    curl -fsSL "${REPO%/macos}/assets/claude-icon.png" -o "$tmp" 2>/dev/null && mv "$tmp" "$ICON_PATH" && ok "Icon downloaded" || { rm -f "$tmp"; true; }
fi

# --- Create notification config ---
echo ""
step "Notification configuration"
NOTIFY_CONFIG_PATH="$CLAUDE_DIR/notify-config.json"
if [[ -f "$NOTIFY_CONFIG_PATH" ]]; then
    ok "Config already exists (preserving)"
    info "$NOTIFY_CONFIG_PATH"
else
    cat > "$NOTIFY_CONFIG_PATH" <<'NCEOF'
{
  "permission":        { "sound": true, "visual": true },
  "stop":              { "sound": true, "visual": true },
  "rate_limit":        { "sound": true, "visual": true, "threshold": 80 },
  "context_high":      { "sound": false, "visual": true, "threshold": 70 },
  "compaction_start":  { "sound": true, "visual": true },
  "compaction_done":   { "sound": true, "visual": true }
}
NCEOF
    ok "Created default config"
    info "$NOTIFY_CONFIG_PATH"
fi

# --- Configure notification hooks ---
echo ""
step "Sound notifications"
info "Plays a sound when Claude needs attention."
ENABLE_SOUND=""
ENABLE_VISUAL=""
if [ -f "$SETTINGS_PATH" ] && jq -e '
  (.hooks.PermissionRequest // []) + (.hooks.Stop // []) | any(any(.hooks[]?; .command? | contains("notify.sh")))
' "$SETTINGS_PATH" &>/dev/null; then
    ok "Already configured"
else
    echo ""
    read -rp "  ${YELLOW}${BOLD} ?${RESET} Enable sound notifications? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
    ENABLE_SOUND="$answer"
fi

echo ""
step "Visual notifications"
info "Shows native OS popups for Claude events."
if command -v terminal-notifier &>/dev/null; then
    echo ""
    read -rp "  ${YELLOW}${BOLD} ?${RESET} Enable visual notifications? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
    ENABLE_VISUAL="$answer"
else
    warn "terminal-notifier not found — visual notifications disabled"
    ENABLE_VISUAL="n"
fi

# Apply sound/visual choices to config
if [[ -f "$NOTIFY_CONFIG_PATH" ]] && command -v jq &>/dev/null; then
    _snd=true; [[ ! "$ENABLE_SOUND" =~ ^[Yy]$ ]] && _snd=false
    _vis=true; [[ ! "$ENABLE_VISUAL" =~ ^[Yy]$ ]] && _vis=false
    tmp=$(mktemp "$NOTIFY_CONFIG_PATH.XXXXXX")
    if jq --argjson s "$_snd" --argjson v "$_vis" '
      to_entries | map(.value.sound = $s | .value.visual = $v) | from_entries
    ' "$NOTIFY_CONFIG_PATH" > "$tmp"; then
        mv "$tmp" "$NOTIFY_CONFIG_PATH"
        ok "Config updated (sound=$_snd, visual=$_vis)"
    else
        rm -f "$tmp"
    fi
fi

# Register hooks for PermissionRequest, Stop, PreCompact, PostCompact
if [[ "$ENABLE_SOUND" =~ ^[Yy]$ ]] || [[ "$ENABLE_VISUAL" =~ ^[Yy]$ ]]; then
    tmp=$(mktemp "$SETTINGS_PATH.XXXXXX")
    if jq '
      .hooks = (.hooks // {}) |
      .hooks.PermissionRequest = (
        [(.hooks.PermissionRequest // [])[] | select(any(.hooks[]?; .command? | contains("notify.sh")) | not)]
        + [{"hooks":[{"type":"command","command":"~/.claude/notify.sh permission","async":true}]}]
      ) |
      .hooks.Stop = (
        [(.hooks.Stop // [])[] | select(any(.hooks[]?; .command? | contains("notify.sh")) | not)]
        + [{"hooks":[{"type":"command","command":"~/.claude/notify.sh stop","async":true}]}]
      ) |
      .hooks.PreCompact = (
        [(.hooks.PreCompact // [])[] | select(any(.hooks[]?; .command? | contains("notify.sh")) | not)]
        + [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/notify.sh compaction_start","async":true}]}]
      ) |
      .hooks.PostCompact = (
        [(.hooks.PostCompact // [])[] | select(any(.hooks[]?; .command? | contains("notify.sh")) | not)]
        + [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/notify.sh compaction_done","async":true}]}]
      )
    ' "$SETTINGS_PATH" > "$tmp"; then
        mv "$tmp" "$SETTINGS_PATH"
        ok "Notification hooks enabled (PermissionRequest, Stop, PreCompact, PostCompact)"
    else
        rm -f "$tmp"
        warn "Failed to configure hooks (jq error)"
    fi

    # Verification toast
    if [[ "$ENABLE_VISUAL" =~ ^[Yy]$ ]] && command -v terminal-notifier &>/dev/null; then
        terminal-notifier -title "Claude Status Line" -message "Notifications enabled!" 2>/dev/null
        ok "Test notification sent"
    fi
else
    info "Skipped — run the installer again to enable later"
fi

# --- Done ---
echo ""
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate.\n"
echo ""
