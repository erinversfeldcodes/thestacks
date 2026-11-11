# ADR 024: HttpOnly Cookie Sessions — `SameSite=Lax`, Double-Submit CSRF, Two-Phase Rollout

**Status:** Accepted
**Date:** 2026-10-22
**Deciders:** Platform owner
**Technical area:** Authentication, session transport, CSRF, SPA boot, E2E harness
**Relates to:** [ADR 016](016-guardian-db-token-revocation.md) — this decides session
**transport**; 016 decides **revocation**, and nothing here changes it. 016's
`guardian_tokens` families, its revocation semantics, and the boot-scoped
rejection of admin tokens all stand unchanged. See *What this supersedes* below,
which is deliberately narrow.

---

## Context

⚠️ **This section describes the system AS IT WAS WHEN THE DECISION WAS TAKEN
(2026-10-22), in the present tense, and three of its four problems are now
closed.** It is left in that tense deliberately — an ADR's context is the
evidence the decision rested on, and rewriting it would destroy the argument.
Where each problem stands:

| Problem | Status |
|---|---|
| 1. A reload loses the proof of elevation | **open** — the admin half, now its own issue |
| 2. The token is readable by any script on the page | **closed** — the stored session is deleted; `check-no-stored-session.sh` holds it |
| 3. A live credential appears in URLs | **closed** — the upload stream authenticates by cookie |
| 4. Identity goes stale in storage | **closed** — identity comes from `GET /api/auth/me` on every boot, and the `role` decoder now FAILS rather than defaulting |

The session is carried as a bearer token in a JSON response body, stored by the
SPA in `localStorage`, and attached to each request as an `Authorization` header.
Four problems follow from that, each measured rather than inferred.

**1. A reload loses the session's proof of elevation.** The server already
records admin elevation — `Stacks.Admin.SessionContext.mark_mfa_verified/1`
(`session_context.ex:42`), called from `admin_auth_controller.ex:63` — but the
SPA cannot replay it, so a refresh inside the elevation window re-prompts for
MFA. The state exists; the transport cannot carry it.

**2. The token is readable by any script on the page.** It lives in
`localStorage`: 16 references to `encodeAuth` / `decodeAuth` / `saveAuth` /
`stacks-auth` across `Main.elm` and `Api.elm`. Any injected script reads the
session.

**3. A live credential appears in URLs, and therefore in logs.**
`Page/Upload.elm:439` and `:773` both build
`/api/upload/<image_id>/stream?token=<token>`, because `EventSource` has no
header API. Every access log, proxy log and browser history entry on that path
holds a working session token.

**4. Identity goes stale in storage.** The walkthrough found an owner whose
stored blob carried no `role`: they passed MFA and then landed on "Page Not
Found". `Main.elm:645` is why it was silent — `Decode.succeed "user"` makes a
missing role indistinguishable from a reader who is a user.

### What makes the absence of CSRF protection survivable today

⛔ **There is no CSRF protection in this application.** Measured: zero matches
for `csrf`, `CSRF` or `protect_from_forgery` in `core_web/router.ex` and
`core_web/endpoint.ex`.

That has been survivable for one reason only: a bearer token in an
`Authorization` header is **not** attached by the browser to a cross-site
request. The attacker's page cannot read `localStorage` for another origin and
cannot make the browser add the header.

⚠️ A cookie removes that protection by design, because the point of a cookie is
that the browser replays it. So the moment session transport becomes a cookie,
CSRF protection stops being a hardening task and becomes a correctness
requirement of the same change.

---

## Decision

### 1. Session transport becomes an `HttpOnly` cookie

Guardian tokens move out of JSON response bodies into a cookie with
`HttpOnly; Secure; SameSite=Lax`, set on login, register and email confirmation,
and cleared on logout. Renewal becomes a server-side re-set on request rather
than a client-side timer, which removes a case the client cannot get right: a
tab asleep past expiry.

`HttpOnly` is the decision that answers problem 2 — script cannot read the
session. `Secure` means the cookie is not sent over plain HTTP.

⚠️ **`Secure` and local development.** Browsers exempt `http://localhost` from
the `Secure` requirement, so development works without a flag. That exemption is
being **relied on deliberately** and is recorded here so nobody later "fixes"
local development by making the cookie non-`Secure` in a shared config. If a
non-localhost development host is ever introduced, it needs HTTPS, not a weakened
cookie.

