# Issue #095: Update technical-architecture.md for Marketplace + Wave D

## Summary
Section 25 of technical-architecture.md still describes the full e-commerce marketplace (Stitch Money, Pargo, offer threads) which contradicts ADR 013 (classifieds-only). The external services table also lists deferred services as active. The version header is stale.

## Goal
Bring technical-architecture.md in line with the current codebase after Waves C and D.

## Scope Check
- 1 file, ~200 lines of edits across several sections
- Documentation only

## Technical Requirements
- Update section 25 to describe the classifieds model: listing CRUD, contact_info field, no payments/shipping/messaging
- Remove or mark as "deferred" references to Stitch Money, Pargo, offer threads, KYC
- Add `contact_info` to the listing schema description
- Fix condition grading list (add `like_new`)
- Update external services table to reflect what's actually deployed
- Update version header and date
- Review sections touched by Wave C (enrichment pipeline, source discovery, monitoring) and Wave D (blog, feeds, metrics, marketplace, dbt models) for accuracy
- Update docs/implementation-mapping.md if stale

## Definition of Done
- [ ] Section 25 matches ADR 013
- [ ] External services table matches reality
- [ ] Version header updated
- [ ] No references to Stitch Money, Pargo, or offer threads as active/planned features

## Priority
P1 — fix before Wave E

## Agent Assignment
Any (documentation task)
