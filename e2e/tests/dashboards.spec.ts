import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import { mintSession } from "./helpers";

const GRAFANA_URL = process.env.GRAFANA_URL;

/**
 * Each live-data dashboard DRIVES the data it asserts on: `drive` performs one
 * cheap authenticated API action that emits a metric family the dashboard
 * panels. Without this, the assertion depended on sibling specs having
 * incidentally fired the right telemetry — an ordering race that failed
 * whenever this spec ran before them.
 */
const DASHBOARDS: Array<{
  uid: string;
  title: string;
  requireLiveData: boolean;
  drive?: (request: APIRequestContext, token: string) => Promise<void>;
}> = [
  // Driven by the setup project's real logins, which always precede chromium.
  { uid: "stacks-auth-security", title: "Auth & Session Security", requireLiveData: true },
  {
    uid: "stacks-visibility-social",
    title: "Visibility, Social & ViewAs",
    requireLiveData: true,
    // Emits the profile-visibility-change counter (fires on every save,
    // including a same-direction save, so no state assumptions needed).
    drive: async (request, token) => {
      const resp = await request.put("/api/settings/profile_visibility", {
        headers: { Authorization: `Bearer ${token}` },
        data: { profile_visibility: "platform" },
      });
      expect(resp.ok(), "visibility driver: profile_visibility save failed").toBeTruthy();
    },
  },
  {
    uid: "stacks-gdpr-data-rights",
    title: "GDPR Data Rights",
    requireLiveData: true,
    // Emits the consent-outcome counter.
    drive: async (request, token) => {
      const resp = await request.post("/api/gdpr/consent", {
        headers: { Authorization: `Bearer ${token}` },
        data: { consent: true, type: "analytics" },
      });
      expect(resp.ok(), "gdpr driver: consent grant failed").toBeTruthy();
    },
  },
  {
    uid: "stacks-discovery",
    title: "Discovery & Profiles",
    requireLiveData: true,
    // Emits the people-search outcome counter (fires on hit AND zero_result).
    drive: async (request, token) => {
      const resp = await request.get("/api/search/users?q=dashboard-driver", {
        headers: { Authorization: `Bearer ${token}` },
      });
      expect(resp.ok(), "discovery driver: people search failed").toBeTruthy();
    },
  },
  // Every HTTP request (including the drivers above) feeds router/repo panels.
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
      request,
    }) => {
      // The wait below is bounded by the metrics push interval (~15s), not by
      // other specs: the driver has already emitted this dashboard's data. The
      // test timeout must exceed the toPass window plus one attempt, or the
      // window is silently truncated by the 90s default.
      test.setTimeout(120_000);

      if (dash.drive) {
        const session = await mintSession(request, {});
        test.skip(
          session === null,
          "live-data drive requires the session-mint helper (STACKS_E2E_TEST_HELPERS=1)",
        );
        await dash.drive(request, session!.token);
      }

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
      }).toPass({ timeout: 60_000, intervals: [5_000, 10_000, 15_000] });
    });
  }
});
