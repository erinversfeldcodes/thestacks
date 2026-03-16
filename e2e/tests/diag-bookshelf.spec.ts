import { test, expect } from "@playwright/test";

test("diagnose bookshelf rendering by injecting auth directly", async ({ page }) => {
  // Get a token via API
  const resp = await page.request.post("/api/auth/login", {
    data: { email: "owner@thestacks.app", password: "dev-password-123" }
  });
  const body = await resp.json();
  const auth = {
    token: body.token,
    userId: body.user.id,
    email: body.user.email,
    displayName: body.user.display_name
  };

  // Inject auth into localStorage before loading the page
  await page.goto("/");
  await page.evaluate((a) => localStorage.setItem("stacks-auth", JSON.stringify(a)), auth);
  
  // Now load antilibrary — Elm will read auth from flags
  await page.goto("/antilibrary");
  await page.waitForTimeout(3000);

  // Dump the page HTML structure
  const html = await page.evaluate(() => {
    const main = document.querySelector(".app__main");
    return main ? main.innerHTML.substring(0, 3000) : "NO .app__main FOUND";
  });
  console.log("=== .app__main HTML ===");
  console.log(html);

  // Check for specific elements
  const checks = await page.evaluate(() => ({
    pageShelf: !!document.querySelector(".page--shelf"),
    shelfRoom: !!document.querySelector(".shelf-room"),
    bookcase: !!document.querySelector(".bookcase"),
    shelfRow: !!document.querySelector(".shelf-row"),
    wallpaper: !!document.querySelector(".wallpaper"),
    shelfLabel: !!document.querySelector(".shelf-label"),
    loading: !!document.querySelector(".loading"),
    error: !!document.querySelector(".error"),
    book: !!document.querySelector(".book"),
    emptyShelf: !!document.querySelector(".empty-shelf"),
  }));
  console.log("=== Element checks ===");
  console.log(JSON.stringify(checks, null, 2));
});
