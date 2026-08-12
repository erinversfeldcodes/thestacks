import { test, expect } from "@playwright/test";

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
