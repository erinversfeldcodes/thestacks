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
- [x] Disposition of the legacy rows decided and justified — evidence: the true origin is the #335 BACKFILL, not the seed: migration `20260730200000` filled pre-column rows from provider identifiers and fell back to `barcode_unverified` when none was stored — and the seed fixtures predate identifier storage, so 100% fell into that bucket (staging still has NO `verification_source` column; every migrated branch re-manufactures the 206/206). Disposition: seed-shaped rows (deterministic `a1b2c3d4-…` ids no production write can mint) → `open_library`, because `seeds.exs` DECLARES that provenance for these very rows with its own in-file justification — the `StaleSeedEditionIsbn` argument: for a fixture row, seeds.exs is the correct value. Reader-created `barcode_unverified` rows are deliberately untouched — for them the label is true
- [x] Correction registered and idempotent — evidence: `SeedEditionVerificationSource` in `Registry.all()` (swept by `Stacks.Release.deploy/0`); `seed_edition_verification_source_test.exs` "applies the seed's declared provenance, and a second run is a no-op" — two consecutive runs, second plans nothing. Scope mutation-probed: filter removed → "never claims a reader-created barcode_unverified edition" REDS; restored → 5/0, full correction suites 71/0
- [x] Title shown whenever a title exists; provisional copy reserved for records without one — evidence: `6f54a28d` (landed earlier in the wave): `isUnidentified = isProvisional AND no known title`; `displayTitle` keyed off `isUnidentified`, never `isProvisional`
- [x] Invariant test (title present ⇒ never the provisional copy) — evidence: `ProvisionalBookTest.elm` fuzz "a book whose title is a name shows it, and the page never says it cannot" (+ the exact 1Q84 preview row as a pinned case). Probed 2026-08-09: reverting `displayTitle` to `isProvisional` reds 3 tests incl. the 1Q84 row; restored 29/0
- [x] `search.spec.ts:312` and `:432` pass unmodified — evidence: 2026-08-09 full real-login run: `:312` ✓ (2.4s) and `:432` ✓ (3.9s) among 301 passed
- [x] Live-driven post-correction — evidence: 2026-08-10 deploy log `data-correction: seed_edition_verification_source (applied)`; Neon branch read: **200/200 editions `open_library`, zero `barcode_unverified`** (was 206/206 at filing); search specs green on the same stack (`search.spec.ts:312`/`:432` in the 306-pass run) with real titles. Getting it to run surfaced and fixed a release-path gap: corrections ran only BEFORE migrations, so a correction over a freshly-added column aborted the deploy (Postgrex 42703) — `Column.column_present?/1` now reads a not-yet-migrated column as nothing-to-correct, and `Release.deploy/0` sweeps corrections on BOTH sides of `migrate()` (each side documented; idempotence is the mechanism's own contract)
- [x] `staff-review` verdict recorded below

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


## Wave 11 close-out (2026-08-10)
staff-review (Mode B shadow): **LGTM** — the disposition argument (seed rows only, `seeds.exs` as the owner of fixture truth, reader rows untouched) held up under the live failure it provoked: the release-path gap it exposed got the general fix (column guard + double-sided sweep) rather than a special case, and the correction then ran clean on the very next deploy.
