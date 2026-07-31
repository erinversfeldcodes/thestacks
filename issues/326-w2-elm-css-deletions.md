# Issue #326: W2 child B — Elm/CSS deletions: Route.Settings collapse, dead idioms, phantom tokens

## Summary
Child of epic #312 (Wave 2). Collapse the `Route.Settings` alias (fixes the sidebar-highlights-nothing bug + kills 20 duplicated init lines), fold `LogoutCompleted` into the `FocusResult` idiom, remove the ReviewSummary "coming soon" rendering (seam with #325), delete the 3 phantom CSS tokens, the stale `Api.elm` comment, and 4 dead env vars.

## User Stories
US-17.1.1 (settings hub active-state fix falls out of the collapse).

## Goal
`/settings` parses directly to `SettingsProfile`; `fromUrl (toPath r) == r` holds for every route (property test); no `var()` references a token that doesn't exist; elm suite green.

## Scope Check
Deletion/collapse only.

## Wiring
No route removed — `/settings` now parses to an existing page constructor (behaviour: sidebar highlights Profile; select shows correct option).

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-17.1.1 active-state on /settings | Route.elm:83 aliases to a distinct constructor → sidebar `==` match fails | driven 2026-07-30: nothing highlighted | ❌ | fixed by the collapse in-scope |

## Technical Requirements
1. `Route.elm:83` → `Parser.map SettingsProfile (s "settings")`; delete the `Settings` constructor, its `toPath` clause (:152-153), and the duplicate init branch (`Main.elm:718-728` vs :730-740 — keep one); fix every `case` that referenced `Settings` (compiler-driven).
2. Add to `RouteTest.elm`: property/table test `fromUrl (toPath r) == r` over all route constructors (this is the guarantee that outlives the collapse).
3. `LogoutCompleted` (no-op Msg discarding its Result) → reuse the `FocusResult` no-op idiom (5 existing call sites show the pattern).
4. Remove `Components/ReviewSummary.elm` + its BookDetail mount + the "What People Think" section rendering (seam with #325's backend removal — coordinate; BookDetail keeps its other sections untouched).
5. CSS: delete the 3 phantom-token `var()` uses, inlining each fallback value (`--link-color`→`#6b4e2e` ×3, `--link-hover`→`#4a351f`, `--parchment-ink`→`#3a2e1e` ×2 — main.css:1524,1530,2954-2955,1480,2973); confirm `scripts/check-css.sh` stays green.
6. `Api.elm:688-690`: correct the stale "presigned R2 PUT URL" doc comment (it's a Phoenix proxy since the rework).
7. Dead env vars: remove `REQUIRE_EMAIL_CONFIRMATION` (.env:144), `OPEN_LIBRARY_BASE_URL` (.env:78, .env.example:103), `VISION_MODEL_NAME` (.env:53), `RELEASE_COOKIE` (.env.example:197 — overwritten unconditionally by rel/env.sh.eex:14). NOTE: `.env` is gitignored — edit it in the MAIN checkout is impossible from your worktree; list the `.env` lines in your report for the lead to apply, and commit only `.env.example` changes.

## Reviewer Context
- BOOTSTRAP (worktree): `git fetch origin feat/campaign-w0-311 && git merge --ff-only FETCH_HEAD` first. For elm-test: your worktree lacks `frontend/node_modules` and gitignored `proto/gen/elm` — run the main checkout's elm-test binary against your worktree cwd and copy `proto/gen/elm` from the main checkout (pattern from #324's report).
- Elm suite baseline on this base: 1176 passed. `elm-review --fix` narrows exposures — don't run it standalone.
- Route collapse touches `Main.elm` cases that #316 will rework later — do the MINIMAL collapse, no drive-by refactors (scope-lock).
- Commit pathspec only your files; NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ round-trip property test (all constructors); suite green post-collapse |
| Visual/live | yes | ❌ finalization drive: /settings shows Profile highlighted in sidebar + correct select option (screenshot) |
| CSS gate | yes | ❌ check-css.sh + check-orphan-classes.sh both green post-deletion |
| 1–13 | no | n/a |

## Definition of Done
- [x] Round-trip property + probes — evidence: builder two-edit probe (1329/1 quoted); reviewer single-edit probe exposed the entry-mapping gap → STRENGTHEN c34b302b, probed red 78/1 / green 79/0
- [x] elm-test green — evidence: 1331 passed 0 failed (full suite post-strengthen)
- [x] CSS gates green — evidence: check-css.sh "720 rules, 0 problems"; check-orphan-classes "0 unstyled, 88 verified hooks"
- [x] Finalization drive — evidence: ss_0513sacfo + DOM check: `settings-hub__nav-item--active :: Profile` on bare /settings; select shows "Profile"; title "Profile — The Stacks" (visual treatment = #318 scope)
- [x] `staff-review` verdict recorded below — evidence: LGTM WITH NOTES → STRENGTHEN APPLIED, Progress Notes

## Dependencies
Epic #312; base = Wave 0 head. Sibling #325 (ReviewSummary seam — B removes frontend, A removes backend).

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-30 (Wave 2 kickoff approved).
Built in worktree; commit 44ba7b29; merged to feat/campaign-w2-312. Dead `.env` lines applied by lead (3 vars removed).
**staff-review verdict: LGTM WITH NOTES → STRENGTHEN APPLIED** (2026-07-30, Mode B on 44ba7b29). Praise: the 43-constructor round-trip property is the right guarantee shape for the collapse, and the child's two-edit probe rationale showed real understanding of what the property can and cannot see. Reviewer's independent single-edit probe then demonstrated the *cannot* half concretely: re-aliasing bare `/settings` to the wrong page left the property suite 78/78 green — the entry mapping itself was unguarded. STRENGTHEN applied on the integration branch (c34b302b): one direct `fromPath "/settings" == SettingsProfile` assertion, probed red (78/1) against the alias and green (79/0) restored; full suite 1331/0. Deviations (test-file updates + e2e assertion removal for the mandated ReviewSummary deletion; protected-route count 24→23) reviewed and accepted as necessary consequences, kept minimal.
