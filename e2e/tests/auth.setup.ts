import { test as setup, newProvenContext, SESSION_COOKIE } from "./fixtures";
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
  elevateOwnerAdmin,
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

  await page.goto("/");

  // ⛔ THE COOKIE HAS TO BE CARRIED ACROSS BY HAND, and the reason is structural
  // rather than an oversight. The login above runs through the `request`
  // fixture, which has its own cookie jar — so the server's
  // `Set-Cookie: stacks_session=…` landed in THAT context and the page context
  // never saw it. Measured before this change: every saved state in
  // `e2e/.auth/*.json` held exactly one cookie, `stacks_csrf`, and no session
  // cookie at all — so the whole suite authenticated by bearer while the server
  // had been issuing cookies since the transport landed.
  //
  // ⚠️ Attributes must match what the server sets (`HttpOnly; Secure;
  // SameSite=Lax`). A cookie that differs is not sent, and the symptom is
  // indistinguishable from logged-out.
  await page.context().addCookies([
    {
      name: SESSION_COOKIE,
      value: body.token,
      url: new URL(page.url()).origin,
      httpOnly: true,
      secure: true,
      sameSite: "Lax",
    },
  ]);

  // ⛔ NOTHING ELSE IS SAVED. A `stacks-auth` blob used to be written into the
  // storage state beside the cookie, because the SPA read its identity from it
  // and around thirty specs pulled a bearer out of it for direct `fetch` calls.
  // The SPA now asks `GET /api/auth/me`, and those specs now let the cookie
  // authenticate them — so the saved state is the cookie jar and nothing more.
  await page.context().storageState({ path: stateFile });
}

/**
 * Authenticate the owner user (used by tests that need owner-level access).
 */
setup("authenticate as owner", async ({ request, page }) => {
  await authenticateUser(request, page, DEV_EMAIL, DEV_PASSWORD, OWNER_AUTH_FILE);
});

/**
 * Enrol the owner's admin second factor ONCE per run.
 *
 * The owner has exactly one TOTP factor and every admin spec shares that one
 * account, so enrolment is a MUTATION of state four parallel specs depend on.
 * Done per-test — as `admin-session.spec.ts` used to — the specs replace each
 * other's secret and their codes are rejected, which surfaces as a gate that
 * never opens: the same symptom as the four real defects that file exists
 * to catch. Doing it here, before the parallel phase any project runs in, makes
 * the factor immutable for the rest of the run; the specs only read it.
 */
setup("enrol the owner's admin MFA factor and elevate once for the whole run", async ({
  request,
}) => {
  // ⛔ ONE STEP, BECAUSE THE SECOND HALF READS WHAT THE FIRST HALF WRITES.
  // These were two `setup()` calls, and `fullyParallel: true` ran them against
  // each other: `elevateOwnerAdmin` calls `readOwnerMfaSecret()`, which is the
  // file `saveOwnerMfaSecret` has just written — or has not written yet.
  //
  // ⚠️ MEASURED 2026-11-07 on a local stack: `admin login` failed in 77ms while
  // the enrolment step passed in 88ms, i.e. elevation reached the server first
  // and verified against a secret that was about to be replaced. Nothing in
  // Playwright ordered them, and nothing would have: setup steps in one file are
  // peers.
  //
  // ⚖️ Merged rather than ordered with `dependencies`, because the dependency is
  // not between two concerns that happen to share a fixture — elevation has no
  // meaning without the factor it verifies against. Two steps invited the race;
  // one step cannot have it.
  saveOwnerMfaSecret(await enrolOwnerMfa(request));
  await elevateOwnerAdmin(request);
});

/**
 * Elevate the operator ONCE, here, for the whole run.
 *
 * ⛔ ELEVATION IS A PROPERTY OF THE OPERATOR, NOT OF THE WORKER, and that is why
 * this belongs in setup rather than in a per-call helper.
 * `Admin.SessionContext.current_for_user/2` looks the admin session up FROM THE
 * USER — newest non-revoked row for that `user_id` — so a worker making an admin
 * write needs only an ordinary owner session cookie plus the existence of one
 * live elevated admin session anywhere.
 *
 * ⛔ And elevating per worker actively BREAKS: `create/3` runs
 * `retire_live_sessions(user.id)` before inserting, revoking every other live
 * admin session the operator holds. Measured against a deployed stack — four
 * workers each elevating produced `admin MFA verify -> 401` (`invalid_session`,
 * the previous worker's `session_id` revoked out from under it), and a shared
 * TOTP step compounds it because a code is single-use. Same suite at
 * `--workers=1`: 33 passed, 0 failed. The server is right; `create/3`'s own
 * moduledoc states the intent — "an operator working from two machines at once is
 * bounced from the first — accepted, because this platform has one operator".
 *
 * ⚠️ TWO WAYS THIS CAN LAPSE MID-RUN, and both surface as a 401 that reads like
 * bad credentials rather than like a lapsed window:
 *   - `RequireMFA` allows 30 minutes from `mfa_verified_at`. A long retrying run
 *     can cross it.
 *   - `check_valid/2` matches `boot_id` and IP. Preview machines auto-stop, so a
 *     restart mid-run invalidates elevation for every worker at once.
 * `assertOwnerElevated` exists to say which of those happened instead of letting
 * the failure surface as "invite create".
 *
 * ⚠️ LOAD-BEARING: `admin-session.spec.ts` and `admin-feedback.spec.ts`
 * deliberately RESET elevation mid-run (via the `STACKS_E2E_TEST_HELPERS` helper
 * that calls `revoke_all_for_user`). They only stay compatible with this because
 * they run in serial projects that `dependencies` order AFTER the parallel pool.
 * Moving either back into the parallel pool would destroy elevation under the
 * specs that now rely on it being established here.
 */


/**
 * Authenticate all per-suite E2E users in one setup step.
 * Each gets its own storage state file for parallel isolation.
 */
setup("authenticate E2E suite users", async ({ request, browser }) => {
  setup.setTimeout(120_000); // 16 suite users × ~2s each against remote preview
  for (const slug of E2E_SUITES) {
    const context = await newProvenContext(browser);
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
