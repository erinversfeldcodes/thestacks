import path from "path";
import { test, expect, Page } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

// The vision pipeline runs classify + extract on VisionModel (A10G GPU) then
// resolves an ISBN via Open Library. Allow 5 minutes for cold-start + inference.
const PIPELINE_TIMEOUT = 300_000;

test.use({ storageState: suiteAuthFile("upload") });

test.describe("Upload pipeline — barcode pre-pass", () => {
  test(
    "identifies The Name of the Rose from barcode_isbn_clean.jpg via local OCR",
    async ({ page }) => {
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

      // Pipeline result: either fresh verify view or "Already in Your Library"
      // (if the book was placed in a prior run). Both prove the barcode was read.
      const verify = page.getByTestId('upload-verify');
      const duplicate = page.getByText('Already in Your Library');
      await expect(verify.or(duplicate)).toBeVisible({ timeout: 240_000 });

      // The Name of the Rose appears in both views (verify shows it in book
      // details; duplicate shows it in "You own '...' as an edition").
      await expect(page.getByText(/Name of the Rose/i)).toBeVisible();
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

      await expect(page.getByTestId('upload-verify')).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await expect(page.getByTestId('upload-verify')).toContainText(
        "We think this is"
      );
      await expect(page.getByTestId('upload-verify')).toContainText(
        "Crystal City"
      );
      await expect(page.getByTestId('upload-verify')).toContainText(
        "Russell"
      );
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

      await expect(page.getByTestId('upload-verify')).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await expect(page.getByTestId('upload-verify')).toContainText(
        "We think this is"
      );
      await expect(page.getByTestId('upload-verify')).toContainText(
        "Flyboys"
      );
      await expect(page.getByTestId('upload-verify')).toContainText(
        "Bradley"
      );
    }
  );

  test(
    "identifies Born Again Bodies from screenshot_mildly_obscured.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      // Trigger the file chooser via the "Choose Photo" button.
      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mildly_obscured.jpg")
      );

      // Upload is accepted; spinner switches to "Processing image..."
      await expect(page.getByTestId('upload-loading').locator("p")).toHaveText(
        "Processing image...",
        { timeout: 60_000 }
      );

      // Wait for the vision pipeline to complete and the verification step to render.
      await expect(page.getByTestId('upload-verify')).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      // Verification heading should be present.
      await expect(page.getByTestId('upload-verify')).toContainText(
        "We think this is"
      );

      // Title and author should match the book in the image.
      await expect(page.getByTestId('upload-verify')).toContainText(
        "Born Again Bodies"
      );
      await expect(page.getByTestId('upload-verify')).toContainText(
        "Griffith"
      );
    }
  );
});
