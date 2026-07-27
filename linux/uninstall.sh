#!/usr/bin/env bash
# Compatibility entry point. The real uninstaller is install/uninstall.sh, which
# covers macOS and Linux from one file (R6); this path exists because it is the
# one the README has always published and a documented one-liner URL must keep
# working.
#
# No `set -e` and no bare `exit`: this runs in the user's live shell via the
# published one-liner. See install/install.sh for the full reasoning.

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

if [[ -n $_SELF_DIR && -f "$_SELF_DIR/../install/uninstall.sh" ]]; then
    # Running from a clone.
    source "$_SELF_DIR/../install/uninstall.sh"
else
    # Fetched. The body is sourced rather than piped so the prompts inside it
    # can still read from /dev/tty -- stdin is already the pipe carrying this
    # script.
    _BODY=$(curl -fsSL "https://raw.githubusercontent.com/axlaser/claude-statusline/master/install/uninstall.sh")
    if [[ -z $_BODY ]]; then
        printf '  Could not fetch install/uninstall.sh\n' >&2
        return 1 2>/dev/null || exit 1
    fi
    eval "$_BODY"
fi
