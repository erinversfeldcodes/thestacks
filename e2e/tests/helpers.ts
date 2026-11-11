import fs from "fs";
import path from "path";
import { createHmac } from "node:crypto";
import type { APIResponse } from "@playwright/test";
import { test, expect, SESSION_COOKIE } from "./fixtures";
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
  "empty-shelves",
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
  const outcome = await page.evaluate(async () => {
    // ⚠️ No `Authorization` header anywhere below, and no "do we have a
    // token" guard. These run in the page, so the session cookie goes with
    // every request automatically; the header was always redundant and the
    // guard was the shape that makes a precondition unable to fail.
    const firstPageResp = await fetch("/api/catalogue");
    if (!firstPageResp.ok) {
      return { why: "catalogue" as const, status: firstPageResp.status };
    }
    const firstPage = await firstPageResp.json();
    const visibleBooks: { id: string }[] = firstPage.books ?? [];
    if (visibleBooks.length === 0) return { why: "catalogue_empty" as const };

    const mineResp = await fetch("/api/placements/mine");
    const mineData = mineResp.ok ? await mineResp.json() : { placements: [] };
    const placedIds = new Set(
      (mineData.placements ?? []).map((p: any) => p.book_id),
    );

    if (visibleBooks.some((b) => placedIds.has(b.id))) {
      return { why: "already" as const };
    }

    const unplaced = visibleBooks.find((b) => !placedIds.has(b.id));
    if (!unplaced) return { why: "all_placed" as const };

    const placeResp = await fetch("/api/bookshelves/library/placements", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ book_id: unplaced.id }),
    });
    if (placeResp.ok) return { why: "placed" as const };
    return {
      why: "refused" as const,
      status: placeResp.status,
      body: (await placeResp.text()).slice(0, 300),
    };
  });

  switch (outcome.why) {
    case "already":
    case "placed":
    case "all_placed":
      return;

    case "catalogue_empty":
      assertSeedOrSkip(
        false,
        "the catalogue's first page is empty, so no book can be placed to satisfy this precondition",
      );
      return;

    default:
      // ⛔ THE WARNING THIS REPLACES COST A WHOLE DIAGNOSIS. This helper used
      // to `console.log("WARN: could not ensure a placed book…")` and return
      // normally, so a refused precondition surfaced as whatever the test
      // asserted next — `audit-log.spec.ts` failed on
      // `locator('.audit-log__row') … element(s) not found`, which reads as an
      // empty audit page rather than as a book that was never placed.
      //
      // ⚠️ And the warning was not even reliably visible: with the `list`
      // reporter the line is attached to the test's stdout, so "no WARN in the
      // log" is not evidence the placement succeeded. I read it as evidence
      // anyway and spent a pass hunting an audit-log defect.
      //
      // ⚖️ An empty catalogue stays a SKIP above — that is an environment
      // without seeds, not a fault. Everything here is the harness or the
      // server saying no, and both deserve to fail by name.
      expect(
        outcome,
        `could not place a book to satisfy this test's precondition: ${JSON.stringify(outcome)}`,
      ).toBeUndefined();
  }
}

/**
 * Ensure at least one book is placed on the given bookshelf.
 * Reuses the same logic as ensureBookOnLibrary but for any shelf name.
 */
export async function ensureBookOnShelf(
  page: Page,
  shelfName: string,
): Promise<void> {
  await page.goto(`/${shelfName}`);
  const placed = await page.evaluate(
    async ({ shelf }) => {
      const shelfResp = await fetch(`/api/bookshelves/${shelf}`);
      if (!shelfResp.ok) return false;
      const shelfData = await shelfResp.json();
      const allPlacements = (shelfData.shelves ?? []).flatMap(
        (s: any) => s.placements ?? [],
      );
      if (allPlacements.length > 0) return true;

      const mineResp = await fetch("/api/placements/mine");
      const mineData = mineResp.ok ? await mineResp.json() : { placements: [] };
      const placedIds = new Set(mineData.placements.map((p: any) => p.book_id));

      const catResp = await fetch("/api/catalogue?per_page=200");
      const catData = await catResp.json();
      const unplaced = catData.books.find((b: any) => !placedIds.has(b.id));
      if (!unplaced) return false;

      const placeResp = await fetch(`/api/bookshelves/${shelf}/placements`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ book_id: unplaced.id }),
      });
      if (placeResp.ok) return true;
      return `${placeResp.status} ${(await placeResp.text()).slice(0, 200)}`;
    },
    { shelf: shelfName },
  );

  // ⚠️ Same reasoning as `ensureBookOnLibrary` above: a precondition that
  // reports its own failure to a log nobody reads is a precondition that fails
  // silently, and the test then fails somewhere that does not name the cause.
  expect(
    placed,
    `could not ensure a book on the ${shelfName} shelf: ${typeof placed === "string" ? placed : "empty catalogue, or every visible book already placed"}`,
  ).toBe(true);
}

/**
 * API helper for making authenticated requests from E2E tests.
 * Extracts token from localStorage and calls the given endpoint.
 */
