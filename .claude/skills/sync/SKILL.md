---
name: sync
description: >
  Fetch the latest upstream branch and merge it into the current branch, in
  the claude-status-line repo — feature branches sync from `dev`, and `dev`
  itself syncs from `master`. Stages the merge, walks through any conflicts
  interactively, then hands off the final commit for the user to run (SSH
  commit signing means Claude can't create it). Use whenever the user says
  "sync", "pull dev", "pull master", "update branch", "merge dev", "merge
  master", "get latest", or anything about bringing upstream changes into
  their working branch — even if they don't say the word "skill".
---

# /sync — Merge Upstream into Current Branch

Fetch the latest upstream branch from origin and merge it into the current branch, walking through any conflicts one file at a time. Because this repo has SSH commit signing enabled and Claude cannot access the signing key (same constraint as the `commit` skill), Claude stages the entire merge and hands the final `git commit` to the user to run themselves.

## Branch model

This repo uses a two-tier flow: feature branches merge into `dev`, and `dev` periodically merges into `master`. This skill picks the sync source automatically from the current branch:

- On a feature branch (anything that isn't `dev`/`master`) → source is `dev`.
- On `dev` → source is `master` (pulling in anything that landed on `master` directly, e.g. a hotfix).
- On `master` → nothing to sync into — stop.

Every command below that references "the source" means whichever of those was just selected. Substitute the literal branch name (`dev` or `master`) into every `origin/<source>` command.

## Step 1 — Pre-flight checks

```bash
git status && git branch --show-current && git stash list
```

- **Dirty working tree?** Warn and suggest the `commit` skill or a stash first. Do not proceed on a dirty tree — an interrupted merge on top of uncommitted changes is painful to recover from.
- **Already on `master`?** Nothing to sync into — stop.
- **Detached HEAD?** `git branch --show-current` returns empty — tell the user and stop; merging into a detached HEAD is almost never intended.

**Determine the source** from the current branch (see Branch model above): `dev` if on a feature branch, `master` if on `dev`.

## Step 2 — Fetch and check for new commits

```bash
git fetch origin <source>
```

If the fetch fails (network, expired auth), report it and stop — don't fall back to a stale local branch.

```bash
git log --oneline HEAD..origin/<source>
```

If this is empty, tell the user "Already up to date with `<source>` — nothing to merge." and stop. Do not run `git merge`.

## Step 3 — Stage the merge (no commit)

```bash
git merge origin/<source> --no-commit
```

`--no-commit` is the key difference from a normal sync: it stages the merge (or surfaces conflicts) without creating the merge commit, so Claude never touches the signing key. Everything through "ready to commit" happens here; only the final commit is left for the user.

## Step 4 — Handle the result

### Clean merge (no conflicts)

Everything is staged. Skip to Step 5.

### Conflicts

```bash
git diff --name-only --diff-filter=U
```

Tell the user how many files conflict.

**Bulk option** (3+ conflicting files): offer via AskUserQuestion before the per-file walk-through:
- **Claude resolves all** — resolve every file automatically, then show a summary table for review
- **Walk through each file** — proceed one at a time below

Per file:
- Read the file and show the `<<<<<<<`/`=======`/`>>>>>>>` sections
- Explain what each side changed and why they conflict — for this repo that's usually the same statusline/install/notify/git-refresh script edited on both branches, or a README section
- Ask via AskUserQuestion:
  - **Keep ours** — `git checkout --ours <file> && git add <file>`
  - **Keep theirs** — `git checkout --theirs <file> && git add <file>`
  - **Claude resolves** — read both sides, edit to a clean merge preserving both contributions, remove conflict markers, `git add` it, and explain what was kept
  - **Let me handle it** — skip; the user resolves manually

`git checkout --ours`/`--theirs` and `git add` don't touch the signing key, so Claude runs these directly.

**Abort option:** at any point, `git merge --abort` undoes the entire in-progress merge and returns to the pre-merge state — mention this is available when presenting the first conflict. Confirm before running it.

## Step 5 — Verify the staged state

1. **No leftover conflict markers** — Grep for `<<<<<<<` across the working tree (glob `*.{sh,ps1,md,json}`) to confirm nothing was left half-resolved.
2. **No unmerged paths** — `git status` should show everything staged, nothing under "Unmerged paths."
3. **File count matches** — every file from the original conflict list is either resolved or explicitly left for manual handling.

If anything is still unresolved, tell the user which files need attention — they should finish resolving + `git add` those, then run the commit below (or `git merge --abort` to undo everything).

**Cross-platform / rule check:** if the merge touched `macos/`, `linux/`, or `windows/` scripts, remind the user to eyeball the merged result against CLAUDE.md's Cross-Platform Parity and Silent Degradation rules before committing — a merge can silently reconcile two working versions into a broken one.

## Step 6 — Hand off the final commit

Everything is staged; only the commit itself needs the user, since it requires the SSH signing key:

```bash
git commit --no-edit
```

Present this as a single-line, paste-safe command (no heredoc needed — it's accepting the default merge message). Tell the user: once they run it, the branch is synced with `<source>`.

## Step 7 — Offer to push

Once the user confirms the commit ran (`git log -1` will show a merge commit with `origin/<source>` as one parent), and if the branch tracks a remote, ask via AskUserQuestion:
- **Push now** — `git push`
- **Skip** — push later

## Edge cases

| Situation | Action |
|-----------|--------|
| Dirty working tree | Warn; suggest `commit` skill or stash first; don't proceed |
| On a feature branch | Source is `dev` |
| On `dev` | Source is `master` |
| Already on `master` | Nothing to sync into — stop |
| Detached HEAD | Not on a branch — stop |
| Fetch fails | Report the error; don't merge stale local branch |
| Already up to date | Nothing to merge — stop |
| 3+ conflicting files | Offer bulk resolve vs. per-file walk-through |
| User wants to bail mid-merge | `git merge --abort`, confirm first |
| Some files left unresolved | List them; user finishes `git add` + the commit, or aborts |
| Merge touches multiple platforms | Remind to check cross-platform parity before committing |
