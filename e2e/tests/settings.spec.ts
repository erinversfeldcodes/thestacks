import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import {
  suiteAuthFile,
  E2E_PASSWORD,
  uniqueEmail,
  mintOrSkip,
  injectSession,
} from "./helpers";

test.use({ storageState: suiteAuthFile("settings") });

/**
 * The password path hashes with Argon2, serialised through a bounded NimblePool
 * (Issue #166, shipped: apps/core/lib/stacks/accounts/argon_pool.ex). Under
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
    // The consent page renders two toggles (Analytics + Writing assistant, #184);
    // target the analytics one specifically.
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
    await page.getByTestId("analytics-consent-toggle").click();
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

    await page.getByTestId("analytics-consent-toggle").click();
    await saveBtn.click();

    // Consent.elm:118-121 renders this exact copy on Failure.
    await expect(page.locator(".error")).toContainText(
      "Could not save preferences. Please try again."
    );
  });

  // US-8.3 (writing-assistant half). The analytics half is driven above; the WA
  // toggle is a DISTINCT test-id (`writing-assistant-consent-toggle`) and, unlike
  // analytics, is NOT staged behind the Save button — each click persists
  // immediately via POST /api/gdpr/consent {type:"writing_assistant"} because
  // revoking triggers a server-side purge (Consent.elm:66-82).
  test("writing-assistant consent grants, flips the off-copy, and persists server-side", async ({
    page,
  }) => {
    await page.goto("/settings/consent");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });

    const toggle = page.getByTestId("writing-assistant-consent-toggle");
    await expect(toggle).toBeVisible();

    // The off-copy is a named constant in Consent.elm
    // (writingAssistantOffDescription). Its "Disabling this…" clause appears
    // ONLY in the OFF state, so it is a safe substring to key off (the ON copy
    // is a strict prefix of the OFF copy).
    const offCopy = page.getByText(
      "Disabling this turns off the writing assistant and deletes your session history and embeddings."
    );

    // The write echoes the persisted DB flag (gdpr_controller consent_payload),
    // so we wait on the POST to both settle the click and read the durable value.
    const waConsentPost = () =>
      page.waitForResponse(
        (r) =>
          r.url().includes("/api/gdpr/consent") &&
          r.request().method() === "POST"
      );

    // Normalise to OFF so "grant" is a deterministic OFF→ON transition,
    // regardless of the seeded settings user's starting consent.
    if ((await toggle.textContent())?.trim() === "On") {
      const settled = waConsentPost();
      await toggle.click();
      await settled;
      await expect(toggle).toHaveText("Off");
    }
    await expect(offCopy).toBeVisible();

    // Grant: OFF → ON.
    const granted = waConsentPost();
    await toggle.click();
    const grantResp = await granted;
    expect(grantResp.status()).toBe(200);

    // The toggle flips to On and the off-copy flips to the shorter on-copy.
    await expect(toggle).toHaveText("On");
    await expect(offCopy).toHaveCount(0);

    // Persistence proof against the REAL backend: the write response echoes the
    // persisted `consent_writing_assistant` flag, so the grant is durable
    // server-side — not just an optimistic client flip. (A page reload can't
    // prove this here: Main.elm re-seeds the toggle from the stored auth in
    // localStorage, which the consent write deliberately does not mutate.)
    const body = await grantResp.json();
    expect(body.consent_writing_assistant).toBe(true);
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
    // own session, never the shared suite token. Minting (POST /api/test/session,
    // Issue #280) is outside the `:auth` bucket and returns a confirmed user with
    // its own JWT whose password is E2E_PASSWORD — replacing the
    // register→confirm→login dance that used to draw on the shared budget.
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

// ADR-020: the self-declared age-verification settings page + its
// `PUT /api/settings/age_verification` endpoint have been REMOVED. Verification is
// now provider-sourced (future KYC) and set in tests via the STACKS_E2E_TEST_HELPERS
// helper `PUT /api/test/age-verification` (see age-gate.spec.ts). There is no
// `/settings/age-verification` route to load or auth-guard any more, so the former
// "Settings — Age Verification" + "Age Verification auth guard" describe blocks are
// deleted rather than repointed.

// ─────────────────────────────────────────────────────────────────────────────
// Phase 5 — E2E UI flows (Issue #126). Every settings user story driven through
// the REAL rendered Elm UI against the live server (no page.route mocking of the
// endpoints under test). Server-side + API-level coverage lives above; this
// section proves the browser wiring: forms, feedback copy, toggle hydration and
// persistence, sidebar navigation, and the unauthenticated auth guard.
//
// Two selector helpers shared by the flows below. Elm renders `<label>` without a
// `for` attribute and `<input>` without an `id`, so getByLabel cannot associate
// them — target the field through its `.form-field` container instead. Each
// settings field label is unique on its page, so `hasText` is unambiguous.
// ─────────────────────────────────────────────────────────────────────────────

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
      has: page.locator(".form-field__label", {
        hasText: new RegExp(`^${labelText}$`),
      }),
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
 * Settings hub layout + sidebar navigation (US-17.1.1, auth-guard punch #2).
 * Uses the shared seeded `settings` suite user — it carries placements, so no
 * onboarding overlay intervenes (unlike the minted users the mutating flows
 * below rely on). These tests are read-only navigation; they mutate nothing.
 */
