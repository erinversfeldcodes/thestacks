import { test, expect } from "@playwright/test";
import { suiteAuthFile, E2E_PASSWORD } from "./helpers";

test.use({ storageState: suiteAuthFile("settings") });

test.describe("Settings — Privacy & Consent", () => {
  test("consent page loads with title and toggle", async ({ page }) => {
    await page.goto("/settings/consent");
    await expect(page.locator(".page--settings")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title")).toContainText("Privacy");
    await expect(page.locator(".toggle")).toBeVisible();
  });

  test("analytics toggle switches between on and off", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    const toggle = page.locator("button.toggle");
    const initialText = await toggle.textContent();
    await toggle.click();
    await page.waitForTimeout(300);
    const newText = await toggle.textContent();

    // Text should have changed (On→Off or Off→On)
    expect(newText).not.toEqual(initialText);
  });

  test("save button is visible and clickable", async ({ page }) => {
    await page.goto("/settings/consent");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    const saveBtn = page.locator("button", { hasText: "Save" });
    await expect(saveBtn).toBeVisible();

    // Toggle then save
    await page.locator(".toggle").click();
    await saveBtn.click();

    // Should show success or at least not error
    await page.waitForTimeout(1000);
    const errorCount = await page.locator(".error").count();
    expect(errorCount).toBe(0);
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

  test("PUT /api/settings/password changes password with correct current password", async ({
    page,
  }) => {
    // Use a separate password update and then restore it so suite remains usable
    const { status } = await apiCall(page, "PUT", "/api/settings/password", {
      current_password: E2E_PASSWORD,
      new_password: E2E_PASSWORD,
    });
    expect(status).toBe(200);
  });

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

test.describe("Settings — Age Verification", () => {
  test("age verification page loads with toggle", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await expect(page.locator(".page--settings")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title")).toContainText("Age Verification");
    await expect(page.locator(".toggle")).toBeVisible();
  });

  test("clicking toggle opens confirmation modal", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

    await page.locator(".toggle").click();
    await expect(page.locator(".modal-overlay")).toBeVisible({ timeout: 3000 });
    await expect(page.locator(".modal__title")).toContainText("Confirm Age");
  });

  test("cancel closes modal without changing state", async ({ page }) => {
    await page.goto("/settings/age-verification");
    await page.waitForSelector(".page--settings", { timeout: 5000 });

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
    await page.waitForSelector(".page--settings", { timeout: 5000 });

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
