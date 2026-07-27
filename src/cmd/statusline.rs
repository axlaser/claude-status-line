//! The status line itself: gather, render, alert (R19, R21, R26, R28).
//!
//! This is the only place the four data sources meet. Everything it calls is
//! either a pure function or a guarded read, and the order is the one the
//! scripts use — the learned map is refreshed before the subagent rows resolve
//! their windows against it, and the alerts fire after the render is already a
//! string, so a slow notification cannot delay the output.
//!
//! There is no output cache (R27). The scripts kept one because a fresh
//! interpreter cost more than the work; the binary recomputes every tick.

use std::path::{Path, PathBuf};

use crate::clock::Clock;
use crate::config::NotifyConfig;
use crate::git::GitStatus;
use crate::notify_state::{self, LatchState};
use crate::payload::Payload;
use crate::render::{self, Inputs};
use crate::session::{sanitize_session_id, temp_dir};
use crate::subagent::{self, Row, Windows};
use crate::transcript::{self, Scan, TokenRecord};

/// The two filesystem roots every state path hangs off.
///
/// Passed rather than read from the environment at each use site. The scripts
/// had no choice — a shell reads `$HOME` wherever it stands — but ambient reads
/// make the render path untestable in-process, and R30 requires a case to pin
/// every render input, which these are. `from_env` is the production
/// construction and the only place the variables are consulted.
pub struct Roots {
    pub home: Option<PathBuf>,
    pub temp: PathBuf,
}

impl Roots {
    pub fn from_env() -> Self {
        Self {
            home: crate::home_dir(),
            temp: temp_dir(),
        }
    }

    fn claude_dir(&self) -> Option<PathBuf> {
        self.home.as_ref().map(|h| h.join(".claude"))
    }

    /// Where the learned model→window map lives.
    pub fn model_windows_path(&self) -> Option<PathBuf> {
        self.claude_dir()
            .map(|d| d.join("statusline-model-windows.json"))
    }

    fn notify_config_path(&self) -> Option<PathBuf> {
        self.claude_dir().map(|d| d.join("notify-config.json"))
    }
}

/// Renders one refresh and fires whatever alerts it crossed.
///
/// Returns the bytes to write to stdout. Degraded input returns the bad-JSON
/// notice and does nothing else — no state is read, written, or invalidated,
/// because a tick that could not be understood must not overwrite what the
/// last good tick recorded.
pub fn run(clock: &dyn Clock, roots: &Roots, raw: &str) -> String {
    let Some(payload) = Payload::parse(raw) else {
        return render::BAD_JSON.to_string();
    };

    let home_str = roots
        .home
        .as_deref()
        .and_then(Path::to_str)
        .map(str::to_owned);
    let session_id = payload.session_id().to_string();

    let git = git_status(clock, roots, &payload, &session_id);
    let (scan, record) = transcript_state(clock, roots, &payload, &session_id);

    // Refreshed before the rows resolve, so a session on a newly seen model
    // gives its own subagents a real denominator on the very first refresh
    // rather than one tick later.
    let learned = learn_and_load(roots, &payload);
    let windows = Windows::new(payload.model_id(), payload.context_window_size(), learned);
    let subagents = subagent_rows(clock, roots, &payload, &session_id, &windows);

    let output = render::render(&Inputs {
        payload: &payload,
        home: home_str.as_deref(),
        git: git.as_ref(),
        scan: scan.as_ref(),
        record: record.as_ref(),
        subagents: &subagents,
        now: clock.now_unix(),
    });

    fire_alerts(roots, &payload, &session_id, &output);
    output
}

fn git_status(
    clock: &dyn Clock,
    roots: &Roots,
    payload: &Payload,
    session_id: &str,
) -> Option<GitStatus> {
    let cwd = crate::git::resolve_cwd(payload.git_cwd());
    crate::git::status(clock, &roots.temp, &cwd, session_id)
}

/// This tick's totals, and the record that carries the per-bucket deltas.
///
/// The totals always come from this tick's scan; only the deltas come from the
/// stored record (R28). That is what lets the head checksum the scripts needed
/// go away: they cached the totals, so a same-size rewrite was invisible.
fn transcript_state(
    clock: &dyn Clock,
    roots: &Roots,
    payload: &Payload,
    session_id: &str,
) -> (Option<Scan>, Option<TokenRecord>) {
    let path = payload.transcript_path();
    if path.is_empty() {
        return (None, None);
    }
    let path = Path::new(path);
    let Ok(meta) = std::fs::metadata(path) else {
        return (None, None);
    };
    let size = meta.len();
    let mtime = clock.mtime_unix(path).unwrap_or(0);

    let record_path = transcript::record_path(&roots.temp, session_id);
    let previous = record_path
        .as_deref()
        .and_then(crate::state::read_trusted)
        .and_then(|b| String::from_utf8(b).ok())
        .and_then(|t| TokenRecord::parse(&t));

    // An unchanged transcript is not read at all. Everything the tokens row and
    // the model row render is already in the record, so re-scanning reproduces
    // it byte for byte at the cost of the whole file.
    //
    // This is the one place the port keeps a *computation* cache, and it is
    // here on measured grounds rather than by symmetry with the scripts. R38's
    // statusline pair found the unconditional rescan costing ~50 ms on an 8 MB
    // transcript, which is invisible next to PowerShell's ~124 ms interpreter
    // floor but is four times bash's entire tick — so dropping the scripts'
    // incremental parser (R27) was right on Windows and a regression on Linux.
    // A static transcript is what a session looks like between messages, which
    // is most ticks.
    //
    // What U12 gave up to always scan was noticing a same-size rewrite. That
    // trade is reversed here deliberately: transcripts are append-only JSONL,
    // a rewrite landing on the byte-identical length is close to unreachable,
    // and the mtime has to match as well. The scripts' version of this bug came
    // from caching totals behind a key that could go stale *and* having no
    // second signal; `(mtime, size)` together is that second signal.
    if let Some(record) = previous
        .clone()
        .filter(|p| p.mtime == mtime && p.size == size)
    {
        crate::debug::log(|| "transcript: unchanged, scan skipped".to_string());
        let scan = Scan {
            messages: record.messages,
            input_tokens: record.input_tokens,
            cache_write_tokens: record.cache_write_tokens,
            cache_read_tokens: record.cache_read_tokens,
            output_tokens: record.output_tokens,
            idle: record.idle,
            // Not stored and not rendered: `consumed` exists for the scan's own
            // torn-tail bound, and nothing downstream reads it.
            consumed: 0,
        };
        return (Some(scan), Some(record));
    }

    let bytes = std::fs::read(path).unwrap_or_default();
    let scan = transcript::scan(&bytes, Some(size), true);
    let (record, needs_write) = TokenRecord::fold(previous.as_ref(), &scan, mtime, size);

    if needs_write {
        if let Some(p) = record_path.as_deref() {
            crate::state::write_guarded(p, record.to_line().as_bytes());
        }
    }
    (Some(scan), Some(record))
}

