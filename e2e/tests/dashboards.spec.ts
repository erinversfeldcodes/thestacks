import { test, expect, type Page } from "@playwright/test";

// Browser dashboard-render gate (ADR-021 / Epic #249 — dashboards-render-as-expected).
//
// The data-layer proofs already exist: dashboard-render-gate.sh (PromQL valid vs
// synthetic data), DashboardCompletenessTest/*_drift (displayed ⊆ measured — no dead
// panels), and dashboard-emission-gate.sh (the app pushes real families to the VM).
// This is the VIEW layer: load each Grafana dashboard in a real browser against the
// live (preview/prod) VM and prove it actually renders — the datasource is healthy
// (no panel-wide query errors) and real data paints (≥1 populated panel).
//
// Gated on GRAFANA_URL: unset ⇒ skipped (local/offline has no Grafana). CI sets it to
// the preview Grafana deployed by deploy-stack.sh, pointed at the preview VM. Grafana
// is anonymous (GF_AUTH_ANONYMOUS_ENABLED) so there is no login step.
//
// Why not "every panel has data": rare/negative/worker/excluded-spec panels (refresh-
// reuse alerts, MFA, image-retention sweeps, rate-limit rejections, uploads) legitimately
// show "No data" after a happy-path drive — the emission gate + static tests already prove
// those families are registered & panel-backed. A panel-wide datasource ERROR (wrong URL,
// VM unreachable, uid mismatch) makes EVERY panel fail; that is the failure this catches,
// plus the positive proof that live data renders.

const GRAFANA_URL = process.env.GRAFANA_URL;

// The six dashboards Core.PromEx ships (uid = dashboard JSON `uid`).
//
// requireLiveData: assert ≥1 panel paints real data. True for dashboards the
// happy-path E2E drives richly. FALSE for moderation_agegate: 4 of its 6 panels
// query `stacks_moderation_*` classifier metrics that ship DARK (the classifier was
// removed in the age-gate rework — the metrics stay registered but are never driven),
// and the remaining 2 age-gate panels are sparse single-event `rate()`s that don't
// deterministically paint at a given instant. For it we still assert the strongest
// signal — it loads and NO panel is in a datasource/query error state — but not
// live-data, which would be a flaky and semantically-wrong expectation here.
const DASHBOARDS = [
  { uid: "stacks-auth-security", title: "Auth & Session Security", requireLiveData: true },
  { uid: "stacks-visibility-social", title: "Visibility, Social & ViewAs", requireLiveData: true },
  { uid: "stacks-gdpr-data-rights", title: "GDPR Data Rights", requireLiveData: true },
  { uid: "stacks-discovery", title: "Discovery & Profiles", requireLiveData: true },
  { uid: "stacks-platform-ops", title: "Platform / Ops", requireLiveData: true },
  {
    uid: "stacks-moderation-agegate",
    title: "Moderation Funnel & Age Gate",
    requireLiveData: false,
  },
];

// A wide window so freshly-pushed samples (VM latencyOffset + push interval) are in
// range. No kiosk mode — kiosk hides the dashboard title bar, and we key off panel
// content (a more robust load signal) rather than the title text anyway.
function dashboardUrl(uid: string): string {
  return `${GRAFANA_URL}/d/${uid}?from=now-6h&to=now`;
}

// Grafana lazy-renders panels as they scroll into view. Walk to the bottom so every
// panel mounts and issues its query before we assert.
async function scrollAllPanelsIntoView(page: Page): Promise<void> {
  await page.evaluate(async () => {
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
    for (let y = 0; y <= document.body.scrollHeight; y += 500) {
      window.scrollTo(0, y);
      await sleep(120);
    }
    window.scrollTo(0, 0);
    await sleep(300);
  });
}

test.describe("Grafana dashboards render live data (#236–240)", () => {
  test.skip(
    !GRAFANA_URL,
    "Set GRAFANA_URL to a running Grafana (preview/prod) to enforce the render guarantee.",
  );
  test.use({ storageState: { cookies: [], origins: [] } }); // anonymous

  for (const dash of DASHBOARDS) {
    test(`${dash.title} renders with a healthy datasource and live panels`, async ({
      page,
    }) => {
      // First push→query can lag (push 15s + VM flush ~10s + query). Retry the whole
      // load/assert on a generous budget so a cold preview settles.
      await expect(async () => {
        await page.goto(dashboardUrl(dash.uid), { waitUntil: "networkidle" });

        // The dashboard loaded (not a 404 / login / datasource-config error page):
        // at least one panel's content region is present. This is a more robust load
        // signal than the dashboard title (which chrome/kiosk settings can hide).
        await expect(
          page.locator('[data-testid="data-testid panel content"]').first(),
        ).toBeVisible({ timeout: 15_000 });

        await scrollAllPanelsIntoView(page);

        // (a) No panel is in a query/datasource ERROR state. A broken datasource
        // (wrong STACKS_VM_URL, VM down, uid mismatch) trips every panel here.
        const errorPanels = page.locator(
          '[data-testid="data-testid Panel status error"], [aria-label="Panel status error"], .panel-status-error',
        );
        expect(
          await errorPanels.count(),
          "a panel is in an error state — datasource likely misconfigured/unreachable",
        ).toBe(0);

        // (b) At least one panel paints real data (not the "No data" placeholder).
        // The emission gate guarantees each dashboard has live families; here we prove
        // that surfaces in the browser. Total panels minus "No data" panels ≥ 1.
        const panelCount = await page
          .locator('[data-testid="data-testid panel content"]')
          .count();
        expect(panelCount, "no panels rendered — dashboard failed to load").toBeGreaterThan(0);

        if (dash.requireLiveData) {
          const noDataCount = await page.getByText("No data", { exact: true }).count();
          expect(
            panelCount - noDataCount,
            `every panel shows "No data" (${noDataCount}/${panelCount}) — no live data reached Grafana`,
          ).toBeGreaterThanOrEqual(1);
        }
      }).toPass({ timeout: 120_000, intervals: [5_000, 10_000, 15_000] });
    });
  }
});
