# Issue #178 — Complete

**Issue**: #178 — Extend the session-expiry 401 interceptor to the remaining authed pages (US-14.3.2)
**Branch**: `178-session-expiry-interceptor-remaining-pages` (off `feat/124-e2e-auth`)
**Completed**: 2026-07-11
**Agent**: elm-agent (Phase 1 + Phase 2) · **Revision cycles**: 0

## What shipped
#173's global session-expiry interceptor covered only the 8 authed pages that already had an `OutMsg`
channel. This converts the remaining **11** authed pages to the 3-tuple `( Model, Cmd Msg, OutMsg )`
pattern with a `SessionExpired` variant (emitted via `Api.isUnauthorized`, 401-only) routed in
`Main.update` to the single `Main.sessionExpired`, **plus** the boot-time hook.

- **Settings**: AgeVerification, Consent, Privacy
- **Admin**: Metrics, ScraperConfig, SourceApproval
- **Blog**: Post, Editor · **Marketplace**: MyListings · **Discovery**: Catalogue, Search
- **Boot hook**: `Main.elm`'s `GotPlacementCheck (Err 401)` (previously swallowed) now routes to
  `sessionExpired`, giving boot/reload expiry coverage for **every** page for free — shrinking the
  residual gap to "in-session request on an uncovered page" only.

### Scope calls (deliberate)
- Only genuinely authenticated `Err` branches route 401. **Catalogue's public `getCatalogue`** list
  fetch (no auth header) stays local (`NoOut`) — guarded by an explicit test
  (`catalogue_public_list_401_stays_local`).
- **Blog optional-auth reads** (`getBlogPost`/`getPostComments`) route their 401 too: a logged-in user
  with an expired token still hits 401 on them (per user decision).
- 403 age-gate + login/register stay local (`Api.isUnauthorized` is 401-only).

## Testing / validation
- **41 page-seam unit tests** (`frontend/tests/Page/SessionExpiryPagesTest.elm`, new): each page's
  authed 401 → `SessionExpired`; non-401/success → `NoOut` (guards over-routing); + the Catalogue
  public-branch guard. Cascading 2-tuple destructures fixed in `TestHelpers`, `CatalogueProgramTest`,
  `BlogPostCommentTest`, `SettingsTest`. **602 elm tests pass.**
- **Live E2E** (`e2e/tests/auth.spec.ts`, +2 cases): a Settings/Privacy *action* redirect
  (newly-covered page) and the **boot-hook** path on `/` (redirect with no user click, attributable
  purely to the placement-check 401). Both green on Fly preview.

## Gate record
- 2A-iv reception: elm-reviewer **APPROVE** — mechanically faithful to the #173 template, no non-401
  behaviour drift (7 `Err _ → Err err` widenings spot-checked), tests non-vacuous. 2 P2 nits, both
  handled: boot-hook test gap → closed with the boot-path E2E; one *intended* Catalogue 401 semantics
  change (`UserPlacementsLoaded` 401 no longer silently degrades to `Success []`) → confirmed correct.
- 2B-i `just verify`: **exit 0**.
- 2B-ii spec coverage: all 11 pages + boot hook routed.
- 2B-iia fresh-DB: **skip** (no migration).
- **2B-iii Deploy-Preview + E2E: PASS** — deploy healthy on Fly; **199 passed, GATE_RESULT=PASS**,
  including the 2 new #178 cases (Privacy 8.2s, boot hook 9.9s) and the existing #173 session-expiry
  test. **1 flaky, unrelated**: `upload.spec.ts:12` (barcode → local-OCR) timed out twice then passed
  on retry — a vision-service cold-start latency flake; #178 touches zero upload/vision code. Flagged
  for its own issue, not fixed here (scope lock).
- 2C: elm-reviewer APPROVE; ux unchanged from #173 (same redirect + notice, no new surface).
- 2F Principal Engineer: light — the backend `:authenticated` pipeline remains the real gate; this
  closes the UX gap (broken view → clean redirect) on the previously-uncovered pages; the boot hook
  shrinks the residual to in-session-on-uncovered-request only. No P0/P1.

## Notable constraint
`Main.sessionExpired` and the boot hook live in `Main.update` (embeds `Nav.Key`, opaque `Cmd`) → not
elm-program-testable. Per-page routing is unit-tested at the page seam; the boot hook + end-to-end
redirect are covered by the live E2E (the reviewer's boot-hook test-gap nit, closed).

## Follow-up (not filed yet)
- **OCR barcode E2E flake** (`upload.spec.ts:12`) — vision-service cold-start timeout; passed on retry.
  Recurring/environmental; warrants its own issue (warmup guard for the vision sidecar, mirroring the
  #175 preview warmup, or a longer first-attempt timeout). Explicitly out of #178 scope.

## Batch
Follow-up #2 of the #178–182 batch (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next: **#182**.
