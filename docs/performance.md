# Performance Practices

Standing performance doctrine for the statusline scripts. CLAUDE.md's Performance rules
section binds every hot-path change to this file; this document is the detail behind it.

**This is a living document.** Update it whenever something new is established: a cost is
measured, a hypothesis is ruled out, a behavioral divergence is accepted, a design
decision is made, or the reference numbers in §6 change. A claim in this file should
always reflect the current scripts.

## 1. The cost model — what is actually expensive here

Every refresh is a **brand-new process**. That single fact drives everything:

1. **Process creation dominates.** ~124 ms floor for `powershell.exe` before line 1; every
   `fork`/`exec` on bash. The script's own logic is usually the minority of the cost.
2. **Every call is a first call.** Types, providers, and formatting pipelines load fresh each
   tick. Anything touching the pipeline (`Measure-Object`, `Select-Object`, `Get-ChildItem`,
   `Write-Host`) pays a load cost that a warm benchmark will never show you.
3. **Work scales with session length only in the transcript.** The transcript scan is linear
   (~12.5–17.5 ms/MB); everything else is roughly constant. The incremental parser bounds
   it: a changed transcript re-parses only appended bytes.
4. **The output cache hits at idle and misses during work** (its key hashes the raw payload,
   which changes every tick while Claude works). Treat the cache-miss path as the common
   case during active use — and keep the pre-cache-check region as thin as possible,
   because it runs on every tick regardless. (A rendered-value second key tier was
   designed and measured no-go — see the decision record in §7.)
5. **Per-item micro-costs do not sum.** The first cmdlet call in a process pays ~80 ms of
   one-time command-discovery init that every later cmdlet rides; removing N cmdlet calls
   saves one init plus small marginal costs, not N first-call measurements. The same holds
   for pipeline/module/assembly loads. Corollary: "the JSON parse costs ~90 ms" really
   means "the first cmdlet costs ~90 ms" — deferring the parse only pays off when the
   whole pre-hit region is cmdlet-free. Always attribute a saving with an end-to-end
   before/after median, never a sum of isolated probes.

## 2. Hard rules (enforced in review)

**All platforms**
- No new subprocess / fork on any per-tick path. State the process-count delta (hit path and
  miss path) in the PR description for any hot-path change. Current baselines to stay under
  (§6): bash 5 execs/hit, 14/miss; git block 2 subprocesses (3 on detached HEAD); Windows
  hit path zero cmdlets before the cache-hit exit.
- No new work before the output-cache check. Anything added there is paid on every tick,
  cache hit or not.
- Never read a file twice in one refresh when one pass can serve.
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
- Helpers return values via `printf -v` out-variables, not `$( )` command substitution —
  every substitution forks a subshell. The format string is always a fixed literal; data is
  never the format operand.
- Prefer builtins over binaries: parameter expansion over `dirname`/`basename`/`cut`,
  `${EPOCHSECONDS:-$(date +%s)}` over bare `date +%s` (bash-4 fallback required), batched
  `stat` (mapped back by filename) over per-file calls.
- awk hot loops: `index()`/`substr()` extraction over whole-line `sub()` chains, and always
  `LC_ALL=C` for byte-oriented scanning — a UTF-8 locale both breaks byte-offset math and
  corrupts gawk's regex extraction on astral-plane characters (see §4).

## 3. Measurement methodology (how numbers must be produced)

The central lesson: **warm-loop micro-benchmarks are systematically wrong for this
codebase** — they understate first-call costs by up to 100×. Production spawns a fresh
process per tick, so measurements must too.

- **One fresh process per probe.** Never loop a probe inside a warm host to average it.
- **Median of ≥ 7 runs**; state machine, OS, and PowerShell/bash version alongside numbers.
- **Isolated numbers do not sum and must not be used for claims.** Removing one first-call
  cost shifts load onto the next operation. Only **end-to-end before/after** medians of the
  real script justify a "saves X ms" claim.
- **Isolate the environment.** Every harness run points `TEMP`/`TMP` *and*
  `USERPROFILE`/`HOME` at a scratch directory (with a `.claude` subdir) and warms the
  learned-model map before sampling — otherwise the harness fights live sessions over a
  cache-key input and "hit" samples silently measure misses. When a benchmark claims to
  measure the hit path, verify hit-ness (cache-file mtime unchanged, or the debug log's
  HIT line); see `docs/solutions/workflow-issues/` and `docs/solutions/best-practices/`.
