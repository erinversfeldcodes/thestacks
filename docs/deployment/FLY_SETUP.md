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

## Real email on a preview (opt-in)

By default a PR preview stack does **not** send real email. Swoosh runs the
local adapter (`Swoosh.Adapters.Local`, configured in
`apps/core/config/config.exs`), which captures messages in-process instead of
delivering them. This keeps ordinary CI runs deterministic and free of any
external dependency — the E2E suite exercises email flows through a
deterministic DB-token path, not a real inbox.

To validate **real Resend delivery** on a preview before merge — proving the
production email path actually sends — opt the PR in with a label:

1. Add the **`preview-real-email`** label to the PR.
2. Re-run the CI workflow (or push a commit). Applying a label does not by
   itself re-trigger CI: the `pull_request` trigger only fires on
   `opened`/`synchronize`/`reopened`, so the label must be present the next
   time the `deploy-preview` job runs.

When the label is present, the `deploy-preview` job in `.github/workflows/ci.yml`
exports the `RESEND_API_KEY` **repository/organization secret** into
`deploy-stack.sh`, which stages it together with `EMAIL_PROVIDER=resend` as Fly
secrets on the preview core app. `config/runtime.exs` then swaps the mailer to
`Swoosh.Adapters.Resend` and the preview sends live email.

Requirements and guarantees:

- The **`RESEND_API_KEY` secret must exist** in the repository/organization
  secret store. It is never hardcoded in any script, workflow, or config — CI
  reads it from `${{ secrets.RESEND_API_KEY }}` only when the label is set,
  otherwise the value resolves to an empty string.
- **Default is OFF.** Without the label the exported value is empty,
  `deploy-stack.sh`'s `${RESEND_API_KEY:+...}` expansion is a no-op, and the
  preview keeps the local (non-sending) adapter.
- Production is unaffected: `deploy-production.yml` always sets
  `RESEND_API_KEY`, so prod always sends via Resend regardless of any label.

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
