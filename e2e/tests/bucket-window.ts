/**
 * The `:auth` bucket's sliding window, and what a flood achieved inside it.
 *
 * ⚖️ A MODULE SO THE ARITHMETIC CAN BE TESTED, and the reason is the shape of
 * `rate-limit.spec.ts` rather than tidiness. Everything else in that spec
 * issues a request and reports a status; this is the only part that can be
 * wrong on its own terms — and BOTH of the spec's assertions read its answer,
 * the first to decide whether the flood ever asked the bucket its question and
 * the second to report the bucket's verdict. While it lived inside the spec the
 * only way to exercise it was to deploy a stack and flood it, so the one piece
 * of logic that could be checked offline was the one piece that never was.
 */

// The limiter's window. ⚠️ This must equal `@window_ms` in
// `StacksWeb.Plugs.RateLimiter`; `test/platform/e2e_auth_ceiling_handoff_test.sh`
// relates the two so the arithmetic here cannot drift away from the limiter it
// reasons about. A bucket of N per window can only answer once N requests land
// inside ONE window — which is the fact the flood is built around.
export const BUCKET_WINDOW_MS = 60_000;

export type WindowProfile = {
  /** The most arrivals that sat inside any single window. */
  peak: number;
  /** First arrival to last, in seconds. 0 for fewer than two arrivals. */
  spanSeconds: number;
  /** Arrivals per second across that span. 0 when the span is 0. */
  ratePerSecond: number;
};

/**
 * The most attempts that sat inside any single window — the number the limiter
 * actually compares against its ceiling — plus the rate that produced it.
 *
 * ⚠️ THE WINDOW IS HALF-OPEN, and that is the limiter's choice rather than one
 * made here. `rate_limiter.ex` keeps `ts > now_ms - @window_ms`, so an entry
 * exactly one window old has already been dropped; the eviction below is
 * `>= BUCKET_WINDOW_MS` to match. Two arrivals 60_000ms apart are never counted
 * together, and at 59_999ms they always are.
 *
 * ⚠️ PEAK IS A MAXIMUM OVER EVERY WINDOW, not the count in the last one. A
 * flood that bursts and then slows has its answer in the burst, and the limiter
 * would have answered there too.
 *
 * ⚖️ Takes arrival times rather than a bucket state because that is all a
 * client can observe: the ETS table belongs to another process, and when the
 * flood's own numbers say the ceiling was never reached, the bucket's silence
 * is a fact about the probe.
 */
export function windowProfile(countedAt: number[]): WindowProfile {
  const times = [...countedAt].sort((a, b) => a - b);
  let peak = 0;
  let start = 0;

  for (let end = 0; end < times.length; end++) {
    while (times[end] - times[start] >= BUCKET_WINDOW_MS) start++;
    peak = Math.max(peak, end - start + 1);
  }

  const spanSeconds =
    times.length > 1 ? (times[times.length - 1] - times[0]) / 1000 : 0;

  return {
    peak,
    spanSeconds,
    ratePerSecond: spanSeconds > 0 ? times.length / spanSeconds : 0,
  };
}
