import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import {
  DEV_EMAIL,
  DEV_PASSWORD,
  freshTotp,
  mintOrSkip,
  readOwnerMfaSecret,
} from "./helpers";

/**
 * The owner's feedback queue, driven end to end.
 *
 * ⛔ **No E2E spec referenced this surface at all**, and the reason it was skipped is the
 * reason it needed one: it sits behind an MFA-verified admin session, so it is the single
 * hardest surface in the product to reach and the one least likely to be driven by hand.
 * Its unit tests feed a token straight into a mocked API — exactly the shape that let four
 * admin surfaces ship built, routed, unit-tested and unreachable, because nothing exercised
 * the code that chooses the token.
 *
 * It is also the ONLY interface through which a reader's feedback body leaves the database,
 * which is why the page being reachable is a correctness question and not a convenience one:
 * if the queue does not render, nobody is reading the beta channel and nothing says so.
 *
 * ⚠️ **The pager is the part worth driving, and it is driven with real rows.** Page size is
 * 25 (`Page.Admin.Feedback.pageSize`) and the client derives "is there an older page" from
 * `total` against what it has shown, so a pager bug is invisible until the queue exceeds one
 * page. This spec puts it over the line itself rather than hoping the target's seed did.
 *
 * ⚠️ Every assertion about the queue is RELATIVE to the total the page reports. The queue is
 * append-only and shared, so a previous run's entries are still in it; an absolute count
 * would pass on a fresh stack and fail on a used one, which is worse than no assertion.
 */

/** `Page.Admin.Feedback.pageSize` — the client's own window, not the server's default. */
const PAGE_SIZE = 25;

/**
 * The `:feedback` rate bucket allows 10 per 60s PER USER, so filling a page takes several
 * users. Minting them is cheaper than waiting out the limiter and does not touch the shared
 * `:auth` bucket.
 */
const PER_USER = 9;

/**
 * ⚠️ A 429 is waited out rather than failed on, and the reason is a defect this spec found.
 *
 * The limiter read Guardian's resource out of `conn.assigns` while Guardian keeps it in
 * `conn.private`, so the bucket documented as "per user" was keyed on the IP — and a run that
 * mints several users from one address was refused as though they were one reader. That is
 * fixed and pinned by unit tests now, but the limiter is not what this spec is about, and a
 * target carrying an older build (or a run following another) should not fail here.
 */
const RATE_LIMIT_WINDOW_MS = 60_000;

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
 * Signs in through the admin gate's own form — the path a person takes, and the path whose
 * absence made four admin pages unreachable.
 *
 * The gate's error banner wins the race against the gate advancing, so a rejected credential
 * or a stale MFA factor fails here by name rather than as fifteen seconds of "still visible",
 * which is also what a genuinely broken admin token looks like.
 */
async function passTheGate(page: Page, secret: string) {
  await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
  await page.getByTestId("admin-email").fill(DEV_EMAIL);
  await page.getByTestId("admin-password").fill(DEV_PASSWORD);
  await page.getByTestId("admin-continue").click();

  const banner = page.getByTestId("admin-gate-error");
  const codeField = page.getByTestId("admin-code");
  const offered = await Promise.race([
    codeField.waitFor({ state: "visible", timeout: 15000 }).then(() => "advanced"),
    banner
      .waitFor({ state: "visible", timeout: 15000 })
      .then(() => banner.innerText()),
  ]).catch(() => "the gate neither offered the code field nor showed an error");
  expect(offered, "the admin gate refused the owner's password").toBe("advanced");

  await codeField.fill(await freshTotp(secret));
  await page.getByTestId("admin-verify").click();

  const opened = await Promise.race([
    page
      .getByTestId("admin-gate")
      .waitFor({ state: "hidden", timeout: 15000 })
      .then(() => "advanced"),
    banner
      .waitFor({ state: "visible", timeout: 15000 })
      .then(() => banner.innerText()),
  ]).catch(() => "the gate neither opened nor showed an error");
  expect(
    opened,
    "the admin gate did not open after the code was submitted. ⚠️ If the value above is a " +
      "message about the CODE, the owner's single shared MFA factor was replaced mid-run — " +
      "enrolment belongs in auth.setup.ts and nowhere else.",
  ).toBe("advanced");
}

/**
 * Submits `count` feedback entries through the real reader-facing endpoint, spreading them
 * across freshly minted users to stay under the per-user rate limit.
 *
 * Deliberately the production path rather than a test helper: the point of this spec is that
 * what a reader submits is what the owner can read, and a helper that wrote rows directly
 * would skip the half of that sentence most likely to break.
 */
async function submitFeedback(request: APIRequestContext, count: number): Promise<string[]> {
  const bodies: string[] = [];

  while (bodies.length < count) {
    const session = await mintOrSkip(request);

    for (let i = 0; i < PER_USER && bodies.length < count; i++) {
      const body = `e2e feedback ${session.userId.slice(0, 8)}-${i}`;
      let resp = await request.post("/api/feedback", {
        headers: { Authorization: `Bearer ${session.token}` },
        data: { body, page_context: "/settings" },
      });

      if (resp.status() === 429) {
        // One wait, then one retry. Enough to clear a sliding window shared with
        // an older build's IP-keyed bucket; not enough to hide a limiter that
        // refuses everything.
        await new Promise((resolve) => setTimeout(resolve, RATE_LIMIT_WINDOW_MS + 2000));
        resp = await request.post("/api/feedback", {
          headers: { Authorization: `Bearer ${session.token}` },
          data: { body, page_context: "/settings" },
        });
      }

      expect(
        resp.status(),
        `submitting feedback failed (HTTP ${resp.status()}) and did not recover after waiting ` +
          `out the rate-limit window`,
      ).toBe(201);
      bodies.push(body);
    }
  }

  return bodies;
}

