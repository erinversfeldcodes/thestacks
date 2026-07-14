# Issue #203: Author display name in block confirmation

## Summary
Child of the #122 epic (integration `feat/122-e2e`). The block affordance on a blog post currently shows a generic "the author" label because the blog-post payload carries only `user_id`, no display name (ux-review + #193 flag). This issue adds the author's `display_name` to the blog-post payload so the block confirmation names the person.

## User Stories
Polishes US-10.1.2 (Block a User) — no new story claimed.

## Scope Check
- Controllers: 0 new. Endpoints: 0. Proto message + serializer field + small frontend wiring. Single concern. OK.

## Wiring
- [x] User-facing when complete (the block modal names the author).
- [ ] Implementation only.

## Feature-Completeness Pre-Check
n/a — enriches an already-built + claimed story (US-10.1.2, #193). Live-drive rides with E2E #199.

## Technical Requirements
- Add `author_display_name` (string) to the blog-post proto message + its `ProtoJSON` serializer (source: the post author's `display_name`; join/preload through `op.users`). Field numbers are forever — append. Run `mix proto.sync`; verify `--check` clean.
- Thread the display name from the post payload into `Page/Blog/Post.elm`'s block `Target` and `Components/BlockUserModal.elm` so the confirmation reads "Block <name>?" instead of "Block the author?". Keep a safe fallback to a generic label if the field is absent (backwards-compat).
- GDPR: `display_name` is already personal data covered by erasure/export on `op.users`; ensure no NEW personal-data class is introduced (it's a projection of an existing field into a payload the requester can already see). Run the `gdpr-review` lens.

## Reviewer Context
- **Sequenced AFTER #201** — both change proto messages + run `mix proto.sync`; running in parallel collides on regenerated files. Branch this from the integration tip that already includes #201.
- The frontend `BlockUserModal` already takes a `displayName` (built future-proof in #193) — wiring is threading the value through, not new component work.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API/serializer (post payload includes `author_display_name`) | yes | ❌ serializer test asserts field present + correct (→ ✅) |
| proto.sync drift | yes | ❌ `--check` clean after regen (→ ✅) |
| Elm (modal shows the name; fallback when absent) | yes | ❌ elm-test (→ ✅) |
| gdpr | yes | ❌ gdpr-review lens clean (→ ✅) |

## Definition of Done
- [ ] Blog-post proto + serializer emit `author_display_name`
- [ ] `mix proto.sync --check` clean; decoders regenerated
- [ ] Block modal names the author, with a safe generic fallback
- [ ] Serializer test + elm-test (named + fallback) pass
- [ ] gdpr-review lens clean
- [ ] `just verify` passes

## Dependencies
Epic #122. **Hard: #201** (proto/serializer sequencing). Consumes #193's modal.

## Agent Assignment
elixir-agent (proto + serializer) + a small elm follow (modal wiring).

## Progress Notes
- 2026-07-14: Created from the ux-review of #193 (fix-everything decision). Sequenced after #201 for proto coordination.
