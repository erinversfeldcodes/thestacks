import { test, expect, APIRequestContext } from "./fixtures";

const WRONG_PASSWORD = "wrong-password-xyz";

// The :auth bucket size the TARGET stack runs, not a constant of this spec.
// Prod parity is 60/min, but a preview deliberately runs a higher ceiling so
// the suite's own opening burst of real form logins (two workers ripping
// through register/login specs) cannot eat the budget out from under the
// specs behind it — which once 429'd every owner sign-in for a 90-second
// window and failed three runs straight. The deploy hands the value it set
// over as E2E_AUTH_RATE_LIMIT so this flood always overshoots the real
// ceiling; a hardcoded 65 against a raised ceiling proves nothing.
//
// ⛔ THERE IS NO DEFAULT, AND ITS ABSENCE IS THE POINT. This read was
// `Number(process.env.E2E_AUTH_RATE_LIMIT || 60)`, and the handoff meant to
// supply it wrote to `$GITHUB_ENV` — a channel that exists only inside a
// GitHub Actions job. Under the gate that deploys this same stack and runs
// this same suite from a shell, nothing arrived: the flood was sized at 70
// against a ceiling of 200, no 429 was reachable at any point in the loop,
// and this test failed with the message below. Brute-force protection was
// reported absent because a variable was unset.
//
// ⚖️ The default is what let a harness fault wear a security verdict, and a
// believable wrong answer is worse than a refusal. So the spec refuses to
// guess, and names the channel that should have told it.
const DECLARED_AUTH_CEILING = process.env.E2E_AUTH_RATE_LIMIT;

function floodEmail(i: number): string {
  return `flood-${i}-${Date.now()}@ratelimit.test`;
}

async function attemptLogin(
  request: APIRequestContext,
  email: string,
  extraHeaders: Record<string, string> = {},
): Promise<number> {
  const resp = await request.post("/api/auth/login", {
    data: { email, password: WRONG_PASSWORD },
    headers: extraHeaders,
    failOnStatusCode: false,
  });
  return resp.status();
}

// The limiter's window. ⚠️ This must equal `@window_ms` in
// `StacksWeb.Plugs.RateLimiter`; `test/platform/e2e_auth_ceiling_handoff_test.sh`
// relates the two so the arithmetic below cannot drift away from the limiter it
// reasons about. A bucket of N per window can only answer once N requests land
// inside ONE window — which is the fact the flood below is built around.
const BUCKET_WINDOW_MS = 60_000;

// ⛔ CONCURRENT, AND THE SEQUENTIAL VERSION WAS ARITHMETICALLY UNABLE TO PROVE
// ANYTHING. `Accounts.check_password(nil, _)` runs a full Argon2 hash for an
// unknown email — deliberately, it is the timing-leak defence — and every hash
// goes through `Stacks.Accounts.ArgonPool`, whose pool_size is 2. So login
// throughput is bounded SERVER-side at 2/hash, and a client that awaits each
// reply in turn leaves at least one of those two workers idle the whole time:
// measured 3.0 req/s against a preview, 210 attempts in 70s. A ceiling of 200
// per 60s window needs a sustained 3.34 req/s, so the sliding window expired
// entries faster than a serial flood could add them and NO flood length would
// have tripped it. This spec reported "brute-force protection absent" about a
// bucket it could not reach.
//
// ⚖️ Concurrency rather than a lower ceiling, because it removes the dependency
// on per-request latency instead of re-tuning against it: queued requests keep
// both pool workers busy, taking throughput to 2/hash — at least double the
// serial rate for any non-zero round trip. And it cannot raise peak hashing
// memory, which is the thing a 512 MB preview has to care about: ArgonPool
// bounds that to 2 x 32 MiB however many requests are in flight. The pool is
// the memory guard, so the client is free to queue behind it.
const FLOOD_CONCURRENCY = 8;

type FloodResult = {
  sawRateLimit: boolean;
  attempts: number;
  lockouts: number;
  /** When each attempt the limiter ALLOWED completed. */
  countedAt: number[];
  lastRequestAt: number;
};

/**
 * Deliver up to `max` failed logins, `FLOOD_CONCURRENCY` in flight, stopping at
 * the first 429.
 *
 * ⚖️ Returns what it MEASURED, not a verdict. The two failures this spec can
 * see are different findings — a bucket that does not limit, and a probe that
 * never reached the bucket's ceiling — and telling them apart needs the arrival
 * times, so they are kept rather than reduced to a boolean.
 */
