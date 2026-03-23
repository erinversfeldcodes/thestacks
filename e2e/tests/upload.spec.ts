import path from "path";
import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

// The vision pipeline runs classify + extract on VisionModel (A10G GPU) then
// resolves an ISBN via Open Library. Allow 5 minutes for cold-start + inference.
const PIPELINE_TIMEOUT = 300_000;

test.use({ storageState: suiteAuthFile("upload") });

test.describe("Upload pipeline — barcode pre-pass", () => {
  test(
    "identifies The Name of the Rose from barcode_isbn_clean.jpg via local OCR",
    async ({ page }) => {
      // The barcode pre-pass should short-circuit the VLM entirely.
      // 60s is generous — the pre-pass itself takes milliseconds; the rest
      // is Open Library lookup + Elm polling.
      test.setTimeout(60_000);

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

      await expect(page.getByTestId('upload-verify')).toBeVisible({
        timeout: 60_000,
      });

      const result = page.getByTestId('upload-verify');
      await expect(result).toContainText("We think this is");
      await expect(result).toContainText("Name of the Rose", {
        ignoreCase: true,
      });
      await expect(result).toContainText("Eco");
    }
  );
});

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