export async function apiCallFromPage(
  page: Page,
  method: string,
  path: string,
  body?: Record<string, unknown>,
): Promise<{ status: number; data: unknown }> {
  return page.evaluate(
    async ({ method, path, body }) => {
      // ⚠️ The credential is the cookie, which this `fetch` carries because
      // it runs in the page. The CSRF proof for an unsafe method is added by
      // the init script in `fixtures.ts`, not here.
      const headers: Record<string, string> = {};
      if (body) headers["Content-Type"] = "application/json";

      const resp = await fetch(path, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
      const data = await resp.json().catch(() => null);
      return { status: resp.status, data };
    },
    { method, path, body },
  );
}

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
  opts: { email: string; password: string; displayName?: string },
) {
  await authenticateOwner(request);
  const created = await request.post("/api/admin/invites", {
    data: { note: "registerViaApi" },
  });
  expect(created.status(), "registerViaApi invite mint").toBe(201);
  const invite_code = (await created.json()).invite.code as string;

  return request.post("/api/auth/register", {
    data: {
      email: opts.email,
      password: opts.password,
      display_name: opts.displayName ?? "E2E Newcomer",
      invite_code,
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
  email: string,
): Promise<string | null> {
  const resp = await request.get(
    `/api/test/confirmation-token?email=${encodeURIComponent(email)}`,
  );
  if (resp.status() === 404) return null;
  if (!resp.ok()) {
    throw new Error(
      `confirmation-token helper returned HTTP ${resp.status()} for ${email}`,
    );
  }
  const body = await resp.json();
  return body.token as string;
}

export interface SentEmail {
  to: string[];
  subject: string;
  html_body: string | null;
  text_body: string | null;
}

/**
 * Poll the sent-emails test-helper until at least one email addressed to
 * `email` appears (transactional email is delivered asynchronously via the
 * :notifications Oban queue). Reads the Swoosh Local mailbox, so it proves the
 * message was actually SENT — not just that a DB token exists.
 *
 * Returns the emails, `null` when the helper is unavailable (flag off — callers
 * should `test.skip`), or `[]` if none arrived before the timeout.
 */
export async function fetchSentEmails(
  request: APIRequestContext,
  email: string,
  opts: { timeoutMs?: number } = {},
): Promise<SentEmail[] | null> {
  const timeoutMs = opts.timeoutMs ?? 20_000;
  const deadline = Date.now() + timeoutMs;
  const url = `/api/test/sent-emails?email=${encodeURIComponent(email)}`;

  while (Date.now() < deadline) {
    const resp = await request.get(url);
    if (resp.status() === 404) return null;
    if (!resp.ok()) {
      throw new Error(
        `sent-emails helper returned HTTP ${resp.status()} for ${email}`,
      );
    }
    const body = await resp.json();
    if (body.mailbox_readable === false) return null;
    if (Array.isArray(body.emails) && body.emails.length > 0) {
      return body.emails as SentEmail[];
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  return [];
}

/**
 * Extract the first URL matching `pattern` from an email's html/text body —
 * e.g. the /api/auth/confirm/:token or /reset-password/:token link.
 */
export function extractLink(email: SentEmail, pattern: RegExp): string | null {
  const haystack = `${email.html_body ?? ""} ${email.text_body ?? ""}`;
  const match = haystack.match(pattern);
  return match ? match[0] : null;
}

export interface MintedSession {
  email: string;
  token: string;
  userId: string;
  displayName: string;
}

/**
 * Mint a fresh, CONFIRMED user with a ready-to-use session token in one call
 * via the POST /api/test/session helper (STACKS_E2E_TEST_HELPERS=1 only).
 * Unlike register→confirm→login, this does NOT consume the shared `:auth`
 * rate bucket (60/60s per IP), so parallel fresh-user specs cannot 429 each
 * other. The server enforces a hard `.test`-domain allowlist; the minted
 * user's password is E2E_PASSWORD if a spec later needs the real login form.
 *
 * Returns `null` when the helper is unavailable (flag off) — callers should
 * `test.skip(session === null, ...)`, matching fetchConfirmationToken.
 */
export async function mintSession(
  request: APIRequestContext,
  opts: { email?: string; displayName?: string } = {},
): Promise<MintedSession | null> {
  const resp = await request.post("/api/test/session", {
    data: {
      ...(opts.email ? { email: opts.email } : {}),
      ...(opts.displayName ? { display_name: opts.displayName } : {}),
    },
  });
  if (resp.status() === 404) return null;
  if (resp.status() !== 201) {
    throw new Error(`session-mint helper returned HTTP ${resp.status()}`);
  }
  const body = await resp.json();
  return {
    email: body.email as string,
    token: body.token as string,
    userId: body.user_id as string,
    displayName: body.display_name as string,
  };
}

/**
 * Seed a VISIBLE blog-post→book association for a minted `.test`-domain user via
 * POST /api/test/book-writing (STACKS_E2E_TEST_HELPERS=1 only), so a spec can
 * drive the spine bookmark ribbon deterministically. The production path
 * associates books via an async LLM worker on publish, which is non-deterministic
 * for a browser test; this helper writes the same end state (visible manual
 * association) directly. Asserts 201 — the caller has already minted a session,
 * so the STACKS_E2E_TEST_HELPERS flag is guaranteed on by the time this runs.
 */
export async function seedBookWriting(
  request: APIRequestContext,
  email: string,
  bookId: string,
): Promise<void> {
  const resp = await request.post("/api/test/book-writing", {
    data: { email, book_id: bookId },
  });
  expect(resp.status(), `seed writing for book ${bookId}`).toBe(201);
}

/**
 * Seed a post whose book-association pass FINISHED WITH NO ASSOCIATIONS,
 * recording `outcome` — the state an author sees when the pass found nothing or
 * could not run.
 *
 * ⛔ THE FAILING HALF HAD NO DRIVABLE ROUTE. `seedBookWriting` above writes the
 * happy path, and production reaches the failure outcomes only through an async
 * LLM worker whose result a browser test cannot steer. So the surface that tells
 * an author "we couldn't link books to this post" had never been seen rendered.
 *
 * ⚖️ `outcome` is validated server-side against the worker's own closed
 * vocabulary, so this cannot seed a state production never reaches. Asserts 201
 * — the caller has already minted a session, so the STACKS_E2E_TEST_HELPERS flag
 * is guaranteed on by the time this runs.
 */
export async function seedAssociationOutcome(
  request: APIRequestContext,
  email: string,
  outcome:
    | "associated"
    | "no_books_found"
    | "unreadable_response"
    | "unexpected_shape"
    | "llm_error",
): Promise<string> {
  const resp = await request.post("/api/test/association-outcome", {
    data: { email, outcome },
  });
  expect(resp.status(), `seed association outcome ${outcome}`).toBe(201);
  const body = await resp.json();
  return body.post_id as string;
}

/**
 * Make this browser context be this user, and nobody else.
 *
 * ⛔ THE CONTRACT IS EXCLUSIVE, and that is the part worth stating. The server
 * accepts a session by cookie OR by bearer header during the rollout, and
 * `AuthPipeline` runs `SessionCookie` BEFORE `VerifyHeader`, so **the cookie
 * wins when present**. A context that already holds a different user's
 * `stacks_session` would therefore keep authenticating as that user while the
 * token injected here sat unused — and the symptom is not an error, it is the
 * minted user's data being absent. A spec would report "my placement did not
 * render" over a stack that rendered the wrong reader's shelf correctly.
 *
 * ⚖️ So this clears before it sets, and sets ONE credential: the cookie. It
 * used to set a `localStorage` blob beside it, because the SPA read its
 * identity from there — that blob is gone, along with every spec that read it,
 * so there is nothing left for a second write to keep in step.
 *
 * ⚠️ The cookie's attributes must MATCH the ones the server sets
 * (`HttpOnly; Secure; SameSite=Lax`). A cookie that differs is silently ignored
 * and looks exactly like logged-out — the same class of trap as the old
 * "`stacks-auth` must be a FLAT blob" one it replaces, and a `clearCookies`
 * whose filter does not match clears nothing at all.
 */
export async function injectSession(
  page: Page,
  session: MintedSession,
): Promise<void> {
  const context = page.context();

  // ⚠️ Navigate FIRST, so the origin the cookie is scoped to comes from the page
  // rather than from a constant this file would have to keep in step with
  // `BASE_URL`. `addCookies` takes a `url` and derives domain and path from it,
  // which is one fewer attribute to get silently wrong.
  await page.goto("/");
  const origin = new URL(page.url()).origin;

  await context.clearCookies({ name: SESSION_COOKIE });
  await context.addCookies([
    {
      name: SESSION_COOKIE,
      value: session.token,
      url: origin,
      httpOnly: true,
      secure: true,
      sameSite: "Lax",
    },
  ]);
}

/**
 * Sign this browser context in as the seeded OWNER, without the login form.
 *
 * ⛔ Replaces two private copies of the same helper (`admin-session.spec.ts`
 * and `admin-feedback.spec.ts` each had one, both titled "Must be a FLAT blob")
 * which logged in through `request` and then wrote the response into
 * `localStorage`. Both halves of that stopped working: the SPA reads no blob,
 * and the `request` fixture is a SEPARATE context, so the login's `Set-Cookie`
 * landed in the request context's jar and never reached the page.
 *
 * ⚠️ `mintSession` is NOT a substitute here. It mints a `.test`-domain user by
 * server-enforced allowlist, and these specs need the owner specifically — the
 * surfaces under test are role-gated.
 */
export async function signInAsOwner(
  page: Page,
  request: APIRequestContext,
): Promise<void> {
  const login = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(login.status(), "owner login for an admin spec").toBe(200);
  const body = await login.json();

  await injectSession(page, {
    email: body.user.email as string,
    token: body.token as string,
    userId: body.user.id as string,
    displayName: body.user.display_name as string,
  });
}


/**
 * Whether this browser context holds a session cookie.
 *
 * ⛔ THE REPLACEMENT FOR `localStorage.getItem("stacks-auth")`, which around
 * thirty assertions used as a stand-in for "is this reader signed in". That
 * stand-in stopped meaning anything when the SPA stopped writing the blob: a
 * reader who signs in through the form now has a live session and an empty
 * `localStorage`, so `toBeFalsy()` passes and `toBeTruthy()` fails, and NEITHER
 * is reporting on the session.
 *
 * ⚠️ Asks the CONTEXT, not the page. The cookie is `HttpOnly`, so
 * `document.cookie` cannot see it and an in-page `evaluate` would answer "no
 * session" for every signed-in reader — the same silent wrong answer in a new
 * disguise. Playwright's context sees it because it owns the cookie jar.
 *
 * ⚖️ It reports PRESENCE, not validity. A corrupted cookie (what `expireSession`
 * installs) is still a cookie, so a test asserting that an expired session is
 * refused must assert on the REFUSAL, not on this. The one thing this answers is
 * whether a credential was issued or torn down.
 */
export async function hasSessionCookie(page: Page): Promise<boolean> {
  const cookies = await page.context().cookies();
  return cookies.some((c) => c.name === SESSION_COOKIE);
}


/**
 * Make this context carry no credential at all.
 *
 * ⛔ WHY OMITTING A HEADER IS NO LONGER ENOUGH, and this is the half that broke
 * four specs the moment the harness started saving the session cookie. A spec
 * that wanted an anonymous request used to get one for free by leaving
 * `Authorization` off, because the bearer header was the only credential a
 * context could hold. The session is a cookie now, which `AuthPipeline` prefers
 * — so an in-page `fetch` with no header is authenticated, and an assertion like
 * "these endpoints return 401 when not authenticated" reads 200 instead.
 *
 * ⚠️ DELETES rather than corrupts, which is the opposite choice from
 * `expireSession` and for the opposite reason: "never signed in" is exactly the
 * state being asserted here, whereas a present-but-invalid credential would
 * exercise the expiry path instead and could answer 401 for the wrong reason.
 */
export async function goAnonymous(page: Page): Promise<void> {
  await page.context().clearCookies({ name: SESSION_COOKIE });
}

/**
 * End the session the way an expiry actually ends one.
 *
 * ⛔ WHY THIS EXISTS AS A HELPER. Five specs ended a session by corrupting the
 * bearer token in `localStorage`, which was complete before the cookie existed
 * and became a no-op on the path that matters: measured on a preview, a context
 * whose stored token had been corrupted still got **200** from
 * `/api/placements/mine`, `/api/bookshelves/library` and
 * `/api/onboarding/status`, because the HttpOnly cookie authenticated every one
 * of them — and nothing redirected to `/login`. The blob is gone now, so the
 * cookie is the only thing there is to corrupt.
 *
 * ⚠️ Corrupts rather than deletes, deliberately. Deleting both credentials
 * produces "never signed in", which routes to `/login` for a different reason
 * and would let a spec asserting the session-expired notice pass without the
 * expiry path running at all. A present-but-invalid credential is what an
 * expired session actually looks like.
 */
export async function expireSession(page: Page): Promise<void> {
  const context = page.context();
  const existing = (await context.cookies()).find((c) => c.name === SESSION_COOKIE);

  // ⛔ THROWS rather than no-opping on an absent cookie. A silent no-op here
  // leaves the session INTACT, and the test then asserts expiry behaviour
  // against a live session — passing or failing for a reason that has nothing to
  // do with what it set out to measure.
  if (!existing) {
    throw new Error(
      `expireSession: this context holds no ${SESSION_COOKIE} cookie, so there ` +
        `is no session to expire. Establish one first (injectSession or ` +
        `signInViaForm).`,
    );
  }

  await context.clearCookies({ name: SESSION_COOKIE });
  await context.addCookies([
    { ...existing, value: `${existing.value}.expired` },
  ]);
}

/**
 * Sign in through the login form and wait for the post-login redirect.
 * Mirrors the flow the real user takes (fill → submit → door transition).
 */
export async function signInViaForm(
  page: Page,
  email: string,
  password: string,
): Promise<void> {
  await page.goto("/login");
  await page.fill('input[id="email"]', email);
  await page.fill('input[id="password"]', password);
  await page.getByTestId("login-submit").click();
  await page.waitForURL("**/antilibrary", { timeout: 15000 });
}

/** Shared skip reason when the session-mint helper is unavailable (flag off). */
export const SESSION_HELPER_SKIP =
  "POST /api/test/session unavailable (STACKS_E2E_TEST_HELPERS off)";

/**
 * mintSession + `test.skip` guard in one call, for specs that mint one or more
 * fresh users where registration/confirmation is NOT the subject.
 * When the helper endpoint is unavailable (prod-shaped targets), `test.skip`
 * aborts the test cleanly BEFORE this returns, so callers get a guaranteed
 * non-null session with no null check — the same clean-skip contract as the
 * inline `mintSession` + `test.skip` pattern in reading-journey/gdpr, minus the
 * `:auth`-bucket cost of the register→confirm→login dance it replaces.
 */
export async function mintOrSkip(
  request: APIRequestContext,
  opts: { email?: string; displayName?: string } = {},
): Promise<MintedSession> {
  const session = await mintSession(request, opts);
  test.skip(session === null, SESSION_HELPER_SKIP);
  return session as MintedSession;
}

/**
 * Seed-data guarantee gate (, PE P3-5). A spec that needs specific
 * seeded catalogue data (e.g. ≥51 books for the reading-pile cap, or a book
 * with page_count ≥ 10 for the progress journey) normally skips loudly when the
 * target lacks it — correct for prod-shaped or thin targets. But a stack that
 * SHOULD carry the full dev-fixture seed silently skipping forever hides a seed
 * regression. Set `E2E_EXPECT_FULL_SEEDS=1` (the preview/CI E2E step) to turn an
 * insufficient-seed skip into a HARD FAILURE. Mirrors the `E2E_EXPECT_LIVE_METRICS`
 * enforcement gate in transparency.spec.ts.
 *
 * @param sufficient  true when the required seed data is present.
 */
export function assertSeedOrSkip(sufficient: boolean, message: string): void {
  if (process.env.E2E_EXPECT_FULL_SEEDS === "1") {
    expect(sufficient, `E2E_EXPECT_FULL_SEEDS=1 but ${message}`).toBe(true);
  } else {
    test.skip(!sufficient, message);
  }
}

/**
 * Email-send budget gate, mirroring `assertSeedOrSkip` — but limb-aware,
 * because the two limbs of this limit mean opposite things.
 *
 * ⛔ WHY A GATE AND NOT A RETRY. An email change is refused with
 * `429 {"error":"email_rate_limited"}` and `retry-after: 3600` when the two
 * letters it is made of cannot be sent — a deliberate refusal, because
 * recording the change anyway would leave a pending change nobody holds a link
 * to. The window is an HOUR, so the `retryOn503` treatment used for Argon2
 * back-pressure is not available: there is nothing to wait out inside a test.
 *
 * ⚠️ MEASURED: a brand-new minted user is refused on its FIRST attempt, so the
 * budget is not per-user and giving the spec its own user does not help. It is
 * exhausted by the suite's own repeated runs against a shared stack, which is
 * why a spec asserting the email-change journey fails deterministically for an
 * hour after enough runs — looking exactly like a broken feature.
 *
 * ⛔ NOT A SILENT SKIP. This repository has a recorded case of
 * `test.skip(status === 502)` swallowing a real failure and making a test unable
 * to fail. So `E2E_EXPECT_EMAIL_DELIVERY=1` — set it on any stack that is
 * supposed to be able to send — turns the skip into a HARD FAILURE, and the skip
 * reason names the budget rather than the feature.
 */
export async function assertEmailBudgetOrSkip(
  response: APIResponse,
): Promise<void> {
  if (response.status() !== 429) return;

  const body = (await response.json().catch(() => ({}))) as { limb?: string };

  // ⛔ THE GLOBAL LIMB IS THE SUITE'S OWN EXHAUST, NOT A FAILURE. The limit is
  // counted from `oban_jobs` rows in the last hour — 10 per user, 100 across
  // the stack — and this suite registers a user per test, each queuing a
  // confirmation. So it fills the global bucket by running, and enforcing
  // delivery against that would make CI deterministically red for a condition
  // the harness creates. Always a skip, flag or no flag.
  if (body.limb === "global") {
    test.skip(
      true,
      "the stack's HOURLY GLOBAL email budget is full (429 email_rate_limited, " +
        "limb=global). That bucket is filled by this suite itself — a user per " +
        "test, each queuing a confirmation — so it is harness volume, not a " +
        "delivery fault. Not enforceable by E2E_EXPECT_EMAIL_DELIVERY.",
    );
    return;
  }

  // ⚠️ `per_user` is a different claim: ten sends in an hour for ONE account,
  // and these specs mint a fresh user, so reaching it means something real.
  // Enforceable, and NOT a silent skip — this repository has a recorded case of
  // `test.skip(status === 502)` swallowing a real failure.
  const message =
    `the email-change send was refused 429 email_rate_limited (limb=` +
    `${body.limb ?? "unreported"}) for a freshly minted user, which is not the ` +
    `suite's shared budget — ten sends in an hour for one account`;
  if (process.env.E2E_EXPECT_EMAIL_DELIVERY === "1") {
    expect(false, `E2E_EXPECT_EMAIL_DELIVERY=1 but ${message}`).toBe(true);
  } else {
    test.skip(true, message);
  }
}

/**
 * The same gate as `assertEmailBudgetOrSkip`, asked BEFORE the send instead of
 * read off the refusal.
 *
 * ⛔ WHY BOTH SHAPES EXIST. An email CHANGE refuses out loud —
 * `429 {"error":"email_rate_limited","limb":…}` — so the refusal carries its
 * own reason and the response-shaped helper can read it. "Forgot my password"
 * and "resend confirmation" answer identically whether or not a letter was
 * queued, deliberately, so that neither reveals whether an address has an
 * account. A spec driving one of those sees only "no mail arrived", which is
 * the same observation for a broken feature and for a full bucket.
 *
 * ⚠️ AND THE SUITE IS WHAT FILLS THE BUCKET. The limit counts `oban_jobs`
 * rows in the last hour — 10 per user, 100 across the stack — and this suite
 * registers a user per test, each queuing a confirmation. Measured on a local
 * stack after three consecutive runs: 101 `EmailDeliveryJob` rows in the hour,
 * and the three email specs all failed with `expected a password-reset email`.
 * That looked like a delivery defect and is not one.
 *
 * ⚖️ Global exhaustion is always a skip — harness volume, not a fault, and not
 * enforceable by `E2E_EXPECT_EMAIL_DELIVERY`, exactly as in the sibling. A
 * missing helper endpoint is NOT a skip: it means the harness could not ask,
 * and a spec that skipped on that would go quiet for the wrong reason.
 */
export async function skipIfGlobalEmailBudgetFull(
  request: APIRequestContext,
): Promise<void> {
  const resp = await request.get("/api/test/email-budget");
  if (resp.status() === 404) return;

  expect(
    resp.ok(),
    `GET /api/test/email-budget answered ${resp.status()}, so the email budget ` +
      `could not be read and a missing letter cannot be attributed`,
  ).toBeTruthy();

  const budget = (await resp.json()) as {
    global_count: number;
    global_limit: number;
  };

  test.skip(
    budget.global_count >= budget.global_limit,
    `the stack's HOURLY GLOBAL email budget is full (${budget.global_count} of ` +
      `${budget.global_limit} sends in the last hour). That bucket is filled by ` +
      `this suite itself — a user per test, each queuing a confirmation — so it ` +
      `is harness volume, not a delivery fault.`,
  );
}

/**
 * Mint a fresh, empty-collection user, place one catalogue book on `shelf` via
 * the normal placement API, and land the browser authenticated as that user.
 * Returns the session and the placed book's id.
 *
 * Because the user is brand-new, the ONLY active placement in their collection
 * is the one created here — a mutation test (move/remove) can drain it without
 * touching the shared suite seed, so repeated local runs stay deterministic
 *. Mirrors the per-test provisioning in spine-rendering.spec.ts:
 * build the exact shelf state the test asserts against instead of consuming a
 * shared seed. Skips cleanly when the session helper is off (mintOrSkip) or the
 * catalogue is empty (assertSeedOrSkip).
 */
export async function provisionBookOnShelf(
  page: Page,
  request: APIRequestContext,
  shelf: string,
): Promise<{ session: MintedSession; bookId: string }> {
  const session = await mintOrSkip(request);
  const resp = await request.get("/api/catalogue?per_page=1");
  expect(resp.ok(), "catalogue fetch for shelf provisioning").toBeTruthy();
  const data = await resp.json();
  const book = ((data.books ?? []) as Array<{ id: string }>)[0];
  assertSeedOrSkip(
    book !== undefined,
    "catalogue has no books to provision a shelf placement",
  );
  const place = await request.post(`/api/bookshelves/${shelf}/placements`, {
    headers: { Authorization: `Bearer ${session.token}` },
    data: { book_id: book.id },
  });
  // ⚠️ The body is in the message because the status alone is not diagnosable:
  // a 422 here was read as a product defect in placements for a stretch, and the
  // reason the server gave was discarded by this very line.
  expect(
    place.status(),
    `place book ${book.id} on ${shelf} as a freshly minted user: ${
      place.status() === 201 ? "" : (await place.text()).slice(0, 300)
    }`,
  ).toBe(201);
  await injectSession(page, session);
  return { session, bookId: book.id };
}

/**
 * Where the run's single owner TOTP secret lives. `.auth/` is gitignored and is
 * already the home of every other cross-project auth artefact this suite mints.
 */
export const ADMIN_MFA_FILE = path.join(AUTH_DIR, "admin-mfa.json");

/** Base32 → bytes. The `otpauth://` provisioning URI carries the secret this way (RFC 4648). */
export function base32Decode(input: string): Buffer {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const char of input.replace(/=+$/, "").toUpperCase()) {
    const idx = alphabet.indexOf(char);
    if (idx < 0) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** RFC 6238 TOTP, SHA-1, 6 digits, 30s step — what an authenticator app would show. */
export function totp(secretBase32: string, atMs: number = Date.now()): string {
  const counter = Math.floor(atMs / 1000 / 30);
  const buf = Buffer.alloc(8);
  buf.writeUInt32BE(counter, 4);
  const mac = createHmac("sha1", base32Decode(secretBase32)).update(buf).digest();
  const offset = mac[mac.length - 1] & 0x0f;
  const bin =
    ((mac[offset] & 0x7f) << 24) |
    (mac[offset + 1] << 16) |
    (mac[offset + 2] << 8) |
    mac[offset + 3];
  return String(bin % 1_000_000).padStart(6, "0");
}

/**
 * A TOTP code guaranteed to still be inside its 30-second validity window when
 * the server checks it.
 *
 * The server validates with a bare `NimbleTOTP.valid?` — EXACTLY the current
 * 30s step, no ±1-step allowance (`Stacks.MFA` confirm_enrollment/verify_totp).
 * A code computed from the local clock in the last moments of a step is
 * therefore rejected when validation lands in the next step — an intermittent
 * 422 whose per-run probability is (latency + clock skew)/30s, i.e. "passes one
 * run, fails the next at identical code". Root cause of the flake.
 *
 * Deterministic fix, not a retry: when the (server-adjusted) clock is inside
 * the guard band before a step boundary, wait the boundary out, then compute.
 * The code presented is always fresh for ≥ GUARD_MS − skew-estimate error, and
 * a genuine encoding regression still fails every run rather than being
 * retried into a green.
 *
 * `skewMs` is server-minus-local, best taken from a response's `Date` header
 * (1s granularity — see `enrolOwnerMfa`). Defaulting it to 0 still removes the
 * dominant boundary race; the skew term guards against a drifted clock.
 */
export async function freshTotp(secretBase32: string, skewMs = 0): Promise<string> {
  const STEP_MS = 30_000;
  const GUARD_MS = 5_000;
  const serverNow = () => Date.now() + skewMs;
  const intoStep = serverNow() % STEP_MS;
  if (intoStep > STEP_MS - GUARD_MS) {
    await new Promise((resolve) => setTimeout(resolve, STEP_MS - intoStep + 250));
  }
  return totp(secretBase32, serverNow());
}

/**
 * Enrol a second factor for the seeded owner and return the base32 secret.
 *
 * ⚠️ **Call this from `auth.setup.ts` ONLY — never from a test.** `op.user_mfa`
 * holds exactly ONE row per user (`conflict_target: :user_id` in
 * `Stacks.MFA.confirm_enrollment/4`), and the owner is a single shared account, so
 * enrolling REPLACES whatever factor was there. Called per-test at the shipped
 * worker count (`workers: CI ? 2 : 4`), spec A enrols S₁, spec B replaces it with
 * S₂, and A's `totp(S₁)` is then rejected — surfacing as a gate that never opens,
 * which is indistinguishable from the four real defects `admin-session.spec.ts`
 * exists to catch. Doing it once, in the `setup` project every other
 * project depends on, leaves the factor immutable for the whole parallel phase: the
 * tests only ever READ it.
 *
 * ⚠️ Enrolment cannot be done once and kept — a preview redeploy recreates the Neon
 * branch — so it must be re-done per run, which is exactly what the setup project is
 * for. Verification has no replay protection (`Stacks.MFA.verify_totp/2` is a bare
 * `NimbleTOTP.valid?`), so parallel specs presenting the same code in the same 30 s
 * step is fine; only REPLACING the factor is not.
 *
 * ⚠️ The `secret` is sent **exactly as the URI carries it** — base32. The endpoint
 * used to demand base64 of the raw bytes, which no client could produce, and getting
 * it wrong returns `422 invalid_code`, reading as clock skew. Do not "helpfully"
 * convert it.
 */
export async function enrolOwnerMfa(request: APIRequestContext): Promise<string> {
  const login = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(login.status(), "owner login for MFA enrolment").toBe(200);
  const ownerToken = (await login.json()).token as string;
  const auth = { Authorization: `Bearer ${ownerToken}` };

  const setup = await request.post("/api/admin/auth/mfa/setup", {
    headers: auth,
    data: {},
  });
  expect(setup.status(), "mfa setup").toBe(200);

  const setupDate = setup.headers()["date"];
  const skewMs = setupDate ? new Date(setupDate).getTime() + 500 - Date.now() : 0;

  const { provisioning_uri, recovery_codes } = await setup.json();

  const secret = new URL(
    String(provisioning_uri).replace("otpauth://", "https://"),
  ).searchParams.get("secret");
  expect(secret, "the provisioning URI must carry a base32 secret").toBeTruthy();

  const confirm = await request.post("/api/admin/auth/mfa/confirm", {
    headers: auth,
    data: { totp_code: await freshTotp(secret!, skewMs), secret: secret!, recovery_codes },
  });
  expect(
    confirm.status(),
    "mfa confirm — a 422 here usually means the secret encoding regressed, not a bad code",
  ).toBe(200);

  return secret!;
}

/**
 * An MFA-verified owner ADMIN token: login, then verify
 * with a fresh TOTP from the run's shared factor (enrolled once by
 * auth.setup.ts — never re-enrol here,).
 */
// ⛔ ONE ELEVATION PER CONTEXT, memoised — repeating it FAILS, and the failure
// is a 401 that looks like bad credentials.
//
// MEASURED: calling this per admin write (`invite-gate`'s `adminAuth` runs on
// every `mintInvite`) turned 13 failures into 6, all of them `admin MFA verify
// -> 401`. Two independent reasons, either sufficient:
//
//   * a TOTP code is single-use, and two elevations inside one 30-second step
//     present the same code, so the second is a replay and is refused;
//   * `SessionContext.create/3` revokes the operator's OTHER live sessions, so
//     a second admin login invalidates the `session_id` the first one is still
//     holding — `invalid_session`, also a 401.
//
// ⚖️ A `WeakSet` keyed on the context, rather than a module flag, because
// elevation is a fact about the session THAT context holds: two contexts in one
// file must each elevate, and neither should be told the other already did.
// A `WeakSet` also lets the context be collected without this leaking it.
const ownerAuthedContexts = new WeakSet<APIRequestContext>();

/**
 * Give this context the owner's ordinary session, and prove the operator is
 * still elevated.
 *
 * ⛔ THIS DOES NOT ELEVATE. Elevation happens ONCE, in `auth.setup.ts`, because
 * it is a property of the operator rather than of the worker:
 * `Admin.SessionContext.current_for_user/2` finds the newest non-revoked admin
 * session for the USER, so an admin write needs only an owner session cookie plus
 * one live elevated session existing anywhere. Elevating here instead revokes
 * every other worker's session (`create/3` retires live sessions first), which is
 * what produced `admin MFA verify -> 401` at four workers and 0 failures at one.
 *
 * ⚠️ The probe below exists because elevation can lapse for reasons that have
 * nothing to do with the test: the MFA window is 30 minutes from
 * `mfa_verified_at`, and `check_valid/2` also matches `boot_id` and IP — so a
 * preview machine auto-stopping mid-run kills it for everyone at once. Without
 * this, that surfaces as `invite create -> 401` and reads like a credentials bug
 * in whichever spec happened to run next.
 */
export async function authenticateOwner(
  request: APIRequestContext,
): Promise<void> {
  if (ownerAuthedContexts.has(request)) {
    return;
  }

  const session = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(session.status(), "owner session login").toBe(200);

  const elevated = await request.get("/api/admin/invites");
  expect(
    elevated.status(),
    "the operator is not elevated. auth.setup.ts elevates once per run; this " +
      "is a LAPSE, not a credentials problem. Either the 30-minute MFA window " +
      "expired (a long or retrying run), or the stack restarted and changed its " +
      "boot_id (preview machines auto-stop) — both invalidate the admin session " +
      "for every worker simultaneously",
  ).toBe(200);

  ownerAuthedContexts.add(request);
}

const elevatedContexts = new WeakSet<APIRequestContext>();

export async function elevateOwnerAdmin(
  request: APIRequestContext,
): Promise<void> {
  if (elevatedContexts.has(request)) {
    return;
  }

  // ⛔ ELEVATION IS A FACT ABOUT THE SESSION THE SERVER HOLDS, so there is no
  // token to collect and nothing to put in an `Authorization` header. This
  // replaces `ownerAdminToken`, which returned
  // `(await verify.json()).token` — a field `verify_mfa` NO LONGER SENDS. Its
  // moduledoc is explicit: "NO TOKEN IN THE RESPONSE", because
  // `mark_mfa_verified/1` records the elevation server-side and
  // `AdminAuthPipeline` now reads the ordinary session cookie instead of a
  // second Guardian token from the header.
  //
  // ⛔ THE FAILURE THAT CAUSED WAS NOT LOCAL TO THIS FUNCTION. Reading a
  // missing field yields `undefined`, so callers sent the literal header
  // `Authorization: Bearer undefined` and got a **401 thirteen tests
  // downstream**, under messages about invites — in `invite-gate` (×4),
  // `register` (×6), `confirm-email` (×2) and `login` (×1). Every one of those
  // looked like a broken signup funnel. The funnel was fine.
  //
  // ⚖️ The lesson is the `expect` on the BODY below, not the sequence above:
  // the old helper asserted `verify.status() === 200` and then read a field it
  // never checked existed. A 200 was a true statement about the request and
  // said nothing about the shape of the reply, so a contract change that
  // removed a field produced `undefined` rather than a failure. Assert the
  // thing you are about to use.
  //
  // The ordinary session must be established FIRST — the admin chain starts
  // from it, and this context never loads a page, so nothing else would set it.
  const session = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(session.status(), "owner session login").toBe(200);

  const login = await request.post("/api/admin/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(login.status(), "admin login").toBe(200);
  const { session_id } = await login.json();

  const verify = await request.post("/api/admin/auth/verify_mfa", {
    data: { session_id, totp_code: await freshTotp(readOwnerMfaSecret()) },
  });
  expect(verify.status(), "admin MFA verify").toBe(200);
  expect(
    (await verify.json()).verified,
    "verify_mfa must confirm the elevation in its body — a 200 alone is a " +
      "statement about the request, not about what came back",
  ).toBe(true);

  elevatedContexts.add(request);
}

/** Persist the run's single owner TOTP secret for the parallel phase to read. */
export function saveOwnerMfaSecret(secret: string): void {
  fs.mkdirSync(AUTH_DIR, { recursive: true });
  fs.writeFileSync(ADMIN_MFA_FILE, JSON.stringify({ secret }), "utf8");
}

/**
 * Read the owner TOTP secret enrolled by `auth.setup.ts`. Throws — loudly, and
 * naming the cause — rather than letting a missing file degrade into a gate that
 * silently never opens.
 */
export function readOwnerMfaSecret(): string {
  if (!fs.existsSync(ADMIN_MFA_FILE)) {
    throw new Error(
      `No owner MFA secret at ${ADMIN_MFA_FILE}. It is enrolled ONCE by the ` +
        `"enrol the owner's admin MFA factor" step in auth.setup.ts, which every ` +
        `project depends on — run with the setup project (do not pass --no-deps).`,
    );
  }
  const { secret } = JSON.parse(fs.readFileSync(ADMIN_MFA_FILE, "utf8"));
  expect(secret, `${ADMIN_MFA_FILE} carries no secret`).toBeTruthy();
  return secret as string;
}
