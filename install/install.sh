#!/usr/bin/env bash
# Installs the claude-statusline binary into ~/.claude/bin and registers it in
# settings.json. Covers macOS and Linux from one file (R6).
#
# No `set -e`: this script can be sourced (see CLAUDE.md), and errexit would
# leak into the caller's shell and persist after return. Failures are handled
# explicitly at each critical step instead.
#
# No bare `exit` either. The published one-liner pipes this into a shell, and
# CLAUDE.md's idiom -- `return 1 2>/dev/null || exit 1` -- returns when sourced
# and exits only when that fails, i.e. when running as a subshell. Every abort
# below uses it, and every one of them lives at top level: `return` inside a
# function would unwind the function and carry on.

REPO_SLUG="axlaser/claude-statusline"
SIGNER_WORKFLOW="$REPO_SLUG/.github/workflows/release.yml"

CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$CLAUDE_DIR/bin"
BIN_PATH="$BIN_DIR/claude-statusline"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
NOTIFY_CONFIG_PATH="$CLAUDE_DIR/notify-config.json"
ICON_PATH="$CLAUDE_DIR/claude-icon.png"
STAGE_PREFIX=".claude-statusline.stage."

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
err()  { printf "  ${RED}${BOLD} x${RESET} %s\n" "$1"; }
info() { printf "  ${DIM}   %s${RESET}\n" "$1"; }

file_bytes() { wc -c < "$1" | tr -d ' '; }
human_size() {
    local b=$1
    if (( b >= 1048576 )); then awk -v b="$b" 'BEGIN{printf "%.1f MB",b/1048576}'
    elif (( b >= 1024 )); then awk -v b="$b" 'BEGIN{printf "%.1f KB",b/1024}'
    else printf "%d B" "$b"; fi
}

# Removes the staged download. Called on every path that does not place it
# (R10) -- a staged file left behind is an unverified binary sitting in the
# install directory under a predictable-ish name.
discard_stage() {
    [[ -n ${STAGE:-} ]] && rm -f "$STAGE"
    [[ -n ${SUMS:-} ]] && rm -f "$SUMS"
    [[ -n ${BUNDLE:-} ]] && rm -f "$BUNDLE"
    return 0
}

# Puts the previous binary back after a failure that has already moved it
# aside. R11 requires a binary that fails its self-check to leave the prior
# installation untouched, and by then the new one is already in place -- so
# "untouched" has to be restored rather than merely not disturbed.
restore_previous() {
    if [[ -n ${BACKUP:-} && -e $BACKUP ]]; then
        mv -f "$BACKUP" "$BIN_PATH" 2>/dev/null
    fi
    BACKUP=""
    return 0
}

# The scripts a pre-binary installation left in ~/.claude (R16). Removed only
# after the self-check passes: until then they are still the working
# installation.
LEGACY_SCRIPTS=(statusline.sh notify.sh git-refresh.sh subagent-statusline.sh)

# --- Options ---
REQUIRE_ATTESTATION=false
PINNED_VERSION="${CLAUDE_STATUSLINE_VERSION:-}"
for _arg in "$@"; do
    case "$_arg" in
        --require-attestation) REQUIRE_ATTESTATION=true ;;
        --version=*)           PINNED_VERSION="${_arg#--version=}" ;;
    esac
done

# --- Header ---
echo ""
printf "\n  ${DIM}claude-statusline installer${RESET}\n"
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
echo ""

# --- Platform detection (R13) ---
# First, and before anything is created, removed, or written: an unsupported
# platform must leave an existing installation exactly as it was (AE16).
step "Detecting platform"
_os=""
case "$(uname -s 2>/dev/null)" in
    Darwin) _os=apple-darwin ;;
    Linux)  _os=unknown-linux-musl ;;
esac
_arch=""
case "$(uname -m 2>/dev/null)" in
    arm64|aarch64) _arch=aarch64 ;;
    x86_64|amd64)  _arch=x86_64 ;;
esac
if [[ -z $_os || -z $_arch ]]; then
    err "Unsupported platform: $(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)"
    info "Published targets: macOS and Linux on x86_64 and aarch64, Windows on x86_64 and aarch64."
    info "Nothing was changed."
    return 1 2>/dev/null || exit 1
fi
TARGET="${_arch}-${_os}"
ASSET="claude-statusline-${TARGET}"
ok "$TARGET"

for _tool in curl uname awk; do
    if ! command -v "$_tool" &>/dev/null; then
        err "$_tool is required but not installed"
        return 1 2>/dev/null || exit 1
    fi
done
echo ""

