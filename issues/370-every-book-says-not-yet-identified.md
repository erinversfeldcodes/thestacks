# Issue #370: Every book in the catalogue says "we can't show its title" — beside its title

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by the lead's Wave 6 live drive, 2026-08-01, while running down two `search.spec.ts` failures
that had been reading as flakes. They were not flakes. They were the product telling the truth about
itself.

Open any book in the catalogue. The card says **1Q84**. The overlay that opens on top of it says:

> ## Not yet identified
> *We have this book's barcode (9780099448792) but haven't matched it to a catalogue record yet, so
> we can't show its title or cover. It is still yours and still on your shelf.*
>
> *Haruki Murakami* · 2009 · 925 pages · ISBN 9780099448792

**It shows the author, the year, the page count and the ISBN, and says it cannot show the title —
which is printed on the card behind it.** The database agrees with the card:

```sql
select b.title, e.isbn, e.verification_source
  from op.book_editions e join op.books b on b.id = e.book_id
 where e.isbn = '9780099448792';

 title |     isbn      | verification_source
-------+---------------+---------------------
 1Q84  | 9780099448792 | barcode_unverified
```

## Scale: this is not an edge case
```sql
select verification_source, count(*) from op.book_editions group by 1;

 verification_source  | count
----------------------+-------
 barcode_unverified   |   206      ← every edition in the database
```

**206 of 206.** Every book on the platform presents this way in its detail overlay, while every
catalogue card, shelf spine and search result shows the real title. There is no book for which the
detail page currently tells the truth.

## Root cause — two independent defects, and both need fixing
**1. The data is mislabelled.** `Page/Upload.elm` and `Types/Book.elm:222` key the placeholder off
`isProvisional`, which is `edition.verificationSource == "barcode_unverified"`. Every row carries
that value. The seed no longer produces it — `seeds.exs:659` writes `verification_source:
"open_library"` — so these are **legacy rows predating that fix**, inherited into every preview via
Neon copy-on-write from staging. ⚠️ **No registered correction repairs them**:
`Stacks.DataCorrection.Registry` holds `NormaliseEditionIsbn10` and `StaleSeedEditionIsbn`, both
about ISBN *format*. Nothing touches `verification_source`, so `Stacks.Release.deploy/0` runs
cleanly and changes nothing here.

**2. The predicate conflates two different claims, so fixing the data alone leaves the bug armed.**
`isProvisional` means *"no provider verified this ISBN"*. The UI renders it as *"we don't know what
this book is"*. Those are not the same statement, and the screen proves it: the record has a title,
an author, a year and a page count. A future book that genuinely arrives barcode-only should say so
— but a record with a title should never claim it has none. ⚠️ **Fixing only the data would hide
this until the next unverified import.**

