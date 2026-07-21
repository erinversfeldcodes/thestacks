/**
 * US-1.2.5 — Bookshelf navigation transitions (issue #277, #112 punch #21).
 *
 * WHY THIS SPEC ASSERTS COMPUTED STYLE, NOT CLASS PRESENCE
 * -------------------------------------------------------
 * The bug this spec exists to prevent was a *silent no-op*: `fade-through-dark-in`
 * was applied to `main.app__main` on every navigation, but the CSS rule was empty
 * (`.fade-through-dark-in {}`), so the computed style was `animation-name: none;
 * animation-duration: 0s`. A test asserting only "the transition class is present"
 * passed against that broken feature for months — the #270 live drive is what
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
  const link = page.locator(`a.app-nav__link[href="${href}"]`);
  await expect(link).toBeVisible({ timeout: 5000 });
  await link.click();
  // Exact pathname match via a predicate rather than `new RegExp(href)`:
  // building a regex from a variable trips semgrep's non-literal-regexp rule
  // (ReDoS), which is blocking in `just ci`. The predicate is also a stricter
  // assertion than the old unanchored substring regex.
  await expect(page).toHaveURL((url) => url.pathname === href);
}

test.describe("US-1.2.5 — bookshelf navigation transitions", () => {
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

    // The assertion that would have caught the original defect: the class must
    // resolve to a real animation, not `none` / `0s`.
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
    // The #270 finding: both yielded `fade-through-dark-in`, so the two kinds of
    // navigation were indistinguishable on the DOM.
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
    // Defect 3: without clearing, the class string persists and a later
    // navigation selecting the same class never restarts the animation.
    await gotoShelf(page, "/library");
    await startRecording(page);

    // Let each animation finish before the next navigation, so the recording
    // shows the class being genuinely removed and re-added rather than merely
    // swapped mid-flight.
    await clickShelf(page, "/antilibrary");
    await waitForTransitionCleared(page);
    await clickShelf(page, "/library");
    await waitForTransitionCleared(page);
    await clickShelf(page, "/antilibrary");
    await waitForTransitionCleared(page);

    const samples = await readRecording(page);
    const sequence = samples.map((s) => transitionClassOf(s.className));

    // slide-in-right must be applied twice, with the class absent in between —
    // that gap is what lets the browser restart the animation.
    const firstRight = sequence.indexOf("slide-in-right");
    expect(firstRight).toBeGreaterThanOrEqual(0);

    const clearedAfter = sequence.indexOf(undefined, firstRight + 1);
    expect(clearedAfter).toBeGreaterThan(firstRight);

    const secondRight = sequence.indexOf("slide-in-right", clearedAfter + 1);
    expect(secondRight).toBeGreaterThan(clearedAfter);

    // And the final state is clean, not a stuck transition class.
    expect(transitionClassOf(samples[samples.length - 1].className)).toBe(
      undefined,
    );
  });

  test("the navigation bar does not shift during a transition", async ({
    page,
  }) => {
    // `.app-header` is `position: relative` by design (main.css:172), so this
    // asserts geometric stability, NOT `position: fixed`.
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
    // Sample mid-animation (the slide runs 300ms).
    await page.waitForTimeout(150);
    const during = await headerBox();

    await page.waitForTimeout(500);
    const after = await headerBox();

    expect(during).toEqual(before);
    expect(after).toEqual(before);
  });
});

test.describe("US-1.2.5 — transitions honour prefers-reduced-motion", () => {
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

    // The class is still applied — it is suppressed in CSS, not in Elm.
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
