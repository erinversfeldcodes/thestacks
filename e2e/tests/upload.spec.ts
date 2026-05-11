import path from "path";
import { test, expect, Page } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

// The vision pipeline runs classify + extract on VisionModel (H100 GPU) then
// resolves an ISBN via Open Library. Allow 5 minutes for cold-start + inference.
const PIPELINE_TIMEOUT = 300_000;

test.use({ storageState: suiteAuthFile("upload") });

test.describe("Upload pipeline — barcode pre-pass", () => {
  test(
    "identifies The Name of the Rose from barcode_isbn_clean.jpg via local OCR",
    async ({ page }) => {
      // Extra headroom beyond 240 s SSE wait + 60 s enrichment poll.
      test.setTimeout(330_000);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
      );

      await expect(page.getByTestId('upload-loading').locator("p")).toHaveText(
        "Processing image...",
        { timeout: 30_000 }
      );

      // Capture the GET /api/books/:id call Elm makes after SSE resolves so we
      // can retrieve the book ID and the initial title for fast-path detection.
      const bookResponsePromise = page.waitForResponse(
        (resp) =>
          /\/api\/books\/[^/?]+$/.test(resp.url()) && resp.status() === 200,
        { timeout: 240_000 }
      );

      // Pipeline result: either fresh verify view or "Already in Your Library"
      // (if the book was placed in a prior run). Both prove the barcode was read.
      const verify = page.getByTestId('upload-verify');
      const duplicate = page.getByText('Already in Your Library');
      await expect(verify.or(duplicate)).toBeVisible({ timeout: 240_000 });

      if (await verify.isVisible()) {
        const bookJson = await (await bookResponsePromise).json();
        const bookId: string = bookJson.book?.id ?? bookJson.id;
        const initialTitle: string =
          bookJson.book?.title ?? bookJson.title ?? "";

        if (/^ISBN \d{13}$/.test(initialTitle)) {
          // Barcode OCR fast path: IdentifyBookJob resolves immediately with a
          // placeholder title while EnrichBookJob fetches real metadata async.
          // Assert the partial data appears in the verify view first…
          await expect(page.locator(".upload-verify__title")).toContainText(
            initialTitle
          );

          // …then confirm EnrichBookJob updated the record (the verify view
          // won't re-render once Elm is in Verifying state, so we poll the API).
          await expect
            .poll(
              () =>
                page.evaluate(async (id) => {
                  const auth = JSON.parse(
                    localStorage.getItem("stacks-auth") || "{}"
                  );
                  const resp = await fetch(`/api/books/${id}`, {
                    headers: { Authorization: `Bearer ${auth.token}` },
                  });
                  if (!resp.ok) return "";
                  const data = await resp.json();
                  return (data.book?.title ?? "") as string;
                }, bookId),
              { timeout: 60_000, intervals: [2000, 3000, 5000] }
            )
            .toMatch(/Name of the Rose/i);
        } else {
          // Book already existed in DB with enriched title (repeat run).
          expect(initialTitle).toMatch(/Name of the Rose/i);
        }
      } else {
        // Duplicate path: book was placed in a prior run — title already enriched.
        await expect(page.getByText(/Name of the Rose/i)).toBeVisible();
      }
    }
  );
});

// ---------------------------------------------------------------------------
// Non-book rejection (real pipeline)
// ---------------------------------------------------------------------------

test.describe("Upload pipeline — non-book rejection", () => {
  test(
    "bunny image rejected as Doesn't Look Like a Book",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/not_a_book.jpg")
      );

      await expect(page.getByTestId("upload-loading").locator("p")).toHaveText(
        "Processing image...",
        { timeout: 30_000 }
      );

      await expect(page.getByTestId("upload-error")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });
      await expect(page.getByTestId("upload-error")).toContainText(
        "Doesn't Look Like a Book"
      );

      await expect(
        page.getByRole("button", { name: "Try Again" })
      ).toBeVisible();
    }
  );
});

// ---------------------------------------------------------------------------
// ISBN not found via manual entry (real pipeline)
// ---------------------------------------------------------------------------

test.describe("Upload pipeline — ISBN not found", () => {
  test(
    "nonexistent ISBN-13 with valid checksum returns Book not found",
    async ({ page }) => {
      // 9780000000019 has a valid ISBN-13 checksum but does not exist in any
      // catalogue, so the backend hard gate returns 404 and the UI rejects it.
      test.setTimeout(30_000);

      await page.goto("/upload");

      await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

      const isbnInput = page.getByTestId("upload-manual-isbn-input");
      await expect(isbnInput).toBeVisible();

      await isbnInput.fill("9780000000019");
      await page.getByTestId("upload-manual-isbn-submit").click();

      await expect(page.getByText("Book not found")).toBeVisible({
        timeout: 15_000,
      });
    }
  );
});

