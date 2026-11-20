# ADR 027: Writing Assistant Architecture (the design, as amended by what shipped)

**Status:** PROPOSED — awaiting owner ruling (the decision section at the end).
**Date:** 2026-11-20
**Deciders:** Platform owner (ruling requested)
**Technical area:** Writing assistant (Socratic editor panel), LLM platform
**Builds on:** `docs/writing-assistant-design.md` (the behaviour/RAG/eval design, which this
ADR adopts as amended below); ADR 017 (GDPR data model — delivered); ADR 026 + addendum §4
(one substrate); `docs/vision-embedding-substrate.md` (the serving story); ADR 001 (vendor
posture); the 2026-11-17 responsiveness ruling (honest waits over keep-warm spend).

---

## 1. What is being decided

The writing-assistant design document is thorough and largely right, but it predates four
decisions and deliveries that contradict parts of it. This ADR adopts the design WITH those
amendments, names the model stack as a ruled (revisitable) choice, sets the promotion rule,
and lists the preconditions that must exist before a reader sees a generated word.

## 2. The amendments (design doc § references)

1. **No second sidecar, no second GPU (§3, §13).** The doc aspires to an
   `apps/writing_assistant/` Modal sidecar. Superseded by the one-substrate ruling: dialogue
   and classification are Together API calls (no container of ours), and embeddings run on
   the EXISTING vision CPU front door per the serving story. The issue breakdown in §13
   re-scopes accordingly.
2. **No keep-warm pings (§4 "Latency Considerations").** Contradicted by the 2026-11-17
   responsiveness ruling (honest waits, never idle spend) — and moot: Together's serverless
   API has no container of ours to keep warm. Time-to-first-token via SSE stands.
3. **The data model is DELIVERED — and needs four refinements before retrieval works as
   designed.** Delivered since July: `op.embeddings` (vector(1024), HNSW, user-FK CASCADE),
   `op.book_content_chunks`, `op.blog_assistant_sessions`, `op.turn_feedback`,
   `op.retrieval_log` (with its PII-excluded staging pattern), and the `writing_assistant`
   consent type with revocation-triggered purge — §11's erasure/export claims are citations,
   not plans. NOT delivered: `op.prompt_templates`. And the live `op.embeddings` shape
   (verified 2026-11-20) lacks what the grounding contract consumes:
   (a) the CHUNK TEXT itself — nothing to retrieve as a span without re-deriving from
   source at query time, with embed-vs-display boundary drift; (b) span provenance
   (`chunk_index`/offsets) for honest citations; (c) a `model` column, so a re-embed is a
   coexisting backfill rather than a destructive one (the model-identity lesson, already
   encoded in the visual-embeddings spec); (d) an FTS side for §7's hybrid RRF (the
   `op.books` tsvector pattern). All additive, all on an already-cascading personal table,
   all under the gdpr-review lens (a content column makes export summarise it) — together
   they are migration-path item 0.
4. **The eval bar rose (§12).** The rubric stands, but promotion follows the W7e/eval
   culture as practised this campaign: a RECORDED golden-set baseline, per-dimension (never
   blended), a gate that demonstrably reds on a planted violation, and faithfulness judged
   against RETRIEVED SPANS (US-12.3.4) — never the producer's own confidence.

## 3. Model stack — ruled, with alternatives

**Adopt the doc's §4 stack as the starting configuration**: Together AI only (ADR 001
posture: one vendor per capability), `Llama-Guard` as the inline `safety_model`, an
8B-class classifier in front, a 70B-class instruct model for dialogue.

- **Alternative: self-hosted dialogue model (Modal GPU)** — REJECTED for v1: violates the
  one-substrate ruling's economics (a second always-warm-ish GPU for conversational latency
  is exactly the idle-tail problem the vision work just measured at ~91 s billed per wake),
  and the assistant's latency envelope (streamed tokens into an editor) suits a serverless
  API.
- **Alternative: a second vendor for dialogue** — REJECTED: ADR 001's one-vendor-per-
  capability posture; Together already carries the association path and the budget/fuse
  machinery extends to it.
- **Cost shape, measured not guessed:** a Socratic turn is order-of a few thousand tokens
  round trip — fractions of a cent on 70B-class serverless pricing. ⚠️ The PRECISE per-turn
  cost is recorded at first light through the billed-truth machinery (the cost page's
  provider line + per-turn telemetry), not copied from a rate card into this ADR, because
  rate cards drift and bills do not lie.

## 4. Grounding contract (the product's one hard rule)

