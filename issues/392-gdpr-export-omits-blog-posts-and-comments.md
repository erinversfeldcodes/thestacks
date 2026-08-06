# Issue #392: GDPR export omits the reader's blog posts and comments (portability gap)

## Summary
`Stacks.GDPR.Export.export_user_data/2` exports **no blog data at all** — not `op.blog_posts`,
not comments, not their associations — even though `op.blog_posts.body` is the reader's own
free-text writing and squarely within the GDPR **right to portability**. Surfaced 2026-08-06 while
writing the POSSE/Substack story (US-6.2.1) in Wave 10; pre-existing (not introduced by Wave 10).

## Goal
A user's own blog posts (and comments) appear in their data export, so the export is a truthful
copy of their portable personal data — consistent with how `post_comments.body` was handled in the
#121 GDPR epic.

## Scope Check
`GDPR.Export` + its test. One context. Under the bar. (Erasure of blog data is a SEPARATE check —
confirm `GDPR.Deletion` already reaches `blog_posts`/comments; if not, that is its own P0.)

## Wiring
`export_user_data/2` assembles the payload; add a `blog:` (posts + comments) section sourced from
the user's own rows. Free-text bodies are included (portability), summarised only if huge.

## Technical Requirements
1. Add the user's `blog_posts` (incl. `body`) and their comments to the export payload.
2. Extend the export test to assert a seeded post/comment appears in the output.
3. ⚠️ **Verify erasure first**: confirm `GDPR.Deletion.delete_user_data/1` already DELETES/anonymises
   blog posts + comments (free-text must be deleted, not author-nulled — the #185 lesson). If it does
   not, that erasure hole is a **P0** and must be fixed in the same change.
4. Run the `gdpr-review` lens over the diff.

## Definition of Done
- [ ] Blog posts + comments in the export payload — evidence: test asserting seeded content present
- [ ] Erasure reachability of blog data confirmed (or fixed) — evidence: deletion test / schema-guard
- [ ] `gdpr-review` verdict recorded

## Dependencies
Surfaced by US-6.2.1 (Wave 10). Belongs with the deferred GDPR revisit. **Assigned to Wave 11.**

## Progress Notes
Filed 2026-08-06 from the Wave 10 POSSE-story GDPR flag. Portability gap; pre-existing.
