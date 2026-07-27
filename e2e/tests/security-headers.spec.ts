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

  test("CSP img-src allows the Open Library cover redirect chain", async ({
    page,
  }) => {
    const response = await page.goto("/upload");
    const csp = response!.headers()["content-security-policy"];
    expect(csp, "SPA must set a Content-Security-Policy header").toBeTruthy();

    const imgSrcMatch = csp!.match(/img-src([^;]*)/);
    expect(imgSrcMatch, "CSP must declare an img-src directive").not.toBeNull();
    const imgSrc = imgSrcMatch![1];

    // covers.openlibrary.org 302s to archive.org, which 302s again to
    // iaNNNNNN.us.archive.org. CSP is enforced on the REDIRECT TARGET, so
    // listing only the first host silently blocks every Open Library cover:
    // curl fetches the image fine while the browser renders a broken frame.
    //
    // NOTE this asserts the header, not that a cover renders — a structure
    // gate, deliberately. A behavioural test is impossible against current
    // seed data: 200 of 201 seeded editions have NO cover_image_url at all
    // (see the seed-cover gap in the campaign plan), so there is no seeded
    // book whose cover could fail to load. Promote this to an
    // image-actually-loads assertion once seeds carry covers.
    for (const host of [
      "https://covers.openlibrary.org",
      "https://archive.org",
      "https://*.us.archive.org",
    ]) {
      expect(
        imgSrc,
        `img-src must allow ${host} — Open Library covers redirect ` +
          `covers.openlibrary.org -> archive.org -> *.us.archive.org and CSP ` +
          `blocks an unlisted redirect target. Got img-src: ${imgSrc}`
      ).toContain(host);
    }
  });
});
