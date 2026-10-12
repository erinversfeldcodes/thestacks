import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import {
  suiteAuthFile,
  E2E_PASSWORD,
  uniqueEmail,
  mintOrSkip,
  injectSession,
  fetchSentEmails,
  extractLink,
} from "./helpers";

test.use({ storageState: suiteAuthFile("settings") });

/**
 * The password path hashes with Argon2, serialised through a bounded NimblePool
 * (, shipped: apps/core/lib/stacks/accounts/argon_pool.ex). Under
 * saturation the API now returns 503 + Retry-After: 5 — NOT the old preview-VM
 * OOM 502 that a `test.skip(status === 502)` guard used to swallow (a guard that
 * made the test unable to fail). Honour the shipped back-pressure contract
 * instead of skipping: retry a small, bounded number of times, waiting the
 * server-advised delay, then let the caller assert the REAL expectation. A
 * persistent 503 is a genuine failure the suite must surface, never a skip.
 */
async function retryOn503<T>(
  call: () => Promise<T>,
  statusOf: (r: T) => number,
  {
    maxAttempts = 3,
    retryAfterMs = 5000,
  }: { maxAttempts?: number; retryAfterMs?: number } = {}
): Promise<T> {
  let result = await call();
  for (
    let attempt = 1;
    attempt < maxAttempts && statusOf(result) === 503;
    attempt++
  ) {
    await new Promise((resolve) => setTimeout(resolve, retryAfterMs));
    result = await call();
  }
  return result;
}

test.describe("Settings — Privacy & Consent", () => {
  test("consent page loads with title and toggle", async ({ page }) => {
    await page.goto("/settings/consent");
    await expect(page.getByTestId('settings-hub').first()).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title").last()).toContainText("Privacy");
    await expect(page.getByTestId("analytics-consent-toggle")).toBeVisible();
  });

  test("analytics toggle switches between on and off", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    const toggle = page.getByTestId("analytics-consent-toggle");
    const initialText = await toggle.textContent();
    await toggle.click();
    await page.waitForTimeout(300);
    const newText = await toggle.textContent();

    expect(newText).not.toEqual(initialText);
  });

  test("saving consent shows the 'Saved!' success state", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    const consent = page.locator(".settings-consent");
    const saveBtn = consent.locator(".settings-actions button");
    await expect(saveBtn).toBeVisible();

    await page.getByTestId("analytics-consent-toggle").click();
    await saveBtn.click();

    await expect(
      consent.getByRole("button", { name: "Saved!" })
    ).toBeVisible({ timeout: 5000 });

    await expect(consent.locator(".error")).toHaveCount(0);
  });

  test("save failure surfaces the error message", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.getByTestId('settings-hub').waitFor({ timeout: 5000 });

    await page.route("**/api/gdpr/consent", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: "{}",
      })
    );

    const consent = page.locator(".settings-consent");
    const saveBtn = consent.locator(".settings-actions button");
    await expect(saveBtn).toBeVisible();

    await page.getByTestId("analytics-consent-toggle").click();
    await saveBtn.click();

    await expect(consent.locator(".error")).toContainText(
      "We could not save your consent preferences, and we cannot say why."
    );
  });

  test("book-linking consent grants, flips the off-copy, and persists server-side", async ({
    page,
  }) => {
    await page.goto("/settings/consent");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });

    const toggle = page.getByTestId("writing-assistant-consent-toggle");
    await expect(toggle).toBeVisible();

    const offCopy = page.getByText(
      "Your published posts are not sent to an AI model, so books you mention won't be linked automatically."
    );

    const waConsentPost = () =>
      page.waitForResponse(
        (r) =>
          r.url().includes("/api/gdpr/consent") &&
          r.request().method() === "POST"
      );

    if ((await toggle.textContent())?.trim() === "On") {
      const settled = waConsentPost();
      await toggle.click();
      await settled;
      await expect(toggle).toHaveText("Off");
    }
    await expect(offCopy).toBeVisible();

    const granted = waConsentPost();
    await toggle.click();
    const grantResp = await granted;
    expect(grantResp.status()).toBe(200);

    await expect(toggle).toHaveText("On");
    await expect(offCopy).toHaveCount(0);

    const body = await grantResp.json();
    expect(body.consent_writing_assistant).toBe(true);
  });
});

