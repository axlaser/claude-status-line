//! Entry point for the multi-call binary.
//!
//! The whole file is the silent-degradation contract. Claude
//! Code spawns this process on every refresh and renders whatever reaches
//! stdout; anything on stderr, or a non-zero exit, breaks the user's status
//! line. Every layer below exists because one of them alone is not enough.

use std::io::Write;

use claude_statusline::{clock, cmd, config, debug, platform, self_check, session, settings};

/// Reads all of stdin, treating an unreadable or non-UTF-8 stream as empty.
///
/// Every caller degrades to "no payload" rather than failing: a hook that
/// errored on odd input would break the tool call that triggered it.
fn read_stdin() -> String {
    use std::io::Read;
    let mut buf = Vec::new();
    if std::io::stdin().read_to_end(&mut buf).is_err() {
        return String::new();
    }
    String::from_utf8_lossy(&buf).into_owned()
}

fn main() {
    // Layer 1: take fd 2 away before any code can write to it. The panic hook
    // below cannot intercept a stack overflow or an allocation failure — those
    // are written by the runtime straight to the descriptor.
    platform::redirect_stderr_to_null();

    // Layer 2: silence the default hook's multi-line panic message.
    std::panic::set_hook(Box::new(|_| {}));

    let args: Vec<String> = std::env::args().skip(1).collect();
    let sub = args.first().map(String::as_str).unwrap_or("statusline");
    let rest: Vec<&str> = args.iter().skip(1).map(String::as_str).collect();

    // `self-check` is deliberately outside the catch below. It is
    // the installer's only signal that a binary launches but renders wrongly,
    // so it has to be able to exit non-zero.
    if sub == "self-check" {
        let (rendered, code) = self_check();
        emit(&rendered);
        std::process::exit(code);
    }

    // `settings` is exempt for the same reason, from the other direction. The
    // exit-0 contract exists for the tick path, where a failure must never
    // break the user's status line. Here the caller is an installer deciding
    // whether it just configured Claude Code — a subcommand that reported
    // success while having written nothing is the worst outcome available.
    if sub == "settings" {
        std::process::exit(settings_cli(&rest));
    }

    // Layer 3: an unwinding panic anywhere below becomes a silent no-op.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| dispatch(sub, &rest)));
    if result.is_err() {
        debug::log(|| format!("panic caught in subcommand `{sub}`"));
    }

    // Layer 4: flush before exiting. `std::process::exit` runs no destructors,
    // so a buffered writer dropped here would silently discard the render and
    // still satisfy every exit-code and stderr assertion.
    flush();

    // Layer 5.
    std::process::exit(0);
}

