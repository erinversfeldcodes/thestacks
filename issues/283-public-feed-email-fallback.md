# Issue #283: Public Atom feeds fall back to the owner's email as the display name

## Summary
`Stacks.Feeds.build_atom_xml/2` uses `user.email` as the feed's display name when
`display_name` is nil — so a platform-visible bookshelf feed can expose the owner's **email
address in a public Atom document** (author/title fields), which RSS readers and crawlers will
cache and index. Pre-existing from #264 (found during #266's hardening review, 2026-07-23).
Email is personal data (GDPR tier: personal); publishing it in a public artifact is an
unconsented disclosure and violates the project's "no PII in public surfaces" posture
(ADR-021 §4 analogue for feeds).

## User Stories
US-6.1 (Subscribe to Shelf RSS Feeds) — privacy hardening.

## Goal
A public feed never contains the owner's email. Nil `display_name` falls back to a neutral
label (e.g. "A Stacks reader" / the handle if claimed — decide against the voice guide), and
regenerated/cached feeds reflect the fix.

## Scope Check
One context function + tests; possibly a cache-busting regeneration note. Well under limits. ✅

## Feature-Completeness Pre-Check
n/a — privacy defect fix on a shipped feature. Proving gate: a nil-display-name user's public
feed fetched live contains no email anywhere in the XML.

## Technical Requirements
1. Replace the email fallback in `build_atom_xml/2` (and anywhere else feeds read user identity
   — grep the feeds context for `email`) with a neutral fallback; prefer `handle` when claimed,
   else a generic label. Never any email-shaped string.
2. Tests: nil-display-name feed contains no `@` /email; display-name and handle paths asserted.
3. Cached copies: `op.feed_cache` may hold already-rendered XML with emails — bust/regenerate
   affected rows in the migration/fix (or document why TTL/regeneration makes this moot, with
   the actual TTL cited).
4. Run the `gdpr-review` lens on the diff (public-surface PII removal).

## Reviewer Context
- #266 made cache-write failures non-fatal and `put_cache/3` changeset-based — build on that.
- Feed visibility gating (`:not_public`) already exists; this issue is about the CONTENT of
  legitimately-public feeds.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Context (L3) + content assertion | yes | ❌ → ✅ — no-email-in-XML tests incl. nil fallback |
| Cache (L8) | yes | ❌ → ✅ — stale cached XML busted or TTL-argued |
| E2E | optional | live feed fetch asserting no email for a nil-name user |

## Definition of Done
- [ ] No email in any generated feed XML (all fallback paths) — evidence: tests + live fetch
- [ ] Stale cached feeds handled — evidence: migration/regeneration or cited TTL rationale
- [ ] `gdpr-review` lens run — evidence: findings or clean statement
- [ ] `just verify` passes

## Dependencies
Builds on #266 (this branch). Related: #264 (origin).

## Agent Assignment
`elixir-agent` + `security-agent` review lens.

## Progress Notes
Filed 2026-07-23 from #266's hardening review (pre-existing since #264).
