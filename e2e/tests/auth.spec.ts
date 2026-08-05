import { test, expect } from "@playwright/test";
import { signInViaForm, suiteAuthFile } from "./helpers";

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

    // Should redirect to antilibrary after login transition completes (~4s animation)
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // Nav should show the user's display name instead of "Sign In"
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

    // Should stay on login page
    await expect(page).toHaveURL("/login");
  });

  test("a failed login preserves the typed email and password (US-16.2.1)", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', "wrong-password");
    await page.getByTestId("login-submit").click();

    // The error renders …
    const error = page.getByTestId("login-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText(
      "The door remains shut. Invalid credentials."
    );

    // … and both inputs RETAIN what the user typed (RemoteData Failure must not
    // clear the form — US-16.2.1 "form inputs never cleared on failure").
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

    // Protected pages redirect to the login form when unauthenticated
    await expect(page.locator('input[id="email"]')).toBeVisible();
  });

  test("upload page is accessible after signing in", async ({ page }) => {
    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();
    // waitForURL is more reliable than toHaveURL here — Nav.pushUrl is async
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // Add Book is a PERSISTENT primary action in the nav now (#318 TR-1) —
    // always visible, no Catalogue hover/disclosure to open. Click it (an
    // in-app nav link) to reach /upload while preserving Elm's in-memory auth
    // state; a full page.goto("/upload") would reload the SPA.
    await page.click('a.app-nav__add-book[href="/upload"]');
    await page.waitForURL("/upload");

    // Should show the upload area, not the auth-required prompt
    await expect(page.getByTestId('upload-auth-required')).not.toBeVisible();
    await expect(page.getByTestId('upload-drop-zone')).toBeVisible();
  });
});

test.describe("Owner-only admin navigation", () => {
  test("the platform owner sees the Admin disclosure (Sources/Scrapers)", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Admin is a disclosure BUTTON now (#318 TR-1), not a hover-revealed
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
  // The "auth" suite user is a plain role=user account.
  test.use({ storageState: suiteAuthFile("auth") });

  test("a non-owner user does not see the Admin dropdown", async ({ page }) => {
    await page.goto("/library");

    // Authenticated nav is present …
    await expect(page.getByTestId("user-menu")).toBeVisible();
    // … but there is no Admin entry point of any kind.
    await expect(page.locator('a[href="/admin/sources"]')).toHaveCount(0);
    await expect(page.locator('a[href="/admin/scrapers"]')).toHaveCount(0);
  });
});

test.describe("Logout", () => {
  test("signing out ends the session, reverts the nav, and kills the token server-side", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Capture the live token so we can prove it is revoked after logout.
    const token = await page.evaluate(
      () => JSON.parse(localStorage.getItem("stacks-auth") || "{}").token
    );
    expect(token).toBeTruthy();

    // Open the display-name menu and sign out.
    await page.getByTestId("user-menu").click();
    await page.getByRole("button", { name: "Sign Out" }).click();

    await page.waitForURL("**/login");

    // Nav reverts to the unauthenticated state.
    await expect(page.locator('a[href="/login"]')).toBeVisible();
    await expect(page.getByTestId("user-menu")).toHaveCount(0);

    // Local session cleared.
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();

    // A protected page bounces back to the login form.
    await page.goto("/upload");
    await expect(page.locator('input[id="email"]')).toBeVisible();

    // A2 revocation: the pre-logout token is dead server-side (guardian_db).
    const resp = await page.request.get("/api/placements/mine", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(resp.status()).toBe(401);
  });
});

test.describe("Unauthenticated access to protected pages (US-16.3.1)", () => {
  test("visiting /library unauthenticated renders the login form at the SAME url", async ({
    page,
  }) => {
    await page.goto("/library");

    // The client-side requiresAuth guard renders the login form in place …
    await expect(page.locator('input[id="email"]')).toBeVisible({
      timeout: 10000,
    });

    // … WITHOUT changing the URL to /login — the login form renders at the
    // protected URL (Reviewer Context: "URL bar does NOT change to /login").
    expect(page.url()).toMatch(/\/library$/);
    expect(page.url()).not.toMatch(/\/login$/);
  });

  // The guard covers every protected route, not just /upload — exercise two
  // more (a settings sub-route and a marketplace action route) to prove breadth.
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

      // URL stays at the protected route (login renders in place).
      expect(page.url()).toContain(route);
    });
  }
});

/**
 * Issue #359 — the credential must land regardless of the door animation.
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
 * Under the pre-#359 code both hang until timeout: the token is never written.
 */
