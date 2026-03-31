import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
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
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock"],
      testMatch: /upload\.spec\.ts$/,
      fullyParallel: false,
    },
  ],
});
