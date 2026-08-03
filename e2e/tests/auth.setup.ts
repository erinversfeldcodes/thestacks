import { test as setup } from "@playwright/test";
import path from "path";
import {
  DEV_EMAIL,
  DEV_PASSWORD,
  E2E_PASSWORD,
  E2E_SUITES,
  enrolOwnerMfa,
  saveOwnerMfaSecret,
  suiteAuthFile,
  suiteEmail,
} from "./helpers";

export const OWNER_AUTH_FILE = path.join(__dirname, "../.auth/owner.json");

/**
 * Authenticate a user via the API and save storage state.
 */
async function authenticateUser(
  request: any,
  page: any,
  email: string,
  password: string,
  stateFile: string
) {
  const resp = await request.post("/api/auth/login", {
    data: { email, password },
  });

  if (!resp.ok()) {
    throw new Error(
      `Auth setup: login failed for ${email} (HTTP ${resp.status()}). ` +
        `Check that the dev server is running and seeds are loaded.`
    );
  }

  const body = await resp.json();

  // Navigate to the app so we can set localStorage on the correct origin
  await page.goto("/");

  // Inject auth into localStorage — same format as the saveAuth port
  await page.evaluate(
    (auth: any) => {
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
  await page.context().storageState({ path: stateFile });
}

/**
 * Authenticate the owner user (used by tests that need owner-level access).
 */
setup("authenticate as owner", async ({ request, page }) => {
  await authenticateUser(request, page, DEV_EMAIL, DEV_PASSWORD, OWNER_AUTH_FILE);
});

/**
 * Enrol the owner's admin second factor ONCE per run (Issue #371).
 *
 * The owner has exactly one TOTP factor and every admin spec shares that one
 * account, so enrolment is a MUTATION of state four parallel specs depend on.
 * Done per-test — as `admin-session.spec.ts` used to — the specs replace each
 * other's secret and their codes are rejected, which surfaces as a gate that
 * never opens: the same symptom as the four real #303 defects that file exists
 * to catch. Doing it here, before the parallel phase any project runs in, makes
 * the factor immutable for the rest of the run; the specs only read it.
 */
setup("enrol the owner's admin MFA factor", async ({ request }) => {
  saveOwnerMfaSecret(await enrolOwnerMfa(request));
});

/**
 * Authenticate all per-suite E2E users in one setup step.
 * Each gets its own storage state file for parallel isolation.
 */
setup("authenticate E2E suite users", async ({ request, browser }) => {
  setup.setTimeout(120_000); // 16 suite users × ~2s each against remote preview
  for (const slug of E2E_SUITES) {
    const context = await browser.newContext();
    const page = await context.newPage();
    await authenticateUser(
      request,
      page,
      suiteEmail(slug),
      E2E_PASSWORD,
      suiteAuthFile(slug)
    );
    await context.close();
  }
});
