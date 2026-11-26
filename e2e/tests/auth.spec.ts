import { test, expect } from "./fixtures";
import {
  expireSession,
  hasSessionCookie,
  signInViaForm,
  suiteAuthFile,
} from "./helpers";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Authentication", () => {
  test("sign in with valid credentials navigates to home and shows user name", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();

    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    await expect(page.getByTestId('user-menu')).toHaveText("Platform Owner");
    await expect(page.locator('a[href="/login"]')).not.toBeVisible();
  });

  test("sign in with wrong password shows error message", async ({ page }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', "wrong-password");
    await page.getByTestId('login-submit').click();

    await expect(page.getByTestId('login-error')).toBeVisible();
    await expect(page.getByTestId('login-error')).toContainText(
      "The door remains shut."
    );

    await expect(page).toHaveURL("/login");
  });

  test("a failed login preserves the typed email and password", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', "wrong-password");
    await page.getByTestId("login-submit").click();

    const error = page.getByTestId("login-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText(
      "The door remains shut. Invalid credentials."
    );

    await expect(page.locator('input[id="email"]')).toHaveValue(DEV_EMAIL);
    await expect(page.locator('input[id="password"]')).toHaveValue(
      "wrong-password"
    );
  });

  test("sign in with unknown email shows error message", async ({ page }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', "nobody@example.com");
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();

    await expect(page.getByTestId('login-error')).toBeVisible();
    await expect(page).toHaveURL("/login");
  });

  test("upload page redirects to login when not authenticated", async ({
    page,
  }) => {
    await page.goto("/upload");

    await expect(page.locator('input[id="email"]')).toBeVisible();
  });

  test("upload page is accessible after signing in", async ({ page }) => {
    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    await page.click('a.app-nav__add-book[href="/upload"]');
    await page.waitForURL("/upload");

    await expect(page.getByTestId('upload-auth-required')).not.toBeVisible();
    await expect(page.getByTestId('upload-drop-zone')).toBeVisible();
  });
});

test.describe("Owner-only admin navigation", () => {
  test("the platform owner sees the Admin disclosure (Sources/Scrapers)", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Admin is a disclosure BUTTON now, not a hover-revealed
    // dropdown link: a real <button class="app-nav__disclosure" aria-haspopup>
    // whose Sources/Scrapers/… sub-links are absent from the DOM until it is
    // clicked open. The CSS :hover reveal is gone (it was unreachable on touch).
    const adminToggle = page.locator(
      'button.app-nav__disclosure:has-text("Admin")'
    );
    await expect(adminToggle).toBeVisible();
    await adminToggle.click();
    await expect(adminToggle).toHaveAttribute("aria-expanded", "true");

    const sources = page.locator(
      'a.app-nav__dropdown-link[href="/admin/sources"]'
    );
    const scrapers = page.locator(
      'a.app-nav__dropdown-link[href="/admin/scrapers"]'
    );
    await expect(sources).toBeVisible();
    await expect(sources).toHaveText("Sources");
    await expect(scrapers).toBeVisible();
    await expect(scrapers).toHaveText("Scrapers");
  });
});

test.describe("Non-owner admin navigation", () => {
  test.use({ storageState: suiteAuthFile("auth") });

  test("a non-owner user does not see the Admin dropdown", async ({ page }) => {
    await page.goto("/library");

    await expect(page.getByTestId("user-menu")).toBeVisible();
    await expect(page.locator('a[href="/admin/sources"]')).toHaveCount(0);
    await expect(page.locator('a[href="/admin/scrapers"]')).toHaveCount(0);
  });
});

