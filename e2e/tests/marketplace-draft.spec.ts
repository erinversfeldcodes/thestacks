import { test, expect } from "./fixtures";
import {
  DEV_EMAIL,
  DEV_PASSWORD,
  ensureBookOnLibrary,
  expireSession,
  signInViaForm,
} from "./helpers";

const LISTING_DRAFT_KEY = "stacks-listing-draft";

const DRAFT_PRICE = "247";
const DRAFT_CONTACT = "e2e-182-draft@thestacks.test";
const DRAFT_DESCRIPTION =
  "DRAFT-RESTORE-MARKER — Plath first edition, mid-compose expiry";

test.describe("Marketplace listing draft", () => {
  test("CreateListing draft survives a mid-compose session expiry and is restored after re-login", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);
    await ensureBookOnLibrary(page);

    await page.goto("/marketplace/create");
    await expect(page.locator(".page--marketplace-create")).toBeVisible({
      timeout: 15000,
    });

    // Wait for the placements request to settle so a real book is selectable
    // (the selector shows "Loading your books..." until then).
    const placementSelect = page.locator("#placement-select");
    await expect(placementSelect).toBeVisible({ timeout: 15000 });

    await placementSelect.selectOption({ index: 1 });
    const selectedPlacementId = await placementSelect.inputValue();
    expect(selectedPlacementId).not.toBe("");

    await page.locator('input[name="condition"][value="like_new"]').check();
    await page.locator('input[name="pricing_mode"][value="fixed"]').check();
    await page.fill("#price-input", DRAFT_PRICE);
    await page.fill("#contact-input", DRAFT_CONTACT);
    await page.fill("#description-input", DRAFT_DESCRIPTION);

    // ⛔ Expire the session the way a real TTL expiry does — corrupt the session
    // cookie, leaving the CSRF cookie intact. `logout` would clear the CSRF
    // cookie too, so the mid-compose write would fail the stateless
    // double-submit check (403) before auth (401) is ever reached — and the
    // draft-save path keys on 401 (`Api.isUnauthorized`), so a logout-based
    // revoke never exercises the expiry branch this spec exists to prove.
    await expireSession(page);

    await page
      .getByRole("button", { name: "Create Listing", exact: true })
      .click();

    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");
    await expect(notice).toContainText("your listing draft is saved");

    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // An expiry leaves a present-but-invalid session cookie (unlike a logout,
    // which clears it), so the credential's absence is the wrong thing to
    // assert here. The refusal is proven by the session-expired notice and the
    // redirect to /login above — the expiry path actually ran.

    const persistedDraft = await page.evaluate(
      (key) => localStorage.getItem(key),
      LISTING_DRAFT_KEY
    );
    expect(persistedDraft).toBeTruthy();
    expect(persistedDraft).toContain(DRAFT_DESCRIPTION);

    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);
    await page.goto("/marketplace/create");
    await expect(page.locator(".page--marketplace-create")).toBeVisible({
      timeout: 15000,
    });

    const restoredBanner = page.locator(".marketplace-create__draft-notice");
    await expect(restoredBanner).toBeVisible({ timeout: 15000 });
    await expect(restoredBanner).toContainText(
      "We kept the listing you were composing"
    );

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

    await page
      .locator(".marketplace-create__draft-discard")
      .click();

    await expect(restoredBanner).toHaveCount(0);
    await expect(page.locator("#placement-select")).toHaveValue("");
    await expect(page.locator("#contact-input")).toHaveValue("");
    await expect(page.locator("#description-input")).toHaveValue("");
    await expect(
      page.locator('input[name="condition"][value="good"]')
    ).toBeChecked();

    const discardedDraft = await page.evaluate(
      (key) => localStorage.getItem(key),
      LISTING_DRAFT_KEY
    );
    expect(discardedDraft).toBeFalsy();
  });
});
