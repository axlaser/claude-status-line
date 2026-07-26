---
title: Isolate USERPROFILE and TEMP when benchmarking the statusline
date: 2026-07-26
category: workflow-issues
module: statusline benchmarking harness
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - "Running statusline equivalence or benchmark harnesses on a machine with live Claude Code sessions"
  - "Any harness fixture whose model/context-window pair differs from the live session's"
tags: [benchmarking, harness-isolation, learned-map, mtime-churn, output-cache]
---

# Isolate USERPROFILE and TEMP when benchmarking the statusline

## Context

During the 2026-07-26 performance work, benchmark "hit" cells kept measuring miss-path
cost. Instrumenting the cache-key components showed the learned model-window map's mtime
(`~/.claude/statusline-model-windows.json`, a key input) changing on every run: the
harness fixture claimed a model→window pair (`Fable 5` → 200000) that differed from the
live session's real pair (→ 1000000), so every fixture run rewrote the user's real map
and every live statusline tick wrote it back. The two fought indefinitely; every "warm"
sample was a miss, and the harness was corrupting real user state.

## Guidance

Every harness invocation of a statusline script must isolate all three environment
roots, and warm the profile before sampling:

- `TEMP`/`TMP` (bash: `TMPDIR`) → a per-variant scratch dir, so cache files never touch
  the real temp or another variant's.
- `USERPROFILE` (bash: `HOME`) → the same scratch dir with a pre-created `.claude`
  subdir, so the learned map and debug log are harness-local.
- Run one **setup tick** before any measured or compared tick: the first run *creates*
  the learned map, which changes a cache-key input, so the first "warm" run after a cold
  run in a fresh profile is always a miss. Prime twice when benchmarking.

## Why This Matters

The production script deliberately writes the learned map only when the pair changes, so
real sessions reach a stable no-write steady state. A harness with a divergent fixture
never reaches that state against the real profile — it perpetually invalidates its own
cache key *and* plants wrong values in the user's real learned map (self-healing only
because live ticks write theirs back). Results are silently mislabeled: miss-path cost
reported as hit-path.

## When to Apply

- Every `run-matrix` / benchmark / spot-check invocation in the statusline harness
  (`~/.claude/statusline-perf-harness/` already encodes this pattern in its runners)
- Any new harness script that spawns a statusline process

## Examples

The isolation pattern used by the harness runners:

```powershell
$cmd = "set `"TEMP=$t`" && set `"TMP=$t`" && set `"USERPROFILE=$t`" && " +
       "powershell -NoProfile -File `"$script`" < `"$fixture`" > `"$out`""
New-Item -ItemType Directory -Force "$t\.claude" | Out-Null   # profile root
# setup tick, then (for benchmarks) a second prime, then measure
```

## Related

- [byte-diff-cannot-see-cache-hit-regressions](../best-practices/byte-diff-cannot-see-cache-hit-regressions.md)
  — how the mislabeled hit samples were detected
