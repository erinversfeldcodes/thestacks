import { defineConfig, devices } from "@playwright/test";

// When BASE_URL points at a remote deployment (Fly.io preview), cold starts and
// Neon wake-up can push individual test steps past the default 30 s. Use 90 s
// for deployed runs so flaky timeouts don't mask real failures.
const isDeployed = !!process.env.BASE_URL;

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  timeout: isDeployed ? 90_000 : 30_000,
  // Parallelise non-upload tests across 4 workers.
  // Upload tests run in a dedicated serial project (workers=1) because the
  // vision model (1 A10G GPU, serial inference) queues concurrent jobs and
  // the 4th would exceed Elm's 150s polling limit.
  workers: process.env.CI ? 2 : 4,
  reporter: "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://localhost:4000",
    trace: "on-first-retry",
  },
  projects: [
    // Setup project: authenticates once, saves storage state for reuse
    {
      name: "setup",
      testMatch: /auth\.setup\.ts/,
    },
    // Main test suite: all non-upload tests, parallelised
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testIgnore: /upload.*\.spec\.ts/,
    },
    // Mock-based upload pipeline tests: parallelised (no GPU needed)
    {
      name: "upload-mock",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testMatch: /upload-pipeline\.spec\.ts/,
    },
    // Real upload tests: serial execution (GPU constraint), runs after all
    // mocked/browser tests complete. This gives the external APIs (Google Books,
    // Open Library) a quiet window before the title-search-dependent tests run,
    // reducing 429 rate-limit failures from concurrent API calls across projects.
    {
      name: "upload",
      timeout: 300_000,
      retries: 0,
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock"],
      testMatch: /upload\.spec\.ts$/,
      fullyParallel: false,
    },
  ],
});