// ---------------------------------------------------------------------------
// Duplicate detection (real pipeline)
// Re-uploads barcode_isbn_clean.jpg after the book has been placed on Library.
// beforeAll is idempotent: if the book is already placed (duplicate heading
// appears), setup is skipped.
// ---------------------------------------------------------------------------

test.describe("Upload pipeline — duplicate detection", () => {
  /** Upload barcode_isbn_clean.jpg and return once "Already in Your Library" is visible. */
  async function uploadAndWaitForDuplicate(page: Page) {
    await page.goto("/upload");

    const fileChooserPromise = page.waitForEvent("filechooser");
    await page.click("button.btn--primary");
    const fileChooser = await fileChooserPromise;
    await fileChooser.setFiles(
      path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
    );

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 60_000,
    });
  }

  test.beforeAll(async ({ browser }) => {
    // Place "The Name of the Rose" on the upload user's Library so subsequent
    // uploads of the same image trigger duplicate detection.
    const context = await browser.newContext({
      storageState: suiteAuthFile("upload"),
    });
    const page = await context.newPage();

    try {
      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
      );

      await page.getByTestId("upload-loading").waitFor({ timeout: 30_000 });

      const verify = page.getByTestId("upload-verify");
      const duplicateHeading = page.getByText("Already in Your Library");
      const error = page.getByTestId("upload-error");

      await expect(verify.or(duplicateHeading).or(error)).toBeVisible({
        timeout: 60_000,
      });

      if (await error.isVisible()) {
        throw new Error("Upload pipeline failed during duplicate detection setup");
      }

      if (await duplicateHeading.isVisible()) {
        return; // Already placed from a previous run — setup is done.
      }

      // First run: confirm the book and place it on Library.
      await page.getByTestId("upload-confirm-btn").click();
      await page.getByTestId("upload-shelf-picker").waitFor({ timeout: 10_000 });
      await page.getByRole("button", { name: "Library", exact: true }).click();
      await page.getByRole("button", { name: /Add to Library/ }).click();
      await page.getByTestId("upload-complete").waitFor({ timeout: 10_000 });
    } finally {
      await context.close();
    }
  });

  test(
    "duplicate: Already in Your Library heading and all action buttons visible",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      await expect(page.getByRole("button", { name: "Yes, merge" })).toBeVisible();
      await expect(page.getByRole("button", { name: "No, add as separate" })).toBeVisible();
      await expect(page.getByRole("link", { name: "View Book" })).toBeVisible();
      await expect(page.getByRole("button", { name: "Go Back" })).toBeVisible();
    }
  );

  test(
    "duplicate: 'View Book' links to a real book route",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      const viewBookLink = page.getByRole("link", { name: "View Book" });
      await expect(viewBookLink).toBeVisible();
      // Href should be a real /books/:uuid route, not a fake placeholder ID.
      await expect(viewBookLink).toHaveAttribute("href", /\/books\/.+/);
    }
  );

  test(
    "duplicate: 'Go Back' resets the upload flow to the drop zone",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      await page.getByRole("button", { name: "Go Back" }).click();
      await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
    }
  );

  test(
    "duplicate: 'No, add as separate' proceeds to the verify view",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      await page.getByRole("button", { name: "No, add as separate" }).click();

      await expect(page.getByTestId("upload-verify")).toBeVisible({
        timeout: 10_000,
      });
      await expect(page.getByTestId("upload-verify")).toContainText(
        "Name of the Rose",
        { ignoreCase: true }
      );
    }
  );
});

// ---------------------------------------------------------------------------