/**
 * API-level auth guards for the GDPR endpoints (, Phase 5).
 *
 * These run against the real server via fetch() inside page.evaluate() with NO
 * Authorization header. All three routes live under the `:authenticated`
 * pipeline (router.ex — scope "/api" pipe_through [:api, :authenticated]) so
 * each must reject an anonymous caller with 401.
 */
test.describe("GDPR — auth guards", () => {
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
 * API-level smoke tests for settings endpoints added in.
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

  test("PUT /api/settings/password rejects wrong current password", async ({
    page,
  }) => {
    const { status, data } = await retryOn503(
      () =>
        apiCall(page, "PUT", "/api/settings/password", {
          current_password: "definitely-wrong-password",
          new_password: "new-password-123",
        }),
      (r) => r.status
    );
    expect(status).toBe(422);
    expect((data as any).error).toBe("invalid_current_password");
  });

  test("PUT /api/settings/password rejects new password shorter than 8 characters", async ({
    page,
  }) => {
    const { status } = await retryOn503(
      () =>
        apiCall(page, "PUT", "/api/settings/password", {
          current_password: E2E_PASSWORD,
          new_password: "short",
        }),
      (r) => r.status
    );
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
 * (— correct security behaviour: changing your password
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
  test.use({ storageState: { cookies: [], origins: [] } });

  test("PUT /api/settings/password changes password with correct current password", async ({
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-pw"),
    });

    const resp = await retryOn503(
      () =>
        request.put("/api/settings/password", {
          headers: { Authorization: `Bearer ${session.token}` },
          data: { current_password: E2E_PASSWORD, new_password: E2E_PASSWORD },
        }),
      (r) => r.status()
    );
    expect(resp.status()).toBe(200);
  });
});

/**
 * The `<input>` inside the `.form-field` whose LABEL is exactly `labelText`.
 * Matching the `.form-field__label` text with an anchored regex avoids the
 * substring traps that a bare container `hasText` falls into: "New Password" is a
 * substring of "Confirm New Password", and the Email field shares the word
 * "email" with the current-password hint ("…change your email address.").
 */
function field(page: Page, labelText: string) {
  return page
    .locator(".form-field")
    .filter({
      has: page.locator(`.form-field__label:text-is("${labelText}")`),
    })
    .locator("input");
}

/** The toggle `<button>` inside the `.toggle-row` whose label is `labelText`. */
function toggle(page: Page, labelText: string) {
  return page
    .locator(".toggle-row", { hasText: labelText })
    .locator("button.toggle");
}

/**
 * A freshly minted `.test` user has no placements and has not completed
 * onboarding, so the global onboarding overlay (`onboarding-overlay`) renders
 * over every authenticated page and intercepts all clicks — including the
 * settings forms. It ALWAYS appears for a fresh mint, so dismiss it
 * unconditionally (not an if-visible guard) before touching any form.
 */
async function dismissOnboarding(page: Page): Promise<void> {
  const overlay = page.getByTestId("onboarding-overlay");
  await overlay.waitFor({ state: "visible", timeout: 10000 });
  await page.getByRole("button", { name: "Skip", exact: true }).click();
  await expect(overlay).toHaveCount(0);
}

/**
 * Settings hub layout + sidebar navigation.
 * Uses the shared seeded `settings` suite user — it carries placements, so no
 * onboarding overlay intervenes (unlike the minted users the mutating flows
 * below rely on). These tests are read-only navigation; they mutate nothing.
 */
test.describe("Settings — Hub layout & navigation", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  const SIDEBAR = [
    { label: "Profile", path: "/settings/profile" },
    { label: "Password", path: "/settings/password" },
    { label: "Notifications", path: "/settings/notifications" },
    { label: "Privacy & consent", path: "/settings/privacy" },
    { label: "Audit Log", path: "/settings/audit-log" },
    { label: "Your Data Insights", path: "/me/insights" },
  ];

  const GROUP_HEADINGS = ["You", "Privacy", "Your data"];

  test("/settings renders the hub in place with the grouped sidebar and profile default", async ({
    page,
  }) => {
    await page.goto("/settings");
    await expect(page.getByTestId("settings-hub")).toBeVisible({
      timeout: 10000,
    });

    await expect(page).toHaveURL(/\/settings$/);
    await expect(
      page.getByRole("button", { name: "Save Profile" })
    ).toBeVisible();

    await expect(page.locator(".settings-hub__group-heading")).toHaveText(
      GROUP_HEADINGS
    );
    const links = page.locator(".settings-hub__nav-link");
    await expect(links).toHaveText(SIDEBAR.map((i) => i.label));
  });

  test("clicking each sidebar link loads its sub-page and marks it active", async ({
    page,
  }) => {
    await page.goto("/settings/profile");
    await expect(page.getByTestId("settings-hub")).toBeVisible({
      timeout: 10000,
    });

    for (const item of SIDEBAR) {
      await page
        .locator(".settings-hub__nav-link", { hasText: item.label })
        .click();
      await page.waitForURL(`**${item.path}`);
      await expect(page.getByTestId("settings-hub")).toBeVisible();
      await expect(
        page.locator('.settings-hub__nav-link[aria-current="page"]')
      ).toHaveText(item.label);
    }
  });

  test("no mobile <select> at a narrow viewport — the grouped nav reflows and still navigates", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 375, height: 800 });
    await page.goto("/settings/profile");
    await expect(page.getByTestId("settings-hub")).toBeVisible({
      timeout: 10000,
    });

    await expect(page.locator(".settings-hub__mobile-select")).toHaveCount(0);

    const links = page.locator(".settings-hub__nav-link");
    await expect(links).toHaveText(SIDEBAR.map((i) => i.label));

    await page
      .locator(".settings-hub__nav-link", { hasText: "Notifications" })
      .click();
    await page.waitForURL(/\/settings\/notifications$/);
    await expect(page.getByTestId("settings-hub")).toBeVisible();
  });
});