test.describe("Logout", () => {
  test("signing out ends the session, reverts the nav, and kills the token server-side", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    expect(
      await hasSessionCookie(page),
      "signing in must leave this context holding a session cookie"
    ).toBe(true);

    await page.getByTestId("user-menu").click();

    // ⛔ AWAIT THE REQUEST, NOT THE NAVIGATION, and the reason has changed since
    // this was written. Sign-out used to dispatch
    // `Cmd.batch [ logoutCmd, clearListingDraft (), Nav.pushUrl … ]`, so the URL
    // changed LOCALLY and immediately while `DELETE /api/auth/logout` was still
    // in flight; `waitForURL` was satisfied before the server had cleared the
    // cookie, and the assertion below read a cookie the response was about to
    // remove — failing consistently rather than flakily, because the local
    // navigation always won the race. Measured on a deployed stack: the server
    // answers `204` and sends
    //   set-cookie: stacks_session=…; max-age=0; expires=Thu, 01 Jan 1970 …
    // which is correct, so this was never a server defect.
    //
    // ⚖️ The app now waits for that response itself — a sign-out the server did
    // not confirm leaves the reader signed in and says so — so the navigation no
    // longer races this. Awaiting the response stays anyway: it is what makes the
    // cookie assertion below an assertion about a COMPLETED sign-out rather than
    // about whichever of two async events happened to land first.
    const loggedOut = page.waitForResponse(
      (r) =>
        r.url().includes("/api/auth/logout") && r.request().method() === "DELETE"
    );
    await page.getByRole("button", { name: "Sign Out" }).click();
    await loggedOut;

    await page.waitForURL("**/login");

    await expect(page.locator('a[href="/login"]')).toBeVisible();
    await expect(page.getByTestId("user-menu")).toHaveCount(0);

    // ⛔ The cookie, not a localStorage blob. Sign-out clears it SERVER-side
    // (`AuthController.logout/2` → `SessionCookie.delete_session_cookie/1`), so
    // this asserts the credential is actually gone from the browser rather than
    // that the SPA forgot a copy of it — which is what the old assertion
    // checked, and which was never a revocation.
    expect(
      await hasSessionCookie(page),
      "signing out must clear the session cookie, not merely the SPA's memory"
    ).toBe(false);

    await page.goto("/upload");
    await expect(page.locator('input[id="email"]')).toBeVisible();

    // ⛔ `page.request` shares the browser context's cookie jar, which sign-out
    // emptied — so this is the signed-out reader's own request, not a synthetic
    // credential-free one. It used to send the bearer the SPA had been holding;
    // there is no such bearer any more, and the cookie's absence is the whole
    // credential story.
    const resp = await page.request.get("/api/placements/mine");
    expect(resp.status()).toBe(401);
  });
});

test.describe("Unauthenticated access to protected pages", () => {
  test("visiting /library unauthenticated renders the login form at the SAME url", async ({
    page,
  }) => {
    await page.goto("/library");

    await expect(page.locator('input[id="email"]')).toBeVisible({
      timeout: 10000,
    });

    expect(page.url()).toMatch(/\/library$/);
    expect(page.url()).not.toMatch(/\/login$/);
  });

  const protectedRoutes = ["/settings/privacy", "/marketplace/create"];
  for (const route of protectedRoutes) {
    test(`visiting ${route} unauthenticated renders the login form`, async ({
      page,
    }) => {
      await page.goto(route);

      await expect(page.locator('input[id="email"]')).toBeVisible({
        timeout: 10000,
      });
      await expect(page.locator('input[id="password"]')).toBeVisible();

      expect(page.url()).toContain(route);
    });
  }
});

