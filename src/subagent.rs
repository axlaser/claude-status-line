//! Subagent rows: one line per Task-tool subagent, and the model-to-window
//! resolution they depend on.
//!
//! Rows come from **one tier per refresh, never merged**: the tasks feed that
//! `cmd::subagent` tees when it is fresh, otherwise per-agent transcript
//! parsing. Merging them would double-count a task that appears in both, and
//! the two tiers disagree about what they can see — the feed knows a task's
//! model and window, the transcripts know only what the agent wrote.
//!
//! Both tiers share a done signal and a linger: a finished row stays visible
//! for [`DONE_LINGER_SECS`] so a subagent that completes between refreshes does
//! not vanish without ever having been seen. The stamp lives in a state file
//! because the linger has to survive the process that observed the completion —
//! `statusline-sa-<session>-task-<id>.txt` for the feed tier,
//! `statusline-sa-<session>-<agent-base>.txt` for the fallback one. The two
//! namespaces are deliberately distinct: [`disappeared_rows`] scans the
//! `-task-` prefix, and a fallback file landing there would be read back as a
//! vanished task and rendered a second time.
//!
//! This paragraph described both tiers before either one implemented it on the
//! fallback side; that tier had no stamp and no linger, so a finished row stayed
//! visible for the full [`FALLBACK_MAX_AGE_SECS`] window instead. The scripts
//! did carry it (`eb56345:linux/statusline.sh:1287` and `:1357`), and the same
//! record now also serves as the mtime skip that keeps the tier from re-reading
//! every agent transcript on every refresh.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::clock::Clock;
use crate::debug;
use crate::payload::sanitize_display;
use crate::session;
use crate::state;

/// How fresh the tasks feed must be to be used at all.
pub const FEED_TTL_SECS: i64 = 10;

/// How long a finished row lingers before it disappears.
pub const DONE_LINGER_SECS: i64 = 30;

/// Fallback-tier transcripts older than this are ignored: a subagent whose file
/// has not moved in three minutes is not a subagent this session is running.
pub const FALLBACK_MAX_AGE_SECS: i64 = 180;

/// The window assumed for a model nothing else can resolve.
pub const DEFAULT_WINDOW: u64 = 200_000;

/// One rendered subagent row's inputs.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Row {
    pub used: u64,
    pub window: u64,
    pub model: String,
    pub display: String,
    pub effort: String,
    pub done: bool,
}

// --- Model identity ------------------------------------------------------

/// Strips a trailing `-YYYYMMDD` date suffix.
///
/// Deliberately narrow. Its output is both the learned map's storage key and
/// the string the `1m` variant tier matches on, so teaching it to strip `[1m]`
/// as well would rewrite every stored key and make that tier unreachable.
pub fn normalize_model_id(id: &str) -> String {
    if let Some(stem) = id.rfind('-').map(|i| (&id[..i], &id[i + 1..])) {
        let (head, tail) = stem;
        if tail.len() == 8 && tail.bytes().all(|b| b.is_ascii_digit()) {
            return head.to_string();
        }
    }
    id.to_string()
}

/// The identity used **only** to ask "is this the same model as the session's".
///
/// Never a storage key and never a resolver-tier input: it folds `[1m]` and
/// `-1m` away, which is exactly what the variant tier needs to still see.
pub fn model_base_id(id: &str) -> String {
    let normalized = normalize_model_id(id);
    let trimmed = normalized
        .strip_suffix("[1m]")
        .or_else(|| normalized.strip_suffix("-1m"))
        .unwrap_or(&normalized);
    trimmed.to_lowercase()
}

/// Known model windows, keyed by normalized id. Unlisted ids fall through to
/// the remaining tiers.
pub fn seed_window(normalized: &str) -> Option<u64> {
    match normalized.strip_prefix("claude-").unwrap_or(normalized) {
        "fable-5" | "opus-4-8" | "opus-4-7" | "opus-4-6" | "sonnet-5" | "sonnet-4-6" => {
            Some(1_000_000)
        }
        "haiku-4-5" | "sonnet-4-5" | "opus-4-5" => Some(200_000),
        _ => None,
    }
}