test.describe("Login is not downstream of the door animation (#359)", () => {
  /** Poll localStorage until the auth token appears; return how long it took. */
  async function msUntilTokenStored(page, deadlineMs: number) {
    const start = Date.now();
    while (Date.now() - start < deadlineMs) {
      const token = await page.evaluate(() => {
        try {
          return JSON.parse(localStorage.getItem("stacks-auth") || "{}").token;
        } catch {
          return null;
        }
      });
      if (token) return { elapsed: Date.now() - start, token };
      await page.waitForTimeout(25);
    }
    return { elapsed: Date.now() - start, token: null };
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
    // Replace WAAPI with animations that start and never finish. `finished` is a
    // promise with no resolver, so anything waiting on it waits forever — the
    // occluded window's behaviour, made engine-independent. Installed before any
    // script runs so the very first login is covered.
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

    // Fail closed: prove the stall is real before asserting anything about it.
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

    const { elapsed, token } = await msUntilTokenStored(page, 1000);
    expect(
      token,
      "the 200 was discarded: no stacks-auth token within 1s (#359)"
    ).toBeTruthy();
    expect(elapsed).toBeLessThan(1000);

    // And the reader really is in — the session survives a reload, which is the
    // whole point of persisting it.
    await page.reload();
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 15000 });
  });

  test("every animation is stalled: the real engine is frozen and the 200 still lands", async ({
    page,
    context,
  }) => {
    // Freeze the browser's own animation timeline. Unlike the test above this
    // leaves `Element.animate` and `Animation.finished` entirely real — the door
    // animations are created and started, they simply never advance, so their
    // `finished` promises never settle. rAF keeps firing, so the port's callback
    // body still runs: the exact shape of the 2026-07-30 evidence.
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

    const { elapsed, token } = await msUntilTokenStored(page, 1000);
    expect(
      token,
      "the 200 was discarded while every animation was stalled (#359)"
    ).toBeTruthy();
    expect(elapsed).toBeLessThan(1000);

    // The reader lands on their shelves without the animation ever completing —
    // the ornament gates nothing.
    await page.waitForURL("**/antilibrary", { timeout: 15000 });
  });
});

/**
 * Issue #364 — the login door dolly-shot plays again, driven from the shell.
 *
 * #359 moved the credential off the animation frame by navigating away from the
 * login scene on the update that decoded the 200 — which unmounted the door
 * before the port's `requestAnimationFrame` callback could animate it. Measured
 * live 2026-07-31: `animationsStarted=0`. #364 renders the door scene layers
 * from the SHELL while `AuthState` is `Arriving`, over the destination page, so
 * the ids the port targets are on screen again — without moving the credential
 * back behind the animation.
 *
 * A literal occluded-window drive is NOT achievable under Playwright — #359
 * measured that across three launch modes x two page-open methods: the page
 * always reports `"visible"` and rAF keeps firing. So these reuse #359's
 * technique rather than rediscovering it: instrument WAAPI to count the door's
 * own animations, and for the counterfactual freeze the real timeline at the
 * browser level (CDP `Animation.setPlaybackRate: 0`), asserting the stall took
 * hold before asserting anything else.
 */
test.describe("The arrival door plays from the shell (#364)", () => {
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
   * FAILS rather than passes for the wrong reason (the #359 pattern).
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

    // The shell renders the door only once navigation has put `AuthState` in
    // `Arriving` over the destination page. Wait for that, then for the port's
    // rAF to create the animations.
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    const count = await doorAnimationCount(page, 4000);
    expect(
      count,
      "the door started zero animations — the dolly-shot is not playing over the arrival (#364)"
    ).toBeGreaterThan(0);
  });

  test("frozen door: the dolly-shot starts but never finishes, and the reader still lands authenticated", async ({
    page,
    context,
  }) => {
    await instrumentDoorAnimations(page);

    // Freeze the real animation timeline: the door animations are created and
    // started (so the count still climbs) but their `finished` promises never
    // settle — the occluded compositor's behaviour, reproduced at the engine.
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

    // Still navigated: the frozen door gated nothing.
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // The door DID start, shell-rendered over the destination — this is really
    // the frozen dolly-shot, not an empty scene that trivially "cannot gate".
    const count = await doorAnimationCount(page, 4000);
    expect(
      count,
      "the door never started, so this is not exercising the frozen dolly-shot (#364)"
    ).toBeGreaterThan(0);

    // ...and the reader is authenticated regardless: the session survives a
    // reload while the animation is still frozen mid-play.
    await page.reload();
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 15000 });
  });
});

