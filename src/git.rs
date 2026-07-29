//! The git row: branch, working-tree counts, upstream divergence, and stashes.
//!
//! Git is invoked as a subprocess. The alternative — a pure-Rust
//! implementation — would mean reimplementing git's *configuration* surface,
//! not just its data: `core.autocrlf` normalisation applied before
//! `--shortstat` counts lines, `.gitattributes` binary and textconv rules,
//! rename detection, and the untracked-directory collapsing that makes a whole
//! new directory count as one entry. Fixtures are captured on default-config
//! scratch repos, so a divergence in that surface would pass CI and then render
//! a plausible wrong number on a user's machine, where the silent-degradation
//! contract guarantees it never announces itself. Calling `git` cannot diverge
//! from `git`.
//!
//! [`parse_porcelain_v2`] is deliberately a pure function over text: it
//! unit-tests without a repository, and it is the seam a later `gix`
//! evaluation would be measured against rather than replacing.
//!
//! The 5-second TTL is ported because subprocess cost is real — 73.9 ms
//! for the pair on the maintainer's Windows machine. Its expiry is also a
//! correctness device, not only a cost dodge: the cache is keyed on
//! `.git/index` mtime, and that key is incomplete. Creating an untracked file
//! does not touch the index, and `git fetch` writes `FETCH_HEAD` and
//! `packed-refs` rather than the index, so without the expiry those rows would
//! stay wrong indefinitely instead of merely being recomputed less often.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::clock::Clock;
use crate::debug;
use crate::session;
use crate::state;

/// How long a cached git reading may be reused. See the module note: this is a
/// staleness bound as much as a cache lifetime.
pub const TTL_SECS: i64 = 5;

/// The field separator in the cache record, matching the scripts byte for byte.
const SEP: char = '\x1f';

/// Everything the git row renders.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GitStatus {
    /// Empty means "render no git segment" — no repository, an unreadable one,
    /// or the unborn-HEAD case below.
    pub branch: String,
    pub insertions: u64,
    pub deletions: u64,
    pub untracked: u64,
    pub ahead: u64,
    pub behind: u64,
    pub stash: u64,
}

/// The raw readings of one `--porcelain=v2 --branch --show-stash` run, before
/// the branch traps are applied.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Porcelain {
    pub branch: String,
    /// `(initial)` on an unborn HEAD — a sentinel, not an object id.
    pub head_oid: String,
    pub untracked: u64,
    pub ahead: u64,
    pub behind: u64,
    pub stash: u64,
}

/// Parses porcelain v2 output. Pure over text, so every trap below is testable
/// without constructing the repository state that produces it.
///
/// The traps, all of which are real output git emits:
///
/// - **No `# branch.ab` line** when the branch has no upstream. Ahead and
///   behind stay 0 rather than being treated as missing data.
/// - **No `# stash` line** when there are no stashes, rather than a zero.
/// - **`# branch.oid (initial)`** on an unborn HEAD, where the field that
///   normally carries a hash carries a word instead.
/// - **`# branch.head (detached)`**, which a branch may also literally be
///   *named*. This function reports what git said; disambiguating is
///   [`resolve_branch`]'s job, and it costs another subprocess.
pub fn parse_porcelain_v2(text: &str) -> Porcelain {
    let mut out = Porcelain::default();
    for line in text.split('\n') {
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            out.branch = rest.to_string();
        } else if let Some(rest) = line.strip_prefix("# branch.oid ") {
            out.head_oid = rest.to_string();
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            // `+3 -0`. The scripts take the first space-delimited token and the
            // last, then strip one leading sign from each, so a malformed line
            // with no space reads both counts from the same token.
            out.ahead = digits(
                first_token(rest)
                    .strip_prefix('+')
                    .unwrap_or(first_token(rest)),
            );
            out.behind = digits(
                last_token(rest)
                    .strip_prefix('-')
                    .unwrap_or(last_token(rest)),
            );
        } else if let Some(rest) = line.strip_prefix("# stash ") {
            out.stash = digits(rest);
        } else if line.starts_with("? ") {
            out.untracked += 1;
        }
    }
    out
}

/// `^[0-9]+$` or zero, which is the scripts' guard against a malformed field
/// reaching arithmetic.
fn digits(s: &str) -> u64 {
    if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) {
        s.parse().unwrap_or(0)
    } else {
        0
    }
}

