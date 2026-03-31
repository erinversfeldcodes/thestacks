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
    // Real upload tests: serial execution (GPU constraint)
    // 300s project-level timeout: cold GPU start (~30s) + classify (~20s) +
    // extract (~20s) + Open Library lookup + polling headroom.
    // test.setTimeout() inside tests can reduce this for faster paths.
    {
      name: "upload",
      timeout: 300_000,
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testMatch: /upload\.spec\.ts$/,
      fullyParallel: false,
    },
  ],
});
