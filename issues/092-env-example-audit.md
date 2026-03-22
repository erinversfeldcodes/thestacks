# Issue #092: .env.example Audit

## Summary
Fix variable name mismatches and add missing variables to .env.example.

## Goal
`.env.example` has stale S3_* variables that nothing reads, and is missing several variables that runtime.exs and deploy scripts actually use.

## Scope Check
- 1 file modification
- Documentation only

## Technical Requirements

### Remove (dead variables)
- `S3_BUCKET`, `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION` — runtime.exs uses `R2_*` vars instead

### Add (missing variables)
- `BRAVE_SEARCH_API_KEY` — Brave Search API for source discovery
- `VISION_TOGETHER_API_KEY` — Together AI for LLM features
- `SCRAPER_HMAC_SECRET` — HMAC auth for scraper sidecar (generate with `openssl rand -hex 32`)
- `SCRAPER_SERVICE_URL` — URL of Rust scraper service (default: `http://localhost:8080`)
- `REQUIRE_EMAIL_CONFIRMATION` — Set to `true` to enforce email verification
- `EMAIL_PROVIDER` — Set to `resend` to enable real email delivery
- `RESEND_API_KEY` — API key for Resend.com transactional email
- `RATE_LIMIT_AUTH` — Override default auth rate limit (optional)
- `VISION_MODEL_NAME` — Model name for vision sidecar (if configurable)

### Fix (R2 section)
- Remove duplicate R2 section at bottom of file
- Consolidate into the Object Storage section with correct variable names

## Definition of Done
- [ ] All variables read by runtime.exs are documented in .env.example
- [ ] All variables read by deploy-stack.sh are documented
- [ ] No dead variables remain
- [ ] Each variable has a comment explaining its purpose and how to obtain it

## Agent Assignment
Any (documentation task)
