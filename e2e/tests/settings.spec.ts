import { test, expect } from "@playwright/test";
import {
  suiteAuthFile,
  E2E_PASSWORD,
  uniqueEmail,
  registerViaApi,
  fetchConfirmationToken,
} from "./helpers";

test.use({ storageState: suiteAuthFile("settings") });

test.describe("Settings — Privacy & Consent", () => {
  test("consent page loads with title and toggle", async ({ page }) => {
    await page.goto("/settings/consent");
    await expect(page.getByTestId('settings-hub').first()).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title").last()).toContainText("Privacy");
    await expect(page.locator(".toggle")).toBeVisible();
  });

  test("analytics toggle switches between on and off", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    const toggle = page.locator("button.toggle");
    const initialText = await toggle.textContent();
    await toggle.click();
    await page.waitForTimeout(300);
    const newText = await toggle.textContent();

    // Text should have changed (On→Off or Off→On)
    expect(newText).not.toEqual(initialText);
  });

  test("saving consent shows the 'Saved!' success state", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    // The clickable save button (Consent.elm renders "Save Preferences" in the
    // idle state and only wires onClick there — not in the Loading/Success states).
    const saveBtn = page.locator(".settings-actions button");
    await expect(saveBtn).toBeVisible();

    // Toggle analytics so there's a change to persist, then save.
    await page.locator("button.toggle").click();
    await saveBtn.click();

    // On success Consent.elm swaps the button label to "Saved!" (Consent.elm:110-112).
    await expect(
      page.getByRole("button", { name: "Saved!" })
    ).toBeVisible({ timeout: 5000 });

    // And no error paragraph should be present.
    await expect(page.locator(".error")).toHaveCount(0);
  });

  test("save failure surfaces the error message", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    // Force the save call to fail BEFORE clicking Save. saveConsent posts to
    // /api/gdpr/consent (Api.elm:681); a 500 drives the Failure branch.
    await page.route("**/api/gdpr/consent", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: "{}",
      })
    );

    const saveBtn = page.locator(".settings-actions button");
    await expect(saveBtn).toBeVisible();

    await page.locator("button.toggle").click();
    await saveBtn.click();

    // Consent.elm:118-121 renders this exact copy on Failure.
    await expect(page.locator(".error")).toContainText(
      "Could not save preferences. Please try again."
    );
  });
});

/**
 * API-level auth guards for the GDPR endpoints (Issue #121, Phase 5).
 *
 * These run against the real server via fetch() inside page.evaluate() with NO
 * Authorization header. All three routes live under the `:authenticated`
 * pipeline (router.ex — scope "/api" pipe_through [:api, :authenticated]) so
 * each must reject an anonymous caller with 401.
 */
test.describe("GDPR — auth guards", () => {
  // Clean context: no shared suite token, no localStorage. The requests below
  // deliberately omit any Authorization header.
  test.use({ storageState: { cookies: [], origins: [] } });

  test("GDPR endpoints return 401 when not authenticated", async ({ page }) => {
    await page.goto("/");

    const unauthResults = await page.evaluate(async () => {
      const endpoints = [
        { method: "POST", path: "/api/gdpr/export" },
        { method: "DELETE", path: "/api/gdpr/account" },
        { method: "POST", path: "/api/gdpr/consent" },
      ];

      const results = await Promise.all(
        endpoints.map(async ({ method, path }) => {
          const resp = await fetch(path, {
            method,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({}),
          });
          return { path, status: resp.status };
        })
      );
      return results;
    });

    for (const result of unauthResults) {
      expect(result.status, `${result.path} should require auth`).toBe(401);
    }
  });
});

/**
 * API-level smoke tests for settings endpoints added in Issue #048.
 * These run against the real server via fetch() inside page.evaluate()
 * so they are independent of whether the Elm settings pages are built.
 */