/**
 * — the credential must land regardless of the door animation.
 *
 * The defect these two tests exist for: the app persisted the auth token only
 * when the browser reported the WAAPI door animation finished. That report comes
 * out of a `requestAnimationFrame` callback resolving `Animation.finished`
 * promises, and neither runs while the window is occluded or backgrounded. So a
 * login could return `200` and the credential be discarded in silence — driven
 * live 2026-07-30: three logins, three 200s, nothing in localStorage.
 *
 * A test that only signs in with the window in front reproduces the bug's own
 * blind spot, which is exactly why this shipped. So both tests below assert the
 * token is stored WITHIN ONE SECOND of the 200, in a browser state where the
 * animation's completion signal provably cannot arrive.
 *
 * ## Why not literally occlude the window
 *
 * A Playwright-driven Chromium will not background a page. Measured 2026-07-31
 * against this stack, across three launch modes — headless, headed, and headed
 * with `--disable-backgrounding-occluded-windows` / `--disable-renderer-
 * backgrounding` / `--disable-background-timer-throttling` removed — and with
 * the second page opened both as `context.newPage()` and as a same-window
 * `target="_blank"` tab:
 *
 *     headless-default:   newPage=visible tabClick=visible rafFired=true
 *     headed-default:     newPage=visible tabClick=visible rafFired=true
 *     headed-no-bg-flags: newPage=visible tabClick=visible rafFired=true
 *
 * Every page Playwright drives is its own always-active CDP target, so
 * `document.visibilityState` never leaves `"visible"` and rAF keeps being
 * served. A first cut of the test below asserted `"hidden"` and failed on that
 * assertion rather than passing vacuously — that failure is what produced this
 * measurement.
 *
 * So both tests reproduce the DEFECT'S MECHANISM instead of its cause. What an
 * occluded window does to this code is precisely one thing: the door
 * animations' `finished` promises never settle, so anything waiting on them
 * waits forever. That is reproduced here two ways, and each one fails closed —
 * each asserts the stall really took hold before it asserts anything else, so
 * neither can quietly stop reproducing the condition it exists for:
 *
 *   1. "the completion signal never arrives" — `Element.prototype.animate` is
 *      replaced with animations whose `finished` promise has no resolver.
 *      Engine-independent; works in any browser or headless mode.
 *   2. "every animation is stalled" — the REAL animation engine is frozen at
 *      the browser level (CDP `Animation.setPlaybackRate: 0`). Real
 *      `Element.animate`, real `Animation` objects, real `finished` promises,
 *      stalled exactly as an occluded compositor stalls them; and rAF still
 *      fires, which reproduces the other half of the live evidence (frozen
 *      transitions, zero completed animations).
 *
 * Under the pre-code both hang until timeout: the token is never written.
 */
test.describe("Login is not downstream of the door animation", () => {
  /**
   * Poll until the SPA has ACTED on the 200; return how long it took.
   *
   * ⛔ It polls the post-login NAVIGATION, and the reason is the whole point of
   * this file. The obvious migration — poll for the session cookie — would be
   * VACUOUS: the cookie arrives on the login response itself, before a line of
   * Elm runs, so it would be there even if the SPA discarded the 200 entirely.
   * That is exactly the defect this suite exists to catch.
   *
   * Navigating to the asked-for page is a `LoginEffect`, fired from the update
   * that decodes the 200. Under the pre-code — where the effects waited for an
   * animation-finished signal an occluded window never sends — the URL stays on
   * `/login` until the deadline.
   */
  async function msUntilSignedIn(page, deadlineMs: number) {
    const start = Date.now();
    while (Date.now() - start < deadlineMs) {
      if (!page.url().includes("/login")) {
        return { elapsed: Date.now() - start, signedIn: true };
      }
      await page.waitForTimeout(25);
    }
    return { elapsed: Date.now() - start, signedIn: false };
  }

  /**
   * Does a freshly-started animation refuse to finish? Run before each test's
   * real assertions so a harness that quietly stops stalling animations makes
   * the test FAIL rather than pass for the wrong reason.
   */
  async function stallProof(page): Promise<boolean> {
    return page.evaluate(() => {
      const probe = document.createElement("div");
      document.body.appendChild(probe);
      const animation = probe.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: 30,
      });
      return Promise.race([
        Promise.resolve(animation.finished).then(() => false),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(true), 400)),
      ]);
    });
  }

  test("the completion signal never arrives: a 200 is still persisted", async ({
    page,
  }) => {
    await page.addInitScript(() => {
      const neverFinishes = new Promise(() => {});
      Element.prototype.animate = function () {
        return {
          finished: neverFinishes,
          cancel() {},
          finish() {},
          pause() {},
          play() {},
          addEventListener() {},
          removeEventListener() {},
        } as unknown as Animation;
      };
    });

    await page.goto("/login");

    const stalled = await stallProof(page);
    expect(
      stalled,
      "WAAPI still finishes — this test must not pass without reproducing the condition"
    ).toBe(true);

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);

    const response = page.waitForResponse(
      (r) => r.url().includes("/api/auth/login") && r.status() === 200
    );
    await page.getByTestId("login-submit").click();
    await response;

    const { elapsed, signedIn } = await msUntilSignedIn(page, 1000);
    expect(
      signedIn,
      "the 200 was discarded: still on /login 1s after a successful login"
    ).toBe(true);
    expect(elapsed).toBeLessThan(1000);

    await page.reload();
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 15000 });
  });

  test("every animation is stalled: the real engine is frozen and the 200 still lands", async ({
    page,
    context,
  }) => {
    const cdp = await context.newCDPSession(page);
    await cdp.send("Animation.enable");
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 0 });

    await page.goto("/login");

    const stalled = await stallProof(page);
    expect(
      stalled,
      "the animation timeline is not frozen — this test must not pass without reproducing the condition"
    ).toBe(true);

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);

    const response = page.waitForResponse(
      (r) => r.url().includes("/api/auth/login") && r.status() === 200
    );
    await page.getByTestId("login-submit").click();
    await response;

    const { elapsed, signedIn } = await msUntilSignedIn(page, 1000);
    expect(
      signedIn,
      "the 200 was discarded while every animation was stalled"
    ).toBeTruthy();
    expect(elapsed).toBeLessThan(1000);

    await page.waitForURL("**/antilibrary", { timeout: 15000 });
  });
});

