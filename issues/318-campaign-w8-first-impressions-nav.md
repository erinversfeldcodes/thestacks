# Issue #318: [EPIC] Campaign Wave 8 — First impressions and navigation

## Summary
Epic for Wave 8 of `plans/staff-campaign-2026-07-30.md`: collapse the product's two visual registers into one. Nav IA (Add Book is currently unreachable on touch), onboarding per owner decision D2, authed home, settings hub, Looking-for-a-Home, About, the verify screen, and the a11y follow-through.

## User Stories
US-14.1.2 (onboarding), US-14.3.3/US-15.2.1 (nav), US-15.1.1 (home), US-17.1.1 (settings hub), US-18.1.1 (fifth shelf), US-1.1.1 (verify layout), US-1.6.5 (empty-state CTAs), US-19.1.1/19.1.2 (a11y).

## Goal
Every Phase 1 surface reads as Register A: nav discloses via real controls with ARIA state; Add Book is a persistent primary action; onboarding matches D2 and honours its modality claim; the authed home routes you into your collection; settings looks like the product and says where you are; Looking-for-a-Home joins the shelf family; About carries real copy; the verify screen matches its story.

## Scope Check
Epic; children per surface family. The settings-hub child folds Consent into Privacy (IA change) — flag as its own child with a small design pass first.

## Wiring
Router wiring: `/settings/consent` folds into `/settings/privacy` (redirect kept); otherwise existing routes, user-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-14.1.2 step 2 = upload | shipped Privacy step; spec says "Upload your first book" | driven: matches neither story nor D2 | 🟡 | build in-scope per D2 (upload + consent) |
| US-15.1.1 authed home routes onward | documented drift (story:13) | marketing hero, no path to collection | 🟡 | build in-scope; resolve the drift note |
| US-18.1.1 shelf aesthetic | flat page, no room | driven | 🟡 | build in-scope |
| US-1.1.1 side-by-side verify | stacked, no uploaded image | driven | 🟡 | build in-scope |

