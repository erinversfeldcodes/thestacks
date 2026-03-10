import path from "path";
import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

// The vision pipeline calls Together AI and ISBNResolver — allow up to 180 s.
const PIPELINE_TIMEOUT = 180_000;

async function signIn(page: import("@playwright/test").Page) {
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-form__submit");
  await page.waitForURL("/", { timeout: 10_000 });
}

test.describe("Upload pipeline", () => {
  test(
    "identifies multiple books from screenshot_mixed_text.PNG",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mixed_text.PNG")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book..."
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
      await expect(result).toContainText("Things I Don't Want to Know");
      await expect(result).toContainText("Levy");
      await expect(result).toContainText("Cost of Living");

      // Each identified book should have a "View Book" link.
      const viewBookLinks = result.locator('a[href^="/books/"]');
      await expect(viewBookLinks).toHaveCount(5);
    }
  );

  test(
    "identifies Train to Crystal City from screenshot_image_reversed_and_cut_off.PNG",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed_and_cut_off.PNG")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book..."
      );

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await expect(page.locator(".upload-result--identified")).toContainText(
        "Crystal City"
      );
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Russell"
      );

      const viewBookLink = page.locator('.upload-result--identified a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );

  test(
    "identifies Flyboys from screenshot_image_reversed.PNG",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed.PNG")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book..."
      );

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await expect(page.locator(".upload-result--identified")).toContainText(
        "Flyboys"
      );
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Bradley"
      );

      const viewBookLink = page.locator('.upload-result--identified a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );

  test(
    "identifies Born Again Bodies from screenshot_mildly_obscured.PNG",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      // Navigate via the SPA link to keep Elm's in-memory auth state.
      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      // Trigger the file chooser via the "Choose Photo" button.
      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mildly_obscured.PNG")
      );

      // Upload is accepted; spinner switches to "Identifying your book..."
      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book..."
      );

      // Wait for the vision pipeline to complete and the result to render.
      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      // Title and author should match the book in the image.
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Born Again Bodies"
      );
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Griffith"
      );

      // "View Book" link should be present and point to a book detail page.
      const viewBookLink = page.locator('.upload-result--identified a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );
});
