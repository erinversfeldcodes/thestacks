/**
 * — Bookshelf navigation transitions (issue, punch).
 *
 * WHY THIS SPEC ASSERTS COMPUTED STYLE, NOT CLASS PRESENCE
 * -------------------------------------------------------
 * The bug this spec exists to prevent was a *silent no-op*: `fade-through-dark-in`
 * was applied to `main.app__main` on every navigation, but the CSS rule was empty
 * (`.fade-through-dark-in {}`), so the computed style was `animation-name: none;
 * animation-duration: 0s`. A test asserting only "the transition class is present"
 * passed against that broken feature for months — the live drive is what
 * finally caught it.
 *
 * So every assertion here reads `getComputedStyle`. A class name alone proves
 * nothing.
 *
 * HOW THE TRANSIENT CLASS IS CAPTURED
 * -----------------------------------
 * The class is deliberately short-lived: an `animationend` handler clears it so the
 * next navigation can re-trigger the animation. Sampling after the fact would race
 * that cleanup and flake. Instead a MutationObserver is installed *before* the
 * click and records every class value the element takes, together with the computed
 * animation values at that instant. Navigation is SPA `pushUrl`, so the observer
 * survives it.
 *
 * WHY WE WAIT FOR THE SAMPLE RATHER THAN READING IMMEDIATELY
 * ---------------------------------------------------------
 * Elm's `pushUrl` updates `location` synchronously inside `update`, but the DOM
 * class is applied on the *next* animation frame. So `expect(page).toHaveURL(...)`
 * resolves in the gap between the two, and reading the log at that moment finds
 * the navigation not yet rendered. Every read therefore waits for a transition
 * sample to be observed first. This is a wait, not a weakened assertion: if the
 * feature stops applying a class the wait times out and the test fails.
 *
 * AND WHY "WAIT FOR CLEARED" IS NEVER ENOUGH ON ITS OWN
 * ----------------------------------------------------
 * The same render gap makes `waitForTransitionCleared` trivially satisfiable:
 * straight after a click the class has not been applied *yet*, so "no transition
 * class is present" is already true and the wait returns instantly, having
 * observed nothing. Chaining click → wait-for-cleared → click therefore lets
 * navigations pile up inside one frame; the class gets swapped mid-flight
 * instead of removed and re-added, and the recorded sequence varies run to run.
 * That is precisely what made this spec non-deterministic against a deployed
 * preview while passing locally (issue).
 *
 * So every wait-for-cleared must be preceded by a wait for the class to have
 * been *applied* (`recordedTransitions`). Applied-then-cleared is the invariant;
 * cleared alone is vacuous.
 */

import { test, expect, type Page } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

const MAIN = "main#main-content";

/** One recorded state of `main.app__main`, sampled as the class changed. */
type Sample = {
  className: string;
  animationName: string;
  animationDuration: string;
};

const TRANSITION_CLASSES = [
  "slide-in-left",
  "slide-in-right",
  "fade-through-dark-in",
];

function transitionClassOf(className: string): string | undefined {
  return TRANSITION_CLASSES.find((c) => className.split(/\s+/).includes(c));
}

/** Parse a CSS duration ("0.3s", "400ms") into milliseconds. */
function durationToMs(value: string): number {
  const trimmed = value.trim();
  if (trimmed.endsWith("ms")) return parseFloat(trimmed);
  if (trimmed.endsWith("s")) return parseFloat(trimmed) * 1000;
  return NaN;
}

/**
 * Start recording class changes on `main.app__main`. Records the current state
 * first, so a navigation that happens immediately is not missed.
 */
async function startRecording(page: Page): Promise<void> {
  await page.evaluate((selector) => {
    const el = document.querySelector(selector);
    if (!el) throw new Error(`${selector} not found`);

    const sample = () => {
      const style = getComputedStyle(el);
      return {
        className: el.className,
        animationName: style.animationName,
        animationDuration: style.animationDuration,
      };
    };

    const w = window as unknown as { __transitionLog: unknown[] };
    w.__transitionLog = [sample()];

    const observer = new MutationObserver(() => {
      w.__transitionLog.push(sample());
    });
    observer.observe(el, { attributes: true, attributeFilter: ["class"] });
  }, MAIN);
}

async function readRecording(page: Page): Promise<Sample[]> {
  return page.evaluate(
    () => (window as unknown as { __transitionLog: Sample[] }).__transitionLog,
  );
}

/** The samples in which a navigation transition class was applied. */
function transitionSamples(samples: Sample[]): Sample[] {
  return samples.filter((s) => transitionClassOf(s.className) !== undefined);
}

/**
 * Block until the recording has captured at least `count` samples carrying a
 * transition class, then return the recording.
 *
 * Times out (and fails the test) if the class is never applied — so this closes
 * the render race without softening what is being proven.
 */
