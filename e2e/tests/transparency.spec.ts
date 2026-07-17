import { test, expect } from "@playwright/test";

/**
 * Browser E2E for the public transparency page (Issue #235, ADR-019):
 *   /metrics  →  GET /api/transparency/metrics
 *
 * Public + unauthenticated. Renders #241's curated payload: durable anonymised
 * aggregates (from public-safe marts) plus a live signals section that degrades
 * gracefully to "unavailable" when Fly Prometheus is unconfigured (as on a
 * preview without the read token) — never an error. Every panel carries a
 * what/how/why teaching expander (#233 standard), a costs widget is featured,
 * and the page links one hop to the GDPR data-rights surfaces.
 *
 * No auth: this deliberately runs with no storage state so it also proves the
 * page is reachable logged-out.
 */
test.describe("Public transparency page (/metrics)", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("renders logged-out: durable stats, teaching tooltips, and a graceful live section", async ({
    page,
  }) => {
    await page.goto("/metrics");

    await expect(page.locator(".metrics__title")).toHaveText("What we measure");
    await expect(page.getByTestId("metrics-content")).toBeVisible({
      timeout: 15_000,
    });

    // Durable statistics always render (public-safe marts, no Prometheus needed).
    await expect(page.getByTestId("metrics-durable-section")).toBeVisible();
    await expect(page.getByTestId("metrics-panel").first()).toBeVisible();

    // Every panel teaches (the #233 self-explanatory standard): at least one
    // what/how/why expander is present.
    await expect(page.getByTestId("metrics-teaching").first()).toBeVisible();

    // The live section is present and must degrade gracefully — either live
    // panels OR the "unavailable" notice, but NEVER the error state.
    await expect(page.getByTestId("metrics-live-section")).toBeVisible();
    await expect(page.getByTestId("metrics-error")).toHaveCount(0);
    const liveState =
      (await page.getByTestId("metrics-live-unavailable").count()) +
      (await page
        .getByTestId("metrics-live-section")
        .getByTestId("metrics-panel")
        .count());
    expect(liveState).toBeGreaterThan(0);

    // One-hop links to the GDPR data-rights surfaces.
    await expect(page.locator('a[href="/settings/privacy"]')).toBeVisible();
    await expect(page.locator('a[href="/settings/consent"]')).toBeVisible();
  });

  test("reachable via About → /metrics", async ({ page }) => {
    await page.goto("/about");

    const metricsLink = page.getByTestId("about-metrics-link");
    await expect(metricsLink).toBeVisible({ timeout: 10_000 });
    await metricsLink.click();

    await expect(page).toHaveURL((url) => url.pathname === "/metrics");
    await expect(page.getByTestId("metrics-content")).toBeVisible({
      timeout: 15_000,
    });
  });
});
