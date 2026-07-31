# Issue #353: Account erasure reports `:ok` while the user's `op.uploaded_images` rows survive

## Summary
`Stacks.GDPR.Deletion.delete_user_data/1` returns `:ok` while every `op.uploaded_images`
row belonging to the erased user is still in the table, still carrying their `user_id`
and the storage key to their image bytes. The erasure schema-guard is GREEN throughout,
because `uploaded_images.user_id` is a bare `:binary_id` column with **no foreign key to
`op.users` at all** — so the guard, which enumerates `op.*` FKs *referencing* `op.users`,
never inspects the table. Found by the `gdpr-review` lens during #345; **pre-existing, not
introduced by it.**

## User Stories
None directly — this is the standing GDPR right-to-erasure invariant (US-13.x family /
`docs/technical-architecture.md` GDPR section).

## Goal
A user who erases their account has their uploaded-image rows and objects gone when
`delete_user_data/1` returns, and the schema-guard fails if a future table repeats this
shape (a user-scoping column with no FK).

## Scope Check
One migration + one erasure step + one guard extension. No controllers, no endpoints.
Within a single issue.

## Wiring
Router wiring: implementation-only — no user-facing surface. The behaviour change is
inside `delete_user_data/1` and the `AccountDeletionJob` that runs it.

## Feature-Completeness Pre-Check
n/a — no user stories; this is an invariant repair, not a feature.

## Technical Requirements

### The evidence
A probe run against `stacks_test` on 2026-07-31 (insert one `uploaded_images` row for a
user via a raw changeset — deliberately NOT through the moved upload code — then call
`Deletion.delete_user_data/1`):

```
erasure result      : :ok
image rows BEFORE   : 1
image rows AFTER    : 1
row survives?       : true
surviving user_id   : "cfdedc53-f4b1-4951-b9d8-f5fa78b10f7d"
surviving path      : "uploads/probe"
export mentions img : false
```

Live FK check — `op.uploaded_images` has FKs to `books` and `book_editions` only:

```
uploaded_images_book_id_fkey|books|a
uploaded_images_book_edition_id_fkey|book_editions|n
```

`apps/core/priv/repo/migrations/20260401074249_add_user_id_to_uploaded_images.exs:9`
adds the column as `add_if_not_exists :user_id, :binary_id` — no `references(...)`.
`apps/core/lib/stacks/gdpr/deletion.ex` has no `uploaded_images` step (its Multi steps are
bookshelves → history → placements → feed_cache → bookshelves → comments → sessions →
user → scrub_event_log → …).

### Severity and the bound
**P1, not P0.** `Stacks.GDPR.ImageRetention.cleanup_expired_images/0`
(`apps/core/lib/stacks/gdpr/image_retention.ex:32`) deletes the storage object *and* the
row once `expires_at < now()`, and `expires_at` is set to upload + 30 days. So the residue
is bounded at ~30 days rather than indefinite. What is broken is the **on-request**
guarantee and the honesty of the return value: erasure reports success over data it did
not erase. #185 explicitly deferred this — `issues/complete/185-gdpr-deeper-deletion-cascade.md:75`
calls object-storage retention "a separate concern" and points at the TTL sweep — but a
time-based sweep is not the right to erasure.

### The fix
1. Migration: make `uploaded_images.user_id` a real FK to `op.users` with
   `on_delete: :delete_all`. It is not free-text, so CASCADE fully de-links; no allowlist
   entry needed. Watch for pre-existing orphan `user_id` values that would fail the
   constraint — backfill-or-null them in the same migration.
2. Delete the R2 objects for the user's images inside `delete_user_data/1` before the
   cascade removes the rows (the rows are the only pointer to the storage keys — once
   they cascade, the objects are unreachable and leak until nothing ever collects them).
   Reuse `ImageRetention`'s `delete_storage_objects/1` path rather than a second copy.
3. Extend the schema-guard so a `*_id` column *named after* `op.users` with **no** FK is
   itself a failure — otherwise the next table added this way is invisible again. This is
   the part that stops the class, not just the instance.
4. Decide whether `export_user_data/2` should list the user's images (ids + uploaded_at +
   status, never the bytes). Probably yes; state the decision either way.

## Reviewer Context
- `apps/core/lib/stacks/gen/books/uploaded_image.ex` is **proto-generated** — do not
  hand-edit. A column-shape change belongs in `proto/persisted.exs` + `mix proto.sync`.
- The schema-guard lives in `apps/core/test/stacks/gdpr/deletion_test.exs:446`
  ("erasure completeness — schema-level guard (#185)"), with a documented SET NULL
  allowlist. This issue adds a *third* category to it: user-scoping column, no FK.
- ⚠️ A green schema-guard is exactly what hid this. Any fix must be proven by a test that
  **fails before it** — insert an image row, erase, assert zero rows — not by the guard alone.
- The 30-day TTL means a naive "is it gone?" test written days later passes for the wrong
  reason. Assert immediately after `delete_user_data/1` returns.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| GDPR | yes | ❌ erasure test: image row + object gone when `delete_user_data/1` returns |
| Regression | yes | ❌ schema-guard extended to catch a user-scoping column with no FK; must fail on today's schema |
| Migration | yes | ❌ FK added; orphan `user_id` values handled; `just run just verify` green |
| Export | yes | ❌ decision recorded, and asserted either way |
| Others | no | n/a |

## Definition of Done
- [ ] `uploaded_images.user_id` is a CASCADE FK to `op.users` — evidence: migration + `pg_constraint` query
- [ ] Storage objects deleted before the cascade — evidence: test asserting the storage mock saw the deletes
- [ ] Erasure test fails on the pre-fix code and passes after — evidence: both runs
- [ ] Schema-guard extended to the no-FK case, and fails on today's schema — evidence: the red run
- [ ] Export decision recorded and asserted — evidence: the test
- [ ] `just run just verify` green — evidence: output

## Dependencies
None. Independent of #345, which only moved the upload functions between modules and
touched no schema, migration, or GDPR code.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 from the `gdpr-review` lens run during #345. #345 is a pure module
extraction and neither caused nor worsened this; the review simply asked the erasure
question against a real database and got a real answer.
