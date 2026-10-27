import { test as base, expect, type APIRequestContext } from "@playwright/test";

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

export const test = base.extend<{ request: APIRequestContext }>({
  request: async ({ playwright, baseURL }, use) => {
    // ⚠️ A throwaway context whose only job is to receive the cookie. The
    // cookie is issued on the SPA page response, so a GET of "/" is what
    // obtains it — exactly what a browser does before it can send anything.
    const seed = await playwright.request.newContext({ baseURL });
    await seed.get("/");
    const state = await seed.storageState();
    const proof = state.cookies.find((c) => c.name === CSRF_COOKIE)?.value;
    await seed.dispose();

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
      storageState: state,
      extraHTTPHeaders: { [CSRF_HEADER]: proof },
    });

    await use(proven);
    await proven.dispose();
  },
});

export { expect };
