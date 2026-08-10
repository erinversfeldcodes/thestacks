import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import * as path from "path";
import { mintSession, injectSession, uniqueEmail, type MintedSession } from "./helpers";

/**
 * The Goodreads library import journey (US-1.1.9, wave 11b): choose the export
 * CSV on /import, watch the server's own progress counters, read the per-row
 * report, and find the shelved books on the real bookshelves afterwards.
 *
 * The fixture is the same 5-row export the backend suite uses. Against the
 * deployed preview the ISBNs resolve against the REAL Open Library / Google
 * Books, so the spec pins only the deterministic rows:
 *   - row 5 (no ISBN at all) can never enter — the hard gate is the subject
 *     of this spec, and that row is its witness;
 *   - rows 1–3 are real, resolvable ISBNs (1984 + two Tolkiens) → shelved;
 *   - row 4 is a real-but-obscure ISBN whose upstream answer we do not pin.
 *
 * Each test owns a throwaway minted user: an import writes placements, and
 * sharing a user across runs would turn every re-run into a duplicate report.
 */

const FIXTURE = path.join(__dirname, "..", "fixtures", "goodreads_library_export.csv");

/**
 * Land authenticated on a path with the onboarding overlay out of the way.
 * A minted user is placement-free, so the global overlay appears and its
 * backdrop intercepts every click. Dismissing via its own Skip button (which
 * persists) — rather than pre-placing a book like other specs — keeps the
 * import as the ONLY writer of placements, so the counts asserted below are
 * attributable to it alone.
 */
async function landOn(page: Page, session: MintedSession, pathName: string): Promise<void> {
  await injectSession(page, session);
  await page.goto(pathName);
  const overlay = page.getByTestId("onboarding-overlay");
  const appeared = await overlay
    .waitFor({ state: "visible", timeout: 3000 })
    .then(() => true)
    .catch(() => false);
  if (appeared) {
    await overlay.getByTestId("onboarding-skip-btn").click();
    await expect(overlay).not.toBeVisible();
  }
}

test.describe("Goodreads import", () => {
  test("the full journey: upload → progress → report → books on shelves", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("gr-import") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    await landOn(page, session, "/import");

    await expect(page.getByTestId("import-page")).toBeVisible();

    // File.Select opens a native chooser — Playwright intercepts it.
    const chooserPromise = page.waitForEvent("filechooser");
    await page.getByTestId("import-choose-file").click();
    const chooser = await chooserPromise;
    await chooser.setFiles(FIXTURE);

    // The report is the terminal surface; the job is batched server-side, and
    // real resolver round-trips for ~4 ISBNs take seconds, not minutes.
    await expect(page.getByTestId("import-report")).toBeVisible({ timeout: 90_000 });

    // The three well-known ISBNs shelved.
    const shelved = page.getByTestId("import-count-shelved");
    const shelvedCount = parseInt((await shelved.locator(".import__count-number").innerText()), 10);
    expect(shelvedCount).toBeGreaterThanOrEqual(3);

    // The hard gate held: the no-ISBN zine row is reported, not invented.
    await expect(page.getByTestId("import-rows")).toBeVisible();
    const zineRow = page
      .getByTestId("import-report-row")
      .filter({ hasText: "Self-Published Zine" });
    await expect(zineRow).toBeVisible();
    await expect(zineRow).toContainText("no valid ISBN");

    // The read book is genuinely on the Library bookshelf — not just counted.
    await page.goto("/library");
    await expect(page.locator("body")).toContainText("1984", { timeout: 15_000 });
  });

  test("a non-Goodreads CSV is refused at upload time with its own copy", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("gr-import-bad") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    await landOn(page, session, "/import");

    const chooserPromise = page.waitForEvent("filechooser");
    await page.getByTestId("import-choose-file").click();
    const chooser = await chooserPromise;
    await chooser.setFiles({
      name: "not-goodreads.csv",
      mimeType: "text/csv",
      buffer: Buffer.from("name,number\nAlice,42\n"),
    });

    await expect(page.getByTestId("import-error")).toBeVisible();
    await expect(page.getByTestId("import-error")).toContainText(
      "doesn't look like a Goodreads export",
    );
    // Still on the chooser — the reader can immediately try the right file.
    await expect(page.getByTestId("import-choose-file")).toBeVisible();
  });

  test("the upload page offers the import to arriving Goodreads readers", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("gr-import-link") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    await landOn(page, session, "/upload");

    const link = page.getByTestId("upload-import-link");
    await expect(link).toBeVisible();
    await link.click();
    await expect(page.getByTestId("import-page")).toBeVisible();
  });
});