## Technical Requirements (child phases)
1. **Nav IA**: Elm-owned disclosure (`<button aria-haspopup aria-expanded>` + `openMenu` state; delete `:hover`/`:focus-within`-only reveal, `main.css:245-246`); **Add Book as persistent primary action** (unreachable on touch today); Search top-level; five bookshelves grouped; user menu exposes the settings family (2 of 8 today); active-route highlight correct on child routes.
2. **Onboarding (D2, spec'd in #387)**: steps = Welcome → **Upload** → **Consent** → Done; ⚠️ **the step sequence is data-driven — an ordered list the view folds over, not hardcoded branches** — so a step can be added, reordered, or removed without rewriting the flow (owner constraint, 2026-08-05; reviewed for at kickoff-child). Real visibility chooser or honestly retitled; Skip persists via the same server path as advance; scrim to ~0.55 with blur (bookcase must read through); focus trap + Escape to honour `aria-modal` (or drop the attribute); dots spec'd and tested (code-level off-by-one not reproducible — remove the dot `transition` and re-verify).
3. **Homes**: authed home gets shelf preview / continue-reading / Add-Book CTA (resolves US-15.1.1's recorded drift, per #320's story edit); Looking-for-a-Home gets its room (wallpaper/wood/label family; pile-view of cover cards is fine if storied — reconcile with US-18.1.1 in #320); About page real copy (Milestone B surface — owner supplies/approves copy).
4. **Settings**: hub styled to the product (real `--active` treatment, grouped You / Privacy / Your data, one nav idiom with an actual breakpoint — the current mobile select has zero CSS); fold Consent into Privacy (three-names-one-page collision resolved); `.success` styled.
5. **Upload surface**: side-by-side verify layout per US-1.1.1:16 (uploaded image left, identified book right); shelf-picker and format widgets styled (browser-default today); replace the 📷 emoji with a crafted icon; empty-state CTAs become real actions (link/button, not prose); delete the design-spec sentence shipped as copy (`EmptyBookshelf.elm:28-30`).
6. **A11y follow-through**: "Deep search" accessible name; upload progress `aria-live`; keyboard reach for all disclosure menus; grid arrow-key decision recorded (spec or explicit defer in the story); "Shelf — 1 books" pluralisation.

## Reviewer Context
- The experiential specs are load-bearing: quote each story's "What they see" in the child PRs (`docs/user_stories/US-1.2.1…` is the bar).
- CSS gates are at zero-budget floors: every new class needs its rule (gate enforces), and #319's token work follows — use existing tokens now, don't mint literals (the drift sweep found drift concentrating in NEW surfaces).
- Consent-fold: keep consent TIMESTAMP semantics (US-8.1.3) intact; `gdpr-review` the diff.
- Reduced-motion must be respected on new transitions; no indicator gets a `transition` (see #316/#319 rule).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ disclosure program tests (open/close/keyboard/aria-expanded); onboarding step tests per D2; hub active-state test |
| E2E | yes | ❌ touch-profile Add-Book reachability; onboarding journey; settings breakpoint |
| Visual/live | yes | ❌ coherence screenshots per surface vs the Register-A exemplars |
| Others | n/a epic-level | per child |

Punch: 9 items.
Verdict: baseline ❌ ×9.

## Definition of Done
- [ ] Full live coherence sweep re-driven in ONE sitting: nav (touch emulation incl.), onboarding, home, settings, Looking-for-a-Home, About, upload — all Register A; screenshots per surface, compared against the shelf-room exemplars — evidence: screenshot set
- [ ] Add Book reachable via keyboard-only and touch-emulation drives — evidence: recording/screenshots
- [ ] aria-modal honoured: focus trapped, Escape closes — evidence: program test + drive
- [ ] Feature-Completeness rows ✅ live; validation paths; suites + `just verify`; audit GREEN; `completion-audit`; Completion Bar
- [ ] `gdpr-review` on the consent-fold diff — cite verdict
- [ ] `staff-review` per child in Progress Notes

## Dependencies
- #316 — Elm-owned disclosure pattern + notice components established there. Reason: one mechanism, not two.
- #315 — verify-screen redesign sits on the wired confirm flow. Reason: don't restyle a flow being rewired.
- **#387** — the D2 / US-15.1.1 / US-18.1.1 story amendments, **pulled forward from #320** (owner decision 2026-08-05) so 8b (onboarding) and 8c-homes build against a truthful spec. Reason: spec-before-build. #320 now records these as done rather than deciding them.

## Agent Assignment
Orchestrator; elm-agent (primary), ux-reviewer per child, elixir-agent (onboarding steps, consent fold).

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.

### 8a Nav IA — built 2026-08-05 (drive owed at the coherence sweep)
Elm-owned disclosure landed: `Model.openNavMenu : Maybe NavMenu`, real `<button aria-haspopup aria-expanded>` triggers, at-most-one-open invariant, backdrop for outside-click, Escape closes on every page; the `:hover`/`:focus-within`-only reveal (`main.css:245-246`) is DELETED. Add-Book is now a persistent `btn btn--primary` (not a hover-menu link); Search is top-level; the five bookshelves are grouped under one disclosure; the account menu exposes the full settings family (was 2 of 8). Active-route highlight extended to child routes.

**Verified (short of the browser drive):** Elm suite `1688 passed / 0 failed`; `MainNavTest` disclosure oracle **mutation-probed** 2026-08-05 — breaking the `if config.isOpen` menu-gate reds exactly "closed: contents NOT in the DOM" + "closed: no backdrop" (reverted with Edit, re-confirmed 49/0); `check-orphan-classes.sh` orphans: 0; `lint-elm.sh` clean; no new hex/px literals (tokens only); caret animates transform-only under a reduced-motion guard.

⚠️ **OWED — live drive:** the program tests prove DOM *presence*, not touch/keyboard *reachability* — the specific 8a guarantee ("Add Book unreachable on touch today"). Add-Book keyboard-only + touch-emulation reachability, Escape/outside-click close, and child-route active-state are to be driven in the epic's one-sitting coherence sweep (DoD box 1/2), not claimed from the code read. Consent-fold deferred to 8d (TR-4) as scoped; account menu links the existing `/settings/consent` for now.

### 8d Settings hub + Consent→Privacy fold — built 2026-08-05 (drive owed at the coherence sweep)
Hub rewritten as ONE grouped nav idiom (You / Privacy / Your data), active state via `aria-current="page"` derived purely from `currentRoute == item.route` (single source for both a11y and styling; the `[aria-current="page"]` selector is 0,2,0 so it beats `:hover` 0,1,1 by construction — the collision `check-css` gates is avoided, not restated). The mobile `<select>` (zero CSS) is deleted for a real `@media (max-width: 768px)` reflow. Consent folded into Privacy: `Page.Settings.Privacy` embeds `Consent` as a sub-model and delegates its update **verbatim**; `Route.SettingsConsent` removed; `/settings/consent` → Phoenix 302 to `/settings/privacy` (+ the Elm parser resolves the legacy path as an in-SPA net). The account-menu Consent link and the writing-assistant "Enable in Settings › Privacy" link re-point to Privacy.

**`gdpr-review`: PASS.** The consent write path is *verifiably* unchanged — `Consent.elm`'s `Model`/`Msg`/`update`/`init` and both `Api.saveConsent`/`Api.saveWritingAssistantConsent` calls are byte-identical (only a `viewSection` split + explanatory comments in the diff); no migration, no Ecto schema, no `Stacks.GDPR.Consent`, no `GDPRController.update_consent` change. Consent-timestamp semantics (US-8.3) and `POST /api/gdpr/consent` are untouched — the fold moved only *where in the UI* the toggles live.

**staff-review: LGTM.** Active-state oracle **mutation-probed** — forcing `isActive=False` reds "the current-page link is the one for the current route" / "the Privacy link is current" (found 0 aria-current instead of 1); reverted via Edit, re-confirmed 40/0. Elm suite 1694/0; `page_controller_test` redirect 4/0; orphans 0; `check-css` 0 problems. Honest correction by the author: `.success` was already styled (`main.css:6586`) — the spec's "unstyled" claim is stale, left as-is.

⚠️ **OWED — live drive (coherence sweep):** `aria-current` correct across each sub-page; the 768px breakpoint reflow (no `<select>`); consent toggles function within Privacy seeded from real consent and round-trip `POST /api/gdpr/consent`; the `/settings/consent` → `/settings/privacy` redirect.

### 8b Onboarding rebuilt to D2 — built 2026-08-05 (drive owed at the coherence sweep)
`Components.OnboardingOverlay` rebuilt from a 3-step hardcoded enum to a **data-driven** flow: `steps : List Step` + `currentIndex`; `currentStep = getAt currentIndex steps`; advance is `currentIndex + 1` (clamped, finishes off the end); dots fold over `model.steps`. There is NO step→step transition — `Step` is only a closed render tag, so adding/reordering/removing a step is a one-line edit to `defaultSteps = [Welcome, UploadFirstBook, Consent, Done]`. The **Upload** step embeds the real `Page.Upload` surface (`Html.map UploadMsg (Upload.view …)`), auto-advancing only on an actual placement; the **Consent** step embeds `Consent.viewSection` and delegates to `Consent.update` verbatim. Scrim 0.85→0.55 + blur; dot `transition` removed (indicator rule).

**`gdpr-review`: PASS.** Consent write path untouched — `Page/Settings/Consent.elm` and `Api.elm` are NOT in the 8b diff; no migration/schema/`Stacks.GDPR.Consent`/`GDPRController` change. Onboarding only chooses *where* the toggles appear; timestamps (US-8.3) + `POST /api/gdpr/consent` byte-identical. Both grants seed OFF.

**staff-review: LGTM.** Data-driven-steps oracle **mutation-probed** — folding the dots over fixed `defaultSteps` instead of `model.steps` reds "dropping a descriptor removes a dot (three-step → three dots)" (rendered 4, not 3); reverted via Edit, re-confirmed 24/0. Elm suite 1706/0; orphans 0; `check-css` clean; no new literals. Skip == Escape == advance-off-end all take one persistence path (server step via #149 + localStorage).

⚠️ **OWED — live drive (coherence sweep) + two honest residuals the builder flagged:** (a) the full upload journey (photo→SSE→identify→place, auto-advance) and consent round-trip need a real stack; (b) **focus-trap is partial** — a forward tab-guard + Escape + focus-on-advance are in, but **Shift+Tab can still escape backward** and focus is **not pulled in on first appearance** (a complete fix likely needs a focus-on-appear signal or a JS port — deliberately not added; to resolve at the sweep or as a follow-up); (c) a taste call — the Upload/Consent steps show both the onboarding heading and the embedded surface's own `<h1>` (double heading) — for the sweep's coherence judgement.