⛔ **An inert `Plug.Session` cookie already exists, and the architecture
document described it as the session transport.** `core_web/endpoint.ex:4-9`
configures a cookie session store (key `_core_key`, `same_site: "Lax"`), wired at
`:36` — and nothing reads or writes it: zero `get_session` / `put_session` /
`fetch_session` call sites in the web layer. `secure: true` is not among its
options either, though `docs/technical-architecture.md` claimed it was; that row
has been corrected.

⚖️ **RULED (contract review, W4a): remove it.** Verified safe — zero
`put_flash`/`get_flash`, zero CSRF, zero LiveView, and no socket declaration
anywhere in the web layer, so nothing depends on a session store.

⛔ And the deciding argument is not tidiness, it is what W4b would otherwise
inherit. That block carries `signing_salt: "stacks_signing"` — **a committed
literal in a tracked file**, which becomes a real finding the moment the cookie
carries a session — and no `secure: true`. Then the part that makes it hazardous
rather than merely untidy: its `same_site: "Lax"` coincidentally matches what
this ADR argues for independently, and **an unreviewed config that agrees with a
reviewed decision on one line reads as vetted.** The next reader infers the other
two options were considered. They were not.

An empty file forces three decisions — salt, `secure`, `same_site`. This block
forecloses two of them silently while appearing to have decided all three.

### 2. `SameSite=Lax`, and the argument is the confirmation link

**Lax**, not `Strict`.

The deciding case is email confirmation. A confirmation link is a **cross-site
top-level GET**: the reader clicks a link in their mail client, which is a
different site. Under `SameSite=Strict` the browser withholds the cookie on that
navigation, so a reader who has just confirmed their address lands on a
logged-out page — the exact moment the product most needs to look like it works.
`Lax` sends the cookie on a cross-site top-level navigation **made with a safe
method** — GET or HEAD — and withholds it on cross-site subrequests, which is
the property wanted.

⛔ **What `Lax` does not buy — CORRECTED 2026-10-28, and the original version of
this paragraph was wrong in the direction that matters.** It read: *"`Lax`
permits the cookie on a cross-site top-level request — and a form POST that
navigates the top-level frame is exactly that. So `Lax` is not CSRF protection
for state-changing requests."* **That is false.** The safe-method condition is
part of the rule: a cross-site top-level form POST does **not** carry a
`SameSite=Lax` cookie, which is precisely why Lax mitigates CSRF for POST. The
error came from the sentence above it, which dropped the method qualifier and
was then reasoned from.

⚠️ Chrome's "Lax-allowing-unsafe" intervention *did* permit cross-site POST for
cookies under two minutes old — but only for cookies that are Lax **by
default**, with no `SameSite` attribute. Both cookies here set the attribute
explicitly, so it never applied to this system.

⚖️ **The decision to add a double-submit token is unchanged, and the real
argument for it is narrower than the false one.** What `Lax` leaves open is:
(1) clients that do not enforce `SameSite` at all — pre-2018 browsers and some
embedded webviews, which is OWASP's stated reason for treating `SameSite` as
defence-in-depth and a token as the primary control; (2) top-level cross-site
GET, which Lax does permit — harmless here only because every session-authorised
GET is confirmed to be a read, and that is a property to re-check whenever one
is added; and (3) a same-site attacker, such as a subdomain, for whom
`SameSite` means nothing. ⛔ A token does **not** close an XSS on our own
origin: the cookie is readable by design, so a script on the page can echo it.
Anyone tempted to weaken `SameSite` on the strength of "we have a token" should
read this paragraph twice — the two controls cover different attackers and
neither subsumes the other.

### 3. CSRF: a double-submit token

A token in a **readable** (deliberately not `HttpOnly`) cookie, echoed by the SPA
in an `X-CSRF-Token` header, compared server-side on every state-changing route
(`POST`, `PUT`, `PATCH`, `DELETE`).

The scheme works because of the same-origin policy: an attacker's page can cause
the browser to *send* our cookies, but cannot *read* them, so it cannot populate
the header. The token is a **same-origin proof, not a secret**.

⚠️ Which means: the token cookie being readable by script is correct, not a
defect. A reviewer or a future hardening pass that makes it `HttpOnly` breaks the
scheme silently — the header can no longer be populated, and every state-changing
request fails or, worse, the check is then relaxed to compensate.

