# CLAUDE.md -- claude-status-line

Cross-platform custom status line for Claude Code. Claude Code pipes JSON to stdin on each refresh; scripts parse, cache, and render ANSI output.

## Project Structure

```
macos/       statusline.sh, install.sh, uninstall.sh, notify.sh, git-refresh.sh
linux/       statusline.sh, install.sh, uninstall.sh, notify.sh, git-refresh.sh
windows/     statusline.ps1, install.ps1, uninstall.ps1, notify.ps1, git-refresh.ps1
```

- `notify.*` -- sound notification handler, triggered by hooks on permission requests and task completion
- `git-refresh.*` -- cache invalidation hook registered as PostToolUse, clears stale git status after file-modifying tools

## Architecture

- **macOS/Linux**: Bash 4+ scripts using `jq` for JSON parsing
- **Windows**: PowerShell 5.1+ with native `ConvertFrom-Json`
- 95% code reuse between macOS and Linux; Windows is functionally equivalent using PS idioms
- Output cached by hashing JSON + file modification times; git status cached with 5s TTL

### JSON Input Contract

Claude Code pipes a JSON object to stdin on each refresh. Key top-level fields:

`session_id`, `workspace.current_dir`, `cwd`, `model.display_name`, `context_window.context_window_size`, `context_window.used_percentage`, `context_window.total_input_tokens`, `effort.level`, `cost.total_cost_usd`, `transcript_path`, `rate_limits.five_hour.*`, `rate_limits.seven_day.*`, `agent.name`, `context_window.current_usage.*`

See the `# @parity:json-extract-begin` / `# @parity:json-extract-end` block in `macos/statusline.sh` for the full field list.

### Dependencies

- **macOS/Linux**: `jq`, `git`, Bash 4+ (for `mapfile`)
- **Windows**: PowerShell 5.1+ (no external dependencies)
- macOS/Linux installers offer to install `jq` via the detected package manager

## Development

### Testing

No test framework. Manual testing required:

- Set `STATUSLINE_DEBUG=1` to enable debug logging to `~/.claude/statusline-debug.log`
- Test on all three platforms when possible; at minimum test macOS/Linux changes on one and verify the other by inspection
- Install locally via `bash macos/install.sh` (or platform equivalent) to test the full flow

What to verify after changes:

- Box renders without broken alignment or trailing characters
- Colors display correctly (green/yellow/red thresholds)
- No output to stderr (breaks Claude Code UI)
- Exit 0 on empty, malformed, or missing JSON input
- Git status row handles detached HEAD, no-repo, and fresh-clone states

### File Encoding

Enforced by `.gitattributes` -- do not override:

- `*.sh` -- LF line endings
- `*.ps1` -- CRLF line endings with UTF-8 BOM

Getting this wrong breaks Windows PowerShell parsing of non-ASCII literals.

---

## Rules

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work.

### General Principles

- **Think before coding.** State assumptions explicitly. Ask rather than guess. Push back when a simpler approach exists.
- **Simplicity first.** Minimum code that solves the problem. No abstractions for single-use code.
- **Surgical changes.** Touch only what you must. Match existing style. Don't refactor what isn't broken.
- **Goal-driven execution.** Define success criteria. Loop until verified.
- **Read before you write.** Read exports, immediate callers, and shared utilities before adding code.
- **Match conventions.** Conformance > taste. Surface disagreements, don't fork silently. Bash: `snake_case` functions, `UPPER_CASE` constants. PowerShell: `PascalCase` functions.
- **Checkpoint after every significant step.** Summarize what was done, what's verified, what's left.
- **Fail loud.** "Completed" is wrong if anything was skipped. Surface uncertainty, don't hide it.

### Cross-Platform Parity

Changes to `macos/` almost always require matching changes in `linux/` and `windows/`.
macOS and Linux share Bash -- keep them in sync. Windows PowerShell is functionally equivalent; port the same logic using PS idioms.
Never merge a change that updates one platform without considering the others.

### Silent Degradation

Statusline scripts (`statusline.*`, `notify.*`, `git-refresh.*`) must always `exit 0`, even on error. Never print to stderr.
Log errors via the debug log (`STATUSLINE_DEBUG`), not to the user's terminal.
Breaking this contract crashes the Claude Code status line for users.

### No `exit` in Install/Uninstall Scripts

Install and uninstall scripts must never use `exit`. Windows scripts are invoked via `irm | iex`, which runs in the user's current PowerShell session -- `exit` terminates that session and closes the terminal window.

- **Trailing `exit 0`**: Remove it. Scripts naturally return 0 when they reach the end.
- **Bash error paths**: Use `return 1 2>/dev/null || exit 1`. `return` succeeds when sourced; `exit` is the fallback for subshell invocation via `curl | bash`.
- **PowerShell error paths**: Use `return`. This exits the script scope without terminating the session.

This rule applies only to `install.*` and `uninstall.*`. Statusline, notify, and git-refresh scripts run as subprocesses where `exit 0` is required (see Silent Degradation above).
