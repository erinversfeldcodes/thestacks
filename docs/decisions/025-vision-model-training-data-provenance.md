# ADR 025: Vision Model Training-Data Provenance — Record the Position, Contain Architecturally

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Platform owner
**Technical area:** Vision sidecar, model selection, GDPR posture, licensing risk
**Relates to:** the ISBN hard gate (CLAUDE.md, *Core Conventions*; enforced in
`Stacks.Moderation` and `Stacks.Books.ISBNResolver`) — the containment this ADR
relies on, adopted for correctness rather than for this.

---

## Context

The platform runs **Qwen2.5-VL-7B-Instruct** (Apache 2.0) on Modal to identify
books from reader photographs. The question this records: **what was it trained
on, and does the answer change what we should do?**

It was asked for a mundane reason — a filename in the owner's notes carried a
shadow-library marker — and generalises badly if left unasked: a project that
declines to read a pirated book while running a model that may have been trained
on thousands is holding two standards at once.

### ⚠️ UNDISCLOSED IS NOT TAINTED, AND THE DISTINCTION IS THE WHOLE POINT

Two model families are **known** to have ingested pirated books: Anthropic
(Books3/LibGen, admitted, settled) and Meta (LibGen, in the court record).

**Qwen is in neither category.** No audit, finding or litigation places pirated
books in any Qwen model. What is true is narrower and duller: Alibaba has not
said. Treating "undisclosed" as "pirated" would be the same error as treating a
model's confident output as a verified fact, and this project has already paid
for that error once today.

### What each model actually discloses

| | Qwen2.5-VL-7B (deployed) | Qwen3-VL-4B (candidate) |
|---|---|---|
| Licence | Apache 2.0 | Apache 2.0 |
| Model card on data | **Nothing** | Nothing |
| Tech report | arXiv 2502.13923 §2.2.1 — types and synthesis, almost no sources | arXiv 2511.21631 — names COCO, Objects365, OpenImages, RefCOCO, PixMo, Omni3D; token counts per stage |
| Books | **Not mentioned at all** | ⛔ "book-scale interleaved data" — **source not named** |
| Encoder init | **DataComp** + "some in-house datasets" | SigLIP2-Large (Google) |
| SFT | "curated purchased datasets" (unnamed) | — |

⬛ **The most pointed item for a book platform** is the 4B's "book-scale
interleaved data" with no provenance. Disclosure improved in every other
respect and this is where it stops.

### ⛔ THE FINDING THAT ACTUALLY TOUCHES US IS PRIVACY, NOT COPYRIGHT

2.5-VL's encoder initialises from **DataComp**. A 2026 UW/CMU audit of DataComp
CommonPool (arXiv 2506.17185) found credit-card and passport numbers in the
corpus, roughly **142,000 resume images in a 0.1% sample**, and face-blurring
that missed an estimated **102 million faces**, with no PII-string filtering.
The authors warn that downstream models may leak that PII.

⚖️ That lands squarely on this project, whose own corpus plan refuses real user
uploads on the grounds that *"a reader photographing a bookshelf may capture
other people who never consented to being processed by a vision model, and those
people cannot be asked."* We hold our own corpus to a standard the model's
encoder does not meet. This does not make the model unusable — it makes the
asymmetry a thing we have decided about rather than inherited.

### Why indemnity is not on the table

Apache 2.0 disclaims warranty and liability and contains **no indemnity**.
Provider indemnification is a paid-hosted-API feature, and self-hosted open
weights do not carry it at any price. At a $50/month total inference budget that
option does not exist, so it is struck from the decision rather than deferred.

Nor is there a legal route to the manifest: China's 2023 CAC Interim Measures are
regulator-facing and exempt non-public R&D. The EU AI Act's Art. 53(1)(d)
template has had live enforcement powers since 2026-08-02, and an enforcement-day
audit found **one** Chinese provider had filed anything — Alibaba was not among
them.

---

## Decision

**1. Record the position per model, with its citation and date.** This file is
that record. It converts a recurring worry into a dated artefact that a future
reader can check rather than re-derive.

**2. Treat disclosure quality as a tiebreaker, not a migration trigger.** The
3-VL family discloses more and its encoder is not the one with a published
privacy audit against it. That is a real point in its favour and it is **not**
sufficient on its own — cost, latency and measured accuracy decide, and the
provenance delta breaks a tie.

**3. Rely on the architectural containment we already have, and name its edge.**

⬛ The ISBN hard gate means the vision pipeline's output is a **verified
identifier, not generated prose**. Every identification is checked against Open
Library or Google Books before anything enters the catalogue, so what the system
emits is a catalogue key that the model merely *proposed*. The infringement
surface of that is near nil, and we get it for free from a gate adopted for
correctness.

⛔ **THAT ARGUMENT DOES NOT EXTEND TO THE WRITING ASSISTANT.** A stage that
generates prose *about* books, from a model with undisclosed book training data,
has no equivalent containment — there is no external authority that verifies a
sentence the way Open Library verifies an ISBN. The vision side's clean position
is a property of the hard gate, not of the model, and must not be assumed to
carry across. Any writing-assistant stage decides this question again, on its
own terms.

**4. Watch exactly one signal:** the first Art. 53 enforcement action against a
non-EU provider. Everything else in the current litigation landscape concerns
model trainers, not downstream users of Apache-2.0 weights.

---

## Consequences

- A migration to 3-VL-4B carries a small provenance improvement alongside its
  cost and latency case. It does not resolve the book-source question.
- The DataComp privacy finding is now a known, accepted asymmetry rather than an
  unexamined one. ⚠️ If the platform ever retains user photographs beyond the
  existing retention deadlines, or feeds them to a model as training data, this
  asymmetry stops being containable and must be revisited.
- No indemnity exists at this budget. Anyone reading this later looking for one
  should not spend time searching.
- ⚠️ **Unchecked links in the chain:** SigLIP2's own corpus (the next step behind
  the 4B's encoder), and whether licences differ per size within a Qwen family —
  only 7B and 4B-Instruct were verified.

---

## What this does not decide

- Which model to run. That is the architecture work, decided on measured cost
  and accuracy.
- Anything about the writing assistant, which is explicitly excluded above and
  needs its own decision.
- Any legal conclusion. The sourcing behind this ADR is technical reports,
  published audits and press reporting; none of it is legal advice.
