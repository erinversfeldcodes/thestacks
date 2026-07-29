import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import { createHmac } from "node:crypto";
import { DEV_EMAIL, DEV_PASSWORD } from "./helpers";

/**
 * The admin sign-in gate (#303) — the spec that makes an entire defect class regression-proof.
 *
 * ⚠️ **Four admin surfaces were built, routed, unit-tested and unreachable.** They passed the
 * ordinary Guardian token to `/api/admin/*`, which sits behind an MFA-verified admin session
 * (`typ: "admin_session"`, IP- and boot_id-bound) and 401s anything else. Every page's own tests
 * passed, because each fed a token straight into a mocked API — **nothing exercised the code that
 * chooses the token.** That is precisely the gap this spec closes: it goes through the real gate,
 * against the real pipeline, and then asserts an admin page renders real rows.
 *
 * Driving it also turned up three more bugs behind the first, each invisible until its predecessor
 * was fixed: an invented status literal (`"pending"` vs `"pending_review"`) that meant Approve/Reject
 * never rendered; an admin 401 that signed the operator out of the whole app; and `initPage` being
 * repointed to the admin token while the `update` handlers were not, so the list loaded and every
 * action 401'd. The assertions below are chosen to catch all four.
 */

/** Base32 → bytes. The `otpauth://` provisioning URI carries the secret this way (RFC 4648). */
function base32Decode(input: string): Buffer {
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
function totp(secretBase32: string): string {
  const counter = Math.floor(Date.now() / 1000 / 30);
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
 * Enrols a second factor for the seeded owner and returns the base32 secret.
 *
 * ⚠️ Runs on **every** test rather than once, because a preview redeploy deletes and recreates the
 * Neon branch, so enrolment never survives. Re-enrolling is idempotent from the client's side: it
 * replaces the stored factor.
 *
 * ⚠️ The `secret` is sent **exactly as the URI carries it** — base32. The endpoint used to demand
 * base64 of the raw bytes, which no client could produce, and getting it wrong returns
 * `422 invalid_code`, reading as clock skew. Do not "helpfully" convert it.
 */
async function enrolOwnerMfa(request: APIRequestContext): Promise<string> {
  const login = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(login.status(), "owner login for MFA enrolment").toBe(200);
  const ownerToken = (await login.json()).token as string;
  const auth = { Authorization: `Bearer ${ownerToken}` };

  const setup = await request.post("/api/admin/auth/mfa/setup", { headers: auth, data: {} });
  expect(setup.status(), "mfa setup").toBe(200);
  const { provisioning_uri, recovery_codes } = await setup.json();

  const secret = new URL(String(provisioning_uri).replace("otpauth://", "https://"))
    .searchParams.get("secret");
  expect(secret, "the provisioning URI must carry a base32 secret").toBeTruthy();

  const confirm = await request.post("/api/admin/auth/mfa/confirm", {
    headers: auth,
    data: { totp_code: totp(secret!), secret: secret!, recovery_codes },
  });
  expect(
    confirm.status(),
    "mfa confirm — a 422 here usually means the secret encoding regressed, not a bad code",
  ).toBe(200);

  return secret!;
}

/** Stores an ordinary session so the SPA is signed in. Must be a FLAT blob. */
async function signInOrdinary(page: Page, request: APIRequestContext) {
  const login = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });
  expect(login.status()).toBe(200);
  const body = await login.json();
  await page.goto("/");
  await page.evaluate((blob) => {
    window.localStorage.setItem("stacks-auth", JSON.stringify(blob));
  }, {
    token: body.token,
    userId: body.user.id,
    email: body.user.email,
    displayName: body.user.display_name,
    handle: body.user.handle,
    role: body.user.role,
  });
}

/** Signs in through the gate's own form — the path a person takes. */
async function passTheGate(page: Page, secret: string) {
  await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
  await page.getByTestId("admin-email").fill(DEV_EMAIL);
  await page.getByTestId("admin-password").fill(DEV_PASSWORD);
  await page.getByTestId("admin-continue").click();

  // Presence first, then act: the code field only exists once the session id is in hand.
  await expect(page.getByTestId("admin-code")).toBeVisible({ timeout: 15000 });
  await page.getByTestId("admin-code").fill(totp(secret));
  await page.getByTestId("admin-verify").click();
}

test.describe("Admin session gate (#303)", () => {
  test("an owner cannot reach an admin page without an admin session", async ({ page, request }) => {
    // The ordinary session is NOT enough, and that is the whole point. Being signed in as the owner
    // used to render the page, whose every request then 401'd.
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");

    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("tbody tr"),
      "the page rendered without an admin session — its API calls will all 401",
    ).toHaveCount(0);
  });

  test("signing in through the gate loads the real page with rows", async ({ page, request }) => {
    const secret = await enrolOwnerMfa(request);
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    await expect(page.getByTestId("admin-gate")).toBeHidden({ timeout: 15000 });
    await expect(
      page.locator("tbody tr").first(),
      "the admin token did not reach the page's first load",
    ).toBeVisible({ timeout: 15000 });
  });

  test("a pending source offers Approve and Reject", async ({ page, request }) => {
    // ⛔ It did not. `status == "pending"` vs the server's `"pending_review"` meant the Actions column
    // was permanently empty — invisible while the page 401'd, so two defects stacked.
    const secret = await enrolOwnerMfa(request);
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });
    await expect(page.getByTestId("source-reject").first()).toBeVisible();
  });

  test("an admin ACTION succeeds, not merely the page load", async ({ page, request }) => {
    // ⛔ The half-wiring bug: `initPage` was repointed to the admin token and the `update` handlers
    // were not, so the list loaded (200) and every action 401'd. A page that loads and cannot act
    // passes any "does it render" assertion, which is why this one asserts a STATE CHANGE.
    const secret = await enrolOwnerMfa(request);
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    const firstApprove = page.getByTestId("source-approve").first();
    await expect(firstApprove).toBeVisible({ timeout: 15000 });
    const pendingBefore = await page.getByTestId("source-approve").count();

    await firstApprove.click();

    // One fewer pending row: the approve was accepted and the row left the pending state.
    await expect(page.getByTestId("source-approve")).toHaveCount(pendingBefore - 1, {
      timeout: 15000,
    });
  });

  test("an admin failure does NOT sign the operator out of the app", async ({ page, request }) => {
    // ⛔ Driven 2026-07-29: honouring a removal request ejected me to "The library closed your
    // session for safekeeping". The admin pages routed an admin 401 into the ORDINARY session-expiry
    // path. The admin session is meant to be fragile — MFA lapses after 30 minutes and it is bound to
    // the client IP and the node's boot_id — so ending the ordinary session on its failure is always
    // wrong.
    //
    // Simulated by corrupting only the admin call: `elm/http` speaks XMLHttpRequest, so `fetch`
    // patching would be a no-op here.
    const secret = await enrolOwnerMfa(request);
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);
    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });

    await page.route("**/api/admin/sources/*/approve", (route) =>
      route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"unauthorized"}' }),
    );
    await page.getByTestId("source-approve").first().click();

    // Back to the gate on the same route — not the Login page.
    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    expect(page.url(), "an admin 401 must not redirect to /login").toContain("/admin/sources");

    const ordinarySession = await page.evaluate(() =>
      window.localStorage.getItem("stacks-auth"),
    );
    expect(
      ordinarySession,
      "the ordinary session was cleared by an ADMIN failure",
    ).not.toBeNull();
  });
});