async function flood(
  request: APIRequestContext,
  max: number,
): Promise<FloodResult> {
  const result: FloodResult = {
    sawRateLimit: false,
    attempts: 0,
    lockouts: 0,
    countedAt: [],
    lastRequestAt: Date.now(),
  };
  let issued = 0;

  async function worker(): Promise<void> {
    while (!result.sawRateLimit && issued < max) {
      const mine = issued++;
      const status = await attemptLogin(request, floodEmail(mine));
      result.attempts++;
      result.lastRequestAt = Date.now();

      if (status === 423) {
        result.lockouts++;
      } else if (status === 429) {
        result.sawRateLimit = true;
      } else {
        // ⚠️ Only an ALLOWED request is in the bucket. `rate_limited?` returns
        // before its insert when the ceiling is already met, so a 429 is never
        // recorded — counting them here would overstate the window's depth and
        // turn an unreachable ceiling back into a security verdict.
        result.countedAt.push(Date.now());
      }
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(FLOOD_CONCURRENCY, max) }, () => worker()),
  );

  return result;
}

/**
 * The most attempts that sat inside any single window — the number the limiter
 * actually compares against its ceiling — plus the rate that produced it.
 */
function windowProfile(countedAt: number[]): {
  peak: number;
  spanSeconds: number;
  ratePerSecond: number;
} {
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

/**
 * Is the `:auth` limiter expected to be ON for the target under test?
 *
 * ⚠️ **This must be decided from the ENVIRONMENT, never from the observation.**
 * Until the spec ended its flood loop with
 * `test.skip(!sawRateLimit, "…rate limiting appears disabled")` — it skipped
 * *precisely when the limiter failed to fire*, which is the one outcome it
 * exists to catch. A regression that silently disabled the `:auth` bucket on the
 * preview would have turned this, the only E2E proof of that bucket, green-by-
 * skipping. Same fail-open shape as `assertSeedOrSkip` (`helpers.ts`) was
 * written to close for seed data.
 *
 * The rule, in precedence order:
 *   1. `E2E_EXPECT_RATE_LIMITING` — explicit operator intent, either direction
 *      (`1` = enforce, anything else = this stack legitimately runs unlimited).
 *   2. Otherwise: a REMOTE `BASE_URL` ⇒ a deployed (Fly preview / staging)
 *      stack, where `rate_limiting_enabled` is true and the 429 is a hard
 *      requirement. Unset or loopback ⇒ local Phoenix, where `config/test.exs`
 *      sets `config :core, :rate_limiting_enabled, false`, so the behaviour
 *      genuinely does not exist and skipping is honest.
 *
 * Loopback is excluded explicitly rather than treating any `BASE_URL` as
 * deployed: `scripts/test-e2e.sh` runs every Playwright project, so a developer
 * pointing it at their own `http://localhost:4000` would otherwise get a hard
 * failure for a limiter their config deliberately disables.
 */
function rateLimitingExpected(): boolean {
  const explicit = process.env.E2E_EXPECT_RATE_LIMITING;
  if (explicit !== undefined && explicit !== "") {
    return explicit === "1";
  }

  const baseUrl = process.env.BASE_URL;
  if (!baseUrl) return false;

  return !/^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:|\/|$)/i.test(baseUrl);
}