/**
 * — the login door dolly-shot plays again, driven from the shell.
 *
 * moved the credential off the animation frame by navigating away from the
 * login scene on the update that decoded the 200 — which unmounted the door
 * before the port's `requestAnimationFrame` callback could animate it. Measured
 * live 2026-07-31: `animationsStarted=0`. renders the door scene layers
 * from the SHELL while `AuthState` is `Arriving`, over the destination page, so
 * the ids the port targets are on screen again — without moving the credential
 * back behind the animation.
 *
 * A literal occluded-window drive is NOT achievable under Playwright —
 * measured that across three launch modes x two page-open methods: the page
 * always reports `"visible"` and rAF keeps firing. So these reuse
 * technique rather than rediscovering it: instrument WAAPI to count the door's
 * own animations, and for the counterfactual freeze the real timeline at the
 * browser level (CDP `Animation.setPlaybackRate: 0`), asserting the stall took
 * hold before asserting anything else.
 */
test.describe("The arrival door plays from the shell", () => {
  /**
   * Count WAAPI animations started on the door's OWN scene layers, leaving the
   * real engine intact. Counting only the door ids — not every animation on the
   * page — is what makes `> 0` mean "the shell rendered the door and the port
   * animated it", the precise thing that measured 0 before this issue.
   */
  async function instrumentDoorAnimations(page): Promise<void> {
    await page.addInitScript(() => {
      const doorIds = new Set([
        "bookshelf",
        "bookshelfDim",
        "passage",
        "passageBright",
        "vignette",
        "wash",
        "overlay",
      ]);
      (window as unknown as { __doorAnimations: number }).__doorAnimations = 0;
      const realAnimate = Element.prototype.animate;
      Element.prototype.animate = function (
        this: Element,
        ...args: unknown[]
      ) {
        if (doorIds.has(this.id)) {
          (window as unknown as { __doorAnimations: number })
            .__doorAnimations += 1;
        }
        return realAnimate.apply(this, args as Parameters<typeof realAnimate>);
      };
    });
  }

  /** Poll the door-animation counter until it climbs above zero, or give up. */
  async function doorAnimationCount(page, deadlineMs: number): Promise<number> {
    const start = Date.now();
    let count = 0;
    while (Date.now() - start < deadlineMs) {
      count = await page.evaluate(
        () =>
          (window as unknown as { __doorAnimations: number }).__doorAnimations ||
          0
      );
      if (count > 0) return count;
      await page.waitForTimeout(25);
    }
    return count;
  }

  /**
   * Does a freshly-started animation refuse to finish? Run before the frozen
   * test's real assertions so a harness that quietly stops stalling animations
   * FAILS rather than passes for the wrong reason (the pattern).
   */
  async function stallProof(page): Promise<boolean> {
    return page.evaluate(() => {
      const probe = document.createElement("div");
      document.body.appendChild(probe);
      const animation = probe.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: 30,
      });
      return Promise.race([
        Promise.resolve(animation.finished).then(() => false),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(true), 400)),
      ]);
    });
  }

  test("animationsStarted > 0: the dolly-shot animates the door over the destination", async ({
    page,
  }) => {
    await instrumentDoorAnimations(page);

    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);

    const response = page.waitForResponse(
      (r) => r.url().includes("/api/auth/login") && r.status() === 200
    );
    await page.getByTestId("login-submit").click();
    await response;

    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    const count = await doorAnimationCount(page, 4000);
    expect(
      count,
      "the door started zero animations — the dolly-shot is not playing over the arrival"
    ).toBeGreaterThan(0);
  });

  test("frozen door: the dolly-shot starts but never finishes, and the reader still lands authenticated", async ({
    page,
    context,
  }) => {
    await instrumentDoorAnimations(page);

    const cdp = await context.newCDPSession(page);
    await cdp.send("Animation.enable");
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 0 });

    await page.goto("/login");

    const stalled = await stallProof(page);
    expect(
      stalled,
      "the animation timeline is not frozen — this test must not pass without reproducing the condition"
    ).toBe(true);

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);

    const response = page.waitForResponse(
      (r) => r.url().includes("/api/auth/login") && r.status() === 200
    );
    await page.getByTestId("login-submit").click();
    await response;

    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    const count = await doorAnimationCount(page, 4000);
    expect(
      count,
      "the door never started, so this is not exercising the frozen dolly-shot"
    ).toBeGreaterThan(0);

    await page.reload();
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 15000 });
  });
});

