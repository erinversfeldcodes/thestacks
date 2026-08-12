import { test, expect, APIRequestContext } from "@playwright/test";

const WRONG_PASSWORD = "wrong-password-xyz";

const MAX_FLOOD_ATTEMPTS = 65;

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
    let sawRateLimit = false;
    let attemptsUsed = 0;

    for (let i = 0; i < MAX_FLOOD_ATTEMPTS; i++) {
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
      `expected a 429 within ${MAX_FLOOD_ATTEMPTS} login attempts but saw none after ` +
        `${attemptsUsed} — the per-IP :auth bucket is not limiting on a stack where ` +
        `rate limiting is expected (BASE_URL set, or E2E_EXPECT_RATE_LIMITING=1). ` +
        `This is the only E2E proof of that bucket: treat it as brute-force ` +
        `protection being absent, not as a flaky test.`,
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
