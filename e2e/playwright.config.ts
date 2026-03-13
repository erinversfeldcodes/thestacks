import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  // workers=1 keeps GPU requests sequential — concurrent jobs queue on VisionModel
  // (1 A10G GPU, serial inference) and the 4th job can exceed Elm's 150s polling
  // limit (75 polls × 2s). Sequential execution keeps each pipeline under 60s.
  workers: 1,
  reporter: "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://localhost:4000",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
