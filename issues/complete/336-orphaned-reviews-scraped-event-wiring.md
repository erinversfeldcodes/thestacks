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
- [x] Direction decided with `45ddcc44`'s rationale cited — evidence: owner ruling 2026-08-07 (campaign state, decisions.336): "reviews ARE planned (US-2.1.1 re-scoped, not deleted). KEEP the vertical scaffolding … mark the orphan event pending-US-2.1.1 (not a live contract) + inverse completeness guard … NO full teardown." Direction = KEEP, third state made legitimate by a checked designation rather than a comment.
- [x] Zero-row sweep — evidence: 2026-08-09 local warehouse counts `op.review_snapshots` 0, `staging.stg_review_snapshots` 0, `intermediate.int_review_sentiment` 0, `marts.mart_book_reviews` 0 (all three dbt relations are VIEWS, so nothing stale is materialised)
- [x] All five references resolved consistently — evidence: all five KEPT per ruling; the registry entry now points at `Registry.pending_event_types/0`, whose entry carries US-2.1.1 + the ruling; `DbtRefreshHandler` mapping and payload contract stand unchanged as the wiring the vertical returns to
- [x] Registry test extended to catch the inverse case, mutation-probed — evidence: "every catalogued type is emitted, indirectly emitted, or explicitly pending" + stale-pending test in `registry_completeness_test.exs`; probe A (fake `probe.never_emitted` in @unsubscribed) → 1 failure naming it; probe B (@pending emptied) → 1 failure naming `enrichment.reviews_scraped`; restored → 39/0 across events suite. Guard surfaced NO further orphans (`source.approved`/`source.rejected` are uncatalogued indirect emits, out of its scope by design — named exemption map provided for when they are catalogued).
- [x] `dbt parse` + suites green — evidence: no dbt file changed (KEEP direction); events suite 39 tests 0 failures; full core suite 3553/0 this session
- [x] `staff-review` verdict recorded below — see Wave 11 close-out

## Dependencies
**#334** (built the registry completeness test this extends; found the orphan). Not blocking any wave — schedule into Wave 11 (#321) with the other wiring work, or earlier if a wave touches `DbtRefreshHandler`.

## Agent Assignment
elixir-agent + dbt.

## Progress Notes
Filed 2026-07-30 by the lead during Wave 4, from #334's follow-up finding. Independently confirmed: `git log -S"reviews_scraped"` identifies `45ddcc44` as the commit that removed the emitter (`- event_type: "enrichment.reviews_scraped"`), and both dbt models still exist on disk.

**Built 2026-08-09 (Wave 11, 11f).** Direction KEEP per the 2026-08-07 owner ruling. `Registry` gains `@pending` (type → reason, compile-checked ⊆ catalogue) + `pending_event_types/0`; the completeness test gains the inverse guard (catalogued ⇒ emitted ∨ pending ∨ named-indirect) and a stale-pending guard (an emitter appearing forces the entry out of pending). The `NOTE:` comment at the registry entry is gone, replaced by the checked designation.

**Wave assignment (owner-approved 2026-07-31): Wave 11.**
Scheduled as item **11f**, beside **11e** (wire the bookstore-events vertical): both are the same decision in opposite directions — 11e wires a vertical that was built but never connected, 11f resolves one whose source was deleted while its consumers remain.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — pending-with-reason is a checked designation, not a comment — the inverse guard fails it in both directions (orphan appears / emitter appears). Owner ruling honoured without keeping dead prose.
