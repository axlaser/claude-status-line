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
use claude_statusline::payload::{sanitize_display, Payload};
use claude_statusline::platform;
use claude_statusline::settings;
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
    // A broken pipe here is the child behaving correctly, not a failure: most
    // subcommands exit without ever draining stdin, and the parent's write
    // races that exit. Linux and Windows lose the race often enough to fail the
    // suite; macOS mostly wins it, which is what kept this hidden. Taking the
    // handle also closes it on drop, so a subcommand that *does* read stdin
    // still sees EOF.
    if let Some(mut pipe) = child.stdin.take() {
        let _ = pipe.write_all(stdin.as_bytes());
    }
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

// ---------------------------------------------------------------------------
// Release workflow contract (R2, R3, R36, R43, KTD2 / U2)
// ---------------------------------------------------------------------------
//
// A release workflow is only exercised by pushing a tag, which is a slow and
// irreversible way to learn that an action reference went unpinned or that the
// arm runner label drifted back to an alias. These cases assert the properties
// that are decidable from the file itself, so the tag push only has to prove
// the parts that genuinely need a runner.

fn repo_file(rel: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(rel)
}

/// Reads a repository file with line endings normalised to LF.
///
/// These cases assert structure, not bytes, and a Windows checkout hands them
/// CRLF. Without this a multi-line pattern match silently means something
/// different depending on which platform ran the test.
fn read_repo_file(rel: &str) -> String {
    std::fs::read_to_string(repo_file(rel))
        .unwrap_or_else(|e| panic!("could not read {rel}: {e}"))
        .replace("\r\n", "\n")
}

const RELEASE_WORKFLOW: &str = ".github/workflows/release.yml";

/// R2's six targets, each with the artifact suffix its family carries.
const PUBLISHED_TARGETS: [&str; 6] = [
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
    "x86_64-pc-windows-msvc",
    "aarch64-pc-windows-msvc",
];

/// Every target R2 publishes builds, tests, and is attested. A target that is
/// silently absent ships an installer that resolves a URL returning 404.
#[test]
fn release_workflow_covers_every_published_target() {
    let wf = read_repo_file(RELEASE_WORKFLOW);
    let mut failures = Failures::default();

    for target in PUBLISHED_TARGETS {
        failures.check(target, wf.contains(&format!("target: {target}")), || {
            "missing from the build matrix".to_string()
        });
        failures.check(target, wf.contains(&format!("Attest {target}")), || {
            "has no attestation step, so R4 would ship it unattested".to_string()
        });
    }
    failures.assert_empty("published targets");
}

/// A mutable tag reference is a supply-chain hole: the SHA a release was built
/// with must be the SHA the reference names.
#[test]
fn every_action_reference_is_pinned_to_a_full_sha() {
    let wf = read_repo_file(RELEASE_WORKFLOW);
    let mut failures = Failures::default();
    let mut seen = 0usize;

    for (n, line) in wf.lines().enumerate() {
        let Some((_, reference)) = line.trim().split_once("uses:") else {
            continue;
        };
        let reference = reference.trim();
        seen += 1;
        // Strip the trailing `# v5` comment the pin carries for readability.
        let pin = reference.split('#').next().unwrap_or("").trim();
        let sha = pin.rsplit('@').next().unwrap_or("");
        let pinned = sha.len() == 40 && sha.chars().all(|c| c.is_ascii_hexdigit());
        failures.check(&format!("line {}", n + 1), pinned, || {
            format!("`{pin}` is not pinned to a full 40-character commit SHA")
        });
    }

    assert!(seen > 0, "no `uses:` references found — did the file move?");
    failures.assert_empty("action pinning");
}

/// Approach item 7: alias labels move under you. `windows-latest` silently
/// became a different image more than once, and neither arm label has an alias
/// that resolves to arm at all.
#[test]
fn runner_labels_are_explicit_not_aliases() {
    let wf = read_repo_file(RELEASE_WORKFLOW);
    let mut failures = Failures::default();

    for (n, line) in wf.lines().enumerate() {
        let trimmed = line.trim();
        if !trimmed.starts_with("runner:") && !trimmed.starts_with("runs-on:") {
            continue;
        }
        failures.check(
            &format!("line {}", n + 1),
            !trimmed.contains("-latest"),
            || format!("`{trimmed}` uses a moving alias"),
        );
    }

    for label in ["windows-11-arm", "ubuntu-24.04-arm"] {
        failures.check(label, wf.contains(label), || {
            "the explicit arm runner label is missing".to_string()
        });
    }
    failures.assert_empty("runner labels");
}

/// The workflow grants nothing beyond read at its own scope, and the write
/// grants appear exactly once — on the single attesting and publishing job.
#[test]
fn write_permissions_are_confined_to_the_publishing_job() {
    let wf = read_repo_file(RELEASE_WORKFLOW);

    let scope = wf
        .find("\npermissions:\n")
        .expect("the workflow declares no top-level `permissions:` block");
    let scope_block: String = wf[scope + 1..]
        .lines()
        .take(2)
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        scope_block.contains("contents: read"),
        "workflow scope must be read-only, got:\n{scope_block}"
    );

    let mut failures = Failures::default();
    for grant in [
        "contents: write",
        "id-token: write",
        "attestations: write",
        "artifact-metadata: write",
    ] {
        let count = wf.matches(grant).count();
        failures.check(grant, count == 1, || {
            format!("appears {count} times; it belongs to the publishing job alone")
        });
    }
    failures.assert_empty("elevated permissions");
}

/// R36. Until U17's dogfood gate passes, a stable tag must not be able to
/// publish. The guard is a step rather than a convention so promoting a
/// verification tag by accident fails loudly instead of shipping.
#[test]
fn stable_releases_are_gated_until_parity() {
    let wf = read_repo_file(RELEASE_WORKFLOW);
    assert!(
        wf.contains("name: Parity gate"),
        "the R36 parity gate step is gone — stable tags can now publish"
    );
    assert!(
        wf.contains("--prerelease"),
        "nothing marks verification tags as prereleases, so R5's resolution would pick them up"
    );
}

// ---------------------------------------------------------------------------
// git-refresh (R1, R31, R34 / U5)
// ---------------------------------------------------------------------------
//
// The pilot component. Its observable is the exact set of paths deleted, so
// these cases assert on that set rather than on side effects — a port that
// deleted the right files plus one more would pass any "the cache is gone"
// check.

use claude_statusline::cmd::git_refresh;

