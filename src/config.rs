//! `~/.claude/notify-config.json`.
//!
//! Two subcommands read this file: `notify` uses the per-event `sound` and
//! `visual` flags to decide what to deliver, and the status line uses
//! `context_high.threshold` and `rate_limit.threshold` to decide when to fire
//! an edge-triggered alert at all.
//!
//! Every failure degrades to the defaults. A missing file is the common case —
//! the installer only writes one when the user answers its prompts — and an
//! unparseable one must not silence notifications, because the user would have
//! no way to tell the difference between "muted" and "broken".

use std::path::{Path, PathBuf};

use serde_json::Value;

/// The events both the scripts and the status line know about.
pub const EVENTS: [&str; 6] = [
    "permission",
    "stop",
    "compaction_start",
    "compaction_done",
    "rate_limit",
    "context_high",
];

/// Defaults for the two edge-triggered alerts, used when the key is absent or
/// not an integer.
pub const DEFAULT_CONTEXT_HIGH_THRESHOLD: i64 = 70;
pub const DEFAULT_RATE_LIMIT_THRESHOLD: i64 = 80;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventConfig {
    pub sound: bool,
    pub visual: bool,
}

impl Default for EventConfig {
    /// Both on. An absent config means "notify me", not "stay quiet".
    fn default() -> Self {
        Self {
            sound: true,
            visual: true,
        }
    }
}

#[derive(Debug, Default)]
pub struct NotifyConfig {
    root: Option<Value>,
}

impl NotifyConfig {
    /// `~/.claude/notify-config.json` for this user, if the home directory
    /// resolves.
    pub fn default_path() -> Option<PathBuf> {
        crate::claude_dir().map(|d| d.join("notify-config.json"))
    }

    /// Reads and parses the file, degrading to defaults on every failure.
    pub fn load(path: &Path) -> Self {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Self::default();
        };
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Self {
        Self {
            root: serde_json::from_str::<Value>(text)
                .ok()
                .filter(Value::is_object),
        }
    }

    /// The delivery flags for one event.
    ///
    /// A flag is off **only** when it is the JSON literal `false`. Anything
    /// else — absent, null, a string, a number — leaves it on.
    ///
    /// This is the one place the port deliberately does not reproduce the
    /// shipped bash behaviour. Both shell scripts read the flag as
    /// `jq -r '.[$e].sound // true'`, and jq's `//` yields its right-hand side
    /// when the left is `false` as well as when it is null — so `false // true`
    /// is `true`, and muting has never worked on macOS or Linux. Here the
    /// flags gate delivery: intended behaviour wins over reproducing a bug.
    pub fn event(&self, event: &str) -> EventConfig {
        let mut cfg = EventConfig::default();
        let Some(entry) = self.root.as_ref().and_then(|r| r.get(event)) else {
            return cfg;
        };
        if entry.get("sound") == Some(&Value::Bool(false)) {
            cfg.sound = false;
        }
        if entry.get("visual") == Some(&Value::Bool(false)) {
            cfg.visual = false;
        }
        cfg
    }

    /// The percentage at which an edge-triggered alert fires.
    ///
    /// Only `context_high` and `rate_limit` have one; any other event reports
    /// its own default so a caller cannot silently get someone else's.
    pub fn threshold(&self, event: &str) -> i64 {
        let fallback = match event {
            "context_high" => DEFAULT_CONTEXT_HIGH_THRESHOLD,
            _ => DEFAULT_RATE_LIMIT_THRESHOLD,
        };
        self.root
            .as_ref()
            .and_then(|r| r.get(event))
            .and_then(|e| e.get("threshold"))
            .and_then(Value::as_i64)
            .unwrap_or(fallback)
    }
}
