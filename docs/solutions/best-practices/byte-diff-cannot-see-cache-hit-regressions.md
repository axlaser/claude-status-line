---
title: Byte-identical output diffing cannot see cache-hit-rate regressions
date: 2026-07-26
category: best-practices
module: statusline caching
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "A change touches a trust-checked cache read (Test-TrustedFile / sl_trusted_file call sites)"
  - "A change touches output-cache key construction or any of its file-probe inputs"
  - "A benchmark claims to measure the cache-hit path"
tags: [equivalence-testing, output-cache, trust-check, hit-rate, verification]
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

## Guidance

When a change touches a trust-checked cache read, cache-key construction, or any
cache-key input, verify the observed hit/miss *outcome*, not just output bytes:

- A true output-cache hit exits before the cache write, so the cache file's mtime is
  unchanged after the tick. Assert `oc mtime before == after` on a warm run.
- With `STATUSLINE_DEBUG=1`, the log carries an explicit `output cache HIT` line (and,
  post-deferral, the absence of `json parse: OK` on a hit). Assert the expected
  hit/miss/parse pattern per tick, not just the rendered bytes.
- For benchmarks, never label a cell "hit" without one of the checks above — a
  prime-then-measure pattern can silently measure misses.

## Why This Matters

The cache tiers are designed to degrade invisibly: every failure mode (distrusted file,
invalid record, churned key input) falls back to a full re-render with identical output.
That is correct behavior for users and a trap for verification — the whole class of
"cache silently dead" regressions passes any byte-diff matrix. The Get-Acl incident cost
nine days; the benchmark incident produced plausible-looking numbers that misattributed
~90 ms of savings before the hit-detection check exposed them.

## When to Apply

- Any diff touching `Test-TrustedFile`, `Test-WriteOk`, `sl_trusted_file`, `sl_write_ok`,
  or their call sites
- Any diff touching output-cache key construction or its probe inputs (transcript mtime,
  git index mtime, feed freshness/content, learned-map mtime)
- Any benchmark report that separates hit-path from miss-path numbers

## Examples

The harness pattern that caught the false-hit benchmark (PowerShell):

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