/// The tiered window resolver.
#[derive(Debug, Default, Clone)]
pub struct Windows {
    session_model_id: String,
    session_window: Option<u64>,
    learned: BTreeMap<String, u64>,
}

impl Windows {
    pub fn new(
        session_model_id: &str,
        session_window: Option<u64>,
        learned: BTreeMap<String, u64>,
    ) -> Self {
        Self {
            session_model_id: session_model_id.to_string(),
            // A non-positive window is no window: the session tier is skipped
            // entirely rather than resolving to something that would divide by
            // zero downstream.
            session_window: session_window.filter(|w| *w > 0),
            learned,
        }
    }

    /// Loads `~/.claude/statusline-model-windows.json`.
    ///
    /// Anything that is not an object of usable numbers yields an empty map,
    /// which degrades to the seed table rather than failing — a learned map is
    /// an optimization over the seeds, never a prerequisite.
    pub fn load_learned(path: &Path) -> BTreeMap<String, u64> {
        let mut map = BTreeMap::new();
        let Some(bytes) = state::read_trusted(path) else {
            return map;
        };
        let Ok(text) = String::from_utf8(bytes) else {
            return map;
        };
        let Ok(Value::Object(entries)) = serde_json::from_str::<Value>(&text) else {
            return map;
        };
        for (key, value) in entries {
            if key.is_empty() {
                continue;
            }
            // Numbers and numeric strings alike: jq stringifies both before
            // bash's `^[0-9]+$` guard sees them.
            let window = match &value {
                Value::Number(n) => n.as_u64(),
                Value::String(s) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
                    s.parse().ok()
                }
                _ => None,
            };
            if let Some(w) = window {
                map.insert(key, w);
            }
        }
        map
    }

    /// Session → learned → seed table → `1m` marker → default.
    ///
    /// The session tier leads because it is live truth for *this* session: a
    /// subagent running the session's own model has the session's window. A
    /// learned entry is a historical observation that may have come from a
    /// different machine or been wrong when it was written.
    pub fn resolve(&self, model_id: &str) -> u64 {
        let normalized = normalize_model_id(model_id);

        if !model_id.is_empty() && !self.session_model_id.is_empty() {
            if let Some(window) = self.session_window {
                if model_base_id(model_id) == model_base_id(&self.session_model_id) {
                    return window;
                }
            }
        }

        if let Some(w) = self.learned.get(&normalized) {
            return *w;
        }

        if let Some(w) = seed_window(&normalized) {
            return w;
        }

        // The marker tier reads the *normalized* id, which still carries the
        // variant suffix — this is what `model_base_id` must never be used for.
        if normalized.contains("[1m]") || normalized.contains("-1m") {
            return 1_000_000;
        }

        DEFAULT_WINDOW
    }
}

// --- Feed tier -----------------------------------------------------------

/// One task as the feed describes it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct FeedTask {
    pub id: String,
    pub display: String,
    pub status: String,
    pub model: String,
    /// `None` when the feed omitted it — Claude Code below v2.1.205 — which
    /// sends the row through the tiered resolver instead.
    pub window: Option<u64>,
    pub tokens: u64,
    pub start: String,
    pub effort: String,
}

/// Whether a feed status means the task is still running.
///
/// Deny-list polarity on purpose: an unrecognized status reads as *working*,
/// so a status Claude Code adds later shows up as a visible row rather than
/// silently vanishing. A genuinely finished task that leaves the feed is still
/// caught by the disappeared-task signal.
pub fn status_is_active(status: &str) -> bool {
    !matches!(
        status.to_lowercase().as_str(),
        "completed"
            | "complete"
            | "done"
            | "finished"
            | "failed"
            | "cancelled"
            | "canceled"
            | "killed"
            | "stopped"
            | "error"
    )
}

