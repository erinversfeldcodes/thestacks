# Deployment Setup

Top-level index for provisioning The Stacks. This page orients you to the
stack and the bootstrap order; the per-platform details live in the linked
sub-docs and runbooks — don't duplicate them here.

For local development, see [`DEV_SETUP.md`](DEV_SETUP.md). This page is for
deploying to real infrastructure.

## Stack overview

| Component | Platform | Config |
|-----------|----------|--------|
| Core API (Phoenix) | Fly.io (`thestacks-core`, `iad`) | `deploy/fly.core.toml` |
| Bookshop scraper | Fly.io (`thestacks-scraper`, `jnb`) | `deploy/fly.scraper.toml` |
| Search proxy | Fly.io (`thestacks-searxng`, `iad`) | `deploy/fly.searxng.toml` |
| Log shipper | Fly.io (`thestacks-log-shipper`, `iad`) | `deploy/fly.log-shipper.toml` |
| Vision sidecar | Modal (`thestacks-vision`) | `apps/vision/modal_app.py` |
| Database | Neon Postgres (two projects) | `docs/deployment/NEON_BRANCH_TOPOLOGY.md` |
| Object storage | Cloudflare R2 | `R2_*` secrets on `thestacks-core` |

Vision deliberately runs on Modal, not Fly — see
`docs/runbooks/modal-outage.md`. Neon uses two separate projects
(`thestacks` for production, `thestacks-staging` for staging + previews)
with zero copy-on-write lineage between them.

## Prerequisites

Accounts:

- Fly.io organisation with billing enabled.
- Modal workspace with billing enabled.
- Neon account with two projects: `thestacks` and `thestacks-staging`.
- Cloudflare account with R2 enabled and a bucket for image storage.

CLI tools (installed via `setup.sh` / `nix develop`, or manually):

- `flyctl` — Fly.io deploys and secret management.
- `modal` — Modal vision app deploys (`pip install modal`).
- `neonctl` — Neon branch management.
- `psql` (PostgreSQL 16) — direct DB access for verification.
- `buf` — proto generation, required before the first Elixir build.

## Secret stores

| Store | Set with | Contains |
|-------|----------|----------|
| Fly secrets (`thestacks-core`) | `fly secrets set -a thestacks-core …` | `SECRET_KEY_BASE`, `CLOAK_KEY`, `DATABASE_URL`, `VISION_HMAC_SECRET`, `R2_*`, external API keys |
| Fly secrets (other apps) | `fly secrets set -a <app> …` | App-specific (`SCRAPER_HMAC_SECRET` for scraper, etc.) |
| Modal secret `thestacks-vision` | `modal secret create thestacks-vision …` | `VISION_HMAC_SECRET` (mirrors core), `VISION_TOGETHER_API_KEY` |

`VISION_HMAC_SECRET` must match between the core Fly app and the Modal
`thestacks-vision` secret, or HMAC auth between them fails. The
`VISION_` prefix on `VISION_TOGETHER_API_KEY` is load-bearing — Modal
filters env vars by prefix.

See [`FLY_SETUP.md`](FLY_SETUP.md) for the full secret matrix and
`docs/runbooks/secrets-rotation.md` for rotation procedures.

## Bootstrap order

For a brand-new environment, provision in this order:

1. **Neon projects.** Create `thestacks` and `thestacks-staging`. Apply
   migrations to the primary branch of each (`mix ecto.migrate` against
   the appropriate `DATABASE_URL`). Seed `thestacks-staging`'s `staging`
   branch via `apps/core/priv/repo/seeds.exs`.
2. **Fly apps.** Create `thestacks-core`, `thestacks-scraper`,
   `thestacks-searxng`, `thestacks-log-shipper`. Stage their secrets
   (compose `DATABASE_URL` from the Neon connection string with
   `?sslmode=require` appended).
3. **Modal vision.** Create the `thestacks-vision` secret, then
   `modal deploy apps/vision/modal_app.py`.
4. **Deploy the Fly stack.** Run `scripts/deploy-stack.sh` to deploy
   core + scraper + searxng + log-shipper with health gates between
   steps.

For the first-time bootstrap of a production environment specifically,
follow `docs/runbooks/bootstrap-prod-environment.md` — it covers the
`main-<sha>` tag prerequisite that the auto-rollback step in
`deploy-production.yml` depends on.

## Setup scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Local dev bootstrap (Homebrew, mise, venvs, DB). Not used for deploy. |
| `scripts/deploy-stack.sh` | Full stack deploy: Neon branch + Modal + Fly apps with health gates. |
| `scripts/deploy-preview.sh` | PR-scoped preview wrapper around `deploy-stack.sh`. |
| `scripts/check-slo-gate.sh` | 10-minute post-deploy SLO gate. |
| `scripts/cleanup-preview.sh` | Destroys preview Fly apps and Neon preview branch. |

## Cross-references

- [`DEV_SETUP.md`](DEV_SETUP.md) — local dev environment (not deployment).
- [`FLY_SETUP.md`](FLY_SETUP.md) — Fly apps, secrets matrix, deploy commands.
- [`NEON_BRANCH_TOPOLOGY.md`](NEON_BRANCH_TOPOLOGY.md) — two-project Neon
  layout and preview branch lifecycle.
- `docs/runbooks/bootstrap-prod-environment.md` — first-time prod
  provisioning checklist.
- `docs/runbooks/secrets-rotation.md` — secret rotation flow across
  Fly, Modal, Neon, and Cloudflare.
- `docs/runbooks/manual-rollback.md`, `modal-outage.md`, `neon-outage.md`
  — incident response.
