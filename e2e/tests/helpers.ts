import fs from "fs";
import path from "path";
import { createHmac } from "node:crypto";
import { test, expect } from "@playwright/test";
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
    const mineData = mineResp.ok ? await mineResp.json() : { placements: [] };
    const placedIds = new Set(
      (mineData.placements ?? []).map((p: any) => p.book_id),
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
    console.log(
      "WARN: could not ensure a placed book is visible on the catalogue first page",
    );
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
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      if (!auth.token) return false;

      const shelfResp = await fetch(`/api/bookshelves/${shelf}`, {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      if (!shelfResp.ok) return false;
      const shelfData = await shelfResp.json();
      // API returns {shelves: [{placements: [...]}]} after #151 shelf entity change
      const allPlacements = (shelfData.shelves ?? []).flatMap(
        (s: any) => s.placements ?? [],
      );
      if (allPlacements.length > 0) return true;

      // Shelf is empty — find an unplaced book and place it
      const mineResp = await fetch("/api/placements/mine", {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      const mineData = mineResp.ok ? await mineResp.json() : { placements: [] };
      const placedIds = new Set(mineData.placements.map((p: any) => p.book_id));

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
    { shelf: shelfName },
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
  body?: Record<string, unknown>,
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
    { method, path, body },
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
  opts: { email: string; password: string; displayName?: string },
) {
  // US-14.1.3: the preview runs invite-gated (the launch posture), so every
  // registration carries a fresh owner-issued single-use code. Ignored by the
  // server when the gate is off, so this helper works in both postures.
  const adminToken = await ownerAdminToken(request);
  const created = await request.post("/api/admin/invites", {
    headers: { Authorization: `Bearer ${adminToken}` },
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
    // A real provider (Resend) is configured — mail never lands in the Local
    // mailbox, so reading it is meaningless. Signal "unavailable" so callers
    // test.skip rather than failing on an expectedly-empty inbox.
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

// ── Session-mint helper (Issue #192) ───────────────────────────────────────

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
 * drive the spine bookmark ribbon (#287) deterministically. The production path
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
 * Land the browser authenticated as a minted user by injecting the session
 * into localStorage under "stacks-auth" — the exact shape the Elm saveAuth
 * port writes and auth.setup.ts injects. The NEXT page.goto() boots the SPA
 * with the session present, skipping the login form and door animation.
 */
export async function injectSession(
  page: Page,
  session: MintedSession,
): Promise<void> {
  // Navigate to the app origin first so localStorage is writable for it.
  await page.goto("/");
  await page.evaluate(
    (auth) => {
      localStorage.setItem("stacks-auth", JSON.stringify(auth));
    },
    {
      token: session.token,
      userId: session.userId,
      email: session.email,
      displayName: session.displayName,
    },
  );
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
 * fresh users where registration/confirmation is NOT the subject (Issue #280).
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
  // `test.skip` throws when the condition holds, so this line is only reached
  // with a real (non-null) session.
  return session as MintedSession;
}

/**
 * Seed-data guarantee gate (Issue #280, PE P3-5). A spec that needs specific
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

// ── Per-test shelf provisioning (Issue #294) ───────────────────────────────

/**
 * Mint a fresh, empty-collection user, place one catalogue book on `shelf` via
 * the normal placement API, and land the browser authenticated as that user.
 * Returns the session and the placed book's id.
 *
 * Because the user is brand-new, the ONLY active placement in their collection
 * is the one created here — a mutation test (move/remove) can drain it without
 * touching the shared suite seed, so repeated local runs stay deterministic
 * (#294). Mirrors the per-test provisioning in spine-rendering.spec.ts (#113):
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
  expect(place.status(), `place book on ${shelf}`).toBe(201);
  await injectSession(page, session);
  return { session, bookId: book.id };
}

// ── The owner's admin MFA factor (Issue #371) ──────────────────────────────

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
 * the server checks it (#394).
 *
 * The server validates with a bare `NimbleTOTP.valid?` — EXACTLY the current
 * 30s step, no ±1-step allowance (`Stacks.MFA` confirm_enrollment/verify_totp).
 * A code computed from the local clock in the last moments of a step is
 * therefore rejected when validation lands in the next step — an intermittent
 * 422 whose per-run probability is (latency + clock skew)/30s, i.e. "passes one
 * run, fails the next at identical code". Root cause of the #394 flake.
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
 * which is indistinguishable from the four real #303 defects `admin-session.spec.ts`
 * exists to catch (Issue #371). Doing it once, in the `setup` project every other
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

  // Server-minus-local clock skew from the response's own Date header (1s
  // granularity; +500ms centres the truncation). Feeds freshTotp so the
  // confirm code is computed against the SERVER's step, not ours (#394).
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
 * An MFA-verified owner ADMIN token (US-14.1.3 / #384): login, then verify
 * with a fresh TOTP from the run's shared factor (enrolled once by
 * auth.setup.ts — never re-enrol here, #371).
 */
export async function ownerAdminToken(request: APIRequestContext): Promise<string> {
  const login = await request.post("/api/admin/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(login.status(), "admin login").toBe(200);
  const { session_id } = await login.json();

  const verify = await request.post("/api/admin/auth/verify_mfa", {
    data: { session_id, totp_code: await freshTotp(readOwnerMfaSecret()) },
  });
  expect(verify.status(), "admin MFA verify").toBe(200);
  return (await verify.json()).token as string;
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