/// Parses the feed payload. `None` means "not a feed", which drops the tier;
/// an object whose `tasks` is absent is a valid empty feed.
pub fn parse_feed(raw: &str) -> Option<Vec<FeedTask>> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let object = value.as_object()?;
    let tasks = match object.get("tasks") {
        None | Some(Value::Null) => return Some(Vec::new()),
        Some(Value::Array(items)) => items,
        Some(_) => return None,
    };

    let mut out = Vec::new();
    for item in tasks {
        let Some(task) = item.as_object() else {
            continue;
        };
        let text = |key: &str| -> String {
            match task.get(key) {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Number(n)) => n.to_string(),
                Some(Value::Bool(b)) => b.to_string(),
                _ => String::new(),
            }
        };
        // Display chain: description, then type, then name — first one that is
        // non-blank *after* scrubbing, so a title of "|||" falls through
        // instead of rendering as spaces.
        let display = ["description", "type", "name"]
            .iter()
            .map(|k| sanitize_display(&text(k)))
            .find(|candidate| !candidate.is_empty())
            .unwrap_or_default();

        let window = match task.get("contextWindowSize") {
            Some(Value::Number(n)) => n.as_u64().filter(|w| *w > 0),
            Some(Value::String(s)) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
                s.parse().ok().filter(|w: &u64| *w > 0)
            }
            _ => None,
        };
        let tokens = match task.get("tokenCount") {
            Some(Value::Number(n)) => n.as_u64().unwrap_or(0),
            Some(Value::String(s)) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
                s.parse().unwrap_or(0)
            }
            _ => 0,
        };

        // Scrubbed here, where the scripts scrubbed. These three land in the
        // `|`-separated task record, so a `|` in any of them shifts every later
        // field on read-back; `display` is already scrubbed above for the same
        // reason. The sink also scrubs, which still covers records an older
        // binary wrote, but by then the field boundaries are already lost.
        let candidate = FeedTask {
            id: text("id"),
            display,
            status: text("status"),
            model: sanitize_display(&text("model")),
            window,
            tokens,
            start: sanitize_display(&text("startTime")),
            effort: sanitize_display(&text("effort")),
        };
        // A row with no identity at all carries nothing to render.
        if candidate.id.is_empty()
            && candidate.display.is_empty()
            && candidate.status.is_empty()
            && candidate.model.is_empty()
        {
            continue;
        }
        out.push(candidate);
    }
    Some(out)
}

/// The per-task state file that carries the done stamp across refreshes.
fn task_state_path(temp: &Path, session_id: &str, task_id: &str) -> Option<PathBuf> {
    let session = session::sanitize_session_id(session_id);
    let task = session::sanitize_session_id(task_id);
    if session.is_empty() || task.is_empty() {
        return None;
    }
    Some(temp.join(format!("statusline-sa-{session}-task-{task}.txt")))
}

/// The per-agent state file the fallback tier keys on.
///
/// Deliberately `-<base>` and never `-task-<id>`: `disappeared_rows` scans the
/// `-task-` prefix, and a fallback file landing in that namespace would be read
/// back as a vanished feed task and rendered a second time. The scripts kept the
/// two apart the same way.
fn agent_state_path(temp: &Path, session_id: &str, agent_base: &str) -> Option<PathBuf> {
    let session = session::sanitize_session_id(session_id);
    let base = session::sanitize_session_id(agent_base);
    if session.is_empty() || base.is_empty() {
        return None;
    }
    Some(temp.join(format!("statusline-sa-{session}-{base}.txt")))
}

/// The per-agent record:
/// `mtime|stop_reason|input|cache_write|cache_read|model|display|done`.
///
/// Field order is the scripts' verbatim, because this is the same *format* on
/// disk: reading one back under a different layout would mean a wrong token
/// count rather than a miss.
///
/// The *location* changed, and that is why the qualifier matters. These now live
/// under `<temp>/claude-statusline-<owner>/`, so a user upgrading mid-session
/// leaves the old flat files behind unread rather than reading them wrongly. The
/// records are reconstructable from the transcripts, so the cost is one re-scan
/// — see the accepted divergence in `docs/performance.md` §4.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct AgentState {
    mtime: i64,
    stop_reason: String,
    input_tokens: u64,
    cache_write_tokens: u64,
    cache_read_tokens: u64,
    model: String,
    display: String,
    done_at: Option<i64>,
}

