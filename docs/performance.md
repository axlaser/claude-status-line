---
module: statusline
doc_type: performance_practices
status: standing
component: statusline
scope: all-platforms
sources:
  - performance-audit-master.md
  - performance-audit-verification.md
tags:
  - performance
  - process-startup
  - caching
  - benchmarking
  - review-checklist
---

# Performance Practices

Standing rules for writing and reviewing statusline code. Grounded in the verified findings
of [`performance-audit-master.md`](performance-audit-master.md) (checked by
[`performance-audit-verification.md`](performance-audit-verification.md)). CLAUDE.md's
Performance rules section points here; this document is the detail behind it.

## 1. The cost model — what is actually expensive here

Every refresh is a **brand-new process**. That single fact drives everything:

1. **Process creation dominates.** ~124 ms floor for `powershell.exe` before line 1; every
   `fork`/`exec` on bash. The script's own logic is usually the minority of the cost.
2. **Every call is a first call.** Types, providers, and formatting pipelines load fresh each
   tick. Anything touching the pipeline (`Measure-Object`, `Select-Object`, `Get-ChildItem`,
   `Write-Host`) pays a load cost that a warm benchmark will never show you.
3. **Work scales with session length only in the transcript.** The transcript scan is linear
   (~12.5–17.5 ms/MB); everything else is roughly constant. Incremental parsing is the only
   fix whose value grows over time.
4. **The output cache hits at idle and misses during work** (its key hashes the raw payload,
   which changes every tick while Claude works). Until that is redesigned, treat the
   cache-miss path as the common case during active use — and keep the pre-cache-check
   region as thin as possible, because it runs on every tick regardless.

## 2. Hard rules (enforced in review)

**All platforms**
- No new subprocess / fork on any per-tick path. State the process-count delta (hit path and
  miss path) in the PR description for any hot-path change. Current baselines to stay under:
  bash 11 execs/hit, 34/miss; git block ≤ its current 6 (target 2 after consolidation).
- No new work before the output-cache check. Anything added there is paid on every tick,
  cache hit or not.
- Never read a file twice in one refresh when one pass can serve (the bash forward-awk +
  reverse-tac transcript read is a known violation being fixed, not a pattern to copy).
- Cache format changes bump `CACHE_VERSION` and keep the `@parity:cache` markers in sync
  across all three platforms.
- Rendered output is sacred: a performance change must be byte-identical on the standard
  state matrix (§4). If output must change, it is not a performance change — split the PR.

**Windows (PowerShell)**
- Prefer .NET calls over pipeline cmdlets on hot paths: `[IO.File]::ReadAllText`,
  `[IO.Directory]::GetFiles`, `[Console]::Write`, `$s.Length`, `.StartsWith()`.
- Debug logging must never evaluate expensive arguments when disabled — PowerShell evaluates
  arguments *before* the callee's guard. Wrap call sites: `if ($DBG) { Write-Log ... }`.
- Do not switch to `pwsh` 7 for the spawned process (measured slower to start: 198 vs 124 ms).
- Do not pre-compile `[regex]` objects (construction dominates; measured slower than `-match`).

**Bash (macOS/Linux)**
- New helpers return values via `printf -v` / nameref out-variables, not `$( )` command
  substitution — every substitution forks a subshell.
- Prefer builtins over binaries: parameter expansion over `dirname`/`basename`/`cut`,
  `${EPOCHSECONDS:-$(date +%s)}` over bare `date +%s` (bash-4 fallback required), batched
  `stat` over per-file calls.
- awk hot loops: `index()`/`substr()` extraction over whole-line `sub()` chains.

## 3. Measurement methodology (how numbers must be produced)

The central lesson of the audits: **warm-loop micro-benchmarks are systematically wrong for
this codebase** — they understate first-call costs by up to 100×. Production spawns a fresh
process per tick, so measurements must too.

- **One fresh process per probe.** Never loop a probe inside a warm host to average it.
- **Median of ≥ 7 runs**; state machine, OS, and PowerShell/bash version alongside numbers.
- **Isolated numbers do not sum and must not be used for claims.** Removing one first-call
  cost shifts load onto the next operation (fixing eager logging makes the JSON parse look
  more expensive). Only **end-to-end before/after** medians of the real script justify a
  "saves X ms" claim.
- **Bash on Git Bash: process counts are portable, milliseconds are not** (emulated fork is
  ~20–50× a real one). Report counts, not Git Bash ms, for macOS/Linux claims.
- Do not re-test the ruled-out hypotheses in master §7 (temp-glob scaling, pre-compiled
  regex, ACL-check removal, pwsh 7, script-size/parse cost) without new evidence.

## 4. Equivalence verification (required for hot-path refactors)

Before merging, capture full rendered output from the current and changed script and compare
byte-for-byte across:

- **Git states** (scratch repo): fresh/unborn HEAD, clean, untracked-only, dirty,
  stashes present, ahead-of-upstream, detached HEAD, no upstream, collapsed untracked dir,
  stash-cleared. Run the matrix **per platform** — platforms differ today on unborn HEAD
  (Windows renders `HEAD`, bash renders no git segment), so "matches current behaviour" is a
  per-platform statement.
- **Payload states**: full payload, minimal payload (missing optional fields), empty stdin,
  malformed JSON (all must exit 0, no stderr).
- **Transcript states**: absent, empty, large (≥ 4 MB real transcript), and — once
  incremental parsing ships — truncated/rotated and same-size-rewritten files must fall back
  to a full rescan (size-shrink check + head checksum).

Known parsing traps that this matrix exists to catch: PowerShell `-like '? *'` treats `?` as
a wildcard (use `.StartsWith('? ')`); porcelain v2 emits `# branch.oid (initial)` on unborn
HEAD, omits `# branch.ab` when no upstream, omits `# stash` at zero.

## 5. PR checklist for statusline hot-path changes

- [ ] Process/fork delta stated (hit and miss paths), per platform.
- [ ] Nothing new runs before the output-cache check (or the addition is justified).
- [ ] End-to-end before/after medians measured per §3 (fresh process, ≥ 7 runs).
- [ ] Byte-identical output across the §4 matrix, on every platform touched.
- [ ] Cross-platform parity: all three platforms updated or the divergence justified.
- [ ] `CACHE_VERSION` bumped if any cache record format changed.
- [ ] No debug-log call site evaluates expensive arguments when logging is off.

## 6. Current agreed direction (from the master audit)

Implementation order when performance work is picked up — see master §4 for full detail:

1. Tier 1 quick wins (Windows): guard log call sites, `Write-Host` → `[Console]::Write`,
   `ReadAllText` cache read, direct property access, `GetFiles` glob.
2. Git 6 → 2 consolidation (all platforms) — with the §4 state matrix per platform, the
   `(initial)` guard per current platform behaviour, and `.StartsWith('? ')`.
3. Incremental transcript parse (all platforms) — offset of last complete line, size-shrink
   rescan, head checksum, carried idle verdict, `CACHE_VERSION` bump.
4. Bash fork reductions: single-pass idle detection, nameref helpers, jq consolidation,
   `get_vis` hoist, builtin substitutions.
5. Config: align `refreshInterval` deliberately across platforms (bash installers currently
   ship 1 vs Windows' 2).

Open design questions (unowned, highest leverage): keying the output cache on rendered
values instead of raw payload; taking the 5 s bucket out of the key; absorbing the
subagent-statusline tee into a cheaper mechanism.
