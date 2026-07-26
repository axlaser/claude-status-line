---
title: gawk under a UTF-8 locale zeroes extraction on astral-plane characters
date: 2026-07-26
category: logic-errors
module: statusline transcript scan (bash)
problem_type: logic_error
component: tooling
symptoms:
  - "Token counts silently omit assistant messages whose line contains an emoji"
  - "Old-vs-new equivalence run diverged only on emoji-bearing growth ticks (base under-counted)"
root_cause: logic_error
resolution_type: code_fix
severity: medium
tags: [gawk, locale, utf-8, astral-plane, emoji, lc-all-c, extraction]
---

# gawk under a UTF-8 locale zeroes extraction on astral-plane characters

## Problem

The pre-optimization bash transcript scan ran its greedy-regex token extraction
(`sub(/.*"input_tokens"[[:space:]]*:.../, ...)`) in gawk with the inherited UTF-8
locale. On any JSONL line containing a 4-byte UTF-8 codepoint (an astral-plane
character — emoji like 🎉) *before* the usage fields, the extraction corrupted and the
line's token contribution was silently counted as zero.

## Symptoms

- Token totals under-count on transcripts where assistant replies contain emoji; no
  error, no stderr — just smaller numbers.
- Found by the combined pre-plan-vs-final equivalence run (2026-07-26): growth ticks
  whose appended fixture line was `"完成了 — done 🎉"` diverged, with the *old* script
  reporting `(+0)` deltas and the new script the true counts.

## What Didn't Work

- Suspecting the harness: a `BINMODE=3` awk wrapper (CRLF handling) made no difference —
  both plain and wrapped invocations of the same gawk 5.0 binary reproduce it.
- Narrowing to multibyte generally: CJK characters and em-dashes alone do **not**
  trigger it; specifically the 4-byte (astral-plane) codepoint does.

## Solution

Run byte-oriented awk text extraction under `LC_ALL=C`. The current scripts do this at
every transcript-scan invocation (introduced with the incremental transcript parser —
commit `09849e2`, "Parse only appended transcript bytes on re-render", unpushed at the
time of writing — for byte-accurate offsets; the extraction fix came along with it):

```bash
LC_ALL=C awk ' ... index()/substr() extraction ... ' "$transcript"
```

Under `LC_ALL=C`, gawk treats input as bytes: `length()` counts bytes (which the
incremental offset math requires) and regex/`index()` matching is byte-clean regardless
of codepoint width.

## Why This Works

Under a UTF-8 locale, gawk operates on characters and its regex engine must decode the
input; gawk 5.0's handling of astral-plane codepoints corrupts the greedy `sub()`
rewrite on such lines, mangling the residue the extraction then reads. `LC_ALL=C`
sidesteps decoding entirely — for a byte-format task (JSONL field scraping, byte
offsets), byte semantics are the correct semantics.

Verified against GNU gawk 5.0 (Git Bash). Real macOS/BSD awk handles multibyte text
differently and was not independently verified (the repo's known no-native-macOS test
limit); the `LC_ALL=C` pin is correct for it regardless, since byte semantics are wanted
either way.

## Prevention

- Treat any awk invocation that scrapes fields or counts lengths from raw file bytes as
  requiring `LC_ALL=C`; a UTF-8 locale is only appropriate when character semantics are
  actually wanted (e.g., visible-width measurement).
- Equivalence fixtures for text-scanning code must include an astral-plane character,
  not just CJK/latin-extended — the failure class is specific to 4-byte codepoints.

## Related Issues

- docs/performance.md §4 — records this as the single accepted rendered-output
  divergence of the 2026-07-26 optimization work (the fix direction: new totals are
  correct where old ones under-counted)
