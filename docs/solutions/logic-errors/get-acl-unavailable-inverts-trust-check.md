---
module: statusline
date: 2026-07-25
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "The 'Context window at 70%' sound and toast repeated every ~2 seconds and never stopped"
  - "notified_context_high stayed true on disk while the alert kept re-firing"
  - "Output, git, transcript and per-task subagent caches never hit on Windows"
  - "No trace in any log; every script still exited 0 with no stderr"
root_cause: wrong_api
resolution_type: code_fix
tags:
  - powershell
  - get-acl
  - exception-swallowing
  - fail-direction
  - windows
  - caching
  - notifications
---

# Get-Acl unavailable in the status line child process inverted the temp-file trust check

## Problem

`Test-TrustedFile` in `windows/statusline.ps1` guards every read of a predictable temp file. It called `Get-Acl` to compare the file's owner SID against the current user. That cmdlet is **not available in the child process Claude Code spawns for the status line** — module auto-loading is off there — so the call raised `CommandNotFoundException`, which fell into the function's own outer `catch { return $false }`.

The guard therefore answered "untrusted" for **every file it was ever asked about**, on every refresh, for nine days.

## Symptoms

- Once a session crossed the 70% context threshold, the `context_high` sound and toast fired every ~2 seconds and never stopped.
- The latch file said `{"notified_context_high":true,...}` and was being rewritten every 2s — yet the alert kept firing, which looks impossible.
- All read-side caches were silently dead on Windows: output cache, git cache, transcript cache, per-task subagent caches. The status line was doing a full re-render every tick.
- Nothing surfaced anywhere. Every script still reached `exit 0` and wrote nothing to stderr — the silent-degradation contract worked exactly as designed and hid the defect completely.
- **Unreproducible from outside the process.** Running the identical function body from an interactive shell against the same file returned `True`.

## What Didn't Work

Two wrong diagnoses, both plausible from the evidence, one of them deployed:

1. **Threshold flapping / missing hysteresis.** Theory: the percentage oscillated across 70, so the reset branch re-armed the latch and the next tick re-fired. Disproved by sampling the latch every 1.5s for 15s — it held `true` the entire time.

2. **Torn read from a non-atomic write.** Theory: `WriteAllText` truncates in place, so a concurrent refresh reads an empty file; `ConvertFrom-Json` yields `$null`; `$null -eq $true` is false; the latch reads as "never notified". This was *demonstrably true in isolation* — an empty file really does produce `latch=False`, and the file really was rewritten every tick. A fix was written and deployed. **The alert continued at exactly the same cadence.**

The second failure is the instructive one: the mechanism was real, reproducible in a unit-sized test, and still not the cause. Confirming a mechanism *can* produce the symptom is not the same as confirming it *did*.

**What actually worked: instrumenting the live process.** An unconditional diagnostic appended to the installed script, dumping the guard's inputs on each refresh:

```
trusted=False  usable=True  nsCtx=False  raw={"notified_context_high":true,...}
```

The file existed, was readable, and said `true`. The guard in front of it was lying. A second pass logged the reason directly:

```
psver=5.1  trusted=False  why=[Get-Acl NOT AVAILABLE in this process]
```

Three rounds of reasoning from the outside produced two wrong answers. One round of observing from the inside produced the right one, in minutes.

## Solution

Resolve the owner off the `FileInfo` object instead of via the cmdlet, and tolerate an owner that cannot be determined (`windows/statusline.ps1:197-214`):

```powershell
# Before — one catch-all turns a missing cmdlet into "untrusted"
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
return ((Get-Acl -LiteralPath $path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]) -eq $me)

# After — no module dependency, and an undeterminable owner is not fatal
$owner = $null
try { $owner = $item.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]) } catch {}
if ($null -eq $owner) { return $true }
return ($owner -eq [System.Security.Principal.WindowsIdentity]::GetCurrent().User)
```

`Test-WriteOk` got the same treatment (`windows/statusline.ps1:225`). The reparse-point rejection above both checks is untouched — on a per-user `%TEMP%` that is the load-bearing guard against symlink planting; the owner check is defense-in-depth, which is precisely why it must not be able to fail the whole check closed.

