# Issue #317: [EPIC] Campaign Wave 7 — Recovery and the unhappy paths

## Summary
Epic for Wave 7 of `plans/staff-campaign-2026-07-30.md`: the missing recovery legs and failure copy. Owner rulings 2026-07-30: undo-remove SPEC'd (toast); un-merge SPEC'd owner-only; cancel-deletion grace EXCLUDED; public photo-delete EXCLUDED (auto-path verification folded into the deferred GDPR revisit).

## User Stories
US-14.4.2 (resend confirmation — to be mapped by #320), US-1.6.4 (undo-remove extension), US-1.1.8 (un-merge, owner-side), US-16.2.1 (failure copy).

## Goal
A user who loses the confirmation email can recover (and cannot be silently erased at 24h without that chance); every upload failure mode has distinct, in-voice copy within seconds; a misclicked removal is undoable for a few seconds; a wrong merge is correctable by the platform owner; 429s and settings-form failures stop sharing one lying message.

## Scope Check
Epic; resend-confirmation alone is close to a full child (endpoint + UI + rate limit + no-enumeration).

## Wiring
Router wiring: one new endpoint (`POST /auth/resend-confirmation`) + owner-only un-merge admin surface; user-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-14.4.2 resend confirmation | none exist | register-success card has no resend affordance (driven) | ❌ | build in-scope |
| Undo-remove | none exist | removal is terminal (driven) | ❌ | build in-scope (toast) |

## Technical Requirements (child phases)
1. **Resend confirmation (US-14.4.2)**: endpoint + login-card/registration-pending affordance + `:auth`-bucket rate limit + no-enumeration generic response; replace the "register again" copy; **reconcile with `ExpiredUnverifiedAccountsJob`**: an unconfirmed account must be recoverable before erasure (extend TTL on resend, or document the interplay in the story).
2. **Undo-remove toast (owner-ruled SPEC)**: "Removed — Undo" toast for a few seconds after Remove-from-collection; undo restores the same placement row (soft-delete reversal, preserving history), not a fresh placement. Write the small story file (with #320's batch or inline here — one home, no duplication).
3. **Owner-only un-merge (owner-ruled SPEC)**: platform-owner data-correction process to split a wrongly merged edition back out (admin surface, MFA-gated like other admin routes; audit-logged). Story written as owner-process, NOT public UI.
4. **Failure copy sweep**: upload failure states with distinct in-voice copy per cause (undecodable / not-a-book / service-down / timeout) consuming #315's terminal events — no more 6-minute spinner; forgot-password double-send dedup (disable+state after first send); 429 UX copy (rate-limited is currently unstoried — one voice-consistent message + retry-after where available); W-10: distinct copy per failure cause (422 / 401 / network) on the settings forms using #316's components.
5. **Record the exclusions**: cancel-deletion grace and public photo-delete recorded in `implementation-mapping.md` as deliberate exclusions with the 2026-07-30 rationale (coordinate with #320 — one editing pass).

## Reviewer Context
- No-enumeration is the load-bearing property of both resend and forgot paths — the generic response must be byte-identical for existing/nonexistent emails; the E2E asserts it.
- Undo must not fight the same-shelf unique index: restoring the SAME row (clear `removed_at`) avoids conflict when the user re-added meanwhile — handle that collision case explicitly.
- The un-merge admin surface follows `admin-session.spec.ts` patterns (MFA gate; admin 401 must not sign out the operator).
- Age-gate Verify affordance stays withdrawn (ADR-020 §2) — nothing here reintroduces it.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API + auth | yes | ❌ resend: happy, rate-limited, no-enumeration (response-identical assertion), TTL interplay |
| Elm | yes | ❌ toast program test (undo restores same placement); failure-copy states per cause |
| E2E | yes | ❌ resend journey via sent-emails helper; undo live drive; 429 copy spec |
| Admin | yes | ❌ un-merge process test (MFA-gated, audit-logged, splits edition) |
| Others | n/a epic-level | per child |

Punch: 8 items.
Verdict: baseline ❌ ×8.

## Definition of Done
- [ ] Live drives: lose-the-email → resend → confirm journey completes; remove → undo restores book in place (screenshots); forced upload failures each show their copy in ≤5s; double-send blocked — evidence: screenshots + logs
- [ ] No-enumeration probe: identical responses for real vs fake email — evidence: diff of captured responses
- [ ] Un-merge driven on preview by owner-role account — evidence: before/after editions query
- [ ] Exclusions recorded in mapping — evidence: diff
- [ ] Feature-Completeness ✅; validation paths; suites + `just verify`; audit GREEN; `completion-audit`; Completion Bar
- [ ] `gdpr-review` on the diff (auth endpoint + retention interplay) — cite verdict
- [ ] `staff-review` per child in Progress Notes

## Dependencies
- #315 — upload failure UX consumes its terminal events. Reason: events before their consumers.
- #316 — notices/copy use its components (Arrival, status notices, save-button). Reason: structure before per-surface copy.
- #320 — story files and mapping edits coordinate (one editing pass over mapping). Reason: doc-conflict avoidance; can interleave.

## Agent Assignment
Orchestrator; elixir-agent (endpoint, TTL, admin), elm-agent (toast, copy).

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. Owner rulings embedded above.