## Why it went unseen
Two E2E specs have been failing on exactly this for as long as the data has been wrong —
`search.spec.ts:312` and `search.spec.ts:432`, both asserting a clicked result's overlay carries the
expected title and both receiving `"Not yet identified"`. They sat inside a suite whose other
failures were genuinely environmental (see **#369**), so the whole run read as "the preview is
flaky". **This is the campaign's dominant theme in its purest form**: the system reported the defect
faithfully, and the reporting channel had lost enough credibility that nobody read it.

It also answers the open production question from **#346**. That was scoped as "40 rows, probably a
labelling nicety, negligible pre-launch". In the staging-derived data it is **100% of editions**,
and the consequence is not a label — it is every book detail page calling itself unidentified.

## User Stories
US-1.1.x (book detail), US-3.x (catalogue/search). The ISBN hard gate's user-facing contract.

## Scope Check
One data correction + one predicate/copy decision. Two concerns, but they are the same bug from the
data and code sides and fixing either alone leaves it live — so they belong together. ⚠️ If the
correction turns out to need provider re-verification rather than a relabel, split that out.

## Technical Requirements
1. **Decide what the legacy rows should say, and justify it.** ⚠️ Do not blanket-update to
   `open_library` just to clear the symptom — that asserts a verification that never happened, which
   is the same class of lie in the other direction. Options: re-verify against Open Library/Google
   Books (honest, slower), or introduce a value that means *"title known, provider verification not
   recorded"*. Whichever is chosen, the ISBN hard gate's meaning must survive it.
2. **Register the correction** in `Stacks.DataCorrection.Registry` so it runs via
   `Stacks.Release.deploy/0` on every environment, including restored backups and re-branched
   databases — the Registry's own docstring explains why corrections stay registered after applying.
3. **Separate the two claims in the UI.** A record with a title shows its title. The provisional
   copy is for records that genuinely have none. ⚠️ Keep the provisional path — it is good, honest
   writing for the case it was built for (`Page/Upload.elm:1250` reasons about it well). It is being
   applied to the wrong rows, not written wrongly.
4. **Make the contradiction impossible, not just absent.** A test that fails if the overlay renders
   the "can't show its title" copy while `book.title` is non-empty. That invariant is checkable
   without any fixture and would have caught this on day one.
5. **Unskip the two specs as the acceptance test.** `search.spec.ts:312` and `:432` currently fail;
   they should pass without modification. ⚠️ If either needs editing to pass, say why — a spec
   changed to accommodate a fix is no longer evidence of it.

## Reviewer Context
- ⚠️ **Do not read `search.spec.ts`'s failures as flakes.** They are the only automated signal that
  caught this. Run them against a preview before and after.
- ⚠️ The preview DB is healthy — 175 books, 449 active placements, 226 bookshelves, 170 users, and
  **zero** books with a null/empty title. This is not missing data; it is present data mislabelled.
- ⚠️ Run the E2E suite against a **1 GB** machine (see **#369**) or the OOM noise will bury the
  result.
- Related: **#339** (fixed the seed), **#346** (asked the production question this answers),
  **#369** (why the suite was unreadable).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ overlay never claims "can't show its title" when a title exists — probe by reverting |
| Elixir | yes | ❌ correction is registered and idempotent — probe by running twice |
| E2E | yes | ❌ `search.spec.ts:312` and `:432` pass unmodified |
| Live drive | yes | ❌ **the acceptance test**: open a catalogue book, see its real title — screenshot |
| Data | yes | ❌ post-correction count of `barcode_unverified` reported, with what each row became |
| Others | no | n/a |

## Definition of Done
- [ ] Disposition of the legacy rows decided and justified — evidence: the reasoning, not just the SQL
- [ ] Correction registered and idempotent — evidence: two consecutive runs, second a no-op
- [ ] Title shown whenever a title exists; provisional copy reserved for records without one — evidence: diff
- [ ] Invariant test (title present ⇒ never the provisional copy) — evidence: test name + probe transcript
- [ ] `search.spec.ts:312` and `:432` pass unmodified — evidence: the run
- [ ] Live-driven: catalogue book opens showing its real title — evidence: screenshot
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by the Wave 6 live drive. Answers the open question in **#346** and supersedes its
"negligible pre-launch" sizing. Downstream of **#339** (seed fixed; legacy rows not). Read
alongside **#369** (which made the signal unreadable). ⚠️ This is the reader's first impression of
every book on the platform — it belongs **before launch**, ahead of 11d, beside #353, #357 and #369.

## Agent Assignment
elixir-agent (correction) + elm-agent (predicate/copy).

## Progress Notes
Filed 2026-08-01 by the lead during the Wave 6 live drive. Screenshot of the overlay captured on the
preview; the contradicting catalogue card is visible behind it in the same frame. The 206/206 count
and the `1Q84` row were read directly from the preview branch `br-falling-wave-and3e0fr`. The seed's
current value was read from `seeds.exs:659`, and the Registry's contents from
`apps/core/lib/stacks/data_correction/registry.ex`.