Two pieces of hardening were kept even though they were not the cause: the notify latch now fails closed when the file exists but cannot be read (`windows/statusline.ps1:1110-1126`), and the latch is written atomically via temp-file-then-rename on all three platforms.

**Bash was never affected.** `sl_trusted_file() { [[ -f "$1" && ! -L "$1" && -O "$1" ]]; }` (`macos/statusline.sh:107`, `linux/statusline.sh:107`) uses only shell builtins — there is no module or cmdlet to be missing. The same commit that broke Windows wrote the correct Bash version.

## Why This Works

The bug was never about atomicity or timing. It was a **fail-direction asymmetry between two guards sharing one dependency**, present from the moment they were written:

```powershell
Test-TrustedFile:  try { ... Get-Acl ... } catch { return $false }    # dependency failure => DENY
Test-WriteOk:      try { ... Get-Acl ... } catch { $bad = $false }    # dependency failure => ALLOW
```

`Test-WriteOk` deliberately tolerates a failed ACL read — correct, since it deletes files on a negative. `Test-TrustedFile` funnels the identical failure into a catch-all meaning "untrusted". Same dependency, opposite outcome. Writes kept working while reads never did, which is why the latch was written `true` every tick and read as `false` every tick.

Removing the cmdlet dependency fixes the immediate cause. Making an undeterminable owner non-fatal fixes the class: the guard now degrades to its load-bearing check instead of collapsing.

### Timeline

Both halves landed on the same morning, from a security-hardening pass and its own code-review follow-up:

| Commit | Time | Effect |
|---|---|---|
| `9c25dd7` | 2026-07-16 10:23 | Introduced both guards with the `Get-Acl` dependency and the fail-direction asymmetry. All Windows read-side caches silently dead from here. No visible symptom. |
| `a73076a` | 2026-07-16 10:59 | Moved the notify-state **read** from `Test-Path` to `Test-TrustedFile`, closing a genuine symlink gap — and routing the latch read through the broken guard. This is where the audible symptom began. |
| `51d6349` | 2026-07-25 | Fixed. |

`9c25dd7` and `a73076a` are on `origin/master`. `51d6349` was a local `dev` commit when this was written — if it was squashed or rebased into `master` afterwards that SHA no longer exists, so search for the commit or PR that carried the `GetAccessControl` change instead.

It took nine days to surface because the alert only fires above 70% context, and most sessions never reach it.

## Prevention

- **A guard must state its unavailable-dependency direction explicitly.** "What does this return when the thing it depends on isn't there?" is a design decision, not an accident of where the `catch` sits. Write the answer down next to the guard.
- **Never let a broad `catch` swallow a dependency error inside a trust check.** A catch-all that spans both "the answer is no" and "I couldn't ask the question" collapses two different outcomes into one. Scope the `catch` to the specific check, and handle unavailability separately — `Test-WriteOk` already did this with an inner `catch`, which is why only its sibling broke.
- **Sibling guards over the same dependency must fail the same direction, or document why they differ.** The asymmetry here was defensible in isolation and wrong in combination. If two functions wrap one dependency differently on purpose, say so in a comment — otherwise the next reader assumes it is a bug in whichever one they are looking at.
- **Prefer .NET calls over module-provided cmdlets in scripts that run as spawned child processes.** `$item.GetAccessControl()` needs no module; `Get-Acl` needs `Microsoft.PowerShell.Security` to be loadable. A hook or status line child is not a normal interactive session, and `-NoProfile` is not the only thing that differs.
- **Test guards inside their real execution context.** This bug was 100% reproducible in the status line child process and 0% reproducible from an interactive shell. Any check of the form "does this cmdlet work here" must be answered *here*, not in your terminal.
- **In a codebase with a silent-degradation contract, add a way to see the decision.** `exit 0` and no stderr are correct for a status line and they also guarantee that a wrong decision is invisible. This was only found by temporarily logging the guard's inputs unconditionally. Consider making trust-check outcomes visible under the existing debug flag so the next occurrence takes minutes instead of an instrumentation round.
- **Watch for the follow-up commit that arms a latent defect.** `9c25dd7` created the broken guard; `a73076a` — a code-review fix closing a real finding — is what made it audible. When a review follow-up routes an existing read through a newly added guard, the guard's failure modes are now in scope for that change.