test.describe("Settings — Hub layout & navigation", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  // The seven sidebar links, in render order (Page/Settings.elm:56-65). The last
  // one, "Your Data Insights", points OUTSIDE the /settings/* prefix at
  // /me/insights (Route.toPath Insights) but still renders inside the hub chrome.
  const SIDEBAR = [
    { label: "Profile", path: "/settings/profile" },
    { label: "Password", path: "/settings/password" },
    { label: "Notifications", path: "/settings/notifications" },
    { label: "Consent", path: "/settings/consent" },
    { label: "Privacy", path: "/settings/privacy" },
    { label: "Audit Log", path: "/settings/audit-log" },
    { label: "Your Data Insights", path: "/me/insights" },
  ];

  test("/settings renders the hub in place with the 7-link sidebar and profile default", async ({
    page,
  }) => {
    await page.goto("/settings");
    await expect(page.getByTestId("settings-hub")).toBeVisible({
      timeout: 10000,
    });

    // Deviation captured in Phase 1: bare /settings does NOT redirect to
    // /settings/profile — it settles at /settings rendering the hub with the
    // profile page as default content.
    await expect(page).toHaveURL(/\/settings$/);
    // Profile is the default content: its Save Profile control proves it.
    await expect(
      page.getByRole("button", { name: "Save Profile" })
    ).toBeVisible();

    // Exactly seven sidebar links, in order, with the expected labels.
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
      await page.waitForURL(new RegExp(`${item.path}$`));
      // The hub chrome persists across the sub-route change...
      await expect(page.getByTestId("settings-hub")).toBeVisible();
      // ...and the clicked item is the one marked active (viewSidebarItem
      // compares currentRoute == item.route — a real route change, not a class
      // flip in isolation).
      await expect(
        page.locator("li.settings-hub__nav-item--active")
      ).toHaveText(item.label);
    }
  });

  test("mobile <select> lists the 7 options and selecting one navigates", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 375, height: 800 });
    await page.goto("/settings/profile");
    await expect(page.getByTestId("settings-hub")).toBeVisible({
      timeout: 10000,
    });

    const select = page.locator(".settings-hub__mobile-select");
    await expect(select.locator("option")).toHaveCount(7);

    // Selecting an option fires onInput → SettingsMobileNavChanged → pushUrl.
    await select.selectOption("/settings/notifications");
    await page.waitForURL(/\/settings\/notifications$/);
    await expect(page.getByTestId("settings-hub")).toBeVisible();
  });
});

