# Wave 9 preview walk — actual vs promised (COMPLETE)

> Driven live on the preview, authenticated as a minted `@thestacks.test` user,
> 2026-11-17. ⚠️ `SKIP_VISION` deploy, so the photo-upload→identify path is not
> exercisable; the manual-ISBN path was used instead where a book was needed.
> ⬛ Headline: the pattern is uniformly **"built but not wired"** — every surface
> exists and its basic flow works, but each item's SPECIFIC promise is a gap.
> This is exactly what "the core loop keeps its promises" targets.

**Also established (answering a mid-walk question): there is NO auth bug.** Real
login enforces CSRF correctly (ADR 024); the mint helper works with a
`@thestacks.test` email. My earlier 404s were (a) a test-only gate and (b) my
wrong email domain — `mint_session` returns the same `{"error":"not_found"}`
body as the gate, which misled me.

---

## W9a — Upload refetch on step transitions
Promise: refetch the provisional book on each step transition; page text updates
after enrichment.
- **Actual:** the manual-ISBN path works end to end — ISBN `9780316769488` →
  resolved "The Catcher in the Rye" → added to Library → success screen with
  "Add another" / "View on shelf". The photo-upload step-transition/refetch
  behaviour is NOT exercisable under `SKIP_VISION`.
- **Gap/scope:** ⚠️ needs a vision-enabled deploy to verify the refetch-on-
  transition assertion. The ISBN path is a different (single-step) flow and
  looks complete. The issue carries a "verify on full stack" note the others
  don't.

## W9b — Onboarding overlay trigger deliberate
Promise: overlay triggers only on (right route + no upload in flight + Success []);
dismissal server-side.
- **Actual:** the authenticated landing with an EMPTY collection shows "Welcome
  back / Your shelves are waiting / Add a book" — **no onboarding overlay at
  all.** So on the exact condition the promise names (empty success), nothing
  triggers.
- **Gap/scope:** either the overlay never triggers (not wired to its route/empty
  condition) or it's gated off. Scope: establish the current trigger (grep
  `OnboardingOverlay` wiring) and build the deliberate route+empty-collection
  trigger + server-side dismissal.

## W9c — Post-publish flow
Promise: after publishing, a "View post" action + URL to `/blog/:id`; relative-
time byline.
- **Actual:** ⛔ Publish SUCCEEDS (button → "Published!") but the URL stays
  `/blog/new`, the page becomes "Edit Post", and there is **NO "View post"
  affordance and no navigation to `/blog/:id`.** The post-publish nav is missing.
- **Gap/scope:** wire the post-publish success to offer "View post" → `/blog/:id`;
  verify the byline voice on the public post page separately.

## W9d — Spine arrival ON THE SHELF
Promise: `/<shelf>?arrived=<id>` → one-shot `book--arriving` keyframe +
reduced-motion fallback.
- **Actual:** "View on shelf" navigates to `/library` **without** the `?arrived=`
  param. Navigating manually to `/library?arrived=<book_id>` applies **no
  arriving class to any element, and there is NO `book--arriving` keyframe in the
  loaded CSS at all.** The spine renders statically (nicely — 3D green spine) but
  does not animate in.
- **Gap/scope:** ⛔ not built/wired — the `arrived` param is inert and the
  keyframe is absent. Build: pass `arrived` on the post-add nav, add the one-shot
  `book--arriving` keyframe + `prefers-reduced-motion` fallback, drop
  `placementStub`, fix US-1.1.1's two copy drifts.

## W9e — community_read_count carried + rendered
Promise: `community_read_count` flows backend → `Types.Book` → rendered.
- **Actual:** ⛔ **`community_read_count` is ABSENT from the entire
  `/api/bookshelves/library` payload** (`has_community_read_count_field: false`).
  It exists in `insights.ex`/`books.ex` (backend) but never reaches the frontend,
  so it cannot render. Textbook wiring break.
- **Gap/scope:** carry the count through the serializer → `Types.Book` decoder →
  render; record the ADR-008 wear ladder as unbuilt. (Dependency W3a is complete.)

---

## Walk summary
- **5 of 5 driven** (W9a partial — photo path needs vision).
- **Built-and-working (basic flow):** add-book (ISBN), publish-post, shelf render — all fine.
- **Built-but-broken / not-wired (the promises):** W9c (no view-post nav), W9d
  (arrived param inert, no keyframe), W9e (count absent from payload), W9b (no
  overlay on the named condition).
- **Not an auth bug:** real auth is healthy.
- **Sequencing:** all five are independent surfaces (parallel-capable). W9e's
  dependency (W3a) is satisfied. W9a is the only one needing a vision-enabled
  deploy to fully verify.
