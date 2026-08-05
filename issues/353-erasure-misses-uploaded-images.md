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
- [x] `uploaded_images.user_id` is a CASCADE FK to `op.users` — evidence: migration `20260805100000` (`ADD CONSTRAINT … ON DELETE CASCADE NOT VALID`, orphans pre-deleted) + `20260805100100` (`VALIDATE CONSTRAINT`, `@disable_ddl_transaction`, squawk-safe two-step). The FK's existence is proven at the pg layer by the schema-guard test below (green ⇒ the anti-join finds the FK); squawk gate exit 0.
- [x] Storage objects deleted before the cascade — evidence: `deletion_test.exs` "deletes the R2 object for each of the user's images" via a `RecordingStorage` backend; `delete_user_data/1` collects `storage_path` first, calls `ImageRetention.delete_storage_objects/1` (reused, not copied) before the `:delete_uploaded_images` step. Mutation-probed 2026-08-05: neutering the delete call reddens the test (`assert_received {:storage_delete, "uploads/obj-a"}` → empty mailbox); reverted → green.
- [x] Erasure test fails on the pre-fix code and passes after — evidence: RED against the pre-#353 schema (migrations moved out, `deletion.ex` stashed to HEAD, test DB re-migrated) — `deletion_test.exs:474` `assert … :count == 0` failed `left: 1 / right: 0` (row survived); GREEN after fix (39/0).
- [x] Schema-guard extended to the no-FK case, and fails on today's schema — evidence: RED against today's schema before the FK migration — `Offenders: ["uploaded_images.user_id"]` (verified the only offender; the other 11 `op.* user_id`/`*_user_id` columns already carry FKs); GREEN after migration.
- [x] Export decision recorded and asserted — evidence: `export.ex:66-79` includes `uploaded_images` as `id + uploaded_at + status` only (decision documented: never bytes/`storage_path`/URL); `gdpr_test.exs` asserts exactly those 3 keys, cross-user isolation, and that the encoded JSON contains neither `secret-key` nor `uploads/`.
- [x] `gdpr-review` verdict: **PASS** — 2026-08-05, recorded in Progress Notes; closes the pre-existing P0 (erasure) + P1 (export). One out-of-scope P2 (warehouse `storage_path` in `stg_uploaded_images`) filed as **#386**.
- [ ] `just run just verify` green — evidence: output (pending — folded into Wave 7's `just ci` integration re-run, in flight)

## Dependencies
None. Independent of #345, which only moved the upload functions between modules and
touched no schema, migration, or GDPR code.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 from the `gdpr-review` lens run during #345. #345 is a pure module
extraction and neither caused nor worsened this; the review simply asked the erasure
question against a real database and got a real answer.

## Lead verification and the generalisation (2026-07-31)
Independently confirmed against a live schema: `op.uploaded_images` carries exactly two foreign keys —
`uploaded_images_book_id_fkey` and `uploaded_images_book_edition_id_fkey` — and **none to `op.users`**,
despite holding a `user_id`.

**The important part is not this table, it is the guard's shape.** The erasure schema-guard enumerates
FKs that *reference* `op.users` and checks each is CASCADE or an allowlisted SET NULL. That makes it
strong against the wrong-delete-behaviour defect — verified during #335's review, where weakening one
FK to `NO ACTION` reddened it with `Offenders: ["auth_token_families.user_id (a)"]` — and **structurally
blind to a column that should be an FK and is not**. A guard that audits the edges that exist cannot
see a missing edge.

So the fix in Technical Requirement 3 (extend the guard) is the load-bearing half of this issue, not a
tidy-up. Whatever shape it takes, it should answer: *which columns look like they identify a user but
have no FK to `op.users`?* — and the probe for it is to add such a column and confirm the guard reddens.

Two related notes: **#335** removed two hand-rolled deletion steps precisely because the guard covered
those FKs, which is correct *for FKs that exist* — that reasoning does not extend to this case, and the
distinction is worth keeping straight when reading either issue. And the ~30-day TTL sweep that bounds
this is `Stacks.GDPR.ImageRetention.cleanup_expired_images/0`; it deletes on `expires_at`, which is a
retention policy, not an erasure guarantee — a reader who asks to be forgotten should not have to wait
out a TTL.

## Independent corroboration, 2026-08-02 (#351)
Re-discovered from scratch by the #351 agent's own `gdpr-review` pass, with no knowledge of this
issue: same table, same missing FK (`20260401074249_add_user_id_to_uploaded_images.exs` adds
`user_id` as a bare `:binary_id`), same reason the schema-guard stays green, same conclusion that
`ImageRetention`'s 30-day sweep is *retention* and not *erasure*. Two independent passes reaching
the same P0 raises confidence this is real rather than a reading error.

⚠️ **#351 also raises the severity.** Its upload inbox (`GET /api/uploads/inbox`) turns these rows
from an invisible residue into a **listed, first-class reader-facing surface**. It also notes that
`uploaded_images` is absent from `GDPR.Export.export_user_data/2` as well as from deletion — so the
export gap should be fixed in the same pass, not treated as separate.

## Pulled into Wave 7 and resolved (2026-08-05)
Owner ruling: the Mode B `staff-review` of the Wave 7 cumulative diff surfaced this as the wave's one
⛔ DESIGN CONCERN — #351 shipped the reader-facing inbox over `op.uploaded_images` while erasure and
export could not reach it — and the owner chose to fix it inside the Wave 7 PR rather than defer to
Wave 11. Implemented as specified: CASCADE FK (two-step squawk-safe migration, orphans pre-deleted),
R2 object deletion before the row cascade (reusing `ImageRetention.delete_storage_objects/1`), export
metadata (`id`/`uploaded_at`/`status` only, no bytes/key), and the class-closing schema-guard.

**`gdpr-review` verdict: PASS** (2026-08-05) — closes the pre-existing P0 (erasure) and P1 (export);
event_log/audit carry counts + UUIDs only; the endpoint is the already-gated `POST /api/gdpr/export`.
One out-of-scope observation — `stg_uploaded_images` projects the raw `storage_path` into the `wh`
staging layer — is pre-existing and filed as **#386** (P2), not folded in (scope-lock).

**`staff-review` verdict: LGTM** (Mode B, 2026-08-05). Every load-bearing assertion was mutation-probed
non-vacuous: the storage-deletion test reds when the delete is neutered (my probe), and both the
erasure test (`left: 1 / right: 0`, row survives) and the schema-guard (`Offenders:
["uploaded_images.user_id"]`) were captured RED against the genuine pre-#353 schema and GREEN after.
The fix resolves the DESIGN CONCERN raised against the wave; no residue is claimed erased that is not.
