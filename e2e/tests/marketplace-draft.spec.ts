import { test, expect } from "@playwright/test";
import {
  DEV_EMAIL,
  DEV_PASSWORD,
  ensureBookOnLibrary,
  signInViaForm,
} from "./helpers";

// ---------------------------------------------------------------------------
// Issue #182 — a marketplace listing draft survives a mid-compose session
// expiry and is restored, field-for-field, after the user signs back in.
//
// This is the load-bearing live proof for the whole round-trip: the SPA
// persists the in-progress form to localStorage (`stacks-listing-draft`) on the
// 401 that a revoked token produces, redirects to /login with the draft-saved
// notice, and rehydrates the form when the create page is (re)built after
// re-login. We drive the REAL UI and poison the token exactly the same way the
// Session-expiry tests in auth.spec.ts do (append `.expired` to the stored
// token so the next authed request comes back 401).
// ---------------------------------------------------------------------------

const LISTING_DRAFT_KEY = "stacks-listing-draft";

// Distinct, recognisable values so the restore assertions can't pass by
// accident (e.g. against a default-valued form).
const DRAFT_PRICE = "247";
const DRAFT_CONTACT = "e2e-182-draft@thestacks.test";
const DRAFT_DESCRIPTION =
  "DRAFT-RESTORE-MARKER — Plath first edition, mid-compose expiry #182";

test.describe("Marketplace listing draft [#182]", () => {
  test("CreateListing draft survives a mid-compose session expiry and is restored after re-login [#182]", async ({
    page,
  }) => {
    // ── 1. Sign in and make sure the owner has a placement to list ──────────
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);
    // CreateListing.init fires Api.getMyPlacements; the placement <select> only
    // renders when the user owns at least one placement. This helper is
    // idempotent — it reuses an existing placement or places one via the API.
    await ensureBookOnLibrary(page);

    await page.goto("/marketplace/create");
    await expect(page.locator(".page--marketplace-create")).toBeVisible({
      timeout: 15000,
    });

    // Wait for the placements request to settle so a real book is selectable
    // (the selector shows "Loading your books..." until then).
    const placementSelect = page.locator("#placement-select");
    await expect(placementSelect).toBeVisible({ timeout: 15000 });

    // ── 2. Fill the form with DISTINCT values ───────────────────────────────
    // Pick the first real book (index 0 is the "Select a book..." placeholder)
    // and remember its id so we can assert the exact same placement re-selects.
    await placementSelect.selectOption({ index: 1 });
    const selectedPlacementId = await placementSelect.inputValue();
    expect(selectedPlacementId).not.toBe("");

    await page.locator('input[name="condition"][value="like_new"]').check();
    await page.locator('input[name="pricing_mode"][value="fixed"]').check();
    await page.fill("#price-input", DRAFT_PRICE);
    await page.fill("#contact-input", DRAFT_CONTACT);
    await page.fill("#description-input", DRAFT_DESCRIPTION);

    // ── 3. Revoke the session SERVER-SIDE, then submit (the authed create → 401) ─
    // We deliberately do NOT use the auth.spec localStorage-poison trick here: that
    // works only because those tests reload (page.goto) so the SPA re-reads the
    // poisoned token from flags. A reload would wipe the in-memory form that is the
    // whole point of this test. Instead we revoke the *current, still-valid* token
    // server-side (guardian_db revocation, #124 A2) — exactly a "logged out
    // elsewhere / revoked mid-compose" expiry — leaving the SPA's in-memory session
    // (and the filled form) untouched. The next authed request (the submit) then
    // comes back 401 in-session, with no reload.
    const liveToken = await page.evaluate(
      () => JSON.parse(localStorage.getItem("stacks-auth") || "{}").token
    );
    expect(liveToken).toBeTruthy();
    const revokeResp = await page.request.delete("/api/auth/logout", {
      headers: { Authorization: `Bearer ${liveToken}` },
    });
    expect(revokeResp.status()).toBe(204);

    // Submitting fires Api.createListing with the now server-revoked token; the 401
    // routes through CreateListing's SessionExpiredWithDraft → Main persists the
    // draft to localStorage and redirects to /login.
    await page
      .getByRole("button", { name: "Create Listing", exact: true })
      .click();

    // ── 4. Redirected to /login WITH the draft-saved expiry notice ──────────
    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    // The draft-saved variant of the expiry copy (Page.Login.sessionExpiredNoticeText).
    await expect(notice).toContainText("closed your session");
    await expect(notice).toContainText("your listing draft is saved");

    // The invalid-credentials error is NOT what's shown here.
    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // The local auth session was cleared by the expiry path …
    const clearedAuth = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(clearedAuth).toBeFalsy();

    // … but the in-progress draft WAS persisted (survives the redirect).
    const persistedDraft = await page.evaluate(
      (key) => localStorage.getItem(key),
      LISTING_DRAFT_KEY
    );
    expect(persistedDraft).toBeTruthy();
    expect(persistedDraft).toContain(DRAFT_DESCRIPTION);

    // ── 5. Sign back in (same user → same userId stamp) and reopen the form ──
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);
    await page.goto("/marketplace/create");
    await expect(page.locator(".page--marketplace-create")).toBeVisible({
      timeout: 15000,
    });

    // ── 6. CORE ASSERTION: the form is restored field-for-field ─────────────
    // The restored-draft banner is shown (draftRestored = True).
    const restoredBanner = page.locator(".marketplace-create__draft-notice");
    await expect(restoredBanner).toBeVisible({ timeout: 15000 });
    await expect(restoredBanner).toContainText(
      "We kept the listing you were composing"
    );

    // Each field shows the distinct value entered before expiry.
    const restoredSelect = page.locator("#placement-select");
    await expect(restoredSelect).toBeVisible({ timeout: 15000 });
    await expect(restoredSelect).toHaveValue(selectedPlacementId);
    await expect(
      page.locator('input[name="condition"][value="like_new"]')
    ).toBeChecked();
    await expect(
      page.locator('input[name="pricing_mode"][value="fixed"]')
    ).toBeChecked();
    await expect(page.locator("#price-input")).toHaveValue(DRAFT_PRICE);
    await expect(page.locator("#contact-input")).toHaveValue(DRAFT_CONTACT);
    await expect(page.locator("#description-input")).toHaveValue(
      DRAFT_DESCRIPTION
    );

    // ── 7. Discard clears the form and dismisses the banner ─────────────────
    await page
      .locator(".marketplace-create__draft-discard")
      .click();

    await expect(restoredBanner).toHaveCount(0);
    await expect(page.locator("#placement-select")).toHaveValue("");
    await expect(page.locator("#contact-input")).toHaveValue("");
    await expect(page.locator("#description-input")).toHaveValue("");
    // Discard resets condition to the Good default (conditionToString Good = "good").
    await expect(
      page.locator('input[name="condition"][value="good"]')
    ).toBeChecked();

    // The discarded draft is also gone from localStorage (ClearDraft port).
    const discardedDraft = await page.evaluate(
      (key) => localStorage.getItem(key),
      LISTING_DRAFT_KEY
    );
    expect(discardedDraft).toBeFalsy();
  });
});
