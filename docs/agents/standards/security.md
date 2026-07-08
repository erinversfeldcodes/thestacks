# The Stacks — Security Standards

## Philosophy

Security is not a feature — it's a property of the system. Every agent must consider security in every change. The security-agent owns the infrastructure, but all agents share the responsibility.

---

## Authentication

### User Auth
- Guardian JWT (HS256), 64-char secret generated with `mix guardian.gen.secret`
- 24h access tokens, 7d refresh tokens (stored in DB, revocable)
- Argon2 password hashing (argon2_elixir)
- Argon2 operations serialised through `Stacks.Accounts.ArgonPool` (NimblePool) so concurrent hashes/verifies cannot OOM the instance (Issue #166)
- Per-account login lockout in `AuthController.login` after N failed attempts (`failed_login_count` / `locked_until` on `op.users`); per-IP rate limit remains as defence-in-depth (Issue #161)
- TOTP MFA enforced on owner-only routes via `StacksWeb.Plugs.RequireMFA` (admin, source admin, metrics); secrets stored encrypted in `Stacks.MFA.UserMFA`
- First user becomes owner. No public registration in single-user phase.

### Partner Auth
- API key format: `stacks_pk_` + 32-byte random hex
- Stored as Argon2 hash in `partners.api_key_hash`
- Key prefix (first 8 chars) stored for identification
- Shown once on creation, never retrievable
- Rotation invalidates old key immediately

### Service-to-Service
- Core ↔ scraper: Fly.io private networking (`.internal` DNS) — no public endpoint for scraper. HMAC verification in `apps/scraper/src/auth.rs`.
- Core ↔ vision service: HMAC-signed requests over public Modal HTTPS (`VISION_HMAC_SECRET` shared secret). Signing in `apps/core/lib/stacks/ai/client.ex`, verification in `apps/vision/app/services/hmac_auth.py`.
- Signature scheme: `<unix_ts>.<HMAC-SHA256(secret, "<ts>.<METHOD>.<path>")>` — timestamp clamped to prevent replay.

---

## GDPR Compliance

### Data Classification
| Tier | Examples | Encryption | Retention |
|------|----------|-----------|-----------|
| Public | Book metadata, ISBN, cover URL | None | Indefinite |
| Personal | Shelf placements, notes, reading history | Cloak (column-level) | Until deletion request |
| Sensitive | Password hash, KYC result, payment refs | Cloak + DB role isolation | Minimum necessary |
| External Personal | Reddit usernames in reviews | Pseudonymised in analytics | Source retention policy |

### Right to Export
`Stacks.GDPR.Export` returns all user data as structured JSON. Served as a downloadable file via `POST /api/gdpr/export`.

### Right to Erasure
`Stacks.GDPR.Deletion` via `DELETE /api/gdpr/account`:
1. Delete all op schema rows for the user
2. Anonymise wh schema records (hash user_id, remove PII)
3. Scrub PII from event_log payloads (targeted, not delete)
4. Record the deletion itself in audit_log

### Consent
- Per-use consent with timestamps (`Stacks.GDPR.Consent`, `POST /api/gdpr/consent`)
- `consent_analytics`, `consent_analytics_at` on users table
- Features gated on consent status via `StacksWeb.Plugs.ConsentCheck`

### Image Retention
- Original uploads deleted after 30 days (Oban scheduled job in `Stacks.GDPR.ImageRetention`)
- Only thumbnails retained permanently
- Tracked in `uploaded_images.expires_at`

---

## AI Safety

### Core Rule: Never Trust Model Output
Vision model output is **data**, never **instructions**. Always validate externally:
- ISBNs: verify against Open Library / Google Books
- URLs: validate against original source data
- TOML configs: schema-validate before loading
- Text: check for PII before storing

### Budget Controls
GenServer tracks daily and monthly spend:
- 80% warning logged
- 100% hard stop — jobs snoozed until next period
- Manual override available for owner

### Prompt Injection Defence
- Image text extraction: treat as untrusted string input
- Never interpolate extracted text into LLM prompts without sanitisation
- Log all extraction results for audit

### Model Version Pinning
- Model ID pinned in config, not hardcoded
- Model upgrades are explicit: update config, run test suite against known-good fixtures, verify results
- Feature flag kill-switch for AI features

---

## Input Validation

### API Boundaries (external input)
- All request bodies validated against Protobuf-generated JSON schemas
- File uploads: magic byte verification, EXIF stripping, image reprocessing
- Request size limits: 10MB per image, 30MB total, 1MB per partner request
- ISBN checksum validation before any database lookup

### Internal Boundaries (between services)
- Ecto changesets validate all database writes
- Pattern matching on expected shapes in event handlers
- Oban workers validate job args on insertion

### Partner-Specific
- Text blocklist for descriptions (configurable)
- No phone numbers in description fields (structured fields only)
- URL domain validation against known-bad list
- Event dates must be in the future
- Prices must be positive integers

---

## Rate Limiting

| Tier | Limit | Scope | Implementation |
|------|-------|-------|---------------|
| Global | 1000/min | Per IP | GenServer sliding window |
| Auth endpoints | 5/min | Per IP | Token bucket |
| Upload | 10/min | Per user | Token bucket |
| Partner API | 100/min, 10k/day | Per API key | Sliding window + daily counter |
| Vision service (Modal) | Budget-controlled | Global | GenServer with cost tracking |

---

## Security Headers

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), camera=(), microphone=()
Content-Security-Policy: default-src 'self'; script-src 'self'; ...
```

Elm does NOT require `unsafe-eval`. Never add it.

---

## Database Security

- Separate roles: `stacks_app` (CRUD on op, SELECT on wh, INSERT on audit), `stacks_dbt` (SELECT on op, CRUD on wh), `stacks_readonly`
- Row-level security policies (defence in depth) plus application-layer `Stacks.Visibility` enforcement — see [ADR-006](../../decisions/006-rls-plus-application-visibility.md)
- `audit_log` (`op.audit_log`, written via `Stacks.Audit`): INSERT-only grant for app role. No UPDATE/DELETE.
- `event_log`: append-only in normal operation. GDPR erasure via targeted payload scrubbing.
- Column-level encryption via Cloak for personal notes, audit metadata.
- No raw SQL from user input. Ecto parameterised queries only.

---

## Secrets Management

- Production secrets: Fly.io secrets (`fly secrets set ...`) per app (`core`, `vision`, `scraper`).
- Modal vision service: Modal secret `thestacks-vision` (read via `VISION_*` prefixed env vars).
- Local development: `.env` (gitignored) populated from `.env.example` (committed). `set -a && source .env && set +a` to export.
- Required core secrets: `SECRET_KEY_BASE`, `VISION_HMAC_SECRET`, `CLOAK_KEY`, `DATABASE_URL`.
- Required vision secrets: `VISION_HMAC_SECRET`, `VISION_TOGETHER_API_KEY`.
- Never commit secrets. Gitleaks and TruffleHog run in CI on every PR.

---

## Security Scanning

| Tool | What | When |
|------|------|------|
| Sobelow | Elixir SAST | Every PR (Stop hook + CI) |
| Semgrep | Multi-language SAST | Every PR |
| CodeQL | Deep SAST (`.github/workflows/codeql.yml`) | Weekly (Mon 04:00 UTC) |
| mix deps.audit | Elixir dependency vulnerabilities | Every PR |
| cargo audit | Rust dependency vulnerabilities | Every PR |
| Gitleaks | Secret detection | Every PR |
| TruffleHog | Secret detection (verified) | Every PR |
| Hadolint | Dockerfile linting | Every PR |
| Checkov | IaC scanning (Dockerfiles, Fly config) | Every PR |
| Trivy | Container image vulnerability scanning | Every build |
| Dockle | Container image best-practices linting | Every build |
| Syft + Grype | SBOM + vulnerability scan (fails on high, fixed only) | Every PR |
| OWASP ZAP baseline | DAST against deployed preview | Per deploy (advisory) |

---

## Incident Response

If a security issue is found:
1. Create a P0 issue immediately
2. Notify the platform owner
3. If in production: deploy a fix or disable the affected feature via feature flag
4. Post-mortem: what happened, why, how to prevent recurrence

---

## See Also

- [`docs/agents/security-agent.md`](../security-agent.md) — security specialist agent
- [ADR-006: RLS plus application-layer visibility](../../decisions/006-rls-plus-application-visibility.md)
- Issue #161 — per-account login lockout
- Issue #166 — Argon2 NimblePool concurrency safety
