import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("settings") });

test.describe("Settings — Privacy & Consent", () => {
  test("consent page loads with title and toggle", async ({ page }) => {
    await page.goto("/settings/consent");
    await expect(page.locator(".page--settings")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title")).toContainText("Privacy");
    await expect(page.locator(".toggle")).toBeVisible();
  });

  test("analytics toggle switches between on and off", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    const toggle = page.locator("button.toggle");
    const initialText = await toggle.textContent();
    await toggle.click();
    await page.waitForTimeout(300);
    const newText = await toggle.textContent();

    // Text should have changed (On→Off or Off→On)
    expect(newText).not.toEqual(initialText);
  });

  test("save button is visible and clickable", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    const saveBtn = page.locator("button", { hasText: "Save" });
    await expect(saveBtn).toBeVisible();

    // Toggle then save
    await page.locator(".toggle").click();
    await saveBtn.click();

    // Should show success or at least not error
    await page.waitForTimeout(1000);
    const errorCount = await page.locator(".error").count();
    expect(errorCount).toBe(0);
  });
});

test.describe("Settings — Age Verification", () => {
  test("age verification page loads with toggle", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await expect(page.locator(".page--settings")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title")).toContainText("Age Verification");
    await expect(page.locator(".toggle")).toBeVisible();
  });

  test("clicking toggle opens confirmation modal", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible({ timeout: 3000 });
    await expect(page.locator(".modal__title")).toContainText("Confirm Age");
  });

  test("cancel closes modal without changing state", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    const toggleTextBefore = await page.locator(".toggle").textContent();

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible();

    await page.click('button:has-text("Cancel")');
    await expect(page.locator(".modal-overlay")).not.toBeVisible();

    const toggleTextAfter = await page.locator(".toggle").textContent();
    expect(toggleTextAfter).toEqual(toggleTextBefore);
  });

  test("confirm saves age verification", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible();

    await page.click('.modal__actions button:has-text("Confirm")');
    await page.waitForTimeout(1000);

    // Modal should close
    await expect(page.locator(".modal-overlay")).not.toBeVisible();
    // No error should appear
    const errorCount = await page.locator(".error").count();
    expect(errorCount).toBe(0);
  });
});
