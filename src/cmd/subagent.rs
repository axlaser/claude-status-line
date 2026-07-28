//! `subagent` — the `subagentStatusLine` handler that tees the tasks feed.
//!
//! Claude Code hands this process every visible task once per refresh tick. It
//! writes a trimmed copy to a session-scoped file and **prints nothing**:
//! anything on stdout replaces Claude Code's default agent panel, so an
//! accidental byte here does not degrade the display, it deletes it.
//!
//! The feed is a data store, not a performance cache. Its freshness
//! window is a render input the status line consults, which is why
//! `git-refresh` deliberately leaves it alone.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::debug;
use crate::session::sanitize_session_id;
use crate::state::{self, WriteOutcome};

/// The per-task fields the status line reads back, in the order the scripts
/// emit them.
///
/// Order is part of the observable: the projected bytes are asserted
/// byte-for-byte against the captured feed fixtures by
/// `feed_bytes_match_the_captured_fixtures`, so a reordering fails the case
/// table even though every rendered row would look identical.
///
/// The reason used to be the output cache — a reorder missed its key on every
/// tick while rendering the same bytes. That cache is gone (CLAUDE.md: "There
/// is no output cache"); the fixture assertion is what pins the order now.
pub const TASK_FIELDS: [&str; 10] = [
    "id",
    "name",
    "type",
    "description",
    "status",
    "model",
    "effort",
    "contextWindowSize",
    "tokenCount",
    "startTime",
];

/// Where this session's feed lives.
pub fn feed_path(temp: &Path, safe_id: &str) -> PathBuf {
    temp.join(format!("statusline-tasks-{safe_id}.json"))
}

/// What one tick did, so a caller can tell the three ways of writing nothing
/// apart. They look identical on disk and mean very different things.
#[derive(Debug, PartialEq, Eq)]
pub enum Tick {
    /// The feed now holds this tick's bytes.
    Wrote(PathBuf),
    /// Nothing was written and the previous feed survives — no usable session
    /// id, or a payload this tick cannot be trusted to represent.
    Skipped,
    /// The target could not be made safe, so the write was abandoned rather
    /// than followed.
    Hostile,
    /// The write itself failed (permissions, disk, rename).
    Failed,
}

/// Projects one task object down to the fields the reader consumes.
///
/// Absent and null fields are *dropped*, not emitted as null or as `""`.
/// `effort` is the field that makes this load-bearing: Claude Code reports it
/// only when the task carries an explicit override, so presence is the signal
/// to render the segment at all. An empty string would render an override that
/// does not exist.
fn project_task(task: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    for field in TASK_FIELDS {
        match task.get(field) {
            Some(v) if !v.is_null() => {
                out.insert(field.to_string(), v.clone());
            }
            _ => {}
        }
    }
    out
}

/// Builds the exact bytes this payload tees, or `None` when the tick must be
/// skipped.
///
/// Returns the sanitized session id alongside them because the caller needs
/// both and deriving the id twice is how two components end up disagreeing
/// about which file they are talking about.
///
/// `None` covers every case where writing would destroy information: an
/// unparseable payload, a payload that is not an object, no usable session id,
/// and a `tasks` field of the wrong type. Each of those leaves the last good
/// feed in place — the malformed-tick isolation that got the raw-tee prototype
/// rejected in `docs/performance.md` §7. A tee that overwrites on garbage
/// silently drops the subagent rows until the next good tick.
pub fn project(payload: &str) -> Option<(String, String)> {
    let value: Value = serde_json::from_str(payload).ok()?;
    let root = value.as_object()?;

    let safe_id = sanitize_session_id(root.get("session_id").and_then(Value::as_str).unwrap_or(""));
    // An id that sanitises to nothing would write `statusline-tasks-.json`, a
    // path every such session would share.
    if safe_id.is_empty() {
        return None;
    }

    let tasks: Vec<Value> = match root.get("tasks") {
        // An absent feed is a real state — a session with no visible tasks —
        // and writes an empty list.
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items
            .iter()
            // A non-object task is dropped rather than emitted as `{}`. jq's
            // `select(type == "object")` does this today; the PowerShell script
            // emits an empty object instead, which reaches the reader as a task
            // with no id. Resolved to the bash behaviour: `{}` is not a task.
            .filter_map(Value::as_object)
            .map(|t| Value::Object(project_task(t)))
            .collect(),
        // Present but not an array. jq fails outright here and writes nothing,
        // which is the isolation behaviour above; treat it as a malformed tick.
        Some(_) => return None,
    };

    let mut root_out = Map::new();
    root_out.insert("tasks".to_string(), Value::Array(tasks));
    Some((safe_id, Value::Object(root_out).to_string()))
}

/// Tees one tick's payload to this session's feed file.
///
/// The write goes through the shared guard: a symlink or reparse point
/// planted at either the final path or the temporary one is removed and
/// re-checked, and the write is abandoned if it survives. On a shared `/tmp`
/// the feed path is entirely predictable from the session id, so this is the
/// difference between a state file and an arbitrary-write primitive.
pub fn run(payload: &str, temp: &Path) -> Tick {
    let Some((safe_id, bytes)) = project(payload) else {
        debug::log(|| "subagent-statusline: tick skipped, feed left as-is".to_string());
        return Tick::Skipped;
    };

    let path = feed_path(temp, &safe_id);
    match state::write_guarded(&path, bytes.as_bytes()) {
        WriteOutcome::Written => {
            if debug::is_enabled() {
                let n = bytes.len();
                debug::log(move || format!("subagent-statusline: wrote {n} byte(s) to the feed"));
            }
            Tick::Wrote(path)
        }
        WriteOutcome::SkippedHostile => {
            let p = path.display().to_string();
            debug::log(move || format!("subagent-statusline: hostile feed target, skipped {p}"));
            Tick::Hostile
        }
        WriteOutcome::Failed => {
            let p = path.display().to_string();
            debug::log(move || format!("subagent-statusline: feed write failed for {p}"));
            Tick::Failed
        }
    }
}
