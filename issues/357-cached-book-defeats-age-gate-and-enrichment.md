# Issue #357: Two writes change a book and never evict it — one is an age-gate bypass window

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by #355's sibling sweep and confirmed by the lead. `BookDetailCache` is now invalidated on `book.created`, `book.cover_confirmed`, `books.edition_merged` and `blog.associations_suggested`. Two write paths that change what `GET /api/books/:id` returns still emit **nothing** and evict **nothing**:

| Write path | Emits | Consequence |
|---|---|---|
| `Books.set_visibility_tier/3` (age gate) | nothing (telemetry only) | **the raised gate is not enforced for up to the 5-minute TTL** |
| `Stacks.Workers.EnrichBookJob` | nothing (`Events.` appears 0× in the file) | an enriched title/description/author stays stale for the TTL |

Both were **driven, not read** — #355 ran a temporary probe against a live database:

```
PROBE-B  first read tier="public"          PROBE-C  first read title="ISBN 9780451524935"
PROBE-B  age-gate response tier="age_gated"   PROBE-C  db title="Nineteen Eighty-Four"
PROBE-B  db tier="age_gated"               PROBE-C  second read title="ISBN 9780451524935"
PROBE-B  second read tier="public"   ← the gate is not applied
```

## Why B is the serious one
`StacksWeb.BookController.render_book_detail/3` calls `AgeGate.enforce(conn, book)` on the book returned by `cached_or_fetch/1` (`book_controller.ex:223-231`). So the gate is evaluated against **the cached copy's `visibility_tier`**, not the current one. Raising a book to `age_gated` therefore leaves it served ungated until the entry expires — `@ttl_ms 300_000`, i.e. **five minutes**.

That is an enforcement window on a content-safety control, which is a different severity class from a stale title.

**Bounded today, not fixed today.** Age-gating ships dark per ADR-020 — `config/runtime.exs:118` reads `AGE_GATING_ENABLED`, which is **not set in production**, so no reader is currently exposed. The window opens the moment that flag is turned on, which is exactly when nobody will be looking for a caching bug. Lead-verified: `set_visibility_tier/3` contains no `Events.emit`, no `BookDetailCache` reference, and its only side effect is telemetry.

## Why it survived
The same reason #355's two bugs did: `CacheInvalidationHandler` is wired to a fixed list of event types, and a write path that emits no event is invisible to it. There is no test that asks *"does every write that changes `get_book_detail/1` evict the entry?"* — the handler's tests each assert one event type in isolation.

Note the precedent from #355: `book.cover_confirmed` **was** subscribed and still broken, because the emitter set `aggregate_id` to an *edition* id while the handler invalidated `aggregate_id` as if it were a work id. Its test passed throughout because it hand-built an event shape the emitter has never produced. So "it is in the registry" is not evidence the invalidation works.

## User Stories
US-4.x (age gating / ADR-020), US-1.1.2 (enrichment visibility).

## Goal
Every write that changes what `get_book_detail/1` returns evicts the entry it invalidates — and that property is asserted once, structurally, rather than per-event.

## Scope Check
Two write paths + one or two new event types (registry + payload contract) + a structural test. If the structural test turns up more paths, report before absorbing them.

## Wiring
Router wiring: none. Emitter → registry → `CacheInvalidationHandler` → `BookDetailCache`; the missing hop is the emit.

## Technical Requirements
1. **Emit on `set_visibility_tier/3` and route it.** ⚠️ The age-gate case may deserve more than eventual invalidation — a 5-minute window on a safety control is arguably not acceptable even asynchronously. Consider whether this path should evict **synchronously** in addition to emitting, and state the reasoning either way. The event is still wanted for the audit trail.
2. **Emit on `EnrichBookJob`** when it updates the work or its primary edition.
3. **Carry the WORK id in the payload.** #355 established the rule the handler's moduledoc now states: the cache is keyed by work, and `aggregate_id` is only the work id for `book.created`. Do not repeat the `cover_confirmed` mistake.
4. **Assert the property, not the instances.** Add a test that enumerates the write paths mutating a work or its editions and fails when one has no invalidation route — otherwise the next such path reintroduces this silently. If a full enumeration is impractical, say so and explain what you did instead.
5. **Probe each fix the way #355 did** — read (populating the cache), write, read again. ⚠️ Writing into a **cold** cache passes regardless of how invalidation is wired, so the first read is load-bearing.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`**, then `git merge --ff-only <wave branch>` (local, unpushed; no `git fetch`).
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long suites. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`. **Stage incrementally.**
- ⚠️ Adding an event type means #334's registry completeness test and the closed-enum coverage gate apply; `bash scripts/lint-proto.sh` checks FIVE targets.
- ⚠️ Age-gating is **human-marked and ships dark** (ADR-020). There is no "Verify" affordance by design. Do not add one; do not enable the flag in prod.
- Related: **#355** (fixed the merge and cover-confirmed halves; found these two), **#334** (registry truth).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Security | yes | ❌ raising an age gate takes effect on the **next** read — probe: read, raise, read |
| API calls | yes | ❌ an enriched title is visible on the next read |
| Event flow | yes | ❌ both new event types routed; payload carries the work id |
| Regression | yes | ❌ structural test: a write path with no invalidation route fails |
| Others | no | n/a |

## Definition of Done
- [ ] `set_visibility_tier/3` invalidates; sync-vs-async decision stated — evidence: diff + reasoning
- [ ] `EnrichBookJob` invalidates — evidence: diff
- [ ] Payloads carry the work id — evidence: contract + test
- [ ] Structural test over write paths — evidence: test name + probe
- [ ] Read-write-read probes for both — evidence: transcripts
- [ ] `staff-review` verdict recorded below

## Dependencies
**#355** (built the invalidation wire and found these). Needs an owner wave assignment. ⚠️ The age-gate half should land **before** `AGE_GATING_ENABLED` is ever turned on in production.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead from #355's sibling sweep. Independently verified: `book_controller.ex:223-231` enforces the gate on the value from `cached_or_fetch/1`; `set_visibility_tier/3` contains no `Events.emit` and no `BookDetailCache` reference; `book_detail_cache.ex:12` sets `@ttl_ms 300_000`; `config/runtime.exs:118` gates the feature on `AGE_GATING_ENABLED`, unset in production.