fn first_token(s: &str) -> &str {
    match s.find(' ') {
        Some(i) => &s[..i],
        None => s,
    }
}

fn last_token(s: &str) -> &str {
    match s.rfind(' ') {
        Some(i) => &s[i + 1..],
        None => s,
    }
}

/// Pulls the first `N insertion` / `N deletion` counts out of
/// `git diff --shortstat` output.
///
/// Absent counts stay zero: `--shortstat` omits the clause entirely when a side
/// is empty, so ` 1 file changed, 3 insertions(+)` has no deletion count rather
/// than a zero one.
pub fn parse_shortstat(text: &str) -> (u64, u64) {
    (
        count_before(text, " insertion"),
        count_before(text, " deletion"),
    )
}

/// The digit run immediately preceding `label`, mirroring the scripts'
/// `([0-9]+)\ <label>` match. Occurrences without a digit run are skipped
/// rather than ending the search, which is what backtracking would do.
fn count_before(text: &str, label: &str) -> u64 {
    let bytes = text.as_bytes();
    let mut from = 0;
    while let Some(rel) = text[from..].find(label) {
        let at = from + rel;
        let mut start = at;
        while start > 0 && bytes[start - 1].is_ascii_digit() {
            start -= 1;
        }
        if start < at {
            return text[start..at].parse().unwrap_or(0);
        }
        from = at + 1;
    }
    0
}

/// Applies the two branch traps to a porcelain reading.
///
/// `detached_hash` is consulted only when git reported the `(detached)`
/// sentinel; it is a closure so the extra subprocess is not paid by a branch
/// that merely *is* named `(detached)` in a test.
///
/// Unborn HEAD renders **no git segment, on every platform**. This is a
/// resolved divergence, not an accident — it breaks Windows,
/// which substitutes the literal `HEAD`.
///
/// The deciding argument is coherence rather than majority. A bare `git init`
/// has no `.git/index`, and the whole git block is guarded on that file, so
/// that repo already renders no git segment anywhere and cannot be changed
/// without redesigning the index-mtime cache key. Keeping Windows' literal
/// would make the row's presence depend on whether an index file happens to
/// exist — invisible to the user, and arbitrary. `HEAD` is also simply wrong:
/// porcelain reports `# branch.head main`, so the branch has a name.
pub fn resolve_branch(p: &Porcelain, detached_hash: impl FnOnce() -> Option<String>) -> String {
    if p.branch == "(detached)" {
        // Ask git for the abbreviation rather than truncating the oid: git
        // lengthens abbreviations for uniqueness, so a fixed width would
        // disagree with what git itself prints in the same repository.
        return match detached_hash() {
            Some(h) if !h.is_empty() => h,
            _ => "HEAD".to_string(),
        };
    }
    if p.head_oid == "(initial)" {
        return String::new();
    }
    p.branch.clone()
}

/// Where this session's git reading is cached.
///
/// Same name and same record shape as the scripts, deliberately: `git-refresh`
/// already ports the deletion of exactly `statusline-git-<id>.txt`, so a binary
/// that cached anywhere else would keep a stale git row alive through every
/// file-modifying tool call.
/// `temp` is passed rather than read from the environment so a fixture replay
/// can stage a clean root per case. Ambient reads would make the whole render
/// path untestable in-process, and every render input has to be pinnable.
pub fn cache_path(temp: &Path, session_id: &str) -> Option<PathBuf> {
    let safe = session::sanitize_session_id(session_id);
    if safe.is_empty() {
        return None;
    }
    Some(temp.join(format!("statusline-git-{safe}.txt")))
}

/// Parses a cache record into the index mtime it was taken at and its reading.
pub fn parse_cache_record(raw: &str) -> Option<(i64, GitStatus)> {
    let fields: Vec<&str> = raw.trim_end_matches(['\r', '\n']).split(SEP).collect();
    if fields.len() != 8 {
        return None;
    }
    let mtime = fields[0].parse().ok()?;
    Some((
        mtime,
        GitStatus {
            branch: fields[1].to_string(),
            insertions: digits(fields[2]),
            deletions: digits(fields[3]),
            untracked: digits(fields[4]),
            ahead: digits(fields[5]),
            behind: digits(fields[6]),
            stash: digits(fields[7]),
        },
    ))
}

