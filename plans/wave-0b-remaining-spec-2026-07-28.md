# Wave 0b — what still needs specifying (G1, G4, G5, G6)

**Date:** 2026-07-28 · **Status:** investigation complete, decisions open
**Purpose:** these four were filed as "wire what is already built". Investigating them shows
that only **one** actually is. The others need scope or design decisions first, and one needs
a user story written before it can be built at all.

---

## Summary — they are four very different problems

| | Filed as | Actually is | Blocked on |
|---|---|---|---|
| **G5** shelf organisation | Frontend wiring | ✅ Exactly that. Backend complete, spec already written in `issues/190` | One UI decision |
| **G4** RSS feeds | Wire `/feeds` + make seeds emit events | 🟡 **Product path already works.** The gap is a *fixture* gap | One general decision about seeds |
| **G6** business opt-out | Add a surface for `POST /api/opt-out` | 🟠 Server done, but its **entry point lives on a surface that does not exist** — depends on G1 | Two scope decisions |
| **G1** third spaces | Route the page + seed the data | 🔴 **No story exists, and nothing can produce the data.** Also a Phase 4 story sitting in a Phase 1 wave | A story, a scope ruling, and a design decision |

---

## G5 — Shelf organisation (US-1.7.1, issue #190)

**This one is genuinely ready.** `issues/190-shelf-organization.md` is a complete spec: it
enumerates the four existing endpoints, names the three missing Elm flows, states the
`422 shelf not empty` sad path, and explicitly rules rename out of scope.

Verified: no `/api/shelves` call exists anywhere in `frontend/src`, so the management UI is
genuinely absent, as the issue says.

### ✅ DECIDED (owner, 2026-07-28): support **both**

> *"we should support both for accessibility and because touch/mouse drag is intuitive to many."*

So drag is not a later enhancement — it ships alongside explicit controls. Consequences to plan
for rather than discover:

- **The issue's own scope check now certainly trips.** It says *"If planning shows >300 LOC, split
  by action (move / reorder / delete) into sub-issues."* Two input methods across three flows will
  exceed that. **Split by action**, and build each action's keyboard/control path and its drag path
  together — splitting by *input method* instead would ship a half-accessible feature and leave the
  keyboard path as follow-up work that never quite lands.
- **Both paths must drive the same Msg.** A drag and a menu selection are the same intent; if they
  diverge into two code paths the model will drift and only one will get tested.
- **E2E covers the control path, not drag.** Playwright drag is flaky, and `e2e/tests/` already
  carries a documented ban on vacuous guards — a flaky drag test that silently passes is worse than
  none. Assert drag at the unit level (the Msg and model transition) and the control path
  end-to-end.
- **Touch needs its own consideration**, since the owner named it: pointer events rather than
  mouse events, and a drag threshold so a tap on a book does not read as a drag.

### Original analysis — the move/reorder affordance

The issue offers both options without choosing: *"drag-between-shelves or a per-book 'move to
shelf…' affordance"*, and *"drag shelf rows or up/down controls"*. The difference is large.

| | Drag and drop | Explicit controls |
|---|---|---|
| Effort | High — pointer events, drop targets, touch, autoscroll | Low — a menu and two buttons |
| Fits the bookcase metaphor | Strongly | Weakly |
| Accessible without extra work | No — needs a keyboard path anyway, so you build both | Yes |
| E2E testability | Awkward (Playwright drag is flaky) | Straightforward |

**Recommendation: explicit controls first**, shipped and driven, with drag as a later
enhancement layered on top. Reasons: an accessible keyboard path is required regardless, so
controls are not throwaway work; and the issue's own scope check warns the three flows are
already borderline against the 300-LOC guidance — adding drag would guarantee a split.

**Second decision:** the issue says split by action if >300 LOC. Explicit controls probably fit
in one; drag would not. Contingent on the above.

---

## G4 — RSS feeds (US-6.1)

**The product path is already wired**, contrary to the wave's framing:

- `Components/RSSLink.elm` **is** mounted in `Page/Bookshelf.elm` — imported, in the model, has
  a `Msg`, initialised, handled in `update`.
- `Stacks.Feeds.Handlers.PlacementHandler` **is** registered in `events/registry.ex`.
- The chain exists: placement event → handler → `RegenerateFeedJob` → `op.feed_cache`.

So a real user moving a real book does generate a feed. Measured in dev:

| | |
|---|---|
| `op.bookshelf_placements` | **220** |
| `op.feed_cache` | **0** |
| `Events.emit` calls in `seeds.exs` | **0** |
| `insert_all` calls in `seeds.exs` | **14** |

