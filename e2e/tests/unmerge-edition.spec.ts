/**
 * #384 — the merge → unmerge round trip, driven end to end (chromium project,
 * NOT Modal-gated).
 *
 * The owner un-merge (#376) splits a wrongly-merged edition back onto its own
 * work. Its unit behaviour is exhaustively covered (41 tests) and it was driven
 * live once by hand — but nothing repeatable drove the loop, and that absence
 * was load-bearing: it let a reviewer assert a non-existent limitation about
 * the merge API. This spec is the repeatable guard:
 *
 *   1. an ordinary reader merge-formats a second REAL ISBN onto an existing
 *      work (the ISBN hard gate is real — Open Library must resolve it);
 *   2. the MFA-verified owner dry-runs, then applies, `unmerge_edition`;
 *   3. the ISBN then resolves to a DIFFERENT work, and a second apply refuses
 *      (the split-out edition is now primary of its new work).
 *
 * ## External dependency, by design
 * The merge leg resolves the ISBN through Open Library (hard gate). OL was
 * fully down on 2026-08-04, so the spec probes the same endpoint the deploy
 * preflight checks (`preflight-resolver-health.sh`: /search.json) and SKIPS
 * with a reason rather than failing the build on an upstream outage.
 *
 * ## State across runs, by design
 * The split leaves the ISBN as its own work, and a preview DB persists between
 * runs — so each full round trip permanently consumes one ISBN (`merge-format`
 * refuses a catalogued ISBN with 422 duplicate_isbn). The spec therefore draws
 * from a pool of stable ISBNs, probing `GET /api/books/isbn/:isbn` for a 404
 * (= not yet catalogued) before use, and skips with a reason when the pool is
 * exhausted on a long-lived preview — recreate the preview or extend the pool.
 *
 * ## MFA (#371)
 * The owner factor is enrolled ONCE by auth.setup.ts; this spec only READS the
 * shared secret (readOwnerMfaSecret) and derives codes with freshTotp (#394).
 * Enrolling here would replace the secret under the admin-session specs.
 */
import { test, expect, type APIRequestContext } from "@playwright/test";
import { mintSession, ownerAdminToken } from "./helpers";

/**
 * Stable, widely-held Penguin/Vintage paperback ISBNs Open Library resolves.
 * Consumed one per full round trip on a given database (see header).
 */
const SPLIT_ISBN_POOL = [
  "9780140449136", // The Odyssey — Penguin Classics
  "9780140449266", // Meditations — Penguin Classics
  "9780140449181", // The Iliad — Penguin Classics
  "9780140449082", // The Histories — Penguin Classics
  "9780140441000", // The Republic — Penguin Classics
  "9780141182605", // The Waste Land and Other Poems — Penguin
  "9780140449276", // The Epic of Gilgamesh — Penguin Classics
  "9780140449198", // Metamorphoses — Penguin Classics
];

const OL_SEARCH = "https://openlibrary.org/search.json?q=frankenstein&limit=1";

async function openLibraryReachable(request: APIRequestContext): Promise<boolean> {
  try {
    const res = await request.get(OL_SEARCH, { timeout: 10_000 });
    return res.ok();
  } catch {
    return false;
  }
}

/** First pool ISBN the platform has never seen (404 on the ISBN lookup). */
async function pickAvailableIsbn(
  request: APIRequestContext,
  readerAuth: { Authorization: string },
): Promise<string | null> {
  for (const isbn of SPLIT_ISBN_POOL) {
    const res = await request.get(`/api/books/isbn/${isbn}`, { headers: readerAuth });
    if (res.status() === 404) return isbn;
  }
  return null;
}

/** A catalogue work the reader can merge onto, readable by this reader. */
async function pickMergeTarget(
  request: APIRequestContext,
  readerAuth: { Authorization: string },
): Promise<{ id: string; title: string }> {
  const catalogue = await request.get("/api/catalogue?sort=title&page=1");
  expect(catalogue.status(), "catalogue").toBe(200);
  const { books } = await catalogue.json();
  expect(Array.isArray(books) && books.length > 0, "catalogue carries books").toBe(true);

  for (const book of books) {
    // Readable by this (age-unverified) reader — skips anything age-gated.
    const detail = await request.get(`/api/books/${book.id}`, { headers: readerAuth });
    if (detail.status() === 200) return { id: book.id, title: book.title };
  }
  throw new Error("no readable catalogue book to merge onto");
}

