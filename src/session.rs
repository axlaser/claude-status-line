//! Session identity and the temp root every session-scoped state file sits in.
//!
//! Three components derive paths from the same session id — `git-refresh`
//! deletes `statusline-git-<id>.txt`, `subagent` writes
//! `statusline-tasks-<id>.json`, and the status line reads both. They agree
//! only because one function answers "what is this session's id" and one
//! answers "where does its state live". Two copies would drift, and the
//! symptom would be silent: a hook that invalidates a path nothing reads, or a
//! feed written where nothing looks for it, both of which still render fine.

use std::path::PathBuf;

/// Strips everything outside `[a-zA-Z0-9_-]` from a session id.
///
/// Characters are *removed*, not replaced, which is what all four scripts do —
/// `../../foo/bar` becomes `foobar`, not `______foo_bar`. Any port that
/// substituted instead would derive different paths for the same session and
/// silently stop invalidating the cache.
///
/// This is also the whole defence against path traversal: the session id
/// arrives from the payload and lands in a filename, so a separator or a `..`
/// surviving here would let a component write or delete outside the temp
/// directory.
/// Session ids longer than this are truncated. Nothing Claude Code emits comes
/// near it — a UUID is 36 characters — but the id lands in a filename, and a
/// name the filesystem refuses makes *every* state write for that session fail.
/// That is the whole per-session cache gone, silently, for as long as the
/// session lasts.
const MAX_SESSION_ID: usize = 128;

pub fn sanitize_session_id(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(MAX_SESSION_ID)
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
