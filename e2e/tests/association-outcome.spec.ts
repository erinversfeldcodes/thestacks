import { test, expect } from "@playwright/test";
import {
  mintSession,
  injectSession,
  seedAssociationOutcome,
  SESSION_HELPER_SKIP,
} from "./helpers";

/**
 * What an author is told when no books could be linked to their post.
 *
 * ⛔ THE AUTHOR USED TO BE TOLD NOTHING. `Components.BookAssociations` rendered
 * no element at all for an empty list, and the payload carried no reason — so a
 * post whose association pass failed looked exactly like one that was never
 * tried, and the writer was left to guess whether the feature was broken or
 * their post simply had no books in it. Every terminal path in the worker counts
 * itself under telemetry, which reaches a dashboard and reaches the author not
 * at all.
 *
 * ⚠️ THIS IS THE HALF THAT HAD NO DRIVABLE ROUTE. Production reaches the failure
 * outcomes only through an async LLM worker whose result a browser cannot steer,
 * which is why this surface had never been seen rendered. The gated
 * `/api/test/association-outcome` helper writes the same end state through the
 * same schema, with the outcome validated against the worker's own vocabulary.
 */
test.describe("the association outcome an author sees", () => {
  test("a failed pass says so, and says it is not permanent", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request);
    test.skip(session === null, SESSION_HELPER_SKIP);
    if (!session) return;

    await injectSession(page, session);

    const postId = await seedAssociationOutcome(request, session.email, "llm_error");

    await page.goto(`/blog/${postId}`);

    // ⬛ WAIT FOR PRESENCE FIRST. An assertion about absence that runs before
    // the page has rendered is satisfied by the pre-condition and fails open —
    // worse the slower the target. So the note is awaited, and only then is its
    // content checked.
    const note = page.locator(".book-associations__note");
    await expect(note).toBeVisible();

    await expect(note).toHaveText("We couldn't link books to this post this time.");
  });

  test("a pass that found nothing says that instead", async ({ page, request }) => {
    const session = await mintSession(request);
    test.skip(session === null, SESSION_HELPER_SKIP);
    if (!session) return;

    await injectSession(page, session);

    const postId = await seedAssociationOutcome(
      request,
      session.email,
      "no_books_found",
    );

    await page.goto(`/blog/${postId}`);

    const note = page.locator(".book-associations__note");
    await expect(note).toBeVisible();

    // ⛔ THE TWO MESSAGES MUST DIFFER. A completed scan that found no books and
    // a scan that could not run are different facts, and the author can act on
    // one of them. Asserting only "some note appeared" would pass with both
    // collapsed into one string.
    await expect(note).toHaveText("No books from your shelves came up in this post.");
  });

  test("a pass that succeeded shows no failure note", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request);
    test.skip(session === null, SESSION_HELPER_SKIP);
    if (!session) return;

    await injectSession(page, session);

    const postId = await seedAssociationOutcome(request, session.email, "associated");

    await page.goto(`/blog/${postId}`);

    // ⚠️ IT DOES NOT ASSERT BOOKS, AND THE NAME NO LONGER CLAIMS TO.
    // `seedAssociationOutcome` writes a call-log row and creates no
    // associations, so there are no books for this case to show — the earlier
    // name ("shows the books") would have misled whoever read a failure. A
    // case that drives a real association belongs with the component's own
    // suite, which now has one.
    //
    // ⚠️ The note's ABSENCE is checked only after the post itself has rendered,
    // so the assertion cannot be satisfied by a page that simply had not loaded
    // yet. `associated` with no visible associations is the case where the
    // author dismissed every one — saying "we found none" there would
    // contradict what they just did.
    await expect(page.locator(".blog-post__content")).toBeVisible();

    await expect(page.locator(".book-associations__note")).toHaveCount(0);
  });
});