/// Characters are removed, not replaced. `../../a/b` becomes `ab`, not
/// `______a_b`: a port that substituted would derive a different filename for
/// the same session and silently stop invalidating anything.
#[test]
fn session_ids_are_sanitised_by_removal() {
    struct Case {
        name: &'static str,
        raw: &'static str,
        want: &'static str,
    }

    let cases = [
        Case {
            name: "plain",
            raw: "fixture-session-0001",
            want: "fixture-session-0001",
        },
        Case {
            name: "traversal",
            raw: "../../fixture/escape",
            want: "fixtureescape",
        },
        Case {
            name: "windows-separators",
            raw: "..\\..\\evil",
            want: "evil",
        },
        Case {
            name: "absolute",
            raw: "/etc/passwd",
            want: "etcpasswd",
        },
        Case {
            name: "underscores-and-dashes-kept",
            raw: "a_b-c",
            want: "a_b-c",
        },
        Case {
            name: "all-stripped",
            raw: "../..",
            want: "",
        },
        Case {
            name: "nul-and-newline",
            raw: "abc\0def\nghi",
            want: "abcdefghi",
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let got = claude_statusline::session::sanitize_session_id(c.raw);
        failures.check(c.name, got == c.want, || {
            format!("{:?} -> {:?}, expected {:?}", c.raw, got, c.want)
        });
    }
    failures.assert_empty("session id sanitisation");
}

/// The session id reaches a filename, so a separator surviving sanitisation
/// would let a hook delete outside the temp directory. This asserts the
/// property directly rather than trusting the sanitiser's unit test.
#[test]
fn no_payload_can_produce_a_path_outside_the_temp_root() {
    let temp = scratch_dir("git-refresh-escape");
    let hostile = [
        "../../../../etc/passwd",
        "..\\..\\..\\Windows\\System32",
        "/absolute/path",
        "C:\\Windows",
        "a/../../b",
        "....//....//x",
    ];

    let mut failures = Failures::default();
    for raw in hostile {
        let payload = serde_json::json!({ "tool_name": "Edit", "session_id": raw }).to_string();
        for path in git_refresh::targets(&payload, &temp) {
            failures.check(raw, path.starts_with(&temp), || {
                format!("escaped the temp root: {}", path.display())
            });
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            failures.check(raw, !name.contains(".."), || {
                format!("filename still carries a traversal: {name}")
            });
        }
    }
    failures.assert_empty("path traversal");
}

/// Only the two performance caches. The tasks feed and the notification latch
/// are data stores under R28 — deleting them here would drop subagent rows and
/// re-fire the context alert on every edit.
#[test]
fn only_the_git_and_output_caches_are_invalidated() {
    let temp = scratch_dir("git-refresh-scope");
    let session = "fixture-session-0001";

    let files = [
        format!("statusline-git-{session}.txt"),
        format!("statusline-oc-{session}.txt"),
        format!("statusline-tasks-{session}.json"),
        format!("statusline-notify-{session}.json"),
        format!("statusline-sa-{session}-task-0001.txt"),
        "unrelated.txt".to_string(),
    ];
    for f in &files {
        std::fs::write(temp.join(f), b"x").unwrap();
    }

    let payload = serde_json::json!({ "tool_name": "Edit", "session_id": session }).to_string();
    git_refresh::run(&payload, &temp);

    let mut failures = Failures::default();
    for f in &files {
        let gone = !temp.join(f).exists();
        let should_go = f.starts_with("statusline-git-") || f.starts_with("statusline-oc-");
        failures.check(f, gone == should_go, || {
            if should_go {
                "should have been deleted but survived".to_string()
            } else {
                "was deleted but is a data store, not a cache".to_string()
            }
        });
    }
    failures.assert_empty("invalidation scope");
}

/// Every degraded input is a no-op, and a tool that cannot change files is too.
#[test]
fn only_file_modifying_tools_invalidate_anything() {
    let temp = scratch_dir("git-refresh-tools");

    struct Case {
        name: &'static str,
        payload: String,
        expect: usize,
    }
    let session = "fixture-session-0001";
    let with =
        |tool: &str| serde_json::json!({ "tool_name": tool, "session_id": session }).to_string();

    let cases = [
        Case {
            name: "Edit",
            payload: with("Edit"),
            expect: 2,
        },
        Case {
            name: "Write",
            payload: with("Write"),
            expect: 2,
        },
        Case {
            name: "MultiEdit",
            payload: with("MultiEdit"),
            expect: 2,
        },
        Case {
            name: "Bash",
            payload: with("Bash"),
            expect: 2,
        },
        Case {
            name: "NotebookEdit",
            payload: with("NotebookEdit"),
            expect: 2,
        },
        Case {
            name: "Read",
            payload: with("Read"),
            expect: 0,
        },
        Case {
            name: "Glob",
            payload: with("Glob"),
            expect: 0,
        },
        Case {
            name: "empty-stdin",
            payload: String::new(),
            expect: 0,
        },
        Case {
            name: "malformed",
            payload: "{not json".to_string(),
            expect: 0,
        },
        Case {
            name: "not-an-object",
            payload: "[1,2,3]".to_string(),
            expect: 0,
        },
        Case {
            name: "no-session-id",
            payload: r#"{"tool_name":"Edit"}"#.to_string(),
            expect: 0,
        },
        Case {
            name: "session-id-sanitises-to-empty",
            payload: r#"{"tool_name":"Edit","session_id":"../.."}"#.to_string(),
            expect: 0,
        },
        Case {
            name: "tool-name-wrong-type",
            payload: r#"{"tool_name":123,"session_id":"abc"}"#.to_string(),
            expect: 0,
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let got = git_refresh::targets(&c.payload, &temp).len();
        failures.check(c.name, got == c.expect, || {
            format!("expected {} target(s), got {got}", c.expect)
        });
    }
    failures.assert_empty("tool matcher");
}

/// A missing cache file is the common case — the status line may not have
/// rendered since the last edit — and must not be an error.
#[test]
fn missing_cache_files_are_a_no_op() {
    let temp = scratch_dir("git-refresh-missing");
    let payload =
        serde_json::json!({ "tool_name": "Edit", "session_id": "nothing-here" }).to_string();
    assert!(
        git_refresh::run(&payload, &temp).is_empty(),
        "reported deleting files that were never there"
    );
}

/// AE-style equivalence against the captured fixture (R31): the set of paths
/// the Rust port deletes must equal the set the script deleted, for the same
/// payload. This is the check the whole harness exists to make possible.
#[test]
fn deleted_paths_match_the_captured_fixtures() {
    let root = repo_file("tests/fixtures/git-refresh");
    let Ok(entries) = std::fs::read_dir(&root) else {
        println!("no git-refresh fixtures captured yet");
        return;
    };

    let mut failures = Failures::default();
    let mut checked = 0usize;

    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let case = dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let meta = std::fs::read_to_string(dir.join("case.json")).unwrap_or_default();
        let payload_rel = json_string_field(&meta, "payload").unwrap_or("");
        let payload = std::fs::read_to_string(repo_file(&format!("tests/harness/{payload_rel}")))
            .unwrap_or_default();

        // Every platform that has been captured must agree with the port. A
        // fixture recorded on a platform this test is not running on is still
        // asserted: the deleted-path set is platform-independent, which is
        // exactly the claim R20 will later have to make about rendered output.
        for platform in ["macos", "linux", "windows"] {
            let expected_path = dir.join("expected").join(format!("{platform}.txt"));
            let Ok(expected_raw) = std::fs::read_to_string(&expected_path) else {
                continue;
            };
            checked += 1;

            let mut expected: Vec<String> = expected_raw
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect();
            expected.sort();

            let temp = scratch_dir(&format!("gr-fixture-{case}-{platform}"));
            // Recreate what the harness supplied, so the port has the same
            // files available to delete that the script did.
            for name in &expected {
                std::fs::write(temp.join(name), b"cache").unwrap();
            }

            let mut got: Vec<String> = git_refresh::run(&payload, &temp)
                .iter()
                .map(|p| {
                    p.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned()
                })
                .collect();
            got.sort();

            failures.check(&format!("{case}/{platform}"), got == expected, || {
                format!("script deleted {expected:?}, port deleted {got:?}")
            });
        }
    }

    println!("compared {checked} captured platform fixture(s)");
    failures.assert_empty("git-refresh fixture equivalence");
}

// ---------------------------------------------------------------------------
// subagent tasks feed (R1, R28, R31, R34 / U6)
// ---------------------------------------------------------------------------
//
// The handler's observable is the exact bytes it writes to the tasks feed, and
// its second contract is that it writes nothing to stdout — output there
// replaces Claude Code's default agent panel rather than adding to it, so an
// accidental byte does not degrade the display, it deletes it.
//
// Field order is part of the observable. The feed's bytes are an input to the
// status line's output-cache key, so a reordering would miss the cache on every
// tick while rendering identically.

use claude_statusline::cmd::subagent;

struct ProjectionCase {
    name: &'static str,
    payload: &'static str,
    /// The exact bytes written, or `None` when the tick must be skipped and the
    /// previous feed left in place.
    want: Option<&'static str>,
}

/// Every state of the tasks-feed contract, resolved to one answer each (R32).
///
/// Two of these record a resolution rather than a port: the shell handlers
/// disagree, and a single behaviour had to be chosen. Both are stored here as
/// literals rather than captured from a script run, which is the mechanism R20
/// prescribes for exactly this situation.
#[test]
fn the_projection_resolves_every_tasks_feed_state() {
    let cases = [
        ProjectionCase {
            name: "drops-absent-and-null-fields",
            payload: r#"{"session_id":"s1","tasks":[{"id":"a","effort":null,"status":"running"}]}"#,
            // `effort` is the field that makes this load-bearing: Claude Code
            // reports it only when the task carries an explicit override, so
            // presence is the signal to render the segment at all. An empty
            // string would render an override that does not exist.
            want: Some(r#"{"tasks":[{"id":"a","status":"running"}]}"#),
        },
        ProjectionCase {
            name: "keeps-falsy-values",
            payload: r#"{"session_id":"s1","tasks":[{"id":"a","tokenCount":0,"description":""}]}"#,
            want: Some(r#"{"tasks":[{"id":"a","description":"","tokenCount":0}]}"#),
        },
        ProjectionCase {
            name: "emits-fields-in-reader-order",
            payload: r#"{"session_id":"s1","tasks":[{"tokenCount":7,"id":"a","status":"x","name":"n"}]}"#,
            want: Some(r#"{"tasks":[{"id":"a","name":"n","status":"x","tokenCount":7}]}"#),
        },
        ProjectionCase {
            name: "drops-fields-the-reader-does-not-consume",
            payload: r#"{"session_id":"s1","tasks":[{"id":"a","tokenSamples":[1,2],"extra":"x"}]}"#,
            want: Some(r#"{"tasks":[{"id":"a"}]}"#),
        },
        // RESOLVED DIVERGENCE. jq's `select(type == "object")` drops a
        // non-object task; the PowerShell handler emits `{}` for it, which
        // reaches the reader as a task with no id. Resolved to the bash
        // behaviour on both platforms: `{}` is not a task.
        ProjectionCase {
            name: "non-object-task-is-dropped-not-emitted-as-empty",
            payload: r#"{"session_id":"s1","tasks":[{"id":"a"},"nope",42,null]}"#,
            want: Some(r#"{"tasks":[{"id":"a"}]}"#),
        },
        // RESOLVED DIVERGENCE. Windows PowerShell 5.1 escapes `'`, `<`, `>` and
        // every non-ASCII character as \uXXXX; jq and PowerShell 7 emit them
        // raw. The Windows handler therefore has no single byte-exact
        // behaviour of its own — it depends on which interpreter the user runs.
        // Resolved to the minimal-escaping form, which matches jq, matches
        // PowerShell 7, and is what the only consumer — a JSON parser in the
        // status line — reads identically either way.
        ProjectionCase {
            name: "escapes-minimally-like-jq-not-like-powershell-51",
            payload: r#"{"session_id":"s1","tasks":[{"id":"a","description":"the user's <tag> & ✅"}]}"#,
            want: Some(r#"{"tasks":[{"id":"a","description":"the user's <tag> & ✅"}]}"#),
        },
        ProjectionCase {
            name: "absent-tasks-writes-an-empty-list",
            payload: r#"{"session_id":"s1"}"#,
            want: Some(r#"{"tasks":[]}"#),
        },
        ProjectionCase {
            name: "empty-tasks-writes-an-empty-list",
            payload: r#"{"session_id":"s1","tasks":[]}"#,
            want: Some(r#"{"tasks":[]}"#),
        },
        // Everything below leaves the previous feed alone. A tee that
        // overwrote on garbage would silently drop the subagent rows until the
        // next good tick — the contract half that got the raw-tee prototype
        // rejected in docs/performance.md §7.
        ProjectionCase {
            name: "tasks-of-the-wrong-type-is-a-malformed-tick",
            payload: r#"{"session_id":"s1","tasks":"nope"}"#,
            want: None,
        },
        ProjectionCase {
            name: "unparseable-payload",
            payload: "{not json",
            want: None,
        },
        ProjectionCase {
            name: "payload-is-not-an-object",
            payload: "[1,2,3]",
            want: None,
        },
        ProjectionCase {
            name: "no-session-id",
            payload: r#"{"tasks":[{"id":"a"}]}"#,
            want: None,
        },
        ProjectionCase {
            name: "session-id-sanitises-to-nothing",
            payload: r#"{"session_id":"../..","tasks":[{"id":"a"}]}"#,
            want: None,
        },
        ProjectionCase {
            name: "empty-payload",
            payload: "",
            want: None,
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let got = subagent::project(c.payload).map(|(_, bytes)| bytes);
        failures.check(c.name, got.as_deref() == c.want, || {
            format!("got {got:?}, expected {:?}", c.want)
        });
    }
    failures.assert_empty("tasks-feed projection");
}

/// The session id reaches a filename, so a separator surviving sanitisation
/// would let the handler write outside the temp directory — and unlike
/// `git-refresh`, this component *creates* files, so an escape plants content
/// rather than deleting it.
#[test]
fn no_payload_can_tee_outside_the_temp_root() {
    let temp = scratch_dir("subagent-escape");
    let hostile = [
        "../../../../etc/cron.d/x",
        "..\\..\\..\\Windows\\System32\\x",
        "/absolute/path",
        "C:\\Windows",
        "a/../../b",
    ];

    let mut failures = Failures::default();
    for raw in hostile {
        let payload = serde_json::json!({ "session_id": raw, "tasks": [] }).to_string();
        let Some((safe_id, _)) = subagent::project(&payload) else {
            continue;
        };
        let path = subagent::feed_path(&temp, &safe_id);
        failures.check(raw, path.starts_with(&temp), || {
            format!("escaped the temp root: {}", path.display())
        });
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        failures.check(raw, !name.contains(".."), || {
            format!("filename still carries a traversal: {name}")
        });
    }
    failures.assert_empty("tasks-feed path traversal");
}

/// The feed path is entirely predictable from the session id, and on a shared
/// `/tmp` that is the difference between a state file and an arbitrary-write
/// primitive. Both shell handlers refuse rather than follow; so must this.
#[test]
fn a_hostile_feed_target_is_refused_not_followed() {
    let dir = scratch_dir("subagent-hostile");
    let victim = dir.join("victim.txt");
    let link = subagent::feed_path(&dir, "s1");
    std::fs::write(&victim, b"original").unwrap();

    if !make_symlink(&victim, &link) {
        eprintln!("skipped: this platform/session cannot create symlinks unprivileged");
        return;
    }

    let payload = r#"{"session_id":"s1","tasks":[{"id":"a"}]}"#;
    let outcome = subagent::run(payload, &dir);
    assert!(
        matches!(outcome, subagent::Tick::Wrote(_) | subagent::Tick::Hostile),
        "unexpected outcome: {outcome:?}"
    );
    assert_eq!(
        std::fs::read(&victim).unwrap(),
        b"original",
        "the tee followed the symlink and clobbered the victim file"
    );
}

/// Anything on stdout replaces Claude Code's default agent panel. This runs the
/// real binary because stdout emptiness is a process-level fact, and it asserts
/// the feed was written in the same breath — otherwise "prints nothing" would
/// be satisfied by a handler that does nothing.
#[test]
fn the_subagent_handler_prints_nothing_while_still_teeing() {
    let dir = scratch_dir("subagent-silent");
    let root = dir.to_string_lossy().into_owned();
    let env: &[(&str, &str)] = &[("TMPDIR", &root), ("TEMP", &root), ("TMP", &root)];

    let valid = r#"{"session_id":"silent-1","tasks":[{"id":"a","status":"running"}]}"#;
    let mut failures = Failures::default();

    for (name, stdin) in [
        ("valid", valid),
        ("malformed", "{not json"),
        ("empty", ""),
        ("not-an-object", "[1,2,3]"),
    ] {
        let run = run_bin(&["subagent"], stdin, env);
        failures.check(name, run.code == Some(0), || {
            format!("expected exit 0, got {:?}", run.code)
        });
        failures.check(name, run.stdout.is_empty(), || {
            format!(
                "wrote to stdout, which replaces the agent panel: {:?}",
                run.stdout
            )
        });
        failures.check(name, run.stderr.is_empty(), || {
            format!("wrote to stderr: {:?}", run.stderr)
        });
    }

    let feed = std::fs::read_to_string(subagent::feed_path(&dir, "silent-1")).unwrap_or_default();
    failures.check("valid", !feed.is_empty(), || {
        "the valid payload wrote no feed, so silence here proves nothing".to_string()
    });
    failures.assert_empty("subagent stdout contract");
}

/// R31 equivalence against the captured fixtures: the bytes the port writes to
/// the feed must equal the bytes each platform's script wrote, for the same
/// payload and the same supplied state.
#[test]
fn feed_bytes_match_the_captured_fixtures() {
    let root = repo_file("tests/fixtures/subagent");
    let Ok(entries) = std::fs::read_dir(&root) else {
        println!("no subagent fixtures captured yet");
        return;
    };

    let mut failures = Failures::default();
    let mut checked = 0usize;

    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let case = dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let meta: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("case.json")).unwrap_or_default(),
        )
        .unwrap_or(serde_json::Value::Null);
        let payload_rel = meta["payload"].as_str().unwrap_or("");
        let payload = std::fs::read_to_string(repo_file(&format!("tests/harness/{payload_rel}")))
            .unwrap_or_default();
        let session = meta["session_id"].as_str().unwrap_or("");

        // Every platform that has been captured is asserted, including ones
        // this test is not running on: the feed's bytes are platform
        // independent, which is the claim the fixtures exist to prove.
        for platform in ["macos", "linux", "windows"] {
            let expected_path = dir.join("expected").join(format!("{platform}.txt"));
            let Ok(expected) = std::fs::read_to_string(&expected_path) else {
                continue;
            };
            checked += 1;
            let label = format!("{case}/{platform}");

            let temp = scratch_dir(&format!("subagent-fixture-{case}-{platform}"));
            // Recreate what the harness supplied, so the port starts from the
            // same state the script did — the malformed case is only meaningful
            // if a previous feed is actually there to survive.
            for input in meta["inputs"].as_array().into_iter().flatten() {
                let target = input["target"].as_str().unwrap_or("");
                let content = input["content"].as_str().unwrap_or("");
                let Some(rel) = target.strip_prefix("{TMP}/") else {
                    failures.check(&label, false, || {
                        format!("unsupported input target `{target}`: this replay only stages {{TMP}} files")
                    });
                    continue;
                };
                let bytes = std::fs::read(repo_file(&format!("tests/harness/{content}")))
                    .unwrap_or_default();
                std::fs::write(temp.join(rel.replace("{SESSION}", session)), bytes).unwrap();
            }

            subagent::run(&payload, &temp);

            let got =
                std::fs::read_to_string(subagent::feed_path(&temp, session)).unwrap_or_default();
            failures.check(&label, got == expected, || {
                format!("script wrote {expected:?}, port wrote {got:?}")
            });

            // An empty expectation means no feed exists at all, which a plain
            // string compare cannot distinguish from an empty file.
            if expected.is_empty() {
                let stray: Vec<String> = std::fs::read_dir(&temp)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect();
                failures.check(&label, stray.is_empty(), || {
                    format!("expected no feed file, found {stray:?}")
                });
            }
        }
    }

    println!("compared {checked} captured platform fixture(s)");
    failures.assert_empty("subagent fixture equivalence");
}

// ---------------------------------------------------------------------------
// notify (R1, R15, R23, R25, R31, R44 / U7)
// ---------------------------------------------------------------------------
//
// R31's observable here is the command and arguments notify invokes, so every
// case asserts the plan rather than the effect: nothing is spawned, no toast
// appears on the developer's desktop, and the assertions are the same on every
// host because `plan` takes the platform as a parameter.

use claude_statusline::cmd::notify::{self, Action, Env, Platform};
use claude_statusline::config::NotifyConfig;

/// Fixtures whose captured bytes are a record of what the scripts do, not a
/// target for the port (R20).
///
/// `muted-sound-for-event` is the only one. Both bash scripts read the config
/// flag as `jq -r '.[$e].sound // true'`, and jq's `//` yields its right-hand
/// side when the left is `false` as well as when it is null — so `false // true`
/// is `true`, and `"sound": false` has never muted anything on macOS or Linux.
/// R44 makes the flags gate delivery, so the port mutes correctly and
/// deliberately breaks the current behaviour of both bash platforms. Windows
/// already behaved correctly. `muting_is_honoured_on_every_platform` is the
/// literal that replaces the capture.
const DIVERGENT_FIXTURES: [&str; 1] = ["muted-sound-for-event"];

/// An environment with every helper and asset present, so a case that wants to
/// exercise the absent ones removes them explicitly rather than depending on
/// what the test machine happens to have installed.
fn full_env() -> Env {
    let home = PathBuf::from("/home/fixture");
    let mut files: std::collections::BTreeSet<PathBuf> =
        ["bell.oga", "complete.oga", "dialog-warning.oga"]
            .iter()
            .map(|f| PathBuf::from(format!("/usr/share/sounds/freedesktop/stereo/{f}")))
            .collect();
    // Spelled with literal backslashes rather than `PathBuf::join`, which would
    // use the host's separator and stop matching what the planner emits when
    // these tests run on Unix.
    for f in [
        "Windows Exclamation.wav",
        "chimes.wav",
        "Windows Battery Low.wav",
        "Windows Battery Critical.wav",
    ] {
        files.insert(PathBuf::from(format!("C:\\Windows\\Media\\{f}")));
    }
    Env {
        home: home.clone(),
        cwd: PathBuf::from("/repo/work"),
        system_root: PathBuf::from("C:\\Windows"),
        programs: [
            "terminal-notifier",
            "notify-send",
            "paplay",
            "ffplay",
            "ogg123",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect(),
        files,
    }
}

/// Collapses a plan into the shim's record format, so a planned invocation and
/// a captured one can be compared directly.
fn as_records(actions: &[Action]) -> Vec<String> {
    fn esc(s: &str) -> String {
        s.replace('\\', "\\\\")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t")
    }
    let mut out: Vec<String> = actions
        .iter()
        .filter_map(|a| match a {
            Action::Spawn { program, args, .. } => {
                let name = program.rsplit(['/', '\\']).next().unwrap_or(program);
                let mut line = esc(name);
                for arg in args {
                    line.push('\t');
                    line.push_str(&esc(arg));
                }
                Some(line)
            }
            // In-process Windows audio leaves nothing for a shim to record.
            Action::PlayWav(_) | Action::Beep => None,
        })
        .collect();
    // The observable is a set: the sound helper is backgrounded, so its record
    // races the visual one. Both capture drivers sort for the same reason.
    out.sort();
    out
}

struct NotifyCase {
    name: &'static str,
    platform: Platform,
    event: &'static str,
    value: &'static str,
    stdin: &'static str,
    config: &'static str,
    want: &'static [&'static str],
}

const PERMISSION_PAYLOAD: &str =
    r#"{"tool_name":"Bash","session_id":"s1","tool_input":{"command":"git status --porcelain"}}"#;

/// Every event on every platform, plus the states that change what is invoked.
#[test]
fn every_event_invokes_what_the_scripts_invoked() {
    let cases = [
        NotifyCase {
            name: "macos-permission",
            platform: Platform::Macos,
            event: "permission",
            value: "",
            stdin: PERMISSION_PAYLOAD,
            config: "{}",
            want: &[
                "afplay\t/System/Library/Sounds/Tink.aiff",
                "terminal-notifier\t-title\tClaude Code\t-message\tBash: git status --porcelain",
            ],
        },
        NotifyCase {
            name: "linux-permission",
            platform: Platform::Linux,
            event: "permission",
            value: "",
            stdin: PERMISSION_PAYLOAD,
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tBash: git status --porcelain\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        NotifyCase {
            name: "macos-stop",
            platform: Platform::Macos,
            event: "stop",
            value: "",
            stdin: "",
            config: "{}",
            want: &[
                "afplay\t/System/Library/Sounds/Glass.aiff",
                "terminal-notifier\t-title\tClaude Code\t-message\tFinished working",
            ],
        },
        NotifyCase {
            name: "linux-rate-limit-carries-its-value",
            platform: Platform::Linux,
            event: "rate_limit",
            value: "82",
            stdin: "",
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tRate limit at 82%\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/dialog-warning.oga",
            ],
        },
        NotifyCase {
            name: "macos-context-high-carries-its-value",
            platform: Platform::Macos,
            event: "context_high",
            value: "71",
            stdin: "",
            config: "{}",
            want: &[
                "afplay\t/System/Library/Sounds/Sosumi.aiff",
                "terminal-notifier\t-title\tClaude Code\t-message\tContext window at 71%",
            ],
        },
        NotifyCase {
            name: "linux-compaction-start",
            platform: Platform::Linux,
            event: "compaction_start",
            value: "",
            stdin: "",
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tCompacting context...\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        NotifyCase {
            name: "linux-compaction-done",
            platform: Platform::Linux,
            event: "compaction_done",
            value: "",
            stdin: "",
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tContext compacted\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/complete.oga",
            ],
        },
        // An unknown event has no message and no sound, so it invokes nothing
        // rather than raising a blank notification.
        NotifyCase {
            name: "unknown-event-invokes-nothing",
            platform: Platform::Macos,
            event: "not-an-event",
            value: "",
            stdin: "",
            config: "{}",
            want: &[],
        },
        NotifyCase {
            name: "empty-event-invokes-nothing",
            platform: Platform::Linux,
            event: "",
            value: "",
            stdin: "",
            config: "{}",
            want: &[],
        },
        // A permission payload that says nothing useful still notifies: the
        // user needs to know something is waiting even if we cannot say what.
        NotifyCase {
            name: "unparseable-payload-still-prompts",
            platform: Platform::Linux,
            event: "permission",
            value: "",
            stdin: "{not json",
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tWaiting for permission\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        NotifyCase {
            name: "tool-with-no-detail-names-the-tool",
            platform: Platform::Linux,
            event: "permission",
            value: "",
            stdin: r#"{"tool_name":"WebFetch"}"#,
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tWebFetch\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        // A file path under the working directory is shown relative to it, so
        // the notification is not mostly the user's home directory.
        NotifyCase {
            name: "file-path-is-relative-to-cwd",
            platform: Platform::Linux,
            event: "permission",
            value: "",
            stdin: r#"{"tool_name":"Edit","tool_input":{"file_path":"/repo/work/src/main.rs"}}"#,
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tEdit: src/main.rs\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        NotifyCase {
            name: "file-path-outside-cwd-is-left-whole",
            platform: Platform::Linux,
            event: "permission",
            value: "",
            stdin: r#"{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}"#,
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tRead: /etc/hosts\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        // AE14. Every metacharacter that would matter to a shell is delivered
        // literally, because argv is a list and no shell ever sees it.
        NotifyCase {
            name: "metacharacters-are-delivered-literally",
            platform: Platform::Linux,
            event: "permission",
            value: "",
            stdin: r#"{"tool_name":"Bash","tool_input":{"command":"echo \"hi\"; rm -rf /; $(id) `id` && x\ny"}}"#,
            config: "{}",
            want: &[
                "notify-send\tClaude Code\tBash: echo \"hi\"; rm -rf /; $(id) `id` && x\\ny\t--urgency=normal",
                "paplay\t/usr/share/sounds/freedesktop/stereo/bell.oga",
            ],
        },
        NotifyCase {
            name: "visual-muted-leaves-only-sound",
            platform: Platform::Macos,
            event: "stop",
            value: "",
            stdin: "",
            config: r#"{"stop":{"visual":false}}"#,
            want: &["afplay\t/System/Library/Sounds/Glass.aiff"],
        },
        NotifyCase {
            name: "a-non-boolean-flag-does-not-mute",
            platform: Platform::Macos,
            event: "stop",
            value: "",
            stdin: "",
            config: r#"{"stop":{"sound":"false","visual":null}}"#,
            want: &[
                "afplay\t/System/Library/Sounds/Glass.aiff",
                "terminal-notifier\t-title\tClaude Code\t-message\tFinished working",
            ],
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let cfg = NotifyConfig::parse(c.config);
        let got = as_records(&notify::plan(
            c.platform,
            c.event,
            c.value,
            c.stdin,
            &cfg,
            &full_env(),
        ));
        let want: Vec<String> = c.want.iter().map(|s| s.to_string()).collect();
        failures.check(c.name, got == want, || {
            format!("got {got:?}, want {want:?}")
        });
    }
    failures.assert_empty("notify invocations");
}

/// AE15, and the resolved divergence. `sound: false` must actually mute, on
/// every platform — which is a deliberate break from what both bash scripts do
/// today. See `DIVERGENT_FIXTURES`.
#[test]
fn muting_is_honoured_on_every_platform() {
    let cfg = NotifyConfig::parse(r#"{"permission":{"sound":false,"visual":true}}"#);
    let env = full_env();
    let mut failures = Failures::default();

    for (name, platform, want) in [
        (
            "macos",
            Platform::Macos,
            vec!["terminal-notifier\t-title\tClaude Code\t-message\tBash: git status --porcelain"],
        ),
        (
            "linux",
            Platform::Linux,
            vec!["notify-send\tClaude Code\tBash: git status --porcelain\t--urgency=normal"],
        ),
    ] {
        let got = as_records(&notify::plan(
            platform,
            "permission",
            "",
            PERMISSION_PAYLOAD,
            &cfg,
            &env,
        ));
        let want: Vec<String> = want.iter().map(|s| s.to_string()).collect();
        failures.check(name, got == want, || {
            format!("a muted event still invoked a sound helper: got {got:?}")
        });
    }

    // Windows sound is in-process, so muting is asserted on the plan itself
    // rather than on an invocation.
    let plan = notify::plan(
        Platform::Windows,
        "permission",
        "",
        PERMISSION_PAYLOAD,
        &cfg,
        &env,
    );
    failures.check(
        "windows",
        !plan
            .iter()
            .any(|a| matches!(a, Action::PlayWav(_) | Action::Beep)),
        || format!("a muted event still planned audio: {plan:?}"),
    );
    failures.assert_empty("muted delivery");
}

/// A helper that is not installed is skipped, and the rest of the notification
/// still goes out. The scripts tolerate every one of these being absent.
#[test]
fn a_missing_helper_degrades_rather_than_dropping_the_notification() {
    let mut env = full_env();
    env.programs.remove("notify-send");
    env.programs.remove("paplay");

    let cfg = NotifyConfig::default();
    let got = as_records(&notify::plan(Platform::Linux, "stop", "", "", &cfg, &env));
    assert_eq!(
        got,
        vec!["ffplay\t-nodisp\t-autoexit\t-loglevel\tquiet\t/usr/share/sounds/freedesktop/stereo/complete.oga"],
        "the next available player should have been used and the visual skipped"
    );

    // Every player gone: sound is dropped, the visual survives.
    env.programs.remove("ffplay");
    env.programs.remove("ogg123");
    env.programs.insert("notify-send".to_string());
    let got = as_records(&notify::plan(Platform::Linux, "stop", "", "", &cfg, &env));
    assert_eq!(
        got,
        vec!["notify-send\tClaude Code\tFinished working\t--urgency=normal"]
    );

    // The sound asset missing is the other half: Linux checks, macOS does not.
    let mut env = full_env();
    env.files.clear();
    let got = as_records(&notify::plan(Platform::Linux, "stop", "", "", &cfg, &env));
    assert_eq!(
        got,
        vec!["notify-send\tClaude Code\tFinished working\t--urgency=normal"],
        "a missing sound asset should skip the player, not the notification"
    );
}

/// The icon is added only when it is actually on disk, because both helpers
/// treat a missing icon path as an error rather than ignoring it.
#[test]
fn the_icon_is_attached_only_when_it_exists() {
    let cfg = NotifyConfig::default();
    let mut env = full_env();
    env.files
        .insert(PathBuf::from("/home/fixture/.claude/claude-icon.png"));

    let macos = as_records(&notify::plan(Platform::Macos, "stop", "", "", &cfg, &env));
    assert_eq!(
        macos,
        vec![
            "afplay\t/System/Library/Sounds/Glass.aiff",
            "terminal-notifier\t-title\tClaude Code\t-message\tFinished working\t-appIcon\t/home/fixture/.claude/claude-icon.png\t-contentImage\t/home/fixture/.claude/claude-icon.png",
        ]
    );

    let linux = as_records(&notify::plan(Platform::Linux, "stop", "", "", &cfg, &env));
    assert!(
        linux
            .iter()
            .any(|l| l.contains("--icon=/home/fixture/.claude/claude-icon.png")),
        "the icon flag is missing: {linux:?}"
    );
}

/// KTD11 and AE14, asserted as an invariant rather than by inspecting escapes.
///
/// The permission message is `tool_input.command` — whatever the model was
/// about to run — so it is attacker-influenceable. On Windows it crosses into a
/// second interpreter, and the only safe way to do that is as data. This checks
/// that no byte of it ever appears in the program path or in any argument,
/// which is a stronger claim than "the quoting looks right".
#[test]
fn the_windows_toast_never_carries_the_message_in_its_argv() {
    let hostile = "'; Remove-Item C:\\ -Recurse; $(whoami) `id` \"quoted\"";
    let stdin = serde_json::json!({
        "tool_name": "Bash",
        "tool_input": { "command": hostile },
    })
    .to_string();

    let plan = notify::plan(
        Platform::Windows,
        "permission",
        "",
        &stdin,
        &NotifyConfig::default(),
        &full_env(),
    );

    let Some(Action::Spawn {
        program,
        args,
        stdin: payload,
        ..
    }) = plan.first()
    else {
        panic!("the Windows plan did not start with a spawn: {plan:?}");
    };

    // Absolute path under %SystemRoot%: a powershell.exe planted on PATH or in
    // the working directory must never be what raises a notification.
    assert_eq!(
        program,
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    );
    assert!(
        args.contains(&"-NoProfile".to_string()),
        "a user profile could otherwise redefine what the script means"
    );

    // The distinctive fragments of the hostile string must appear nowhere in
    // argv — not escaped, not quoted, not at all.
    for fragment in ["Remove-Item", "whoami", "quoted"] {
        assert!(
            !program.contains(fragment),
            "the program path carries the message"
        );
        for arg in args {
            assert!(
                !arg.contains(fragment),
                "an argument carries the message, which is exactly what KTD11 forbids: {arg:?}"
            );
        }
    }

    // It does reach the child — as data, on stdin.
    let payload = payload.as_deref().unwrap_or("");
    assert!(
        payload.contains("Remove-Item"),
        "the message never reached the child at all: {payload:?}"
    );
    let parsed: serde_json::Value = serde_json::from_str(payload).expect("stdin is not JSON");
    assert_eq!(
        parsed["message"],
        serde_json::Value::String(format!("Bash: {hostile}"))
    );

    // And the script body is a constant that cannot be influenced.
    assert!(
        !notify::WINDOWS_TOAST_SCRIPT.contains('"'),
        "a double quote in the body would be re-encoded by the Windows command-line rules"
    );
}

/// R44's thresholds, which the status line reads to decide whether to fire at
/// all. A non-integer must fall back rather than disable the alert.
#[test]
fn thresholds_default_when_absent_or_unusable() {
    struct Case {
        name: &'static str,
        json: &'static str,
        event: &'static str,
        want: i64,
    }

    let cases = [
        Case {
            name: "absent-config",
            json: "{}",
            event: "context_high",
            want: 70,
        },
        Case {
            name: "absent-rate-limit",
            json: "{}",
            event: "rate_limit",
            want: 80,
        },
        Case {
            name: "configured",
            json: r#"{"context_high":{"threshold":55}}"#,
            event: "context_high",
            want: 55,
        },
        Case {
            name: "non-integer",
            json: r#"{"context_high":{"threshold":"high"}}"#,
            event: "context_high",
            want: 70,
        },
        Case {
            name: "unparseable-file",
            json: "{not json",
            event: "rate_limit",
            want: 80,
        },
        Case {
            name: "json-not-an-object",
            json: "[1,2,3]",
            event: "context_high",
            want: 70,
        },
    ];

    let mut failures = Failures::default();
    for c in cases {
        let got = NotifyConfig::parse(c.json).threshold(c.event);
        failures.check(c.name, got == c.want, || {
            format!("threshold for {} was {got}, want {}", c.event, c.want)
        });
    }
    failures.assert_empty("notify thresholds");
}

/// R31 equivalence against the captured fixtures, for the cases where the
/// scripts and the port are supposed to agree.
#[test]
fn notify_invocations_match_the_captured_fixtures() {
    let root = repo_file("tests/fixtures/notify");
    let Ok(entries) = std::fs::read_dir(&root) else {
        println!("no notify fixtures captured yet");
        return;
    };

    let mut failures = Failures::default();
    let mut checked = 0usize;

    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let case = dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        if DIVERGENT_FIXTURES.contains(&case.as_str()) {
            println!("skipping {case}: a recorded divergence, asserted as a literal instead");
            continue;
        }

        let meta: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("case.json")).unwrap_or_default(),
        )
        .unwrap_or(serde_json::Value::Null);
        let payload_rel = meta["payload"].as_str().unwrap_or("");
        let payload = std::fs::read_to_string(repo_file(&format!("tests/harness/{payload_rel}")))
            .unwrap_or_default();
        let config_rel = meta["notify_config"].as_str().unwrap_or("");
        let cfg = NotifyConfig::load(&repo_file(&format!("tests/harness/{config_rel}")));
        let event = meta["args"][0].as_str().unwrap_or("");
        let value = meta["args"][1].as_str().unwrap_or("");

        for (platform, name) in [(Platform::Macos, "macos"), (Platform::Linux, "linux")] {
            let Ok(expected_raw) =
                std::fs::read_to_string(dir.join("expected").join(format!("{name}.txt")))
            else {
                continue;
            };
            checked += 1;
            let label = format!("{case}/{name}");

            // The harness supplies its own isolated home and working directory,
            // and the capture scrubbed both back to placeholders. Replaying
            // with the same placeholders is what makes the comparison possible.
            let mut env = full_env();
            env.home = PathBuf::from("{HOME}");
            env.cwd = PathBuf::from("{REPO}");

            let expected: Vec<String> = expected_raw
                .lines()
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect();
            let got = as_records(&notify::plan(platform, event, value, &payload, &cfg, &env));

            failures.check(&label, got == expected, || {
                format!("script invoked {expected:?}, port planned {got:?}")
            });
        }
    }

    println!("compared {checked} captured platform fixture(s)");
    failures.assert_empty("notify fixture equivalence");
}

// ---------------------------------------------------------------------------
// Installer contract (R7, R8, R10, R17 / U4)
// ---------------------------------------------------------------------------
//
// These rules are invisible until they are violated, and each one has already
// cost this project something: an `exit` closes the terminal of anyone who ran
// the published one-liner, a BOM breaks `iex` on the first token, and staging
// in a shared temp reopens the window between verification and placement.

/// Every shell installer, including the compatibility entry points at the
/// published one-liner URLs. The rules below apply to whatever a user can pipe
/// into their shell, not just to the file that holds the logic.
const INSTALL_SH: [&str; 6] = [
    "install/install.sh",
    "install/uninstall.sh",
    "macos/install.sh",
    "macos/uninstall.sh",
    "linux/install.sh",
    "linux/uninstall.sh",
];
const INSTALL_PS1: [&str; 4] = [
    "install/install.ps1",
    "install/uninstall.ps1",
    "windows/install.ps1",
    "windows/uninstall.ps1",
];

fn code_lines(body: &str, comment: char) -> impl Iterator<Item = (usize, &str)> {
    body.lines()
        .enumerate()
        .map(|(n, l)| (n + 1, l.trim()))
        .filter(move |(_, l)| !l.is_empty() && !l.starts_with(comment))
}

/// R17. `irm | iex` and `curl | bash` both run these in the user's live shell,
/// where `exit` terminates their session and closes the window. CLAUDE.md's
/// idiom is `return 1 2>/dev/null || exit 1`: `return` succeeds when sourced,
/// and the `exit` fallback only ever runs in a subshell.
#[test]
fn install_scripts_never_exit_the_users_shell() {
    let mut failures = Failures::default();

    for rel in INSTALL_SH {
        let body = read_repo_file(rel);
        for (n, line) in code_lines(&body, '#') {
            if line.contains("exit") && line != "return 1 2>/dev/null || exit 1" {
                failures.check(&format!("{rel}:{n}"), false, || {
                    format!("bare `exit` outside CLAUDE.md's guarded idiom: {line}")
                });
            }
        }
    }

    for rel in INSTALL_PS1 {
        let body = read_repo_file(rel);
        for (n, line) in code_lines(&body, '#') {
            let has_exit = line
                .split(|c: char| !c.is_ascii_alphanumeric() && c != '-')
                .any(|w| w == "exit");
            if has_exit {
                failures.check(&format!("{rel}:{n}"), false, || {
                    format!("`exit` would close the user's PowerShell session: {line}")
                });
            }
        }
    }
    failures.assert_empty("no-exit rule");
}

/// The `irm | iex` exception in `.gitattributes`. A BOM survives `irm` as a
/// stray U+FEFF that breaks `iex` on the first token — fixed once in 762dcc0,
/// then regressed by re-applying the repo's BOM rule mechanically. ASCII-only
/// keeps them safe to run from a local clone too.
#[test]
fn fetched_powershell_installers_are_bomless_ascii() {
    let mut failures = Failures::default();
    for rel in INSTALL_PS1 {
        let bytes = std::fs::read(repo_file(rel)).unwrap_or_else(|e| panic!("{rel}: {e}"));
        failures.check(rel, !bytes.starts_with(&[0xEF, 0xBB, 0xBF]), || {
            "has a UTF-8 BOM, which `iex` chokes on".to_string()
        });
        if let Some(pos) = bytes.iter().position(|b| *b > 127) {
            failures.check(rel, false, || format!("non-ASCII byte at offset {pos}"));
        }
    }
    failures.assert_empty("installer encoding");
}

/// R10. Staging in a shared world-writable temp reopens exactly the window the
/// staging rules exist to close: another user swapping the file between the
/// checksum passing and the binary being placed.
#[test]
fn downloads_are_staged_in_the_destination_directory() {
    let mut failures = Failures::default();

    let sh = read_repo_file("install/install.sh");
    failures.check("install.sh", sh.contains("STAGE=\"$BIN_DIR/"), || {
        "does not stage inside the install directory".to_string()
    });
    for bad in ["mktemp", "/tmp/", "$TMPDIR"] {
        failures.check("install.sh", !sh.contains(bad), || {
            format!("stages via `{bad}`, outside the destination directory")
        });
    }

    let ps = read_repo_file("install/install.ps1");
    failures.check(
        "install.ps1",
        ps.contains("Join-Path $binDir \"$stagePrefix"),
        || "does not stage inside the install directory".to_string(),
    );
    for bad in ["$env:TEMP", "GetTempPath", "GetTempFileName"] {
        failures.check("install.ps1", !ps.contains(bad), || {
            format!("stages via `{bad}`, outside the destination directory")
        });
    }
    failures.assert_empty("staging location");
}

/// R7 and R8's fail directions, which are deliberately different from each
/// other and from the runtime guard. The checksum is the fail-closed gate; the
/// attestation is opportunistic but still fails closed when it actually runs.
#[test]
fn verification_is_pinned_and_fails_closed() {
    let mut failures = Failures::default();

    for rel in ["install/install.sh", "install/install.ps1"] {
        let body = read_repo_file(rel);

        // An unpinned attestation check accepts any valid Sigstore bundle from
        // anywhere, which makes it close to decorative.
        failures.check(rel, body.contains("--signer-workflow"), || {
            "attestation verification is not pinned to a signer workflow".to_string()
        });
        failures.check(rel, body.contains("--repo"), || {
            "attestation verification is not pinned to a repository".to_string()
        });
        // Verified against the published bundle, not the attestation API: the
        // API serves it Snappy-compressed and needs an authenticated gh.
        failures.check(rel, body.contains("--bundle"), || {
            "verifies through the attestation API instead of the published bundle".to_string()
        });
        failures.check(rel, body.contains("--require-attestation"), || {
            "offers no way to demand attestation".to_string()
        });
        failures.check(rel, body.contains("checksums.txt"), || {
            "never fetches the checksum file".to_string()
        });
    }
    failures.assert_empty("verification pinning");
}

// ---------------------------------------------------------------------------
// settings.json merge (R14, R15 / U4)
// ---------------------------------------------------------------------------
//
// This is the user's file. Everything below is really one property stated four
// ways: the installer owns exactly the entries it wrote, and touching anything
// else — content, ordering, or a hook someone added themselves — is a bug.

const WIN_BINARY: &str = "\"C:\\Users\\a b\\.claude\\bin\\claude-statusline.exe\"";
const UNIX_BINARY: &str = "/home/u/.claude/bin/claude-statusline";

/// A settings file with content the installer must not disturb, including a
/// hook the user registered on the same event the installer writes to.
fn user_settings() -> serde_json::Value {
    serde_json::json!({
        "theme": "dark",
        "model": "opus",
        "hooks": {
            "PostToolUse": [
                { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/my-own-hook.sh" }] }
            ]
        }
    })
}

fn all() -> settings::ApplySpec {
    settings::ApplySpec {
        statusline: true,
        subagent: true,
        git_refresh: true,
        notify: true,
        quote: false,
    }
}

fn all_quoted() -> settings::ApplySpec {
    settings::ApplySpec {
        quote: true,
        ..all()
    }
}

/// R15's idempotent re-run. A second install must not append a second copy of
/// every hook — the shape that turns a re-run into four notification sounds.
#[test]
fn applying_twice_leaves_one_entry_each() {
    let mut once = user_settings();
    settings::apply(&mut once, UNIX_BINARY, &all());
    let mut twice = once.clone();
    settings::apply(&mut twice, UNIX_BINARY, &all());

    assert_eq!(once, twice, "a second apply changed the file");

    let post = twice["hooks"]["PostToolUse"].as_array().unwrap();
    assert_eq!(
        post.len(),
        2,
        "expected the user's hook plus exactly one of ours, got {post:#?}"
    );
}

/// The installer writes into a file it does not own. A user's own hook on the
/// same event, and every unrelated key, has to come through untouched.
#[test]
fn unrelated_content_and_foreign_hooks_survive() {
    let mut root = user_settings();
    settings::apply(&mut root, UNIX_BINARY, &all());

    let mut failures = Failures::default();
    failures.check("theme", root["theme"] == "dark", || {
        "an unrelated key was lost".to_string()
    });
    failures.check("model", root["model"] == "opus", || {
        "an unrelated key was lost".to_string()
    });

    let post = root["hooks"]["PostToolUse"].as_array().unwrap();
    let kept = post
        .iter()
        .any(|e| e["hooks"][0]["command"] == "~/my-own-hook.sh" && e["matcher"] == "Bash");
    failures.check("foreign-hook", kept, || {
        "the user's own PostToolUse hook was dropped".to_string()
    });
    failures.assert_empty("settings merge");
}

/// Uninstall has to leave no trace it can avoid leaving, which means pruning
/// the containers our entries were the only occupants of — but not the ones
/// still holding someone else's hook.
#[test]
fn remove_restores_the_pre_install_file() {
    let before = user_settings();
    let mut root = before.clone();
    settings::apply(&mut root, UNIX_BINARY, &all());
    assert_ne!(
        root, before,
        "apply did nothing, so the test proves nothing"
    );

    settings::remove(&mut root, UNIX_BINARY);
    assert_eq!(
        root, before,
        "uninstall did not restore the file to its pre-install state"
    );
}

/// R14's Windows quoting, driven the way an installer drives it: with the
/// **bare** path.
///
/// Quoting is the binary's job precisely because the caller is a shell and
/// shells eat quotes. PowerShell consumes the surrounding quotes of a pre-quoted
/// argument as delimiters, so an installer that passed `"C:\path\x.exe"` handed
/// the merge a bare path and silently wrote an unquoted command. That shipped
/// once and was only caught by installing from a real release — the earlier
/// version of this test passed a pre-quoted string straight to the function and
/// never crossed the boundary where the bug lived.
#[test]
fn quoting_is_applied_on_this_side_of_the_shell_boundary() {
    let bare = WIN_BINARY.trim_matches('"');

    let mut quoted = serde_json::json!({});
    settings::apply(&mut quoted, bare, &all_quoted());
    let command = quoted["statusLine"]["command"].as_str().unwrap_or_default();
    assert_eq!(
        command, WIN_BINARY,
        "a bare path handed in was not quoted on the way out"
    );
    assert!(
        quoted["subagentStatusLine"]["command"]
            .as_str()
            .unwrap_or_default()
            .starts_with(WIN_BINARY),
        "the subcommand form lost its quoting"
    );

    // Unix entries stay bare, which is what the shell installers always wrote.
    let mut unquoted = serde_json::json!({});
    settings::apply(&mut unquoted, UNIX_BINARY, &all());
    assert_eq!(
        unquoted["statusLine"]["command"]
            .as_str()
            .unwrap_or_default(),
        UNIX_BINARY,
        "a Unix entry was quoted, which the shell installers never did"
    );

    // Quoting must also be idempotent: an already-quoted path stays as it is
    // rather than accumulating a second pair.
    let mut twice = serde_json::json!({});
    settings::apply(&mut twice, WIN_BINARY, &all_quoted());
    assert_eq!(
        twice["statusLine"]["command"].as_str().unwrap_or_default(),
        WIN_BINARY,
        "an already-quoted path was quoted again"
    );
}

/// Whatever form the command was stored in, every query and the removal path
/// have to recognise it — the uninstaller holds a bare path where the installer
/// wrote a quoted one.
#[test]
fn quoted_windows_paths_round_trip() {
    let mut root = serde_json::json!({});
    settings::apply(&mut root, WIN_BINARY, &all());

    let mut failures = Failures::default();
    let command = root["statusLine"]["command"].as_str().unwrap_or_default();
    failures.check(
        "quoted",
        command.starts_with('"') && command.ends_with('"'),
        || format!("statusLine command is not quoted: {command}"),
    );

    for feature in ["statusline", "subagent", "git-refresh", "notify"] {
        failures.check(feature, settings::has(&root, WIN_BINARY, feature), || {
            "written but not detected by has()".to_string()
        });
        // The uninstaller may hold the bare path where the installer wrote a
        // quoted one; both have to match the same entry.
        let bare = WIN_BINARY.trim_matches('"');
        failures.check(feature, settings::has(&root, bare, feature), || {
            "not detected when queried with the unquoted path".to_string()
        });
    }

    settings::remove(&mut root, WIN_BINARY.trim_matches('"'));
    failures.check("removed", root.get("statusLine").is_none(), || {
        "removal by unquoted path left the entry behind".to_string()
    });
    failures.assert_empty("windows quoting");
}

/// The installer prompts before overwriting a `statusLine` it did not write.
/// Detecting "occupied by someone else" is what drives that prompt.
#[test]
fn a_foreign_statusline_is_distinguished_from_ours() {
    let foreign = serde_json::json!({
        "statusLine": { "type": "command", "command": "~/some-other-tool.sh" }
    });
    assert!(
        settings::has_foreign(&foreign, UNIX_BINARY, "statusline"),
        "another tool's statusLine was not recognised as foreign"
    );
    assert!(
        !settings::has(&foreign, UNIX_BINARY, "statusline"),
        "another tool's statusLine was mistaken for ours"
    );

    let mut ours = serde_json::json!({});
    settings::apply(&mut ours, UNIX_BINARY, &all());
    assert!(
        !settings::has_foreign(&ours, UNIX_BINARY, "statusline"),
        "our own entry was reported as foreign, which would prompt on every re-run"
    );
}

/// A settings file that exists but does not parse must stop the install, never
/// be silently replaced with an empty object — that would discard everything
/// the user had configured and report success.
#[test]
fn unparseable_settings_is_an_error_not_a_fresh_start() {
    let dir = scratch_dir("settings-malformed");
    let path = dir.join("settings.json");
    std::fs::write(&path, b"{ this is not json").unwrap();
    assert!(
        settings::load(&path).is_err(),
        "a corrupt settings.json parsed as an empty object"
    );

    let missing = dir.join("absent.json");
    assert!(
        settings::load(&missing).is_ok_and(|v| v.as_object().is_some_and(|m| m.is_empty())),
        "an absent settings.json should read as an empty object"
    );
}

/// The whole file is rewritten on every apply, so key order is a property of
/// the writer. Re-sorting the user's keys would make U4's own verification —
/// "settings.json diffs show only intended entries" — impossible to perform.
#[test]
fn existing_key_order_is_preserved() {
    let dir = scratch_dir("settings-order");
    let path = dir.join("settings.json");
    std::fs::write(&path, br#"{"theme":"dark","model":"opus","zzz":1,"aaa":2}"#).unwrap();

    let mut root = settings::load(&path).unwrap();
    settings::apply(&mut root, UNIX_BINARY, &all());
    settings::save(&path, &root).unwrap();

    let text = std::fs::read_to_string(&path).unwrap();
    let order: Vec<&str> = ["theme", "model", "zzz", "aaa"]
        .into_iter()
        .filter(|k| text.contains(&format!("\"{k}\"")))
        .collect();
    assert_eq!(
        order,
        vec!["theme", "model", "zzz", "aaa"],
        "keys were re-sorted; the install diff would show the entire file"
    );
    let theme_at = text.find("\"theme\"").unwrap();
    let aaa_at = text.find("\"aaa\"").unwrap();
    assert!(
        theme_at < aaa_at,
        "alphabetical re-sorting detected in the written file"
    );
}

// ---------------------------------------------------------------------------
// Fixture and harness contract (R29, R30, R31, R33 / U3)
// ---------------------------------------------------------------------------
//
// Fixtures are the only thing the ported components will be checked against, so
// a fixture that cannot be regenerated is not evidence — it is an unfalsifiable
// claim. These cases assert that every captured fixture carries what R30 and
// R33 require, and that the case table the harness drives stays consistent with
// the state matrix it references.

/// Minimal object reader. Pulling in a YAML or full JSON dependency for four
/// tests would put a build-time cost on every `cargo test` for the crate's
/// entire life; these files are generated by the harness to a fixed shape.
fn json_string_field<'a>(body: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\"");
    let start = body.find(&needle)? + needle.len();
    let rest = body[start..].trim_start().strip_prefix(':')?.trim_start();
    if let Some(quoted) = rest.strip_prefix('"') {
        Some(&quoted[..quoted.find('"')?])
    } else {
        let end = rest.find([',', '\n', '}']).unwrap_or(rest.len());
        Some(rest[..end].trim())
    }
}

fn fixture_case_files() -> Vec<PathBuf> {
    fn walk(dir: &Path, found: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, found);
            } else if path.file_name().is_some_and(|n| n == "case.json") {
                found.push(path);
            }
        }
    }
    let mut found = Vec::new();
    walk(&repo_file("tests/fixtures"), &mut found);
    found.sort();
    found
}

/// R30 and R33. A fixture missing any of these cannot be regenerated: without
/// the source commit there is no way to re-run the scripts that produced it,
/// and without the pinned clock and config input the re-run is a different
/// experiment.
#[test]
fn every_fixture_records_what_it_takes_to_regenerate_it() {
    let mut failures = Failures::default();
    let files = fixture_case_files();

    for path in &files {
        let name = path
            .parent()
            .and_then(|p| p.strip_prefix(repo_file("tests/fixtures")).ok())
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| path.display().to_string());
        let body = std::fs::read_to_string(path).expect("could not read a fixture");

        for key in ["source_commit", "clock", "notify_config", "observable"] {
            let value = json_string_field(&body, key).unwrap_or("");
            failures.check(&name, !value.is_empty() && value != "null", || {
                format!("`{key}` is missing or empty")
            });
        }

        let commit = json_string_field(&body, "source_commit").unwrap_or("");
        failures.check(&name, commit.len() == 40, || {
            format!("`source_commit` is `{commit}`, not a full commit sha")
        });

        // CLAUDE.md forbids committing a personal absolute path, and a fixture
        // is a committed file. The harness scrubs and then refuses; this is the
        // check that survives if someone hand-edits one.
        for leak in ["/Users/", "/home/", "C:\\Users\\", "C:/Users/"] {
            failures.check(&name, !body.contains(leak), || {
                format!("contains a machine-local path (`{leak}`)")
            });
        }
    }

    // Fixtures land with their component's port (R37), so this is empty until
    // U5. Reporting the count keeps that visible rather than letting a vacuous
    // pass read as coverage.
    println!("checked {} fixture(s)", files.len());
    failures.assert_empty("fixture metadata");
}

/// The two harness drivers read the same case table, so a case naming a git
/// state that `states.json` does not define fails on whichever platform runs
/// first — after doing all the setup work.
#[test]
fn every_case_references_a_defined_git_state() {
    let cases = read_repo_file("tests/harness/cases.json");
    let states = read_repo_file("tests/harness/states.json");

    let defined: Vec<&str> = states
        .lines()
        .filter_map(|l| l.trim().strip_prefix("\"name\": \""))
        .filter_map(|l| l.split('"').next())
        .collect();
    assert!(
        defined.len() >= 10,
        "expected the full §4 git-state matrix, found {}: {defined:?}",
        defined.len()
    );

    let mut failures = Failures::default();
    for (n, line) in cases.lines().enumerate() {
        let trimmed = line.trim();
        let Some(rest) = trimmed.strip_prefix("\"git_state\": ") else {
            continue;
        };
        let value = rest.trim_end_matches(',');
        if value == "null" {
            continue;
        }
        let state = value.trim_matches('"');
        failures.check(&format!("line {}", n + 1), defined.contains(&state), || {
            format!("references undefined git state `{state}`")
        });
    }
    failures.assert_empty("case table git states");
}

/// §4's matrix is the reason the harness exists. A state quietly dropped from
/// `states.json` would shrink coverage without failing anything.
#[test]
fn the_git_state_matrix_covers_every_documented_state() {
    let states = read_repo_file("tests/harness/states.json");
    let mut failures = Failures::default();

    for state in [
        "unborn-head",
        "clean",
        "untracked-only",
        "dirty",
        "stash-present",
        "stash-cleared",
        "ahead-of-upstream",
        "no-upstream",
        "detached-head",
        "collapsed-untracked-dir",
    ] {
        failures.check(
            state,
            states.contains(&format!("\"name\": \"{state}\"")),
            || "documented in docs/performance.md §4 but absent from the matrix".to_string(),
        );
    }
    failures.assert_empty("§4 git-state coverage");
}

/// KTD10 names the shims the harness intercepts through. Both drivers install
/// them by name, so a renamed or deleted shim body turns every notification
/// fixture into a silent empty capture.
#[test]
fn the_harness_ships_every_shim_it_installs() {
    let mut failures = Failures::default();
    for shim in ["record.sh", "record.cmd", "record.ps1"] {
        let path = repo_file("tests/harness/shims").join(shim);
        failures.check(shim, path.is_file(), || "shim body is missing".to_string());
    }

    let sh = read_repo_file("tests/harness/capture.sh");
    let ps = read_repo_file("tests/harness/capture.ps1");
    for name in ["afplay", "paplay", "terminal-notifier", "notify-send"] {
        failures.check(name, sh.contains(name), || {
            "named by KTD10 but not installed by capture.sh".to_string()
        });
    }
    failures.check("powershell.cmd", ps.contains("powershell.cmd"), || {
        "the Windows PATH shim is not installed by capture.ps1".to_string()
    });
    failures.assert_empty("harness shims");
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

// ---------------------------------------------------------------------------
// Payload (R21, R24, KTD14 / AE6, AE13 / U8)
// ---------------------------------------------------------------------------

/// Reads a pinned payload from `tests/harness/payloads/`, resolving the two
/// placeholders the capture harness substitutes. The same files feed the
/// fixture captures, so a payload that drifts breaks both at once.
fn payload_fixture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("harness")
        .join("payloads")
        .join(name);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()))
        .replace("{REPO}", "/scratch/repo")
        .replace("{HOME}", "/scratch/home")
}

fn shown<T: std::fmt::Display>(v: Option<T>) -> String {
    v.map(|x| x.to_string()).unwrap_or_default()
}

/// One name-to-value lookup so the tables below read as the parity block does,
/// rather than as twenty separate assertions.
fn field(p: &Payload, name: &str) -> String {
    match name {
        "session_id" => p.session_id().to_string(),
        "cwd" => p.cwd().to_string(),
        "git_cwd" => p.git_cwd().to_string(),
        "model_display_name" => p.model_display_name().to_string(),
        "model_id" => p.model_id().to_string(),
        "context_window_size" => shown(p.context_window_size()),
        "used_percentage" => shown(p.used_percentage()),
        "total_input_tokens" => shown(p.total_input_tokens()),
        "effort_level" => p.effort_level().to_string(),
        "total_cost_usd" => shown(p.total_cost_usd()),
        "duration_ms" => shown(p.duration_ms()),
        "transcript_path" => p.transcript_path().to_string(),
        "rate_five_hour_percentage" => shown(p.rate_five_hour_percentage()),
        "rate_five_hour_resets_at" => p.rate_five_hour_resets_at().to_string(),
        "rate_seven_day_percentage" => shown(p.rate_seven_day_percentage()),
        "rate_seven_day_resets_at" => p.rate_seven_day_resets_at().to_string(),
        "agent_name" => p.agent_name().to_string(),
        "agent_input_tokens" => p.agent_input_tokens().to_string(),
        "agent_output_tokens" => p.agent_output_tokens().to_string(),
        other => panic!("no accessor named {other} — the table and the model disagree"),
    }
}

/// Every field the parity block extracts, with the value `full.json` carries.
/// The three duplicated spellings — the second `workspace.current_dir` read,
/// and the legacy cost and duration keys — are covered by `git_cwd` and by the
/// fallback tests below rather than by separate rows.
const FULL_PAYLOAD_FIELDS: &[(&str, &str)] = &[
    ("session_id", "fixture-session-0001"),
    ("cwd", "/scratch/repo"),
    ("git_cwd", "/scratch/repo"),
    ("model_display_name", "Opus 5"),
    ("model_id", "claude-opus-5"),
    ("context_window_size", "200000"),
    ("used_percentage", "42.5"),
    ("total_input_tokens", "85000"),
    ("effort_level", "high"),
    ("total_cost_usd", "1.2345"),
    ("duration_ms", "654321"),
    (
        "transcript_path",
        "/scratch/home/.claude/projects/fixtures/transcript.jsonl",
    ),
    ("rate_five_hour_percentage", "31"),
    ("rate_five_hour_resets_at", "2026-01-01T05:00:00Z"),
    ("rate_seven_day_percentage", "12"),
    ("rate_seven_day_resets_at", "2026-01-05T00:00:00Z"),
    ("agent_name", "main"),
    ("agent_input_tokens", "84000"),
    ("agent_output_tokens", "1000"),
];

#[test]
fn full_payload_reads_every_documented_field() {
    let raw = payload_fixture("full.json");
    let p = Payload::parse(&raw).expect("the full fixture is a JSON object");

    let mut failures = Failures::default();
    for (name, want) in FULL_PAYLOAD_FIELDS {
        let got = field(&p, name);
        failures.check(name, got == *want, || format!("want {want:?}, got {got:?}"));
    }
    failures.assert_empty("full-payload extraction");
}

/// A payload carrying only `session_id` and the workspace directory. Absent is
/// not an error anywhere: every other field reads as its fallback, and the two
/// token counts read as 0 rather than as absent, which is what both scripts pin
/// them to.
#[test]
fn minimal_payload_falls_back_without_failing() {
    let raw = payload_fixture("minimal.json");
    let p = Payload::parse(&raw).expect("the minimal fixture is a JSON object");

    let expected: &[(&str, &str)] = &[
        ("session_id", "fixture-session-0001"),
        ("cwd", "/scratch/repo"),
        ("git_cwd", "/scratch/repo"),
        ("model_display_name", ""),
        ("model_id", ""),
        ("context_window_size", ""),
        ("used_percentage", ""),
        ("total_input_tokens", ""),
        ("effort_level", ""),
        ("total_cost_usd", ""),
        ("duration_ms", ""),
        ("transcript_path", ""),
        ("rate_five_hour_percentage", ""),
        ("rate_five_hour_resets_at", ""),
        ("agent_name", ""),
        ("agent_input_tokens", "0"),
        ("agent_output_tokens", "0"),
    ];

    let mut failures = Failures::default();
    for (name, want) in expected {
        let got = field(&p, name);
        failures.check(name, got == *want, || format!("want {want:?}, got {got:?}"));
    }
    failures.assert_empty("minimal-payload fallback");
}

/// AE6. One field carrying the wrong JSON type costs exactly its own row. The
/// whole reason the payload is read as a generic value (KTD14): a derived model
/// would reject the document and blank the entire status line.
#[test]
fn one_wrong_typed_field_degrades_only_its_own_row() {
    let raw = payload_fixture("full.json")
        .replace("\"used_percentage\": 42.5", "\"used_percentage\": {}");
    let p = Payload::parse(&raw).expect("a wrong-typed field must not fail the document");

    assert_eq!(
        p.used_percentage(),
        None,
        "an object where a number belongs must read as absent"
    );

    let mut failures = Failures::default();
    for (name, want) in FULL_PAYLOAD_FIELDS {
        if *name == "used_percentage" {
            continue;
        }
        let got = field(&p, name);
        failures.check(name, got == *want, || {
            format!("collateral damage: want {want:?}, got {got:?}")
        });
    }
    failures.assert_empty("AE6 single-row degradation");
}

/// The scripts read the payload as 23 newline-separated rows, so a field whose
/// *value* looks like more payload is the classic way to shift every field
/// after it. Structured parsing cannot be fooled that way, and this pins it.
#[test]
fn decoy_field_names_inside_values_do_not_shift_extraction() {
    let raw = r#"{
      "session_id": "real-session",
      "model": { "display_name": "\"session_id\": \"decoy\", \"model\": {" },
      "effort": { "level": "high" }
    }"#;
    let p = Payload::parse(raw).expect("decoy payload is a JSON object");

    assert_eq!(p.session_id(), "real-session");
    assert_eq!(p.effort_level(), "high");
    assert_eq!(
        p.model_display_name(),
        "\"session_id\": \"decoy\", \"model\": {"
    );
}

/// A newline inside a string value shifts every later field in the bash
/// scripts: `jq -r` prints it literally and `mapfile` splits on it, so
/// `_jf[4]` onward move by one. Rust reads fields by name and cannot shift.
/// A deliberate divergence in an exotic case, recorded rather than reproduced —
/// the bash behaviour is a bug, and no fixture exercises it.
#[test]
fn a_newline_inside_a_value_does_not_shift_later_fields() {
    let raw = r#"{
      "session_id": "line-one\nline-two",
      "model": { "display_name": "Opus 5" },
      "context_window": { "context_window_size": 200000 }
    }"#;
    let p = Payload::parse(raw).expect("multi-line value payload is a JSON object");

    assert_eq!(p.session_id(), "line-one\nline-two");
    assert_eq!(p.model_display_name(), "Opus 5");
    assert_eq!(p.context_window_size(), Some(200_000));
}

/// Astral-plane characters survive the round trip. The token-extraction
/// incident behind this fixture is U9's, but the payload has to carry the
/// characters intact before the transcript scan can mishandle them.
#[test]
fn astral_plane_characters_survive_the_round_trip() {
    let raw = payload_fixture("astral.json");
    let p = Payload::parse(&raw).expect("the astral fixture is a JSON object");

    assert_eq!(p.model_display_name(), "Opus 5 🚀");
    assert_eq!(p.agent_name(), "𝕬gent 🧪");
    assert_eq!(
        sanitize_display(p.agent_name()),
        "𝕬gent 🧪",
        "the render scrub must not damage characters outside the BMP"
    );
}

/// Paths are read, never validated. A payload from a machine whose paths this
/// host could not create still has to parse, because the binary that reads it
/// may be running on a different platform than the one that wrote the session.
#[test]
fn hostile_and_overlong_paths_read_without_error() {
    let illegal = r#"/tmp/a<b>c:d"e|f?g*h/transcript.jsonl"#;
    let overlong = format!("/tmp/{}/transcript.jsonl", "d".repeat(300));
    // The quote is part of the hostile input, so it has to reach the parser as
    // a JSON escape rather than as a string terminator.
    let escaped = illegal.replace('"', "\\\"");
    let raw = format!(
        r#"{{ "session_id": "s", "transcript_path": "{escaped}", "workspace": {{ "current_dir": "{overlong}" }} }}"#
    );
    let p = Payload::parse(&raw).expect("hostile paths must not fail the parse");

    assert_eq!(
        p.transcript_path(),
        illegal,
        "the transcript path is opened, not rendered, so it is never scrubbed — \
         including the pipe, which the display scrub would have replaced"
    );
    assert_eq!(p.cwd(), overlong);
}

/// AE13. The render sink strips anything that could move the cursor, colour the
/// line, or forge a column separator.
#[test]
fn display_scrub_removes_escape_and_control_bytes() {
    let cases: &[(&str, &str, &str)] = &[
        ("esc-sequence", "\u{1b}[31mred\u{1b}[0m", "[31mred [0m"),
        ("bare-esc", "a\u{1b}b", "a b"),
        ("c0-bell-and-soh", "a\u{7}b\u{1}c", "a b c"),
        ("del", "a\u{7f}b", "a b"),
        ("nul", "a\u{0}b", "a b"),
        ("carriage-return", "a\rb", "a b"),
        ("pipe-forges-a-separator", "main|fake", "main fake"),
        ("trims-to-empty", "\u{1b}\u{1}\u{7f}", ""),
        ("leading-and-trailing", "  branch  ", "branch"),
        ("interior-spaces-kept", "a  b", "a  b"),
        (
            "clean-value-untouched",
            "dev-rust-migration",
            "dev-rust-migration",
        ),
    ];

    let mut failures = Failures::default();
    for (name, input, want) in cases {
        let got = sanitize_display(input);
        failures.check(name, got == *want, || format!("want {want:?}, got {got:?}"));
    }
    failures.assert_empty("display scrub");
}

/// R21's fatal cases: the two inputs that make the scripts print
/// `[statusline: bad JSON]` instead of a status line.
#[test]
fn parse_rejects_exactly_what_the_scripts_reject() {
    let malformed = payload_fixture("malformed.json");
    let cases: &[(&str, &str, bool)] = &[
        ("empty", "", false),
        ("whitespace-only", "   \n  ", false),
        ("malformed-fixture", &malformed, false),
        ("json-array", "[1, 2, 3]", false),
        ("json-string", "\"just a string\"", false),
        ("json-number", "42", false),
        ("json-null", "null", false),
        ("json-true", "true", false),
        ("trailing-garbage", "{} trailing", false),
        ("empty-object", "{}", true),
        ("object", "{\"session_id\": \"s\"}", true),
    ];

    let mut failures = Failures::default();
    for (name, raw, want_ok) in cases {
        let got = Payload::parse(raw).is_some();
        failures.check(name, got == *want_ok, || {
            format!("want parse ok = {want_ok}, got {got}")
        });
    }
    failures.assert_empty("parse acceptance");
}

/// The tolerant helpers, at the type boundaries that decide whether a row
/// renders. Numeric strings are accepted because jq hands bash every field as
/// text and bash re-parses it, so quoting a number has never changed the
/// rendered line.
#[test]
fn tolerant_reads_match_the_scripts_accepted_types() {
    let raw = r#"{
      "session_id": "s",
      "quoted_int": "200000",
      "quoted_float": "42.5",
      "integral_float": 200000.0,
      "negative": -5,
      "signed_string": "-5",
      "spaced_string": " 42 ",
      "flag_false": false,
      "flag_true": true,
      "as_object": {},
      "as_array": [],
      "as_null": null,
      "empty_string": ""
    }"#;
    let p = Payload::parse(raw).expect("type-matrix payload is a JSON object");

    let mut f = Failures::default();
    let mut check = |name: &str, ok: bool, detail: String| f.check(name, ok, || detail);

    check(
        "quoted-int-as-uint",
        p.uint(&["quoted_int"]) == Some(200_000),
        format!("{:?}", p.uint(&["quoted_int"])),
    );
    check(
        "quoted-float-as-number",
        p.number(&["quoted_float"]) == Some(42.5),
        format!("{:?}", p.number(&["quoted_float"])),
    );
    check(
        "integral-float-as-uint",
        p.uint(&["integral_float"]) == Some(200_000),
        format!("{:?}", p.uint(&["integral_float"])),
    );
    check(
        "negative-rejected-by-uint",
        p.uint(&["negative"]).is_none(),
        format!("{:?}", p.uint(&["negative"])),
    );
    check(
        "negative-accepted-by-number",
        p.number(&["negative"]) == Some(-5.0),
        format!("{:?}", p.number(&["negative"])),
    );
    check(
        "signed-string-rejected-by-uint",
        p.uint(&["signed_string"]).is_none(),
        format!("{:?}", p.uint(&["signed_string"])),
    );
    check(
        "spaced-string-rejected-by-uint",
        p.uint(&["spaced_string"]).is_none(),
        format!("{:?}", p.uint(&["spaced_string"])),
    );
    // jq's `//` returns its right-hand side for `false` as well as null, so a
    // false-valued field has always read as absent. Reproduced, not fixed.
    check(
        "false-reads-as-absent",
        p.number(&["flag_false"]).is_none() && p.text(&["flag_false"]).is_empty(),
        "false leaked through".to_string(),
    );
    check(
        "true-is-not-a-string",
        p.text(&["flag_true"]).is_empty(),
        format!("{:?}", p.text(&["flag_true"])),
    );
    for name in ["as_object", "as_array", "as_null", "empty_string"] {
        check(
            name,
            p.text(&[name]).is_empty() && p.number(&[name]).is_none(),
            format!("{name} did not read as absent"),
        );
    }
    check(
        "absent-path",
        p.text(&["nope", "deeper"]).is_empty() && p.uint(&["nope"]).is_none(),
        "a missing path must not panic or invent a value".to_string(),
    );
    check(
        "descend-through-a-scalar",
        p.text(&["session_id", "deeper"]).is_empty(),
        "walking into a string must read as absent".to_string(),
    );

    f.assert_empty("tolerant type handling");
}

/// The fallback chains, which live in the model rather than at each call site
/// because both scripts spell them out identically and a second copy would
/// eventually disagree.
#[test]
fn legacy_field_spellings_fall_back_in_the_scripts_order() {
    let legacy = r#"{
      "session_id": "s",
      "cwd": "/fallback/dir",
      "total_cost_usd": 9.99,
      "duration_ms": 1234
    }"#;
    let p = Payload::parse(legacy).expect("legacy payload is a JSON object");

    assert_eq!(
        p.cwd(),
        "/fallback/dir",
        "cwd falls back to the top-level key"
    );
    assert_eq!(
        p.git_cwd(),
        "",
        "the git row reads workspace.current_dir only — it has no cwd fallback"
    );
    assert_eq!(p.total_cost_usd(), Some(9.99));
    assert_eq!(p.duration_ms(), Some(1234.0));

    let preferred = r#"{
      "session_id": "s",
      "cwd": "/fallback/dir",
      "workspace": { "current_dir": "/preferred/dir" },
      "cost": { "total_cost_usd": 1.0, "total_duration_ms": 10 },
      "total_cost_usd": 9.99,
      "total_duration_ms": 20,
      "duration_ms": 30
    }"#;
    let p = Payload::parse(preferred).expect("preferred payload is a JSON object");

    assert_eq!(p.cwd(), "/preferred/dir");
    assert_eq!(p.git_cwd(), "/preferred/dir");
    assert_eq!(p.total_cost_usd(), Some(1.0));
    assert_eq!(p.duration_ms(), Some(10.0));
}