test.describe("Session expiry", () => {
  test("an expired/revoked token redirects to login with a session-expired notice on the next authed action", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // ⛔ BOTH TRANSPORTS. Corrupting only the stored bearer token stopped ending
    // the session once the server began issuing an HttpOnly cookie: measured on
    // a preview, a context whose stored token had been corrupted still got 200
    // from /api/placements/mine, /api/bookshelves/library and
    // /api/onboarding/status, and nothing redirected — the cookie authenticated
    // every one of them. `expireSession` corrupts the cookie too.
    await expireSession(page);

    await page.goto("/library");

    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");

    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // ⚠️ NOT an assertion about the cookie. `expireSession` CORRUPTS it rather
    // than removing it, so it is still present — what must be true is that the
    // app refuses to render itself signed in on a credential the server rejects.
    await expect(page.getByTestId("user-menu")).toHaveCount(0);
  });

  test("Session expiry redirects from a newly-covered page (Settings/Privacy)", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    await page.goto("/settings/privacy");

    const saveProfileVisibility = page.getByRole("button", {
      name: "Save Profile Visibility",
    });
    await expect(saveProfileVisibility).toBeVisible({ timeout: 15000 });

    // Revoke the session out from under the open page. No credential to look
    // up: this runs in the page, so the session cookie goes with the request.
    await page.evaluate(async () => {
      await fetch("/api/auth/logout", { method: "DELETE" });
    });

    await page.locator(".form-field__select").first().selectOption("platform");
    await saveProfileVisibility.click();

    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");

    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // The app is signed OUT, not merely showing a login form: the signed-in
    // chrome is gone. (Asserted on the nav rather than on the cookie, because
    // the server revoked this session without being asked to clear a cookie
    // the browser still holds.)
    await expect(page.getByTestId("user-menu")).toHaveCount(0);
  });

  test("Session expiry redirects at boot when the placement check 401s (boot hook)", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // ⛔ BOTH TRANSPORTS. Corrupting only the stored bearer token stopped ending
    // the session once the server began issuing an HttpOnly cookie: measured on
    // a preview, a context whose stored token had been corrupted still got 200
    // from /api/placements/mine, /api/bookshelves/library and
    // /api/onboarding/status, and nothing redirected — the cookie authenticated
    // every one of them. `expireSession` corrupts the cookie too.
    await expireSession(page);

    await page.goto("/");

    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");

    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // ⚠️ NOT an assertion about the cookie. `expireSession` CORRUPTS it rather
    // than removing it, so it is still present — what must be true is that the
    // app refuses to render itself signed in on a credential the server rejects.
    await expect(page.getByTestId("user-menu")).toHaveCount(0);
  });
});
