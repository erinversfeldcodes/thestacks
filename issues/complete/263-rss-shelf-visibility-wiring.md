# Issue #263: US-6.1 RSS — wire real shelf visibility into the bookshelf page

## Summary
`frontend/src/Page/Bookshelf.elm:190` hardcodes `visibility = "platform"` at init and never
updates it, so `Components/RSSLink.elm`'s platform-only gate is dead in the running app: the RSS
icon renders on **every** owner shelf regardless of the shelf's real visibility. Lift the
bookshelf's real `visibility` from the server (add it to `BookshelfController.show`'s response +
the Elm decoder, and set `model.visibility` in `ShelvesLoaded (Ok …)`) so the gate is driven by
real data and #119's named "RSS hidden for private shelf" behaviour becomes reachable.

## User Stories
US-6.1 (RSS feed for a bookshelf). Implementation fix spun out of #119's feature-completeness
pre-check.

## Goal
The RSS affordance on the owner's own bookshelf page renders **only** when the bookshelf's real
visibility is `platform`, and is hidden for any non-platform bookshelf (`owner`, `group`,
`public`). `model.visibility` reflects the server's actual `op.visibility_level` value for that
bookshelf, not a hardcoded literal. #119's "RSS hidden for private shelf" behaviour is now
provable by an Elm program test.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- More than 3 controllers? **No** — one (`BookshelfController.show`), a one-field addition. ✓
- More than 2 new endpoints? **No** — 0 new; the existing `GET /api/bookshelves/:name` response
  gains one field. ✓
- Exceeds ~300 lines of production code? **No** — ~2 lines Elixir + ~15 lines Elm (new response
  record + decoder + model wiring). ✓
- Combines unrelated concerns? **No** — single concern: wire real visibility into the RSS gate. ✓

**Verdict: within all limits (~S).**

## Wiring
Includes API/UI wiring — adds a bookshelf-response `visibility` field and drives the RSS gate;
user-facing on completion.

**Contract change:** this changes the shape of the `GET /api/bookshelves/:bookshelf_name` JSON
response (adds a top-level `visibility` field). Contract-reviewer must confirm the additive change
and that the Elm decoder stays tolerant of older/absent payloads. No `.proto` change — the
bookshelf-list response is hand-serialized in `ProtoJSON`/the controller, not proto-generated.

