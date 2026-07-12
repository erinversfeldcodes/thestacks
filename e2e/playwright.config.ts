import { defineConfig, devices } from "@playwright/test";

// When BASE_URL points at a remote deployment (Fly.io preview), cold starts and
// Neon wake-up can push individual test steps past the default 30 s. Use 90 s
// for deployed runs so flaky timeouts don't mask real failures.
const isDeployed = !!process.env.BASE_URL;

export default defineConfig({
  testDir: "./tests",
  // Warm the deployed preview before any project runs (Issue #175). No-op when
  // BASE_URL is unset, so local runs are untouched.
  globalSetup: "./global-setup",
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
      // Exclude the upload projects AND the rate-limit saturation test — the
      // latter has its own dedicated `ratelimit` project that runs last/alone.
      testIgnore: /(upload.*|rate-limit)\.spec\.ts/,
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
      // Two retries to absorb transient external-service flakiness (Google Books
      // / Open Library rate limits, Modal cold-starts, R2 hiccups). Worst case
      // a hung test still terminates on the 300 s per-attempt timeout, so the
      // serial project cannot run longer than 3 × 300 s × test_count even when
      // every retry exhausts. Do NOT use retries to mask consistent failures —
      // a test that needs all three attempts to pass is a flaky test that
      // needs fixing.
      retries: 2,
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock"],
      testMatch: /upload\.spec\.ts$/,
      fullyParallel: false,
    },
    // Rate-limit saturation test (Issue #176, B1): runs LAST and ALONE.
    // It floods the real Fly stack's per-IP `:auth` bucket to trip a 429, which
    // saturates the shared bucket for ~60s — so it depends on every other
    // project and disables parallelism/retries. See rate-limit.spec.ts header
    // for the full isolation rationale.
    {
      name: "ratelimit",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock", "upload"],
      testMatch: /rate-limit\.spec\.ts$/,
      fullyParallel: false,
      retries: 0,
    },
  ],
});
