import { test, expect } from "@playwright/test";
import { OWNER_AUTH_FILE } from "./helpers";

test.use({ storageState: OWNER_AUTH_FILE });

test.skip("library loads content when navigated to directly", async ({ page }) => {
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

  await page.goto("/library");
  await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf, .error", { timeout: 10000 });

  console.log("=== After loading library ===");
  console.log("Bookshelf API calls:", apiCalls.filter(c => c.includes('bookshelves')));

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

test.skip("library loads after navigating away and back", async ({ page }) => {
  await page.goto("/library");
  await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

  // Go to catalogue
  await page.locator('a.app-nav__link[href="/catalogue"]').click();
  await expect(page).toHaveURL(/\/catalogue/, { timeout: 10000 });

  // Then go back to library
  await page.locator('a.app-nav__link[href="/library"]').click();
  await expect(page).toHaveURL(/\/library/, { timeout: 10000 });
  await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

  const bookCount = await page.locator(".book").count();
  const emptyMsg = await page.locator(".empty-msg, .empty-shelf").count();
  console.log(`After catalogue->library: Books: ${bookCount}, Empty: ${emptyMsg}`);

  expect(bookCount > 0 || emptyMsg > 0).toBeTruthy();
});
