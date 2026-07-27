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