/// Renders a cache record. The numeric fields are re-read through [`digits`] on
/// the way back in, so a planted value costs a zero rather than reaching
/// arithmetic.
pub fn cache_record(index_mtime: i64, s: &GitStatus) -> String {
    format!(
        "{}{SEP}{}{SEP}{}{SEP}{}{SEP}{}{SEP}{}{SEP}{}{SEP}{}",
        index_mtime, s.branch, s.insertions, s.deletions, s.untracked, s.ahead, s.behind, s.stash
    )
}

/// The directory the git row describes: the payload's workspace directory, or
/// this process's own when the payload had none.
pub fn resolve_cwd(payload_git_cwd: &str) -> PathBuf {
    if payload_git_cwd.is_empty() {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    } else {
        PathBuf::from(payload_git_cwd)
    }
}

/// Reads the git row, through the cache when it is fresh.
///
/// `None` means no git segment renders. The `.git/index` test is what decides
/// that, and it is the scripts' test verbatim — which also means a linked
/// worktree or a submodule, where `.git` is a file rather than a directory,
/// renders no git row today. Ported as-is; changing it would be a feature.
pub fn status(clock: &dyn Clock, temp: &Path, cwd: &Path, session_id: &str) -> Option<GitStatus> {
    let index = cwd.join(".git").join("index");
    if !index.is_file() {
        return None;
    }
    let index_mtime = clock.mtime_unix(&index).unwrap_or(0);
    let cache = cache_path(temp, session_id);

    if let Some(path) = cache.as_deref() {
        if let Some(hit) = read_fresh_cache(clock, path, index_mtime) {
            debug::log(|| "git: cache hit".to_string());
            return Some(hit);
        }
    }

    let fresh = read_from_git(cwd);

    if let Some(path) = cache.as_deref() {
        // Reported, not discarded. A cache that never lands means every tick
        // pays the subprocess the TTL exists to bound, forever, and the
        // silent-degradation contract guarantees no other signal — which is
        // precisely the blind spot
        // `docs/solutions/best-practices/byte-diff-cannot-see-cache-hit-regressions.md`
        // exists to close. The path is named because a reader triaging a stale
        // row needs to know *which* file refused the write.
        let outcome = state::write_guarded(path, cache_record(index_mtime, &fresh).as_bytes());
        if outcome != state::WriteOutcome::Written {
            let p = path.display().to_string();
            debug::log(move || format!("git: cache not persisted to {p}: {outcome:?}"));
        }
    }
    Some(fresh)
}

fn read_fresh_cache(clock: &dyn Clock, path: &Path, index_mtime: i64) -> Option<GitStatus> {
    let bytes = state::read_trusted(path)?;
    let text = String::from_utf8(bytes).ok()?;
    let (recorded_mtime, status) = parse_cache_record(&text)?;
    if recorded_mtime != index_mtime {
        return None;
    }
    // Age, not "now minus the recorded mtime": the record ages from when it was
    // written, and both halves of the comparison go through the injected clock
    // so a fixture can reach both sides of the boundary without sleeping.
    match clock.age_secs(path) {
        Some(age) if age < TTL_SECS => Some(status),
        _ => None,
    }
}

fn read_from_git(cwd: &Path) -> GitStatus {
    let mut out = GitStatus::default();

    // One porcelain call covers branch, ahead/behind, stash and untracked.
    // `--show-stash` needs git >= 2.15; on older git the whole call fails and
    // the row renders empty through the same path as "no repository".
    let v2 = run_git(
        cwd,
        &["status", "--porcelain=v2", "--branch", "--show-stash"],
    );

    if let Some(text) = v2.as_deref().filter(|t| !t.is_empty()) {
        let parsed = parse_porcelain_v2(text);
        out.untracked = parsed.untracked;
        out.ahead = parsed.ahead;
        out.behind = parsed.behind;
        out.stash = parsed.stash;
        out.branch = resolve_branch(&parsed, || run_git(cwd, &["rev-parse", "--short", "HEAD"]));
    }

    if !out.branch.is_empty() {
        if let Some(stat) = run_git(cwd, &["diff", "--shortstat", "HEAD"]) {
            let (insertions, deletions) = parse_shortstat(&stat);
            out.insertions = insertions;
            out.deletions = deletions;
        }
    }

    out
}

/// How long one `git` invocation may take before it is killed.
///
/// Two seconds is well past any healthy status read on a local repo, and short
/// enough that a stalled one degrades to a missing git row within a tick or two
/// instead of blocking forever. It is deliberately under the 5s cache TTL, so a
/// timing-out repo still refreshes on the same cadence a healthy one does.
const GIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// How often the deadline is checked while the child runs.
const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(5);

