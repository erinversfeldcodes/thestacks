# Runbook: Rotating Production Secrets

**Severity:** P2 for routine rotation; P1 if rotation is reactive to a suspected leak
**Owner:** Platform operator
**Last reviewed:** 2026-04-18

---

## Scope

Covers rotation of the prod secrets that the `deploy-production.yml` workflow reads from GitHub Secrets and stages onto the `thestacks-core` Fly app. Two classes:

1. **Neon DB credentials** — composed from four component secrets.
2. **Single-value app secrets** — `METRICS_SCRAPE_TOKEN`, `VISION_HMAC_SECRET`, `GUARDIAN_SECRET_KEY`, `SECRET_KEY_BASE`, `CLOAK_KEY`, `SCRAPER_HMAC_SECRET`, `SEARXNG_SECRET_KEY`, `PROD_OWNER_*`, `STACKS_PROBER_*`, `STACKS_APP_DB_PASSWORD`, `STACKS_DBT_DB_PASSWORD`, `LOG_SHIPPER_ACCESS_TOKEN`, `AXIOM_TOKEN`, `R2_*`, external API keys (`RESEND_API_KEY`, `VISION_TOGETHER_API_KEY`, `BRAVE_SEARCH_API_KEY`, `GOOGLE_BOOKS_API_KEY`).

## General order for all rotations

1. Rotate the secret at its source of truth (Neon, Modal, Cloudflare, etc. — OR generate a new random value locally).
2. Update the corresponding value in **GitHub Secrets** (repo → Settings → Secrets and variables → Actions).
3. Trigger `deploy-production.yml` (push or manual dispatch) so `deploy-stack.sh` stages the new value on the Fly app.
4. Verify health post-deploy.

The GitHub Secret is the source of truth for the deploy workflow. Do **not** `fly secrets set` directly on prod — it creates a state divergence between Fly and GH, and the next CI-driven deploy will revert to whatever GH has.

---

## Neon DB password rotation

### Secrets involved
| GH Secret | What it holds |
|---|---|
| `STACKS_PROD_DB_ROLE` | Role name (e.g. `neondb_owner`, `stacks_app`) |
| `STACKS_PROD_DB_PASSWORD` | Raw password — workflow URL-encodes at compose time |
| `STACKS_PROD_DB_HOST` | Endpoint host incl. `-pooler` |
| `STACKS_PROD_DB_NAME` | Database name (usually `neondb`) |

`deploy-production.yml`'s "Compose DATABASE_URL from prod Neon components" step builds `DATABASE_URL` from these four. `deploy-stack.sh` stages the composed URL onto the Fly app.

### Steps

1. **Rotate in Neon** — console → `thestacks` project → Branches → `production` → Roles → select role → Reset password. Copy the new value.

   Or CLI:
   ```bash
   neon roles reset-password <role> --project-id late-cake-59855655 --branch production
   ```

   The old password is invalidated immediately.

2. **Update GitHub Secret** — repo → Settings → Secrets and variables → Actions → `STACKS_PROD_DB_PASSWORD` → Update. Paste the raw password (no URL-encoding).

3. **Trigger deploy** — push a commit or run `deploy-production.yml` manually via the Actions UI.

4. **Verify** — after deploy, confirm `/api/health` returns 200; watch Fly logs for connection errors on the first few seconds post-deploy.

### Rotation window

The old password stops working the moment step 1 completes. The app will hit auth failures on the next connection pool check-out until step 3's new deploy lands (~5–10 minutes).

To minimise the window:
- Have the new password ready in GH before running step 1.
- Trigger the deploy immediately after the Neon rotation.
- Schedule rotations outside peak traffic windows.

### Rotating other Neon components

- **Host change** — Neon endpoint moves (rare; usually platform migrations). Update `STACKS_PROD_DB_HOST` in GH Secrets, deploy. Same flow but no Neon-side action required.
- **Role change** (e.g. moving from `neondb_owner` to least-privilege `stacks_app`) — ensure the new role has grants on all needed schemas first, then update `STACKS_PROD_DB_ROLE`, deploy.
- **Database rename** — rare. Update `STACKS_PROD_DB_NAME`.

---

## Single-value app secrets

### `METRICS_SCRAPE_TOKEN`
Used by `StacksWeb.Plugs.MetricsAuth` to authenticate scrapes of `/internal/metrics`.

1. Generate a new random token: `openssl rand -base64 32`.
2. Update `METRICS_SCRAPE_TOKEN` in GitHub Secrets.
3. Trigger deploy. The SLO gate's scrape step reads from the same secret, so in-flight gate runs after deploy pick up the new value automatically.

### `GUARDIAN_SECRET_KEY`, `SECRET_KEY_BASE`
JWT / session signing keys. Rotating invalidates all existing sessions — users must log back in.

1. Generate: `mix phx.gen.secret` (or `openssl rand -base64 64`).
2. Update GH secret.
3. Trigger deploy.
4. Users see a forced logout. Document this in a release note if public.

### `CLOAK_KEY`
Used by `Cloak.Ecto` for column-level encryption of PII (audit log metadata). Rotating is **destructive** without a prior data migration: old ciphertext cannot be decrypted with the new key.

**Do not rotate casually.** If you must:
1. Add the new key as a secondary cloak cipher alongside the old one (supports both for decryption).
2. Run a re-encrypt task that decrypts existing rows with the old key and re-encrypts with the new.
3. After verifying all rows are re-encrypted, swap primary → new key and remove the old from the cipher list.
4. Then update the GH secret and deploy.

Owner: principle-engineer should review before CLOAK_KEY rotation.