## Feature-Completeness Pre-Check
US-6.1 RSS is **built** end-to-end — feed endpoint (`/api/feeds/:userId/:bookshelfName`), the
`RSSLink` component, and its render site all exist. The single missing hop is the visibility
**wiring** this issue closes. Not a de-scope candidate; a small implementation fix.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-6.1 RSS feed affordance | `Page/Bookshelf.elm:284-292` renders `RSSLink.view` (owner mode) → `RSSLink.elm:33` gates on `visibility == "platform"` → **`Page/Bookshelf.elm:190` hardcodes `"platform"`, `ShelvesLoaded` (`:207-213`) never updates it** → gate always passes | ⬜ to verify (browser drive is #119) | 🟡 partial — 1 broken hop (visibility never lifted from server) | Build in-scope (this issue) |

Verdict: 🟡 partial — the one broken hop is exactly this issue's deliverable.

## Technical Requirements

### Backend — add `visibility` to the bookshelf-list response
- `apps/core/lib/stacks_web/controllers/bookshelf_controller.ex:74-78`
  (`render_visible_bookshelf/5`): add `visibility: bookshelf.visibility` to the response map
  `%{bookshelf, count, shelves}`. `bookshelf` is the loaded `Stacks.Shelving.Bookshelf` struct
  whose `.visibility` is the `op.visibility_level` enum (`"owner"` default, `"group"`, `"platform"`,
  `"public"` — created in `20260305000002_create_users.exs:13`, `"public"` added in
  `20260715130000_add_public_to_visibility_level.exs`).
- `bookshelf_controller.ex:56-59` (`render_bookshelf/4`, the `nil` branch — bookshelf does not exist
  yet): emit `visibility: "owner"` (the enum default) so the field is always present. An absent
  bookshelf is non-platform → RSS stays hidden, which is correct.
- **Investigation result (do NOT derive from placements):** `ProtoJSON.placement_detail/1`
  (`proto_json.ex:238-255`, used by `shelf_with_placements/2`) emits each placement's **own**
  `visibility` but **not** `bookshelf_visibility` — that denormalised field only rides the
  single-book `book_placement/1` detail payload (`proto_json.ex:291-292`), never the bookshelf-list
  payload. So a top-level `visibility` on the response is the clean source; there is nothing to
  derive from.

### Frontend — decode it and set `model.visibility`
- `frontend/src/Types/Shelf.elm:22-24`: `shelvesResponseDecoder` currently decodes only
  `Decode.field "shelves"` and returns `List Shelf`. Introduce a response record that also carries
  visibility, e.g. `{ shelves : List Shelf, visibility : String }`, decoding `visibility` with a
  tolerant default (`Decode.oneOf [ Decode.field "visibility" Decode.string, Decode.succeed "owner" ]`)
  so an older/absent payload does not fail the decode.
  - **Reuse caution:** `shelvesResponseDecoder` is also used by the public-profile shelf fetch
    (`Api.elm:2297-2305`, `getPublicBookshelf`). That path is `readOnly` and never renders RSS
    (`Page/Bookshelf.elm:278-282`), so it does not need visibility. Prefer a **new** response
    type/decoder for `getBookshelf` and leave `shelvesResponseDecoder` (public path) unchanged,
    rather than widening the shared decoder and rippling into the public-profile path.
- `frontend/src/Api.elm:793-807` (`getBookshelf`): change its result type from
  `Result Http.Error (List Shelf)` to the new response record and decode with the new decoder.
- `frontend/src/Page/Bookshelf.elm`:
  - `:207-213` (`ShelvesLoaded (Ok response)`): set `model.visibility = response.visibility`
    alongside `shelves = Success response.shelves` (currently only `shelves` is set).
  - `:190`: drop the hardcoded `visibility = "platform"` at init (a Loading-state placeholder is
    fine, but it must be overwritten on load).
  - Confirm the render site `:284-292` still passes `visibility = model.visibility` into
    `RSSLink.view` in owner mode (`not cfg.readOnly`) — it does; no change needed beyond the model
    now holding real data.
- `frontend/src/Components/RSSLink.elm:33`: no change — the gate `if config.visibility /= "platform"`
  is already correct; it was just fed a constant. (Note for reviewer: this makes RSS
  platform-**only**, so a `public` bookshelf also hides RSS. That is the existing intended gate;
  broadening it to `public` is out of scope.)

## Reviewer Context
- `op.visibility_level` enum ladder: `owner` (default) < `group` < `platform` < `public`. RSSLink's
  gate is `== "platform"` exactly — not `>= platform` — so `public` shelves currently hide RSS by
  design. Do not "fix" that here.
- The bookshelf-list response is **not** proto-generated — it is assembled in `BookshelfController`
  + `ProtoJSON.shelf_with_placements/2`. Adding a top-level field needs no `.proto`/`buf` change.
- `shelvesResponseDecoder` is shared with the public-profile shelf path; keep that path untouched
  (see Reuse caution above).
- Bookshelf domain term: `op.bookshelves` (`Stacks.Shelving.Bookshelf`) is the "shelf" the RSS icon
  belongs to; the physical `op.shelves` rows are a separate concept and irrelevant here.

## Test Audit
<!-- Compact format — a targeted wiring fix; two layers apply, rest n/a. -->

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 10 — Elm state machine (`Page.Bookshelf`) | yes | ❌ needed — program test: RSS icon (`.rss-link__button` / `.rss-link`) **renders** when `ShelvesLoaded` carries a `"platform"` bookshelf, and is **absent** for a non-platform (`"owner"`) bookshelf. This is the exact #119 "RSS hidden for private shelf" behaviour, now testable. Add to `frontend/tests/Page/BookshelfShelvesTest.elm` (extend `simulateShelvesResponse` to emit top-level `visibility`).  (→ ✅ when both cases pass) |
| 1 — API contract (`bookshelf_controller_test.exs`) | yes | ❌ needed — assert `GET /api/bookshelves/:name` response includes top-level `"visibility"` and that it equals the bookshelf's real value (e.g. a `platform` bookshelf → `"platform"`; an `owner` bookshelf → `"owner"`). Add to `apps/core/test/stacks_web/bookshelf_controller_test.exs` (existing `insert(:bookshelf, …, visibility: …)` fixtures at `:118/:137/:167`).  (→ ✅ when both cases assert) |
| 2 — auth/middleware guards | no | n/a — no auth change; existing `Guardian` + `ViewAsPlug` path untouched. |
| 3 — DB interactions | no | n/a — reads an existing column; no schema/migration change. |
| 4 — event flow | no | n/a — no event emitted or changed. |
| 5 — Oban jobs | no | n/a. |
| 6 — external service calls | no | n/a. |
| 7 — storage | no | n/a. |
| 8 — cache | no | n/a. |
| 9 — dbt models | no | n/a — no warehouse surface; visibility already staged. |
| 11/12 — operational metrics / performance | no | n/a — covered by SLO gate; no new metric. |
| 13 — cost tracking | no | n/a. |

**Punch list**
1. Layer 10 — `frontend/tests/Page/BookshelfShelvesTest.elm`: `rss_icon_renders_for_platform_shelf`
   (owner-mode library program, `ShelvesLoaded` with top-level `visibility: "platform"` →
   `expectViewHas [ Selector.class "rss-link" ]`).
2. Layer 10 — same file: `rss_icon_hidden_for_non_platform_shelf` (`visibility: "owner"` →
   `expectViewHasNot [ Selector.class "rss-link" ]`). Requires `simulateShelvesResponse` to emit
   the new top-level field.
3. Layer 1 — `apps/core/test/stacks_web/bookshelf_controller_test.exs`:
   `returns bookshelf visibility in response` (assert `resp["visibility"] == "platform"` for a
   platform bookshelf and `"owner"` for an owner bookshelf).

**Validation path per behaviour**
- "RSS shown for platform / hidden for non-platform" → Layer-10 Elm program test (both cases). The
  live browser drive of this behaviour belongs to **#119** (its E2E), not this issue.
- "response carries real `visibility`" → Layer-1 controller test.

**Verdict:** baseline ❌ — 0 passing of 3 target cells; feature hop exists, tests + wiring missing.

## Definition of Done
- [x] `BookshelfController.show` response includes top-level `visibility` — evidence: `bookshelf_controller_test.exs` (3 cases: platform/owner/absent→"owner"), 28/0; commit `f58bebf1`
- [x] `getBookshelf` decodes `visibility` and `ShelvesLoaded (Ok …)` sets `model.visibility`; init no longer hardcodes `"platform"` (→ `"owner"`) — evidence: diff `f58bebf1` (`Page/Bookshelf.elm`, `Api.elm`, `Types/Shelf.elm` new `BookshelfResponse`)
- [x] RSS icon renders for a `"platform"` shelf and HIDDEN for non-platform — evidence: `BookshelfShelvesTest.elm` show/hide program tests GREEN; **live-driven** `rss.spec.ts` 5/5 (icon show + hide)
- [x] Public-profile shelf path unchanged and GREEN — evidence: `BookshelfReadOnlyTest.elm` 8/8; shared `shelvesResponseDecoder` byte-unchanged
- [x] Contract change reviewed — evidence: contract-reviewer APPROVED (additive `visibility`, tolerant decoder, profile path intact)
- [x] **Feature-Completeness Pre-Check ✅** — the broken visibility hop closed; RSS gate driven by real server data — evidence: `rss.spec.ts` "hidden for non-platform" GREEN live
- [x] Every behaviour has a validation path — Layer 10 (Elm program) + Layer 1 (controller) + #119 `rss.spec.ts` browser live-drive — evidence: 5/5 local
- [x] Tests written and passing — evidence: elm 864/0 + `bookshelf_controller_test.exs` 28/0
- [x] Standards compliance (`just verify` passes; GDPR N/A) — evidence: integration verify GREEN (elixir 2749/0, elm 864/0, dbt 295)
- [x] **Test audit GREEN** — 3 target cells ✅ — evidence: BookshelfShelvesTest + bookshelf_controller_test
- [x] **`completion-audit` passed on the integrated branch** — evidence: epic-wide completion-audit 2026-07-20
- [x] **Meets the Completion Bar** — RSS show/hide observed live (`rss.spec.ts` 5/5, "hidden for private" GREEN), logs clean — evidence: local live-drive; commit `f58bebf1`

### GDPR
**N/A — no new personal data.** Shelf `visibility` is an existing `op.visibility_level` column
already stored, exported, and erasable via the bookshelf record; this issue only **surfaces** it in a
response the owner already receives. The endpoint returns the **authenticated owner's own** bookshelf
(`Guardian.Plug.current_resource` + `ViewAsPlug`; third-party viewers are visibility-gated to 404 at
`bookshelf_controller.ex:66-68`), so exposing `visibility` leaks nothing private — the owner already
sets and sees this value. No new event/audit/warehouse surface. gdpr-review lens: nothing to add to
`GDPR.Deletion`/`GDPR.Export`; no `ConsentCheck` gate required.

## Dependencies
None to start. **Feeds #119** (e2e-auth / RSS feature-completeness) — this closes the broken hop #119
identified; #119's browser E2E is the live-drive for the show/hide behaviour.

## Agent Assignment
- **elm-agent** — response record + decoder (`Types/Shelf.elm`, `Api.elm`), `ShelvesLoaded` wiring
  and init cleanup (`Page/Bookshelf.elm`), the two Layer-10 program tests.
- **elixir-agent** — add `visibility` to `BookshelfController.show` response + the Layer-1 controller
  test.
- **contract-reviewer** — sign off on the additive response-shape change and decoder tolerance.

## Progress Notes
[Updated by agents during execution.]
