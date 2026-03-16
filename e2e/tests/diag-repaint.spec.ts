import { test, expect } from "@playwright/test";

test("check if forcing repaint makes books visible", async ({ page }) => {
  const resp = await page.request.post("/api/auth/login", {
    data: { email: "owner@thestacks.app", password: "dev-password-123" }
  });
  const body = await resp.json();
  const u = body.user;
  const auth = {
    token: body.token, userId: u.id,
    email: u.email, displayName: u.display_name
  };

  await page.goto("/");
  await page.evaluate((a) => localStorage.setItem("stacks-auth", JSON.stringify(a)), auth);
  await page.goto("/antilibrary");
  await page.waitForTimeout(2000);

  // Screenshot BEFORE repaint
  await page.screenshot({ path: "test-results/before-repaint.png" });

  // Force a repaint by toggling a style
  await page.evaluate(() => {
    document.querySelectorAll(".book").forEach((el) => {
      const e = el as HTMLElement;
      e.style.display = "none";
      e.offsetHeight; // force reflow
      e.style.display = "";
    });
  });
  await page.waitForTimeout(500);

  // Screenshot AFTER repaint
  await page.screenshot({ path: "test-results/after-repaint.png" });

  // Check if books are visually present (bounding box has non-zero size)
  const bookBox = await page.locator(".book").first().boundingBox();
  console.log("Book bounding box:", bookBox);
  expect(bookBox).toBeTruthy();
  expect(bookBox!.height).toBeGreaterThan(0);
});