### `VISION_HMAC_SECRET`, `SCRAPER_HMAC_SECRET`
HMAC for signed callbacks between core ↔ vision ↔ scraper. Rotating requires both sides updated simultaneously (one secret shared). Core-before-vision ordering from `docs/runbooks/vision-service-rollback.md` applies.

`deploy-stack.sh` resyncs the `thestacks-vision` Modal secret on every prod deploy via `modal secret create thestacks-vision ... --force`, so `VISION_HMAC_SECRET` lands on Modal in the same workflow run as it lands on Fly core.

1. Generate new secret.
2. Update GH secret.
3. Trigger deploy-production.yml — deploys both Modal (vision, app: `thestacks-vision`) and Fly (core) with the new value.
4. Any in-flight callbacks signed with the old secret will be rejected and Oban-retried — expect a minute of noise.

### `PROD_OWNER_PASSWORD`
The owner account password. Handled at app level, not infrastructure.

1. Update `PROD_OWNER_PASSWORD` in GH Secrets.
2. Trigger deploy — but `Stacks.Release.seed_prod/0` is idempotent and only inserts if the user doesn't exist. **So updating the GH secret alone does not change the owner's password on prod.**
3. Change the password via the app's existing "change password" flow while logged in, OR run a one-off `mix` task via `fly ssh console` that updates the hash.

Rotating `PROD_OWNER_PASSWORD` in GH Secrets is useful for keeping the "if we ever need to re-seed from scratch" value current; it's not how you rotate the live owner's password.

### External API keys (`GOOGLE_BOOKS_API_KEY`, `VISION_TOGETHER_API_KEY`, `BRAVE_SEARCH_API_KEY`, `RESEND_API_KEY`)
Rotate at the provider's console, update the GH secret, trigger deploy. No special ordering. If `RESEND_API_KEY` rotation causes email delivery to break, see `docs/runbooks/email-delivery-failure.md`.

### `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`
Cloudflare R2 credentials for image storage. `R2_ACCOUNT_ID` and `R2_BUCKET_NAME` are also staged by `deploy-stack.sh` but are identifiers, not secrets — only update them if the bucket or account changes.

1. Create new key pair in Cloudflare dashboard (don't delete the old one yet).
2. Update both GH secrets.
3. Trigger deploy.
4. Verify uploads succeed post-deploy (smoke test or synthetic probe).
5. Once verified, revoke the old key pair in Cloudflare.

### `STACKS_APP_DB_PASSWORD`, `STACKS_DBT_DB_PASSWORD`
Passwords for the `stacks_app` and `stacks_dbt` Postgres roles. Used by migrations to (re)create the roles on hosted databases that enforce password strength. Rotate by updating the GH secret and triggering a deploy — the migration is idempotent and resets the password on the next run. Not the same as `STACKS_PROD_DB_PASSWORD`, which is the owner role used by the runtime connection.

### `STACKS_PROBER_EMAIL`, `STACKS_PROBER_PASSWORD`
Credentials for the dedicated prober user seeded by `Stacks.Release.seed_prober/0`. Same caveat as `PROD_OWNER_PASSWORD` — updating the GH secret alone does not change the live password (seed is insert-if-missing). Rotate via the app's change-password flow or a one-off `mix` task.

### `LOG_SHIPPER_ACCESS_TOKEN`, `AXIOM_TOKEN`, `AXIOM_DATASET`
Credentials for the `thestacks-log-shipper` Fly app (Vector → Axiom). Staged on every prod deploy via `deploy-stack.sh`. An empty `LOG_SHIPPER_ACCESS_TOKEN` is graceful — the shipper deploy is skipped with a WARN and logs simply stop persisting until the next deploy with a populated token.

### `SEARXNG_SECRET_KEY`
Request-signing secret for the internal SearXNG Fly app (`thestacks-searxng`). Update GH secret, trigger deploy. SearXNG is in the SLO gate's hot path via `/internal/deps-check`, so verify `/api/health` and dep-check pass post-deploy.

---

## What NOT to rotate via this workflow

- **Fly API tokens** — rotated at Fly's side; set as repo-level GH secret `FLY_API_TOKEN`. Not stored on the Fly app itself.
- **Neon API key** — set as `NEON_STAGING_API_KEY` (scoped to the `thestacks-staging` Neon project). Used only by preview-branch creation; prod deploys never touch Neon branching and don't reference this secret.
- **Modal tokens** — `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`. Stored as GH secrets for workflow use; Modal itself has no matching "app secret" concept.

These rotate independently; update the GH secret and the next workflow run picks them up. No `fly secrets set` involved.

---

## Emergency rotation (suspected leak)

If a secret is known or suspected to be compromised:

1. Rotate at source **immediately** — don't wait for the deploy pipeline.
2. Update GH Secret.
3. Trigger deploy (do not wait for next natural push).
4. Invalidate any dependent sessions (e.g. force-logout on `GUARDIAN_SECRET_KEY`).
5. Audit logs (`audit.audit_log`) for any activity during the compromised window.
6. File a security-incident entry.

## Related

- `.github/workflows/deploy-production.yml` — where the secrets are consumed
- `scripts/deploy-stack.sh` — stages them onto Fly via `fly secrets set` and resyncs the Modal `thestacks-vision` secret
- `docs/deployment/NEON_BRANCH_TOPOLOGY.md` — DB branch model
- `docs/runbooks/neon-outage.md` — DB unavailability (separate from a rotation that broke the credential)
- `docs/runbooks/modal-outage.md` — Modal vision unavailability
- `docs/runbooks/email-delivery-failure.md` — Resend / email path
- `docs/runbooks/vision-service-rollback.md` — core ↔ vision deploy ordering (applies to HMAC rotation)
- `docs/agents/standards/security.md` — general secret-handling standards