/// How long the stdout drain may still take once the child is resolved.
///
/// The child's deadline does not cover the drain: on the kill path there is
/// nothing left of it, and that is exactly the moment the reader needs to
/// notice the closed pipe. A short floor keeps the total bounded — the worst
/// case is `GIT_TIMEOUT` plus this, still under the 5s cache TTL — without
/// discarding output that had already arrived.
const DRAIN_GRACE: std::time::Duration = std::time::Duration::from_millis(250);

/// Runs git and returns its trimmed stdout, or `None` for any failure.
///
/// `--no-optional-locks` keeps a status read from writing the index, which
/// would otherwise make the status line invalidate its own cache on every tick.
/// Trailing newlines are stripped because the scripts read these through `$(…)`,
/// which strips them.
fn run_git(cwd: &Path, args: &[&str]) -> Option<String> {
    let mut command = Command::new("git");
    command
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null());

    #[cfg(windows)]
    {
        // Without this a console window flashes on every refresh when the
        // parent has no console of its own to inherit.
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }

    let stdout = run_bounded(command, GIT_TIMEOUT)?;
    let text = String::from_utf8_lossy(&stdout)
        .trim_end_matches(['\n', '\r'])
        .to_string();
    Some(text)
}

/// Runs a prepared command and returns its raw stdout, bounded end to end:
/// spawn, poll against `timeout`, kill at the deadline, drain under its own
/// grace. `None` for any failure, including the deadline.
///
/// `run_git` is the only production caller — the debug lines keep their `git:`
/// prefix so the log stays greppable. The split is what lets the test file
/// prove the deadline: it hands this a child that sleeps past `timeout` and
/// asserts the kill fires, which the hardcoded `git` invocation could not
/// express without racing `PATH` across the shared test binary.
pub fn run_bounded(mut command: Command, timeout: std::time::Duration) -> Option<Vec<u8>> {
    // Deliberately not `output()`. It blocks until the child exits, with no
    // bound, on the render path — and this process is respawned every couple of
    // seconds, so a repo on a stalled network mount left one blocked process per
    // tick, accumulating without limit. The 5s cache TTL bounds how *often* git
    // runs, never how long it may block.
    command.stdout(Stdio::piped());
    let mut child = match command.spawn() {
        Ok(c) => c,
        Err(e) => {
            debug::log(move || format!("git: cannot run: {e}"));
            return None;
        }
    };

    // Drained on a helper thread: a child that fills the pipe blocks on write,
    // so waiting for exit without reading would deadlock on a large status.
    //
    // The buffer comes back over a channel rather than from `join`, because the
    // drain needs its own bound. Killing the child closes *its* handle on the
    // write end, not every handle: anything `git status` spawned — a
    // `core.fsmonitor` daemon is the ordinary case — inherited the same piped
    // stdout and keeps it open, and on Windows `TerminateProcess` does not
    // touch descendants at all. A `join` here would then block exactly as the
    // unbounded `output()` this replaced did, on the render path, once per
    // tick. The thread is left running in that case: it is blocked on a read
    // that ends when the last writer goes away, and the process exits within
    // milliseconds regardless.
    let mut pipe = child.stdout.take();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(p) = pipe.as_mut() {
            use std::io::Read;
            let _ = p.read_to_end(&mut buf);
        }
        // The receiver is gone when the deadline already passed. Nothing to do
        // about it and nothing to report: the send failing *is* the timeout.
        let _ = tx.send(buf);
    });

    let deadline = std::time::Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    debug::log(|| "git: killed at the deadline".to_string());
                    break None;
                }
                std::thread::sleep(POLL_INTERVAL);
            }
            Err(e) => {
                debug::log(move || format!("git: wait failed: {e}"));
                break None;
            }
        }
    };

    // Whatever is left of the child's deadline, floored at the drain grace so
    // the kill path — where nothing is left of it — still gets a moment.
    let budget = deadline
        .saturating_duration_since(std::time::Instant::now())
        .max(DRAIN_GRACE);
    let stdout = match rx.recv_timeout(budget) {
        Ok(buf) => buf,
        Err(_) => {
            debug::log(|| "git: stdout drain did not finish before the deadline".to_string());
            return None;
        }
    };
    if !status?.success() {
        return None;
    }
    Some(stdout)
}
