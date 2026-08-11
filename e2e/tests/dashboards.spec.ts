import { test, expect, type Page } from "@playwright/test";

const GRAFANA_URL = process.env.GRAFANA_URL;

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

function dashboardUrl(uid: string): string {
  return `${GRAFANA_URL}/d/${uid}?from=now-6h&to=now`;
}

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

test.describe("Grafana dashboards render live data", () => {
  test.skip(
    !GRAFANA_URL,
    "Set GRAFANA_URL to a running Grafana (preview/prod) to enforce the render guarantee.",
  );
  test.use({ storageState: { cookies: [], origins: [] } }); // anonymous

  for (const dash of DASHBOARDS) {
    test(`${dash.title} renders with a healthy datasource and live panels`, async ({
      page,
    }) => {
      await expect(async () => {
        await page.goto(dashboardUrl(dash.uid), { waitUntil: "networkidle" });

        await expect(
          page.locator('[data-testid="data-testid panel content"]').first(),
        ).toBeVisible({ timeout: 15_000 });

        await scrollAllPanelsIntoView(page);

        const errorPanels = page.locator(
          '[data-testid="data-testid Panel status error"], [aria-label="Panel status error"], .panel-status-error',
        );
        expect(
          await errorPanels.count(),
          "a panel is in an error state — datasource likely misconfigured/unreachable",
        ).toBe(0);

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
