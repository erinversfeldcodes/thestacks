# US-8.6 — See What Your Own Data Reveals About You

## 1. User Story

> **As a** signed-in reader, **I want to** see what can be worked out about me from my own shelf behaviour — including how identifiable I am — **so that** I can make an informed decision about what I put on this platform.

**Retro-story (spec-of-record).** This surface shipped in Issue #242 against [ADR-019 §3a](../decisions/019-radical-transparency-metrics.md) and had no story file. Written 2026-08-06 from the code, not from a plan: every claim below cites the implementation.

**What the user wants to accomplish:** Most platforms tell you what data they hold. This one tells you what that data *means* — the interests it implies, the reading habits it exposes, and whether the combination of books on your shelves is rare enough to identify you even though The Stacks never asked for your name.

**How they accomplish it:**
1. From Settings, under the "Your data" group, the reader clicks **"Your Data Insights"** (`frontend/src/Page/Settings.elm:78`).
2. `/me/insights` loads and immediately fetches the reader's own payload.
3. Three sections render as **fact**: their interests, how they read, and whether they could be re-identified.
4. A fourth section is withheld behind a button — "Show me what could be inferred" — because it illustrates sensitive guesses a third party might make.
5. Clicking that button re-fetches the same endpoint with `?reveal_risk=true` and the illustrations appear, each captioned as an illustration rather than a claim.

**What they see on the page:**
- Title "What your data reveals", then the promise the page has to keep: *"This is computed live from your own records, just for you. **Nothing on this page is stored** — it is worked out fresh each time you visit and then forgotten."* (`Page/Insights.elm:128-133`)
- "Your interests" — "Your shelf is mostly: …" plus the recurring BISAC codes.
- "How you read" — books shelved / finished / abandoned, abandonment rate, typical days to finish, most active hour.
- "Could you be re-identified?" — a verdict headline (one of four), then the explanation sentence the server composed.
- "What a third party could infer" — a gate, then (on request) captioned illustrations.

**Acceptance Criteria:**
- Strictly own-only: no parameter selects another reader's data.
- Nothing computed here is persisted — not to `op.*`, not to `wh.*`, not to `event_log`.
- The sensitive section is server-enforced, not merely hidden client-side.
- Facts are labelled as facts; inferences are labelled as illustrations.

---

## 2. UI Interaction Flow

### Happy Path
1. Reader is signed in and navigates to `/me/insights` (auth-gated — `Main.requiresAuth` is a whitelist of public routes with a `_ -> True` fallthrough at `Main.elm:866-867`, and `Insights` is not on the whitelist).
2. `Page.Insights.init (Just token)` sets `data = Loading` and fires `Api.getInferences False token InferencesReceived`.
3. `GET /api/me/inferences` returns the three fact sections.
4. `InferencesReceived (Ok payload)` → `data = Success payload`; the three sections render.
5. Reader clicks "Show me what could be inferred" → `RevealRiskRequested` → `riskLoading = True` → `Api.getInferences True token RiskRevealReceived`.
6. `GET /api/me/inferences?reveal_risk=true` returns the same payload **plus** `risk_inferences`.
7. `RiskRevealReceived (Ok payload)` replaces the whole payload; `viewRisk` now matches `Just inferences` and renders `viewRiskRevealed`.

### Sad Paths
- **Not signed in**: the route is auth-gated, so `Main` redirects before the page mounts. If the page is somehow reached with no token, `init Nothing` sets `data = NotAsked` and the content area renders nothing (`Page/Insights.elm:69-76`, `141-142`).
- **Session expired mid-load**: `Api.isUnauthorized err` → `OutMsg SessionExpired`; `Main` handles the bounce. Both the initial fetch and the reveal fetch do this (`Page/Insights.elm:88-89`, `114-115`).
- **Fetch failed**: `data = Failure err` → "This could not be loaded right now. Please try again."
- **Reveal failed**: `riskError = True` and the gate stays put with "That could not be loaded. Please try again." — the gate is deliberately not replaced, so the reader can retry the same button.
- **Too little shelf data to fingerprint**: fewer than two distinct books → `uniqueness = "insufficient_data"`, and the headline reads "Not enough on your shelves yet." (`Stacks.Insights:229-237`)
- **Fingerprint query unavailable** (mart missing, DB hiccup): `others_sharing_all = nil` → `uniqueness = "unknown"` → "We couldn't work this out right now. … Nothing has been recorded either way." A degraded read never becomes a misleading number (`Stacks.Insights:287-312`).
- **Empty subject list**: "Shelve a few more books and your subject profile will appear here."