- **Bash on Git Bash: process counts are portable, milliseconds are not** (emulated fork is
  ~20–50× a real one). Report counts, not Git Bash ms, for macOS/Linux claims.
- **Script-vs-binary pairs go through `tests/harness/measure.sh` / `measure.ps1`**, which
  implement every rule above and refuse to report a number until each variant has been
  proven to do its work. A probe that silently no-opped reads as a spectacular speed-up:
  that guard is what caught a measurement of an unimplemented subcommand at U6.
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
  malformed JSON (all must exit 0, no stderr), plus adversarial variants: Windows-illegal
  path characters, overlong paths, decoy field names inside string values, astral-plane
  characters in string fields.
- **Transcript states**: absent, empty, large (≥ 4 MB real transcript), plus the incremental
  parser's edges: truncated/rotated and same-size-rewritten files fall back to a full rescan
  (size-shrink check + head checksum), torn trailing lines are re-read next tick, and a
  malformed/corrupt v2 cache record (wrong field count, out-of-range or oversized-digit
  offset, non-hex checksum) degrades to a full rescan on all three platforms. Multibyte
  fixtures must include a 4-byte (astral-plane) character, not just CJK.

Known parsing traps that this matrix exists to catch: PowerShell `-like '? *'` treats `?` as
a wildcard (use `.StartsWith('? ')`); porcelain v2 emits `# branch.oid (initial)` on unborn
HEAD, omits `# branch.ab` when no upstream, omits `# stash` at zero.

**Accepted divergences** (deliberate, documented — add new entries here when one is accepted):

- *2026-07-26:* a branch literally *named* `(detached)` is indistinguishable from real
  detached HEAD in porcelain v2, so it renders as the short commit hash instead of the name.
  Disambiguating would cost a subprocess on a pathological case; the sentinel collision is
  inherent to the v2 format.
- *2026-07-26:* under a UTF-8 locale, gawk's old greedy-regex token extraction silently
  zeroed the token counts of assistant lines containing an astral-plane character (emoji).
  The `LC_ALL=C` pin fixes the extraction, so token totals on emoji-bearing transcripts are
  higher — and correct — compared to earlier releases. Verified on GNU gawk 5.0; BSD awk
  unverified either way (no native macOS test hardware). See
  `docs/solutions/logic-errors/gawk-utf8-locale-zeroes-astral-plane-extraction.md`.
