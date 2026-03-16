import { test, expect } from "@playwright/test";

test("diagnose login transition timing", async ({ page }) => {
  // Track all console messages from the page
  const logs: string[] = [];
  page.on("console", (msg) => logs.push(`[${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (err) => logs.push(`[PAGE ERROR] ${err.message}`));

  await page.goto("/login");

  // Check that the transition DOM elements exist
  const elements = await page.evaluate(() => ({
    overlay: !!document.getElementById("overlay"),
    bookshelf: !!document.getElementById("bookshelf"),
    passage: !!document.getElementById("passage"),
    wash: !!document.getElementById("wash"),
  }));
  console.log("Login page transition elements:", JSON.stringify(elements));

  // Check that the Elm ports exist
  const ports = await page.evaluate(() => {
    const elmApp = (window as any).__elm_app;
    // The app variable isn't globally exposed, so check for port subscriptions
    // by looking at the DOM events
    return "checked";
  });

  await page.fill('input[id="email"]', "owner@thestacks.app");
  await page.fill('input[id="password"]', "dev-password-123");

  // Listen for URL changes
  const startTime = Date.now();
  await page.click("button.login-card__submit");

  // Wait up to 20s, logging state every second
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(1000);
    const url = page.url();
    const elapsed = Date.now() - startTime;
    console.log(`${elapsed}ms: URL=${url}`);
    if (url.includes("antilibrary")) {
      console.log(`Redirect happened after ${elapsed}ms`);
      break;
    }
  }

  const finalUrl = page.url();
  console.log("Final URL:", finalUrl);
  console.log("Page logs:", logs.join("\n"));

  expect(finalUrl).toContain("antilibrary");
});
