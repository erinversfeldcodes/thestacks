# Neon Branch Topology

The Stacks runs on two Neon projects with zero copy-on-write lineage between them.
Previews never clone production — structurally, not just by policy.

## Two-project architecture

```
Neon project: thestacks                 Neon project: thestacks-staging
────────────────────────────            ─────────────────────────────────
production (primary)                    staging (primary)
  real user data                          migrations + dev fixture set
  migrations only — no fixtures           owner + sample books + placements
  read/write only by the prod Fly app     parent for every preview/<pr>
                                        └── preview/<pr>
                                              ephemeral, one per PR
                                              destroyed by cleanup-preview.sh
```

- **`thestacks` (production project)** — holds a single `production` branch. The
  production Fly app (`thestacks-core`) talks to it exclusively via a
  `DATABASE_URL` composed from `STACKS_PROD_DB_*` secrets in
  `deploy-production.yml`. No preview or staging workload ever touches this
  project.
- **`thestacks-staging` (staging project)** — holds the `staging` branch plus
  every `preview/<pr>` branch. `staging` contains migrations applied from
  scratch + `apps/core/priv/repo/seeds.exs` output. Previews are copy-on-write
  clones of `staging` at branch-creation time, so they inherit the full dev
  fixture set with no per-preview seed step.

## Why two projects?

1. **GDPR and blast radius.** Previews are visible to reviewers, other
   contributors, and anyone with CI log access. Copying production user data
   into ephemeral review environments would be a straight compliance
   violation. Two projects mean a preview DB URL leak gives no path into
   production.
2. **Operator safety.** A Neon admin running `branches reset --parent` on
   `staging` cannot pull production data — they're in a different project,
   with different credentials. The only way to move prod data here is
   deliberate.
3. **Platform-bug isolation.** Any future Neon platform issue in the
   copy-on-write lineage can't surface prod data in a preview that was
   branched from `staging`, because `staging` has no such lineage to prod.

## Branch lifecycle

| Branch | Project | Created by | Contains | Destroyed |
|--------|---------|-----------|----------|-----------|
| `production` | `thestacks` | Neon project setup (one-time) | Migrations + real user data | Never |
| `staging` | `thestacks-staging` | One-time bootstrap (`mix ecto.migrate` + `seeds.exs`) | Migrations + dev fixtures | Never (maintained manually) |
| `preview/<pr>` | `thestacks-staging` | `deploy-stack.sh` (preview mode) | Copy-on-write clone of `staging` at branch time | `cleanup-preview.sh` on PR close, or manually |

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `NEON_STAGING_PROJECT_ID` | — | Neon project ID for `thestacks-staging` (GH secret for CI, local `.env` for dev) |
| `NEON_STAGING_API_KEY` | — | Neon API key scoped to the staging project |
| `NEON_PARENT_BRANCH` | `staging` | Branch inside `thestacks-staging` that previews are cloned from |

Production deploys call `scripts/deploy-stack.sh --production`, which clears
`NEON_STAGING_API_KEY` internally so the Neon-branch-creation block in the script
is a no-op. The production Fly app gets its `DATABASE_URL` from the component
secrets composed in `.github/workflows/deploy-production.yml` (`STACKS_PROD_DB_ROLE`
/ `PASSWORD` / `HOST` / `NAME`). See `docs/runbooks/secrets-rotation.md` for the
composition and rotation flow.

## Cleanup

`scripts/cleanup-preview.sh` destroys both the Fly preview apps and the Neon
preview branch. It runs automatically from the `deploy-preview` CI job's
`Cleanup preview stack` step on every job completion (`if: always()`).

If a CI run is terminated abnormally and a preview branch is orphaned, list and
delete manually with:

```bash
neonctl branches list --project-id "$NEON_STAGING_PROJECT_ID" \
  --api-key "$NEON_STAGING_API_KEY"
neonctl branches delete <branch-id> \
  --project-id "$NEON_STAGING_PROJECT_ID" \
  --api-key "$NEON_STAGING_API_KEY"
```

Everything under `preview/*` older than the oldest open PR is safe to remove.

## Related

- `scripts/deploy-stack.sh` — preview-branch creation
- `scripts/cleanup-preview.sh` — preview-branch destruction on PR close
- `docs/runbooks/secrets-rotation.md` — rotating prod DB credentials
- `docs/runbooks/neon-outage.md` — what to do when Neon is down
