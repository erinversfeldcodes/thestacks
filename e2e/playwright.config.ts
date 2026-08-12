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
      name: "setup",
      testMatch: /auth\.setup\.ts/,
    },
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testIgnore: /(upload.*|rate-limit)\.spec\.ts/,
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
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup", "chromium", "upload-mock", "upload"],
      testMatch: /rate-limit\.spec\.ts$/,
      fullyParallel: false,
      retries: 0,
    },
  ],
});
