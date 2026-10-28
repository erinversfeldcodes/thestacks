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

    let sawRateLimit = false;
    let attemptsUsed = 0;

    for (let i = 0; i < maxFloodAttempts; i++) {
      attemptsUsed = i + 1;
      const status = await attemptLogin(request, floodEmail(i));

      expect(
        status,
        "unique-email flood should never hit the per-account lockout (423)",
      ).not.toBe(423);

      if (status === 429) {
        sawRateLimit = true;
        break;
      }
    }

    expect(
      sawRateLimit,
      `expected a 429 within ${maxFloodAttempts} login attempts but saw none after ` +
        `${attemptsUsed} — the per-IP :auth bucket is not limiting on a stack where ` +
        `rate limiting is expected (BASE_URL set, or E2E_EXPECT_RATE_LIMITING=1). ` +
        `The stack told this suite its ceiling is ${authBucketLimit}, so the flood ` +
        `overshot it by 10 and a limiting bucket had to answer. This is the only ` +
        `E2E proof of that bucket: treat it as brute-force protection being ` +
        `absent, not as a flaky test.`,
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