### Elm State Machine
- **Page module**: `Page.Insights`
- **Model fields involved**: `token : Maybe String`, `data : RemoteData Http.Error PersonalInferences`, `riskLoading : Bool`, `riskError : Bool`
- **Msg flow**: `init → InferencesReceived` · `RevealRiskRequested → RiskRevealReceived`
- **RemoteData states**: `NotAsked` (no token) → `Loading` → `Success payload` / `Failure err`
- **OutMsg pattern**: `NoOut` | `SessionExpired`

⚠️ `riskLoading`/`riskError` are separate booleans rather than a second `RemoteData`, because the reveal does not replace the page's data with a loading state — the three fact sections must stay on screen while the fourth is being fetched.

---

## 3. API Calls

### `GET /api/me/inferences`
- **Auth**: Required
- **Pipeline**: `:api` → `:authenticated` (`apps/core/lib/core_web/router.ex:253`)
- **Controller**: `StacksWeb.MeInferenceController.index/2`
- **Query params**: `reveal_risk=true` — the only parameter, and it selects a *section*, never a subject
- **Response (success)** — HTTP 200:
  ```json
  { "interest_profile": { "top_subjects": [{"subject": "…", "count": 3}],
                          "top_bisac":    [{"code": "FIC019000", "count": 2}] },
    "behaviour":        { "books_shelved": 12, "books_finished": 4, "books_abandoned": 1,
                          "abandonment_rate": 0.083, "median_days_to_finish": 21,
                          "most_active_hour": 22 },
    "deanonymisation":  { "sample_size": 5, "others_sharing_all": 0,
                          "uniqueness": "unique", "explanation": "…" },
    "generated_at":     "2026-08-06T…Z",
    "risk_inferences":  [ … ]   // present ONLY with ?reveal_risk=true
  }
  ```
- **Response (error)**: `401` from the `:authenticated` pipeline. There is no 403 and no 404 — the resource is always the caller.

⚠️ **The subject is `Guardian.Plug.current_resource/1` and nothing else.** There is no `:id` in the path, no `user_id` in the query, and no code path in `Stacks.Insights` that takes one. That is the story's central guarantee, stated in the controller's own moduledoc (`me_inference_controller.ex:6-10`).

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` → `AuthPipeline` (`:authenticated`)
- **Visibility checks**: N/A — own-only by construction, so there is no viewer/subject distinction to resolve.
- **Age gate**: N/A
- **Ownership checks**: structural. Every query in `Stacks.Insights` is hard-scoped to `user.id`: the placement read joins through `Bookshelf` on `bs.user_id == ^user_id` (`insights.ex:78-97`), the history read first collects the user's own bookshelf ids (`insights.ex:101-114`), and the fingerprint query binds `user_id` as `$2` with `bs.user_id <> $2::uuid` (`insights.ex:288-297`).
- **Consent gate**: the `risk_inferences` section is gated **server-side** on `params["reveal_risk"] == "true"` (`me_inference_controller.ex:24-27`) and omitted from the map entirely otherwise (`insights.ex:67-71`). Hiding it in Elm alone would make "we only show them if you ask" a convention.

---

## 5. Database Interactions

Every interaction is a **read**. This story has no write.

### Read: the reader's active placements + their books' subjects
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves` JOIN `op.books`
- **Query**: `where is_nil(p.removed_at)`, scoped by `bs.user_id == ^user_id`; selects `book_id`, `subjects`, `bisac_codes`, `reading_status`, `started_at`, `finished_at`, `placed_at`, `bookshelf_name`
- **Schema modules**: `Stacks.Shelving.Placement`, `Stacks.Shelving.Bookshelf`, `Stacks.Books.Book`

### Read: the reader's placement-history timestamps
- **Table(s)**: `op.bookshelf_placement_history`
- **Query**: `where h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids`, selecting `moved_at` only
- **Schema module**: `Stacks.Shelving.PlacementHistory`
- **Note**: history rows reference bookshelf UUIDs rather than a user, so the scope is applied by first resolving the reader's own bookshelf ids.

### Read: community read counts for the fingerprint set
- **Table(s)**: `wh.mart_community_read_count`
- **Query**: one raw `SELECT book_id::text, read_count … WHERE book_id = ANY($1::uuid[])` for the whole shelf
- **Why raw + batched**: a per-book `Books.community_read_count/1` would be an N+1 over an unbounded shelf. A missing mart degrades to an empty map (all-zero, deterministic ordering by id) rather than raising (`insights.ex:267-281`).

