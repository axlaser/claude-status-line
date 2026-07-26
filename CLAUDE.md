# CLAUDE.md -- claude-statusline

Cross-platform custom status line for Claude Code. Claude Code pipes JSON to stdin on each refresh; scripts parse, cache, and render ANSI output.

## Project Structure

```
macos/       statusline.sh, install.sh, uninstall.sh, notify.sh, git-refresh.sh, subagent-statusline.sh
linux/       statusline.sh, install.sh, uninstall.sh, notify.sh, git-refresh.sh, subagent-statusline.sh
windows/     statusline.ps1, install.ps1, uninstall.ps1, notify.ps1, git-refresh.ps1, subagent-statusline.ps1
docs/solutions/  documented fixes and practices, by category, with YAML frontmatter (module, tags, problem_type) -- relevant when debugging or implementing in an area one of them covers
docs/performance.md  standing performance rules: cost model, measurement methodology, equivalence matrix, PR checklist -- binding for any hot-path change
```

- `notify.*` -- sound notification handler, triggered by hooks on permission requests and task completion
- `git-refresh.*` -- cache invalidation hook registered as PostToolUse, clears stale git status after file-modifying tools
- `subagent-statusline.*` -- subagentStatusLine handler, tees Claude Code's per-task feed to a session state file for the status line to read; prints nothing so the default agent panel stays intact

## Architecture

- **macOS/Linux**: Bash 4+ scripts using `jq` for JSON parsing
- **Windows**: PowerShell 5.1+ with native `ConvertFrom-Json`
- macOS and Linux scripts are kept in sync; Windows is functionally equivalent using PS idioms
- Output cached by hashing JSON + file modification times; git status cached with 5s TTL
- **Statusline scripts are deliberately single-file per platform.** Installers fetch each script individually, so a sourced helper file would create a partial-upgrade hazard (new statusline + stale/missing sibling = broken status line). Accept file growth and small in-file repetition (e.g. the done-linger stamp/expire logic at its three per-platform sites) -- do not split `statusline.*` into sourced files or flag its length in reviews

### JSON Input Contract

Claude Code pipes a JSON object to stdin on each refresh. Key top-level fields:

`session_id`, `workspace.current_dir`, `cwd`, `model.display_name`, `context_window.context_window_size`, `context_window.used_percentage`, `context_window.total_input_tokens`, `effort.level`, `cost.total_cost_usd`, `transcript_path`, `rate_limits.five_hour.*`, `rate_limits.seven_day.*`, `agent.name`, `context_window.current_usage.*`

See the `# @parity:json-extract-begin` / `# @parity:json-extract-end` block in `macos/statusline.sh` for the full field list.

### Subagent Tasks Feed

Second input contract beside the stdin JSON: Claude Code's `subagentStatusLine` feature pipes `{session_id, tasks: [...]}` (per-task model, context window size, status, token count, description) to `subagent-statusline.*` on each refresh tick. The handler prints nothing and tees the payload to `statusline-tasks-<session-id>.json` in the OS temp dir (`$TMPDIR`, `%TEMP%` on Windows); the status line reads it when fresh. Per-task `model` / `contextWindowSize` require Claude Code >= v2.1.205 -- without feed data, the status line falls back to parsing subagent transcripts, resolving context windows via the learned map (`~/.claude/statusline-model-windows.json`, written from each main session's model -> window pair), then a seed table, then a 200K default.

### Dependencies

- **macOS/Linux**: `jq`, `git`, Bash 4+ (for `mapfile`)
- **Windows**: PowerShell 5.1+ (no external dependencies)
- macOS/Linux installers offer to install `jq` via the detected package manager

## Development

### Branching

Two-tier flow: create feature branches as `dev-<feature>` (e.g. `dev-notifications`), PR them into `dev`, and periodically release `dev` into `master` via a release PR. The repo-local `pr` and `sync` skills pick the right base/source automatically from this model.

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
- **Exception:** `windows/install.ps1` and `windows/uninstall.ps1` are **BOM-less and ASCII-only**. They run via `irm <url> | iex`, and a BOM survives `irm` as a stray U+FEFF that breaks `iex` on the first token (fixed in `762dcc0`, regressed once by re-applying the BOM rule mechanically -- do not "fix" the missing BOM back). ASCII-only keeps them safe to run from a local clone too.

Getting this wrong breaks Windows PowerShell parsing of non-ASCII literals.

---

## Rules

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work.
Naming: Bash uses `snake_case` functions and `UPPER_CASE` constants; PowerShell uses `PascalCase` functions.

### Cross-Platform Parity

Changes to `macos/` almost always require matching changes in `linux/` and `windows/`.
macOS and Linux share Bash -- keep them in sync. Windows PowerShell is functionally equivalent; port the same logic using PS idioms.
Never merge a change that updates one platform without considering the others.

### Silent Degradation

Statusline scripts (`statusline.*`, `notify.*`, `git-refresh.*`, `subagent-statusline.*`) must always `exit 0`, even on error. Never print to stderr.
Log errors via the debug log (`STATUSLINE_DEBUG`), not to the user's terminal.
Breaking this contract crashes the Claude Code status line for users.

### No `exit` in Install/Uninstall Scripts

Install and uninstall scripts must never use `exit`. Windows scripts are invoked via `irm | iex`, which runs in the user's current PowerShell session -- `exit` terminates that session and closes the terminal window.

- **Trailing `exit 0`**: Remove it. Scripts naturally return 0 when they reach the end.
- **Bash error paths**: Use `return 1 2>/dev/null || exit 1`. `return` succeeds when sourced; `exit` is the fallback for subshell invocation via `curl | bash`.
- **PowerShell error paths**: Use `return`. This exits the script scope without terminating the session.

This rule applies only to `install.*` and `uninstall.*`. Statusline, notify, git-refresh, and subagent-statusline scripts run as subprocesses where `exit 0` is required (see Silent Degradation above).

### Performance

The hot cost is process creation, not script logic: every refresh spawns a fresh interpreter (~124 ms PowerShell floor), so every call is a first call and every fork counts. Full rules, cost model, and the mandatory PR checklist live in `docs/performance.md`. The non-negotiables:

- No new subprocess/fork on a per-tick path, and no new work before the output-cache check.
- Performance changes must keep rendered output byte-identical (verified across the state matrix in `docs/performance.md` §4) and must be measured with fresh-process probes, never warm loops — end-to-end before/after medians only.
- Debug-log call sites must not evaluate expensive arguments when logging is off (PowerShell evaluates arguments before the callee's guard).
- Bump `CACHE_VERSION` whenever a cache record format changes.

### Repo Skills and Branching

- Every commit, sync, and pull request goes through the repo-local skills (`commit`, `sync`, `pr`) — never hand-written `git commit`, `git merge`, or `gh pr create`. The skills encode this repo's message style, two-tier flow, signing, and safety checks.
- Never create a new branch without asking the user first — use `AskUserQuestion` when available, plain chat otherwise. This applies even when a plan, skill, or workflow suggests a branch: the user decides branch creation, every time.

### Never Commit

- A hardcoded absolute personal path (`/Users/<name>/...`, `C:\Users\<name>\...`) where `$HOME` / `~` / `$env:USERPROFILE` belongs. This tool runs on other people's machines — a baked-in personal path is a shipped bug, not just a privacy leak.
- `statusline-debug.log` or any other runtime debug/log artifact.
