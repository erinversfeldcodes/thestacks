# Issue #347: Program-test effect translators rebuild Api requests, so a divergence is invisible

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by the lead's independent probe during #343's review. `TestHelpers.uploadEffects` (`frontend/tests/TestHelpers.elm:868-1010`) translates `Upload.Msg` into `SimulatedEffect`s by **hand-constructing the HTTP request** — URL, method and JSON body — rather than deriving it from the `Api.*` function the production code actually calls. There are **5 hand-built requests in that one translator**:

```
/api/books/<id>          /api/books/confirm          /api/books/<id>/merge-format   (+2 more)
```

The consequence is concrete and was demonstrated, not theorised:

> **Probe:** in `frontend/src/Api.elm`, change `confirmBook`'s body from `Encode.string body.shelfName` to a hardcoded `Encode.string "wishlist"` — i.e. the reader picks Antilibrary and the app files the book on their Wish List.
> **Result: `TEST RUN PASSED — Passed: 1353, Failed: 0`.**

`UploadProgramTest.manualIsbnHonoursTheChosenShelf` *does* assert `shelf_name == "antilibrary"` — and it is a good test — but it asserts against the **translator's** encoder, so it validates `Page.Upload`'s model→request mapping while saying nothing about `Api.confirmBook`. The production encoder has no test at all.

## Not a regression — a convention
⚠️ **#343 did not introduce this**; it followed the established shape of the file (all five requests in `uploadEffects` are hand-built, and other translators do the same). Treat this as pre-existing structural debt that #343's probe made visible, not as a fault in that change.

Some simulation is unavoidable: `elm-program-test` cannot run a real `Http.request`, so effects must be translated. The avoidable part is **re-deriving the URL and body** instead of taking them from one source.

## Why it matters beyond this one field
Wave 3's **#328** removed 11 hand-mirrored *decoders* and exported `Api.elm`'s real ones, because a mirror drifts silently — and **one of those mirrors had already diverged from production when it was found**. This is the same defect class on the *request* side, still open. A wrong URL, a wrong field name, or a dropped field in any `Api.*` request function is currently invisible to the Elm suite.

## User Stories
None — test truthfulness. Validated by the probe above.

## Goal
An Elm program test that passes is evidence about the code that ships. A divergence between a simulated effect and the `Api.*` function it stands in for fails a test.

## Scope Check
Test infrastructure plus whatever minimal `Api.elm` surface must be exposed. Start with `uploadEffects` (5 requests) and generalise only if the pattern holds. One concern.

## Wiring
Router wiring: none. Test-infrastructure surface only; no production behaviour change.

## Feature-Completeness Pre-Check
n/a — no user story. Acceptance is the counterfactual in Technical Requirement 3.

## Technical Requirements
1. **Give `Api.*` request builders a testable seam.** The cheapest shape is to expose the request *record* (url/method/body) separately from the `Http.request` call, so both production and the translator consume one definition. Follow #328's precedent — it widened `Api.elm`'s exposing list deliberately and documented why in the module doc; do the same rather than inventing a second convention.
2. **Rewrite `uploadEffects`' five branches** to use that seam instead of hand-built records.
3. **Counterfactual acceptance test** — re-run the exact probe above: hardcode `confirmBook`'s `shelf_name`, and the suite must now go **red**. Quote both transcripts (green before, red after), the way #330 proved the rate-limit repair.
4. **Survey the other translators** before generalising. Report how many hand-built requests exist repo-wide so the size of the class is known, and fix them if the same seam serves; do not force an ill-fitting abstraction onto translators that differ.

## Reviewer Context
- ⚠️ **Elm has no test-only exposing**, so this widens `Api.elm`'s public surface deliberately. Note it in the module doc — that is the accepted project convention (see #328 and the `Msg(..)` exposure rule).
- ⚠️ `elm-review --fix` narrows an exposure back if no test consumes it — land each exposure together with its consuming test, never a suppression.
- Do **not** delete `manualIsbnHonoursTheChosenShelf` or its siblings; they are correct about what they cover. This issue changes what they are wired to, not what they assert.
- Run `bash scripts/lint-elm.sh` (elm-format, elm-review, vacuous-guard and prose-assertion checks) and `bash scripts/check-orphan-classes.sh`.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Test truthfulness | yes | ❌ the counterfactual: hardcoding `confirmBook`'s shelf must redden the suite (today it passes 1353/0) |
| Elm | yes | ❌ all five `uploadEffects` branches derive from the `Api.*` seam |
| Regression | yes | ❌ existing program tests still pass and still assert what they did |
| Others | no | n/a |

## Definition of Done
- [x] `Api.*` request seam exposed and documented in the module doc — evidence: 2026-08-09 diff — `RequestSpec` (method/url/`Maybe Encode.Value` body, kept as data because `elm/http` and `SimulatedEffect.Http` body types differ) + `confirmBookRequest`/`getBookRequest`/`mergeFormatRequest`; production `confirmBook`/`getBook`/`mergeFormat` now derive from the same specs via `specHttpBody`; moduledoc paragraph added beside the #328 note
- [x] `uploadEffects` derives all five requests from it — evidence: the 5 sites named at filing (2× duplicate/batch `getBook`, same-work `getBook`, `confirmBook`, `mergeFormat`) now call `TestHelpers.authedRequestFromSpec`; converting `mergeFormat` exposed and fixed a REAL drift — the translator sent an empty body where production sends proto-encoded `{isbn, format_label}`
- [x] Counterfactual red — evidence: before (filing probe): hardcoded `shelf_name` → `1353 passed, 0 failed`; after: same mutation → `Passed: 1743, Failed: 1` — `manual_isbn_shelf_choice` fails with `Ok "wishlist"` vs `Ok "antilibrary"`; reverted → `Passed: 1744, Failed: 0`
- [x] Repo-wide hand-built-request count reported — evidence: 47 `SimulatedEffect.Http.request` sites pre-change (34 in TestHelpers.elm + 13 across 8 program-test files); 5 converted, 42 remain hand-built. `uploadEffects` itself grew post-filing branches (multipart `GotFile` — not servable by a JSON spec — placement, reject-identification, age-gate) which follow the now-established `RequestSpec` convention as their `Api.*` builders gain specs; not forced here per Technical Requirement 4's own instruction
- [x] Elm suite green at cited count; `lint-elm.sh` clean — evidence: 1744 passed / 0 failed; `just run bash scripts/lint-elm.sh` fully green 2026-08-09 (elm-review keeps the new exposures because the tests consume them)
- [x] `staff-review` verdict recorded below — see Wave 11 close-out

## Dependencies
Related to **#328** (removed the decoder-side mirrors and set the precedent). Surfaced during **#343**. Not blocking any wave — needs an owner wave assignment.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-31 by the lead. Probe transcript: hardcoding `Api.confirmBook`'s `shelf_name` to `"wishlist"` left the Elm suite fully green (1353 passed, 0 failed), proving the production encoder is untested. Probe reverted via Edit; `git status` clean, `grep -c` → 1.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM WITH NOTES** — RequestSpec carries data, not transport — the right seam given Elm's two body types; the counterfactual that motivated the issue now reds the suite. Note: 42 hand-built simulated requests remain repo-wide (13 outside TestHelpers); convention established, conversion is follow-up-class work.