/**
 * Auth guard. Every settings route requires auth
 * (Main.elm `requiresAuth _ -> True`); initPage returns the Login page when
 * there is no session, WITHOUT changing the URL. Anonymous context, no token.
 */
test.describe("Settings — Auth guard (UI)", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("unauthenticated /settings and a sub-route render the login form, URL unchanged", async ({
    page,
  }) => {
    for (const path of ["/settings", "/settings/notifications"]) {
      await page.goto(path);
      await expect(page.getByTestId("login-submit")).toBeVisible({
        timeout: 10000,
      });
      await expect(page.getByTestId("settings-hub")).toHaveCount(0);
      await expect(page).toHaveURL(path);
    }
  });
});

/**
 * Profile UI flow — including the CG-1 payoff: email changes work
 * from the UI. Each test mints its OWN fresh user (isolated: an email change
 * mutates the account, so it must never touch the shared suite user, whose login
 * identity later runs depend on).
 */
test.describe("Settings — Profile UI flow", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("edits display name and changes email with the current-password gate", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-profile"),
    });
    await injectSession(page, session);
    await page.goto("/settings/profile");
    await dismissOnboarding(page);

    await field(page, "Display Name").fill("E2E Renamed User");
    await page.getByRole("button", { name: "Save Profile" }).click();
    await expect(page.getByText("Profile saved.")).toBeVisible();

    const newEmail = uniqueEmail("e2e-settings-changed");
    await expect(field(page, "Current Password")).toHaveCount(0);
    await field(page, "Email").fill(newEmail);
    await expect(field(page, "Current Password")).toBeVisible();

    await field(page, "Current Password").fill("definitely-wrong-password");
    await page.getByRole("button", { name: "Save Profile" }).click();
    await expect(
      page.getByText("Current password is incorrect.")
    ).toBeVisible();
    await expect(field(page, "Email")).toHaveValue(newEmail);

    await field(page, "Current Password").fill(E2E_PASSWORD);
    await page.getByRole("button", { name: "Save Profile" }).click();
    await expect(page.getByText("Profile saved.")).toBeVisible();

    // The typed address does NOT land: it parks as pending, and the account
    // answers on the old address until the new one confirms itself. The form
    // snaps back to the settled address and announces the wait.
    await expect(field(page, "Email")).toHaveValue(session.email);
    await expect(page.locator(".pending-email")).toContainText(newEmail);

    // "Profile saved." is the form telling itself the news, so the account has
    // to be read back to know anything was written.
    //
    // Read it back the way the reader does: reload, and look at the form. The
    // page fetches the account on open, so the fields are the server's answer
    // — including the pending change, which a login-time blob never carried.
    await page.reload();
    await expect(field(page, "Display Name")).toHaveValue("E2E Renamed User", {
      timeout: 10000,
    });
    await expect(field(page, "Email")).toHaveValue(session.email);
    await expect(page.locator(".pending-email")).toContainText(newEmail);

    // Confirm from the new address's mailbox; only now does the change land.
    const emails = await fetchSentEmails(request, newEmail);
    test.skip(emails === null, "sent-emails helper unavailable");
    const confirm = emails!.find((e) =>
      /confirm-email-change/.test(`${e.html_body ?? ""} ${e.text_body ?? ""}`),
    );
    expect(confirm, "expected a confirm-your-new-address email").toBeTruthy();
    const link = extractLink(
      confirm!,
      /\/api\/auth\/confirm-email-change\/[^"'\s]+/,
    );
    expect(link).toBeTruthy();
    await page.goto(link!);
    await expect(page).toHaveURL(/\/confirm-email\/change-confirmed/);

    await page.goto("/settings/profile");
    await expect(field(page, "Email")).toHaveValue(newEmail, {
      timeout: 10000,
    });
    await expect(page.locator(".pending-email")).toHaveCount(0);
  });
});

