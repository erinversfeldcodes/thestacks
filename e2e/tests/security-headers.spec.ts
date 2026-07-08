import { test, expect } from "@playwright/test";

// Regression guard for the SPA's Content-Security-Policy.
//
// Two failure modes this catches:
//   1. The SPA's catch-all route is rewired without the `:spa` pipeline,
//      so the HTML response carries no CSP header at all and browser-side
//      enforcement disappears silently.
//   2. CSP `connect-src` is tightened back to `'self'` without realising
//      the presigned-URL upload flow PUTs directly to
//      `<account>.r2.cloudflarestorage.com` — the browser would block the
//      PUT and uploads would fail with no obvious server-side signal.
//
// Asserts on a live HTTP response from the deployed app rather than the
// plug in isolation, so we catch both the plug-level config and the
// router-pipeline wiring at the same time.

test.describe("Security headers — SPA CSP regression guard", () => {
  test("upload page response sets CSP and connect-src allows R2", async ({
    page,
  }) => {
    const response = await page.goto("/upload");
    expect(response, "page response should not be null").not.toBeNull();

    const csp = response!.headers()["content-security-policy"];
    expect(csp, "SPA must set a Content-Security-Policy header").toBeTruthy();

    const connectSrcMatch = csp!.match(/connect-src([^;]*)/);
    expect(
      connectSrcMatch,
      "CSP must declare a connect-src directive"
    ).not.toBeNull();

    const connectSrc = connectSrcMatch![1];
    expect(
      connectSrc,
      "connect-src must whitelist R2 (presigned PUT target); " +
        "without it the browser blocks the upload PUT silently. " +
        `Got connect-src: ${connectSrc}`
    ).toContain("r2.cloudflarestorage.com");
  });
});
