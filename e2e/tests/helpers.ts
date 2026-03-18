import path from "path";
import type { Page } from "@playwright/test";

export const OWNER_AUTH_FILE = path.join(__dirname, "../.auth/owner.json");
export const DEV_EMAIL = "owner@thestacks.app";
export const DEV_PASSWORD = "dev-password-123";

/**
 * Per-suite E2E user credentials.
 * Each test suite gets its own user with isolated shelf state.
 * Password is the same for all E2E users.
 */
export const E2E_PASSWORD = "e2e-password";

const AUTH_DIR = path.join(__dirname, "..", ".auth");

export function suiteAuthFile(slug: string): string {
  if (!E2E_SUITES.includes(slug)) {
    throw new Error(`Unknown E2E suite slug: ${slug}`);
  }
  // Safe: slug validated against fixed allowlist above, no path traversal possible.
  const filename = "e2e-" + slug + ".json";
  return path.join(AUTH_DIR, filename); // nosemgrep: path-join-resolve-traversal
}

export function suiteEmail(slug: string): string {
  return `e2e-${slug}@thestacks.test`;
}

/**
 * All E2E suite slugs — must match Seeds.e2e_suites() in seeds.exs.
 */
export const E2E_SUITES = [
  "age-gate",
  "auth",
  "book-detail",
  "book-interaction",
  "bookshelf",
  "catalogue",
  "editions",
  "looking-for-home",
  "navigation",
  "reading-pile",
  "reading-pile-hover",
  "search",
  "settings",
  "shelf-actions",
  "upload",
];

/**
 * Ensure at least one book is placed on the library shelf.
 * If the library is empty, finds an unplaced book from the catalogue
 * and places it via the API. Must be called after navigating to the app
 * (needs localStorage access for the auth token).
 */
export async function ensureBookOnLibrary(page: Page): Promise<void> {
  await page.goto("/library");
  const placed = await page.evaluate(async () => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    if (!auth.token) return false;

    // Check if library already has books
    const shelfResp = await fetch("/api/bookshelves/library", {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    if (!shelfResp.ok) return false;
    const shelfData = await shelfResp.json();
    if (shelfData.placements && shelfData.placements.length > 0) return true;

    // Library is empty — find an unplaced book and place it
    const mineResp = await fetch("/api/placements/mine", {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    const mineData = mineResp.ok
      ? await mineResp.json()
      : { placements: [] };
    const placedIds = new Set(
      mineData.placements.map((p: any) => p.book_id)
    );

    const catResp = await fetch("/api/catalogue?per_page=200");
    const catData = await catResp.json();
    const unplaced = catData.books.find((b: any) => !placedIds.has(b.id));
    if (!unplaced) return false;

    const placeResp = await fetch("/api/bookshelves/library/placements", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${auth.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ book_id: unplaced.id }),
    });
    return placeResp.ok;
  });

  if (!placed) {
    console.log("WARN: could not ensure a book on library shelf");
  }
}
