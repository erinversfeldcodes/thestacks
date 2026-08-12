---
name: finalize-pr
description: Close out a completed feature branch — fill its PR body, move the local issue files it completed into issues/complete/, open a GitHub issue per completed local issue, and wire the PR to close them on merge. Takes the feature BRANCH NAME as input and looks up the PR itself. Use when the user says "finalize the PR", "fill out the PR", "close out this branch", "move the completed issues and open GitHub issues", or after an epic/issue's completion-audit has PASSed and it's ready to ship.
---

# finalize-pr

The Stacks "ship it" step: turn a completed, verified feature branch into a well-documented PR with a
clean issue trail. Runs **after** the work is genuinely done — ideally after `completion-audit` has
PASSed. It does **not** re-verify the work; it packages it.

## Input

The **feature branch name** (e.g. `feat/e2e-112`). Everything else is looked up:

```bash
BRANCH="$1"                      # the only input
gh pr list --head "$BRANCH" --json number,url,title,baseRefName --state open
```

Take the PR number from that lookup — **do not** ask the user for it. If `gh pr list --head` returns
nothing, stop and tell the user no open PR exists for that branch (they may need to push / open one).
If it returns more than one, list them and ask which.

## Preconditions (check, don't assume)

1. **`gh` is authed:** `gh auth status`. If not, stop and ask the user to `gh auth login`.
2. **The branch is the current one or is checked out**, so `git` operations apply to it.
3. **The work is actually complete.** This skill assumes done-ness; if unsure, run `completion-audit`
   first. Do not finalize an epic with unchecked child DoDs or a stale test audit.

## Steps

### 1. Identify the completed local issues

The issues completed on this branch live under `issues/` (not yet `issues/complete/`). Determine which
ones this branch *finished* — typically the epic root + its children whose DoDs are fully checked.

- List candidates: `git diff main...$BRANCH --name-only -- 'issues/*.md'` shows issue files touched.
- For each, a **completed** issue has **zero unchecked DoD boxes**:
  `grep -cE '^- \[ \]' issues/NNN-*.md` → 0 means done; > 0 means still open (a spun-out/not-started
  follow-up — leave it in `issues/`).
- **Never move an issue with unchecked boxes.** Spun-out follow-ups (discovered mid-work, not started)
  stay in `issues/` and are named in the PR's "Follow-ups" section instead.

Confirm the completed set with the user before moving anything, listing what moves and what stays.

### 2. Move completed issues to `issues/complete/`

```bash
git mv issues/NNN-slug.md issues/complete/NNN-slug.md    # one per completed issue
```

The canonical directory is **`issues/complete/`** (note: `complete`, not `completed`). Verify it exists
(`ls -d issues/complete`).

### 3. ⚠️ Open a GitHub issue per completed local issue — MIND THE NUMBER NAMESPACE

**The local `issues/NNN-*.md` number is NOT the GitHub issue number.** They are separate namespaces —
GitHub assigns its own sequential numbers, and a GitHub issue with the same number as your local one
almost certainly already exists and is *unrelated*. Writing `Closes #NNN` with a **local** number will
close the **wrong** GitHub issue.

So: create each GitHub issue, capture the **new** number GitHub returns, and build an explicit
local→GitHub map.

```bash
url=$(gh issue create --repo <owner>/<repo> \
        --title "<concise title from the issue's H1>" \
        --body "<summary paragraph> Local: \`issues/complete/NNN-slug.md\`.")
gh_num=$(echo "$url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
echo "local #NNN -> GH #$gh_num"
```

- Title: derive from the issue file's `# ` heading, trimmed to something readable.
- Body: a short human summary of what the issue delivered + a pointer to the local file. Do not dump
  the whole issue.
- Keep the printed `local #NNN -> GH #<num>` map — the PR body needs the **GitHub** numbers.

### 4. Run the staff shadow review

Invoke the **`staff-review` skill** over this branch (`git diff main...$BRANCH`). It is the Staff
Engineer's advisory design/taste lens (see `docs/agents/staff-engineer-agent.md`) — it does not
re-verify the work and cannot block this skill.

- **LGTM / LGTM WITH NOTES:** proceed. Carry the condensed "Staff review" block (verdict +
  finding one-liners) into the PR body in step 5. Offer to file 🟧 findings as follow-up issues;
  any filed go in the PR's "Follow-ups" section.
- **DESIGN CONCERNS (⛔ findings):** present them to the user before proceeding. The user decides:
  fix now (stop finalizing, return after the fix), or file-and-ship (create the follow-up issues,
  note the override in the PR body, continue). Record whichever they choose.

### 5. Fill the PR body and wire close-on-merge

Write a real PR description (what it delivers, how it was validated, follow-ups), then a `Closes`
section using the **GitHub** numbers from step 3 — one `Closes #<gh_num>` per line (GitHub only
auto-closes on merge to the default branch, which the PR's `baseRefName` should confirm is `main`).

Write the body to a file and apply it (avoids shell-quoting hell):

```bash
gh pr edit <pr_number> --repo <owner>/<repo> \
   --title "<epic/issue title>" \
   --body-file <path-to-body.md>
```

PR body should include:
- **What this delivers** — the substance, not a commit list.
- **Validation** — `just verify` / `just ci` results, E2E counts, completion-audit verdict, with real
  numbers. If Modal-dependent E2E was skipped, say so and why (vision-clean diff).
- **Staff review** — the condensed block from step 4: verdict + finding one-liners (and any
  override note if the user shipped past DESIGN CONCERNS).
- **Follow-ups (tracked, not in this PR)** — the spun-out issues left in `issues/` from step 1,
  plus any 🟧/⛔ staff-review findings filed as follow-up issues in step 4.
- **Closes** — `Closes #<gh_num>` lines.
- End with the Claude Code generation trailer.

### 6. Commit the moves — do NOT push

```bash
git add -A issues/
git commit -m "chore: move completed <slug> issues to issues/complete"
```

**Do not `git push`.** Pushing is the user's call in this project (standing rule). After committing,
tell the user the branch has an unpushed commit and they need to push it for the PR to reflect the
moved files:

```bash
git log --oneline origin/$BRANCH..$BRANCH    # show what's unpushed
```

## Output

Report back:
- The PR (number + URL) you filled.
- The staff-review verdict (and any follow-up issues it filed, or the override decision).
- The local→GitHub issue map (so the user can see which GH issue each local one became).
- What moved to `issues/complete/` and what stayed (with why — unchecked boxes / spun-out).
- The unpushed commit, and that **the user must push** for the PR to update.

## Guardrails

- **Number namespace:** never use a local issue number in `Closes #` — always the GitHub number from
  the create step. This is the easiest way to close the wrong issue.
- **Don't move open work:** an issue with any `- [ ]` box stays in `issues/`.
- **Don't push.** Commit only.
- **Don't invent validation:** the PR body's numbers must come from real runs. If you didn't run it,
  don't claim it.
- **History-rewrite awareness:** if the branch's history was rewritten locally (e.g. subject-only
  cleanup) and already force-pushed, confirm `origin/$BRANCH` matches local HEAD before relying on the
  PR reflecting local commits.
