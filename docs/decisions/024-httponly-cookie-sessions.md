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

⚠️ So the document describing this system has been asserting cookie sessions,
with the same `SameSite=Lax` value argued for above, for however long. The
agreement is a coincidence rather than a prior decision — nothing read the
cookie. W4b (#506) chooses explicitly whether to use that plumbing, leave it
inert with a reason, or delete it; a wired plug carrying nothing is the mirror of
this repository's commonest defect.

### 2. `SameSite=Lax`, and the argument is the confirmation link

**Lax**, not `Strict`.

The deciding case is email confirmation. A confirmation link is a **cross-site
top-level GET**: the reader clicks a link in their mail client, which is a
different site. Under `SameSite=Strict` the browser withholds the cookie on that
navigation, so a reader who has just confirmed their address lands on a
logged-out page — the exact moment the product most needs to look like it works.
`Lax` sends the cookie on top-level navigation and withholds it on cross-site
subrequests, which is the property wanted.

⛔ **What `Lax` does not buy, stated because it is the whole reason the next
decision exists.** `Lax` permits the cookie on a cross-site **top-level** request
— and a form POST that navigates the top-level frame is exactly that. So `Lax`
is not CSRF protection for state-changing requests. Treating it as such is the
most likely way this ADR gets misread.

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

`GET /api/me` at boot, replacing the parsed storage blob.
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

⚠️ `GET /api/me` must not have a "not signed in" success shape. An
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

- `guardian_tokens` families and the `family_id` revocation check
  (`guardian.ex:56-59`) — the mechanism for **user** sessions.
- The boot-scoped rejection of **admin** tokens: `typ: "admin_session"` carries a
  `bid` claim compared against `Core.Application.boot_id()` (`guardian.ex:49`),
  so every admin session dies on deploy. ⚠️ Note the precision — `boot_id`
  invalidation is admin-only; user sessions are revoked by family, not by boot.
  A change that applied one mechanism's reasoning to the other would be wrong.
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

- Issue #505 (this ADR), #506 (transport + `/api/me` + counter), #507 (CSRF),
  #508 (SPA auth model), #509 (SSE + admin elevation), #510 (E2E harness +
  rollout), #511 (review currency).
- `docs/technical-architecture.md` — session transport description, updated with
  this ADR.
- [ADR 016](016-guardian-db-token-revocation.md) — revocation, unchanged.
