# Runbook: Bootstrap Production Environment

**Severity:** P2 (one-time bootstrap, planned)
**Owner:** Platform operator
**Last reviewed:** 2026-05-20

---

## When to use this runbook

A new prod environment is being provisioned for the first time, e.g.:

- A second-region mirror (`thestacks-core-eu`).
- A sacrificial pre-prod environment that exercises the real
  `deploy-production.yml` workflow against a separate Fly app.
- Disaster recovery: a fresh prod stack rebuilt from scratch after the
  previous one was destroyed.

You need this runbook when there are no `main-<sha>` git tags in the
repo yet (or none for this environment's branch). Without at least one
`main-*` tag, the `record-prev-state` step in `deploy-production.yml`
resolves `MODAL_PREV_COMMIT` to an empty string, and the first
auto-rollback on the new environment silently skips the Modal vision
leg by design.

If the environment already has prior successful deploys (and therefore
prior `main-<sha>` tags), you do not need this runbook.

---

## Prerequisites

Verify each of these before running the bootstrap one-liner:

| Item | Verification |
|------|--------------|
| Fly app exists | `flyctl apps list \| grep <new-app-name>` returns a row |
| Neon project provisioned | Console shows the project; `NEON_PROJECT_ID` and `NEON_API_KEY` are added as repo secrets |
| Fly secrets staged | `flyctl secrets list -a <new-app-name>` shows `SECRET_KEY_BASE`, `CLOAK_KEY`, `DATABASE_URL`, `VISION_HMAC_SECRET`, `VISION_SERVICE_URL` |
| Modal secrets staged | `modal secret list` shows `VISION_HMAC_SECRET` configured under the target `MODAL_APP_NAME` (default `thestacks-vision`) |
| `MODAL_APP_NAME` reserved | If using a non-default Modal namespace, the env var is set in the workflow input or repo variable |
| Cloak key matches | The `CLOAK_KEY` on Fly matches the one used to encrypt rows in the Neon project (mismatched keys break decryption) |

If any item is missing, finish provisioning before continuing.

---

## The bootstrap one-liner

From a local checkout of `main`:

```bash
git tag main-bootstrap "$(git rev-parse main^)"
git push origin main-bootstrap
```

What this does: seeds a single `main-*` tag pointing at `HEAD~1`, so
that the next time `deploy-production.yml` runs, the line

```sh
git tag --list 'main-*' --sort=-committerdate | head -1
```

returns a real SHA (the bootstrap tag) for `MODAL_PREV_COMMIT` rather
than an empty string.

The tag points at `HEAD~1`, not `HEAD`, because the first deploy is
going to deploy `HEAD`. The bootstrap tag is the *previous* target —
the SHA that an auto-rollback would revert *to* — not the current one.

---

## Verification

After pushing the tag, confirm the workflow can resolve it:

1. **Dry-resolve locally.** From the same checkout:
   ```bash
   git tag --list 'main-*' --sort=-committerdate | head -1
   ```
   should print `main-bootstrap` (the tag name). `git rev-parse
   main-bootstrap^{commit}` should print the SHA of `main^`. If
   `head -1` prints nothing, the tag wasn't pushed.

2. **Trigger a workflow_dispatch on `deploy-production.yml`** with the
   `target_app` input pointed at the new environment's Fly app.
   Inspect the workflow log in the GitHub Actions UI. In the
   `record-prev-state` step, look for the line:

   ```
   prev modal commit: <sha>
   ```

   It should print a non-empty SHA matching the bootstrap tag's
   commit. An empty value means the tag wasn't visible to the
   workflow (check that `actions/checkout@v4` was invoked with
   `fetch-depth: 0`, already set in the existing workflow — this
   pulls all tags along with the full history).

3. **Confirm the rollback composite is wired.** The
   `.github/actions/rollback-production` step should appear in the workflow
   summary. If the SLO gate passes, the composite never fires; if the
   gate fails, the composite runs and the resolved `MODAL_PREV_COMMIT`
   is what it reverts the vision service to.

---

## What the first auto-rollback looks like

The first deploy that fails the SLO gate fires the rollback composite
against the bootstrap tag's SHA. Concretely:

- **Fly core:** reverted to the bootstrap-tagged commit's image
  (`flyctl releases rollback <id>`).
- **Modal vision:** redeployed at the bootstrap-tagged SHA. Modal's
  `modal deploy` is idempotent w.r.t. revisioning, so deploying an
  identical-or-near-identical image is safe.
- **Neon DB:** restored from the LSN captured pre-migrate, creating a
  `pre-rollback-<sha>-<timestamp>` preserved branch (Issue #137).
  This is the standard Neon rollback path; the bootstrap tag does not
  change it.

After the first successful deploy stamps a real `main-<sha>` tag (via
`tag-main.yml`), subsequent rollbacks resolve `MODAL_PREV_COMMIT` from
that real tag rather than the bootstrap. The bootstrap tag stops
mattering after the first successful deploy.

---

## Cleanup

After the first successful deploy stamps a real `main-<sha>` tag,
`main-bootstrap` is no longer the most-recent tag in the
`committerdate`-sorted listing. It stops affecting `record-prev-state`
without any further action.

The tag itself can stay in the repo (it's cheap — annotated tags are
~200 bytes each) or be deleted:

```bash
git push origin :main-bootstrap     # delete remote tag
git tag -d main-bootstrap           # delete local tag
```

Keep it if you expect to need a clean "deploy from a known-bootstrap
state" pointer; delete it otherwise. There is no operational reason to
keep it after the first real `main-<sha>` tag lands.

---

## Cross-references

- [`manual-rollback.md`](manual-rollback.md) — operator-initiated rollback (image-only by design).
- [`migration-recovery.md`](migration-recovery.md) — restoring from a `pre-rollback-*` Neon branch when the rollback itself was wrong.
- [`vision-service-rollback.md`](vision-service-rollback.md) — Modal-only rollback path (without touching Fly or Neon).
- Issue #137 — original rollback composite implementation; section "Bootstrap edge case (Modal target)" cross-links here.
- Issue #162 — scheduled cleanup of `pre-rollback-*` Neon branches (the safety net created by every auto-rollback).