impl AgentState {
    fn parse(raw: &str) -> Option<Self> {
        let fields: Vec<&str> = raw.trim_end_matches(['\r', '\n']).split('|').collect();
        // The scripts wrote exactly eight. A shorter record is a torn or
        // foreign file, and guessing at it would render a confident wrong
        // number -- the one outcome the silent-degradation contract cannot
        // announce.
        if fields.len() != 8 {
            return None;
        }
        let at = |i: usize| fields[i];
        Some(Self {
            mtime: at(0).parse().ok()?,
            stop_reason: at(1).to_string(),
            input_tokens: at(2).parse().unwrap_or(0),
            cache_write_tokens: at(3).parse().unwrap_or(0),
            cache_read_tokens: at(4).parse().unwrap_or(0),
            model: at(5).to_string(),
            display: at(6).to_string(),
            done_at: at(7).parse().ok(),
        })
    }

    fn to_line(&self) -> String {
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}",
            self.mtime,
            scrub_field(&self.stop_reason),
            self.input_tokens,
            self.cache_write_tokens,
            self.cache_read_tokens,
            scrub_field(&self.model),
            scrub_field(&self.display),
            self.done_at.map(|d| d.to_string()).unwrap_or_default()
        )
    }

    fn used(&self) -> u64 {
        self.input_tokens
            .saturating_add(self.cache_write_tokens)
            .saturating_add(self.cache_read_tokens)
    }
}

/// Keeps a `|` in a value from shifting every later field on read-back.
fn scrub_field(s: &str) -> String {
    s.chars()
        .map(|c| if c == '|' || c.is_control() { ' ' } else { c })
        .collect()
}

/// The per-task record: `tokens|window|model|display|done|start|effort`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct TaskState {
    tokens: u64,
    window: u64,
    model: String,
    display: String,
    done_at: Option<i64>,
    start: String,
    effort: String,
}

impl TaskState {
    fn parse(raw: &str) -> Self {
        let fields: Vec<&str> = raw.trim_end_matches(['\r', '\n']).split('|').collect();
        let at = |i: usize| fields.get(i).copied().unwrap_or_default();
        Self {
            tokens: at(0).parse().unwrap_or(0),
            window: at(1).parse().unwrap_or(0),
            model: at(2).to_string(),
            display: at(3).to_string(),
            done_at: at(4).parse().ok(),
            start: at(5).to_string(),
            effort: at(6).to_string(),
        }
    }

    fn to_line(&self) -> String {
        format!(
            "{}|{}|{}|{}|{}|{}|{}",
            self.tokens,
            self.window,
            self.model,
            self.display,
            self.done_at.map(|d| d.to_string()).unwrap_or_default(),
            self.start,
            self.effort
        )
    }
}