The seeds use `insert_all`, which bypasses changesets and therefore events, so no feed is ever
generated in a seeded environment. **That is a fixture gap, not a product gap.**

### Decision needed — and it is bigger than feeds

This is the general case, which is why the wave called it "the systemic cause": **any feature
whose data is produced by an event handler looks broken in a seeded environment.** Feeds are
just the instance we noticed. The options:

1. **Seeds emit events for the rows that have handlers.** Truthful — a seeded environment then
   resembles a used one. Costs: seeding gets slower, and it becomes order-dependent (handlers
   must be registered before the seed runs).
2. **Seeds populate derived tables directly** (write `feed_cache` rows alongside placements).
   Fast and simple, but every future derived table needs remembering, and the seed then encodes
   what the handler *should* produce — a second implementation to drift.
3. **Accept it, and make it visible.** Add an assertion to the zero-row sweep so a derived table
   being empty in a seeded environment is a *known* state rather than a surprise.

**Recommendation: (1) for feeds specifically, plus (3) as the general guard.** Option 2 is the
one to avoid: it is exactly the "second source of truth" shape that caused the `book_id`/
`book_edition_id` and `maybe_assign_owner_role` bugs earlier in this campaign.

⚠️ Worth noting: this makes G4 a **test-infrastructure** issue, not a Phase 1 feature gap. It
should probably leave Wave 0b and become its own issue.

---

## G6 — Business opt-out (US-2.5.3)

Server side is complete: `POST /api/opt-out` → `OptOutController.create` →
`Discovery.opt_out/2`, with email validation and the `excluded` status transition.

The story (`docs/user_stories/US-2.5.3-business-optout.md`) is detailed and specifies more than
the wave item implies:

> Every discovered (non-partner) listing includes a discreet "Is this your business?" link.
> Clicking opens a simple form: business name, contact email, and a choice between "Remove my
> listing" and **"I'd like to become a partner instead."** … The platform owner sees removal
> requests in the **Metrics Dashboard** alongside partner requests.

### ✅ DECIDED (owner, 2026-07-28): a standalone submission form, with contactability for verification

> *"right now, let's have the entry point be a submission form. as part of the form a means of
> contacting the person submitting the form should be included so that we can verify that it is the
> owner of the establishment who is getting in touch to have their content removed. then we need to
> build out the means for removing them."*

This settles Decision 1 (standalone, so G6 no longer waits on G1) and adds a requirement the story
did not state: **the request must be verifiable, not merely received.**

That distinction matters. `Discovery.opt_out/2` currently applies the exclusion immediately on
submission, which means **anyone can delist any business** by knowing its URL. For a form with no
account behind it, that is an abuse vector, not a feature. What the owner is asking for closes it.

**What this implies, and needs building:**

1. **Contact fields on the form.** Business name, contact email, and — worth deciding — a phone
   number and/or the role of the person submitting. Recommendation: email required, phone optional,
   plus a free-text "how are you connected to this business?".
2. **Email round-trip before the exclusion applies.** The submitter must click a signed link, the
   way email confirmation already works (`Phoenix.Token`, `"email_confirm"` salt pattern in
   `Accounts`). Until then the request is *pending*, not applied.
3. ⚠️ **DECIDE — is a confirmed email sufficient?** It proves the submitter controls that mailbox,
   not that they own the business. Stronger: require the contact email's **domain to match the
   listing's website domain** (cheap, no human step, and correct for most small businesses), and
   fall back to owner review where it does not match. Recommendation: take this — it makes the
   common case self-service and the ambiguous case reviewed.
4. **A pending→applied state.** `discovered_sources.status` already has
   `pending_review | approved | dismissed | excluded`. A removal request needs its own pending
   state so a request in flight is distinguishable from one applied. This is a proto + `proto.sync`
   change.
5. **The removal itself** — "the means for removing them". Today `opt_out` sets `excluded` on
   `discovered_sources`, which stops future sweeps re-adding it. But once G1 exists, a
   `third_space` row will also exist, and **excluding the source must remove the space** or the
   listing stays visible. That link does not exist yet.

⚠️ **DECIDE — what "removed" means.** Options: soft-delete the `third_space` (keeps the exclusion
auditable, and `opted_out`/`opted_out_at` columns already exist for exactly this), or hard-delete
it. Recommendation: **soft-delete via the existing columns**, with reads filtering on them — the
audit trail matters for a takedown, and the columns were clearly added with this in mind.

### Original analysis — Decision 1: G6 had no entry point without G1