async function recordedTransitions(
  page: Page,
  count = 1,
): Promise<Sample[]> {
  await page.waitForFunction(
    ({ classes, want }) => {
      const log = (window as unknown as { __transitionLog?: Sample[] })
        .__transitionLog;
      if (!log) return false;
      const hits = log.filter((s) =>
        classes.some((c) => s.className.split(/\s+/).includes(c)),
      );
      return hits.length >= want;
    },
    { classes: TRANSITION_CLASSES, want: count },
    { timeout: 5000 },
  );
  return transitionSamples(await readRecording(page));
}

/**
 * Wait until no transition class is applied. Required before starting a second
 * recording: the class is transient, and a recording begun while the previous
 * animation is still running would capture the *stale* class as its first
 * sample.
 *
 * Only valid under normal motion — under `prefers-reduced-motion` no
 * `animationend` fires, so the class is never cleared.
 *
 * MUST be called only after `recordedTransitions` has confirmed the class was
 * applied. Called straight after a click it returns immediately without
 * observing anything — see the header comment.
 */
async function waitForTransitionCleared(page: Page): Promise<void> {
  await page.waitForFunction(
    (selector) => {
      const el = document.querySelector(selector);
      return el ? !/slide-in-|fade-through-dark/.test(el.className) : false;
    },
    MAIN,
    { timeout: 5000 },
  );
}

async function gotoShelf(page: Page, path: string): Promise<void> {
  await page.goto(path);
  await page.waitForSelector(".app-nav__link", { timeout: 10000 });
}

async function clickShelf(page: Page, href: string): Promise<void> {
  // Wave 8 moved the five shelf links INSIDE a "Bookshelves"
  // disclosure — a real <button aria-haspopup> whose menu is absent from the
  // DOM until it is clicked open. So the navigation step is now: open the
  // disclosure, then click the shelf link. Opening the disclosure only toggles
  // `openNavMenu`; it does NOT touch `main`'s class, so it adds no spurious
  // sample to the transition recording started before this call. A navigation
  // does not reset `openNavMenu`, so on a repeat call the menu may already be
  // open — open only when it is closed.
  const trigger = page.locator(
    'button.app-nav__disclosure:has-text("Bookshelves")'
  );
  await expect(trigger).toBeVisible({ timeout: 5000 });
  if ((await trigger.getAttribute("aria-expanded")) !== "true") {
    await trigger.click();
  }

  const link = page.locator(`a.app-nav__dropdown-link[href="${href}"]`);
  await expect(link).toBeVisible({ timeout: 5000 });
  await link.click();
  await expect(page).toHaveURL((url) => url.pathname === href);
}

