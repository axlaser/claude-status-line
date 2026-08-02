//! Session identity and the temp root every session-scoped state file sits in.
//!
//! Three components derive paths from the same session id — `git-refresh`
//! deletes `statusline-git-<id>.txt`, `subagent` writes
//! `statusline-tasks-<id>.json`, and the status line reads both. They agree
//! only because one function answers "what is this session's id" and one
//! answers "where does its state live". Two copies would drift, and the
//! symptom would be silent: a hook that invalidates a path nothing reads, or a
//! feed written where nothing looks for it, both of which still render fine.

use std::path::{Path, PathBuf};

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

/// The directory name this binary groups its state under, minus the per-user
/// suffix.
///
/// The suffix is `platform::current_owner()` — a raw uid on Unix, a digest of
/// the token SID on Windows — so the two platforms produce different-looking
/// names for the same reason. It is not a security control: any user can create
/// any name in a shared `/tmp`. What it buys is an unambiguous owner check. With
/// one shared name, a foreign owner might be a second user legitimately there
/// first, and there would be no answer that is right for both of them; with the
/// owner in the name, a mismatch is always wrong and the whole failure is
/// confined to one uid.
const STATE_DIR_PREFIX: &str = "claude-statusline-";

/// Where this session's state lives, and whether this binary owns that
/// directory.
///
/// The second field is the whole reason this is a struct. `state::write_guarded`
/// serves the flat temp root, `~/.claude`, and the test harness's scratch roots
/// as well as the state directory, and it must create only the last of those
/// privately — applying the private-directory check to `/tmp` (mode 1777,
/// root-owned) fails it, and every state write on Linux fails with it. The
/// distinction cannot be recovered downstream by comparing paths or by testing
/// existence: on a machine whose temp root does not yet exist, "the parent is
/// absent" would route `/tmp` straight back into the guard.
///
/// Derefs to `Path` so the eight path builders that only ever `join` onto it
/// need no signature change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateRoot {
    path: PathBuf,
    guarded: bool,
}

impl StateRoot {
    /// A root this binary did not create and must not judge: the flat temp
    /// root, or any directory a test stages directly.
    pub fn inherited(path: PathBuf) -> Self {
        Self {
            path,
            guarded: false,
        }
    }

    /// True when this binary is responsible for creating the directory
    /// privately on first write.
    pub fn is_guarded(&self) -> bool {
        self.guarded
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl std::ops::Deref for StateRoot {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.path
    }
}

impl AsRef<Path> for StateRoot {
    fn as_ref(&self) -> &Path {
        &self.path
    }
}

/// Resolves the state directory under `temp_root`, without creating anything.
///
/// **Creates nothing.** `Roots::from_env` runs before the payload is parsed, and
/// a tick whose payload does not parse must leave the temp directory untouched —
/// `degraded_input_renders_the_notice_and_touches_no_state` asserts exactly
/// that. Creation happens on the first guarded write instead.
///
/// Falls back to `temp_root` itself, unguarded, in two cases: the candidate
/// directory exists and does not verify, and the owner cannot be read at all. The
/// second is what keeps the per-user component honest — a name with no owner in
/// it would put every user on the machine in one directory, which is the
/// opposite of what the suffix is for.
pub fn state_dir_in(temp_root: &Path) -> StateRoot {
    let Some(owner) = crate::platform::current_owner() else {
        crate::debug::log(|| {
            "state_dir: owner unavailable, using the temp root directly".to_string()
        });
        return StateRoot::inherited(temp_root.to_path_buf());
    };

    let candidate = temp_root.join(format!("{STATE_DIR_PREFIX}{owner}"));
    match crate::platform::dir_verdict(&candidate) {
        crate::platform::DirVerdict::Absent | crate::platform::DirVerdict::Private => StateRoot {
            path: candidate,
            guarded: true,
        },
        crate::platform::DirVerdict::Hostile => {
            let shown = candidate.display().to_string();
            crate::debug::log(move || {
                format!("state_dir: {shown} did not verify, using the temp root directly")
            });
            StateRoot::inherited(temp_root.to_path_buf())
        }
    }
}

/// Production wrapper: `state_dir_in` over the real temp root.
///
/// The root is read here and nowhere else, so the resolution itself stays a pure
/// function of its argument and the tests can drive it without touching process
/// environment from inside a threaded test binary.
pub fn state_dir() -> StateRoot {
    state_dir_in(&temp_dir())
}
