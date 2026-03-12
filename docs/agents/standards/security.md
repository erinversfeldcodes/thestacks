# The Stacks — Security Standards

## Philosophy

Security is not a feature — it's a property of the system. Every agent must consider security in every change. The security-agent owns the infrastructure, but all agents share the responsibility.

---

## Authentication

### User Auth
- Guardian JWT (HS256), 64-char secret generated with `mix guardian.gen.secret`
- 24h access tokens, 7d refresh tokens (stored in DB, revocable)
- Argon2 password hashing (argon2_elixir)
- First user becomes owner. No public registration in single-user phase.

### Partner Auth
- API key format: `stacks_pk_` + 32-byte random hex
- Stored as Argon2 hash in `partners.api_key_hash`
- Key prefix (first 8 chars) stored for identification
- Shown once on creation, never retrievable
- Rotation invalidates old key immediately

### Service-to-Service
- Core ↔ scraper: Fly.io private networking (`.internal` DNS) — no public endpoint for scraper
- Core ↔ vision service: HMAC-signed requests over public Modal HTTPS (`VISION_HMAC_SECRET` shared secret)
- HMAC-signed requests as defence in depth

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
`Stacks.GDPR.export/1` returns all user data as structured JSON. Served as a downloadable file.

### Right to Erasure
`Stacks.GDPR.delete_user/1` via Ecto.Multi:
1. Delete all op schema rows for the user
2. Anonymise wh schema records (hash user_id, remove PII)
3. Scrub PII from event_log payloads (targeted, not delete)
4. Record the deletion itself in audit_log

### Consent
- Per-use consent with timestamps
- `consent_analytics`, `consent_analytics_at` on users table
- Features gated on consent status via `StacksWeb.Plugs.ConsentCheck`

### Image Retention
- Original uploads deleted after 30 days (Oban scheduled job)
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
- `audit_log`: INSERT-only grant for app role. No UPDATE/DELETE.
- `event_log`: append-only in normal operation. GDPR erasure via targeted payload scrubbing.
- Column-level encryption via Cloak for personal notes, audit metadata.
- No raw SQL from user input. Ecto parameterised queries only.

---

## Security Scanning

| Tool | What | When |
|------|------|------|
| Sobelow | Elixir SAST | Every PR |
| Semgrep | Multi-language SAST + custom AI safety rules | Every PR |
| CodeQL | Deep SAST | Weekly |
| mix deps.audit | Elixir dependency vulnerabilities | Every PR |
| cargo audit | Rust dependency vulnerabilities | Every PR |
| npm audit | Node/Elm tooling vulnerabilities | Every PR |
| Trivy | Container image scanning | Every build |
| Gitleaks | Secret detection | Every PR |
| Checkov | IaC scanning (Dockerfiles, Fly config) | Every PR |
| Hadolint | Dockerfile linting | Every PR |
| OWASP ZAP | DAST | Weekly |
| Nuclei | DAST (template-based) | Weekly |
| cargo-fuzz | Rust fuzzing (TOML parsing, HTML extraction) | Nightly |
| Atheris | Python fuzzing (image input) | Nightly |

---

## Incident Response

If a security issue is found:
1. Create a P0 issue immediately
2. Notify the platform owner
3. If in production: deploy a fix or disable the affected feature via feature flag
4. Post-mortem: what happened, why, how to prevent recurrence