test.describe("— bookshelf navigation transitions", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  test("adjacent shelf, moving forwards, slides in from the right and actually animates", async ({
    page,
  }) => {
    await gotoShelf(page, "/library");
    await startRecording(page);
    await clickShelf(page, "/antilibrary");

    const applied = await recordedTransitions(page);
    expect(applied.length).toBeGreaterThan(0);

    const sample = applied[0];
    expect(transitionClassOf(sample.className)).toBe("slide-in-right");

    expect(sample.animationName).toBe("slide-in-right");
    expect(sample.animationName).not.toBe("none");
    expect(durationToMs(sample.animationDuration)).toBeGreaterThanOrEqual(300);
    expect(durationToMs(sample.animationDuration)).toBeLessThanOrEqual(500);
  });

  test("adjacent shelf, moving backwards, slides in from the left", async ({
    page,
  }) => {
    await gotoShelf(page, "/wishlist");
    await startRecording(page);
    await clickShelf(page, "/library");

    const applied = await recordedTransitions(page);
    expect(applied.length).toBeGreaterThan(0);

    const sample = applied[0];
    expect(transitionClassOf(sample.className)).toBe("slide-in-left");
    expect(sample.animationName).toBe("slide-in-left");
    expect(durationToMs(sample.animationDuration)).toBeGreaterThanOrEqual(300);
    expect(durationToMs(sample.animationDuration)).toBeLessThanOrEqual(500);
  });

  test("the slide is directional — forwards and backwards differ", async ({
    page,
  }) => {
    await gotoShelf(page, "/library");
    await startRecording(page);
    await clickShelf(page, "/wishlist");
    const forwards = (await recordedTransitions(page))[0];

    await waitForTransitionCleared(page);
    await startRecording(page);
    await clickShelf(page, "/library");
    const backwards = (await recordedTransitions(page))[0];

    expect(forwards.animationName).toBe("slide-in-right");
    expect(backwards.animationName).toBe("slide-in-left");
    expect(forwards.animationName).not.toBe(backwards.animationName);
  });

  test("room navigation fades through darkness and actually animates", async ({
    page,
  }) => {
    await gotoShelf(page, "/library");
    await startRecording(page);
    await clickShelf(page, "/reading-pile");

    const applied = await recordedTransitions(page);
    expect(applied.length).toBeGreaterThan(0);

    const sample = applied[0];
    expect(transitionClassOf(sample.className)).toBe("fade-through-dark-in");
    expect(sample.animationName).toBe("fade-through-dark-in");
    expect(sample.animationName).not.toBe("none");
    expect(durationToMs(sample.animationDuration)).toBeGreaterThanOrEqual(300);
    expect(durationToMs(sample.animationDuration)).toBeLessThanOrEqual(500);
  });

  test("an adjacent move and a room move are distinguishable", async ({
    page,
  }) => {
    await gotoShelf(page, "/library");
    await startRecording(page);
    await clickShelf(page, "/antilibrary");
    const adjacent = (await recordedTransitions(page))[0];

    await waitForTransitionCleared(page);
    await startRecording(page);
    await clickShelf(page, "/reading-pile");
    const room = (await recordedTransitions(page))[0];

    expect(adjacent.animationName).toBe("slide-in-right");
    expect(room.animationName).toBe("fade-through-dark-in");
    expect(adjacent.animationName).not.toBe(room.animationName);
  });

  test("the class is cleared after the animation, so repeat navigation re-triggers it", async ({
    page,
  }) => {
    await gotoShelf(page, "/library");
    await startRecording(page);

    await clickShelf(page, "/antilibrary");
    await recordedTransitions(page, 1);
    await waitForTransitionCleared(page);
    await clickShelf(page, "/library");
    await recordedTransitions(page, 2);
    await waitForTransitionCleared(page);
    await clickShelf(page, "/antilibrary");
    await recordedTransitions(page, 3);
    await waitForTransitionCleared(page);

    const samples = await readRecording(page);
    const sequence = samples.map((s) => transitionClassOf(s.className));

    expect(transitionSamples(samples)).toHaveLength(3);

    const firstRight = sequence.indexOf("slide-in-right");
    expect(firstRight).toBeGreaterThanOrEqual(0);

    const clearedAfter = sequence.indexOf(undefined, firstRight + 1);
    expect(clearedAfter).toBeGreaterThan(firstRight);

    const secondRight = sequence.indexOf("slide-in-right", clearedAfter + 1);
    expect(secondRight).toBeGreaterThan(clearedAfter);

    expect(transitionClassOf(samples[samples.length - 1].className)).toBe(
      undefined,
    );
  });

  test("the navigation bar does not shift during a transition", async ({
    page,
  }) => {
    const headerBox = () =>
      page.evaluate(() => {
        const el = document.querySelector(".app-header");
        if (!el) throw new Error(".app-header not found");
        const r = el.getBoundingClientRect();
        return { top: r.top, left: r.left, width: r.width, height: r.height };
      });

    await gotoShelf(page, "/library");
    const before = await headerBox();

    await clickShelf(page, "/antilibrary");
    await page.waitForTimeout(150);
    const during = await headerBox();

    await page.waitForTimeout(500);
    const after = await headerBox();

    expect(during).toEqual(before);
    expect(after).toEqual(before);
  });
});

test.describe("— transitions honour prefers-reduced-motion", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  /**
   * Emulate reduced motion and *prove the emulation took*.
   *
   * `test.use({ reducedMotion: "reduce" })` is silently dropped in this setup —
   * it never reaches `contextOptions`, so the page kept matching
   * `(prefers-reduced-motion: no-preference)` and these tests failed against a
   * stylesheet that is in fact correct. `page.emulateMedia` does apply.
   *
   * The `matchMedia` assertion below is the guard: without it, a future
   * regression in the emulation would make these tests fail confusingly (as it
   * just did) or — worse, if the polarity ever flipped — pass vacuously. Same
   * class of trap as the empty `.fade-through-dark-in {}` rule this spec exists
   * to catch.
   */
  async function emulateReducedMotion(page: Page): Promise<void> {
    await page.emulateMedia({ reducedMotion: "reduce" });
    const matches = await page.evaluate(
      () => window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    );
    expect(
      matches,
      "reduced-motion emulation did not reach the page; the suppression assertions below would be meaningless",
    ).toBe(true);
  }

  test("the slide animation is suppressed", async ({ page }) => {
    await gotoShelf(page, "/library");
    await emulateReducedMotion(page);
    await startRecording(page);
    await clickShelf(page, "/antilibrary");

    const applied = await recordedTransitions(page);
    expect(applied.length).toBeGreaterThan(0);

    expect(transitionClassOf(applied[0].className)).toBe("slide-in-right");
    expect(applied[0].animationName).toBe("none");
  });

  test("the fade animation is suppressed", async ({ page }) => {
    await gotoShelf(page, "/library");
    await emulateReducedMotion(page);
    await startRecording(page);
    await clickShelf(page, "/reading-pile");

    const applied = await recordedTransitions(page);
    expect(applied.length).toBeGreaterThan(0);

    expect(transitionClassOf(applied[0].className)).toBe("fade-through-dark-in");
    expect(applied[0].animationName).toBe("none");
  });
});