**Why not a server-side synchroniser token.** The API is stateless per request
and the SPA renders no server-side forms, so a synchroniser token would need
server-side per-session storage that nothing else requires, for no additional
property over double-submit against a same-origin SPA.

⛔ The route population must be **enumerated and declared**, not inferred from a
pipeline's name. A state-changing route added outside the protected pipeline is
the gap this scheme would otherwise ship with, so a check compares the declared
count against the router's own route list.

### 4. Identity becomes a server answer

`GET /api/auth/me` at boot, replacing the parsed storage blob. ⚠️ The route
already exists and is already consumed; what moves is WHEN the SPA asks.
(Corrected 2026-10-22 — this document previously implied the endpoint was new.)
`encodeAuth`/`decodeAuth`/`saveAuth` and the stored token are deleted, and the
`Decode.succeed "user"` fallback goes with them: with role arriving from the
server the field is always present, so a decoder that cannot produce a role
should fail rather than guess.

⛔ **Three states, not two.** Identity used to be available synchronously from
storage; a network request is not. So the SPA has
**resolved-signed-in**, **resolved-signed-out**, and **not-yet-resolved**, and
the third is not the second. Rendering signed-out chrome while the answer is in
flight flashes a logged-out header at every signed-in reader on every load;
rendering signed-in chrome shows it to anonymous readers. This is a new window
that the old model did not have, and it is the most likely silent regression of
the change.

⚠️ `GET /api/auth/me` must not have a "not signed in" success shape — and
measured 2026-10-22, it does not: the `:authenticated` pipeline refuses first.
So this is a property to PRESERVE, not one to add. An
unauthenticated request gets **401**, not 200 with a null user — otherwise "am I
signed in?" is a guess again, one layer further out.

### 5. SSE loses its query-string credential

`EventSource` sends cookies on same-origin requests, so the `?token=` parameter
becomes redundant and is removed from both construction sites and from the
route's authentication.

⚠️ **This assumes same-origin.** `EventSource` does not send cookies
cross-origin without `withCredentials`, and the server would then need CORS
credentials configured. If any deployment ever serves the SPA from a different
origin than the API, this decision needs revisiting — it is recorded as an
assumption rather than left implicit.

✅ **The assumption was VERIFIED before the change landed, not asserted.**
`Api.baseUrl` was the empty string, so every request the SPA built was a relative
URL and therefore same-origin by construction; `scripts/check-credential-origin.sh`
reported *"83 request record(s) parsed in frontend/src/Api.elm; none declares
SameOrigin with an unprovable URL"*, and as of 2026-10-28 **no request in
`Api.elm` was cross-origin at all** — the one that claimed to be was the upload
byte `PUT`, and it had been same-origin since July while declaring otherwise.

⚖️ **UPDATED 2026-11-07: that script is gone, and so is `Api.baseUrl`.** Every
request in the client is now a `RequestSpec` whose `url` is an
`Api.Url.SameOriginUrl`, built only by `Api.Url.path`, which percent-encodes each
segment and drops empty ones. So the property the script parsed for is checked by
the compiler on every build rather than re-derived by a parser that had to be kept
in step with the source. The gate's own retirement condition — nothing left in
`Api.elm` with a `String` url — is what was reached.
⚠️ So `withCredentials` is deliberately NOT set: setting it would have no effect
today and would quietly make a future cross-origin deployment appear to work
while the server lacked the CORS credentials to complete it.

### 6. Admin elevation survives a reload

`AdminAuthPipeline` reads the session cookie plus the session's
`mfa_verified_at`. No new elevation semantics: the record already exists
(decision context, problem 1), and the cookie is what lets the client present a
session the server can match it to.

### 7. Two-phase rollout, deleted on evidence

Both transports are accepted for one release. A counter tagged by transport
(`:cookie` / `:bearer`) reports which was used on each request.

⛔ **The bearer path is deleted when that counter has read zero for a release —
not on a date, and not on confidence.** The counter exists precisely so the
deletion needs no judgement. If it is non-zero, the honest outcome is that the
deletion waits.

### 8. The operator recovery path

⚠️ **None exists today.** Measured: the only operator workflows are
`gdpr-erase-user.yml` and `gdpr-lookup-user.yml`; there is no task or workflow
that restores an operator's own access.

