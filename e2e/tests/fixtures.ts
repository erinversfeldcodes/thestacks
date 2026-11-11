import {
  test as base,
  expect,
  type APIRequestContext,
  type Browser,
  type BrowserContext,
  type Page,
} from "@playwright/test";

/**
 * Playwright fixtures that make the suite behave like a browser with respect to
 * CSRF.
 *
 * ⛔ WHY THIS EXISTS. The server refuses a state-changing request that carries
 * no double-submit proof. Playwright's `request` fixture has its own cookie jar
 * and never loads a page, so it held no `stacks_csrf` cookie and sent no
 * `x-csrf-token` header — and **84 write sites across the specs** would have
 * been refused the moment enforcement went on.
 *
 * ⚖️ Rather than edit those 84 sites, the `request` fixture is replaced once,
 * here: it fetches a page to obtain the cookie, then carries the matching
 * header on every request. A spec written tomorrow gets it without knowing this
 * file exists, which is the property that makes this a fixture and not a
 * helper.
 *
 * ⚠️ WHAT A GREEN SUITE NOW MEANS, stated because it is easy to over-read: it
 * means the HARNESS carries the proof. It is not evidence that every
 * application path does — those 84 sites had never exercised the proven path
 * before this, so their passing is evidence about the fixture. The
 * application-side evidence is the `stacks_auth_csrf_proof_count_total` counter
 * and the browser drives recorded against it.
 */

const CSRF_COOKIE = "stacks_csrf";
const CSRF_HEADER = "x-csrf-token";

/**
 * The server's session cookie, named here because this file is the one place
 * that has to know the difference between "a cookie the harness needs" and "a
 * credential the harness must not acquire by accident".
 *
 * ⚠️ Imported by `helpers.ts` rather than redeclared there: the helpers that
 * set, clear and corrupt it must agree with the filter below, and a typo in any
 * one of them is silent — a cookie whose name does not match is simply not
 * sent, which looks exactly like logged-out.
 */
export const SESSION_COOKIE = "stacks_session";

/**
 * Runs in the page, before any spec code, on every page of every context.
 *
 * ⛔ WHY A SECOND MECHANISM IS NEEDED, and the `request` fixture below does not
 * cover it. **29 of this suite's API calls are made from inside the page**, as
 * `page.evaluate(() => fetch(path, { method: "PUT", … }))` — 13 of them with an
 * unsafe method. Those run in the browser, so they carry the `stacks_csrf`
 * cookie automatically and are invisible to the `request` fixture entirely.
 * They sent no header, so enforcement refused all 13, and the refusals surfaced
 * as **34 spec failures reading like application bugs** (`PUT
 * /api/settings/profile_visibility -> owner (got 403)`).
 *
 * ⚖️ WHY WRAP RATHER THAN EDIT 13 SITES. The same reason the fixture replaces
 * `request` rather than 84 call sites: a spec written tomorrow gets the proof
 * without knowing this file exists. A 14th hand-built write would otherwise fail
 * with a bare 403 and send its author hunting in the application.
 *
 * ⚠️ WHAT IT DOES NOT TOUCH, deliberately:
 *   * safe methods — a GET must never be refused, and adding a header to one
 *     would make this harness diverge from a browser for the majority of calls;
 *   * cross-origin requests — the proof belongs to the origin that minted it,
 *     and a custom header on a cross-origin subresource forces a CORS preflight
 *     that would break cover-image loading across the suite;
 *   * a call that already sets the header — the application's own requests do,
 *     and overwriting them would hide a real defect in that path;
 *   * `Request`-object and other exotic `fetch` shapes — every site in this
 *     suite passes `(pathString, initObject)`; anything else falls through
 *     untouched rather than being reconstructed, because re-wrapping a `Request`
 *     that carries a body is not reliably lossless.
 *
 * ⚠️ Elm's own requests go through `XMLHttpRequest`, not `fetch`, so this
 * wrapper is invisible to the application under test. It changes the harness
 * only — which is also why a green suite is evidence about the harness, as the
 * note on the `request` fixture says.
 */