/// Builds the feed tier's rows, stamping and expiring done markers as it goes.
///
/// Returns `None` when the payload is not a feed at all, which is what sends
/// the caller to the fallback tier.
pub fn rows_from_feed(
    clock: &dyn Clock,
    temp: &crate::session::StateRoot,
    session_id: &str,
    feed_json: &str,
    windows: &Windows,
) -> Option<Vec<Row>> {
    let tasks = parse_feed(feed_json)?;
    let now = clock.now_unix();
    let mut seen: Vec<String> = Vec::new();
    // Sorted by the same key the scripts sort on — start time, then id — so the
    // row order is stable across refreshes rather than following feed order.
    let mut candidates: Vec<(String, Row)> = Vec::new();

    for task in &tasks {
        let safe_id = session::sanitize_session_id(&task.id);
        if !safe_id.is_empty() {
            seen.push(safe_id);
        }
        let window = task.window.unwrap_or_else(|| windows.resolve(&task.model));
        let path = task_state_path(temp, session_id, &task.id);
        let previous = path
            .as_deref()
            .and_then(state::read_trusted)
            .and_then(|b| String::from_utf8(b).ok())
            .map(|t| TaskState::parse(&t));

        let done_at = if status_is_active(&task.status) {
            None
        } else {
            // First observation stamps; later ones keep the original stamp so
            // the linger measures from completion, not from noticing.
            Some(previous.as_ref().and_then(|p| p.done_at).unwrap_or(now))
        };

        if let Some(path) = path.as_deref() {
            let record = TaskState {
                tokens: task.tokens,
                window,
                model: task.model.clone(),
                display: task.display.clone(),
                done_at,
                start: task.start.clone(),
                effort: task.effort.clone(),
            };
            // Only when it changed. The token record and the learned map both
            // already skip an unchanged write; this store rewrote every visible
            // task's file on every tick, which is most ticks of a long task.
            if previous.as_ref() != Some(&record) {
                let outcome = state::write_guarded_under(temp, path, record.to_line().as_bytes());
                if outcome != state::WriteOutcome::Written {
                    let p = path.display().to_string();
                    debug::log(move || {
                        format!("subagent: task state not persisted to {p}: {outcome:?}")
                    });
                }
            }
        }

        if let Some(stamp) = done_at {
            if now - stamp > DONE_LINGER_SECS {
                continue;
            }
        }
        candidates.push((
            sort_key(&task.start, &task.id),
            Row {
                used: task.tokens,
                window,
                model: task.model.clone(),
                display: task.display.clone(),
                effort: task.effort.clone(),
                done: done_at.is_some(),
            },
        ));
    }

    candidates.extend(disappeared_rows(clock, temp, session_id, &seen));
    candidates.sort_by(|a, b| a.0.cmp(&b.0));
    let count = candidates.len();
    debug::log(move || format!("subagents: feed tier, {count} row(s)"));
    Some(candidates.into_iter().map(|(_, row)| row).collect())
}

/// A task that has a state file but is no longer in a fresh feed has finished.
///
/// This is the second done signal, and it is the one that catches a task which
/// completes and leaves the feed in the same tick — the status-based signal
/// never sees those.
fn disappeared_rows(
    clock: &dyn Clock,
    temp: &crate::session::StateRoot,
    session_id: &str,
    seen: &[String],
) -> Vec<(String, Row)> {
    let session = session::sanitize_session_id(session_id);
    if session.is_empty() {
        return Vec::new();
    }
    // `strip_prefix`, never a greedy scan for the last `-task-`: bash uses
    // `${file##*-task-}`, so an id that itself contains `-task-` — including
    // the ordinary `task-0001` — resolves to a suffix that never matches the
    // seen list, and a running task is rendered a second time as `done`.
    let prefix = format!("statusline-sa-{session}-task-");
    let now = clock.now_unix();
    let Ok(entries) = std::fs::read_dir(temp) else {
        return Vec::new();
    };

    let mut out = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(id) = name
            .strip_prefix(&prefix)
            .and_then(|rest| rest.strip_suffix(".txt"))
        else {
            continue;
        };
        if seen.iter().any(|s| s == id) {
            continue;
        }
        let path = entry.path();
        let Some(bytes) = state::read_trusted(&path) else {
            continue;
        };
        let Ok(text) = String::from_utf8(bytes) else {
            continue;
        };
        let mut record = TaskState::parse(&text);

        let stamp = match record.done_at {
            Some(stamp) => stamp,
            None => {
                record.done_at = Some(now);
                // A stamp that never lands re-stamps `now` on every later tick,
                // so the row lingers indefinitely instead of for
                // `DONE_LINGER_SECS`. Nothing else can report that.
                let outcome = state::write_guarded_under(temp, &path, record.to_line().as_bytes());
                if outcome != state::WriteOutcome::Written {
                    let p = path.display().to_string();
                    debug::log(move || {
                        format!("subagent: done stamp not persisted to {p}: {outcome:?}")
                    });
                }
                now
            }
        };
        if now - stamp > DONE_LINGER_SECS {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        out.push((
            sort_key(&record.start, id),
            Row {
                used: record.tokens,
                window: record.window,
                model: record.model,
                display: record.display,
                effort: record.effort,
                done: true,
            },
        ));
    }
    out
}