test.describe("Settings — Profile & Account API", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  /**
   * Helper: extract the JWT from localStorage and make a settings API call.
   */
  async function apiCall(
    page: any,
    method: string,
    path: string,
    body: Record<string, unknown>
  ): Promise<{ status: number; data: unknown }> {
    await page.goto("/");
    return page.evaluate(
      async ({
        method,
        path,
        body,
      }: {
        method: string;
        path: string;
        body: Record<string, unknown>;
      }) => {
        const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
        const resp = await fetch(path, {
          method,
          headers: {
            Authorization: `Bearer ${auth.token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        });
        const data = await resp.json().catch(() => null);
        return { status: resp.status, data };
      },
      { method, path, body }
    );
  }

  test("PUT /api/settings/profile updates display_name", async ({ page }) => {
    const { status } = await apiCall(page, "PUT", "/api/settings/profile", {
      display_name: "E2E Settings User",
    });
    expect(status).toBe(200);
  });

  test("PUT /api/settings/profile with email update requires current_password", async ({
    page,
  }) => {
    const { status: noPasswordStatus } = await apiCall(
      page,
      "PUT",
      "/api/settings/profile",
      { email: "new-e2e-settings@thestacks.test" }
    );
    expect(noPasswordStatus).toBe(422);

    const { status: wrongPasswordStatus } = await apiCall(
      page,
      "PUT",
      "/api/settings/profile",
      {
        email: "new-e2e-settings@thestacks.test",
        current_password: "wrong-password",
      }
    );
    expect(wrongPasswordStatus).toBe(422);
  });

  test("PUT /api/settings/location updates country_code and city", async ({
    page,
  }) => {
    const { status, data } = await apiCall(
      page,
      "PUT",
      "/api/settings/location",
      { country_code: "GB", city: "London" }
    );
    expect(status).toBe(200);
    expect((data as any).country_code).toBeDefined();
  });

  test("PUT /api/settings/location rejects invalid country_code", async ({
    page,
  }) => {
    const { status } = await apiCall(page, "PUT", "/api/settings/location", {
      country_code: "GBR",
    });
    expect(status).toBe(422);
  });

  test("PUT /api/settings/notifications updates notification preferences", async ({
    page,
  }) => {
    const { status } = await apiCall(
      page,
      "PUT",
      "/api/settings/notifications",
      {
        notify_wishlist_availability: true,
        notify_marketplace: false,
        notify_group_invitations: true,
        notify_event_matches: false,
      }
    );
    expect(status).toBe(200);
  });

  // NOTE: the happy-path "changes password with correct current password" test
  // lives in its OWN isolated describe below. A successful change revokes ALL of
  // the user's sessions, which would kill the shared suite token this describe
  // relies on. The wrong-password / short-password cases below FAIL the change,
  // so they never revoke — they can safely keep sharing the suite token.

  test("PUT /api/settings/password rejects wrong current password", async ({
    page,
  }) => {
    const { status, data } = await apiCall(
      page,
      "PUT",
      "/api/settings/password",
      {
        current_password: "definitely-wrong-password",
        new_password: "new-password-123",
      }
    );
    test.skip(status === 502, "Preview machine OOM under concurrent Argon2 load (Issue #166)");
    expect(status).toBe(422);
    expect((data as any).error).toBe("invalid_current_password");
  });

  test("PUT /api/settings/password rejects new password shorter than 8 characters", async ({
    page,
  }) => {
    const { status } = await apiCall(page, "PUT", "/api/settings/password", {
      current_password: E2E_PASSWORD,
      new_password: "short",
    });
    test.skip(status === 502, "Preview machine OOM under concurrent Argon2 load (Issue #166)");
    expect(status).toBe(422);
  });

  test("PUT /api/settings/profile_visibility updates visibility", async ({
    page,
  }) => {
    const { status } = await apiCall(
      page,
      "PUT",
      "/api/settings/profile_visibility",
      { profile_visibility: "platform" }
    );
    expect(status).toBe(200);
  });

  test("settings endpoints return 401 when not authenticated", async ({
    page,
  }) => {
    await page.goto("/");

    const unauthResults = await page.evaluate(async () => {
      const endpoints = [
        { method: "PUT", path: "/api/settings/profile" },
        { method: "PUT", path: "/api/settings/location" },
        { method: "PUT", path: "/api/settings/notifications" },
        { method: "PUT", path: "/api/settings/password" },
        { method: "PUT", path: "/api/settings/profile_visibility" },
      ];

      const results = await Promise.all(
        endpoints.map(async ({ method, path }) => {
          const resp = await fetch(path, {
            method,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({}),
          });
          return { path, status: resp.status };
        })
      );
      return results;
    });

    for (const result of unauthResults) {
      expect(result.status, `${result.path} should require auth`).toBe(401);
    }
  });
});

/**
 * Password-change happy path — ISOLATED from the shared suite token.
 *
 * A SUCCESSFUL password change calls Accounts.revoke_all_user_sessions/1
 * (Issue #178/#179/#180 — correct security behaviour: changing your password
 * invalidates every existing session). If this test used the shared
 * `suiteAuthFile("settings")` token, that revocation would destroy the token
 * for EVERY other settings test. Under `fullyParallel: true` the tests race, so
 * reordering can't protect them — any test that reuses the revoked token gets a
 * spurious 401 (observed: "rejects wrong current password", "rejects short
 * password", "profile_visibility updates" all 401'd after this test ran).
 *
 * So this test mints its OWN throwaway user (register → confirm → sign in) and
 * changes THAT user's password. The revocation only burns the throwaway token;
 * the shared suite token is never touched.
 */
test.describe("Settings — Password change (isolated)", () => {
  // Purely API-level (request fixture only): no shared storageState, no UI login.
  // Auth is carried by an explicit Authorization header on this user's own JWT.
  test.use({ storageState: { cookies: [], origins: [] } });

  test("PUT /api/settings/password changes password with correct current password", async ({
    request,
  }) => {
    // Mint a fresh throwaway user so a successful change revokes ONLY this user's
    // own session, never the shared suite token.
    const email = uniqueEmail("e2e-settings-pw");
    const reg = await registerViaApi(request, { email, password: E2E_PASSWORD });
    test.skip(reg.status() === 502, "Preview machine OOM under concurrent Argon2 load (Issue #166)");
    expect(reg.ok()).toBeTruthy();

    const token = await fetchConfirmationToken(request, email);
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    await request.get(`/api/auth/confirm/${token}`);

    // Log in via the API to obtain THIS user's own JWT. Skip only on 502 — a
    // genuine Argon2 OOM capacity flake on the small preview machine (Issue #166).
    // A 403 here would mean the just-confirmed throwaway user is still unconfirmed
    // (an email-confirm regression) — that must FAIL loudly, not skip.
    const login = await request.post("/api/auth/login", {
      data: { email, password: E2E_PASSWORD },
    });
    test.skip(login.status() === 502, "Preview machine OOM under concurrent Argon2 load (Issue #166)");
    expect(login.ok()).toBeTruthy();
    const authToken = (await login.json()).token as string;

    const resp = await request.put("/api/settings/password", {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { current_password: E2E_PASSWORD, new_password: E2E_PASSWORD },
    });
    test.skip(resp.status() === 502, "Preview machine OOM under concurrent Argon2 load (Issue #166)");
    expect(resp.status()).toBe(200);
  });
});

test.describe("Settings — Age Verification", () => {
  test("age verification page loads with toggle", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await expect(page.getByTestId('settings-hub').first()).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title").last()).toContainText("Age Verification");
    await expect(page.locator(".toggle")).toBeVisible();
  });

  test("clicking toggle opens confirmation modal", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible({ timeout: 3000 });
    await expect(page.locator(".modal__title")).toContainText("Confirm Age");
  });

  test("cancel closes modal without changing state", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    const toggleTextBefore = await page.locator(".toggle").textContent();

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible();

    await page.click('button:has-text("Cancel")');
    await expect(page.locator(".modal-overlay")).not.toBeVisible();

    const toggleTextAfter = await page.locator(".toggle").textContent();
    expect(toggleTextAfter).toEqual(toggleTextBefore);
  });

  test("confirm saves age verification", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible();

    await page.click('.modal__actions button:has-text("Confirm")');
    await page.waitForTimeout(1000);

    // Modal should close
    await expect(page.locator(".modal-overlay")).not.toBeVisible();
    // No error should appear
    const errorCount = await page.locator(".error").count();
    expect(errorCount).toBe(0);
  });
});
