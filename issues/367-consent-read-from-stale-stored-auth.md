# Issue #367: Revoking analytics consent works, and the page then says it didn't

## Summary
Found by the lead's Wave 6 live drive on the preview, 2026-08-01, while confirming #363's fix to the inert "Saved!" button. **#363's fix works** — the revocation now reaches the server. What the drive exposed is a *second, independent* defect underneath it.

Driven end to end as `owner@thestacks.app`:

```
1. Analytics On  → Save          POST /api/gdpr/consent {"consent":true}   → 200
2. Toggle to Off → Save          POST /api/gdpr/consent {"consent":false}  → 200
3. Reload the page               Analytics renders "On"
4. Database (preview branch)     consent_analytics = false
                                 consent_analytics_at = 2026-08-01T13:26:44.127Z
```

**The server honoured the withdrawal. The page tells the reader it did not.**

## Root cause
`Main.elm:1041` seeds the consent page from `auth.user.consentAnalytics`:

```elm
Consent.init { analytics = auth.user.consentAnalytics, … }
```

That value is decoded from the **stored auth blob in `localStorage`** (`Main.elm:550`, `:580`), which is written once at login and never revised. Confirmed live — the blob still held `consentAnalytics: true` while the database held `false`:

```json
{"stored_consentAnalytics": true, "blobKeys": ["token","userId","email","displayName","handle","role","consentAnalytics","consentWritingAssistant"]}
```

So the **write goes to the server and the read comes from a cached credential**. After any change they disagree until the reader logs out and back in.

## Why this one matters more than its shape suggests
This is the same family as #355 (merge succeeded, detail page showed the old value) and #357 (age gate raised, cached book still ungated) — a successful write followed by a stale read. But the surface changes the severity:

- **A reader who withdraws consent and is then shown "On" will reasonably conclude the withdrawal failed.** They will either repeat it, or stop trusting the control.
- GDPR requires withdrawal to be **as easy as granting**. The server complies; the interface undermines it by reporting the opposite.
- `consent_writing_assistant` sits in the same blob and has the same problem.

## Not a regression
Pre-existing and independent of Wave 6. #363 fixed the *sending* half (an enabled "Saved!" button wired to nothing, plus a toggle that never reset `saving`), which is what made this half reachable at all — before, the second save never left the browser, so nobody got as far as the stale read.

## User Stories
US-17.2.x (settings forms), GDPR consent lifecycle.

## Goal
The consent surface reflects what the server actually holds, and a withdrawal a reader performs is a withdrawal they can see.

## Scope Check
One seed site + wherever the stored blob is refreshed. Small. ⚠️ Decide the general rule, not just this field — the blob carries `role` too.

## Technical Requirements
1. **Decide where consent state lives, and make one source authoritative.** Two candidates: refresh the stored blob after a successful consent write, or stop seeding consent from the blob and fetch it from the server when the page opens. ⚠️ Prefer the second unless there is a reason not to: a credential is for *authentication*, and every non-auth field carried inside it is a cache with no invalidation story.
2. **Audit the rest of the blob.** `consentAnalytics`, `consentWritingAssistant`, `role`, `displayName`, `handle` are all in there. Say which are safe to cache in a credential and which are not — `role` in particular decides what the reader is shown.
3. **Test read-after-write, not the write.** The write already returns 200 and the DB is already correct; a test asserting either would pass today. The regression test must span **write → reload → read**, which is the boundary no current test crosses. Same shape as #355's request→cache→read test.
4. **Live-drive it** — this was only findable by driving, because the DOM, the API and the database all disagreed and only the database was right.

## Reviewer Context
- ⚠️ **Do not "fix" this by trusting the DOM.** During this drive the tab was occluded, so Elm's paint was frozen and three DOM reads reported stale values (#362's harness finding). The screenshot and the database were the reliable signals. Verify with a screenshot plus a server read.
- ⚠️ #363 changed `ToggleAnalytics` to reset `saving`, which is load-bearing and must not be reverted — see the ⛔ comment on that line.
- Related: **#355** (merge → stale detail), **#357** (age gate → cached book). If a third instance is landing, consider whether the project needs a general rule about read-after-write rather than three point fixes.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ consent page reflects the server after a write + reload — probe by reverting the seed |
| API calls | yes | ❌ write → reload → read spans the boundary; asserting the 200 alone passes today |
| Security | yes | ❌ whatever the blob keeps is stated and justified, `role` especially |
| Live drive | yes | ❌ **the acceptance test**: revoke, reload, see it revoked — screenshot + DB row |
| Others | no | n/a |

## Definition of Done
- [x] One authoritative source for consent state, with the decision stated — evidence: `8b79c626` — consent REMOVED from the stored-auth blob entirely; the server is the single source, hydrated on page load (`5280adb7`)
- [x] Blob audit — evidence: `8b79c626`'s treatment: consent fields dropped from the blob (state, not identity); the remaining fields (token/userId/email/displayName/handle/role) are login identity, cacheable by construction
- [x] write → reload → read regression test — evidence: Elm hydration unit-proven at landing (1744/0)
- [x] Live-driven: revoke → reload → still revoked — evidence: definitive REAL-LOGIN validation at finalize 2026-08-09 (settings.spec.ts:132 WA-consent, real login, part of the 298 pass) — the earlier injected-session drive could not exercise auth-init hydration and was recorded OPEN until this
- [x] `staff-review` verdict recorded below — see Wave 11 close-out

## Dependencies
Surfaced by the Wave 6 live drive, downstream of **#363**. Related to **#355**, **#357**. Needs an owner wave assignment — ⚠️ this is a **consent** surface, so it belongs before launch (Wave 11, beside #353 and #357) rather than in the general backlog.

## Agent Assignment
elm-agent + elixir-agent.

## Progress Notes
Filed 2026-08-01 by the lead during the Wave 6 live drive. Every step verified independently: the two POSTs captured at the XHR layer with their bodies and statuses, the database read from the preview branch `br-falling-wave-and3e0fr`, and the stale blob read out of `localStorage` in the live tab.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — removing consent from the blob (rather than refreshing it) makes the class unrepresentable — the strongest of the available shapes. Definitive real-login validation closed the injected-session gap honestly.
