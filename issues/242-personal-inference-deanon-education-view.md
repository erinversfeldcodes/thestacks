# Issue #242: Personal inference & de-anonymisation education view (authed, own-only)

## Summary
An authenticated, **own-only** transparency surface that shows a signed-in user **only their own**
data-derived inferences, to educate on **(a) what can be inferred about them** from their behaviour and
**(b) how they could be de-anonymised even though the platform keeps no PII.** The authed counterpart to
the public `/metrics` page (#235). Design: **ADR-019 §3a**. Child of epic **#231**.

## User Stories
US-8.x (data transparency / GDPR education) — "As a user, I want to see what can be inferred about me
and how I could be re-identified, so I can make informed choices." Child of **#231**.

## Goal
A signed-in user opens their personal transparency view and sees, computed live from *their own*
records: their real interest/behaviour profile, clearly-labelled *risk* inferences, and a concrete
**de-anonymisation demonstration** (a uniqueness/fingerprint score from their own shelf vs the corpus) —
with plain, empowering explanations. **No inference is persisted; no other user's data is ever reachable.**

## Scope Check
- >3 controllers? No (one `PersonalTransparencyController` + a `Stacks.Transparency.Personal` context).
  >2 endpoints? No (one authed own-only GET; maybe a consent-to-view toggle). >300 LOC? Borderline —
  the inference derivations + rarity score + serializer; keep lean, split derivations if it grows.
  Mixed concerns? No — one concern: the personal inference/de-anon view.

## Wiring
- [x] User-facing + router wiring — an authed route under the profile/settings.

## Feature-Completeness Pre-Check
This is a NEW feature (no such view exists). Design is done (ADR-019 §3a); this builds it. Its own
validation paths are the own-only-authz, no-persistence, and rarity-computation tests below.

## Technical Requirements

### 1. Own-only surface
- An authed route (e.g. `GET /api/me/inferences`, page under `/settings/your-data` or the profile).
  **Every query hard-scoped to `current_user.id`** — no parameter, path, or code path can select
  another user. This is the primary invariant.

### 2. Ephemeral inference derivation (compute-and-display, NEVER persist)
Derive from the user's EXISTING records (own-only), on the fly, returning a display payload — **do not
write any inference/profile table**:
- **Interest/subject profile** — top genres/BISAC subjects from shelved books (real, shown as fact).
- **Behavioural patterns** — reading pace / abandonment / activity-time from placement history
  timestamps (real, factual).
- **Risk inferences** — clearly labelled *"what a third party could infer"*: e.g. sensitive-topic
  interest from subject clusters. **Labelled as illustration, never asserted or stored.**

### 3. De-anonymisation demonstration (the point of the feature)
- Compute a real **uniqueness/rarity score**: e.g. how many other readers share the user's top-N
  shelved books (from aggregate corpus popularity) → "0 others share your top-5; your combination is
  unique here." A concrete k-anonymity-style fingerprint from the user's own data vs the corpus aggregate.
- Explain plainly: this fingerprint could be cross-referenced with public data (a Goodreads profile, a
  tweet about a niche book) to re-identify them — **no PII needed.** That is the lesson.

### 4. Consent-to-view + tone
- Gate the sensitive-inference section behind an explicit "show me what could be inferred" action
  (informed choice; some illustrations touch special-category topics).
- Tone: educational + empowering, not alarmist/manipulative (ADR-019 §3a); plain + direct; placeholder
  prose (owner refines).

## Reviewer Context
- **Security-critical — own-only:** no cross-user path. A test MUST prove user A cannot see user B's
  inferences by any parameter/route manipulation. Route through platform-reviewer + security lens.
- **GDPR-critical — no new PII store:** inferences are computed ephemerally and NOT persisted.
  Persisting derived sensitive inferences would create a new special-category data category needing its
  own erasure/export/consent — explicitly avoided. Route through gdpr-review. Confirm nothing is written
  to `op.*`/warehouse as a derived-inference record.
- The rarity score reads aggregate corpus popularity (fine) + the user's own shelf (their data) — no
  other user's individual data.
- Distinct from the public `/metrics` page (#235, aggregate/anonymised) and from ops Grafana (#232, full firehose).

## Test Audit
_Compact — a new authed feature; load-bearing: own-only authz, no-persistence, derivation correctness._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Own-only authz (no cross-user leak) | yes | ❌ (→ ✅ test: A cannot reach B's inferences by any means; unauth → 401) |
| No-persistence (ephemeral, no inference store) | yes | ❌ (→ ✅ test: after a view request, no new inference/profile row exists in op/warehouse) |
| Interest/behaviour derivation correctness | yes | ❌ (→ ✅ test: seeded shelves → expected top-subjects; timestamps → expected pattern) |
| De-anon rarity score | yes | ❌ (→ ✅ test: a unique shelf → uniqueness=0-others; a common shelf → higher k) |
| Consent-to-view gate | yes | ❌ (→ ✅ test: sensitive section hidden until the explicit action) |
| Elm page (own-only render) | yes | ❌ (→ ✅ elm-test for the view states) |
| Metrics/perf | no | n/a — computed per-request; SLO gate. |

Punch: (1) own-only endpoint + strict authz; (2) ephemeral derivations (no persist); (3) rarity/de-anon demo; (4) consent-to-view gate; (5) Elm page; (6) the security + no-persistence tests.
Verdict: baseline — 6 punch items; own-only-authz + no-persistence are the highest-risk.

## Definition of Done
- [ ] Authed own-only view shows the user's own interest/behaviour profile + labelled risk inferences + a de-anon uniqueness demo.
- [ ] **Strict own-only authz** — test proves no cross-user access by any route/param; unauth → 401.
- [ ] **No persisted inferences** — test proves no derived-inference row is written (op/warehouse) after a view.
- [ ] Sensitive-inference section gated behind an explicit consent-to-view action.
- [ ] Derivation + rarity-score tests (seeded data → expected outputs); Elm view tests.
- [ ] `just verify` passes; test audit GREEN; platform + gdpr reviewed.
- [ ] Meets the Completion Bar — the own-only + no-persistence invariants are real tests, driven live.

## Dependencies
User data model (shelves/placements/subjects — merged); ADR-019 §3a (design). Corpus aggregate for the
rarity score (a small mart or query). Part of the current #118+#231 PR (or a fast-follow — see note).

## Agent Assignment
elixir-agent (own-only context + derivations + rarity) + elm-agent (the view). Reviewers: elixir-reviewer
+ platform-reviewer (own-only authz) + gdpr-review lens (no-persistence / special-category).
