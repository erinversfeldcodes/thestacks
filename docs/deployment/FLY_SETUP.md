# Fly.io Setup

Provisioning notes for The Stacks' Fly.io apps. The vision service is **not**
on Fly — it runs on Modal (`apps/vision/modal_app.py`); see
`docs/runbooks/modal-outage.md`.

## Apps

| App | Config | Dockerfile | Region |
|-----|--------|------------|--------|
| `thestacks-core` | `deploy/fly.core.toml` | `deploy/Dockerfile.core` | `iad` |
| `thestacks-scraper` | `deploy/fly.scraper.toml` | `deploy/Dockerfile.scraper` | `jnb` |
| `thestacks-searxng` | `deploy/fly.searxng.toml` | `deploy/searxng/Dockerfile` | `iad` |
| `thestacks-log-shipper` | `deploy/fly.log-shipper.toml` | `deploy/log-shipper/Dockerfile` | `iad` |

Scraper sits in `jnb` (Johannesburg) to keep bookshop scraping close to
South African bookshop origins; everything else is `iad` for proximity to
Neon's primary region.

## Required secrets

### `thestacks-core`

| Secret | Source |
|--------|--------|
| `SECRET_KEY_BASE` | `mix phx.gen.secret` |
| `VISION_HMAC_SECRET` | Shared with Modal vision app |
| `CLOAK_KEY` | 32-byte base64 (`openssl rand -base64 32`) |
| `DATABASE_URL` | Neon connection string with `?sslmode=require` appended |

Neon's plain connection URI does not include `sslmode=require`; append it
before setting the secret or `Postgrex` will fail to negotiate TLS.

### Modal vision service (not Fly, listed here for completeness)

| Secret | Notes |
|--------|-------|
| `VISION_HMAC_SECRET` | Must match the core app's value |
| `VISION_TOGETHER_API_KEY` | Together AI key; **must** keep the `VISION_` prefix |

## Deploy commands

```bash
fly deploy --config deploy/fly.core.toml
fly deploy --config deploy/fly.scraper.toml
fly deploy --config deploy/fly.searxng.toml
fly deploy --config deploy/fly.log-shipper.toml
```

Other useful commands: `fly secrets set`, `fly machines list`,
`fly status`, `fly logs`.

For full stack provisioning (Neon branch + Modal + Fly core + searxng +
log-shipper, with health gates between each step), prefer the orchestrated
scripts:

- `scripts/deploy-stack.sh` — full stack deploy. Creates Fly apps
  idempotently, stages secrets, runs `fly deploy`, and waits for
  `[[checks]]` to pass before returning.
- `scripts/deploy-preview.sh` — thin wrapper that calls `deploy-stack.sh`
  with a PR-scoped app name (`stacks-core-pr-<branch>`).
- `scripts/check-slo-gate.sh` — 10-minute post-deploy SLO gate
  (windowed Prometheus deltas + synthetic probes); exit 0 iff every SLI
  passes.

## Cross-references

- `docs/runbooks/manual-rollback.md` — image-only rollback procedure
  (Fly + Modal reverted, Neon left intact).
- `docs/runbooks/neon-outage.md` — Neon Postgres outage response (Fly core
  surfaces the failures).
- `docs/runbooks/modal-outage.md` — vision service outage response.
- `docs/runbooks/bootstrap-prod-environment.md` — first-time prod
  provisioning runbook.
- `docs/deployment/NEON_BRANCH_TOPOLOGY.md` — Neon branch layout that
  feeds `DATABASE_URL` for previews vs prod.