- *2026-07-27:* the path row's home-prefix match differs from `windows/statusline.ps1:287` on two
  spellings of a path, both resolved to the Rust port's behaviour. A `cwd` written with forward
  slashes under `$HOME` collapses to `~` (the script normalised the `cwd`'s separators but never
  `$USERPROFILE`'s own, so it fell through to `.../parent/leaf`), and the comparison is
  case-sensitive, so `c:\users\me\src` no longer collapses (the script used `OrdinalIgnoreCase`).
  Keeping the second would require a platform-conditional comparison, which R25 does not allow for
  path formatting. Neither shape is reachable in practice — Claude Code supplies native backslash
  paths in canonical casing on Windows, confirmed against a live session — which is why four
  rounds of fixture captures never produced either. Asserted as literals by
  `resolved_cwd_divergences_keep_the_ports_behaviour`.

## 5. PR checklist for statusline hot-path changes

- [ ] Process/fork delta stated (hit and miss paths), per platform.
- [ ] Nothing new runs before the output-cache check (or the addition is justified).
- [ ] End-to-end before/after medians measured per §3 (fresh process, ≥ 7 runs).
- [ ] Byte-identical output across the §4 matrix, on every platform touched.
- [ ] If the change touches a trust-checked cache read or an output-cache key input:
  observed hit/miss verified (oc-file mtime unchanged on a hit, or the debug log's HIT
  line) — byte-diffing alone cannot see a hit-rate regression (see
  `docs/solutions/best-practices/byte-diff-cannot-see-cache-hit-regressions.md`).
- [ ] Cross-platform parity: all three platforms updated or the divergence justified.
- [ ] `CACHE_VERSION` bumped if any cache record format changed.
- [ ] No debug-log call site evaluates expensive arguments when logging is off.
- [ ] §6 reference numbers updated if the change moves them.

## 6. Reference numbers (update when a hot-path change moves them)

End-to-end fresh-process medians, measured 2026-07-26 on the maintainer's machine
(Windows 11, Windows PowerShell 5.1; bash numbers are MSYS shape-only). These are the
baselines the §2 rules hold changes against.

| Path | Cost |
|---|---|
| Windows cache hit | ~326–334 ms |
| Windows miss, 13.4 MB transcript, unchanged content | 542 ms |
| Windows miss, 13.4 MB transcript, +100-line growth tick | 568 ms |
| Windows cold full rescan (once per session) | ~1470 ms |
| Windows miss, git cache expired | 614 ms |
| bash hit / miss (MSYS shape-only) | 249 / 1124 ms |
| bash external processes, hit / miss | 5 / 14 |
| bash forks, six-row subagent render | 39 |
| Interpreter floor (`powershell.exe -NoProfile`, empty script) | ~124 ms |

### R38 paired medians — script vs. binary (2026-07-27)

The Rust migration replaces each runtime script with a subcommand of one binary.
R38 requires both halves of the pair to be measured end to end, one fresh
process per probe, on a single host with the runs interleaved, and recorded
before that component's scripts are deleted — after deletion the script half can
never be measured again.

Produced by `tests/harness/measure.sh` and `measure.ps1`: 11 interleaved pairs
per host, payload `tests/harness/payloads/tasks-feed.json`, isolated
`HOME`/`TEMP`, `STATUSLINE_DEBUG` cleared so neither variant is charged for a log
append the other skips.

**Host class is part of the number.** A hosted-runner figure must never later be
held against a bare-metal baseline (R41), so every row carries the runner label
and image version it came from.

| Component | Host | Host class | Script | Binary | Delta |
|---|---|---|---|---|---|
| `subagent` | Windows 11 26200, Windows PowerShell 5.1.26100 | maintainer machine | 264.0 ms | 21.6 ms | −91.8% |
| `subagent` | `macos-15`, image `macos15 20260715.0234.1`, bash 5.3, jq 1.8.2 | hosted runner | 25.1 ms | 3.0 ms | −88.2% |
| `subagent` | `ubuntu-24.04`, image `ubuntu24 20260720.247.2`, bash 5.2, jq 1.7 | hosted runner | 10.4 ms | 1.1 ms | −89.1% |

Reading them:

- The Windows script figure independently corroborates §7's 2026-07-26
  measurement of the same handler (~266 ms), taken by a different harness.
- The Windows binary sits **below the ~124 ms interpreter floor**, which is the
  whole point of the migration's cost model: that floor was never the script's
  cost to avoid, it was the interpreter's cost to exist. There is no interpreter.
- Bash's own floor is ~10 ms, not ~124 ms, so the Unix saving is an order of
  magnitude smaller in absolute terms while being the same proportion. The three
  platforms were never paying the same price for the same handler.

Provenance: the binary half was built from a throwaway commit
(`d7a963ccbc975fd36b11091afc197de3173bd3d3`) that is deliberately not on the
branch. R37 keeps a component's port, its fixtures and its script deletion in
one commit, and R38 requires these medians to be recorded *before* that commit —
so the tree that was measured could not itself be a branch commit. The measured
content is what the U6 port commit lands.

#### `statusline` (2026-07-27)

Payload `tests/harness/payloads/full.json`, with the transcript and the learned
model-window map staged into the isolated `HOME` the payload points at, so both
variants parse a real session rather than an empty one.

R38 requires this pair to cover the large-transcript state. The transcript is
**generated to a target size** rather than pointed at a real session file: a
machine-local transcript is not reproducible on CI, on another machine, or next
month, and a number nobody else can reproduce is an anecdote rather than
evidence. Repeating one pinned record keeps the token totals a pure function of
the size.

All rows use a generated 8 MB transcript. Two states, because one of them alone
is misleading in each direction.

**Warm** — nothing changed since the last tick. The script's output cache (keyed
on a 5-second bucket) and its incremental parser are both working; the binary
skips its rescan on an unchanged `(mtime, size)`. This is the common tick.

| Host | Host class | Runs | Script | Binary | Delta |
|---|---|---|---|---|---|
| Windows 11 26200, Windows PowerShell 5.1.26100 | maintainer machine | 7 | 311.8 ms | 22.1 ms | **−92.9%** |
| `macos-15`, image `macos15 20260715.0234.1` | hosted runner | 11 | 70.5 ms | 5.0 ms | **−92.9%** |
| `ubuntu-24.04`, image `ubuntu24 20260720.247.2` | hosted runner | 11 | 13.2 ms | 1.3 ms | **−90.3%** |

