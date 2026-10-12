# The vision eval corpus: what a real one looks like

**Status:** plan only. Ruled 2026-08-19: do **not** expand the corpus yet. Build the
harness against today's fixtures with a no-regression gate, and treat this document as
the specification for the expansion when it is worth the owner's time.

**Hard constraint, ruled and non-negotiable:** no real user uploads, ever. Not a
sample, not "just the ones that failed", not with consent bolted on afterwards.
`docs/technical-architecture.md:1484` states that we deliberately do not preserve the
ability to re-run vision processing on an original image, and `:1558` gives the reason
that outlives any convenience argument: *a user photographing a bookshelf may capture
other people who never consented to being processed by a vision model.* Those people
cannot be asked, and a corpus is forever. Every image below is authored by the owner
or synthetic.

---

## 1. Why today's set cannot carry an absolute gate

Six committed fixtures, already labelled twice over — class labels in
`scripts/probe-production.sh:18-26` (`barcode`, `not_a_book`, `reversed`,
`reversed_cutoff`, `obscured`, `mixed_text`) and identity ground truth in
`e2e/tests/upload.spec.ts` (expected titles/authors per image; the barcode fixture is
The Name of the Rose, ISBN `9780156001311`). ⚠️ This paragraph previously cited
`9780061470769` as the fixture's ISBN. That is Bird Lake Moon, which appears only in the
manual-ISBN-entry specs — the two were conflated, and the error was copied into the eval
corpus before the first real run caught it.

That is a real, legally clean seed set and it is enough to detect *breakage*. It is not
enough to measure *accuracy*, for one arithmetic reason: **on six samples, every
observation moves the score by 16.7 points.** An "≥90% ISBN agreement" gate on six items
is a gate that fires on one image changing its mind. It would read as rigour and behave
as noise, and the first time it went red for a benign reason someone would raise the
threshold rather than investigate — which is how a gate becomes decoration.

Hence: **no-regression-against-a-recorded-baseline now**, absolute thresholds only when
the corpus is large enough for a percentage to mean something.

---

## 2. Target shape

### Size

**120 images minimum, 200 preferred.** The reasoning is per-stratum rather than total:
the gate is only meaningful if each *class* has enough members that one image flipping
does not swing that class's score more than a couple of points. At 15–20 per stratum a
single flip moves a stratum by 5–7 points and the overall figure by well under 1 — which
is the resolution an absolute threshold needs.

Below ~100 total, keep the no-regression gate. Above ~120, absolute thresholds per
stratum become defensible.

### Strata

The corpus must mirror the **cascade**, because a single blended accuracy number hides
exactly the regression that matters — a cheap tier silently degrading and pushing load
onto an expensive one. The cascade runs barcode → cover-embedding → OCR → VLM fallback.

| Stratum | Target n | What it proves | Cascade tier under test |
|---|---:|---|---|
| Clean barcode, sharp, face-on | 20 | The cheap path stays cheap | `local_isbn_scan` (pyzbar, CPU, deterministic) |
| Barcode present but hostile — angled, low light, partial, curved spine | 20 | Where the cheap path *should* hand off | barcode → fallback boundary |
| Mirrored / rotated barcode | 10 | pyzbar cannot decode mirrored codes; the mirror+rotation retry is real logic with real failure modes | `local_ocr` retry ladder |
| Cover, no barcode, clear title/author | 25 | The common real case | OCR / VLM |
| Cover, no barcode, hostile typography — art titles, series marks, foreign scripts, heavy design | 20 | Where extraction confidently invents things | VLM |
| Multiple books in frame | 15 | Whether it picks one confidently or declines honestly | VLM + candidate scoring |
| Not a book at all — a mug, a plant, a screenshot, a person | 20 | Rejection, the safety-critical class | `classify` |
| Book-adjacent non-books — a magazine, a boxed DVD, a notebook, a bookshelf photographed at distance | 15 | The genuinely hard rejection cases | `classify` |
| Deliberately illegible | 10 | That it declines rather than guesses | whole cascade |

Roughly 155 at target, 120 at the floor by trimming the well-behaved strata first.

### Distribution rule

**Do not build a corpus of easy cases and report a high number.** A corpus that mirrors
a happy path is a corpus that certifies the happy path. Weight it toward the boundaries
where the cascade makes decisions — the hostile-barcode, book-adjacent and
multiple-books strata are the ones that will actually catch a model swap going wrong.

---

## 3. Label quality

Each item carries, in a committed manifest:

- **`class`** — one of the strata above. Assigned by the author, not by the model.
- **`expected_isbn`** — the true ISBN-13 where one exists, verified against Open
  Library or Google Books at labelling time, not from what the model returned.
- **`expected_title` / `expected_author`** — for identity checks.
- **`expect_rejection: true`** — for the non-book strata. This is a first-class expected
  outcome, not an absence of one.
- **`acceptable_outcomes`** — for genuinely ambiguous items (a multi-book shelf where
  two answers are both defensible), an explicit set. Pinning a single answer to an
  ambiguous image manufactures a failure the model does not deserve.
- **`provenance`** — who photographed it and when. Cheap to record, and it is the
  evidence that the no-user-images rule was kept.
- **`notes`** — why the item is in the corpus. An item nobody can justify is an item
  nobody will dare delete when it becomes wrong.

⛔ **Never label from model output.** A corpus labelled by the system it grades will
certify the system's own mistakes and drift with it, and the drift is invisible because
the labels move too.

### Ambiguity handling

Two labellers would be ideal and are not available. The single-labeller substitute:
label, wait, re-label a 20% sample cold, and record the disagreement rate in the
manifest. A stratum where you disagree with yourself is a stratum whose threshold should
be looser — and knowing that is worth more than pretending to a precision you do not
have.

---

## 4. Sourcing, given the constraint

1. **The owner's own shelves** — the primary source. Perhaps 2–3 hours of photography
   for ~100 items across the strata, and the hostile strata are the ones to stage
   deliberately: photograph the same book face-on, angled, in poor light, and partially
   covered.
2. **Synthetic hostility** — programmatic rotation, mirroring, crop, blur and
   brightness applied to clean originals. Cheap, reproducible, and it generates the
   mirrored/rotated stratum exactly. Record the transform in `provenance` so a
   synthetic failure is never mistaken for a real-world one.
3. **Openly-licensed cover imagery** — for typography diversity beyond one person's
   shelves. Record the licence per item.
4. **Deliberately not** — user uploads, scraped retail imagery, or anything whose
   licence cannot be named.

---

## 5. What the gate becomes, at size

- **Per-stratum** scores, never one blended number.
- **Barcode/OCR tier gated in CI**: CPU-only, deterministic, free, no Modal credentials
  in CI. This is where an absolute floor belongs first, because a deterministic tier
  either decodes or does not.
- **VLM tier gated post-deploy**, not in CI: it burns GPU on every run and is
  nondeterministic.
- **Rejection accuracy is the safety metric.** A false accept — confidently identifying
  a book that is not there — is worse than a false reject, and should carry the
  tightest threshold of anything in the corpus.
- **Baseline recorded per model version.** A model swap is expected to move numbers; the
  gate's question is "did this move in a direction we accepted", which needs the old
  number kept, not overwritten.

---

## 6. When to do this

The trigger is **any change to the vision model, the cascade's ordering, or the
provider** — at that moment the no-regression gate becomes untrustworthy, because
"no regression against a baseline recorded on the previous model" is not a claim the
baseline can support. Until then the six fixtures plus a no-regression gate are an
honest instrument, and this document is the plan for when they stop being one.
