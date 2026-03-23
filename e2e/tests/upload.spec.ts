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

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      // All five books should appear in the results.
      const result = page.locator(".upload-result--identified");
      await expect(result).toContainText("Kite Runner");
      await expect(result).toContainText("Hosseini");
      await expect(result).toContainText("Klara");
      await expect(result).toContainText("Ishiguro");
      await expect(result).toContainText("Idiot");
      await expect(result).toContainText("Batuman");
      await expect(result).toContainText("Things I Don't Want to Know", { ignoreCase: true });
      await expect(result).toContainText("Levy");
      await expect(result).toContainText("Cost of Living", { ignoreCase: true });

      // Each identified book should have a "View Book" link.
      const viewBookLinks = result.locator('a[href^="/books/"]');
      await expect(viewBookLinks).toHaveCount(5);
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
