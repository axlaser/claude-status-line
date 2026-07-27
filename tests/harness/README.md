# Fixture-capture harness

Drives the **current** scripts and records what each one observably does, so the
Rust port has something to be equivalent to after the scripts are deleted
(R30, R31, R33; KTD9, KTD10).

Everything here is a development tool. The silent-degradation and no-`exit`
contracts in `CLAUDE.md` govern the runtime scripts and the shipped binary —
they do not apply to the harness, and must not. A capture that cannot be trusted
has to fail loudly, because a harness that degrades silently writes a plausible
fixture that everything downstream then treats as truth.

```
capture.sh      macOS and Linux driver (bash 4+, jq, git)
capture.ps1     Windows driver (PowerShell 5.1+, git) — its functional twin
measure.sh      macOS and Linux paired measurement (bash 5+, jq, git)
measure.ps1     Windows paired measurement — its functional twin
cases.json      the case table: what to capture, with what inputs
states.json     the docs/performance.md §4 git-state matrix, as data
payloads/       pinned stdin payloads
configs/        pinned notify-config.json inputs (R44)
inputs/         pinned state files a case supplies
shims/          recording stand-ins for the helpers a component invokes
```

Both drivers read the same `cases.json` and `states.json`. A case is defined
once and captured on all three platforms — the duplication this migration exists
to delete does not get to reappear in the harness.

## Running it

```bash
tests/harness/capture.sh --list
tests/harness/capture.sh --component git-refresh
tests/harness/capture.sh --at 5d474a0        # regenerate a historical commit's fixtures
tests/harness/capture.sh --verify            # capture twice, require byte-identical output
```

```powershell
.\tests\harness\capture.ps1 -List
.\tests\harness\capture.ps1 -Component git-refresh
.\tests\harness\capture.ps1 -At 5d474a0
.\tests\harness\capture.ps1 -Verify
```

macOS and Linux capture runs on CI via `.github/workflows/capture-fixtures.yml`.
Windows capture runs on the maintainer's machine (KTD9) — the Windows script
tree is the one with no hosted equivalent of a real developer environment.

## What a capture guarantees

**Isolation.** `HOME`/`USERPROFILE` and `TMPDIR`/`TEMP` are redirected into a
throwaway root for every case, so a capture cannot read or write the real
profile and no case can see another's leftovers.

**A verified cache miss, in both directions.** The isolated temp root starts
empty, so no output cache can exist before the run. A case that renders must
leave one behind; a case marked `expect_render: false` must not. Byte-diffing
alone cannot tell a full render from a served cache or from an early exit —
all three produce the same bytes, which is exactly how the trust-check inversion
in `docs/solutions/logic-errors/get-acl-unavailable-inverts-trust-check.md` ran
nine days undetected.

**A recorded source commit.** Every fixture records the commit its scripts came
from. Capturing a dirty tree is refused without `--allow-dirty`, because the
recorded commit would not describe what actually ran and nothing downstream
could tell.

**No machine-local paths.** Captured output has every isolated path replaced by
a placeholder, and a capture still containing the real home path is refused
rather than written. `CLAUDE.md` forbids committing a personal absolute path,
and a fixture is a committed file.

**Deterministic git.** Identity, both dates, the branch name, and the
line-ending config are pinned in `states.json`. The detached-HEAD state renders
a short commit hash, so a fixture is only reproducible if the hash is.

## Pinning time against scripts that have no clock

R30 requires every case to pin its time source. The scripts read the real wall
clock and there is no injection point in a shell script, so the harness pins the
*outcome* instead: an intended modification time is materialised as an offset
from capture time, and recorded as an offset from the case's pinned `clock`.

Replaying in Rust pins the clock to `clock` and each state file's mtime to
`clock + mtime_offset`, which reproduces the same freshness and staleness
decisions deterministically. This is what KTD6's `Clock` trait — covering
filesystem mtimes as well as wall-clock reads — exists to make possible.

## Paired measurement (R38)

`measure.sh` and `measure.ps1` produce the end-to-end fresh-process medians R38
requires before a component's scripts are deleted — one number for the script,
one for the binary, taken on the same host with the runs interleaved.

```bash
tests/harness/measure.sh --component subagent --runs 11 --json out.json
```

```powershell
.\tests\harness\measure.ps1 -Component subagent -Runs 11 -Json out.json
```

`docs/performance.md` §3 governs the method and both drivers implement it
literally: one fresh process per probe, a median of at least seven runs, an
isolated `HOME`/`USERPROFILE` and `TMPDIR`/`TEMP`, and `STATUSLINE_DEBUG`
cleared so one variant is not charged for a log append the other skips.

Interleaving is the part that is easy to skip and expensive to get wrong. A
machine that gets busier halfway through a run would charge the whole drift to
whichever variant was measured second, and the result would look exactly like a
finding.

Both drivers **prove each variant does its work before timing anything**. A
probe that silently no-opped — a missing `jq`, a changed payload contract —
would otherwise be reported as a spectacular speed-up.

macOS and Linux pairs come from `.github/workflows/measure.yml`, one job per
platform so both halves of a pair share a runner, with the runner label and
image version recorded beside the numbers (R38, R41). Windows pairs are measured
on the maintainer's machine, for the same reason KTD9 keeps Windows capture off
CI.

## Observables (R31)

| Component | Observable | How it is captured |
|---|---|---|
| `statusline` | rendered bytes | stdout |
| `subagent` | the exact bytes written to the tasks feed | the feed file; stdout must stay empty |
| `git-refresh` | the exact set of paths deleted | the isolated temp root, diffed before and after |
| `notify` | the command and arguments invoked | the PATH shims |

The `git-refresh` observable is the whole temp-root diff rather than a probe of
the two expected names. That is the point: a session id that escaped
sanitisation would delete something else, and only a full diff can show it.

## Shims

`shims/record.sh` is one body installed under every name that needs
intercepting — `afplay`, `paplay`, `terminal-notifier`, `notify-send`, and the
isolated `HOME`'s `notify.sh`. Five near-identical stubs would be the same
duplication problem in miniature, and a shim that drifted from its siblings
would silently change what a fixture means.

Each records one line per invocation into `$STATUSLINE_CAPTURE_FILE`, with
arguments backslash-escaped so a newline or tab inside one cannot forge a record
boundary. The status line backgrounds its notification spawn and `notify`
backgrounds its sound helper, so both drivers wait for the capture file to stop
growing rather than sleeping a fixed amount and hoping.

On Windows the spawn is intercepted twice: `powershell.cmd` on `PATH` (the
status line spawns `Start-Process -FilePath 'powershell'`, which resolves
through `PATH`) and `record.ps1` installed at the isolated `HOME`'s
`.claude\notify.ps1` (the script addresses its own notifier by path, which
`PATH` cannot intercept).

## Known gaps

**Windows `notify` delivery has no external observable.** It is entirely
in-process — `System.Media.SoundPlayer`, `SystemSounds`, and the BurntToast
module — so it spawns nothing a `PATH` shim can see. Both `notify` cases carry
`platforms: ["macos", "linux"]` and are skipped with a printed reason on
Windows rather than stored as empty fixtures, because an empty golden file is
worse than a missing one: everything downstream then asserts against nothing.
**U7 owns choosing the Windows observable.**

**Reproducibility is per environment, not across machines.** The status line
renders a truncated working directory, so the length of the temp root reaches
the rendered bytes. Within one environment that length is constant and captures
are byte-identical; a different machine or a changed runner image can shift it.
Each platform's fixtures are captured in one place — CI for macOS and Linux, the
maintainer's machine for Windows — so this is a constraint to know about, not a
failure mode in normal use.