test.describe("Session expiry", () => {
  test("an expired/revoked token redirects to login with a session-expired notice on the next authed action", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Simulate the access token having expired / been revoked server-side:
    // keep the stored session SHAPE (so the SPA still boots "authenticated")
    // but swap in a token the server will reject with 401 — exactly the state a
    // real expiry produces. We do NOT fabricate a session from nothing.
    await page.evaluate(() => {
      const raw = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      raw.token = `${raw.token}.expired`;
      localStorage.setItem("stacks-auth", JSON.stringify(raw));
    });

    // Take an authed action with the now-invalid token: loading a bookshelf
    // issues a Bearer request that comes back 401, which must route through the
    // single global session-expiry interceptor.
    await page.goto("/library");

    // Redirected to the login form …
    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    // … showing the DISTINCT session-expired notice (not invalid-credentials) …
    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");

    // … the invalid-credentials error is NOT what's shown here …
    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // … and the local session has been cleared.
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();
  });

  test("Session expiry redirects from a newly-covered page (Settings/Privacy) [#178]", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Load Settings/Privacy with a VALID token so the page actually renders. The
    // page itself fires no authed request on load, but the SPA's boot hook does
    // (Main.init → Api.getMyPlacements). Booting from an already-invalid token
    // would 401 there and bounce to /login BEFORE Privacy renders — that boot-hook
    // path is covered by the next test. Here we need the page rendered so the
    // redirect below is driven by an authed ACTION, not by page load.
    await page.goto("/settings/privacy");

    const saveProfileVisibility = page.getByRole("button", {
      name: "Save Profile Visibility",
    });
    await expect(saveProfileVisibility).toBeVisible({ timeout: 15000 });

    // Now revoke this session SERVER-SIDE (a real expiry: DELETE /api/auth/logout
    // → Guardian.revoke), leaving the SPA's in-memory token in place — so the NEXT
    // authed action is the first request the server rejects. A client-side token
    // swap can't reach the already-booted in-memory token without a reload, and a
    // reload would trip the boot hook above.
    await page.evaluate(async () => {
      const raw = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      await fetch("/api/auth/logout", {
        method: "DELETE",
        headers: { Authorization: `Bearer ${raw.token}` },
      });
    });

    // Take an authed action on this page: saving issues a Bearer request
    // (Api.updateProfileVisibility) that returns 401 with the now server-revoked
    // token, which must route through the single global session-expiry interceptor.
    await page.locator(".form-field__select").first().selectOption("platform");
    await saveProfileVisibility.click();

    // Redirected to the login form …
    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    // … showing the DISTINCT session-expired notice (not invalid-credentials) …
    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");

    // … the invalid-credentials error is NOT what's shown here …
    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // … and the local session has been cleared.
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();
  });

  test("Session expiry redirects at boot when the placement check 401s (boot hook) [#178]", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Same server-side-invalidation mechanism as the tests above: keep the stored
    // session SHAPE (so the SPA still boots "authenticated") but swap in a token
    // the server will reject with 401 — exactly the state a real expiry produces.
    await page.evaluate(() => {
      const raw = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      raw.token = `${raw.token}.expired`;
      localStorage.setItem("stacks-auth", JSON.stringify(raw));
    });

    // Fresh full navigation to Home (`/`). On any authed boot, Main.elm's `init`
    // unconditionally fires `Api.getMyPlacements auth.token GotPlacementCheck`
    // (Main.elm ~L208) — this is the BOOT hook wired in #178. Home is chosen
    // deliberately because its page init is `Cmd.none` (no page-level authed
    // request), so the ONLY Bearer request at boot is the placement check. That
    // makes the redirect unambiguously attributable to the boot hook rather than
    // to a page action or a page's own init request. The `GotPlacementCheck`
    // handler routes an unauthorized result to the central session-expiry path.
    await page.goto("/");

    // Redirected to the login form purely by the boot request — NO user click …
    await page.waitForURL("**/login", { timeout: 15000 });
    await expect(page.locator('input[id="email"]')).toBeVisible();

    // … showing the DISTINCT session-expired notice (not invalid-credentials) …
    const notice = page.getByTestId("session-expired-notice");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("closed your session");

    // … the invalid-credentials error is NOT what's shown here …
    await expect(page.getByTestId("login-error")).toHaveCount(0);

    // … and the local session has been cleared.
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();
  });
});