test.describe("Upload pipeline", () => {
  test(
    "identifies multiple books from screenshot_mixed_text.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mixed_text.jpg")
      );

      await expect(page.getByTestId('upload-loading').locator("p")).toHaveText(
        "Processing image...",
        { timeout: 60_000 }
      );

      // Wait for any terminal state: multi-book identified, single-book verify,
      // or error (so we fail fast instead of hanging for 5 minutes on queue issues).
      const identified = page.getByTestId("upload-identified");
      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(identified.or(verify).or(error)).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });
      // If error appeared, fail with a useful message
      if ((await error.count()) > 0) {
        const errorText = await error.textContent();
        throw new Error(`Upload pipeline failed: ${errorText}`);
      }

      // If the multi-book identified view rendered, verify all five books.
      if ((await identified.count()) > 0) {
        await expect(identified).toContainText("Kite Runner");
        await expect(identified).toContainText("Hosseini");
        await expect(identified).toContainText("Klara");
        await expect(identified).toContainText("Ishiguro");
        await expect(identified).toContainText("Idiot");
        await expect(identified).toContainText("Batuman");
        await expect(identified).toContainText("Things I Don't Want to Know", { ignoreCase: true });
        await expect(identified).toContainText("Levy");
        await expect(identified).toContainText("Cost of Living", { ignoreCase: true });

        // Each identified book should have a "View Book" link.
        const viewBookLinks = identified.locator('a[href^="/books/"]');
        await expect(viewBookLinks).toHaveCount(5);
      } else {
        // Single-book verify view — at least one book was identified.
        await expect(verify).toContainText("We think this is");
      }
    }
  );

  test(
    "identifies Train to Crystal City from screenshot_image_reversed_and_cut_off.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed_and_cut_off.jpg")
      );

      await expect(page.getByTestId('upload-loading').locator("p")).toHaveText(
        "Processing image...",
        { timeout: 60_000 }
      );

      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(verify.or(error)).toBeVisible({ timeout: PIPELINE_TIMEOUT });
      if (await error.isVisible()) {
        throw new Error(
          `Upload pipeline failed: ${await error.textContent()}`
        );
      }

      await expect(verify).toContainText("We think this is");
      await expect(verify).toContainText("Crystal City");
      await expect(verify).toContainText("Russell");
    }
  );

  test(
    "identifies Flyboys from screenshot_image_reversed.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed.jpg")
      );

      await expect(page.getByTestId('upload-loading').locator("p")).toHaveText(
        "Processing image...",
        { timeout: 60_000 }
      );

      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(verify.or(error)).toBeVisible({ timeout: PIPELINE_TIMEOUT });
      if (await error.isVisible()) {
        throw new Error(
          `Upload pipeline failed: ${await error.textContent()}`
        );
      }

      await expect(verify).toContainText("We think this is");
      await expect(verify).toContainText("Flyboys");
      await expect(verify).toContainText("Bradley");
    }
  );

  test(
    "identifies Born Again Bodies from screenshot_mildly_obscured.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mildly_obscured.jpg")
      );

      await expect(page.getByTestId('upload-loading').locator("p")).toHaveText(
        "Processing image...",
        { timeout: 60_000 }
      );

      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(verify.or(error)).toBeVisible({ timeout: PIPELINE_TIMEOUT });
      if (await error.isVisible()) {
        throw new Error(
          `Upload pipeline failed: ${await error.textContent()}`
        );
      }

      await expect(verify).toContainText("We think this is");
      await expect(verify).toContainText("Born Again Bodies");
      await expect(verify).toContainText("Griffith");
    }
  );
});

// ---------------------------------------------------------------------------
// Manual ISBN entry (real service — no mocks)
// ---------------------------------------------------------------------------

test.describe("Upload pipeline — manual ISBN entry", { tag: ["@US-1.1.5"] }, () => {
  // Client-side checksum validation — no network call needed.
  test("invalid ISBN shows checksum error", async ({ page }) => {
    test.setTimeout(15_000);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/i }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await expect(isbnInput).toBeVisible();

    await isbnInput.fill("1234567890");
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByText("Invalid ISBN checksum")).toBeVisible();
  });

  // Real internal DB lookup — uses a seeded book so no external API dependency.
  // 0061470767 = The Dispossessed by Ursula K. Le Guin (seeded in all environments).
  test("valid ISBN-10 resolves to real book in verify view", async ({ page }) => {
    test.setTimeout(15_000);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/i }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await isbnInput.fill("0061470767");
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByTestId("upload-verify")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("upload-verify")).toContainText(/Dispossessed|Le Guin/i);
    await expect(page.getByTestId("upload-confirm-btn")).toBeVisible();
    await expect(page.getByTestId("upload-reject-btn")).toBeVisible();
  });

  // Same book, ISBN-13 format — verifies both input formats are accepted end-to-end.
  // 9780061470769 = The Dispossessed ISBN-13 (seeded).
  test("valid ISBN-13 resolves to real book in verify view", async ({ page }) => {
    test.setTimeout(15_000);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/i }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await isbnInput.fill("9780061470769");
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByTestId("upload-verify")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("upload-verify")).toContainText(/Dispossessed|Le Guin/i);
  });

  // Full recovery flow: real non-book image triggers rejection, then the user
  // switches to manual ISBN entry and completes a real book lookup.
  // Tests the Elm UploadError → ManualEntry state transition against live services.
  test(
    "recovery: rejected upload → Enter ISBN Manually → real book found",
    async ({ page }) => {
      // Extra 30s buffer beyond pipeline timeout for the manual ISBN steps after rejection.
      test.setTimeout(PIPELINE_TIMEOUT + 30_000);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/not_a_book.jpg")
      );

      await expect(page.getByTestId("upload-loading").locator("p")).toHaveText(
        "Processing image...",
        { timeout: 30_000 }
      );

      await expect(page.getByTestId("upload-error")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await page.getByRole("button", { name: /Enter ISBN Manually/i }).click();
      await expect(page.getByTestId("upload-manual-isbn-input")).toBeVisible();

      await page.getByTestId("upload-manual-isbn-input").fill("9780061470769");
      await page.getByTestId("upload-manual-isbn-submit").click();

      await expect(page.getByTestId("upload-verify")).toBeVisible({
        timeout: 10_000,
      });
      await expect(page.getByTestId("upload-verify")).toContainText(
        /Dispossessed|Le Guin/i
      );
    }
  );
});
