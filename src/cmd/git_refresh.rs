//! `git-refresh` — the PostToolUse hook that invalidates the git cache.
//!
//! The pilot component (R34). It is the smallest of the four, which makes it
//! the one that proves the pipeline — capture, port, fixture, delete — before
//! anything harder is attempted.
//!
//! Claude Code runs this after every tool use, so it is a hot path in the same
//! sense the status line is: it must exit 0, write nothing to stderr, and do as
//! little as possible.

use std::path::{Path, PathBuf};

use crate::debug;

/// The tools whose use can change git state. Kept verbatim from the scripts:
/// this list also appears as the hook's `matcher` in `settings.json`, so the
/// two have to agree or the hook fires for tools this ignores.
pub const INVALIDATING_TOOLS: [&str; 5] = ["Edit", "Write", "MultiEdit", "Bash", "NotebookEdit"];

/// Strips everything outside `[a-zA-Z0-9_-]` from a session id.
///
/// Characters are *removed*, not replaced, which is what both scripts do —
/// `../../foo/bar` becomes `foobar`, not `______foo_bar`. Any port that
/// substituted instead would derive different paths for the same session and
/// silently stop invalidating the cache.
///
/// This is also the whole defence against path traversal: the session id
/// arrives from the payload and lands in a filename, so a separator or a `..`
/// surviving here would let the hook delete outside the temp directory.
pub fn sanitize_session_id(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect()
}

/// The temp directory the scripts use.
///
/// Spelled out rather than deferring to `std::env::temp_dir`, which consults
/// `TMP` before `TEMP` on Windows. The scripts read `%TEMP%`, and a machine
/// where the two differ would have the hook deleting from one directory while
/// the status line writes to the other — invisible, because a cache that is
/// never invalidated still renders correctly.
pub fn temp_dir() -> PathBuf {
    #[cfg(windows)]
    {
        std::env::var_os("TEMP")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
    }
    #[cfg(unix)]
    {
        std::env::var_os("TMPDIR")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"))
    }
}

/// The two caches a file-modifying tool invalidates.
///
/// The tasks feed and the notification latch are deliberately absent: R28 makes
/// them data stores rather than performance caches, and deleting them here
/// would drop subagent rows and re-fire alerts on every edit.
pub fn cache_paths(temp: &Path, safe_id: &str) -> Vec<PathBuf> {
    vec![
        temp.join(format!("statusline-git-{safe_id}.txt")),
        temp.join(format!("statusline-oc-{safe_id}.txt")),
    ]
}

/// Decides which paths this payload invalidates, without touching the disk.
///
/// Returns an empty vector for every degraded case — unparseable input, a tool
/// that does not change files, an absent or unusable session id.
pub fn targets(payload: &str, temp: &Path) -> Vec<PathBuf> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
        return Vec::new();
    };

    let tool = value
        .get("tool_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if !INVALIDATING_TOOLS.contains(&tool) {
        return Vec::new();
    }

    let raw = value
        .get("session_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let safe_id = sanitize_session_id(raw);
    // An id that sanitises to nothing would produce `statusline-git-.txt`, a
    // path shared by every such session. The scripts stop on an empty id; so
    // does this.
    if safe_id.is_empty() {
        return Vec::new();
    }

    cache_paths(temp, &safe_id)
}

/// Deletes the caches this payload invalidates and returns what it removed.
///
/// A missing file is a no-op, not an error: the common case is that the status
/// line has not rendered since the last edit, so there is nothing to remove.
pub fn run(payload: &str, temp: &Path) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    for path in targets(payload, temp) {
        match std::fs::remove_file(&path) {
            Ok(()) => removed.push(path),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                let p = path.display().to_string();
                debug::log(move || format!("git-refresh: cannot remove {p}: {e}"));
            }
        }
    }
    if debug::is_enabled() {
        let n = removed.len();
        debug::log(move || format!("git-refresh: removed {n} cache file(s)"));
    }
    removed
}