**Cold** — every per-tick cache cleared before each probe, so both variants do
the whole job. This is the tick after the transcript grows.

| Host | Host class | Runs | Script | Binary | Delta |
|---|---|---|---|---|---|
| Windows 11 26200, Windows PowerShell 5.1.26100 | maintainer machine | 7 | 1527.1 ms | 72.4 ms | **−95.3%** |
| `macos-15`, image `macos15 20260715.0234.1` | hosted runner | 11 | 1282.0 ms | 74.4 ms | **−94.2%** |
| `ubuntu-24.04`, image `ubuntu24 20260720.247.2` | hosted runner | 11 | 299.8 ms | 62.1 ms | **−79.3%** |

The binary is faster on every platform in both states, by 79% to 95%. Three
things are worth keeping from how that number was arrived at:

- **The first version of this table had the binary 4× *slower* on Linux.** The
  port scanned the transcript unconditionally, which cost ~50 ms on 8 MB —
  invisible under PowerShell's ~124 ms interpreter floor, four times bash's
  entire tick. R27 had argued the scripts' incremental machinery "buys nothing
  once the interpreter is gone", measured against a *growing* transcript. That
  was the script's worst case, and the conclusion was over-generalised to
  platforms whose floor is an order of magnitude lower. The port now skips the
  rescan when `(mtime, size)` are unchanged, and Linux went from +307% to −90%.
- **A warm-only pair is not a comparison.** The script's output cache serves
  almost every probe of a short run, so the original measurement was the
  script's best case against the binary's only case — the state where it renders
  nothing at all read as 13 ms. The cold rows are the honest half, and they are
  where the script costs 0.3–1.5 seconds.
- **The two floors are still the whole story on Windows.** ~124 ms of the
  script's warm 311 ms is PowerShell starting. The binary's entire warm tick is
  22 ms, well below the floor the script cannot get under by any means.

Method note: `--cold-cache` / `-ColdCache` clears `statusline-*` from the
isolated temp root before each probe, outside the timed region. The transcript
is generated to size rather than pointed at a real session file, so these
numbers are reproducible on any runner instead of tied to one machine's files.

Provenance note: unlike the `subagent` pair above, this one needed no throwaway
commit. The port landed at U12 and the scripts are deleted at U13, so a commit
carrying both the Rust statusline and the three scripts exists on the branch and
could be measured directly. The R37/R38 collision only bites when a single
commit has to do both.

## 7. Decision record (settled design questions — do not re-litigate without new evidence)

### Rendered-value cache key — no change (2026-07-26)

The design resolved cleanly (two-tier key: the raw-level key as tier 1, a rendered-value
key checked after display inputs are computed as tier 2; tier 2 needs no time bucket
because visible countdown labels self-invalidate; threshold notifications are safe on the
miss path because rendered percentages and configured thresholds are both integers, so
every crossing changes the key). It fails on the measured benefit bar:

- A tier-2 hit still pays everything before the render — measured 501 ms of a 538.6 ms
  forced-miss tick — because those stages produce the tier-2 key's inputs.
- The render tail (box assembly, notifications, cache write, emit) is **37.6 ms**: the
  per-hit ceiling, ~7% of tick cost, against a permanent second key tier in three
  scripts whose completeness failure mode is a silently stale display.
- Root cause: the idea was priced against pre-optimization misses (0.7–1.4 s). The git
  consolidation and incremental transcript parse moved that work behind their own caches,
  leaving the rendered-value key nothing expensive to skip.

Reopen condition: a future change that makes the render tail expensive again, or a hard
requirement to eliminate the idle 5 s re-render entirely — which additionally needs a
replacement idle recompute driver for ref-only git changes (`git fetch` touches
`FETCH_HEAD`/`packed-refs`, not `.git/index`, so no existing key probe observes it).

### Cheaper subagent tee — no change (2026-07-26)

Measured (fresh-process medians, 11+ samples): current handler ~266 ms; interpreter floor
~142 ms; raw-tee + .NET-only I/O prototype ~172 ms (−35.5%, the only variant clearing the
pre-registered ≥30% bar); cmdlet-swap-only ~249 ms (−6.9%, byte-identical output).

The bar-clearing variant does not ship, because it fails the bar's contract half:

- **Malformed-tick isolation is lost.** Today a broken payload throws in the JSON parse
  and writes nothing — the last good feed survives. A raw tee writes the garbage over it,
  silently dropping the feed tier for that session until the next good tick.
