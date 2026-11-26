import { test, expect } from "./fixtures";
import { type Page } from "@playwright/test";
import {
  DEV_EMAIL,
  DEV_PASSWORD,
  freshTotp,
  hasSessionCookie,
  readOwnerMfaSecret,
  signInAsOwner,
} from "./helpers";

/**
 * The admin sign-in gate — the spec that makes an entire defect class regression-proof.
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
 * ⚠️ **Nothing in this file may enrol a second factor.** (.)
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


/**
 * Signs in through the gate's own form — the path a person takes.
 *
 * ⚠️ The gate's own error banner is asserted between the two steps, so a REJECTED
 * credential or code fails here, named, in about a second. Without it the only
 * signal is a gate that is still visible 15 s later, which is exactly what a
 * broken admin token, a wrong status literal or a half-wired `initPage` also look
 * like — and what a replaced MFA factor used to look like. A comment is not
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
 * with no cause attached — the ambiguity that made a replaced MFA factor
 * indistinguishable from the four real defects.
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
      `enrolment belongs in auth.setup.ts and nowhere else. If the gate ` +
      `offered ENROLMENT instead, the setup step's factor never landed.`,
  ).toBe("advanced");
}

test.describe("Admin session gate", () => {
  /**
   * ⛔ EVERY TEST STARTS UNELEVATED, because elevation now survives a reload.
   *
   * That is the product behaviour this file's subject exists to deliver — and
   * it means the gate no longer appears on every load, so a spec that simply
   * navigates and expects a gate is testing the old defect. Without this reset,
   * seven cases below fail on a CORRECT build because the operator is still
   * elevated from the previous test.
   *
   * The two alternatives were both worse: a conditional "pass the gate if it
   * happens to be showing" is a vacuous guard by this repo's own rule
   * (`check-e2e-vacuous-guards.sh`), and ordering dependencies between tests
   * makes any single one unrunnable alone.
   */
  test.beforeEach(async ({ request }) => {
    const res = await request.delete("/api/test/admin-sessions", {
      data: { email: DEV_EMAIL },
    });
    expect(
      res.status(),
      "could not reset admin elevation — is STACKS_E2E_TEST_HELPERS set?",
    ).toBe(200);
  });

  test("an owner cannot reach an admin page without an admin session", async ({ page, request }) => {
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");

    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("tbody tr"),
      "the page rendered without an admin session — its API calls will all 401",
    ).toHaveCount(0);
  });

  test("signing in through the gate loads the real page with rows", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    await expect(page.getByTestId("admin-gate")).toBeHidden({ timeout: 15000 });
    await expect(
      page.locator("tbody tr").first(),
      "the admin token did not reach the page's first load",
    ).toBeVisible({ timeout: 15000 });
  });

  /**
   * ⛔ THE RELOAD. Elevation is a fact about the session the server holds, not a
   * credential the page carries — so a full reload inside the MFA window must
   * land the operator back on the admin surface without a second factor.
   *
   * Before, the SPA held an admin token in memory and nothing persisted it, so
   * every full load cost email + password + TOTP again. That is the defect this
   * whole change exists to remove, and no unit test can see it: the server-side
   * mechanism can be perfect while the page still re-gates itself.
   */
  test("a reload inside the MFA window does not re-prompt", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);
    await expect(page.locator("tbody tr").first()).toBeVisible({ timeout: 15000 });

    await page.reload();

    // ⚠️ PRESENCE FIRST, THEN ABSENCE. `toBeHidden()` is satisfied by an element
    // that is merely not there yet, so asserting the gate is hidden while the
    // page is still booting passes instantly and measures nothing — it passed
    // against a build that re-gated on every reload. Waiting for the surface
    // first means the absence is asserted against a page that has finished.
    await expect(
      page.locator("tbody tr").first(),
      "the admin surface did not come back after a reload",
    ).toBeVisible({ timeout: 15000 });
    await expect(
      page.getByTestId("admin-gate"),
      "a reload re-presented the gate — the elevation the server recorded is not being replayed",
    ).toBeHidden();
  });

  test("a pending source offers Approve and Reject", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });
    await expect(page.getByTestId("source-reject").first()).toBeVisible();
  });

  test("an admin ACTION succeeds, not merely the page load", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    const firstApprove = page.getByTestId("source-approve").first();
    await expect(firstApprove).toBeVisible({ timeout: 15000 });
    const pendingBefore = await page.getByTestId("source-approve").count();

    await firstApprove.click();

    await expect(page.getByTestId("source-approve")).toHaveCount(pendingBefore - 1, {
      timeout: 15000,
    });

    // One fewer button could be a row this page dropped from its own list.
    // Re-entering the console rebuilds the queue from the server, so the source
    // still being gone is the approval having actually been recorded.
    //
    // ⚠️ The reload is NOT followed by a second pass through the gate any more,
    // and that is the point rather than a convenience: elevation lives on the
    // server's session, so a reload inside the window lands straight back on
    // the surface. This used to call `passTheGate` again, which was itself a
    // quiet statement of the defect.
    await page.reload();
    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });
    await expect(page.getByTestId("source-approve")).toHaveCount(pendingBefore - 1, {
      timeout: 15000,
    });
  });

  /**
   * ⛔ The assertion this test exists for is the LAST one: the captured token,
   * which worked a moment ago, now 401s.
   *
   * `DELETE /api/admin/auth/logout` was routed, correct, and never called — an
   * admin session could only time out or be dropped client-side. A test that
   * only watched the gate reappear would pass just as happily against a button
   * that cleared `Model.adminAuth` and sent nothing, leaving the session live
   * server-side for the rest of its 30-minute window. Proving the revoke fired
   * means using the token afterwards.
   *
   * The token is read off the wire because that is the only place it exists:
   * the SPA holds it in memory and never persists it, deliberately.
   */
  test("ending an admin session revokes it server-side", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);

    const verified = page.waitForResponse(
      (r) => r.url().includes("/api/admin/auth/verify_mfa") && r.status() === 200,
    );
    await page.goto("/admin/sources");
    await passTheGate(page, secret);
    const adminToken = (await (await verified).json()).token as string;

    const before = await page.request.get("/api/admin/invites", {
      headers: { Authorization: `Bearer ${adminToken}` },
    });
    expect(
      before.status(),
      "the captured token must be a WORKING admin token before sign-out, or the 401 below proves nothing",
    ).toBe(200);

    const revoked = page.waitForResponse(
      (r) => r.url().includes("/api/admin/auth/logout") && r.request().method() === "DELETE",
    );
    await page.getByTestId("admin-end-session").click();
    expect((await revoked).status(), "the sign-out request itself failed").toBe(200);

    const after = await page.request.get("/api/admin/invites", {
      headers: { Authorization: `Bearer ${adminToken}` },
    });
    expect(
      after.status(),
      "the admin token still works — the session was dropped client-side only, which is the defect",
    ).toBe(401);
  });

  /**
   * The surface closes where the operator is standing, with no reload.
   *
   * ⚠️ This used to argue "a reload would re-gate anyway — the admin token is
   * memory-only — so navigating and finding the gate would prove nothing". That
   * premise is gone: elevation is on the server's session and a reload does NOT
   * re-gate. The test is unchanged and still right, for a better reason —
   * watching the surface be replaced in place is what proves the end took
   * effect immediately, rather than at the next navigation.
   */
  test("ending an admin session re-gates the surface in place", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);
    await expect(page.locator("tbody tr").first()).toBeVisible({ timeout: 15000 });

    await page.getByTestId("admin-end-session").click();

    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    await expect(
      page.getByTestId("admin-surface"),
      "the admin page is still rendered behind the gate",
    ).toBeHidden();
    await expect(page.locator("tbody tr")).toHaveCount(0);
    await expect(page.getByTestId("admin-gate-notice")).toContainText("admin session has ended");
    expect(page.url(), "ending an admin session must not navigate away").toContain("/admin/sources");
  });

  test("ending an admin session leaves the ordinary session alone", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);

    await page.getByTestId("admin-end-session").click();
    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });

    expect(
      await hasSessionCookie(page),
      "ending the ADMIN session signed the operator out of the whole product",
    ).toBe(true);
  });

  test("an admin failure does NOT sign the operator out of the app", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await signInAsOwner(page, request);
    await page.goto("/admin/sources");
    await passTheGate(page, secret);
    await expect(page.getByTestId("source-approve").first()).toBeVisible({ timeout: 15000 });

    await page.route("**/api/admin/sources/*/approve", (route) =>
      route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"unauthorized"}' }),
    );
    await page.getByTestId("source-approve").first().click();

    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    expect(page.url(), "an admin 401 must not redirect to /login").toContain("/admin/sources");

    expect(
      await hasSessionCookie(page),
      "the ordinary session was cleared by an ADMIN failure",
    ).toBe(true);
  });
});
