import { test, expect, APIRequestContext } from "@playwright/test";

// ─────────────────────────────────────────────────────────────────────────────
// Issue #176 — LIVE-STACK rate-limit validation (B1)
//
// WHY THIS TEST IS ISOLATED AND RUNS LAST/ALONE:
//
// The rate limiter keys buckets on the TRUSTED `fly-client-ip` header, which
// Fly injects/overwrites at its edge — a real client cannot set or rotate it.
// Unit/integration tests set `fly-client-ip` by hand, which is impossible on a
// real Fly-fronted deployment; they therefore cannot prove the production
// topology (that XFF rotation buys an attacker nothing). This test closes that
// gap by hitting a real Fly preview through the same public HTTP path a
// brute-forcer would use.
//
// Because we CANNOT fake distinct source IPs on live Fly (that impossibility is
// precisely the security property under test), every request here lands in the
// SAME per-IP `:auth` bucket (prod limit 60 / 60s). Tripping the 429 therefore
// SATURATES the shared bucket for ~60s for the whole preview. Any other test
// that then logs in / registers from the same egress IP would spuriously 429.
//
// So this spec is wired into a dedicated Playwright project (`ratelimit`) that:
//   - depends on ["setup", "chromium", "upload-mock", "upload"] → runs LAST,
//   - is `fullyParallel: false` with `retries: 0` (a saturation test must not
//     be re-attempted into an already-saturated bucket), and
//   - is excluded from the `chromium` project's `testIgnore`.
// See e2e/playwright.config.ts.
// ─────────────────────────────────────────────────────────────────────────────

const WRONG_PASSWORD = "wrong-password-xyz";

// Per-IP `:auth` bucket limit is 60/60s in prod; loop a little past it so the
// 429 has room to appear even if the shared preview already has a few requests
// on the bucket from earlier warm-up.
const MAX_FLOOD_ATTEMPTS = 65;

// Unique per request so we fill the per-IP bucket WITHOUT ever repeating a
// single account (which would trip the per-account lockout → 423, not 429).
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
    // A 429 is an expected status here, not a transport failure.
    failOnStatusCode: false,
  });
  return resp.status();
}

/**
 * Is the `:auth` limiter expected to be ON for the target under test?
 *
 * ⚠️ **This must be decided from the ENVIRONMENT, never from the observation.**
 * Until Issue #330 the spec ended its flood loop with
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
  // Environment-derived gate, evaluated BEFORE the flood runs. Inside the test
  // body a missing 429 is a failure, never a skip.
  test.skip(
    !rateLimitingExpected(),
    "Rate limiting is not expected on this target (no BASE_URL ⇒ local Phoenix, " +
      "where config/test.exs disables it). Set E2E_EXPECT_RATE_LIMITING=1 to " +
      "enforce the :auth bucket guarantee against this stack.",
  );

  test("brute-force login trips 429 and rotating X-Forwarded-For cannot bypass it", async ({
    request,
  }) => {
    // ── Flood phase: realistic brute force, one unique account per attempt ──
    let sawRateLimit = false;
    let attemptsUsed = 0;

    for (let i = 0; i < MAX_FLOOD_ATTEMPTS; i++) {
      attemptsUsed = i + 1;
      const status = await attemptLogin(request, floodEmail(i));

      // Guard: a per-account lockout (423) means we accidentally reused an
      // account — the loop is meant to stress the per-IP bucket, not one
      // account. Unique emails should make this impossible; fail loudly if not.
      expect(
        status,
        "unique-email flood should never hit the per-account lockout (423)",
      ).not.toBe(423);

      if (status === 429) {
        sawRateLimit = true;
        break;
      }
    }

    // No 429 within the budget ⇒ the per-IP `:auth` bucket is not limiting on a
    // stack where we established (above, from the environment) that it must.
    // That is the brute-force protection being gone — a hard failure.
    expect(
      sawRateLimit,
      `expected a 429 within ${MAX_FLOOD_ATTEMPTS} login attempts but saw none after ` +
        `${attemptsUsed} — the per-IP :auth bucket is not limiting on a stack where ` +
        `rate limiting is expected (BASE_URL set, or E2E_EXPECT_RATE_LIMITING=1). ` +
        `This is the only E2E proof of that bucket: treat it as brute-force ` +
        `protection being absent, not as a flaky test.`,
    ).toBe(true);

    // ── Spoof phase: rotate X-Forwarded-For, expect STILL 429 ──
    // On the real stack the limiter keys on Fly-injected `fly-client-ip`, so a
    // client-supplied XFF is ignored: rotating it must NOT mint fresh buckets
    // or reset the counter. Each attempt uses a distinct spoofed XFF AND a
    // fresh unique account (so a 423 can never masquerade as "not bypassed").
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
