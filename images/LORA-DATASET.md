# What a LoRA fine-tune needs from you

⚠️ **Read this before shooting anything.** Half of it is a request for photographs;
the other half is a warning about when *not* to do this. A fine-tune is the most
expensive thing on the list and the easiest to do pointlessly.

---

## ⛔ The honest position first: this may not be worth building

A LoRA teaches a model a **behaviour**, not a **fact**. It cannot teach the model
which ISBN belongs to which book — that is what Open Library is for, and we
already query it. What it *can* teach is:

- reading text set vertically on a spine without being told to rotate
- reading a title that is part of the cover artwork rather than typeset
- declining confidently when the photograph does not contain a book
- returning the title and the author in the shape our parser expects, every time

⚖️ **Three of those four are prompt or post-processing problems first.** A fine-tune
that fixes something a better prompt would have fixed is a permanent maintenance
cost bought to avoid a temporary one — and this project has already paid once this
week for changing a prompt without measuring it.

⬛ So the sequence is: measure the four GPU experiments, then try prompt changes
scored on the **whole** corpus, and only then consider a fine-tune — with this
dataset already in hand, because building it is slow and the measurements are fast.

---

## 1. How many, and of what

A LoRA on a 4B vision model for a narrow task wants **500–2,000 examples**. Below
~300 it tends to memorise; above a few thousand the returns flatten for a task this
constrained.

⚠️ **The eval corpus must not be training data.** All 122 existing images stay in
the eval set and never enter training — a model fine-tuned on its own test set
produces a number that means nothing. Everything below is *additional*.

| Group | Count | Why it earns its place |
|---|---:|---|
| **Spines, single, face-on** | 120 | The case you say dominates and the corpus cannot currently measure at all |
| **Spines, shelf row at reading distance** | 80 | What a reader actually points a phone at; several spines per frame |
| **Spines, hostile** | 60 | Dark board with foil or embossed lettering, thin spines, titles over two lines, publisher name outsizing the title |
| **Covers, hostile typography** | 100 | Art titles, foreign scripts, series name dominating, title inside the artwork |
| **Covers, ordinary** | 150 | The bulk case — varied lighting, angle, and distance, because a model trained only on hard examples gets jumpy |
| **Not a book** | 80 | DVDs, board games, tins, notebooks, a phone. ⛔ Teaching the model to DECLINE is worth as much as teaching it to read |
| **Book-adjacent** | 50 | Slipcases, e-readers showing a cover, a book in a bag, a closed box of books |
| **Multiple books in frame** | 60 | Stacks, a pile on a table, two held together |
| **TOTAL** | **~700** | |

⬛ **Shoot in sets, not singles.** Five photographs of the *same* book — face-on,
angled, spine, poor light, close crop — are worth more than five photographs of
five books, because they teach the model that those five images denote one thing.
Roughly **140 books × 5 frames** gets you the table above.

---

## 2. What each photograph must come with

This is the part that cannot be reconstructed later, and the part that makes the
dataset releasable rather than merely useful.

### Required, per book (not per photograph)

```
isbn13:      9780571163205          # from the barcode or the copyright page
title:       Moon-Whales            # as printed on the book
author:      Ted Hughes             # as printed
```

⛔ **The ISBN is per-copy, not per-work.** A photograph is of one physical edition,
and most of these works have many. We already have one label in the corpus that was
wrong because a plausible ISBN was guessed for the right title — the note in
`vision_corpus.exs` reads *"the model was right where this label was wrong."*

### Required, per photograph

```
filename:    spine-9780571163205-lowlight-01.jpg
```

That is all — the identity comes from the ISBN in the filename, and everything else
is derivable. Keep the naming scheme and I can ingest the whole set automatically.

### Required once, for the set

```
photographer:  <your name, or a pseudonym you are happy to publish>
captured:      2026-11
consent:       I own or have permission to photograph every object in these images
```

⚖️ **Why provenance matters more than it looks.** The existing corpus already carries
this per image, and it is the reason the set could one day be published: research
for ADR 025 found **no open-weight vision-language model has genuinely documented
end-to-end training data**, and no book-cover dataset exists whose *pixels* carry a
nameable licence. Ours would. That is recorded as RL-499 and is explicitly a later
question — but it costs nothing to keep the receipts now and cannot be added
retroactively.

---

## 3. ⛔ The rule that must not bend

**No photographs containing people, and no real user uploads. Ever.**

The corpus plan's §0 says it better than I can: *"a reader photographing a bookshelf
may capture other people who never consented to being processed by a vision model,
and those people cannot be asked. A corpus is forever."*

⚠️ This extends to things in the background — framed photographs on a wall, a laptop
screen, post, a name on a parcel. One image in the existing corpus is already flagged
for exactly this (`neg-bear-birthday-cake.jpg`, two framed pictures above the cake).
When in doubt, reframe rather than crop later.

⬛ And it applies to **training data more strictly than to eval data**, because a
fine-tuned model carries what it was trained on inside its weights. An eval image can
be deleted. A trained weight cannot.

---

## 4. What I will do with it

1. **Hold out 20%** as a validation split, stratified by group, never trained on.
2. Train a LoRA adapter — rank 16–32, a few hundred steps, which costs a few dollars
   of GPU time rather than a few hundred.
3. Score the adapter on the **existing 122-image eval corpus**, which it has never
   seen, using the same harness and the same per-stratum gate as every other
   experiment in this series.
4. ⚖️ Report it against the *un-tuned* model of the same size. A fine-tune that beats
   the 7B but not its own base model has taught us nothing except that the base model
   was good.

---

## 5. Shoot these first, if you shoot nothing else

The 60 images that would change a decision this week, in priority order:

1. **20 single spines**, varied quality — the stratum that does not exist
2. **15 shelf rows** at reading distance, with 2–3 ISBNs noted per frame
3. **15 hostile covers** — the typography stratum is at 4 of a planned 20
4. **10 more negatives** — objects that are emphatically not books

⬛ Those alone let me measure the spine case for the first time, which currently
caps every claim I can make about your primary use case at *unknown*.