/// The scripts join the row fields with `\x1f` and byte-sort the result, so the
/// effective key is start time then id. Reproduced literally rather than as a
/// tuple compare, because `\x1f` sorts below every printable byte and that is
/// what makes a short start time sort before a longer one sharing its prefix.
fn sort_key(start: &str, id: &str) -> String {
    format!("{start}\u{1f}{id}")
}

// --- Fallback tier -------------------------------------------------------

/// Where per-agent transcripts live, derived from the session transcript path:
/// `<project>/<session-base>/subagents/`.
pub fn subagents_dir(transcript_path: &str) -> Option<PathBuf> {
    let path = Path::new(transcript_path);
    let parent = path.parent()?;
    let stem = path.file_stem()?.to_str()?;
    Some(parent.join(stem).join("subagents"))
}

/// A terminal stop reason means the agent is finished. `tool_use`, `pause_turn`
/// and "no assistant message yet" all mean it is still working.
pub fn stop_reason_is_done(stop_reason: &str) -> bool {
    matches!(
        stop_reason,
        "end_turn" | "max_tokens" | "refusal" | "model_context_window_exceeded" | "stop_sequence"
    )
}

/// What one agent transcript's last assistant entry reports.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct AgentReading {
    pub stop_reason: String,
    pub input_tokens: u64,
    pub cache_write_tokens: u64,
    pub cache_read_tokens: u64,
    pub model: String,
}

impl AgentReading {
    pub fn used(&self) -> u64 {
        self.input_tokens
            .saturating_add(self.cache_write_tokens)
            .saturating_add(self.cache_read_tokens)
    }
}

