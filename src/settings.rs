//! `settings.json` merge, shared by both installers (R14, R15).
//!
//! The installers cannot use `jq`: a fresh install has to complete on a machine
//! with no `jq` and no package manager, which is one of the migration's stated
//! goals. By the time `settings.json` is touched the installer already has a
//! checksum-verified binary on disk, and that binary already links a JSON
//! implementation — so the merge lives here rather than being hand-rolled twice
//! in two shell dialects against arbitrary user JSON.
//!
//! Everything below preserves unrelated content. `settings.json` is the user's
//! file; this code owns exactly the entries it wrote and nothing else.

use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

/// Default location: `~/.claude/settings.json`.
pub fn default_path() -> Option<PathBuf> {
    crate::claude_dir().map(|d| d.join("settings.json"))
}

/// Reads `settings.json`, treating an absent file as an empty object.
///
/// A file that exists but does not parse is an error, never an empty object:
/// silently starting fresh would discard everything the user configured, and
/// the installer is expected to stop and say so instead.
pub fn load(path: &Path) -> Result<Value, String> {
    match std::fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Ok(Value::Object(Map::new())),
        Ok(text) => serde_json::from_str(&text)
            .map_err(|e| format!("{} is not valid JSON: {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Object(Map::new())),
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

/// Writes `settings.json` atomically.
///
/// Claude Code may read this file at any moment, and a partial write would be
/// read as corrupt. The temporary lands in the same directory so the rename
/// stays on one filesystem and is therefore atomic.
pub fn save(path: &Path, root: &Value) -> Result<(), String> {
    let mut text =
        serde_json::to_string_pretty(root).map_err(|e| format!("cannot serialise: {e}"))?;
    text.push('\n');

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }

    let tmp = path.with_extension(format!("json.tmp{}", std::process::id()));
    std::fs::write(&tmp, text.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot replace {}: {e}", path.display())
    })
}

/// The matcher today's PostToolUse hook registers. Kept verbatim: R15 requires
/// the same hook entries, and this string decides which tool uses invalidate
/// the git cache.
pub const POST_TOOL_MATCHER: &str = "Edit|Write|MultiEdit|Bash|NotebookEdit";

/// Claude Code's refresh cadence for the status line, in seconds.
pub const REFRESH_INTERVAL: u64 = 2;

/// Which parts of the integration to write.
#[derive(Clone, Copy, Debug, Default)]
pub struct ApplySpec {
    pub statusline: bool,
    pub subagent: bool,
    pub git_refresh: bool,
    pub notify: bool,
    /// Store the binary path wrapped in quotes (R14).
    ///
    /// Quoting is decided here rather than by the caller because the caller is
    /// a shell, and shells eat quotes. PowerShell consumes the surrounding
    /// quotes of a pre-quoted argument as delimiters, so an installer that
    /// passed `"C:\path\x.exe"` handed this code a bare path and silently wrote
    /// an unquoted command — which word-splits on the first space in the
    /// profile directory. Passing the bare path and quoting on this side has no
    /// such boundary to cross.
    pub quote: bool,
}

/// Whether this platform needs the stored command quoted.
///
/// Windows does: a profile directory containing a space would otherwise
/// word-split the command. Unix entries are stored bare, which is what the
/// shell installers always wrote.
pub const fn quote_for_this_platform() -> bool {
    cfg!(windows)
}

/// The notification events that get their own hook, paired with the hook event
/// Claude Code fires and the matcher today's installer writes for it.
///
/// `PermissionRequest` and `Stop` carry no matcher; `PreCompact` and
/// `PostCompact` carry `*`. That asymmetry is what the current installer
/// produces, and R15 says preserve today's entries — so it is reproduced rather
/// than tidied.
const NOTIFY_HOOKS: [(&str, Option<&str>, &str); 4] = [
    ("PermissionRequest", None, "permission"),
    ("Stop", None, "stop"),
    ("PreCompact", Some("*"), "compaction_start"),
    ("PostCompact", Some("*"), "compaction_done"),
];

/// Applies the requested entries to `root`, replacing any this tool wrote
/// before and leaving everything else untouched.
///
/// `binary` is the command reference exactly as it should appear in
/// `settings.json` — already quoted on Windows, where a profile directory
/// containing a space would otherwise word-split the command (R14). Quoting is
/// the installer's business because it is platform-specific; concatenation is
/// this function's.
pub fn apply(root: &mut Value, binary: &str, spec: &ApplySpec) {
    ensure_object(root);

    let binary: &str = &if spec.quote && !binary.starts_with('"') {
        format!("\"{binary}\"")
    } else {
        binary.to_string()
    };

    if spec.statusline {
        root[STATUS_LINE] = json!({
            "type": "command",
            "command": binary,
            "refreshInterval": REFRESH_INTERVAL,
        });
    }

    if spec.subagent {
        root[SUBAGENT_STATUS_LINE] = json!({
            "type": "command",
            "command": format!("{binary} subagent"),
        });
    }

    if spec.git_refresh {
        // `async: true` is preserved deliberately. The plan left its survival
        // open, but R15 says the same hook entries, and without it the hook
        // runs synchronously inside every file-modifying tool call.
        set_hook(
            root,
            "PostToolUse",
            Some(POST_TOOL_MATCHER),
            &format!("{binary} git-refresh"),
        );
    }

    if spec.notify {
        for (event, matcher, arg) in NOTIFY_HOOKS {
            set_hook(root, event, matcher, &format!("{binary} notify {arg}"));
        }
    }
}

/// Removes every entry whose command references `binary`, and prunes the
/// containers that leaves empty.
///
/// Matching is by substring against the command with surrounding quotes
/// stripped, so a Windows entry written as `"C:\...\claude-statusline.exe"
/// notify stop` is still recognised when the uninstaller passes the bare path.
pub fn remove(root: &mut Value, binary: &str) {
    let Some(map) = root.as_object_mut() else {
        return;
    };

    for key in [STATUS_LINE, SUBAGENT_STATUS_LINE] {
        if map
            .get(key)
            .and_then(|v| v.get("command"))
            .and_then(Value::as_str)
            .is_some_and(|c| references(c, binary))
        {
            map.remove(key);
        }
    }

    let Some(hooks) = map.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };

    let events: Vec<String> = hooks.keys().cloned().collect();
    for event in events {
        let Some(entries) = hooks.get_mut(&event).and_then(Value::as_array_mut) else {
            continue;
        };
        entries.retain(|entry| !entry_references(entry, binary));
        if entries.is_empty() {
            hooks.remove(&event);
        }
    }

    // An empty `hooks` object left behind would be harmless but is not what the
    // user had before; uninstall should leave no trace it can avoid leaving.
    if hooks.is_empty() {
        map.remove("hooks");
    }
}