test.describe("un-merge correction round trip (#384)", () => {
  test("a merged edition can be split onto its own work, exactly once", async ({
    request,
  }) => {
    test.skip(
      !(await openLibraryReachable(request)),
      "Open Library unreachable — the merge leg cannot resolve an ISBN (same gate as the deploy preflight); not a build failure",
    );

    const session = await mintSession(request, { displayName: "Unmerge Driver" });
    test.skip(session === null, "STACKS_E2E_TEST_HELPERS off — cannot mint an isolated reader");
    const readerAuth = { Authorization: `Bearer ${session!.token}` };

    const splitIsbn = await pickAvailableIsbn(request, readerAuth);
    test.skip(
      splitIsbn === null,
      "split-ISBN pool exhausted on this long-lived database — recreate the preview or extend SPLIT_ISBN_POOL",
    );

    // ---- 1. reader merges a second real ISBN onto an existing work --------
    const target = await pickMergeTarget(request, readerAuth);

    const merge = await request.post(`/api/books/${target.id}/merge-format`, {
      headers: readerAuth,
      data: { isbn: splitIsbn, format_label: "Paperback" },
    });
    expect(
      merge.status(),
      `merge-format of ${splitIsbn} onto "${target.title}" (isbn_not_found here = OL could not resolve a pool ISBN)`,
    ).toBe(200);
    const merged = await merge.json();
    const editionId = merged.edition.id as string;
    expect(editionId, "merge-format returns the new edition").toBeTruthy();

    // The merged ISBN now resolves to the target work — the wrong-merge state
    // the correction exists to repair.
    const beforeSplit = await request.get(`/api/books/isbn/${splitIsbn}`, {
      headers: readerAuth,
    });
    expect(beforeSplit.status(), "merged ISBN resolves").toBe(200);
    expect((await beforeSplit.json()).book.id, "merged ISBN points at the target work").toBe(
      target.id,
    );

    // ---- 2. owner dry-runs, then applies, the un-merge --------------------
    const adminAuth = { Authorization: `Bearer ${await ownerAdminToken(request)}` };
    const argument = { edition_id: editionId, title: `Split of ${target.title} (#384)` };

    const dry = await request.post("/api/admin/data_corrections/unmerge_edition/target", {
      headers: adminAuth,
      data: { reason: "#384 E2E round trip — dry run", argument },
    });
    expect(dry.status(), "dry-run").toBe(200);
    const dryOutcome = (await dry.json()).correction;
    expect(dryOutcome.mode, "an absent apply flag means dry-run").toBe("dry_run");
    expect(dryOutcome.count, "dry-run names exactly the one edition").toBe(1);

    // Dry-run wrote nothing: the ISBN still resolves to the merged-onto work.
    const afterDry = await request.get(`/api/books/isbn/${splitIsbn}`, { headers: readerAuth });
    expect((await afterDry.json()).book.id, "dry-run must not move the edition").toBe(target.id);

    const apply = await request.post("/api/admin/data_corrections/unmerge_edition/target", {
      headers: adminAuth,
      data: { reason: "#384 E2E round trip — apply", apply: true, argument },
    });
    expect(apply.status(), "apply").toBe(200);
    expect((await apply.json()).correction.count).toBe(1);

    // ---- 3. the repair: the ISBN resolves to a DIFFERENT work -------------
    const afterSplit = await request.get(`/api/books/isbn/${splitIsbn}`, {
      headers: readerAuth,
    });
    expect(afterSplit.status(), "split ISBN still resolves").toBe(200);
    const splitWorkId = (await afterSplit.json()).book.id as string;
    expect(splitWorkId, "the split edition lives on its own work now").not.toBe(target.id);

    // ---- and exactly once: a second apply refuses -------------------------
    const again = await request.post("/api/admin/data_corrections/unmerge_edition/target", {
      headers: adminAuth,
      data: { reason: "#384 E2E round trip — second apply must refuse", apply: true, argument },
    });
    expect(again.status(), "second apply refuses").toBe(422);
    expect((await again.json()).detail, "refusal names the primary-edition guard").toContain(
      "primary_edition",
    );
  });
});