Every assistant turn is grounded in retrieval over the author's OWN corpus (their posts,
shelf intent, reading history per consent). A turn that retrieved nothing says so and asks
rather than asserts; retrieved spans are the faithfulness gate's evidence. Ghost-writing
refusal (§2's anti-sycophancy) is enforced in the output pass and red-teamed per US-12.3.3.

## 4a. The author's own corpus: ingestion and annotation (owner requirement, 2026-11-20)

The assistant's knowledge is not only what was published on the platform: the author
imports UNPUBLISHED writing (PDF, ePub, DOCX, Markdown, plain text) into their corpus,
annotates it, and the assistant grounds in it like anything else.

- **Data class: the most sensitive text the platform will hold.** Unpublished drafts are
  personal by default and intimate in practice. They enter through the DEPLOYED app's
  consent-gated path (never tooling that writes straight to the database past the consent,
  audit and purge machinery), live under the `writing_assistant` consent — revocation
  purges them with the rest — cascade on erasure, appear in export (text included,
  vectors summarised), and never reach event_log, audit payloads, or the warehouse
  (the `retrieval_log.query` exclusion pattern governs).
- **One pipeline for published and imported alike:** extraction (on the Python CPU front
  door — the PDF/ePub libraries live there naturally) → chunking per §6 → the item-0
  substrate (chunk text, span provenance, model stamp) → hybrid retrieval. `source_type`
  distinguishes; nothing else forks.
- **Annotation is first-class, not an afterthought:** per-work and per-chunk annotations
  (topic tags, exemplar quality, DO-NOT-RETRIEVE redaction, notes) stored as structured
  data beside the chunks. The authoring tool may run locally, but it writes THROUGH the
  API as the author — annotations are corpus data with the same GDPR standing as what
  they annotate. The same mechanism authors the §6 golden set.
- **This is the LoRA path's missing substrate.** The Phase-7 expert-corpus item (adapter
  training, grant/revocation, extraction eval) was excluded for lack of exactly this
  pipeline; it stays Phase 7, but ingestion + annotation is designed so adapter training
  consumes it without rework. "Training" in v1 means retrieval grounding; fine-tuning
  remains a later, separately-ruled step.
- ⚠️ **Interaction with the §3 model question:** unpublished drafts transiting a
  third-party inference API is a materially sharper version of the privacy trade than
  published posts — weight accordingly when ruling on local-first.

## 5. Preconditions (no reader sees generated text before these exist)

| Precondition | Story | State |
|---|---|---|
| Budget ceiling on the Together path | US-12.3.1 | GAP — fuse exists, budget does not |
| Call log / replay | US-12.3.2 | future-spec |
| Guardrails + red-team record | US-12.3.3 | spec; LlamaGuard inline is the start, not the record |
| Faithfulness measurement | US-12.3.4 | spec |
| Consent gating | ADR 017 / `ConsentCheck` | DELIVERED |
| Retrieval substrate | serving story | DELIVERED (embeddings producer is part of the build) |

## 6. Promotion rule (numeric, wired, able to fail)

- A golden set (owner-authored dialogues, per §12's rubric dimensions) with a RECORDED
  per-dimension baseline before any UI ships; regressions per-dimension refuse promotion.
- Faithfulness: every golden turn's claims traceable to its retrieved spans; the gate reds
  on a planted unfaithful output (the planted run quoted in the implementing issue's DoD).
- The gate lives beside `mix eval.vision` / `mix eval.cascade` as `mix eval.assistant`,
  sandboxed the same way, refusal semantics shared (INCOMPLETE is never a verdict).

## 7. Migration path

§13's issue breakdown re-scoped by the amendments: (0) the four schema refinements above +
`op.prompt_templates` + the imported-works and annotation tables (§4a), as one gdpr-reviewed
migration change; (1) embeddings producer on the existing substrate + backfill (model-stamped
per refinement c); (1a) ingestion + annotation tooling (§4a; filed as its own issue); (2) retrieval + hybrid search (§5–§7 unchanged); (3) the budget
precondition (US-12.3.1); (4) `mix eval.assistant` + golden set; (5) the editor panel +
SSE streaming (riding the upload stream's ack-first pattern); (6) guardrails/observability
per their stories. Each lands as its own scoped issue at build time; none starts before
this ADR is ruled.

## Ruling

**Status: AWAITING OWNER DECISION.**

- [ ] Adopt the design-as-amended (sections 2–4) — yes / amend
- [ ] Preconditions list (section 5) binding before first reader exposure — yes / amend
- [ ] Promotion rule (section 6) — yes / amend
- [ ] Anything above de-scoped or re-sequenced — owner's note