/// `settings apply|remove|has|has-foreign|has-legacy`, the installers' JSON
/// editor.
///
/// Returns the process exit code: 0 for success or a true query, 1 otherwise.
/// Errors go to stdout, not stderr — fd 2 is already redirected to the null
/// device by the time this runs, so anything written there would vanish and
/// leave a failing installer with nothing to show the user.
fn settings_cli(rest: &[&str]) -> i32 {
    let mut binary = String::new();
    let mut path: Option<std::path::PathBuf> = None;
    let mut spec = settings::ApplySpec {
        quote: settings::quote_for_this_platform(),
        ..Default::default()
    };
    let mut positional: Vec<&str> = Vec::new();
    let mut args = rest.iter().copied();

    while let Some(arg) = args.next() {
        match arg {
            "--binary" => match args.next() {
                Some(v) => binary = v.to_string(),
                None => return fail("--binary needs a value"),
            },
            "--settings" => match args.next() {
                Some(v) => path = Some(std::path::PathBuf::from(v)),
                None => return fail("--settings needs a value"),
            },
            "--statusline" => spec.statusline = true,
            "--subagent" => spec.subagent = true,
            "--git-refresh" => spec.git_refresh = true,
            "--notify" => spec.notify = true,
            "--all" => {
                spec.statusline = true;
                spec.subagent = true;
                spec.git_refresh = true;
                spec.notify = true;
            }
            // Testing hooks: the platform default is what installers use.
            "--quote" => spec.quote = true,
            "--no-quote" => spec.quote = false,
            // A mistyped flag must not reach `positional` and be dropped. This
            // subcommand is exempt from the exit-0 contract precisely so a
            // caller can tell it configured nothing; silently accepting
            // `--subagnet` and then reporting success is the outcome that
            // exemption exists to prevent. Non-flag tokens still fall through:
            // `has`, `has-foreign` and `has-legacy` read a feature name there.
            other if other.starts_with("--") => return fail(&format!("unknown option: {other}")),
            other => positional.push(other),
        }
    }

    let action = match positional.first() {
        Some(a) => *a,
        None => {
            return fail(
                "usage: settings <apply|remove|has|has-foreign|has-legacy> --binary <path>",
            )
        }
    };
    if binary.is_empty() {
        return fail("--binary is required");
    }

    let path = match path.or_else(settings::default_path) {
        Some(p) => p,
        None => return fail("cannot resolve the home directory"),
    };

    let mut root = match settings::load(&path) {
        Ok(v) => v,
        Err(e) => return fail(&e),
    };

    match action {
        "apply" => {
            settings::apply(&mut root, &binary, &spec);
            match settings::save(&path, &root) {
                Ok(()) => 0,
                Err(e) => fail(&e),
            }
        }
        "remove" => {
            settings::remove(&mut root, &binary);
            match settings::save(&path, &root) {
                Ok(()) => 0,
                Err(e) => fail(&e),
            }
        }
        // Query forms report through the exit code so a shell can branch on
        // them without parsing output.
        "has" => match positional.get(1) {
            Some(f) if settings::has(&root, &binary, f) => 0,
            Some(_) => 1,
            None => fail("has needs a feature name"),
        },
        "has-foreign" => match positional.get(1) {
            Some(f) if settings::has_foreign(&root, &binary, f) => 0,
            Some(_) => 1,
            None => fail("has-foreign needs a feature name"),
        },
        // Unlike its siblings the feature name is optional: the installer
        // asks the unscoped form to decide whether it is migrating at all, and
        // the scoped form to carry one setting across.
        "has-legacy" => {
            if settings::has_legacy(&root, positional.get(1).copied()) {
                0
            } else {
                1
            }
        }
        other => fail(&format!("unknown settings action: {other}")),
    }
}

fn fail(message: &str) -> i32 {
    emit(&format!("claude-statusline settings: {message}\n"));
    1
}

fn dispatch(sub: &str, rest: &[&str]) {
    match sub {
        "statusline" => {
            let payload = read_stdin();
            let roots = cmd::statusline::Roots::from_env();
            emit(&cmd::statusline::run(&clock::SystemClock, &roots, &payload));
        }
        "notify" => {
            let event = rest.first().copied().unwrap_or("");
            let value = rest.get(1).copied().unwrap_or("");
            // Only the permission event carries a payload, and only it reads
            // stdin — the status line invokes the others with no input at all,
            // and a blocking read there would hang the tick that spawned it.
            let payload = if event == "permission" {
                read_stdin()
            } else {
                String::new()
            };
            let cfg = config::NotifyConfig::default_path()
                .map(|p| config::NotifyConfig::load(&p))
                .unwrap_or_default();
            let env = platform::notify::probe_env();
            for action in cmd::notify::plan(
                cmd::notify::Platform::current(),
                event,
                value,
                &payload,
                &cfg,
                &env,
            ) {
                platform::notify::execute(&action);
            }
        }
        "git-refresh" => {
            let payload = read_stdin();
            cmd::git_refresh::run(&payload, &session::temp_dir());
        }
        // Prints nothing on purpose: stdout here replaces Claude Code's default
        // agent panel rather than adding to it.
        "subagent" => {
            let payload = read_stdin();
            cmd::subagent::run(&payload, &session::temp_dir());
        }
        // Forces a panic so the catch above can be exercised. Kept in release
        // builds so the test drives the artifact that actually ships.
        "__panic-probe" => panic!("deliberate panic probe"),
        other => {
            let other = other.to_string();
            debug::log(move || format!("unknown subcommand: {other}"));
        }
    }
}

/// Writes to a locked stdout and flushes, swallowing failure. Never
/// `println!` — it panics on a broken pipe, which is a routine condition when
/// the parent stops reading.
fn emit(s: &str) {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    if lock.write_all(s.as_bytes()).is_err() {
        debug::log(|| "stdout write failed".to_string());
        return;
    }
    if lock.flush().is_err() {
        debug::log(|| "stdout flush failed".to_string());
    }
}

fn flush() {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    if lock.flush().is_err() {
        debug::log(|| "stdout flush failed at exit".to_string());
    }
}
