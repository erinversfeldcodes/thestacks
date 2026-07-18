# Issue #257: Writing Assistant → Production Bar (AI-native showcase) [EPIC]

## Summary
**Epic.** Finish the writing assistant (US-12.2.1) to a genuine production bar so it is the
AI-native centerpiece of the launch: not just "a real model behind the chat endpoint" (that
core is tracked by **#205**), but the surrounding engineering that makes an LLM feature good
and safe — guardrails + red-teaming, streaming UX with citations + confidence, hybrid
retrieval, LLM observability, and deliberate anti-sycophancy behaviour. Every AI-shaped piece
is gated on the **eval harness** (a keystone dependency, to be filed). This epic wraps #205
and adds the production-bar dimensions as ordered child issues; it is not a single PR.

## User Stories
- US-12.2.1 (Use the Writing Assistant) — real, grounded, safe, streamed.
- US-12.2.2 (Manage Writing Assistant Data) — already delivered via #184/#189; this epic must
  not regress its consent/erasure guarantees.

## Goal
A user in the blog editor gets a Socratic writing assistant that (a) is grounded in **their
own** reading history + shelves and pushes them toward unread books, (b) streams its response
with visible citations and confidence, (c) is guarded against harmful/injected/exfiltrating
prompts and verified by an adversarial red-team suite, (d) is fully observable (every LLM call
logged, scored, replayable), and (e) is deliberately non-sycophantic — all while preserving
the ownership + consent + GDPR-erasure guarantees already in place.

## Epic — child issues (implement in order)
1. **[keystone dependency] Eval harness + labeled dataset** — *to be filed*. LLM-output
   faithfulness (the `docs/data-quality.md` "LLM Faithfulness Trend" panel) + the vision
   cascade eval. Gates every AI item below (and the vision redesign, and Phase 2). Nothing
   AI-shaped here goes green without it.
2. **#205 — real writing-assistant AI behind the chat endpoint** (EXISTS) — the core: replace
   the stub with a real model call, keep ownership + consent guards, user-scoped retrieval,
   GDPR-purge reachability. This epic's foundation.
3. **[child, to file] Hybrid retrieval (pgvector + FTS + RRF)** — semantic + keyword +
   reciprocal-rank-fusion over the user's own embeddings; the grounding quality layer.
4. **[child, to file] Guardrails + adversarial red-teaming** — eval-backed guardrail layer
   (semantic + model-scoring + rules) + a red-team suite (prompt injection, jailbreak, harmful
   output, training-data extraction). Extends the Llama Guard in `writing-assistant-design.md`.
5. **[child, to file] Streaming UX — citations + confidence** — token streaming (SSE), citation
   rendering (which book/passage grounded the suggestion), confidence/uncertainty display,
   graceful hallucination handling.
6. **[child, to file] LLM observability** — every call logged, scored, replayable
   (Langfuse-compatible), structured-output validated; pairs with the eval harness.
7. **[child, to file] Anti-sycophancy behavioural design** — the anti-flattery / friction-as-
   feature system-prompt constraints from `writing-assistant-design.md §2`, with tests.

## Scope Check
- This is an **EPIC** — it exceeds every single-issue bound (multiple controllers/workers,
  well over 300 LOC, AI + retrieval + safety + UX + observability). It MUST be split into the
  child issues above; each child re-runs its own Scope Check + feature-completeness pre-check.
- Do NOT implement this as one PR.

## Wiring
- [ ] Router already wired (`POST /api/blog/posts/:id/chat`); a streaming route (SSE) is added
  by child #5. User-facing when the epic completes.

## Feature-Completeness Pre-Check
<!-- Pre-filled from a 2026-07 state check; re-verify per child at pickup. -->
Current state: the chat endpoint + ownership + consent gate (#184) and a frontend panel
(`Components/WritingAssistant.elm`) exist; the AI behind it is **stubbed** (#205), and the
production-bar dimensions are largely absent (grep found no RRF/hybrid retrieval, no
Llama-Guard/guardrail layer, no assistant SSE stream).

| Dimension | State (file:line) | Verdict | Resolution |
|-----------|-------------------|---------|------------|
| Core AI (grounded chat) | endpoint + guards built; AI stubbed | ❌ | #205 (exists) |
| Hybrid retrieval (RRF) | not found in `apps/core/lib` (grep → 0); embeddings/chunks infra exists | ❌ | child #3 |
| Guardrails + red-team | no Llama-Guard/guardrail code found; designed in `writing-assistant-design.md §4` | ❌ | child #4 |
| Streaming + citations + confidence | chat is plain POST; `WritingAssistant.elm` panel exists but non-streaming | 🟡 | child #5 |
| LLM observability | `ai/budget_tracker.ex` exists; no call-level trace/score/replay | 🟡 | child #6 |
| Anti-sycophancy | in design doc; not verified in code | ❌ | child #7 |
| Eval harness (gate for all above) | not built | ❌ | keystone dependency |

Verdict: ❌/🟡 — deliberately an epic; each dimension is built in its child, eval-gated. No
dimension reaches GREEN via `n/a`.

## Technical Requirements
Per-child (see the child issues); the epic-level invariants that every child must preserve:
- **Ownership + consent guards retained** (per-post `check_ownership`, WA-consent pipeline —
  #205 / #184). The real AI reads the post body; these must not be removed as "redundant".
- **Retrieval scoped to the requesting user's own embeddings** — no cross-user leakage
  (assert with a leakage test).
- **GDPR reachability** — any new personal data (chat transcripts, scores, embeddings) is
  erasure-reachable via `WritingAssistantDataPurgeWorker`, export-included, consent-gated, and
  kept out of `event_log`/audit/warehouse. Run the **`gdpr-review`** skill on every child diff.
- **No architecture/model bet without the eval harness** (project vision-baseline rule).
- **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) per child.

## Reviewer Context
- The per-post ownership check predates the real AI (added defensively) — keep it.
- `gdpr-review` is mandatory on every child touching chat data / embeddings.
- Guardrails/red-team is security-sensitive — involve security-agent.
- Streaming reuses the SSE pattern already used by the upload pipeline (`/upload/:id/stream`).

## Test Audit
<!-- Epic-level baseline; each child carries its own full audit + feature-completeness pre-check. -->
_To be generated per child (via `test-audit`) once that child's feature-completeness pre-check
is ✅. Epic-level expectation: adversarial red-team suite (injection/jailbreak/harmful/
extraction), a cross-user retrieval-leakage test, streaming + citation E2E, faithfulness eval
against the harness, and `gdpr-review` green on every diff._

## Definition of Done (epic)
- [ ] Eval harness (keystone) exists and gates the AI children.
- [ ] #205 core AI shipped; ownership + consent + user-scoped-retrieval asserted.
- [ ] Hybrid retrieval, guardrails+red-team, streaming+citations+confidence, observability, and
      anti-sycophancy each shipped as a child with its own GREEN audit + ✅ feature-completeness.
- [ ] Cross-user leakage test; `gdpr-review` green on every child.
- [ ] The assistant is driven live end-to-end (grounded → guarded → streamed → cited) on a real
      stack; a real user can complete US-12.2.1.
- [ ] `just verify` passes (via `just run`).

## Dependencies
- **Eval harness + labeled dataset** (keystone — to be filed; also gates the vision redesign).
- #205 (core AI), #184 (WA consent), #123 (blog), #183 (GDPR data-model foundation).

## Agent Assignment
Orchestrator-coordinated epic: elixir-agent (AI wiring, retrieval, observability) + security-agent
(guardrails/red-team, gdpr-review) + elm-agent (streaming/citations/confidence UI) +
testing-coordinator (red-team suite, E2E).

## Progress Notes
- 2026-07-16: Filed as the production-bar epic wrapping #205 (core AI). Scopes the writing
  assistant as the launch's AI-native centerpiece; children + eval-harness keystone to follow.
  Coordinate with the other session — #205 is theirs; this epic must not duplicate it.
