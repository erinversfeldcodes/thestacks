# Issue #368: The banner knows we reconnected; the shelf underneath it never finds out

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by the lead's Wave 6 live drive on the preview, 2026-08-01, while confirming #362's
connectivity banner. **#362 works** — both halves of it. What the drive exposed is that its two
halves don't talk to each other.

Driven end to end as `owner@thestacks.app`, with connectivity simulated the way `elm/http`
actually experiences it (an `XMLHttpRequest.prototype.send` that dispatches `error`):

```
1. Go offline, navigate to /library
   → global banner: "You are offline. The Stacks can't reach the library right now —
                     anything already on screen stays put, and this will clear as soon
                     as you reconnect."
   → shelf body:    "The library is unreachable. Check your connection, then try again."
   → the bookcase is NOT repainted as empty        ✅ (the thing most worth getting right)

2. Restore transport, dispatch `online`
   → banner clears                                  ✅ its promise is kept
   → shelf still reads "unreachable ... try again"  ❌ on a working connection
```

**The application knows the connection came back — it demonstrably acts on that knowledge by
clearing its own banner — and leaves the reader looking at a stale failure it could now fix.**

## Two defects, one seam

**1. "Then try again" names an affordance that does not exist.** `loadError`
(`frontend/src/Page/Bookshelf.elm:551`) is rendered as bare text at line 633. There is no `Retry`
message in the module and no button. The only ways to actually try again are to navigate away and
back, or to reload — neither of which the copy mentions. We tell the reader to act and hand them
nothing to act with.

**2. The shelf cannot see connectivity.** `grep` for `isOnline|onLine|Connectivity` in
`Page/Bookshelf.elm` returns nothing. The signal exists globally, arrives correctly, and stops at
the banner. So the recovery the reader is being asked to perform manually is one the app is better
placed to perform itself, at the exact moment it already knows to.

These are the same seam from two sides. Fixing (2) largely dissolves (1) for the offline case —
which is why they belong in one issue rather than two.

## What is genuinely good here, and should not be lost
#362's author reasoned about this explicitly, in a comment above `loadError`:

> `NetworkError` — there is no connection. "Try again" alone would send them round the same loop;
> the fix is upstream of the app.

That diagnosis is correct and it is the right instinct. The gap is that the shipped string still
ends in "then try again" — the reasoning did not make it all the way into the copy. Likewise the
deliberate choice to stay generic on a 500 ("a reader cannot act on a 500") is right and must
survive this change. ⚠️ **Do not flatten `loadError` into one message while fixing this.**

## User Stories
Cross-cutting: every shelf surface (US-2.x, US-4.x). No new story.

## Goal
When the connection returns, the reader's shelf returns with it — without being asked to do
anything, and without being told to press something that isn't there.

## Scope Check
One module's error branch plus the connectivity signal's reach. Single concern. ⚠️ Decide whether
recovery is a general rule for `RemoteData` surfaces or a shelf-local fix — see requirement 3.

## Technical Requirements
1. **Refetch on reconnect.** When connectivity is restored and the current page is in a
   `NetworkError` failure state, reissue the request. The reader does nothing.
2. **Make the copy true.** Either give the error a working retry control, or — preferably, given
   (1) — stop instructing the reader to do a thing the app now does for them. Whichever is chosen,
   the string and the affordance must agree. ⚠️ Keep `Timeout` and `NetworkError` distinct; that
   split is #362's and it is right.
3. **Decide the scope of the rule and state it.** The shelf is where this was found, not
   necessarily where it lives. Every page that can fail with `NetworkError` has the same hole.
   Say whether this is a shelf fix or a shared recovery behaviour, and why — a per-page fix
   repeated six times is the duplication family #363 just spent an issue collapsing.
4. **Do not regress the good behaviour.** A failed load must still never repaint the bookcase as
   empty (verified working in this drive). That is the higher-severity property and it is
   currently correct.

## Reviewer Context
- ⚠️ **`fetch` is a no-op for `elm/http`** — patch `XMLHttpRequest.prototype.send` to simulate
  transport failure. Note that assigning over it and then `delete`-ing removes the native
  own-property rather than unmasking it; recover a pristine `send` from a fresh realm (an iframe)
  or reload.
- ⚠️ **Do not trust `document.body.innerText` on this preview.** During this drive the tab was
  occluded, so zero `requestAnimationFrame`s fired, Elm never patched the DOM, and text reads
  returned stale frames repeatedly (#362's own harness finding). A screenshot forces a frame and
  was the reliable signal throughout — every observation above is screenshot-backed.
- Related: **#366** (nothing ties an Elm port name to its JS) covers the hop this feature's signal
  travels over. If the reconnect signal gains a second consumer, that gate matters more.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ reconnect while in `NetworkError` reissues the request — probe by removing the trigger |
| Elm | yes | ❌ copy and affordance agree; `Timeout` ≠ `NetworkError` still holds |
| Elm | yes | ✅→ keep: a failed load does not render an empty bookcase (currently correct — pin it) |
| Live drive | yes | ❌ **the acceptance test**: offline → error → reconnect → shelf populates, untouched |
| Others | no | n/a |

## Definition of Done
- [ ] Reconnect reissues the failed request — evidence: diff + probe transcript
- [ ] Copy matches the affordance actually offered — evidence: the string + the control
- [ ] Scope rule stated (shelf-local vs shared) with reasoning — evidence: the decision
- [ ] Empty-bookcase regression pinned by a test — evidence: test name + probe
- [ ] Live-driven: offline → reconnect → shelf recovers with no reader action — evidence: screenshots
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by the Wave 6 live drive, downstream of **#362** (which built both halves of the seam).
Related to **#366**. Needs an owner wave assignment — this is polish on a shipping surface rather
than a correctness hole, so it sits behind #367 (consent) in priority.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-08-01 by the lead during the Wave 6 live drive. Every step screenshot-verified: the
banner appearing, the shelf error, the banner clearing on reconnect, and the shelf error surviving
it. The absence of a retry affordance confirmed by reading `Page/Bookshelf.elm` — `loadError` is
rendered as text at line 633, and the module contains no `Retry` message and no connectivity field.
