//! Entry point for the multi-call binary.
//!
//! The whole file is the silent-degradation contract (R21, R22, KTD7). Claude
//! Code spawns this process on every refresh and renders whatever reaches
//! stdout; anything on stderr, or a non-zero exit, breaks the user's status
//! line. Every layer below exists because one of them alone is not enough.

use std::io::Write;

use claude_statusline::{debug, platform, self_check};

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

    // R11 / AE8: `self-check` is deliberately outside the catch below. It is
    // the installer's only signal that a binary launches but renders wrongly,
    // so it has to be able to exit non-zero.
    if sub == "self-check" {
        let (rendered, code) = self_check();
        emit(&rendered);
        std::process::exit(code);
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

fn dispatch(sub: &str, _rest: &[&str]) {
    match sub {
        // Filled in by U8-U13.
        "statusline" => {}
        // U7.
        "notify" => {}
        // U5.
        "git-refresh" => {}
        // U6.
        "subagent" => {}
        // AE4's trigger. Kept in release builds so the shipped artifact is the
        // one the acceptance example exercises.
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