/**
 * Location UI flow. Minted user; a location save mutates only this
 * throwaway account.
 */
test.describe("Settings — Location UI flow", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("saves country code + city with success feedback", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-loc"),
    });
    await injectSession(page, session);
    await page.goto("/settings/profile");
    await dismissOnboarding(page);

    await field(page, "Country Code").fill("GB");
    await field(page, "City").fill("London");
    await page.getByRole("button", { name: "Save Location" }).click();
    await expect(page.getByText("Location saved.")).toBeVisible();

    // Reload and read the form, for the same reason as the profile save above.
    // This is the whole point of the location fields: a reader who sets a city
    // and comes back tomorrow should see the city. (The stored session carries
    // no location at all, so before the page fetched the account this reload
    // came back blank whether or not the save had landed — which is why this
    // assertion used to go through the API.)
    await page.reload();
    await expect(field(page, "Country Code")).toHaveValue("GB", {
      timeout: 10000,
    });
    await expect(field(page, "City")).toHaveValue("London");
  });
});

/**
 * Password UI flow. Minted user. A SUCCESSFUL change revokes all of
 * the user's sessions, so it is the LAST action in its test.
 */
test.describe("Settings — Password UI flow", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("client-side validation blocks submit with inline errors and no request", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-pw-validate"),
    });
    await injectSession(page, session);
    await page.goto("/settings/password");
    await dismissOnboarding(page);

    const pwPuts: string[] = [];
    page.on("request", (req) => {
      if (
        req.method() === "PUT" &&
        req.url().includes("/api/settings/password")
      ) {
        pwPuts.push(req.url());
      }
    });

    const changeBtn = page.getByRole("button", { name: "Change Password" });

    await field(page, "New Password").fill("short");
    await field(page, "Confirm New Password").fill("short");
    await changeBtn.click();
    await expect(
      page.getByText("New password must be at least 8 characters.")
    ).toBeVisible();

    await field(page, "New Password").fill("longenough1");
    await field(page, "Confirm New Password").fill("different1");
    await changeBtn.click();
    await expect(
      page.getByText("New password and confirmation do not match.")
    ).toBeVisible();

    await field(page, "New Password").fill("longenough1");
    await field(page, "Confirm New Password").fill("longenough1");
    await field(page, "Current Password").fill("");
    await changeBtn.click();
    await expect(
      page.getByText("Please enter your current password.")
    ).toBeVisible();

    expect(pwPuts).toHaveLength(0);
  });

  test("wrong current password errors inline, then a correct change succeeds", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-pw-change"),
    });
    await injectSession(page, session);
    await page.goto("/settings/password");
    await dismissOnboarding(page);

    const changeBtn = page.getByRole("button", { name: "Change Password" });

    await field(page, "Current Password").fill("definitely-wrong-password");
    await field(page, "New Password").fill("brand-new-password");
    await field(page, "Confirm New Password").fill("brand-new-password");
    await changeBtn.click();
    await expect(
      page.getByText("Current password is incorrect.")
    ).toBeVisible();

    await field(page, "Current Password").fill(E2E_PASSWORD);
    await field(page, "New Password").fill("brand-new-password");
    await field(page, "Confirm New Password").fill("brand-new-password");
    await changeBtn.click();
    await expect(
      page.getByText("Password changed successfully.")
    ).toBeVisible();
    await expect(field(page, "Current Password")).toHaveValue("");
    await expect(field(page, "New Password")).toHaveValue("");
    await expect(field(page, "Confirm New Password")).toHaveValue("");

    // A password has no field to reload into, so the only honest question is
    // which password now opens the account. Asking BOTH matters: a change that
    // never landed leaves the old one working, and asserting only the new one
    // would miss that.
    const withNew = await retryOn503(
      () =>
        request.post("/api/auth/login", {
          data: { email: session.email, password: "brand-new-password" },
        }),
      (r) => r.status()
    );
    expect(withNew.status(), "the new password signs in").toBe(200);

    const withOld = await retryOn503(
      () =>
        request.post("/api/auth/login", {
          data: { email: session.email, password: E2E_PASSWORD },
        }),
      (r) => r.status()
    );
    expect(withOld.status(), "the old password no longer signs in").toBe(401);
  });
});

