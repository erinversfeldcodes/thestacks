# Issue #336: The `enrichment.reviews_scraped` wiring outlives its emitter

## Summary
Discovered by #334's event-registry audit and independently confirmed by the lead. Wave 2's deletion commit `45ddcc44` ("delete dead workers, reviews scaffolding, and orphaned functions") removed the **sole emitter** of `enrichment.reviews_scraped` but left every consumer-side reference standing:

| Surviving reference | File |
|---|---|
| Registry handler entry | `apps/core/lib/stacks/events/registry.ex:91` |
| dbt refresh mapping → `int_review_sentiment`, `mart_book_reviews` | `apps/core/lib/stacks/workers/dbt_refresh_handler.ex:12` |
| Payload contract (`version: 1, keys: ~w(book_count)`) | `apps/core/lib/stacks/events/payload_contract.ex:113` |
| dbt model | `dbt/models/intermediate/int_review_sentiment.sql` |
| dbt model | `dbt/models/marts/mart_book_reviews.sql` |

This is the **mirror image** of the campaign's dominant defect class (see memory: *"built but not wired"*). Here the wiring is intact and the source is gone — an event that can never fire, a handler that can never run, and two dbt models whose only refresh trigger is now unreachable.

## User Stories
None — dead wiring removal. Validatable via the zero-row sweep and the registry completeness test #334 added.

## Goal
Either the reviews vertical returns with an emitter, or its consumer-side wiring goes with it. No third state — a handler for an unemittable event is exactly what `all_event_types/0` exists to make visible.

## Scope Check
Three Elixir references + two dbt models + whatever `sources.yml`/schema entries they carry. One concern. Well under the bar.

## Wiring
Router wiring: none. This *is* a wiring issue: the trace runs emitter → registry → `DbtRefreshHandler` → dbt models, and the first hop is missing.

## Feature-Completeness Pre-Check
n/a — no user story. The pre-check that matters is the **zero-row sweep**: confirm `mart_book_reviews` and `int_review_sentiment` are empty/stale in the warehouse before deleting, which is the evidence that nothing has fed them since `45ddcc44`.

## Technical Requirements
1. **Decide the direction first, and say why.** Wave 2 deleted the reviews scaffolding deliberately; check that commit's rationale and the campaign plan before assuming deletion is correct. If reviews are genuinely coming back (a scraper, an enrichment source), the fix is an emitter and a tracked issue for it — not retaining orphaned wiring on the hope.
2. **If deleting**: remove the registry entry, the `DbtRefreshHandler` mapping, the payload contract, and both dbt models — plus their `schema.yml`/`sources.yml` entries and any downstream `ref()`. `dbt parse` and `dbt build --select state:modified+` must stay green.
3. **Zero-row sweep evidence** on both models before removal — a row count, not an assertion that they look unused.
4. **`#334`'s registry completeness test must stay green** and should be the thing that would have caught this: consider extending it to also flag the inverse (a registered type with no emit site anywhere), which is the check that turns this defect class structural. That extension is the highest-leverage part of this issue.

## Reviewer Context
- ⚠️ The `NOTE:` comment at `registry.ex:85` documents the orphan; #334 deliberately left it in place rather than moving it to `@unsubscribed`, because that list is for types that *are* emitted. Whichever direction this issue goes, that comment must not survive it.
- `dbt` models here are **views** in two neighbouring cases (#334 found `stg_listings`, `stg_uploaded_images` are views) — check materialisation before reasoning about refresh cost.
- Deleting a dbt model that a mart `ref()`s is a build break, not a warning — trace downstream first.
- Commit: agent commits are DENIED. Stage, one-line message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Event flow | yes | ❌ registry completeness test extended to catch registered-but-unemitted; probe it by re-adding a fake orphan |
| dbt | yes | ❌ `dbt parse` + downstream `ref()` trace clean after removal |
| Warehouse | yes | ❌ zero-row sweep evidence captured before deletion |
| Others | no | n/a |

## Definition of Done
- [ ] Direction decided with `45ddcc44`'s rationale cited — evidence: quoted rationale + decision
- [ ] Zero-row sweep on both models — evidence: row counts
- [ ] All five references resolved consistently — evidence: `grep -rn reviews_scraped` → 0 (or an emitter exists)
- [ ] Registry test extended to catch the inverse case, mutation-probed — evidence: probe transcript
- [ ] `dbt parse` + suites green — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
**#334** (built the registry completeness test this extends; found the orphan). Not blocking any wave — schedule into Wave 11 (#321) with the other wiring work, or earlier if a wave touches `DbtRefreshHandler`.

## Agent Assignment
elixir-agent + dbt.

## Progress Notes
Filed 2026-07-30 by the lead during Wave 4, from #334's follow-up finding. Independently confirmed: `git log -S"reviews_scraped"` identifies `45ddcc44` as the commit that removed the emitter (`- event_type: "enrichment.reviews_scraped"`), and both dbt models still exist on disk.

**Wave assignment (owner-approved 2026-07-31): Wave 11.**
Scheduled as item **11f**, beside **11e** (wire the bookstore-events vertical): both are the same decision in opposite directions — 11e wires a vertical that was built but never connected, 11f resolves one whose source was deleted while its consumers remain.
