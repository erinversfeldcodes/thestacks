# Issue #205: US-12.2.1 — real writing assistant (deferred AI + ownership contract) [FUTURE]

## Summary
TRACKING issue for the real AI behind the writing-assistant chat endpoint, which #184/#123 deferred in prose but never filed. This makes the deferral tracked per completion-bar item 3. **This is FUTURE work — not built on the current branch.**

## User Stories
- US-12.2.1 (real writing assistant chat)

## Goal
The `POST /api/blog/posts/:id/chat` endpoint drives a real writing-assistant conversation grounded in the user's own content, while preserving the ownership + consent guarantees already in place.

## Scope Check
- Touches `blog_controller` chat/2 + AI client + a worker → likely 1–2 controllers. OK, but re-check at pickup.
- Adds 0 new endpoints (chat route already exists). OK.
- Real AI + retrieval likely exceeds 300 LOC → **split into design pass + build phases at pickup.**
- Combines AI + retrieval + consent + purge — enumerate as phases, not one PR.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] Route already wired (`POST /api/blog/posts/:id/chat`); this replaces the stub behind it.

## Feature-Completeness Pre-Check
The endpoint + ownership/consent scaffolding ship; the AI behind it is a stub → this story is intentionally ❌ (build in-scope when picked up).

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-12.2.1 real WA chat | `blog_controller.ex:144` chat/2 → `check_ownership` (`:152`) + consent-gated pipeline (`:139`) → **stubbed AI** | ⬜ FUTURE | ❌ deferred | build in-scope when scheduled |

Verdict: ❌ missing — deliberately deferred; this issue exists to track it.

## Technical Requirements
- Replace the stub in `blog_controller.ex` chat/2 with a real writing-assistant model call.
- **KEEP the defensive per-post ownership check** already added: chat/2 uses `check_ownership(post, user)` (`blog_controller.ex:152`, `check_ownership/2` at `:171-172`). The real AI reads the post body — without this, a consenting user could chat about another user's post. This guard must remain when the AI is wired.
- Keep consent-gating (pipeline-level, `blog_controller.ex:139`) — no chat without WA consent (US-8.3 / #184).
- Retrieval grounded over the **user's own embeddings only** (no cross-user leakage).
- Reconcile with `WritingAssistantDataPurgeWorker` — purge must remove any AI/chat-derived personal data (GDPR erasure reachability; run the `gdpr-review` skill on the diff).

## Reviewer Context
- The ownership check predates the real AI — it was added defensively; do not remove it as "redundant" when wiring the model.
- Any new personal data (chat transcripts, embeddings) must be erasure-reachable, export-included, consent-gated, and kept out of event_log/audit/warehouse — `gdpr-review` is mandatory.
- No vLLM/H100 without the eval framework (see project vision baseline note).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API calls (chat/2 real path) | yes | ❌ FUTURE |
| auth & middleware guards (ownership + consent gate) | yes | ❌ FUTURE — assert ownership 403 + consent 403 |
| external service calls (AI model) | yes | ❌ FUTURE — mock + live-stack |
| Oban jobs (WritingAssistantDataPurgeWorker) | yes | ❌ FUTURE — purge removes chat PII |
| event flow / metrics | yes | ❌ FUTURE |
| 1–13 remaining | at pickup | to verify |

Verdict: ❌ FUTURE — this is a tracking baseline; regenerate when scheduled.

## Definition of Done
- [ ] Real writing-assistant model wired behind `POST /api/blog/posts/:id/chat`.
- [ ] Per-post `check_ownership` retained and asserted (403 on non-owner).
- [ ] Consent-gating retained and asserted (403 without WA consent).
- [ ] Retrieval scoped to the requesting user's own embeddings; cross-user leakage test.
- [ ] `WritingAssistantDataPurgeWorker` purges chat-derived personal data; `gdpr-review` passes.
- [ ] **Feature-Completeness Pre-Check ✅ for US-12.2.1** (driven live) when built.
- [ ] Every behaviour has a validation path.
- [ ] Tests written and passing.
- [ ] Standards compliance verified (`just verify` passes).
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — all 7 items.

## Dependencies
#184 (WA consent), #123 (blog), GDPR foundation (#183). AI eval framework prerequisite.

## Agent Assignment
elixir-agent + elm-agent (future).

## Progress Notes
FUTURE — filed to track the deferral. Not built on this branch.
