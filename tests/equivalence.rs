//! The single integration test file for claude-statusline (R29).
//!
//! Cases live in tables. Every failure names the case, so a red run points at
//! the exact scenario without a second lookup. Fixtures live under
//! `tests/fixtures/` as data files, never as additional test files.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use claude_statusline::clock::{Clock, TestClock};
use claude_statusline::debug;
use claude_statusline::platform;
use claude_statusline::state::{self, WriteOutcome};

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const BIN: &str = env!("CARGO_BIN_EXE_claude-statusline");

struct Run {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

/// Runs the built binary as a fresh process, which is the only way to observe
/// the entry contract: exit code and stderr emptiness are process-level facts.
fn run_bin(args: &[&str], stdin: &str, env: &[(&str, &str)]) -> Run {
    let mut cmd = Command::new(BIN);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().expect("failed to spawn the binary under test");
    child
        .stdin
        .as_mut()
        .expect("stdin was not piped")
        .write_all(stdin.as_bytes())
        .expect("failed to write stdin");
    let out = child.wait_with_output().expect("failed to collect output");
    Run {
        code: out.status.code(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

fn scratch_dir(case: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("claude-statusline-test-{case}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("failed to create the scratch directory");
    dir
}

/// Collects failures so one run reports every broken case rather than stopping
/// at the first.
#[derive(Default)]
struct Failures(Vec<String>);

impl Failures {
    fn check(&mut self, case: &str, ok: bool, detail: impl FnOnce() -> String) {
        if !ok {
            self.0.push(format!("  [{case}] {}", detail()));
        }
    }

    fn assert_empty(self, what: &str) {
        assert!(
            self.0.is_empty(),
            "{what} failed for {} case(s):\n{}",
            self.0.len(),
            self.0.join("\n")
        );
    }
}

// ---------------------------------------------------------------------------
// Entry contract (R21, R22 / AE3, AE4)
// ---------------------------------------------------------------------------

struct EntryCase {
    name: &'static str,
    args: &'static [&'static str],
    stdin: &'static str,
}

/// Every subcommand exits 0 and writes nothing to stderr, whatever it is fed.
/// This is the contract `CLAUDE.md` calls Silent Degradation: breaking it
/// crashes the Claude Code status line for users.
#[test]
fn entry_contract_always_exits_zero_and_silent() {
    let cases = [
        EntryCase {
            name: "empty-stdin",
            args: &[],
            stdin: "",
        },
        EntryCase {
            name: "malformed-json",
            args: &[],
            stdin: "{not json",
        },
        EntryCase {
            name: "truncated-json",
            args: &[],
            stdin: "{\"session_id\":",
        },
        EntryCase {
            name: "json-not-object",
            args: &[],
            stdin: "[1,2,3]",
        },
        EntryCase {
            name: "whitespace-only",
            args: &[],
            stdin: "   \n\t ",
        },
        EntryCase {
            name: "unknown-subcommand",
            args: &["no-such-subcommand"],
            stdin: "",
        },
        EntryCase {
            name: "notify-no-event",
            args: &["notify"],
            stdin: "",
        },
        EntryCase {
            name: "git-refresh-empty",
            args: &["git-refresh"],
            stdin: "",
        },
        EntryCase {
            name: "subagent-empty",
            args: &["subagent"],
            stdin: "",
        },
        // AE4: an unwinding panic must not escape as stderr or a non-zero code.
        EntryCase {
            name: "forced-panic",
            args: &["__panic-probe"],
            stdin: "",
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let run = run_bin(c.args, c.stdin, &[]);
        failures.check(c.name, run.code == Some(0), || {
            format!("expected exit 0, got {:?}", run.code)
        });
        failures.check(c.name, run.stderr.is_empty(), || {
            format!("expected empty stderr, got {:?}", run.stderr)
        });
    }
    failures.assert_empty("entry contract");
}

/// AE5. `std::process::exit` runs no destructors, so a buffered writer dropped
/// unflushed produces empty output that still satisfies every exit-code and
/// stderr assertion above. This is the case that catches that.
#[test]
fn buffered_output_reaches_stdout_before_exit() {
    let run = run_bin(&["self-check"], "", &[]);
    assert_eq!(
        run.code,
        Some(0),
        "self-check should succeed on an unmodified binary"
    );
    assert!(
        !run.stdout.is_empty(),
        "self-check produced no stdout — output was buffered and lost at exit"
    );
    assert!(
        run.stderr.is_empty(),
        "self-check wrote to stderr: {:?}",
        run.stderr
    );
}

/// AE8. The self-check is the installer's only guard against placing a binary
/// that launches but renders wrongly, so it must be able to fail.
#[test]
fn self_check_reports_failure_with_nonzero_exit() {
    let run = run_bin(
        &["self-check"],
        "",
        &[("STATUSLINE_FORCE_SELFCHECK_MISMATCH", "1")],
    );
    assert_eq!(
        run.code,
        Some(1),
        "a forced self-check mismatch must exit non-zero; it is exempt from the exit-0 catch"
    );
}

// ---------------------------------------------------------------------------
// Clock (R26, KTD6)
// ---------------------------------------------------------------------------

/// R26 covers filesystem timestamps as well as wall-clock reads: feed freshness
/// and transcript staleness are both `now - mtime`, so pinning only the clock
/// would leave those comparisons reading real file times.
#[test]
fn test_clock_drives_both_now_and_mtime() {
    let dir = scratch_dir("clock");
    let file = dir.join("state.json");
    std::fs::write(&file, b"{}").unwrap();

    let clock = TestClock::at(1_000_000).with_mtime(&file, 999_000);

    assert_eq!(
        clock.now_unix(),
        1_000_000,
        "now() must come from the injected clock"
    );
    assert_eq!(
        clock.mtime_unix(&file),
        Some(999_000),
        "mtime() must come from the injected clock, not the filesystem"
    );
    assert_eq!(
        clock.age_secs(&file),
        Some(1_000),
        "age must be computed from the injected pair"
    );
}

#[test]
fn test_clock_reports_missing_mtime_for_unknown_path() {
    let clock = TestClock::at(500);
    assert_eq!(clock.mtime_unix(Path::new("/nonexistent/path")), None);
    assert_eq!(clock.age_secs(Path::new("/nonexistent/path")), None);
}

// ---------------------------------------------------------------------------
// State-file guards (R23 / AE11, AE12)
// ---------------------------------------------------------------------------

/// AE12 and the nine-day incident in
/// `docs/solutions/logic-errors/get-acl-unavailable-inverts-trust-check.md`.
/// An owner that cannot be determined must NOT fail the read closed: that
/// inversion silently killed every read-side cache and re-fired the context
/// alert every two seconds for nine days. The symlink rejection is the
/// load-bearing guard; the owner check is defense-in-depth.
#[test]
fn owner_check_fail_direction_matches_the_shipped_fix() {
    struct Case {
        name: &'static str,
        owner: Option<u64>,
        expected: bool,
        why: &'static str,
    }

    let me = 4242u64;
    let cases = [
        Case {
            name: "owned-by-me",
            owner: Some(me),
            expected: true,
            why: "our own file must be trusted",
        },
        Case {
            name: "owned-by-other",
            owner: Some(9999),
            expected: false,
            why: "a foreign-owned file must be rejected",
        },
        Case {
            name: "owner-unresolvable",
            owner: None,
            expected: true,
            why: "an undeterminable owner must degrade to the symlink guard, not fail closed",
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let got = state::owner_check_passes(c.owner, me);
        failures.check(c.name, got == c.expected, || {
            format!("expected {}, got {} — {}", c.expected, got, c.why)
        });
    }
    failures.assert_empty("owner-check fail direction");
}

/// A state file that exists but cannot be parsed reads as its conservative
/// value. For the notification latch that means "already notified", so a
/// corrupt latch suppresses a repeat alert rather than re-firing it every tick.
#[test]
fn unreadable_state_reads_as_its_conservative_value() {
    let dir = scratch_dir("latch");
    let latch = dir.join("statusline-notify-abc.json");
    std::fs::write(&latch, b"\x00\x01 not json at all").unwrap();

    assert!(
        state::latch_reads_as_notified(&latch),
        "an unparseable latch must suppress, not re-fire"
    );
}

/// AE11. A hostile target that cannot be removed must abort the write rather
/// than following the link. On a sticky directory the unlink fails, so a guard
/// that removes-then-writes without re-checking would write through the
/// attacker's symlink into a victim-owned file.
#[test]
fn write_to_hostile_target_is_skipped_not_followed() {
    let dir = scratch_dir("hostile");
    let victim = dir.join("victim.txt");
    let link = dir.join("statusline-state.json");
    std::fs::write(&victim, b"original").unwrap();

    if !make_symlink(&victim, &link) {
        eprintln!("skipped: this platform/session cannot create symlinks unprivileged");
        return;
    }

    let outcome = state::write_guarded(&link, b"attacker-controlled");
    assert!(
        matches!(
            outcome,
            WriteOutcome::Written | WriteOutcome::SkippedHostile
        ),
        "unexpected outcome: {outcome:?}"
    );
    assert_eq!(
        std::fs::read(&victim).unwrap(),
        b"original",
        "the write followed the symlink and clobbered the victim file"
    );
}

#[test]
fn write_to_a_normal_path_succeeds() {
    let dir = scratch_dir("normal-write");
    let target = dir.join("statusline-state.json");
    let outcome = state::write_guarded(&target, b"{\"ok\":true}");
    assert!(
        matches!(outcome, WriteOutcome::Written),
        "unexpected outcome: {outcome:?}"
    );
    assert_eq!(std::fs::read(&target).unwrap(), b"{\"ok\":true}");
}

/// The ownership FFI compiling proves nothing about what it returns. This repo
/// lost nine days to a trust check that answered "untrusted" for every file
/// because its dependency was unavailable in the spawned child process — a
/// failure that was 100% reproducible there and 0% reproducible from a shell.
/// Exercise the real calls, in the real process.
#[test]
fn ownership_resolution_works_in_this_process() {
    let dir = scratch_dir("owner");
    let file = dir.join("mine.json");
    std::fs::write(&file, b"{}").unwrap();

    assert!(
        platform::current_owner().is_some(),
        "current_owner() could not resolve our own identity — the guard would \
         degrade to the symlink check everywhere"
    );
    assert!(
        platform::file_owner(&file).is_some(),
        "file_owner() returned None for a file we just created — the ownership \
         half of the guard is inert"
    );
}

/// The behaviour that actually matters: a file we own round-trips through the
/// guard. If ownership resolution is subtly wrong, this fails while the two
/// `is_some()` assertions above still pass.
#[test]
fn our_own_state_file_round_trips_through_the_guard() {
    let dir = scratch_dir("round-trip");
    let target = dir.join("statusline-state.json");

    let outcome = state::write_guarded(&target, b"{\"notified_context_high\":true}");
    assert!(
        matches!(outcome, WriteOutcome::Written),
        "writing our own file was refused: {outcome:?}"
    );

    let back = state::read_trusted(&target);
    assert!(
        back.is_some(),
        "a file we just wrote read back as untrusted — this is the shape of the \
         nine-day cache-death incident"
    );
    assert!(
        state::latch_reads_as_notified(&target),
        "a latch we wrote with notified_context_high=true did not read as notified"
    );
}

#[cfg(unix)]
fn make_symlink(target: &Path, link: &Path) -> bool {
    std::os::unix::fs::symlink(target, link).is_ok()
}

#[cfg(windows)]
fn make_symlink(target: &Path, link: &Path) -> bool {
    // Requires Developer Mode or elevation; the caller skips when this fails.
    std::os::windows::fs::symlink_file(target, link).is_ok()
}

// ---------------------------------------------------------------------------
// Debug log (R45)
// ---------------------------------------------------------------------------

/// `CLAUDE.md`'s Silent Degradation rule has two halves: never write to stderr,
/// and log errors via `STATUSLINE_DEBUG`. Silencing without logging would make
/// a field failure indistinguishable from no failure.
#[test]
fn debug_log_writes_only_when_enabled() {
    let dir = scratch_dir("debug");
    let log = dir.join("statusline-debug.log");

    debug::log_to(&log, false, || "should not appear".to_string());
    assert!(
        !log.exists(),
        "the log was created while STATUSLINE_DEBUG was unset"
    );

    debug::log_to(&log, true, || "hello from the probe".to_string());
    let body = std::fs::read_to_string(&log).expect("the log should exist once enabled");
    assert!(
        body.contains("hello from the probe"),
        "log body was {body:?}"
    );
}

/// The message closure must not be evaluated when logging is off — this is the
/// Rust equivalent of the PowerShell rule that arguments evaluate before the
/// callee's guard.
#[test]
fn debug_log_does_not_evaluate_its_message_when_disabled() {
    let dir = scratch_dir("debug-lazy");
    let log = dir.join("statusline-debug.log");
    let mut evaluated = false;

    debug::log_to(&log, false, || {
        evaluated = true;
        String::new()
    });

    assert!(
        !evaluated,
        "the message closure ran even though logging was disabled"
    );
}