The link belongs "on every discovered listing", and **no surface renders discovered listings**.
`third_spaces` has 0 rows and the cork board page is unrouted. So either:

- **(a) Sequence G6 after G1** — the honest order, since the story places the link on a listing.
- **(b) Ship the form standalone** at a public URL (e.g. `/opt-out?url=…`), reachable from the
  confirmation email and linkable by hand, with the in-listing link added when G1 lands.

**Recommendation: (b).** It makes the capability real and independently testable, and the story's
"does not require account creation" already implies a standalone public page. The in-listing link
is then a one-line addition to whatever G1 builds.

### Decision 2 — where does the owner see requests?

The story says "Metrics Dashboard". That surface **no longer exists** — superseded by Grafana
(ADR-021, #267). Grafana is a metrics tool and cannot serve a work queue. Options:

- An admin list view in the SPA (new surface, needs its own story slice).
- An email to the owner per request (cheapest, no new surface, fits the existing
  `EmailDeliveryJob` pattern).
- Nothing: the exclusion is applied automatically, so no human step is strictly required.

**Recommendation: email the owner, and record in the story that the dashboard line is superseded.**
The exclusion already takes effect without human action, so the notification is awareness, not a
gate.

### Decision 3 — is the "become a partner instead" branch in scope?

Partner onboarding is **Phase 3**. Offering the choice now would either dead-end or need a
Phase 3 dependency pulled forward.

**Recommendation: ship removal only**, and record the partner branch as deferred to Phase 3 in
the story — so the next audit does not re-report it as a gap.

---

## G1 — Third Spaces cork board (US-3.1.1)

The wave describes this as "route + import the existing page **and** seed/ingest
`third_spaces`; both ends are empty". Both ends are indeed empty, but the reasons are worse than
that framing suggests.

### 🔴 Finding 1 — the story does not exist

`US-3.1.1` has **no file** in `docs/user_stories/`. It appears only as rows in
`implementation-mapping.md`. There is nothing that says what the cork board *is*, what a visitor
does with it, or what "done" means. It cannot be built to spec because there is no spec.

### 🔴 Finding 2 — nothing can produce `third_spaces` rows

The discovery chain exists and stops short:

```
user.location_updated → LocationUpdatedHandler → GeographicDiscoveryJob
                      → SourceDiscoveryJob → op.discovered_sources ✓
                                           → op.third_spaces        ✗ nothing writes this
```

Grepped: nothing inserts a `ThirdSpace` anywhere outside the seeds. `Discovery.approve_source/1`
transitions a `discovered_source` to `approved` but does not promote it into a third space. **The
promotion step is missing entirely** — this is a build, not a wiring fix.

### 🔴 Finding 3 — it is a Phase 4 story in a Phase 1 wave

`implementation-mapping.md:48` puts US-3.1.1 in **Phase 4 (Polish)**. Phase 3 is documented as
*depending* on the cork board, so it is not merely late — it is out of order relative to its own
phase table.

### Decisions needed

1. ~~**Does G1 belong in Wave 0b at all?**~~ Owner is promoting it toward Phase 1 with a much
   larger design (split map + cork board). It leaves Wave 0b regardless — it is no longer a wiring
   task — and becomes its own issue.
2. ✅ **Story written:** `docs/user_stories/US-3.1.1-third-spaces-map.md`, drafted 2026-07-28 with
   the owner's design and six `⚠️ DECIDE` markers (categories/filtering, the ratings source, the
   approval→promotion rule, the Elm port, map tiles and CSP, and lat/lng vs PostGIS).
3. **Design the promotion step.** Given `discovered_sources` already has a
   `pending_review → approved` flow with a `config_generated` column and an owner approval action,
   the natural design is: approving a source of a space-like type creates the `third_space`. That
   needs deciding, because it determines whether a third space can exist without owner review —
   and these are real businesses, so listing one without review is the risk US-2.5.3 exists to
   mitigate.

---

## Recommended sequencing

1. **G5** — ready now, one decision (explicit controls), real user-facing value.
2. **G6 (b)** — standalone public form, removal only. Small, independently testable.
3. **G4** — reclassify as test-infrastructure; fix seeds to emit events and add the zero-row
   guard.
4. **G1** — remove from Wave 0b. Write US-3.1.1, decide the promotion step, then schedule.

**What this changes about the wave:** Wave 0b was framed as six wiring tasks. It is really one
wiring task (G5), one fixture fix (G4), one small build (G6), one thing that needs a story before
it can be built (G1), and two already done (G2, G3). Saying so is the point — "wire what is
already built" was the wrong description for four of the six.
