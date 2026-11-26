# ADR 027: Writing Assistant Architecture (the design, as amended by what shipped)

**Status:** ACCEPTED (owner ruling 2026-11-20: "ADR 27 is acceptable").
**Amendment 2026-11-21 (owner):** the full build is scheduled as campaign wave 24, and **LoRA is IN-SCOPE for it** — overriding this ADR's original Phase-7 deferral of fine-tuning. The research's gate stands as a HARD precondition: the adapter ships only behind a canary + extraction + membership-inference eval (a 16-rep canary reproduced in full on a 7B LoRA), RAG-only remains the default, and the adapter is handled at the corpus's data classification (erasure reaches it).
**Date:** 2026-11-20 (proposed) / 2026-11-20 (accepted)
**Deciders:** Platform owner
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

**LOCAL-FIRST, pending the eval** (owner ruling 2026-11-20, reinforced by §4b): keep the
assistant inside our own tenancy by default, so the author's unpublished drafts never transit
a third party at inference time — the same posture the vision path already holds, and the
sharper version of it that §4b's threat model argues for. Concretely: a small open dialogue
model (Qwen3-class ~8–14B) on the existing scale-to-zero GPU family, woken per editing session
(an upload-style demand wake, NOT the idle keep-warm the responsiveness ruling banned); the
classifier and the Llama-Guard-class safety pass run local regardless (small, latency-tolerant).