/// Reads the last assistant entry of an agent transcript.
///
/// Unparseable lines are skipped rather than ending the scan: a torn tail is
/// routine in a file being appended to, and the entry before it is still the
/// best available reading.
pub fn read_agent(bytes: &[u8]) -> AgentReading {
    let mut out = AgentReading::default();
    for line in bytes.split(|b| *b == b'\n') {
        let Ok(text) = std::str::from_utf8(line) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        if value.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let message = value.get("message");
        let usage = message.and_then(|m| m.get("usage"));
        let number = |key: &str| -> u64 {
            usage
                .and_then(|u| u.get(key))
                .and_then(Value::as_u64)
                .unwrap_or(0)
        };
        out = AgentReading {
            stop_reason: message
                .and_then(|m| m.get("stop_reason"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            input_tokens: number("input_tokens"),
            cache_write_tokens: number("cache_creation_input_tokens"),
            cache_read_tokens: number("cache_read_input_tokens"),
            model: message
                .and_then(|m| m.get("model"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        };
    }
    out
}

/// The display title for a fallback row: the meta file's description, then its
/// agent type, then the agent id from the filename.
pub fn agent_display(meta: Option<&str>, agent_base: &str) -> String {
    if let Some(raw) = meta {
        if let Ok(value) = serde_json::from_str::<Value>(raw) {
            for key in ["description", "agentType"] {
                let candidate =
                    sanitize_display(value.get(key).and_then(Value::as_str).unwrap_or_default());
                if !candidate.is_empty() {
                    return candidate;
                }
            }
        }
    }
    sanitize_display(agent_base.strip_prefix("agent-").unwrap_or(agent_base))
}

/// Builds the fallback tier's rows by parsing each agent transcript.
pub fn rows_from_transcripts(
    clock: &dyn Clock,
    temp: &crate::session::StateRoot,
    session_id: &str,
    transcript_path: &str,
    windows: &Windows,
) -> Vec<Row> {
    let Some(dir) = subagents_dir(transcript_path) else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let now = clock.now_unix();

    let mut rows: Vec<(String, Row)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with("agent-") || !name.ends_with(".jsonl") {
            continue;
        }
        if !path.is_file() {
            continue;
        }
        // An agent file that has not moved in three minutes belongs to an
        // earlier run, not to anything this session is waiting on.
        let mtime = clock.mtime_unix(&path).unwrap_or(0);
        if now - mtime > FALLBACK_MAX_AGE_SECS {
            continue;
        }

        let base = name.trim_end_matches(".jsonl");
        let state_path = agent_state_path(temp, session_id, base);

        // The record from a previous tick, when there is a trustworthy one.
        let previous = state_path
            .as_deref()
            .and_then(state::read_trusted)
            .and_then(|b| String::from_utf8(b).ok())
            .and_then(|t| AgentState::parse(&t));

        // The whole point of the record: an agent file whose mtime has not
        // moved is re-read from the previous tick's fields instead of from
        // disk. Without it the fallback tier re-read and re-parsed every agent
        // transcript on every refresh -- the same unconditional-scan cost that
        // made the main transcript 4x slower than the script it replaced, in
        // the tier that runs whenever the tasks feed is unavailable.
        // The scripts' `sa_cache_dirty`: a fresh read, or a stamp that moved.
        // Anything else leaves the file alone rather than rewriting an
        // identical line on every refresh.
        let mut dirty = false;
        let mut record = match previous {
            Some(prev) if prev.mtime == mtime => prev,
            prev => {
                let Ok(bytes) = std::fs::read(&path) else {
                    continue;
                };
                let reading = read_agent(&bytes);
                let meta = std::fs::read_to_string(dir.join(format!("{base}.meta.json"))).ok();
                dirty = true;
                AgentState {
                    mtime,
                    stop_reason: reading.stop_reason,
                    input_tokens: reading.input_tokens,
                    cache_write_tokens: reading.cache_write_tokens,
                    cache_read_tokens: reading.cache_read_tokens,
                    model: reading.model,
                    display: agent_display(meta.as_deref(), base),
                    // Carried across a re-read: the stamp records when the
                    // completion was first *seen*, and re-stamping it on every
                    // content change would make the row linger forever.
                    done_at: prev.and_then(|p| p.done_at),
                }
            }
        };

        // A terminal stop reason stamps once and keeps its stamp; anything else
        // clears it, so an agent that resumes is not still carrying a
        // completion time from earlier.
        let done = stop_reason_is_done(&record.stop_reason);
        match (done, record.done_at) {
            (true, None) => {
                record.done_at = Some(now);
                dirty = true;
            }
            (false, Some(_)) => {
                record.done_at = None;
                dirty = true;
            }
            _ => {}
        }

        if dirty {
            if let Some(p) = state_path.as_deref() {
                let outcome = state::write_guarded_under(temp, p, record.to_line().as_bytes());
                if outcome != state::WriteOutcome::Written {
                    let path = p.display().to_string();
                    debug::log(move || {
                        format!("subagent: agent state not persisted to {path}: {outcome:?}")
                    });
                }
            }
        }

        // The linger the module doc promises for *both* tiers. The port had it
        // on the feed tier only, so a finished fallback row stayed visible for
        // the full 180s staleness window instead of DONE_LINGER_SECS -- a
        // divergence from the scripts (eb56345:linux/statusline.sh:1357) that no
        // fixture covered.
        if done {
            if let Some(stamp) = record.done_at {
                if now - stamp > DONE_LINGER_SECS {
                    continue;
                }
            }
        }

        rows.push((
            sort_key("", base),
            Row {
                used: record.used(),
                window: windows.resolve(&record.model),
                model: record.model.clone(),
                display: record.display.clone(),
                // The feed reports an effort override; a transcript cannot, and
                // nothing is inferred from the session's own effort here.
                effort: String::new(),
                done,
            },
        ));
    }

    rows.sort_by(|a, b| a.0.cmp(&b.0));
    let count = rows.len();
    debug::log(move || format!("subagents: fallback tier, {count} row(s)"));
    rows.into_iter().map(|(_, row)| row).collect()
}

/// Whether the tasks feed is fresh enough to be the tier for this refresh.
pub fn feed_is_fresh(clock: &dyn Clock, feed_path: &Path) -> bool {
    matches!(clock.age_secs(feed_path), Some(age) if age <= FEED_TTL_SECS)
}
