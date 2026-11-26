# What a retrieval tier needs from you

⚖️ **Much less than the fine-tune, and it is the cheaper experiment.** Where a LoRA
changes the model, retrieval changes what the model is *asked* — it proposes
candidates from a catalogue we already query, and the ISBN hard gate decides. Most
of what it needs is already on disk.

---

## ⬛ Why this is the architecturally favoured option

Published practice in shelf recognition, book scanning and receipt processing is
uniformly **restore → read → match-against-catalogue**: the middle tier emits a
*catalogue identifier by retrieval*, never a description by generation. Nobody puts
a generative model behind a failed decoder the way we currently do.

And this platform owns the expensive half already. The **ISBN hard gate is a free
external verifier** — every candidate is checked against Open Library or Google
Books before anything enters the catalogue. The generator-verifier literature says
that changes the requirement on the proposing tier:

> **from precision to recall-within-k**

⚖️ A tier that must be right *first time* needs to be good. A tier that must be right
*somewhere in its top five*, with a checksum and a catalogue to select, can be much
cheaper and much smaller. That is the whole argument for a sub-7B model, and it is
structural rather than hopeful.

---

## 1. What I need from you: almost nothing new

### Nothing, for the text path

The title-and-author retrieval path needs **no new data at all**. It uses
`ISBNResolver.search_by_title/4`, which is already built, already cached, and
already called at the vision seam. The work is ours, not yours.

⚠️ With one published caution worth knowing before we build it: on a catalogue the
size of Open Library (~2.3M titles), **fuzzy string matching beat embedding
similarity** — 0.505 against 0.449 — while on a 15,000-title shelf list embeddings
won easily (0.939 vs 0.783). Candidate-set size decides which wins, so the design is
"constrain first with a text query, rank second with similarity", not "embed
everything".

### A small set, for the cover-image path

If we add cover-embedding retrieval — match the photograph against cover art rather
than against text — I need a **reference set**, which is different from training data:

| | |
|---|---:|
| Books you own, photographed face-on in good light | **100–200** |
| Frames per book | **1** is enough; 2 is better |

⬛ **These are deliberately the EASY photographs.** A reference image is the thing
being matched *against*, so it wants to be clean, well-lit and square-on — the
opposite of the hostile images an eval set wants. This is the one request in either
document where "a nicer photograph" is strictly better.

Per book, the same identity as before:

```
isbn13:  9780571163205
title:   Moon-Whales
author:  Ted Hughes
```

---

## 2. ⛔ The failure mode to design against, stated up front

Chip Huyen's public writing on semantic caching applies here verbatim, and she is
describing the exact mechanism: *"many of its components are prone to failure"*,
*"setting the right similarity threshold can also be tricky"* — and a wrong match
returns an **incorrect answer**, not a missing one. She lists semantic caching under
"starting too complex".

⚠️ A near-miss is the specific hazard: the *same work in a different edition*, which
looks almost identical and carries a different ISBN. Our existing title cross-check
already guards this — it compares the catalogue's title against the one read off the
cover — but an embedding tier makes near-misses far more common, so that guard stops
being a backstop and becomes load-bearing.

⬛ The published standard for this is **NNDR**: threshold the *ratio* between the
nearest and second-nearest match, not the raw similarity. A photograph matching two
editions almost equally well is a photograph we should decline on, however high the
top score is.

---

## 3. ⚠️ The finding that should temper enthusiasm for the learned version

In the one directly comparable published experiment on book-cover matching, a learned
BERT re-ranker **with an explicit "no match" abstention head underperformed plain CLIP
in every setting**, and fell below simple fuzzy string matching on the large catalogue.

**A structural gate beat a learned gate.** Our structural gates are the ISBN check
digit, the catalogue resolution, and the title cross-check — all three already exist
and all three cost nothing. That is the order to exhaust before training anything.

---

## 4. What I will build, in order

1. **Digit-beam retrieval on the existing corpus — needs nothing from you.**
   When a barcode will not decode but digits are partly legible, propose k
   candidates over the real OCR confusions (`0/O`, `1/l/7`, `5/S`, `8/B`), and let
   checksum plus catalogue select. ⬛ Measured first as a *false-accept rate*: perturb
   known-good ISBNs and count how many still resolve to a real-but-wrong edition.
   That number is unpublished anywhere and decides whether this is safe at all.

2. **Title-and-author retrieval, properly measured.** Already built, never measured
   as a tier in its own right — we do not know its standalone hit rate.

3. **Cover-image embedding** — only if 1 and 2 leave a gap, and only with the
   reference set above.

---

## 5. If you want to send one thing

The **100 clean face-on covers** of books you own. They serve as the retrieval
reference set, and ⚖️ unlike the LoRA set they are useful even if we never build the
embedding tier — a clean photograph of a known book is the most reusable image in
this whole programme.
