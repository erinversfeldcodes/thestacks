# Dropping photographs into the eval corpus

⛔ **Record the ISBN-13 for every book-bearing photo, at capture time.** This is the one
instruction that matters more than the photographs. The existing fixtures were shot and
labelled afterwards, and "afterwards" is why 7 of the first 8 carry no identity and
`recall@1` was uncomputable on them at any corpus size.

⛔ **No real user uploads, ever** — not a sample, not "just the ones that failed", not with
consent bolted on later. A reader photographing a shelf may capture people who never
consented to a vision model, those people cannot be asked, and a corpus is forever. Every
image is owner-authored or synthetic. See `docs/vision-eval-corpus-plan.md`.

## The fastest way to record an ISBN

Name the file with it. Anything in this shape is parsed:

    clean-9780156001311.jpg
    hostile-9780156001311-angled.jpg
    cover-9781234567897.jpg

No ISBN to hand (a cover with no barcode, an old printing)? Use the title instead:

    cover-flyboys.jpg
    cover-train-to-crystal-city.jpg

⚖️ A title is a weaker claim than an ISBN and the harness scores it as such — an ISBN match
is proof of *edition*, a title match is proof of *work*. Both are useful; don't guess an
ISBN from a title, because a photograph is of one physical copy and the work has many
editions. That guess is already a documented defect here: the corpus plan cited Bird Lake
Moon's ISBN for the barcode fixture, which is The Name of the Rose.

## What to shoot, and how much

**You shoot 135. Strata 3 and 9 (20 images) are generated from your clean originals.**

| Stratum | Target | Prefix | Notes |
|---|---|---|---|
| Clean barcode, sharp, face-on | 20 | `clean-` | the cheap-path control |
| Barcode hostile — angled, low light, partial, curved spine | 20 | `hostile-` | **re-shoot books from `clean-`** |
| Mirrored / rotated barcode | 10 | — | ⬛ generated |
| Cover, no barcode, clear title/author | 25 | `cover-` | the common real case |
| Cover, hostile typography — art titles, series marks, foreign scripts | 20 | `typo-` | ⚠️ pick deliberately |
| Multiple books in frame | 15 | `multi-` | 2–4 books; ⚠️ see the note below |
| Not a book — mug, plant, screenshot, person | 20 | `neg-` | no ISBN needed |
| Book-adjacent — magazine, boxed DVD, notebook, distant shelf | 15 | `adjacent-` | no ISBN needed |
| Deliberately illegible | 10 | — | ⬛ generated |

**~45–55 distinct books**, not 135. `hostile-` and `typo-` are deliberate restagings, so the
same book appears in several rows — that is the plan's method, not duplication.

### Shoot in this order if you may stop early

1. `cover-` (25) — both the OCR and cover-embedding candidates live or die here
2. `typo-` (20) — the discriminating stratum, where a VLM currently earns its cost
3. `clean-` (20) — the control
4. `neg-` + `adjacent-` (35) — no ISBNs, fastest, and they set the safety threshold
5. `hostile-` + `multi-` (35)

⬛ At **45** (`cover-` + `typo-`) a directional pilot can run. At **135** the corpus is the
plan's full shape (155 with the 20 generated).

## After dropping files in

    just run mix eval.corpus.intake      # parses filenames, writes manifest rows, reports gaps

It never overwrites a hand-written label, and it reports any file it could not parse rather
than guessing. Anything it cannot read an identity from is listed, not silently dropped.

## ⚠️ The multi-book stratum cannot express its own ground truth yet

`expect_isbn` is a **single** field, so a frame holding three books can record only one
expected identity. Naming extra ISBNs in the filename is harmless — the parser takes the
first and ignores the rest — but the corpus cannot yet say "all three of these should come
back", which is the thing a multi-book frame is for.

⬛ So shoot the 15 `multi-` frames last, and put the ISBN of the book that should be the
*primary* answer first in the filename. Making the expectation list-valued is a harness
change that belongs with the architecture work, not something to fake with a single field
— a corpus row that claims one book when the truth is three is a lying label, and this
project has been bitten by exactly that shape before.
