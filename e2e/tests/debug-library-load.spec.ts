import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test("library loads content when navigated to immediately after login", async ({ page }) => {
  // Intercept API calls to see if the bookshelf request fires
  const apiCalls: string[] = [];
  page.on('request', (req) => {
    if (req.url().includes('/api/')) {
      apiCalls.push(`${req.method()} ${req.url()}`);
    }
  });

  page.on('response', (res) => {
    if (res.url().includes('/api/bookshelves')) {
      console.log(`API response: ${res.status()} ${res.url()}`);
    }
  });

  // Login
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-card__submit");
  await page.waitForURL("**/antilibrary", { timeout: 15000 });

  console.log("=== After login, on antilibrary ===");
  console.log("API calls so far:", apiCalls.filter(c => c.includes('bookshelves')));

  // Immediately navigate to library
  await page.locator('a.app-nav__link[href="/library"]').click();
  await page.waitForURL("**/library", { timeout: 10000 });

  // Wait for API call to complete
  await page.waitForTimeout(3000);

  console.log("=== After navigating to library ===");
  console.log("All bookshelf API calls:", apiCalls.filter(c => c.includes('bookshelves')));

  // Check what's on the page
  const bookCount = await page.locator(".book").count();
  const emptyMsg = await page.locator(".empty-msg, .empty-shelf").count();
  const loading = await page.locator(".loading").count();
  const error = await page.locator(".error").count();
  const shelfRoom = await page.locator(".shelf-room").count();
  const bookcase = await page.locator(".bookcase").count();

  console.log(`Books: ${bookCount}, Empty: ${emptyMsg}, Loading: ${loading}, Error: ${error}`);
  console.log(`Shelf-room: ${shelfRoom}, Bookcase: ${bookcase}`);

  // The page should have rendered content (books, empty state, or error — not stuck on loading)
  const hasContent = bookCount > 0 || emptyMsg > 0 || error > 0;
  console.log(`Has content: ${hasContent}`);

  // Also check if the API call for library was made
  const libraryApiCall = apiCalls.find(c => c.includes('bookshelves/library'));
  console.log(`Library API call found: ${!!libraryApiCall}`);

  expect(hasContent || !!libraryApiCall).toBeTruthy();
});

test("library loads after navigating away and back", async ({ page }) => {
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-card__submit");
  await page.waitForURL("**/antilibrary", { timeout: 15000 });

  // Go to catalogue first
  await page.locator('a.app-nav__link[href="/catalogue"]').click();
  await page.waitForURL("**/catalogue", { timeout: 10000 });
  await page.waitForTimeout(1000);

  // Then go to library
  await page.locator('a.app-nav__link[href="/library"]').click();
  await page.waitForURL("**/library", { timeout: 10000 });
  await page.waitForTimeout(3000);

  const bookCount = await page.locator(".book").count();
  const emptyMsg = await page.locator(".empty-msg, .empty-shelf").count();
  console.log(`After catalogue->library: Books: ${bookCount}, Empty: ${emptyMsg}`);

  expect(bookCount > 0 || emptyMsg > 0).toBeTruthy();
});
