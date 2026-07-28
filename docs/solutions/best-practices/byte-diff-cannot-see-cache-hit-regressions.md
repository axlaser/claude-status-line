---
title: Byte-identical output diffing cannot see cache-hit-rate regressions
date: 2026-07-26
updated: 2026-07-28
category: best-practices
module: state guards and freshness bounds
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "A change touches a trust-checked state read (state::read_trusted / write_guarded call sites)"
  - "A change touches the transcript (mtime, size) rescan skip, RECORD_VERSION, or the git cache TTL"
  - "A change touches tasks-feed freshness or the subagent done-linger stamp"
  - "A benchmark claims to measure a cache-hit or skip path"
tags: [equivalence-testing, state-guards, trust-check, hit-rate, verification]
---

# Byte-identical output diffing cannot see cache-hit-rate regressions

## Context

The repo's performance rules (docs/performance.md §4) verify hot-path changes by
byte-diffing rendered output across a state matrix. During the 2026-07-26 optimization
work, two incidents showed the blind spot in that bar: a benchmark's "hit" samples were
silently all misses (the harness was churning a cache-key input), and the earlier
Get-Acl trust-check inversion (see
[get-acl-unavailable-inverts-trust-check](../logic-errors/get-acl-unavailable-inverts-trust-check.md))
ran for nine days undetected. In both cases every rendered byte was correct — only the
*hit rate* was wrong, because a distrusted or invalidated cache just causes a silent
full re-render that produces identical output.

Both incidents predate the Rust port, and the output cache they centred on is gone —
deleted deliberately along with the interpreter startup cost it existed to hide. The
blind spot is not gone. Every surviving skip in the binary has the same shape: it
degrades to a correct-but-slower recompute, so no byte diff can see it fail.

## Guidance

When a change touches a trust-checked state read, a freshness or staleness bound, or any
input those decisions key on, verify the observed *outcome*, not just output bytes:

- **The transcript rescan skip.** A true skip never re-reads the file. Under
  `STATUSLINE_DEBUG=1` the log carries `transcript: unchanged, scan skipped`. Assert that
  line appears on the second of two identical ticks — not merely that both ticks render
  the same bytes, which they will either way.
- **The git 5s TTL.** A hit reuses `statusline-git-<session>.txt` without rewriting it,
  so its mtime is unchanged across a tick inside the window. Assert
  `mtime before == mtime after`.
- **Guarded state writes.** `state::write_guarded` returns `Written` / `SkippedHostile` /
  `Failed`, and any non-`Written` outcome degrades silently — the record never lands, so
  the *next* tick recomputes from scratch, forever. `WriteOutcome` is `#[must_use]` and
  every call site logs a non-`Written` result; assert the outcome or the log line, never
  the rendered row.
- **Feed freshness and the done-linger.** Both decide whether a row appears at all, from
  a timestamp. A broken bound renders plausibly right until the boundary. Assert the
  fresh/stale and linger/expired outcomes *at* the boundary, in both directions.
- **For benchmarks**, never label a cell "hit" without one of the checks above — a
  prime-then-measure pattern can silently measure misses.

## Why This Matters

These tiers are designed to degrade invisibly: every failure mode (distrusted file,
invalid record, churned key input, unwritable temp dir) falls back to a full recompute
with identical output. That is correct behavior for users and a trap for verification —
the whole class of "skip silently dead" regressions passes any byte-diff matrix. The
Get-Acl incident cost nine days; the benchmark incident produced plausible-looking
numbers that misattributed ~90 ms of savings before the hit-detection check exposed them.

## When to Apply

- Any diff touching `state::read_trusted`, `state::write_guarded`, `state::is_hostile`,
  `platform::trusted_owners`, `platform::file_owner`, or their call sites
- Any diff touching the transcript `(mtime, size)` skip, `TokenRecord` / `RECORD_VERSION`,
  or the git cache TTL and the `git-refresh` hook that invalidates it
- Any diff touching tasks-feed freshness or the subagent done-linger stamp
- Any benchmark report that separates hit-path from miss-path numbers

## Examples

Assert the skip actually happened. This form is portable — it reads the debug log rather
than a platform-specific `stat` dialect:

```bash
STATUSLINE_DEBUG=1 claude-statusline statusline < payload.json > /dev/null
STATUSLINE_DEBUG=1 claude-statusline statusline < payload.json > /dev/null
grep -c 'transcript: unchanged, scan skipped' ~/.claude/statusline-debug.log
# Expect 1 (the second tick skipped). 0 means every tick re-reads the whole
# transcript while rendering identically -- the regression a byte diff cannot see.
```

The original harness pattern that caught the false-hit benchmark, kept for the record.
It probed the output cache, which no longer exists; the equivalent today is the git
cache file above.

```powershell
$m1 = (Get-Item $ocFile).LastWriteTimeUtc.Ticks
& cmd /c "... statusline.ps1 < payload.json > out.txt"
$m2 = (Get-Item $ocFile).LastWriteTimeUtc.Ticks
if ($m1 -ne $m2) { "NOT a hit -- the tick re-rendered and rewrote the cache" }
```

## Related

- [get-acl-unavailable-inverts-trust-check](../logic-errors/get-acl-unavailable-inverts-trust-check.md)
  — the nine-day incident this practice would have caught
- docs/performance.md §4 — the byte-diff equivalence matrix this practice complements
