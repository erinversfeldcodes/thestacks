import { defineConfig, devices } from "@playwright/test";

const isDeployed = !!process.env.BASE_URL;

export default defineConfig({
  testDir: "./tests",
  globalSetup: "./global-setup",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  timeout: isDeployed ? 90_000 : 30_000,
  workers: process.env.CI ? 2 : 4,
  reporter: "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://localhost:4000",
    trace: "on-first-retry",
  },
  projects: [
    {
      // Claims about calculations, not about a stack. No browser, no
      // dependency on `setup`, nothing to deploy: `tests/unit` holds the logic
      // a spec would otherwise be able to exercise only by flooding a live
      // preview. It runs first because it costs milliseconds, and `npm test`
      // selects every project, so it runs on both the local and the deployed
      // path without either runner naming it.
      name: "unit",
      testDir: "./tests/unit",
    },
    {
      name: "setup",
      testMatch: /auth\.setup\.ts/,
    },
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      // `**/unit/**` is excluded because chromium's testDir is the whole
      // `tests` tree: without it the offline cases would run a second time,
      // behind a login they do not need.
      testIgnore: [/(upload.*|rate-limit)\.spec\.ts/, "**/unit/**"],
    },
    {
      name: "upload-mock",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testMatch: /upload-pipeline\.spec\.ts/,
    },
    {
      name: "upload",
      timeout: 300_000,
      retries: 2,
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock"],
      testMatch: /upload\.spec\.ts$/,
      fullyParallel: false,
    },
    {
      name: "ratelimit",
      // Flooding a bucket to its ceiling, then waiting out the window so the
      // stage behind this one does not inherit a spent budget, cannot fit in
      // the 90s default: the drain alone is a full 60s window, and an
      // afterEach hook spends the test's own budget. Sized for the flood plus
      // one window plus slack rather than tuned to an observed duration.
      timeout: 240_000,
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock", "upload"],
      testMatch: /rate-limit\.spec\.ts$/,
      fullyParallel: false,
      retries: 0,
    },
  ],
});