test.describe("auth rate limiting (live Fly stack)", () => {
  test.skip(
    !rateLimitingExpected(),
    "Rate limiting is not expected on this target (no BASE_URL ⇒ local Phoenix, " +
      "where config/test.exs disables it). Set E2E_EXPECT_RATE_LIMITING=1 to " +
      "enforce the :auth bucket guarantee against this stack.",
  );

  // When this spec last touched the `:auth` bucket, so the drain below knows
  // how much of the window is left to run. 0 ⇒ the flood never started.
  let floodLastRequestAt = 0;

  // ⛔ THE FLOOD MUST NOT OUTLIVE THIS SPEC, and the run that found this is why.
  // The bucket records every allowed attempt for a full window, so when this
  // spec ends the runner IP's `:auth` budget is spent — and the gate's next
  // stage logs in: `check-e2e-repeatability.sh` runs two complete Playwright
  // setups, each a round of real form logins. A 429 there reads as a broken
  // stack rather than as this spec's residue. Measured: a flood that did not
  // even trip left ~180 entries in the window, the stage's run A crept the
  // count to just under the ceiling, and run B tipped it over — run B executed
  // ZERO tests and the gate reported a repeatability failure.
  //
  // ⚠️ Runs after a FAILING run too, deliberately. The residue is the same
  // either way, and a spec that only poisons the stage behind it when it fails
  // is harder to diagnose than one that always does.
  test.afterEach(async ({ request }) => {
    if (floodLastRequestAt === 0) return;

    const remainingMs =
      BUCKET_WINDOW_MS + 2_000 - (Date.now() - floodLastRequestAt);
    if (remainingMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, remainingMs));
    }

    // ⚖️ Verified, not assumed. Waiting out the window is arithmetic about
    // another process's ETS table, and if a login still 429s here the drain did
    // not work — which the next stage would otherwise discover as its own
    // unexplained failure, one stage further from the cause.
    const afterDrain = await attemptLogin(request, floodEmail(9999));
    expect(
      afterDrain,
      `the :auth bucket had not drained ${BUCKET_WINDOW_MS / 1000}s after this ` +
        `spec's last request, so the stage behind it inherits a spent budget and ` +
        `its logins will 429 for reasons that look nothing like this spec. ` +
        `Expected any status but 429, got ${afterDrain}.`,
    ).not.toBe(429);
  });

  test("brute-force login trips 429 and rotating X-Forwarded-For cannot bypass it", async ({
    request,
  }) => {
    expect(
      DECLARED_AUTH_CEILING,
      "E2E_AUTH_RATE_LIMIT is unset: the deploy's :auth ceiling never reached " +
        "this suite, so any flood length here is a guess — and a guess that " +
        "falls short of the real ceiling reports brute-force protection " +
        "absent when the only thing absent is this value. The preview deploy " +
        "writes it through scripts/lib/e2e-handoff.sh and scripts/ci.sh loads " +
        "it; set it by hand when aiming this spec at a stack deployed another " +
        "way.",
    ).toBeTruthy();

    const authBucketLimit = Number(DECLARED_AUTH_CEILING);
    const maxFloodAttempts = authBucketLimit + 10;

    const flooded = await flood(request, maxFloodAttempts);
    floodLastRequestAt = flooded.lastRequestAt;
    const { peak, spanSeconds, ratePerSecond } = windowProfile(
      flooded.countedAt,
    );
    const windowSeconds = BUCKET_WINDOW_MS / 1000;

    expect(
      flooded.lockouts,
      "unique-email flood should never hit the per-account lockout (423)",
    ).toBe(0);

    // ⛔ REACHABILITY FIRST, AND THE ORDER IS THE WHOLE POINT. A flood that
    // never put the ceiling's worth of attempts inside one window never asked
    // the bucket the question, so its silence says nothing about brute-force
    // protection. Asserted before the verdict below so the honest message wins
    // whenever both would fire.
    expect(
      flooded.sawRateLimit || peak >= authBucketLimit,
      `this probe never reached the ceiling, so the :auth bucket was never asked ` +
        `to answer. ${flooded.attempts} attempt(s) over ${spanSeconds.toFixed(1)}s ` +
        `(${ratePerSecond.toFixed(1)}/s) put at most ${peak} inside one ` +
        `${windowSeconds}s window, against a declared ceiling of ${authBucketLimit}: ` +
        `the window expired entries faster than this flood could add them, so no ` +
        `flood LENGTH would have tripped it. Reaching ${authBucketLimit} per ` +
        `${windowSeconds}s needs a sustained ` +
        `${(authBucketLimit / windowSeconds).toFixed(2)}/s. Each failed login costs ` +
        `one Argon2 hash through ArgonPool (pool_size 2), so the endpoint's own ` +
        `throughput is the limit — raise FLOOD_CONCURRENCY here, or lower ` +
        `RATE_LIMIT_AUTH in scripts/deploy-stack.sh to a ceiling this endpoint can ` +
        `actually serve. ⚠️ This is NOT a finding about rate limiting.`,
    ).toBe(true);

    expect(
      flooded.sawRateLimit,
      `the per-IP :auth bucket is not limiting on a stack where rate limiting is ` +
        `expected (BASE_URL set, or E2E_EXPECT_RATE_LIMITING=1). ` +
        `${peak} attempt(s) sat inside one ${windowSeconds}s window against the ` +
        `ceiling of ${authBucketLimit} the stack itself declared, so the bucket was ` +
        `asked and did not answer — the reachability assertion above has already ` +
        `ruled out a probe too slow to reach it. This is the only E2E proof of that ` +
        `bucket: treat it as brute-force protection being absent, not as a flaky ` +
        `test.`,
    ).toBe(true);

    for (let n = 1; n <= 5; n++) {
      const spoofedStatus = await attemptLogin(request, floodEmail(1000 + n), {
        "X-Forwarded-For": `203.0.113.${n}`,
      });

      expect(
        spoofedStatus,
        `rotating X-Forwarded-For (203.0.113.${n}) must not bypass the rate limit — ` +
          `expected 429, got ${spoofedStatus}`,
      ).toBe(429);
    }
  });
});
