import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import {
  DEV_EMAIL,
  DEV_PASSWORD,
  freshTotp,
  readOwnerMfaSecret,
} from "./helpers";

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

/**
 * ⚠️ **Nothing in this file may enrol a second factor.** (Issue #371.)
 *
 * The owner is one shared account with exactly ONE stored TOTP factor
 * (`op.user_mfa` is upserted on `user_id`), so enrolling is a mutation of state
 * every spec below depends on. This file used to enrol per-test; at the worker
 * count the suite ships with (`workers: CI ? 2 : 4`) that meant spec A enrolled
 * S₁, spec B replaced it with S₂, and A's code was then rejected — visible only
 * as a gate that never opens, i.e. **the same symptom as the four real defects
 * this file exists to catch.** A false failure that mimics the true one teaches
 * people to disbelieve the spec.
 *
 * The factor is now enrolled once by the `setup` project (`auth.setup.ts`),
 * before any test runs, and the specs only READ it — `totp()` derives a fresh
 * code from the shared secret each time, and verification has no replay
 * protection, so parallel specs presenting the same code are fine.
 */

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

/**
 * Signs in through the gate's own form — the path a person takes.
 *
 * ⚠️ The gate's own error banner is asserted between the two steps, so a REJECTED
 * credential or code fails here, named, in about a second. Without it the only
 * signal is a gate that is still visible 15 s later, which is exactly what a
 * broken admin token, a wrong status literal or a half-wired `initPage` also look
 * like — and what a replaced MFA factor (#371) used to look like. A comment is not
 * a guard: this is the assertion that keeps the shared factor from ever again
 * degrading into an ambiguous timeout.
 */
async function passTheGate(page: Page, secret: string) {
  await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
  await page.getByTestId("admin-email").fill(DEV_EMAIL);
  await page.getByTestId("admin-password").fill(DEV_PASSWORD);
  await page.getByTestId("admin-continue").click();

  await gateAdvances(
    page,
    page.getByTestId("admin-code").waitFor({ state: "visible", timeout: 15000 }),
    "the gate never offered the code field",
  );
  await page.getByTestId("admin-code").fill(await freshTotp(secret));
  await page.getByTestId("admin-verify").click();
  await gateAdvances(
    page,
    page.getByTestId("admin-gate").waitFor({ state: "hidden", timeout: 15000 }),
    "the gate never opened after the code was submitted",
  );
}

/**
 * Wait for the gate to advance — but let its own error banner win the race.
 *
 * ⚠️ Both sides wait for something to APPEAR. A "no error is showing" check would
 * be satisfied by the instant before the banner renders and fail open, which is
 * the failure mode this guard exists to remove, not reproduce.
 *
 * Losing to the banner turns a rejection into an immediate failure that quotes the
 * message the operator would have read, instead of 15 s of "element still visible"
 * with no cause attached — the ambiguity that made a replaced MFA factor (#371)
 * indistinguishable from the four real #303 defects.
 */
async function gateAdvances(page: Page, advanced: Promise<unknown>, what: string) {
  const banner = page.getByTestId("admin-gate-error");
  const neither = `${what}, and it showed no error either`;
  const outcome = await Promise.race([
    advanced.then(() => "advanced").catch(() => neither),
    banner
      .waitFor({ state: "visible", timeout: 15000 })
      .then(() => banner.innerText())
      .catch(() => neither),
  ]);
  expect(
    outcome,
    `${what}. ⚠️ If the value above is the gate's message about a CODE, the owner's ` +
      `single shared MFA factor was replaced mid-run and this run's secret is stale ` +
      `(#371) — enrolment belongs in auth.setup.ts and nowhere else. If the gate ` +
      `offered ENROLMENT instead, the setup step's factor never landed.`,
  ).toBe("advanced");
}

test.describe("Admin session gate (#303)", () => {
  test("an owner cannot reach an admin page without an admin session", async ({ page, request }) => {
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");

    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("tbody tr"),
      "the page rendered without an admin session — its API calls will all 401",
    ).toHaveCount(0);
  });

  test("signing in through the gate loads the real page with rows", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
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
    const secret = readOwnerMfaSecret();
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });
    await expect(page.getByTestId("source-reject").first()).toBeVisible();
  });

  test("an admin ACTION succeeds, not merely the page load", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    const firstApprove = page.getByTestId("source-approve").first();
    await expect(firstApprove).toBeVisible({ timeout: 15000 });
    const pendingBefore = await page.getByTestId("source-approve").count();

    await firstApprove.click();

    await expect(page.getByTestId("source-approve")).toHaveCount(pendingBefore - 1, {
      timeout: 15000,
    });
  });

  test("an admin failure does NOT sign the operator out of the app", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInOrdinary(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);
    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });

    await page.route("**/api/admin/sources/*/approve", (route) =>
      route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"unauthorized"}' }),
    );
    await page.getByTestId("source-approve").first().click();

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
