# Issue #063: Final Deployment + Integration Test

## Summary
Deploy all services to production, configure all external providers, run the full Phase 1 integration test, and complete remaining Issues #012 (Playwright E2E) and #025 (vision benchmark).

## User Stories
All Phase 1 stories — this is the integration verification.

## Goal
The complete platform is deployed, all external services are configured, and every Phase 1 user story can be exercised end-to-end in a production-like environment.

## Technical Requirements

**Deployment:**
- Fly.io: core app, Rust scraper (private networking)
- Modal: vision service with `/extract`, `/classify`, `/associate`
- SearXNG: self-hosted instance on Fly.io for discovery fallback
- Neon PostgreSQL: production branch with RLS enabled
- Resend/Postmark: email delivery configured with verified domain
- Stitch Money: payment webhook configured (sandbox or production)
- Pargo: shipping API configured
- KYC provider: age verification configured; `REQUIRE_KYC=true`
- `REQUIRE_EMAIL_CONFIRMATION=true`

**Configuration verification:**
- All env vars from `.env.example` have production values in Fly.io secrets
- HMAC secrets match between core and vision service
- Webhook endpoints reachable from Stitch Money and Pargo
- Email delivery: send test email, verify receipt
- KYC: test registration with age verification flow

**Issue #012 — Playwright E2E Smoke Tests:**
- 15 browser-level smoke tests as specified in the issue
- `upload.spec.ts`, `bookshelf.spec.ts`, `search.spec.ts`, `navigation.spec.ts`
- CI integration: `just test-e2e` recipe

**Issue #025 — Vision Model Benchmark:**
- Corpus assembled (65+ images across 9 strata)
- Benchmark harness implemented
- First run against Qwen2.5-VL-7B-Instruct
- Results committed, report generated
- Production model confirmed or upgraded based on results

**Phase 1 Integration Test (all must pass):**
- [ ] Register account → KYC age verification → email confirmation → onboarding flow
- [ ] Upload a book photo → verify → choose shelf (WishList) → book created as work + edition
- [ ] Login redirects to `/antilibrary`
- [ ] Browse all 5 shelf views; Looking for a Home shows community wear
- [ ] Click spine → overlay opens (URL unchanged); dismiss via Escape
- [ ] Move book between all 5 shelves → history recorded
- [ ] Search finds book; platform-wide scope available
- [ ] Upload Kindle edition → multi-format merge → editions listed on overlay
- [ ] Enrichment: prices appear per edition, reviews appear per work, author card shows RSS
- [ ] Settings hub: profile, location, password, notifications all work
- [ ] Privacy: set shelf visibility, block a user → blocked content returns 404
- [ ] View As mode works correctly
- [ ] List a book for sale → another user buys → Stitch payment → Pargo shipping → post-sale prompt
- [ ] Write blog post → LLM associations appear → confirm/dismiss
- [ ] Book detail overlay shows "My Writing" section with linked posts
- [ ] RSS feed for public shelf validates as Atom
- [ ] Metrics dashboard shows real system data
- [ ] List view toggle renders table view
- [ ] ARIA labels present; keyboard navigation works
- [ ] Playwright E2E tests pass
- [ ] Full CI pipeline green on `main`
- [ ] `docs/capacity-model.md`, `docs/runbooks/`, `docs/decisions/` all exist

## Definition of Done
- [ ] All integration test items above pass
- [ ] All 22 issues (#042-063) are complete
- [ ] Issues #012 and #025 are complete
- [ ] Production deployment is stable and accessible
- [ ] No P0 or P1 issues from principle-engineer-agent review

## Dependencies
ALL previous issues (#042-062, #012, #025)

## Agent Assignment
platform-agent + principle-engineer-agent (deployment + final review)

## Progress Notes
