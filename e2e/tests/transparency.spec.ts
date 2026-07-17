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

  // The full user-based path: a visitor can reach the public Grafana dashboards
  // starting from the HOME page (#254). Rendering the page isn't enough — the
  // dashboards must be NAVIGABLE from home. Clicks every internal hop, then
  // asserts the external Grafana link is present + correct (a preview has no
  // Grafana app of its own, so we prove the reachable link, not a cross-env load).
  test("public Grafana is navigable from the home page (home → About → /metrics → dashboards)", async ({
    page,
  }) => {
    await page.goto("/");

    // Home → About via the brand dropdown.
    await page.locator(".app-nav__dropdown").first().hover();
    const aboutLink = page.locator('a.app-nav__dropdown-link[href="/about"]');
    await expect(aboutLink).toBeVisible({ timeout: 10_000 });
    await aboutLink.click();
    await expect(page).toHaveURL((url) => url.pathname === "/about");

    // About → transparency /metrics.
    const metricsLink = page.getByTestId("about-metrics-link");
    await expect(metricsLink).toBeVisible({ timeout: 10_000 });
    await metricsLink.click();
    await expect(page).toHaveURL((url) => url.pathname === "/metrics");
    await expect(page.getByTestId("metrics-content")).toBeVisible({
      timeout: 15_000,
    });

    // The public Grafana link — the reachable path to the full dashboards. It's
    // visible on this home-navigated page and targets the external Grafana in a
    // new tab. We assert the navigation TARGET rather than loading the prod app
    // cross-env (a preview has no Grafana of its own), which is the standard,
    // non-flaky way to prove an external link is navigable.
    const grafanaLink = page.getByTestId("metrics-grafana-link");
    await expect(grafanaLink).toBeVisible();
    await expect(grafanaLink).toHaveAttribute(
      "href",
      "https://thestacks-grafana.fly.dev",
    );
    await expect(grafanaLink).toHaveAttribute("target", "_blank");
    await expect(grafanaLink).toHaveAttribute("rel", /noopener/);
  });

  // Browser-level counterpart to the CI preview VM emission smoke (ADR-021 / #255):
  // proves the LIVE section actually renders real metric panels, not just the
  // graceful "unavailable" fallback. Gated on E2E_EXPECT_LIVE_METRICS because live
  // data only exists on a stack with the self-hosted VictoriaMetrics wired and the
  // core pusher having delivered samples (preview/prod) — set on the preview E2E
  // step in ci.yml. Off local/offline (no VM), where "unavailable" is correct and
  // the graceful-degradation test above covers it.
  test("live section renders real metric panels (preview: VM wired + data pushed)", async ({
    page,
  }) => {
    test.skip(
      !process.env.E2E_EXPECT_LIVE_METRICS,
      "Live metrics require the self-hosted VictoriaMetrics + pushed data (preview/prod). " +
        "Set E2E_EXPECT_LIVE_METRICS=1 to enforce the frontend-render guarantee.",
    );

    // First data can take >60s to surface and the server-side cache (45s TTL) to
    // refresh past an early "unavailable": push interval (15s) + VM flush (~10s) +
    // cache TTL (45s). Reload on a generous budget until real live panels render.
    await expect(async () => {
      await page.goto("/metrics", { waitUntil: "networkidle" });
      await expect(page.getByTestId("metrics-live-section")).toBeVisible();
      await expect(page.getByTestId("metrics-error")).toHaveCount(0);
      // Must be real panels — never the "unavailable" notice.
      await expect(page.getByTestId("metrics-live-unavailable")).toHaveCount(0);
      const livePanels = await page
        .getByTestId("metrics-live-section")
        .getByTestId("metrics-panel")
        .count();
      expect(livePanels).toBeGreaterThan(0);
    }).toPass({ timeout: 150_000, intervals: [5_000, 10_000, 15_000] });
  });
});