- **Raw retention feeds `tokenSamples` (an accumulating per-task array) and other
  unfiltered fields into the statusline's output-cache key** (feed content is a key
  input). Unverified tick-to-tick order/field stability risks re-introducing the
  every-tick-miss behaviour the cache work exists to eliminate.

Reopen conditions: a live multi-tick capture confirming raw field/order stability and no
idle-tick key churn, plus a structural guard (trimmed payload starts `{` and ends `}`)
re-measured to confirm the mechanism still clears 30%. The −6.9% cmdlet swap remains a
zero-risk fallback but does not meet the bar on its own.

### Git access — subprocess, not a pure-Rust library (2026-07-27)

The Rust port keeps invoking `git`. The alternative considered was `gix`, which
satisfies the same pure-Rust constraint and benchmarks faster than git itself.

Measured cost of the calls being kept — fresh-process medians, 15 runs, this
repository, git 2.48.1 on the maintainer's Windows machine. Indicative, not an
R38 pair:

| Call | Median |
|---|---|
| `status --porcelain=v2 --branch --show-stash` | 36.5 ms |
| `diff --shortstat HEAD` | 37.4 ms |
| pair | 73.9 ms |

**Process-count delta: none for the git block itself** — 2 subprocesses per
miss, 3 on detached HEAD, 0 on a cache hit, exactly as §6 records for the
scripts. What the port removes is the interpreter around them: the bash tick
falls from 5 execs on a hit and 14 on a miss to 0 and 2–3.

The decision was not made on cost. An in-process reading means reimplementing
git's *configuration* surface — `core.autocrlf` normalisation ahead of
`--shortstat`, `.gitattributes` binary and textconv rules, rename detection,
untracked-directory collapsing. Fixtures are captured on default-config scratch
repos, so divergence in that surface passes CI and then renders a plausible
wrong number on a user's machine, where the exit-0 contract guarantees it never
announces itself. Subprocess `git` cannot diverge from `git` by construction,
and this repo treats performance as tracked rather than gated.

Reopen condition: a post-parity evaluation with the git-state fixtures in hand,
run against a configuration matrix the harness does not have today — `autocrlf`
on and off, a `.gitattributes`-marked binary file, `diff.renames` disabled.
Porcelain parsing is kept as a pure function over text so that evaluation is a
diff rather than a rewrite.

### Incremental transcript parser — deleted in the Rust port (2026-07-27)

The scripts' incremental parse (stored byte offset, head checksum over
`min(4096, size)` bytes, truncation and rewrite detection) exists because a full
rescan of a large transcript costs ~1470 ms in PowerShell. The Rust port does not
inherit that cost, so U9 measured a full parse before porting any of it.

Fresh-process medians, maintainer's machine (Windows 11 26200), release build,
15 runs, largest transcript available locally — 8,406,985 bytes. The plan's
13.4 MB reference transcript no longer exists on this machine, so the row is
smaller than the §6 script rows it is read against:

| Probe | Median |
|---|---|
| Process only (632-byte transcript) | 6.5 ms |
| Full parse, 8.4 MB | 46.9 ms |
| Full parse, 8.4 MB, before search optimization | 98.8 ms |

Against §6's script rows for 13.4 MB — 568 ms for an incremental growth tick and
~1470 ms for a cold full rescan — a full Rust parse is roughly an order of
magnitude cheaper than the incremental path it would be replacing, before
adjusting for the smaller file. The offset, checksum and resume machinery are
therefore deleted rather than ported (R27).

Two things worth keeping from the measurement:

- **Substring search dominated the scan.** Replacing `windows(n).position(..)`
  with a first-byte scan followed by a compare halved the figure, 98.8 ms to
  46.9 ms, with byte-identical results. The first-byte scan vectorizes; the
  window compare does not. This is why the crate needs no search dependency.
- **The token record is not deleted with the parser.** The per-bucket `(+N)`
  deltas are this tick's totals minus the previous tick's, and an unchanged
  transcript re-displays the stored deltas rather than recomputing them to zero.
  That makes the record a render input under R28, not a performance cache. What
  goes is the offset and checksum; what stays is mtime, size, four totals and
  four deltas.

Reopen condition: a transcript large enough that a full parse becomes visible
next to the ~124 ms interpreter floor the migration removes — on this hardware
that is somewhere north of 25 MB.