# --- Resolve the release (R5) ---
step "Resolving release"
if [[ -n $PINNED_VERSION ]]; then
    TAG="$PINNED_VERSION"
    ok "Pinned to $TAG"
else
    # The /releases/latest redirect resolves the current stable tag without an
    # authenticated API call, and excludes prereleases -- which is what keeps
    # the pipeline-verification tags of R36 from ever being installed.
    _effective=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO_SLUG/releases/latest" 2>/dev/null)
    TAG="${_effective##*/}"
    if [[ -z $TAG || $TAG == "latest" ]]; then
        err "Could not resolve the latest release"
        info "Set CLAUDE_STATUSLINE_VERSION=<tag> to pin a version, or check your connection."
        info "Your existing installation was left untouched."
        return 1 2>/dev/null || exit 1
    fi
    ok "$TAG"
fi
BASE_URL="https://github.com/$REPO_SLUG/releases/download/$TAG"
echo ""

# --- Verify the install directory (R9) ---
# Deliberately inverted relative to the runtime guard: at runtime an
# undeterminable owner leaves the guard passing, because failing a read closed
# kills every cache and re-fires alerts (see
# docs/solutions/logic-errors/get-acl-unavailable-inverts-trust-check.md). Here
# the check runs once, at install time, and a directory we cannot vouch for is
# a directory we must not place an executable into.
step "Checking the install directory"
if [[ -L $BIN_DIR ]]; then
    err "$BIN_DIR is a symlink"
    info "Refusing to install through a link. Remove it and re-run."
    return 1 2>/dev/null || exit 1
fi
if [[ ! -d $BIN_DIR ]]; then
    ( umask 077 && mkdir -p "$BIN_DIR" ) || {
        err "Cannot create $BIN_DIR"
        return 1 2>/dev/null || exit 1
    }
    ok "Created $BIN_DIR (0700)"
fi

# BSD stat takes -f, GNU stat takes -c. Probe rather than branch on uname: both
# platforms ship a `stat` and which dialect is not always what the OS suggests.
_stat_owner() {
    stat -f %u "$1" 2>/dev/null || stat -c %u "$1" 2>/dev/null
}
_stat_mode() {
    stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null
}
_dir_owner=$(_stat_owner "$BIN_DIR")
_dir_mode=$(_stat_mode "$BIN_DIR")
_me=$(id -u 2>/dev/null)
if [[ -z $_dir_owner || -z $_dir_mode || -z $_me ]]; then
    err "Cannot determine ownership or permissions of $BIN_DIR"
    info "Refusing to install where the directory cannot be vouched for."
    return 1 2>/dev/null || exit 1
fi
if [[ $_dir_owner != "$_me" ]]; then
    err "$BIN_DIR is owned by uid $_dir_owner, not by you (uid $_me)"
    return 1 2>/dev/null || exit 1