This is the one change in the wave that can lock the owner out of production, so
creating that path is an **obligation of the transport change** (W4b, #506), not
a follow-up. Until it exists, the rollout's first phase accepting both transports
is itself the recovery path — which is a reason to keep phase one running until
the recovery path is proven, rather than only until the counter zeroes.

---

## What this supersedes

**ADR 016 — transport only.** 016 decides server-side revocation via
Guardian.DB. This ADR changes how a session token reaches the server; it does not
change what makes one invalid.

Unchanged and load-bearing after this ADR:

⚖️ **Two claim-level mechanisms plus the `Guardian.DB` baseline** — three
things, and `verify_claims/2` is a `cond`, so the two claim-level ones are
**mutually exclusive by control flow** rather than by convention about
populations:

- Branch 1 — the boot-scoped rejection of **admin** tokens: `typ:
  "admin_session"` carries a `bid` claim compared against
  `Core.Application.boot_id()` (`guardian.ex:48-53`), so every admin session dies
  on deploy. ⚠️ An admin session takes this branch and **never reaches the family
  check, even if it carried a `family_id`**.
- Branch 2 — `guardian_tokens` families and the `family_id` revocation check
  (`guardian.ex:55-59`), for **user** sessions. A family-bearing token never gets
  a boot check.
- Branch 3 — `true -> {:ok, claims}` (`guardian.ex:61-62`) is **reachable**: a
  token that is neither admin nor family-bearing passes with no claim-level
  revocation check at all. ⚠️ It is not unrevocable — `Guardian.DB.on_verify`
  (`guardian.ex:75`) still applies to every token — but a reader of branches 1
  and 2 alone could conclude such a session has *no* revocation path, which is
  why the third is named here.

⛔ The precision matters: `boot_id` invalidation is admin-only, and a change that
applied one branch's reasoning to another would be wrong in a way the `cond`
makes silent — the wrong branch simply never runs.
- Partner API keys: server-to-server, Argon2-hashed, no cookie, untouched.
- The `/api/test/*` helper gate.

⛔ A sentence reading "this supersedes ADR 016" without that scope would invite
someone to drop the revocation layer, which this ADR does not replace and cannot.

## Consequences

**Bought:** script cannot read the session; no credential in URLs or logs; a
reload keeps both the session and its elevation; identity cannot go stale; the
E2E harness gets simpler, because Playwright's `storageState` already persists
cookies and the blob-injection recipe disappears.

**Paid:** CSRF protection becomes load-bearing where previously the header
transport made its absence survivable; the SPA gains a boot window with three
states instead of two; a cross-origin SPA deployment would need revisiting; and
the readable CSRF cookie is a construct a future reader may mistake for a defect.

**Superseded elsewhere:** the project memory *"SPA auth injection recipe —
`stacks-auth` must be a FLAT blob; nesting under `user` fails silently and looks
exactly like logged-out"* describes the model this ADR deletes. It is rewritten
in W4f (#510), **including the replacement's own trap**: a cookie with the wrong
`domain` or `path` is also silently ignored and also looks exactly like
logged-out. Replacing one documented pitfall with an undocumented one would be a
net loss.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Keep bearer tokens; fix the reload with a refresh endpoint** | Addresses problem 1 only. The token stays readable by script, stays in SSE URLs and logs, and identity stays a client-held blob. Three of four problems survive. |
| **`SameSite=Strict`** | Breaks email confirmation: a cross-site top-level GET arrives without the cookie, so the reader lands logged out immediately after confirming. |
| **Cookie for the admin surface only** (the scoped option) | Considered and rejected by the owner in favour of the full migration. A split model means two auth paths indefinitely, and the three non-admin problems — script-readable token, SSE credential, stale identity — are untouched. |
| **Server-side synchroniser CSRF token** | Needs per-session server storage nothing else requires, for no property double-submit does not give against a same-origin SPA. |
| **Deleting the bearer path in one step** | No evidence that no client is using it. The counter exists so the deletion is a measurement rather than a hope. |

## References

- Issue #505 (this ADR), #506 (transport + counter; `/api/me` struck — the
  route exists as `/api/auth/me`), #507 (CSRF),
  #508 (SPA auth model), #509 (SSE + admin elevation), #510 (E2E harness +
  rollout), #511 (review currency).
- `docs/technical-architecture.md` — session transport description, updated with
  this ADR.
- [ADR 016](016-guardian-db-token-revocation.md) — revocation, unchanged.
