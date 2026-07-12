import path from "path";
import type { APIRequestContext, Page } from "@playwright/test";

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
 * Ensure at least one PLACED book is visible on the FIRST PAGE of the
 * catalogue, so badge-rendering assertions can succeed without scrolling
 * or paginating. The catalogue endpoint paginates at per_page=24 by
 * default; existing placements past position 24 won't render a badge on
 * the default catalogue view, so checking "any placements exist" is not
 * enough. We instead fetch the same first page the UI will render and
 * verify at least one of those books is in the user's placements,
 * placing one from that page if not.
 */
export async function ensureBookOnLibrary(page: Page): Promise<void> {
  await page.goto("/library");
  const placed = await page.evaluate(async () => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    if (!auth.token) return false;

    // Fetch the first page the catalogue UI will render (default per_page=24).
    const firstPageResp = await fetch("/api/catalogue");
    if (!firstPageResp.ok) return false;
    const firstPage = await firstPageResp.json();
    const visibleBooks: { id: string }[] = firstPage.books ?? [];
    if (visibleBooks.length === 0) return false;

    // Set of book IDs already placed by this user across all shelves.
    const mineResp = await fetch("/api/placements/mine", {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    const mineData = mineResp.ok
      ? await mineResp.json()
      : { placements: [] };
    const placedIds = new Set(
      (mineData.placements ?? []).map((p: any) => p.book_id)
    );

    // If any visible book is already placed, the badge will render.
    if (visibleBooks.some((b) => placedIds.has(b.id))) return true;

    // Otherwise, place the first visible-but-unplaced book on the library.
    const unplaced = visibleBooks.find((b) => !placedIds.has(b.id));
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
    console.log("WARN: could not ensure a placed book is visible on the catalogue first page");
  }
}

/**
 * Ensure at least one book is placed on the given bookshelf.
 * Reuses the same logic as ensureBookOnLibrary but for any shelf name.
 */
export async function ensureBookOnShelf(
  page: Page,
  shelfName: string
): Promise<void> {
  await page.goto(`/${shelfName}`);
  const placed = await page.evaluate(
    async ({ shelf }) => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      if (!auth.token) return false;

      const shelfResp = await fetch(`/api/bookshelves/${shelf}`, {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      if (!shelfResp.ok) return false;
      const shelfData = await shelfResp.json();
      // API returns {shelves: [{placements: [...]}]} after #151 shelf entity change
      const allPlacements = (shelfData.shelves ?? []).flatMap((s: any) => s.placements ?? []);
      if (allPlacements.length > 0) return true;

      // Shelf is empty — find an unplaced book and place it
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

      const placeResp = await fetch(`/api/bookshelves/${shelf}/placements`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${auth.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ book_id: unplaced.id }),
      });
      return placeResp.ok;
    },
    { shelf: shelfName }
  );

  if (!placed) {
    console.log(`WARN: could not ensure a book on ${shelfName} shelf`);
  }
}

/**
 * API helper for making authenticated requests from E2E tests.
 * Extracts token from localStorage and calls the given endpoint.
 */
export async function apiCallFromPage(
  page: Page,
  method: string,
  path: string,
  body?: Record<string, unknown>
): Promise<{ status: number; data: unknown }> {
  return page.evaluate(
    async ({ method, path, body }) => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      const headers: Record<string, string> = {};
      if (auth.token) headers["Authorization"] = `Bearer ${auth.token}`;
      if (body) headers["Content-Type"] = "application/json";

      const resp = await fetch(path, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
      const data = await resp.json().catch(() => null);
      return { status: resp.status, data };
    },
    { method, path, body }
  );
}

// ── Auth-lifecycle helpers (Issue #124) ────────────────────────────────────

/**
 * Generate a unique, never-before-seen email so registration tests never
 * collide with prior runs or with seeded users. Uses the `.test` TLD, which
 * matches the E2E user convention and is never delivered to a real inbox.
 */
export function uniqueEmail(prefix = "e2e-reg"): string {
  const rand = Math.floor(Math.random() * 1_000_000);
  return `${prefix}-${Date.now()}-${rand}@thestacks.test`;
}

/**
 * Register a user directly via the API (no email delivery). Newly-registered
 * users are UNCONFIRMED — the server sends a confirmation email we never read
 * in CI. Returns the raw APIResponse so callers can assert on status/body.
 */
export async function registerViaApi(
  request: APIRequestContext,
  opts: { email: string; password: string; displayName?: string }
) {
  return request.post("/api/auth/register", {
    data: {
      email: opts.email,
      password: opts.password,
      display_name: opts.displayName ?? "E2E Newcomer",
    },
  });
}

/**
 * Retrieve a user's email-confirmation token via the test-helper endpoint.
 * This endpoint only exists when the server is booted with
 * STACKS_E2E_TEST_HELPERS=1; it 404s otherwise (or if the user is unknown).
 *
 * Returns the token string, or `null` when the helper is unavailable — callers
 * should `test.skip(token === null, ...)` so the spec is skipped rather than
 * failing when the flag is off (e.g. against production-like environments).
 */
export async function fetchConfirmationToken(
  request: APIRequestContext,
  email: string
): Promise<string | null> {
  const resp = await request.get(
    `/api/test/confirmation-token?email=${encodeURIComponent(email)}`
  );
  if (resp.status() === 404) return null;
  if (!resp.ok()) {
    throw new Error(
      `confirmation-token helper returned HTTP ${resp.status()} for ${email}`
    );
  }
  const body = await resp.json();
  return body.token as string;
}

/**
 * Sign in through the login form and wait for the post-login redirect.
 * Mirrors the flow the real user takes (fill → submit → door transition).
 */
export async function signInViaForm(
  page: Page,
  email: string,
  password: string
): Promise<void> {
  await page.goto("/login");
  await page.fill('input[id="email"]', email);
  await page.fill('input[id="password"]', password);
  await page.getByTestId("login-submit").click();
  await page.waitForURL("**/antilibrary", { timeout: 15000 });
}