/// Merges this session's model→window pair into the learned map and returns
/// the map to resolve against.
///
/// The write is skipped when the entry already matches, so an unchanged pair
/// leaves the file's mtime alone — the scripts key their output cache on that
/// mtime, and churning it every tick would have defeated it.
fn learn_and_load(roots: &Roots, payload: &Payload) -> std::collections::BTreeMap<String, u64> {
    let Some(path) = roots.model_windows_path() else {
        return Default::default();
    };
    let mut map = Windows::load_learned(&path);

    let key = subagent::normalize_model_id(payload.model_id());
    let Some(window) = payload.context_window_size() else {
        return map;
    };
    if key.is_empty() || map.get(&key) == Some(&window) {
        return map;
    }

    // Re-read as the merge base rather than serialising the flattened map: a
    // concurrent session may have learned a different model since the load
    // above, and writing the stale view would drop its entry.
    let mut base = Windows::load_learned(&path);
    base.insert(key.clone(), window);
    let body = serde_json::to_string(&base).unwrap_or_default();
    if !body.is_empty() {
        crate::state::write_guarded(&path, format!("{body}\n").as_bytes());
        crate::debug::log(|| format!("model-windows: learned {key}={window}"));
    }
    map.insert(key, window);
    map
}

/// One tier per refresh, never merged: the feed when it is fresh, else the
/// per-agent transcripts.
fn subagent_rows(
    clock: &dyn Clock,
    roots: &Roots,
    payload: &Payload,
    session_id: &str,
    windows: &Windows,
) -> Vec<Row> {
    let safe = sanitize_session_id(session_id);
    if !safe.is_empty() {
        let feed = crate::cmd::subagent::feed_path(&roots.temp, &safe);
        if subagent::feed_is_fresh(clock, &feed) {
            let json = crate::state::read_trusted(&feed)
                .and_then(|b| String::from_utf8(b).ok())
                .unwrap_or_default();
            if let Some(rows) =
                subagent::rows_from_feed(clock, &roots.temp, session_id, &json, windows)
            {
                return rows;
            }
        }
    }
    subagent::rows_from_transcripts(clock, payload.transcript_path(), windows)
}

/// Reads the latch, decides the edges, spawns what crossed, stores the result.
///
/// `rendered` is taken only so this cannot be called before the render exists —
/// the alert must never sit between the work and the output.
fn fire_alerts(roots: &Roots, payload: &Payload, session_id: &str, rendered: &str) {
    let _ = rendered;
    let Some(path) = notify_state::latch_path(&roots.temp, session_id) else {
        return;
    };
    let config = roots
        .notify_config_path()
        .map(|p| NotifyConfig::load(&p))
        .unwrap_or_default();

    let ctx_pct = payload
        .used_percentage()
        .map(render::round_pct)
        .unwrap_or(0);
    let (rate_max, resets_now) = rate_inputs(payload);

    let decision = notify_state::decide(
        notify_state::read_latch(&path),
        ctx_pct,
        config.threshold("context_high"),
        rate_max,
        config.threshold("rate_limit"),
        &resets_now,
    );

    for alert in &decision.alerts {
        // R44: the per-event flags gate delivery. A muted event still latches,
        // so unmuting mid-window does not immediately fire for a crossing the
        // user already lived through.
        let event = config.event(alert.event);
        if event.sound || event.visual {
            notify_state::spawn(alert);
        }
    }
    if decision.changed && !matches!(notify_state::read_latch(&path), LatchState::Unusable) {
        crate::state::write_guarded(&path, notify_state::latch_json(&decision.latch).as_bytes());
    }
}

/// The higher of the two rate windows, and the `resets_at` that belongs to it.
fn rate_inputs(payload: &Payload) -> (i64, String) {
    let five = payload.rate_five_hour_percentage();
    let seven = payload.rate_seven_day_percentage();
    let five_int = five.map(|v| v.trunc() as i64);
    let seven_int = seven.map(|v| v.trunc() as i64);

    let max = five_int.unwrap_or(0).max(seven_int.unwrap_or(0));
    let resets = match (five_int, seven_int) {
        (Some(f), Some(s)) if s > f => payload.rate_seven_day_resets_at(),
        (None, Some(_)) => payload.rate_seven_day_resets_at(),
        _ => payload.rate_five_hour_resets_at(),
    };
    (max, resets.to_string())
}