fi
# Group- or world-writable means someone else can replace the binary after it
# is verified, which would make every check above decorative.
if (( (8#$_dir_mode & 8#022) != 0 )); then
    err "$BIN_DIR is group- or world-writable (mode $_dir_mode)"
    info "Fix with: chmod go-w \"$BIN_DIR\""
    return 1 2>/dev/null || exit 1
fi
ok "Owned by you, mode $_dir_mode"
echo ""

# --- Stage the download (R10) ---
step "Downloading"
# Sweep anything a previous interrupted run left behind before adding one.
rm -f "$BIN_DIR/$STAGE_PREFIX"* 2>/dev/null

# Staged inside the destination directory, never in a shared world-writable
# temp: /tmp staging would let another user swap the file between verification
# and placement, and a cross-filesystem move would not be atomic either.
umask 077
STAGE="$BIN_DIR/${STAGE_PREFIX}$$"
SUMS="$BIN_DIR/${STAGE_PREFIX}$$.sums"
BUNDLE="$BIN_DIR/${STAGE_PREFIX}$$.sigstore.json"

if ! curl -fsSL "$BASE_URL/$ASSET" -o "$STAGE"; then
    err "Download failed: $BASE_URL/$ASSET"
    discard_stage
    return 1 2>/dev/null || exit 1
fi
# No execute bit yet. Between here and verification the file must not be
# runnable, by us or by anything else that finds it.
chmod 600 "$STAGE" 2>/dev/null
ok "$ASSET ($(human_size "$(file_bytes "$STAGE")"))"
echo ""

# --- Verify the checksum (R7) ---
# Verification that cannot be performed counts as verification failure. There is
# no "proceed without checking" path here: the checksum is the fail-closed gate
# for the whole transport (KTD3).
step "Verifying checksum"
if ! curl -fsSL "$BASE_URL/checksums.txt" -o "$SUMS"; then
    err "Could not fetch checksums.txt"
    discard_stage
    return 1 2>/dev/null || exit 1
fi
_expected=$(awk -v f="$ASSET" '$2 == f { print $1 }' "$SUMS" | head -n 1)
if [[ -z $_expected ]]; then
    err "checksums.txt has no entry for $ASSET"
    discard_stage
    return 1 2>/dev/null || exit 1
fi
if command -v sha256sum &>/dev/null; then
    _actual=$(sha256sum "$STAGE" 2>/dev/null | awk '{print $1}')
elif command -v shasum &>/dev/null; then
    _actual=$(shasum -a 256 "$STAGE" 2>/dev/null | awk '{print $1}')
else
    err "No SHA-256 tool found (sha256sum or shasum)"
    info "Cannot verify the download, so it will not be installed."
    discard_stage
    return 1 2>/dev/null || exit 1
fi
if [[ -z $_actual || $_actual != "$_expected" ]]; then
    err "Checksum mismatch for $ASSET"
    info "expected $_expected"
    info "actual   ${_actual:-<none>}"
    discard_stage
    return 1 2>/dev/null || exit 1
fi
ok "SHA-256 matches"
echo ""

# --- Verify the attestation (R8) ---
# Opportunistic but fail-closed when it runs (KTD3): a negative result stops the
# install with or without --require-attestation; only the inability to verify is
# tolerated, and only without the flag.
step "Verifying build provenance"
_attested=false
if command -v gh &>/dev/null; then
    if curl -fsSL "$BASE_URL/$ASSET.sigstore.json" -o "$BUNDLE"; then
        # Verified against the downloaded bundle rather than the attestation
        # API: the API serves its bundle Snappy-compressed and needs an
        # authenticated gh, which is exactly why R4 publishes the bundle as a
        # release asset.
        if gh attestation verify "$STAGE" \
                --bundle "$BUNDLE" \
                --repo "$REPO_SLUG" \
                --signer-workflow "$SIGNER_WORKFLOW" &>/dev/null; then
            _attested=true
            ok "Provenance verified (built by $SIGNER_WORKFLOW)"
        else
            err "Attestation verification FAILED for $ASSET"
            info "The download matched its checksum but does not carry a valid"
            info "provenance attestation from this repository's release workflow."
            info "Refusing to install."
            discard_stage
            return 1 2>/dev/null || exit 1
        fi
    else
        warn "No attestation bundle published for this release"
    fi
else
    warn "gh CLI not found — provenance not verified"
fi

if [[ $_attested != true ]]; then
    if [[ $REQUIRE_ATTESTATION == true ]]; then
        err "--require-attestation was given but provenance could not be verified"
        discard_stage
        return 1 2>/dev/null || exit 1
    fi
    info "Verify manually later with:"
    info "  gh attestation verify \"$BIN_PATH\" --repo $REPO_SLUG \\"
    info "     --signer-workflow $SIGNER_WORKFLOW"
fi
echo ""

# --- Place the binary (R9, R10) ---
step "Installing"
# Move any existing binary aside rather than overwriting it, so the self-check
# below has something to roll back to (AE8). The stage prefix is deliberate:
# a run interrupted between here and the self-check leaves the backup where
# the next run's sweep will find it.
BACKUP=""
if [[ -e $BIN_PATH ]]; then
    BACKUP="$BIN_DIR/${STAGE_PREFIX}$$.previous"
    if ! mv -f "$BIN_PATH" "$BACKUP"; then
        err "Could not move the existing binary aside"
        BACKUP=""
        discard_stage
        return 1 2>/dev/null || exit 1
    fi
fi
if ! mv -f "$STAGE" "$BIN_PATH"; then
    err "Could not place the binary at $BIN_PATH"
    discard_stage
    restore_previous
    return 1 2>/dev/null || exit 1
fi
STAGE=""
# The execute bit goes on only now, after both gates have passed. 0700 also
# satisfies R9's "writable only by that user".
chmod 700 "$BIN_PATH" 2>/dev/null || warn "Could not set permissions on $BIN_PATH"
rm -f "$SUMS" "$BUNDLE" 2>/dev/null
ok "$BIN_PATH"
info "$(human_size "$(file_bytes "$BIN_PATH")")"
echo ""

# --- Self-check (R11, AE8) ---
# A binary can pass its checksum, launch, and still render wrongly -- a bad
# build, a corrupt fixture, an architecture that runs but misbehaves. The
# silent-degradation contract guarantees that failure would reach the user as
# an absent status line and nothing else, so this is the only place it can be
# caught. Everything destructive below is gated on it.
step "Verifying the binary renders"
if ! "$BIN_PATH" self-check >/dev/null 2>&1; then
    err "The installed binary failed its self-check"
    info "It downloaded and verified but does not render correctly, so it was"
    info "not activated. Your previous installation is untouched."
    rm -f "$BIN_PATH"
    restore_previous
    return 1 2>/dev/null || exit 1
fi
[[ -n $BACKUP ]] && rm -f "$BACKUP"
BACKUP=""
ok "Renders correctly"
echo ""

# --- Migrate from a script installation (R16, F2) ---
# Only now, with a binary that has proved it renders. notify-config.json is
# deliberately not in this list: it is the user's configuration, its schema is
# unchanged, and the binary reads it as-is (R44).
_legacy_found=()
for _script in "${LEGACY_SCRIPTS[@]}"; do
    [[ -e "$CLAUDE_DIR/$_script" ]] && _legacy_found+=("$_script")
done
if (( ${#_legacy_found[@]} > 0 )); then
    step "Removing the superseded scripts"
    for _script in "${_legacy_found[@]}"; do
        if rm -f "$CLAUDE_DIR/$_script"; then
            ok "$_script"
        else
            warn "Could not remove $CLAUDE_DIR/$_script"
        fi
    done
    info "Your notification settings were kept."
    echo ""
fi

# --- Configure settings.json (R14) ---
# The merge runs through the binary just placed. It is the only JSON
# implementation on hand: a fresh install has to work with no jq and no package
# manager, and hand-rolling a JSON merge in shell against the user's own
# settings is not something to do twice in two dialects.
step "Configuring Claude Code settings"
_apply_flags=()

if "$BIN_PATH" settings has-foreign --binary "$BIN_PATH" statusline &>/dev/null; then
    echo ""
    read -rp "  ${YELLOW}${BOLD} ?${RESET} Existing statusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        _apply_flags+=(--statusline)
    else
        warn "Skipped statusLine update"
        info "Continuing with hook and notification setup..."
    fi
    echo ""
else
    _apply_flags+=(--statusline)
fi

if "$BIN_PATH" settings has-foreign --binary "$BIN_PATH" subagent &>/dev/null; then
    echo ""
    read -rp "  ${YELLOW}${BOLD} ?${RESET} Existing subagentStatusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
    [[ "$answer" =~ ^[Yy]$ ]] && _apply_flags+=(--subagent) || warn "Skipped subagentStatusLine update"
    echo ""
else
    _apply_flags+=(--subagent)
fi

# Live git status. Always on: it is not a notification, it has no prompt today,
# and it costs nothing when idle.
_apply_flags+=(--git-refresh)

# --- Notification configuration (R15, R44) ---
echo ""
step "Notification configuration"
if [[ -f $NOTIFY_CONFIG_PATH ]]; then
    ok "Config already exists (preserving)"
    info "$NOTIFY_CONFIG_PATH"
    _config_was_new=false
else
    _config_was_new=true
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

echo ""
step "Notifications"
info "Plays a sound and shows a popup when Claude needs attention."
# The legacy check is what carries the choice across an upgrade (R16): someone
# who enabled notifications under the scripts has hooks pointing at notify.sh,
# which `has` does not recognise, and re-prompting them would turn a silent
# upgrade into a question they already answered.
if "$BIN_PATH" settings has --binary "$BIN_PATH" notify &>/dev/null \
    || "$BIN_PATH" settings has-legacy --binary "$BIN_PATH" notify &>/dev/null; then
    ok "Already configured"
    _apply_flags+=(--notify)
else
    echo ""
    read -rp "  ${YELLOW}${BOLD} ?${RESET} Enable notifications? (${GREEN}y${RESET}/${RED}n${RESET}) " answer </dev/tty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        _apply_flags+=(--notify)
    else
        info "Skipped — run the installer again to enable later"
    fi
fi

# --- Notification icon ---
if [[ ! -f $ICON_PATH ]]; then
    curl -fsSL "https://raw.githubusercontent.com/$REPO_SLUG/master/assets/claude-icon.png" \
        -o "$ICON_PATH" 2>/dev/null && ok "Icon installed" || true
fi

# --- Apply ---
echo ""
if ! _apply_err=$("$BIN_PATH" settings apply --binary "$BIN_PATH" "${_apply_flags[@]}" 2>&1); then
    err "Failed to update settings.json"
    [[ -n $_apply_err ]] && info "$_apply_err"
    info "The binary is installed at $BIN_PATH but Claude Code is not pointing at it yet."
    return 1 2>/dev/null || exit 1
fi
ok "Updated $SETTINGS_PATH"

# --- Done ---
echo ""
printf "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate.\n"
echo ""
