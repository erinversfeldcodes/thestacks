import { test as setup } from "@playwright/test";
import path from "path";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

export const OWNER_AUTH_FILE = path.join(__dirname, "../.auth/owner.json");

/**
 * Authenticate once via the API and save storage state.
 * All test suites that need auth use: test.use({ storageState: OWNER_AUTH_FILE })
 * This avoids calling /api/auth/login in every test, preventing rate limiting.
 */
setup("authenticate as owner", async ({ request, page }) => {
  const resp = await request.post("/api/auth/login", {
    data: { email: DEV_EMAIL, password: DEV_PASSWORD },
  });

  const body = await resp.json();

  // Navigate to the app so we can set localStorage on the correct origin
  await page.goto("/");

  // Inject auth into localStorage — same format as the saveAuth port
  await page.evaluate(
    (auth) => {
      localStorage.setItem("stacks-auth", JSON.stringify(auth));
    },
    {
      token: body.token,
      userId: body.user.id,
      email: body.user.email,
      displayName: body.user.display_name,
    }
  );

  // Save the browser context (cookies + localStorage) for reuse
  await page.context().storageState({ path: OWNER_AUTH_FILE });
});