/** Reads the total out of the page's own "Showing a–b of N" line. */
async function reportedTotal(page: Page): Promise<number> {
  const label = await page.getByTestId("admin-feedback-count").innerText();
  const match = label.match(/of (\d+)/);
  expect(match, `the count line did not state a total: ${label}`).not.toBeNull();
  return Number((match as RegExpMatchArray)[1]);
}

test.describe("Admin feedback queue", () => {
  test("the queue is not reachable without an admin session", async ({ page, request }) => {
    await signInOrdinary(page, request);
    await page.goto("/admin/feedback");

    await expect(page.getByTestId("admin-gate")).toBeVisible({ timeout: 15000 });
    await expect(
      page.getByTestId("admin-feedback-entry"),
      "feedback bodies rendered without an admin session. This is the only interface that " +
        "reads them, and the MFA gate is what makes that access accountable.",
    ).toHaveCount(0);
  });

  test("what a reader submits is what the owner reads", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    const submitted = await submitFeedback(request, 1);

    await signInOrdinary(page, request);
    await page.goto("/admin/feedback");
    await passTheGate(page, secret);

    await expect(page.getByTestId("admin-feedback-entry").first()).toBeVisible({
      timeout: 15000,
    });

    // Newest first, so the entry just submitted is on the first page.
    await expect(
      page.getByText(submitted[0], { exact: false }),
      "the queue rendered rows but not the one just submitted — the surface is reachable " +
        "and reading something other than the reader's channel",
    ).toBeVisible({ timeout: 15000 });

    await expect(page.getByTestId("admin-feedback-error")).toHaveCount(0);
  });

  test("the count line states where in the queue the owner is", async ({ page, request }) => {
    const secret = readOwnerMfaSecret();
    await submitFeedback(request, 1);

    await signInOrdinary(page, request);
    await page.goto("/admin/feedback");
    await passTheGate(page, secret);

    const count = page.getByTestId("admin-feedback-count");
    await expect(count).toBeVisible({ timeout: 15000 });

    const total = await reportedTotal(page);
    const shown = await page.getByTestId("admin-feedback-entry").count();

    expect(shown, "the first page is empty despite a non-zero total").toBeGreaterThan(0);
    expect(shown, "the page rendered more rows than its own window").toBeLessThanOrEqual(
      PAGE_SIZE,
    );
    await expect(count).toContainText(`1–${shown} of ${total}`);
  });

  test("Older reaches the entries behind the first page, and Newer comes back", async ({
    page,
    request,
  }) => {
    // ⛔ The assertion this test exists for. `total` is the only thing that tells the client
    // there is more behind the page it is showing, and a full page and a truncated queue
    // look identical without it — so the entries that fall off the end are the OLDEST,
    // which in a beta channel is the feedback most likely to have gone unanswered.
    // Filling a page means minting several readers and submitting through the real
    // reader endpoint, and a rate-limit window may have to be waited out once.
    test.slow();

    const secret = readOwnerMfaSecret();

    await signInOrdinary(page, request);
    await page.goto("/admin/feedback");
    await passTheGate(page, secret);
    await expect(page.getByTestId("admin-feedback-count")).toBeVisible({ timeout: 15000 });

    // Put the queue over one page if it is not already. Reading the total first means a
    // stack that has been driven before does not pay for entries it already has.
    const existing = await reportedTotal(page);
    if (existing <= PAGE_SIZE) {
      await submitFeedback(request, PAGE_SIZE + 1 - existing);
      await page.reload();
      await passTheGate(page, secret);
    }

    await expect(page.getByTestId("admin-feedback-entry")).toHaveCount(PAGE_SIZE, {
      timeout: 15000,
    });

    const total = await reportedTotal(page);
    expect(total, "the queue is still within one page, so the pager cannot be driven").toBeGreaterThan(
      PAGE_SIZE,
    );

    // "Newer" is absent on the first page rather than disabled — this stylesheet has no
    // `:disabled` rule for `.btn`, so a dead button would look exactly like a live one.
    await expect(
      page.getByTestId("admin-feedback-newer"),
      "a Newer control is offered on the first page, where it leads nowhere",
    ).toHaveCount(0);

    // ⚠️ `textContent`, not `innerText`. `toHaveText` compares the element's
    // textContent with whitespace collapsed, so an `innerText` capture — which
    // keeps the line breaks between the row's spans — never matches itself.
    const firstEntry = page.getByTestId("admin-feedback-entry").first();
    const firstPageText = (await firstEntry.textContent()) ?? "";

    expect(firstPageText, "the first row of the first page rendered empty").not.toBe("");

    await page.getByTestId("admin-feedback-older").click();

    await expect(page.getByTestId("admin-feedback-count")).toContainText(
      `${PAGE_SIZE + 1}–`,
      { timeout: 15000 },
    );
    await expect(
      page.getByTestId("admin-feedback-entry").first(),
      "the second page is empty, so the older end of the queue is unreachable",
    ).toBeVisible({ timeout: 15000 });
    await expect(
      firstEntry,
      "the second page shows the same first row as the first page — Older did not advance",
    ).not.toHaveText(firstPageText);

    await page.getByTestId("admin-feedback-newer").click();

    await expect(page.getByTestId("admin-feedback-count")).toContainText(`1–`, {
      timeout: 15000,
    });
    await expect(
      firstEntry,
      "Newer did not return to the page the owner came from",
    ).toHaveText(firstPageText);
  });
});
