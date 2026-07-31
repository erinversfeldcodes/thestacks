# Issue #328: W3 child — One SSE wire format; fixtures derived from the contract

## Summary
Child of epic #313. A mutation probe on 2026-07-30 broke all five production SSE wire fields and **1,285/1,285 Elm tests stayed green** — the upload pipeline's real decode path is guarded by nothing, because fixtures use a camelCase shape the server never emits. Collapse to the server's snake_case, derive fixtures from the contract, and delete the hand-mirrored decoders that let the drift hide.

## User Stories
US-1.1.1 (upload — the guarantee being restored), US-1.6.6 (reading progress — see the contract decision below).

## Goal
`Api.elm`'s upload poll/SSE decoder accepts exactly what `proto_json.ex` emits; breaking any wire field reddens a test; `TestHelpers.elm` no longer carries a second source of truth for decoders the app already owns.

## Scope Check
Frontend + fixtures. No server behaviour change (server is already snake_case).

## Wiring
Router wiring: n/a — decode-path change on an existing surface.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-1.1.1 upload SSE decode | `Api.elm:288-318` oneOf camelCase-first; server emits snake_case (`proto_json.ex:525-534`) | core loop drives fine (server shape wins at runtime); the *tests* exercise the dead branch | 🟡 | fix in-scope: single format + guarding tests |
| US-1.6.6 progress card | fixture invents `reading_status`/`current_page`/`started_at`/`finished_at`; `proto_json.ex:311-322` allow-list cannot emit them | card renders blank in production | ❌ | **drop the invented fields here** (make it honest); the "should the contract carry them?" question goes to #314 — do NOT fake server data