### Read: how many other readers share all of the fingerprint books
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `GROUP BY bs.user_id HAVING count(DISTINCT p.book_id) = $3`, excluding the caller
- **Parameters**: `$1` book ids (from the caller's own shelf, never from request params), `$2` caller id, `$3` sample size
- **Degradation**: any error → `nil` → `uniqueness: "unknown"`, logged at warning

### Write: none — and that is the invariant
⛔ Nothing in this story writes an inference, a profile, or a rarity row. Persisting derived sensitive inferences would create a new special-category PII store needing its own erasure, export, and consent path — the exact outcome ADR-019 §3a exists to avoid. Stated as an invariant in the context's moduledoc (`insights.ex:14-18`) and asserted by the page copy the reader is shown.

---

## 6. Event Flow & Lifecycle

### Events Emitted
**None.** Deliberately. An `event_log` row naming the subjects a reader was shown inferences about would put the very data this feature refuses to persist into the immutable log — where GDPR erasure can only scrub payloads, not delete rows. A read of your own data is not a state change.

### Event Handlers Triggered
None.

---

## 7. Background Jobs (Oban)

None. The payload is computed synchronously per request. A job would need somewhere to put its result, which is the thing this story will not do.

---

## 8. External Service Calls

None. No LLM is involved: `risk_inferences` are templated from the reader's own top subjects (`insights.ex:211-222`), so there is no third party to send a shelf to, no cost, and no hallucination surface.

---

## 9. Storage (R2 / Local)

N/A.

---

## 10. Cache Interactions

None. Caching would mean holding a computed inference set somewhere with a lifetime, which is persistence with a shorter name. Recomputed per request.

---

## 11. dbt Model Dependencies

### `mart_community_read_count`
- **Model**: `mart_community_read_count` (incremental table)
- **Trigger**: refreshed by `DbtRefreshHandler` on `placement.created` / `placement.removed` / `placement.restored` — not by anything in this story
- **Consumer**: the rarity ordering in `Insights.rarest_books/1`
- **Read-only, and optional**: its absence degrades the fingerprint to a deterministic by-id ordering rather than failing the page.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Insights`
- **URL**: `/me/insights` (`Navigation/Route.elm:85` parser, `:168-169` path)
- **Public or authenticated**: authenticated, via `Main.requiresAuth`'s `_ -> True` fallthrough (`Main.elm:866-867`)
- **Sidebar highlighting**: `Route.isSettingsRoute Insights = True` (`Navigation/Route.elm:270-271`) — which is why the page keeps the settings chrome even though its URL is `/me/insights` rather than `/settings/...`

### Init
- **`initPage` branch**: `Page.Insights.init maybeToken`
- **API calls on init**: `GET /api/me/inferences` (no `reveal_risk`)
- **Initial model state**: `data = Loading` with the request that resolves it; `riskLoading = False`; `riskError = False`

### Update cycle
| Msg | Model change | Cmd |
|-----|--------------|-----|
| `InferencesReceived (Ok p)` | `data = Success p` | — |
| `InferencesReceived (Err e)` | `data = Failure e`, or `SessionExpired` on 401 | — |
| `RevealRiskRequested` | `riskLoading = True`, `riskError = False` | `Api.getInferences True token` |
| `RiskRevealReceived (Ok p)` | `data = Success p`, `riskLoading = False` | — |
| `RiskRevealReceived (Err e)` | `riskLoading = False`, `riskError = True`, or `SessionExpired` on 401 | — |

### View
- **Key elements**:
  - `Loading`: "Working out what your data reveals..."
  - `Failure`: "This could not be loaded right now. Please try again."
  - `Success`: four sections — interests, behaviour, de-anonymisation, risk
  - De-anonymisation headline branches on `uniqueness`: `"unique"` → "On this platform, you are a fingerprint." · `"rare"` → "Your reading is close to unique here." · `"common"` → "You blend into the crowd — for now." · `"insufficient_data"` → "Not enough on your shelves yet." · anything else → "We couldn't work this out right now."
  - Risk section: gate with "Show me what could be inferred" (label becomes "Revealing…" while `riskLoading`), or, once revealed, the caveat *"These are illustrations, not facts."* followed by the list
- **ARIA attributes**: none beyond the semantic `h1`/`h2`/`ul`/`button` structure. **Gap:** the reveal is a content injection with no `aria-live`, so a screen-reader user gets no announcement that the section appeared. Worth an accessibility follow-up (US-19.1.x family).
- **CSS classes** (all present in `frontend/css/main.css`): `page--insights`, `insights__intro`, `insights__sections`, `insights__section`, `insights__section--deanon`, `insights__section--risk`, `insights__section-title`, `insights__section-desc`, `insights__fact`, `insights__empty`, `insights__bisac`, `insights__list`, `insights__list-item`, `insights__code`, `insights__stats`, `insights__stat`, `insights__stat-label`, `insights__stat-value`, `insights__deanon-headline` (+ `--unique`/`--rare`/`--common`/`--insufficient`/`--unknown`), `insights__deanon-verdict`, `insights__deanon-explanation`, `insights__risk-gate`, `insights__risk-reveal`, `insights__risk-revealed`, `insights__risk-caveat`, `insights__risk-list`, `insights__risk-item`, `insights__risk-label`, `insights__risk-could`, `insights__risk-basis`
- **Test ids**: `insights-page`, `insights-interest`, `insights-behaviour`, `insights-deanon`, `insights-deanon-explanation`, `insights-risk`, `insights-reveal-risk`, `insights-risk-revealed`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/me/inferences"}` | Phoenix.Telemetry | Counter | Per request; split by `reveal_risk` presence | Volume baseline |
| `reveal_risk.rate` | Phoenix.Telemetry | Gauge (%) | Requests carrying `reveal_risk=true` / total | Informational — how many readers opt in to the sensitive section |
| `db.query.duration{query="insights.count_others_sharing_all"}` | Ecto.Telemetry | Histogram (ms) | The `GROUP BY … HAVING` fingerprint query | p95 < 150ms |
| `db.query.duration{query="insights.community_read_counts"}` | Ecto.Telemetry | Histogram (ms) | The batched mart read | p95 < 50ms |
| `insights.degraded.count` | Logger warning | Counter | `Insights.community_read_counts failed` / `count_others_sharing_all failed` warnings | 0 in steady state; > 0 means readers are seeing `"unknown"` |
| `http.response.status{endpoint="/api/me/inferences", status=401}` | Phoenix.Telemetry | Counter | Unauthenticated attempts | Informational |
| **Rows written** | SQL | Invariant | `op.*` / `wh.*` / `event_log` row deltas attributable to this endpoint | **Exactly 0** — the zero-write property is the metric, and a non-zero value is a defect |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `insights.load_time` | Elm Performance API | Histogram (ms) | `init` → `InferencesReceived` | p50 < 400ms, p95 < 1.2s |
| `insights.reveal_time` | Elm Performance API | Histogram (ms) | `RevealRiskRequested` → `RiskRevealReceived` | p95 < 1.2s (same query plus a template pass) |
| `insights.uniqueness_distribution` | Derived from responses | Histogram | Share of readers classified `unique` / `rare` / `common` / `insufficient_data` / `unknown` | Informational — but a rising `unknown` share means the mart or the query is degrading |
| `insights.insufficient_data_rate` | Derived | Gauge (%) | Readers with < 2 distinct books | Falls as the platform fills; high on a fresh install by design |
| `insights.reveal_error_rate` | Elm event tracking | Gauge (%) | `RiskRevealReceived (Err _)` / `RevealRiskRequested` | < 2% |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Page views | All aggregation (`Enum.frequencies`, medians, top-N) happens in the BEAM over the reader's own shelf. Bounded by shelf size. |
| Neon DB | Compute Units per request | Page views × 4 queries | Two Ecto reads (placements, history) + two raw SQL reads (mart batch, fingerprint `GROUP BY … HAVING`). The fingerprint query is the expensive one — it groups over `op.bookshelf_placements` filtered to five book ids. |
| Neon DB | Write IOPS | — | **Zero.** No INSERT, UPDATE, or DELETE on any path. |
| LLM / external API | — | — | **Zero.** `risk_inferences` are string templates over the reader's own subject clusters; no model is called. |
| Object storage | — | — | N/A |

**Cost shape worth noting:** because nothing is cached and nothing is stored, cost is strictly per view — the deliberate trade for the zero-persistence guarantee. If this ever becomes hot, the answer is to bound the fingerprint query, not to memoise the result.

---

## 16. Relationship to the Public Transparency Surfaces

This story is the **authenticated, own-only** half of radical transparency. Its public counterparts are separate stories and must not be conflated with it:

- **US-5.1 (metrics dashboard)** — platform-wide operational metrics. Per ADR-021 and #267 the in-app dashboard was superseded by the self-hosted push-metrics stack (VictoriaMetrics + Grafana); `Page.Metrics` and `Api.getTransparencyMetrics` remain the public transparency read.
- **`Page.CostTransparency`** — the platform's own running costs, public, aggregate, no reader in it.
- **ADR-019 §3 (the de-anonymisation boundary)** — why the *public* marts cannot carry per-reader rarity: they would enable de-anonymisation by correlation. This story computes rarity for one reader, about themselves, and throws it away. That asymmetry is the whole design, and it is the reason this surface is authenticated rather than a public page with a login prompt.
- **ADR-019 §3a note "Future: the owner-only de-anonymisation-education view (linked accounts) under the profile"** — not built, not in this story.
