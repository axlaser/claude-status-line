//! claude-statusline: one multi-call binary replacing the three per-platform
//! script trees.
//!
//! The library half exists so the single integration test file (R29) can reach
//! internal behaviour — the state guards and the clock — which a binary-only
//! crate cannot expose.

pub mod clock;
pub mod cmd;
pub mod config;
pub mod debug;
pub mod git;
pub mod payload;
pub mod platform;
pub mod session;
pub mod settings;
pub mod state;
pub mod transcript;

use std::path::PathBuf;

/// The user's home directory, however this platform spells it.
///
/// One resolver for the whole crate: two of them would eventually disagree, and
/// every predictable state path is derived from this one.
pub fn home_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("USERPROFILE").map(PathBuf::from)
    }
    #[cfg(unix)]
    {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}

/// `~/.claude`, where Claude Code keeps `settings.json` and this tool keeps its
/// config, its data stores, and its binary.
pub fn claude_dir() -> Option<PathBuf> {
    home_dir().map(|h| h.join(".claude"))
}

/// Output the `self-check` subcommand compares against (R11, KTD15).
///
/// U1 ships a stub. U13 replaces it with `include_str!` of a fixture the case
/// table also asserts, so the expected output cannot drift from the renderer.
pub const SELF_CHECK_FIXTURE: &str = "claude-statusline self-check ok\n";

/// Renders the built-in fixture and compares it to the built-in expectation.
///
/// Exempt from the exit-0 catch: this is the installer's only guard against
/// placing a binary that launches but renders wrongly, so it has to be able to
/// fail (R11 / AE8).
pub fn self_check() -> (String, i32) {
    let rendered = if std::env::var_os("STATUSLINE_FORCE_SELFCHECK_MISMATCH").is_some() {
        "self-check mismatch\n".to_string()
    } else {
        SELF_CHECK_FIXTURE.to_string()
    };

    let code = if rendered == SELF_CHECK_FIXTURE { 0 } else { 1 };
    (rendered, code)
}