/**
 * Auth guard (US-17.1.1, punch #2). Every settings route requires auth
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
      // The login form's submit control proves the Login page was rendered in
      // place of the settings hub.
      await expect(page.getByTestId("login-submit")).toBeVisible({
        timeout: 10000,
      });
      // The settings hub must NOT be reachable while unauthenticated.
      await expect(page.getByTestId("settings-hub")).toHaveCount(0);
      // The URL is unchanged — the guard renders login in place, no redirect.
      await expect(page).toHaveURL(new RegExp(`${path}$`));
    }
  });
});

/**
 * Profile UI flow (US-17.2.1) — including the CG-1 payoff: email changes work
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

    // 1) Display-name-only save: no email change, so no password gate.
    await field(page, "Display Name").fill("E2E Renamed User");
    await page.getByRole("button", { name: "Save Profile" }).click();
    await expect(page.getByText("Profile saved.")).toBeVisible();

    // 2) Email change surfaces the current-password field only once the email
    // actually differs from the stored value.
    const newEmail = uniqueEmail("e2e-settings-changed");
    await expect(field(page, "Current Password")).toHaveCount(0);
    await field(page, "Email").fill(newEmail);
    await expect(field(page, "Current Password")).toBeVisible();

    // 2a) Wrong current password → inline error, form inputs retained.
    await field(page, "Current Password").fill("definitely-wrong-password");
    await page.getByRole("button", { name: "Save Profile" }).click();
    await expect(
      page.getByText("Current password is incorrect.")
    ).toBeVisible();
    await expect(field(page, "Email")).toHaveValue(newEmail);

    // 2b) Correct current password → the email change lands.
    await field(page, "Current Password").fill(E2E_PASSWORD);
    await page.getByRole("button", { name: "Save Profile" }).click();
    await expect(page.getByText("Profile saved.")).toBeVisible();
  });
});

/**
 * Location UI flow (US-17.2.2). Minted user; a location save mutates only this
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
  });
});

/**
 * Password UI flow (US-17.2.3). Minted user. A SUCCESSFUL change revokes all of
 * the user's sessions (#178/#179), so it is the LAST action in its test.
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

    // Any PUT to the password endpoint means validation FAILED to block it.
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

    // Short new password (< 8 chars).
    await field(page, "New Password").fill("short");
    await field(page, "Confirm New Password").fill("short");
    await changeBtn.click();
    await expect(
      page.getByText("New password must be at least 8 characters.")
    ).toBeVisible();

    // Mismatched confirmation.
    await field(page, "New Password").fill("longenough1");
    await field(page, "Confirm New Password").fill("different1");
    await changeBtn.click();
    await expect(
      page.getByText("New password and confirmation do not match.")
    ).toBeVisible();

    // Empty current password (new + confirm valid and matching).
    await field(page, "New Password").fill("longenough1");
    await field(page, "Confirm New Password").fill("longenough1");
    await field(page, "Current Password").fill("");
    await changeBtn.click();
    await expect(
      page.getByText("Please enter your current password.")
    ).toBeVisible();

    // Not one of the three blocked submits reached the server.
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

    // Wrong current password → 422 → inline error (session still valid).
    await field(page, "Current Password").fill("definitely-wrong-password");
    await field(page, "New Password").fill("brand-new-password");
    await field(page, "Confirm New Password").fill("brand-new-password");
    await changeBtn.click();
    await expect(
      page.getByText("Current password is incorrect.")
    ).toBeVisible();

    // Correct current password → success. This revokes the session, so it is the
    // final action in this test.
    await field(page, "Current Password").fill(E2E_PASSWORD);
    await field(page, "New Password").fill("brand-new-password");
    await field(page, "Confirm New Password").fill("brand-new-password");
    await changeBtn.click();
    await expect(
      page.getByText("Password changed successfully.")
    ).toBeVisible();
    // Fields are cleared back to init on success.
    await expect(field(page, "Current Password")).toHaveValue("");
    await expect(field(page, "New Password")).toHaveValue("");
    await expect(field(page, "Confirm New Password")).toHaveValue("");
  });
});

/**
 * Notifications UI flow (US-17.3.1) — the CG-2 payoff. A freshly minted user's
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

    // Hydrated state (NOT all-off defaults): the two schema-default-true prefs
    // render "On", proving GET /api/settings/notifications was applied.
    await expect(toggle(page, "Price Drops")).toHaveText("Off");
    await expect(toggle(page, "New Reviews")).toHaveText("On");
    await expect(toggle(page, "Author Updates")).toHaveText("On");
    await expect(toggle(page, "Event Alerts")).toHaveText("Off");

    // Flip Price Drops off → on; it auto-saves with the success banner.
    await toggle(page, "Price Drops").click();
    await expect(page.getByText("Preferences saved.")).toBeVisible();
    await expect(toggle(page, "Price Drops")).toHaveText("On");
    await expect(toggle(page, "Price Drops")).toHaveClass(/toggle--on/);

    // Reload: the SPA re-fetches and the flip is still there (durable, not an
    // optimistic client-only change). The onboarding overlay reappears (its
    // dismissal is not persisted), so dismiss it again before reading state.
    await page.reload();
    await dismissOnboarding(page);
    await expect(toggle(page, "Price Drops")).toHaveText("On");
  });
});