function carryTheProofOnInPageWrites({
  cookieName,
  headerName,
}: {
  cookieName: string;
  headerName: string;
}): void {
  const safeMethods = ["GET", "HEAD", "OPTIONS"];
  const nativeFetch = window.fetch;

  window.fetch = function patchedFetch(
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> {
    if (typeof input !== "string" || !init) {
      return nativeFetch(input, init);
    }

    const method = (init.method ?? "GET").toUpperCase();
    if (safeMethods.includes(method)) {
      return nativeFetch(input, init);
    }

    let target: URL;
    try {
      target = new URL(input, window.location.href);
    } catch {
      return nativeFetch(input, init);
    }
    if (target.origin !== window.location.origin) {
      return nativeFetch(input, init);
    }

    const headers = new Headers(init.headers ?? {});
    if (headers.has(headerName)) {
      return nativeFetch(input, init);
    }

    const entry = document.cookie
      .split("; ")
      .find((pair) => pair.startsWith(`${cookieName}=`));
    if (!entry) {
      return nativeFetch(input, init);
    }
    headers.set(headerName, entry.slice(cookieName.length + 1));

    return nativeFetch(input, { ...init, headers });
  };
}

/**
 * Install the proof-carrying wrapper on a context, so every page it opens
 * carries the proof on its in-page writes.
 *
 * ⛔ EXPORTED BECAUSE THE FIXTURE IS NOT THE ONLY WAY A CONTEXT IS BORN, and
 * assuming it was is how this bit twice. **13 specs call
 * `browser.newContext()` directly** — for an anonymous browser, a second tab,
 * a different suite's storage state — and such a context never passes through
 * the `context` fixture, so it never got the wrapper. `rss.spec.ts` does
 * exactly that and then writes through `apiCallFromPage`, and it kept failing
 * `PUT /api/settings/profile_visibility -> platform (got 403)` after the
 * fixture was supposedly fixed.
 *
 * ⚠️ Prefer `newProvenContext` below. Use this directly only when a context
 * already exists and cannot be created through it.
 */
export async function installProof(context: BrowserContext): Promise<void> {
  await context.addInitScript(carryTheProofOnInPageWrites, {
    cookieName: CSRF_COOKIE,
    headerName: CSRF_HEADER,
  });
}

/**
 * `browser.newContext()` with the proof wrapper already installed.
 *
 * ⚖️ A drop-in replacement, taking the same options, so the call site reads
 * the same and cannot forget the install. That is the point: the previous
 * version of this guarantee lived only in the `context` fixture, which is a
 * property of how a context is *requested* rather than of what a context
 * *is* — and every spec that built its own was silently exempt.
 */
export async function newProvenContext(
  browser: Browser,
  options?: Parameters<Browser["newContext"]>[0],
): Promise<BrowserContext> {
  const context = await browser.newContext(options);
  await installProof(context);
  return context;
}

export const test = base.extend<{
  context: BrowserContext;
  request: APIRequestContext;
}>({
  context: async ({ context }, use) => {
    await installProof(context);
    await use(context);
  },

  request: async ({ playwright, baseURL }, use) => {
    // ⚠️ A throwaway context whose only job is to receive the cookie. The
    // cookie is issued on the SPA page response, so a GET of "/" is what
    // obtains it — exactly what a browser does before it can send anything.
    const seed = await playwright.request.newContext({ baseURL });
    await seed.get("/");
    const state = await seed.storageState();
    const proof = state.cookies.find((c) => c.name === CSRF_COOKIE)?.value;
    await seed.dispose();

    // ⛔ THE SESSION COOKIE IS STRIPPED, AND THIS IS THE CORRECTION OF A WRONG
    // MODEL I HELD FOR MOST OF A SESSION. `playwright.request.newContext()`
    // INHERITS the test's `use` options — including `storageState` — so the
    // seed above silently arrives already signed in as whichever suite user the
    // spec declared. Measured, not reasoned: a probe inside this fixture
    // printed `["stacks_csrf","stacks_session"]` on a spec whose storage state
    // is a suite auth file.
    //
    // ⚠️ WHAT THAT BREAKS IS THE WORD "ANONYMOUS". Across this suite, "as a
    // logged-out client" is written as a `request` call with no `Authorization`
    // header — which was airtight while a bearer token was the only credential
    // a context could hold, and became false the moment the saved storage state
    // started carrying a session cookie the server PREFERS over the header.
    // Three assertions about logged-out access then read 200 where they wanted
    // 404, and each one looked exactly like a privacy defect in the
    // application. The server was right in every case: probed directly, a
    // `platform` bookshelf's feed answers 404 to a credential-free client.
    //
    // ⚖️ So this fixture carries the PROOF and no IDENTITY. A spec says who it
    // is with an explicit header, which is what nearly every call here already
    // does, and a spec that logs in during the test still gets its session from
    // the response — as a browser would. Nothing legitimately depended on the
    // inheritance: before the cookie transport landed, a saved state held no
    // session cookie at all, so there was nothing to inherit.
    const credentialFree = {
      ...state,
      cookies: state.cookies.filter((c) => c.name !== SESSION_COOKIE),
    };

    // ⛔ NOT a silent fallback. If the cookie did not arrive, a spec that then
    // fails with a 403 would look like an application bug; this says plainly
    // that the harness could not obtain a proof. An empty header would be
    // worse still — the server compares it against the cookie and an empty
    // match is the hole the emptiness check exists to close.
    if (!proof) {
      throw new Error(
        `CSRF fixture: no ${CSRF_COOKIE} cookie on the page response from ${baseURL}. ` +
          `Every state-changing request in this suite will be refused. Check that ` +
          `StacksWeb.Plugs.CsrfCookie is on the :spa pipeline and that the cookie is ` +
          `reaching the client (it must NOT be HttpOnly).`,
      );
    }

    const proven = await playwright.request.newContext({
      baseURL,
      storageState: credentialFree,
      extraHTTPHeaders: { [CSRF_HEADER]: proof },
    });

    await use(proven);
    await proven.dispose();
  },
});

/**
 * The proof the page currently holds, as headers to spread into a request.
 *
 * ⛔ FOR `page.request` ONLY, which is the one write path neither mechanism
 * above reaches: it is an `APIRequestContext` bound to the browser context, so
 * it shares the context's cookies but is not the `request` fixture and does not
 * run in the page. There is exactly one unsafe `page.request` call in this
 * suite; a second one should use this rather than build a header by hand.
 *
 * ⚠️ Throws rather than returning `{}`. An absent proof here means the page
 * never received the cookie, and a silently unproven write would fail as a 403
 * that looks like an application defect.
 */
export async function provenHeaders(
  page: Page,
): Promise<Record<string, string>> {
  const proof = await page.evaluate((cookieName) => {
    const entry = document.cookie
      .split("; ")
      .find((pair) => pair.startsWith(`${cookieName}=`));
    return entry ? entry.slice(cookieName.length + 1) : null;
  }, CSRF_COOKIE);

  if (!proof) {
    throw new Error(
      `No ${CSRF_COOKIE} cookie in the page at ${page.url()}, so this write ` +
        `cannot carry a proof and the server will refuse it. Load a page first ` +
        `— the cookie is issued on the SPA page response.`,
    );
  }

  return { [CSRF_HEADER]: proof };
}

export { expect };