/// Whether an entry referencing `binary` is already present for `feature`.
///
/// Drives the installer's "Already configured" path, which is how R15's
/// idempotent re-runs avoid re-prompting for something already set up.
pub fn has(root: &Value, binary: &str, feature: &str) -> bool {
    let present = |key: &str| {
        root.get(key)
            .and_then(|v| v.get("command"))
            .and_then(Value::as_str)
            .is_some_and(|c| references(c, binary))
    };

    match feature {
        "statusline" => present(STATUS_LINE),
        "subagent" => present(SUBAGENT_STATUS_LINE),
        "git-refresh" => hook_present(root, "PostToolUse", binary),
        "notify" => NOTIFY_HOOKS
            .iter()
            .any(|(event, _, _)| hook_present(root, event, binary)),
        _ => false,
    }
}

/// Whether any entry at all exists for `key`, ours or not.
///
/// The installer asks before overwriting a `statusLine` it did not write, which
/// is today's prompt and therefore R15's requirement.
pub fn has_foreign(root: &Value, binary: &str, feature: &str) -> bool {
    let occupied = |key: &str| {
        root.get(key).is_some_and(|v| {
            !v.is_null()
                && !v
                    .get("command")
                    .and_then(Value::as_str)
                    .is_some_and(|c| references(c, binary))
        })
    };
    match feature {
        "statusline" => occupied(STATUS_LINE),
        "subagent" => occupied(SUBAGENT_STATUS_LINE),
        _ => false,
    }
}

const STATUS_LINE: &str = "statusLine";
const SUBAGENT_STATUS_LINE: &str = "subagentStatusLine";

fn ensure_object(root: &mut Value) {
    if !root.is_object() {
        // A settings file that is valid JSON but not an object cannot be merged
        // into. Replacing it loses user content, so this only fires for input
        // the caller has already decided to discard — the installer refuses to
        // proceed when the existing file is unparseable.
        *root = Value::Object(Map::new());
    }
}

fn references(command: &str, binary: &str) -> bool {
    let needle = binary.trim_matches('"');
    !needle.is_empty() && command.trim_matches('"').contains(needle)
}

fn entry_references(entry: &Value, binary: &str) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks.iter().any(|h| {
                h.get("command")
                    .and_then(Value::as_str)
                    .is_some_and(|c| references(c, binary))
            })
        })
}

fn hook_present(root: &Value, event: &str, binary: &str) -> bool {
    root.get("hooks")
        .and_then(|h| h.get(event))
        .and_then(Value::as_array)
        .is_some_and(|entries| entries.iter().any(|e| entry_references(e, binary)))
}

/// Replaces our entry for `event` while preserving every entry that is not
/// ours, so a user's own hook on the same event survives an install.
fn set_hook(root: &mut Value, event: &str, matcher: Option<&str>, command: &str) {
    let hooks = root
        .as_object_mut()
        .expect("root is an object by this point")
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()));
    if !hooks.is_object() {
        *hooks = Value::Object(Map::new());
    }

    let entries = hooks
        .as_object_mut()
        .expect("hooks is an object by this point")
        .entry(event)
        .or_insert_with(|| Value::Array(Vec::new()));
    if !entries.is_array() {
        *entries = Value::Array(Vec::new());
    }

    let list = entries.as_array_mut().expect("entries is an array");
    // Drop any previous entry of ours for this event before appending, or a
    // re-run accumulates duplicates — R15's idempotence requirement.
    list.retain(|e| !entry_references(e, command_binary(command)));

    let mut entry = Map::new();
    if let Some(m) = matcher {
        entry.insert("matcher".into(), json!(m));
    }
    entry.insert(
        "hooks".into(),
        json!([{ "type": "command", "command": command, "async": true }]),
    );
    list.push(Value::Object(entry));
}

/// The binary reference inside a composed command, i.e. everything before the
/// subcommand. Quoted Windows paths keep their quotes here and are stripped by
/// `references`.
fn command_binary(command: &str) -> &str {
    if let Some(rest) = command.strip_prefix('"') {
        return rest.split('"').next().unwrap_or(command);
    }
    command.split(' ').next().unwrap_or(command)
}