- **The eval decides, not this ADR.** Build §6's golden set and `mix eval.assistant` FIRST, then
  score the local candidate AND a hosted 70B-class reference against the same rubric + billed
  cost-per-session. Local is the default and ships if it clears the per-dimension bar; a hosted
  API (Together, ADR 001's one-vendor posture) is the RECORDED FALLBACK if measurement shows the
  small local model cannot meet the Socratic bar. The choice is made on numbers, the way the
  vision model was.
- **Why not hosted-by-default:** it would send the author's private drafts to a third party at
  every turn — defensible only behind consent, and §4b makes the point that keeping it local
  makes that question disappear. The idle-tail economics that argued against a self-hosted
  dialogue model (~91 s billed per wake) are answered by the per-session demand wake + a small
  model, and are themselves what the eval's cost-per-session line measures.
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

## 4b. The corpus's two hard protections (owner requirement, 2026-11-20 — research-settled)

The deep-research pass is done (`reports/Protecting a private writing corpus.md`, four
cited notes under `research_notes/`). It turns both protections from aspirations into
buildable postures. The one architectural decision it forces: **keep the corpus out of
every artifact the database or a future adapter could hand an attacker.**

1. **Never verbatim — a four-layer gate, because no single mechanism suffices.** The
   assistant may surface a work's key arguments and bibliographic specifics; it may not
   reproduce the prose. A system-prompt rule alone is proven insufficient (it leaks on
   retry, and cannot see text that is in the context window), so: (a) the prompt rule;
   (b) a normalised n-gram + longest-common-substring/subsequence detector of the response
   against the RETRIEVED chunks (research anchor: ~50-token canonical verbatim threshold,
   an 8–50-token gray band, an ACS floor above ~3 words); (c) a detect→rewrite→abstain
   loop; (d) a distinctiveness/allowlist path (entropy/IDF + a structural allowlist) that
   lets bibliographic strings and paraphrased arguments through while blocking distinctive
   prose; (e) an OWNER bypass so the author reads their own text (the Gemini-RECITATION
   false-positive lesson); (f) a CoTaEval-style regression eval. DoD carries a
   planted-verbatim RED run. This is also the hard precondition for any future
   corpus-sharing — grounding for others is citations and arguments only, by construction.

2. **A breach must not read the corpus — and the naive layering is a trap.** The research's
   sharpest finding: the pgvector column is a near-complete copy of the corpus (vec2text
   recovers ~92% of 32-token inputs EXACTLY; bge-m3 being open-weights is the worst case,
   exact encoder in the attacker's hands), and a tsvector/GIN index is the corpus
   transcribed (built-in lexeme extraction). So encrypting only the chunk TEXT while
   vectors and FTS stay plaintext is "redacting the document but shipping its photocopy."
   The posture, strongest-first:
   - **Store vectors AES-GCM-encrypted and run exact brute-force kNN in application
     memory** — at this corpus's scale (10³–10⁵ chunks) this is free and removes plaintext
     vectors from the DB, its backups, and its branches entirely. This is the decisive move
     and it makes encryption-at-rest and semantic search fully compatible (the trade vendor
     schemes are still failing to buy). ⚠️ No published kNN-vs-HNSW benchmark at this scale
     — PROVE the latency on our own corpus before committing, HNSW-on-quantized as the
     fallback.
   - **Default to vector-only retrieval, NO tsvector/trgm index** over corpus text.
   - **App-layer AES-GCM (Cloak) on chunk text + sensitive metadata**, decrypt only top-k
     at prompt assembly; keep decrypted chunks out of logs, traces, caches, event_log,
     audit, warehouse, and preview branches.
   - **Dedicated least-privilege role + RLS, probed under `SET LOCAL ROLE`** (the local
     superuser-bypass lesson — an untested RLS layer is an unproven one).
   - **Erasure deletes rows AND destroys/rotates `CLOAK_KEY` for crypto-shredding**; the
     corpus IS the person under GDPR, so every copy (backups, branches, caches, any future
     adapter, eval logs) is reachable by the same erasure path.
   - Noise/rotation/shuffling are NON-defenses against an open encoder (ALGEN/ZSinvert/
     Zero2Text break them); quantization is the only cheap in-DB hardening and is
     adversarially under-tested, so it is a fallback carrying a documented residual risk,
     not the plan.

3. **LoRA is the sharpest knife — deferred, not forbidden.** A canary repeated just 16×
   reproduced in full on a LLaMA-2-7B LoRA; a hundred-document corpus over a few epochs
   crosses that threshold for EVERY document, and membership inference sits at ~0.9 AUC.
   RAG-only eliminates the weight-memorisation class entirely, which is why v1 is RAG-only.
   Any future fine-tune (the Phase-7 item) uses near-dup dedup + few epochs + low rank +
   dropout, treats the adapter at the corpus's own data classification, and ships ONLY
   behind a canary + extraction + MIA eval.

⚠️ **Proven vs uncertain (carry into the implementing issues):** PROVEN — short-chunk
inversion, geometry-obfuscation failure, tsvector extractability, microsecond top-k
decrypt cost, the 16–32-rep memorisation threshold, RAG's class-elimination. UNCERTAIN,
treat as live until measured — inversion at 256–1000-token chunks (gist-level leakage is
extrapolation), quantization vs alignment attacks, how safe a well-configured LoRA is (two
studies disagree), and the in-app-kNN latency at our scale.

## 5. Preconditions (no reader sees generated text before these exist)

| Precondition | Story | State |
|---|---|---|
| Budget ceiling on the Together path | US-12.3.1 | GAP — fuse exists, budget does not |
| Call log / replay | US-12.3.2 | future-spec |
| Guardrails + red-team record | US-12.3.3 | spec; LlamaGuard inline is the start, not the record |
| Faithfulness measurement | US-12.3.4 | spec |
| Verbatim-overlap gate (§4b.1) | the guardrails child | spec — planted-verbatim red required |
| Corpus threat model + at-rest posture (§4b.2) | `reports/Protecting a private writing corpus.md` → #593's schema work | research SETTLED 2026-11-20: encrypted-vectors + in-app kNN, no FTS, crypto-shred erasure |
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

**ACCEPTED by the platform owner, 2026-11-20 ("ADR 27 is acceptable").**

- [x] Adopt the design-as-amended (sections 2–4) — YES, including §4a (import + annotate the
  author's own writing) and §4b (never-verbatim + breach-unreadable, research-settled).
- [x] Model stack (§3) — **LOCAL-FIRST, pending the eval**, per the owner's repeated request to
  keep both the book-recognition and writing-assistant systems inside our own tenancy. A hosted
  API is the recorded fallback the eval may select; it is not the default.
- [x] Preconditions list (section 5) binding before first reader exposure — YES.
- [x] Promotion rule (section 6) — YES; it is also the mechanism that decides §3's local-vs-hosted
  question on measured per-dimension quality + billed cost-per-session.
- [x] Sequencing — build children (§7, incl. migration item 0's schema refinements, the ingestion
  + annotation pipeline #593, and `mix eval.assistant` before any reader sees generated text) may
  now be filed; the LoRA path stays Phase-7 and separately ruled.

⚠️ Recorded interpretation: the owner's "acceptable" is read as local-first for §3 (not Together-
as-originally-drafted), because the owner twice asked to keep these systems local and §4b's research
reinforced it; accepting the ADR against that stated preference would have contradicted it. Flagged
here so it can be corrected if the owner meant accept-as-originally-drafted.