/**
 * Notifications UI flow — the CG-2 payoff. A freshly minted user's
 * stored defaults are notify_marketplace=true and notify_group_invitations=true
 * (others false), so the toggles must HYDRATE from the server, not render an
 * all-off default: New Reviews (→notify_marketplace) and Author Updates
 * (→notify_group_invitations) rendering "On" is the proof the server round-trip
 * happened. Then a flipped toggle must SURVIVE a reload (durable persistence).
 */
test.describe("Settings — Notifications UI flow", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("toggles hydrate from stored state, and a flip persists across reload", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-notif"),
    });
    await injectSession(page, session);
    await page.goto("/settings/notifications");
    await dismissOnboarding(page);

    await expect(toggle(page, "Price Drops")).toHaveText("Off");
    await expect(toggle(page, "New Reviews")).toHaveText("On");
    await expect(toggle(page, "Author Updates")).toHaveText("On");
    await expect(toggle(page, "Event Alerts")).toHaveText("Off");

    await toggle(page, "Price Drops").click();
    await expect(page.getByText("Preferences saved.")).toBeVisible();
    await expect(toggle(page, "Price Drops")).toHaveText("On");
    await expect(toggle(page, "Price Drops")).toHaveClass(/toggle--on/);

    await page.reload();
    await expect(toggle(page, "Price Drops")).toHaveText("On");
  });
});

/**
 * Analytics consent — the persistence leg the interactivity tests above cannot
 * supply. Those assert that the toggle's label changes and that a "Saved!"
 * button appears; both are painted from the page's own state, so they read
 * identically whether the POST landed or was thrown away. The consent page
 * seeds its toggles from the user's stored consent on open, so a reload is what
 * asks the server what it kept.
 *
 * A minted user, because this WRITES consent: the shared `settings` suite user
 * is read by the parallel consent tests above, and flipping its stored consent
 * from here would race them.
 */
test.describe("Settings — Analytics consent persistence", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("granting analytics consent survives a reload", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-settings-consent"),
    });
    await injectSession(page, session);
    await page.goto("/settings/consent");
    await dismissOnboarding(page);

    const analytics = page.getByTestId("analytics-consent-toggle");
    await expect(analytics).toHaveText("Off");

    const consent = page.locator(".settings-consent");
    const saved = page.waitForResponse(
      (r) =>
        r.url().includes("/api/gdpr/consent") && r.request().method() === "POST",
      { timeout: 15000 }
    );
    await analytics.click();
    await consent.locator(".settings-actions button").click();
    expect((await saved).status(), "POST /api/gdpr/consent").toBe(200);
    await expect(
      consent.getByRole("button", { name: "Saved!" })
    ).toBeVisible({ timeout: 10000 });

    await page.reload();
    await expect(page.getByTestId("analytics-consent-toggle")).toHaveText("On", {
      timeout: 10000,
    });

    // The reloaded toggle is seeded from the session blob the app keeps in
    // localStorage, which the app itself wrote — so the account has to be read
    // back too, or a consent the server never stored would still show as "On"
    // to the only reader who checks.
    const stored = await request.get("/api/auth/me", {
      headers: { Authorization: `Bearer ${session.token}` },
    });
    expect(stored.status(), "GET /api/auth/me").toBe(200);
    expect((await stored.json()).user.consent_analytics).toBe(true);
  });
});
