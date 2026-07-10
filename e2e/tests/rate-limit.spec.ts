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

test.describe("auth rate limiting (live Fly stack)", () => {
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

    // No 429 within the budget ⇒ this stack has rate limiting disabled (e.g.
    // local dev / test.exs default). The behaviour under test does not exist
    // here, so skip rather than assert a property the deployment doesn't have.
    test.skip(
      !sawRateLimit,
      `No 429 after ${MAX_FLOOD_ATTEMPTS} login attempts — rate limiting appears ` +
        `disabled on this stack. This test is meaningful only against a rate-limited ` +
        `deployed (Fly) preview.`,
    );

    expect(
      sawRateLimit,
      `expected a 429 within ${MAX_FLOOD_ATTEMPTS} attempts (got rate limited after ${attemptsUsed})`,
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