## Technical Requirements
1. **Single format**: delete the camelCase alternatives from the upload poll/SSE decoder (`Api.elm:288-318` — `imageId`, `bookId`, `bookIds`, `rejectionReason`, `isDuplicate`), keeping snake_case only. Keep the `succeed`-defaults only where the server genuinely omits a field; where the server always sends it, make the field required so a rename cannot pass silently.
2. **Fixtures from the contract**: rebuild the Upload SSE fixtures (`Page/UploadProgramTest.elm:69-75` and any siblings) to the shapes `apps/core/lib/stacks/gen/proto_json.ex` actually produces (`:525-534` for upload events, `:311-322` for `book_placement`). Read the module; do not guess.
3. **BookDetail progress fixture**: remove the four invented placement fields from `TestHelpers.elm:619-628`. The two tests that pass only because of them (`Page/BookDetailProgressTest.elm:117`, `:148`) must be rewritten to assert what the contract *can* deliver, or explicitly marked as blocked on #314 with a one-line note naming the missing contract fields. Report which you chose and why.
4. **Delete the hand-mirrors**: export the real decoders from `Api.elm` and delete `TestHelpers.elm`'s duplicates (`decodeBookDetailResponse` :1222, `decodeMergeFormatResponse` :1246, `decodeAvailabilityResponse` :1322, `decodeAuthResponse` :1571, `publicProfileSummaryDecoder` :1077) plus the six ad-hoc mirrors elsewhere (`Page/GdprExportProgramTest.elm:59-74`, `GdprDeleteProgramTest.elm:99-118`, `MetricsProgramTest.elm:41-59`, `InsightsProgramTest.elm:95-103`, `SessionExpiryTest.elm:234-260`, `:267-282`) where they duplicate an exportable decoder. Widening `Api.elm`'s `exposing` for tests is accepted repo practice — note it in the module doc.
5. **The probe is the acceptance criterion**: after the change, breaking any single wire field must redden at least one test. Run it for all five fields; quote the red output for at least two.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w2-312` FIRST (worktrees share refs; the branch is local/unpushed). elm-test needs the main checkout's `node_modules/.bin/elm-test` run against your worktree cwd, plus `proto/gen/elm` copied from `/Users/erinversfeld/thestacks/proto/gen/elm` (gitignored).
- Baseline on this base: **1331 passed** (Wave 2 added 43 route tests + the entry pin).
- `elm-review --fix` narrows `Msg(..)`/decoder exposures when no test consumes them — land each exposure WITH its consuming test, never a suppression.
- SCOPE-LOCK: the read-only SECURITY test and the rate-limit spec are #330's; the proto contract itself is #314's. You change the client and its fixtures only.
- Commit: agent commits are denied. Stage everything, write a ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-328.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm decode | yes | ❌ five-field probe battery: each wire-field break reddens ≥1 test (was: all five green) |
| Fixture realism | yes | ❌ every Upload/BookDetail fixture shape traceable to a `proto_json.ex` line |
| Suite | yes | ❌ elm-test green at cited count |
| 1–13 | no | n/a |

## Definition of Done
- [x] camelCase branches gone; server shape is the only accepted one — evidence: commit f01fea1c diff; all six fields now required `Decode.field`
- [x] SIX-field probe battery run (child found a sixth: `status`); each rename → 16 red / 1315 passed; 2 transcripts quoted — evidence: Progress Notes
- [x] Fixtures cite their `proto_json.ex` source lines — evidence: in-code comments citing :525-534 / :311-322
- [x] Progress-card decision: REWRITTEN (not blocked) — `reading_progress/1` (:688-696) can carry the quartet, so the honest test drives it; absence assertion pins the contract for #314 — evidence: Progress Notes + lead probe (4/1 red)
- [x] Hand-mirrored decoders deleted; real ones exported — evidence: 6 TestHelpers mirrors + 5 in two unlisted files; `catalogueResponseDecoder` mirror had already diverged from production
- [x] elm-test green — evidence: 1,331/0 at merge; 1,332/0 at wave gate
- [x] `staff-review` verdict recorded below — evidence: LGTM + independent absence-pin probe, Progress Notes

## Dependencies
Epic #313. Level 1 — parallel with #327. Feeds #330 (which rewrites remaining Elm test verdicts). Contract question handed to #314.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-30 (Wave 3 kickoff approved). Built in worktree; commit f01fea1c; merged into feat/campaign-w3-313.
**staff-review verdict: LGTM** (2026-07-30, Mode B on f01fea1c). The wave's premise is now closed: the probe battery that previously left 1,285/1,285 green produces **16 red tests per field, on all six fields** (the child found a sixth — `status` also carried a `succeed ""` fallback). Praise: (a) `isDuplicate` went `Maybe Bool` → `Bool` — a genuine ladder climb, the tri-state was unrepresentable on the wire; (b) the progress-card call was better than either option I offered — rather than faking data or parking the tests, it found that `reading_progress/1` (`proto_json.ex:688-696`) *can* carry the quartet, rewrote `card_mounts` to assert what production actually shows, and drove `error_surfaces`' draft through the form so the 422-preserves-input claim comes from a real user path; (c) it corrected my spec: four of the six "hand-mirror" sites I named had nothing to delete (two already used real decoders, two are effect mirrors), and a proper sweep found five genuine mirrors in two files I hadn't listed — including `catalogueResponseDecoder`, where the test mirror had **already diverged** from production's lenient proto decoder. That divergence is the campaign's hand-mirror thesis proving itself.
**Reviewer independent probe** — aimed at the assertion class my persona most distrusts, the new absence-based contract pin (`expectViewHasNot [reading-progress]`): made `PlacementCard.viewProgress`'s live branch render the testid unconditionally → `BookDetailProgressTest` 4 passed / **1 failed**. The pin is genuine, and it is correctly preceded by three presence assertions (card class, "Reading Progress", the badge with "To Read"), so it cannot pass on a component that failed to render. (First probe attempt hit the inner `Just Reading → currentPage = Nothing` branch, which a ToRead placement never reaches — my aim, not a defect.) Probe reverted via Edit; `git diff` clean; suite 1331/0.
Behaviour change reviewed and accepted: heartbeat frames now fail the decode by design, landing in `Page/Upload.elm:328`'s `Err _ -> ignore, stay in current state` branch (comment names heartbeats explicitly) — previously dead code, now the intended path. Deviations accepted: six fields not five; scope substitution on the mirror list; `position`/`placed_at` also dropped from the fixture (outside the allow-list); `_ -> Pending` status fallthrough kept with the doc comment corrected rather than the behaviour changed.
