# Issue #189: GDPR Audit-Log Read API + Page

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Add a paginated read surface over the immutable audit log — a backend endpoint and an Elm page — so a user/admin can view their audit history.

## User Stories
US-8.5 (Audit Log — read surface).

## Goal
A user/admin can read their immutable audit log (action, resource, timestamp) through a paginated, read-only page, with metadata decrypted for display and hashed IPs never exposed.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (one read controller).
- Does this issue add more than 2 new endpoints? No (one read endpoint).
- Does this issue exceed ~300 lines of production code? Borderline — endpoint + Elm page; split if needed.
- Does this issue combine unrelated concerns? No (audit read only).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [x] This issue includes router/UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.5 — Audit Log (read surface) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Paginated read endpoint over `audit.audit_log`: decrypt `metadata` via `Stacks.Vault` for display; **never expose raw/hashed IPs**.
- `/settings/audit-log` Elm page listing entries (action, resource, `occurred_at`).
- Read-only — the append-only trigger stays unchanged; no write/update/delete surface.

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- `audit.audit_log` is INSERT-only, protected by a DB-level append-only trigger — this issue must not add any write path.
- IPs are stored SHA-256-hashed; never surface them (raw or hashed) in the API/UI.
- `metadata` is Cloak-encrypted via `Stacks.Vault` (`CLOAK_KEY` required — load `.env` in tests).

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [ ] Paginated read endpoint over `audit.audit_log`
- [ ] `metadata` decrypted via `Stacks.Vault` for display
- [ ] Hashed IPs never exposed in response/UI
- [ ] `/settings/audit-log` Elm page (action, resource, `occurred_at`)
- [ ] Read-only — append-only trigger unchanged
- [ ] `just verify` passes
- [ ] E2E / elm-test coverage

## Dependencies
None.

## Agent Assignment
elixir-agent + elm-agent.

## Progress Notes
