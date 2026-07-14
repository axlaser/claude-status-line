---
name: pr
description: >
  Create a pull request from the current branch for claude-status-line, into
  the right base for this repo's two-tier flow — feature branches target
  `dev`, and `dev` itself targets `master` as a release PR. Analyzes the new
  commits, drafts a PR title and a Summary/Test-plan body matching this repo's
  existing PR style, previews it for approval, then creates it via the `gh`
  CLI. Use whenever the user says "pr", "pull request", "open a pr", "create
  pr", "ship it", "merge into dev", "merge into master", "raise a pr", or
  anything about getting the current branch merged — even if they don't say
  the word "skill".
---

# /pr — Create Pull Request

Analyze the current branch's changes relative to its base branch, draft a PR title and body, preview for approval, and open the PR on GitHub.

## Branch model

Work happens on feature branches (`feat/...`, or anything that isn't `dev`/`master`), which PR into **`dev`**. `dev` is the integration branch; periodically a **release PR** merges `dev` into **`master`**. This skill picks the base automatically from the current branch — no need to ask which one:

- On a feature branch → base is `dev`.
- On `dev` → base is `master` (this is the release PR).
- On `master` → nothing to PR — stop.

Every command below that references "the base" means whichever of those was just selected. Substitute the literal branch name (`dev` or `master`) into every `origin/<base>` / `--base <base>` command.

## Why this exists

Past PRs in this repo (before the `dev` branch existed) used a body of just `## Summary` + `## Test plan` — no separate "Changes" section, no conventional-commit-style title enforcement. This skill keeps that convention regardless of which base it's targeting. It also bakes in the two checks this project's CLAUDE.md calls out explicitly: cross-platform parity and a sensitive-content scan — this is a tool that runs on every user's machine, so a hardcoded personal path or leaked credential is a real risk, not a hypothetical one.

There's no CI configured in this repo and no automated test suite (CLAUDE.md: "No test framework. Manual testing required.") — so unlike a gate that runs pytest/tsc/eslint, this skill produces a **manual** test-plan checklist and doesn't run or wait on anything automated, unless `.github/workflows` shows up later (Step 7).

## Step 1 — Pre-flight checks

Verify the GitHub CLI is available and authenticated:

```bash
gh --version && gh auth status
```

- If `gh` is not installed, tell the user to install it (`winget install --id GitHub.cli` on Windows, `brew install gh` on macOS/Linux) and stop.
- If `gh` is installed but not authenticated, tell the user to run `gh auth login` and stop.

**Determine the base** from the current branch (see Branch model above):

```bash
git branch --show-current
```

- Current branch is `master` → tell the user there's nothing to PR and stop.
- Current branch is `dev` → base = `master`.
- Anything else → base = `dev`.

Then gather branch state in one call (use `origin/<base>`, never a local branch, which can be stale):

```bash
git fetch origin <base> && git status --short && git log --oneline origin/<base>..HEAD && git diff --stat origin/<base>..HEAD
```

Handle these conditions before going further:

- **No commits ahead?** If `origin/<base>..HEAD` is empty, there's nothing to merge — tell the user and stop.
- **Uncommitted changes?** Warn that they won't be in the PR; suggest running the `commit` skill first to commit them.
- **Existing PR for this branch?**
  ```bash
  gh pr list --head "$(git branch --show-current)" --json number,title,url,state --jq '.[]'
  ```
  If an **open** PR exists, show its number/title/URL and ask via AskUserQuestion:
    - **Update description** — re-analyze and `gh pr edit <number> --title "..." --body "..."`
    - **View it** — print the URL and stop
    - **Create new anyway** — proceed (rare)
- **Behind the base?** Check:
  ```bash
  git log --oneline HEAD..origin/<base>
  ```
  If the base has moved on, ask via AskUserQuestion rather than syncing silently — finishing a sync may require a manual `git commit` (see the `sync` skill), which doesn't fit cleanly inside this flow:
    - **Sync first (recommended)** — stop here and invoke the `sync` skill, then re-run this skill once the branch is current
    - **Proceed anyway** — open the PR as-is; GitHub will flag any real conflicts on the PR page
- **Not pushed / behind upstream?** Note that `git push` will be needed in Step 6:
  ```bash
  git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "no upstream yet"
  ```

## Step 2 — Analyze the changes

```bash
git log --oneline origin/<base>..HEAD
git diff --stat origin/<base>..HEAD
```

Group changes by platform — `macos/`, `linux/`, `windows/`, plus `assets/`, `README.md`, `CLAUDE.md` for anything else. Watch for what this repo's CLAUDE.md calls out:

- **Cross-platform parity:** if the diff touches `macos/` or `linux/` without a matching `windows/` change (or vice versa), note it in the preview — don't block, just flag, since a platform-specific fix can be intentional.
- **`exit` added to `install.*`/`uninstall.*`:** these scripts run via `irm | iex` on Windows and must never `exit` the user's shell session. Flag any new occurrence.
- **Silent degradation:** `statusline.*`, `notify.*`, `git-refresh.*` must always reach `exit 0` and never write to stderr. Flag any new code path that could break this.

**Sensitive-content scan (blocking).** Inspect the diff:

```bash
git diff origin/<base>..HEAD | grep -nE "\.env|SECRET|PRIVATE KEY|BEGIN .*PRIVATE|password\s*=|api[_-]?key|token\s*="
```

- Secrets/credentials, private key blocks, hardcoded API keys or tokens.
- A hardcoded absolute personal path (`/Users/<name>/...`, `C:\Users\<name>\...`) instead of `$HOME`/`~`/`$env:USERPROFILE` — this tool runs on other people's machines, so that's a real bug, not just a leak risk.

If found, warn prominently and require explicit acknowledgment before creating the PR.

## Step 3 — Draft the PR

**Title** — match this repo's actual style (`gh pr list`/`git log` history): a short, plain imperative sentence, no forced `type(scope):` prefix (e.g. "Add sound and visual toast notifications", "Fix 9 code review findings across all platforms"). Under 70 characters. For a `dev` → `master` release PR covering several feature merges, summarize the release as a whole rather than listing every commit title.

**Body** — this repo's merged PRs all use exactly this shape; match it rather than adding sections it doesn't use:

```markdown
## Summary
- 2-4 bullets: the high-level what and why, calling out which platform(s) are affected

## Test plan
- [ ] Manual checks specific to what changed (see below)
```

**Test plan guidance** — pull items from CLAUDE.md's "What to verify after changes" list, scoped to the actual diff. Common ones:
- `- [ ] Box renders without broken alignment or trailing characters`
- `- [ ] Colors display correctly (green/yellow/red thresholds)`
- `- [ ] No output to stderr`
- `- [ ] Exit 0 on empty, malformed, or missing JSON input`
- `- [ ] Git status row handles detached HEAD, no-repo, and fresh-clone states`
- `- [ ] Tested on <platform(s)> — note if the others were only verified by inspection`
- `- [ ] Installer re-run preserves existing config` (if install/uninstall scripts changed)

Leave every box unchecked (`- [ ]`) — Claude hasn't run these manually, so it can't claim they passed. The user checks off what they've actually verified, either in the preview edit pass or after merging.

## Step 4 — Verify before presenting

1. **Title length** — count characters, must be under 70.
2. **File coverage** — every changed file should be represented in the Summary or explicitly noted (binary, generated, lock file).
3. **Re-scan for sensitive content** — re-run the Step 2 grep; don't let a finding slip through.

## Step 5 — Preview and confirm

Show the user:

- **Branch:** `current-branch` → `<base>`
- **Commits:** N
- **Files changed:** N
- **Proposed PR:** title (code block) and full body (fenced code block)

Then AskUserQuestion:
1. **Create PR** — push and create it exactly as shown (assigned to the user via `@me`)
2. **Create as draft** — same, but `--draft`
3. **Edit** — describe changes, re-preview

Do NOT create the PR until the user approves.

## Step 6 — Create the PR

`git push` and `gh pr create` don't touch commit signing — pushing and opening a PR don't create new commits, so Claude runs these directly once approved.

1. Push if needed:
   ```bash
   git push -u origin "$(git branch --show-current)"
   ```
2. Create the PR against `<base>`, assigned to the user, using a heredoc so markdown survives:
   ```bash
   gh pr create --base <base> --assignee @me --title "the title" --body "$(cat <<'EOF'
   ## Summary
   - ...

   ## Test plan
   - [ ] ...
   EOF
   )"
   ```
   Add `--draft` if that was chosen. No `Co-Authored-By` / "Generated with Claude Code" footer — this repo's history doesn't use AI attribution (same convention as the `commit` skill).
3. Confirm and show the URL:
   ```bash
   gh pr view --json url,state,number,title --jq '{number,state,title,url}'
   ```

## Step 7 — CI (only if configured)

```bash
ls .github/workflows 2>/dev/null
```

This repo currently has no `.github/workflows` — if that's still true, report "No CI configured in this repo — nothing to wait on" and stop.

If workflows exist (e.g. added later), watch them instead of leaving the PR's status unknown:
```bash
sleep 8
gh pr checks <number> --watch --interval 20
```
Report pass/fail. On failure, run `gh pr checks <number>` and `gh run view --job <id> --log-failed` to surface the concrete error, then ask whether to fix now or leave the PR open red.

## Edge cases

| Situation | Action |
|-----------|--------|
| `gh` not installed | Tell the user to install it, stop |
| `gh` not authenticated | Tell the user to run `gh auth login`, stop |
| On `master` | Nothing to PR — stop |
| On `dev` | Base is `master` — this is a release PR |
| Any other branch | Base is `dev` |
| No commits ahead of the base | Nothing to merge — stop |
| Branch already has an open PR | Offer: update description / view / create new |
| Uncommitted changes | Warn; suggest the `commit` skill first |
| Base ahead of branch | Ask: sync first (via `sync` skill) or proceed anyway |
| Sensitive content in diff | Block; list files; require explicit acknowledgment |
| Cross-platform parity gap | Flag in the preview, don't block — may be intentional |
| No `.github/workflows` | Report "no CI configured", stop after Step 6 |
| No remote / upstream | `git push -u origin <branch>`; if no `origin` at all, ask for the URL first |
