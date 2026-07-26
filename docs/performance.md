---
module: statusline
doc_type: performance_practices
status: standing
component: statusline
scope: all-platforms
sources:
  - performance-audit-master.md (local working document, not committed)
  - performance-audit-verification.md (local working document, not committed)
tags:
  - performance
  - process-startup
  - caching
  - benchmarking
  - review-checklist
---

# Performance Practices

Standing rules for writing and reviewing statusline code. Grounded in the verified findings
of the 2026-07-26 performance audits (`performance-audit-master.md` and its verification
record — local working documents, not committed; the load-bearing numbers are restated
here). CLAUDE.md's Performance rules section points here; this document is the detail
behind it.

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
- The region before the output-cache hit exit is a **zero-cmdlet zone**, not a style
  preference: the first cmdlet call in a fresh process pays ~80 ms of one-time
  command-discovery init, so a single `Get-Item` or `Test-Path` added there re-adds
  everything the deferred parse saved. Grep the pre-hit region for cmdlet names before
  merging. Elsewhere on hot paths, prefer .NET calls over pipeline cmdlets:
  `[IO.File]::ReadAllText`, `[IO.Directory]::GetFiles`, `[Console]::Write`, `$s.Length`,
  `.StartsWith()`.
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
- Do not re-test the ruled-out hypotheses without new evidence: temp-glob scaling with
  file count (false — flat; the cost is one-time provider load), pre-compiled `[regex]`
  (slower), ACL-check removal (load-bearing), `pwsh` 7 (slower start), script-size/parse
  cost (~10 ms, not the problem).

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

## 6. Current agreed direction (from the 2026-07-26 audits)

Implementation order when performance work is picked up:

1. Tier 1 quick wins (Windows) — **done** (`461e89a`): guard log call sites, `Write-Host` →
   `[Console]::Write`, `ReadAllText` cache read, direct property access, `GetFiles` glob.
   The JSON-parse deferral landed with it (`b8ecec6`): raw-string key fields plus a
   zero-cmdlet pre-hit path — measured hit 427.6 → 333.7 ms, miss +2.8 ms.
2. Git 6 → 2 consolidation (all platforms) — **done** (`d5407f8`): one
   `status --porcelain=v2 --branch --show-stash` + `diff --shortstat`; 13-state matrix
   byte-identical; miss median −107 ms. Floor: git ≥ 2.15.
3. Incremental transcript parse (all platforms) — offset of last complete line, size-shrink
   rescan, head checksum, carried idle verdict, `CACHE_VERSION` bump.
4. Bash fork reductions: single-pass idle detection, nameref helpers, jq consolidation,
   `get_vis` hoist, builtin substitutions.
5. Config: align `refreshInterval` deliberately across platforms — **done** (`a76e1b0`):
   all installers ship 2.

Open design questions (unowned, highest leverage): keying the output cache on rendered
values instead of raw payload; taking the 5 s bucket out of the key.

### Rendered-value cache key decision (2026-07-26, U9 design gate) — no change

The design resolved cleanly (two-tier key: today's raw-level key as tier 1, a
rendered-value key checked after display inputs are computed as tier 2; tier 2 needs no
time bucket because visible countdown labels self-invalidate; threshold notifications
are safe where they are because rendered percentages and configured thresholds are both
integers, so every crossing changes the key). It fails on the measured benefit bar:

- A tier-2 hit still pays everything before the render — measured 501 ms of a 538.6 ms
  forced-miss tick — because those stages produce the tier-2 key's inputs.
- The render tail (box assembly, notifications, cache write, emit) is **37.6 ms**: the
  per-hit ceiling, ~7% of tick cost, against a permanent second key tier in three
  scripts whose completeness failure mode is a silently stale display.
- Root cause: the audits priced this idea against pre-optimization misses (0.7–1.4 s).
  The git consolidation and incremental transcript parse moved that work behind their
  own caches, leaving the rendered-value key nothing expensive to skip.

Reopen condition: a future change that makes the render tail expensive again (or a
requirement to eliminate the idle 5 s re-render entirely, which additionally needs a
replacement idle recompute driver for ref-only git changes — see the plan's U9 gate
questions for the full analysis).

### Subagent tee decision (2026-07-26, U10 design gate) — no change

Measured (fresh-process medians, 11+ samples): current handler ~266 ms; interpreter floor
~142 ms; raw-tee + .NET-only I/O prototype ~172 ms (−35.5%, the only variant clearing the
pre-registered ≥30% bar); cmdlet-swap-only ~249 ms (−6.9%, byte-identical output).

The bar-clearing variant does not ship, because it fails the bar's contract half:

- **Malformed-tick isolation is lost.** Today a broken payload throws in `ConvertFrom-Json`
  and writes nothing — the last good feed survives. A raw tee writes the garbage over it,
  silently dropping the feed tier for that session until the next good tick.
- **Raw retention feeds `tokenSamples` (an accumulating per-task array) and other
  unfiltered fields into the statusline's output-cache key** (feed content is a key
  input). Unverified tick-to-tick order/field stability risks re-introducing the
  every-tick-miss behaviour the cache work exists to eliminate.

Reopen conditions: a live multi-tick capture confirming raw field/order stability and no
idle-tick key churn, plus a structural guard (trimmed payload starts `{` and ends `}`)
re-measured to confirm the mechanism still clears 30%. The −6.9% cmdlet swap remains a
zero-risk fallback but does not meet this unit's bar on its own.
