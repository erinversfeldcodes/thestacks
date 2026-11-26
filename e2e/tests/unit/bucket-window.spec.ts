// `test`/`expect` come from the suite's own fixtures rather than
// `@playwright/test` so a case added here later gets the proof-carrying
// `request` like every other spec. The fixtures are lazy, so nothing in this
// file touches a stack.
import { test, expect } from "../fixtures";
import { BUCKET_WINDOW_MS, windowProfile } from "../bucket-window";

/**
 * `windowProfile` offline, against the limiter's semantics.
 *
 * ⛔ WHAT THESE CASES ARE FOR. `rate-limit.spec.ts` asks the `:auth` bucket a
 * question and then has to decide whether it ever managed to ask it — and that
 * decision is this function. It got one wrong answer, which was reported as a
 * security finding: a serial flood delivered 3.0 arrivals per second against a
 * ceiling of 200 per 60s window, the window expired entries faster than the
 * flood could add them, and the spec said brute-force protection was absent.
 * The last two cases below are that arithmetic, held still.
 *
 * ⚖️ Offline rather than against a stack, deliberately. These are claims about
 * a calculation, and a test that needs a deployed preview to check a
 * calculation can only run where the calculation is hardest to vary.
 */
test.describe("the auth bucket's window profile", () => {
  const SECONDS = BUCKET_WINDOW_MS / 1000;

  /** `n` arrivals from `startMs`, one every `intervalMs`. */
  function arrivals(n: number, startMs: number, intervalMs: number): number[] {
    return Array.from({ length: n }, (_, i) => startMs + i * intervalMs);
  }

  test("no arrivals profile as nothing, not as a division", () => {
    // The flood that was refused on its very first request counts no arrivals,
    // and the reachability message prints every field of this result.
    expect(windowProfile([])).toEqual({
      peak: 0,
      spanSeconds: 0,
      ratePerSecond: 0,
    });
  });

  test("one arrival has no span, so it is given no rate", () => {
    expect(windowProfile([1_000_000])).toEqual({
      peak: 1,
      spanSeconds: 0,
      ratePerSecond: 0,
    });
  });

  test("arrivals inside one window all count toward the peak", () => {
    const profile = windowProfile(arrivals(10, 1_000_000, 500));

    expect(profile.peak).toBe(10);
    expect(profile.spanSeconds).toBe(4.5);
    expect(profile.ratePerSecond).toBeCloseTo(10 / 4.5, 6);
  });

  // ⛔ THE BOUNDARY IS THE LIMITER'S, NOT A CHOICE MADE HERE.
  // `rate_limiter.ex` keeps `ts > now_ms - @window_ms`, so an entry exactly one
  // window old is already gone. These two cases pin that decision from the
  // outside: get them wrong by one millisecond's worth of semantics and the
  // flood's reachability verdict is off by one arrival at every ceiling.
  test("two arrivals exactly one window apart are never counted together", () => {
    const profile = windowProfile([1_000_000, 1_000_000 + BUCKET_WINDOW_MS]);

    expect(profile.peak).toBe(1);
    expect(profile.spanSeconds).toBe(SECONDS);
  });

  test("one millisecond inside the window, they always are", () => {
    const profile = windowProfile([
      1_000_000,
      1_000_000 + BUCKET_WINDOW_MS - 1,
    ]);

    expect(profile.peak).toBe(2);
  });

  test("completion times out of order profile the same as sorted ones", () => {
    // Not hypothetical: the flood runs eight requests in flight and pushes each
    // arrival as its own reply lands, so the array it hands over is only
    // roughly ordered.
    const ordered = arrivals(10, 1_000_000, 500);

    expect(windowProfile([...ordered].reverse())).toEqual(
      windowProfile(ordered),
    );
  });

  test("the peak is the densest window, not the most recent one", () => {
    // 50 arrivals in five seconds, then a trickle every 20s for five minutes.
    // The limiter would have answered during the burst; a profile that reported
    // the trailing window would say the ceiling was never approached.
    const profile = windowProfile([
      ...arrivals(50, 1_000_000, 100),
      ...arrivals(10, 1_100_000, 20_000),
    ]);

    expect(profile.peak).toBe(50);
    expect(profile.spanSeconds).toBe(280);
  });

  // ⛔ THE MEASURED FAILURE, AS ARITHMETIC. A ceiling of 200 per 60s window
  // needs a sustained 3.34 arrivals/s before 200 of them are ever inside one
  // window at once. The serial flood achieved 3.0, so it topped out at 180 and
  // reported the bucket as not limiting — a verdict about the probe wearing the
  // words of a verdict about the stack.
  test("a flood below the ceiling's own rate never reaches the ceiling", () => {
    const ceiling = 200;
    const rateTheCeilingNeeds = ceiling / SECONDS;

    // 200 arrivals, one every 334ms — the rate measured against a preview.
    const profile = windowProfile(arrivals(ceiling, 1_000_000, 334));

    expect(profile.ratePerSecond).toBeLessThan(rateTheCeilingNeeds);
    expect(
      profile.peak,
      "below the rate the ceiling demands, no flood LENGTH reaches it — which " +
        "is why the spec asserts reachability before it reports a verdict",
    ).toBeLessThan(ceiling);
    expect(profile.peak).toBe(180);
  });

  test("and at a rate above it, the same attempt count does", () => {
    const ceiling = 200;
    const rateTheCeilingNeeds = ceiling / SECONDS;

    // The same 200 attempts, one every 294ms.
    const profile = windowProfile(arrivals(ceiling, 1_000_000, 294));

    expect(profile.ratePerSecond).toBeGreaterThan(rateTheCeilingNeeds);
    expect(profile.peak).toBe(ceiling);
  });
});
