# The Stacks — Elixir Agent

## Role
Develop and maintain the Phoenix/Elixir core: API endpoints, Oban job workers, event-driven architecture, contexts, supervision trees, and the partner API. This is the heart of The Stacks.

## Technology Stack
- **Framework:** Phoenix 1.7+ (JSON API mode, no LiveView)
- **Language:** Elixir 1.18+ with OTP 28
- **Database:** Ecto for PostgreSQL (3 schemas: op, wh, audit)
- **Job queue:** Oban (job processing + event bus)
- **Auth:** Guardian JWT (HS256)
- **Rate limiting:** GenServer sliding window + token bucket
- **Circuit breakers:** Fuse library
- **Password hashing:** Argon2 (argon2_elixir)

## Owned Domains

### Contexts (bounded domains in `apps/core/lib/stacks/`)
- `Stacks.Books` — CRUD, ISBN resolution, enrichment orchestration
- `Stacks.Shelving` — Bookshelf placements, history tracking, bookshelf transitions
- `Stacks.Partners` — Registration, approval, API key management, inventory/event/space ingest
- `Stacks.Events` — Event bus: emit/1, replay/3, subscriber registry, upcaster
- `Stacks.Enrichment` — Fan-out to scrapers, review aggregation, author intelligence (+ `Stacks.Enrichment.{Authors,Reviews,Prices,PricePipeline,ScraperClient,RssFetcher,Handlers.*}`)
- `Stacks.Moderation` — Content moderation pipeline
- `Stacks.GDPR.{Consent,Deletion,Export,ImageRetention}` — Export, deletion, consent, retention (no umbrella context module)
- `Stacks.Audit` — Immutable audit logging
- `Stacks.Marketplace` — Listings, offers, transactions
- `Stacks.Feeds` — Atom 1.0 feeds for public bookshelves
- Infrastructure modules (`Core.Repo`, `Core.Application`, etc.) live in `apps/core/lib/core/`; do not add new domain code there.

### Controllers (in `apps/core/lib/stacks_web/controllers/`, namespace `StacksWeb.*`)
- `BookController`, `BookshelfController`, `BookshelfPlacementController`, `ShelfController`, `SearchController`
- `PartnerController`, `PartnerRegistrationController`, `PartnerInventoryController`, `PartnerEventController` (flat namespace — no `PartnerAPI.` prefix)
- `AuthController`, `AdminController`, `AdminAuthController`, `OnboardingController`
- `GDPRController`, `MetricsController`, `FeedController`, `UploadController`, `UserSettingsController`
- `BlogController`, `CommentController`, `GroupController`, `GroupFeedController`, `GroupMemberController`, `SocialController`
- `ListingController`, `ThirdSpaceController`, `VisibilityGrantController`, `EmailVerificationController`, `OptOutController`, `CatalogueController`, `CostController`, `BookAvailabilityController`, `SourceAdminController`, `InternalController`

### Oban Workers (in `apps/core/lib/stacks/workers/`, namespace `Stacks.Workers.*`)
- Vision + ISBN: `IdentifyBookJob`, `EnrichBookJob`, `PostBookAssociationWorker`
- Enrichment: `FetchReviewsJob`, `TriggerPriceScrapeJob`, `DiscoverAuthorSourcesJob`, `FetchAuthorRSSJob`, `RecalculateWearJob`
- Discovery: `SourceDiscoveryJob`, `ScoreSourceJob`, `DiscoverBookstoreEventsJob`, `GeographicDiscoveryJob`, `RssLivenessJob`
- GDPR: `DataExportJob`, `AccountDeletionJob`, `ConfirmDeletionJob`, `ImageRetentionJob`
- Feeds & social: `RegenerateFeedJob`, `VisibilityRecapJob`
- Marketplace: `ListingExpiryJob`
- Ops: `CacheSweepJob`, `RefreshCostsJob`, `EmailDeliveryJob`, `DbtRefreshJob`, `DbtRefreshHandler`

### Plugs (in `apps/core/lib/stacks_web/plugs/`)
- `SecurityHeaders`, `RateLimiter`, `AgeGate`, `ConsentCheck`, `DepsCheck`, `RouteGroup`
- `AuthPipeline`, `OptionalAuthPipeline`, `AdminAuthPipeline`, `SseAuthPipeline`, `AuthErrorHandler`
- `PartnerAuthPlug` (API key extraction, hash verification, status check)
- `RequireConfirmedEmail`, `RequireMfa`, `RequireRole`, `ViewAsPlug`
- `MetricsAuth`, `AuditAdminCall`

## Event Bus Pattern

Every significant state change emits an event:

```elixir
# In a context function:
def create_book(attrs) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:book, Book.changeset(%Book{}, attrs))
  |> Ecto.Multi.run(:event, fn _repo, %{book: book} ->
    Stacks.Events.emit(%{
      event_type: "book.created",
      aggregate_type: "book",
      aggregate_id: book.id,
      payload: %{isbn: book.isbn, title: book.title},
      metadata: %{actor: "user:#{attrs.user_id}"}
    })
  end)
  |> Repo.transaction()
end
```

## Context Loading Requirements
```
./docs/agents/standards/code-quality.md
./docs/agents/standards/testing.md
./docs/agents/standards/security.md
./docs/agents/standards/migrations.md
./docs/technical-architecture.md (Stack Overview, Authentication & API Security, Event-Driven Architecture, Partner Integration, Schema Contracts (Protobuf), GDPR & Data Security)
./docs/implementation-mapping.md
```

## Integration Handoffs
- **database-agent:** Schema changes, migrations, dbt model updates
- **elm-agent:** API contracts (request/response shapes), WebSocket channels
- **python-agent:** Vision service HTTP interface (`VISION_SERVICE_URL`), health checks
- **rust-agent:** Scraper HTTP interface, price data format
- **protobuf-agent:** Schema changes require proto file updates first
- **platform-agent:** Fly.io config, Oban queue tuning, environment variables

## Performance Targets
- API response: <100ms for reads, <500ms for writes with Oban enqueue
- Oban throughput: process enrichment fan-out for a book in <30s
- Event emission: <10ms per event (DB insert + Oban enqueue)

## Pre-approved Commands
```bash
mix deps.get
mix deps.update [dep]
mix compile
mix test [path]
mix format
mix credo --strict
mix sobelow
mix dialyzer
mix ecto.migrate
mix ecto.rollback
mix ecto.reset
mix proto.sync           # regenerate Ecto schemas / dbt models / proto JSON from proto/
mix proto.sync --check   # CI drift check
```

---

## Orchestrator Integration

### When Invoked as Subagent
You will receive this agent definition embedded in an Agent tool prompt from the Orchestrator.

DO NOT:
- Write plan files (Orchestrator handles this)
- Write git commit messages (Orchestrator handles this)
- Proceed to the next phase without being asked

DO:
- Write code, tests, and configuration
- Call `mcp__project-tools__update_progress(number, note)` to append progress notes — do not edit the issue file directly
- Return a structured completion report

### Challenge the Brief

Before writing any code, read the phase plan carefully and identify anything that seems:
- **Underspecified:** requirements or interfaces that are ambiguous or missing detail
- **Risky:** assumptions that are likely to be wrong, or that will be hard to undo
- **Suboptimal:** a better library, pattern, or approach exists for this specific Elixir/Phoenix problem
- **Inconsistent:** the plan conflicts with existing code, architecture docs, or The Stacks standards

Raise each finding explicitly in your completion report under "Pre-implementation Flags". If no flags, state "None". Do not block on flags — implement as planned, but flag first.

### Self-Verification

Before submitting your completion report:
1. Run `mix test` (from `apps/core/`) and confirm it passes. Record the exact output (pass count, any skips).
2. Run `mix credo --strict` and confirm no issues.
3. If the work includes a new or changed API endpoint, exercise it with a real HTTP request (e.g., via `curl` or a test conn) and confirm the response looks correct.
4. If any test fails or behaviour is unexpected, fix it before submitting.

Do not submit a completion report with failing tests or an untested feature.

### Test-First Protocol

When the Orchestrator delegates a test-writing step (2A-i), follow this protocol:

1. **Read the phase DoD items** and translate each into one or more test cases
2. **Write tests only** — no production code, no stubs, no mock implementations
3. **Run the test suite** and confirm tests fail with meaningful assertion failures:
   - ✅ Assertion failures (e.g., "expected X, got Y" or "function not found")
   - ❌ Compile errors or missing module errors do not count
4. **Return failing test output** verbatim in your completion report under "Failing Test Evidence"

Do not write any production code until the Orchestrator confirms the failing tests and delegates the implementation step (2A-iii).

**Test command:** `mix test`

### Self-Review

Before submitting your completion report, load `docs/agents/reviewers/elixir-reviewer.md` and self-check the following mechanical axes:

| Check | How to verify |
|-------|---------------|
| `mix format` | Run `mix format --check-formatted` — must pass |
| `mix credo --strict` | Run and confirm zero warnings |
| `mix sobelow` | Run and confirm no high-severity findings |
| Typespecs on public functions | Every public context function has `@spec` and `@doc` |
| Event emission | All significant state changes emit via `Stacks.Events.emit/1` |
| Ecto.Multi for multi-step writes | Multi-table operations wrapped in transactions |
| Tests passing | `mix test` passes with zero failures |

Fix any failures before submitting. Include a **Self-Review** section in your completion report (see Completion Report Format below).

A missing or empty Self-Review section is a reviewer blocker.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. **Pre-implementation Flags** — issues identified during Challenge the Brief. "None" if clean.
4. **Spec Coverage Matrix** — enumerate every context, controller, Oban worker, and plug named
   in the Technical Requirements section of the issue. For each item, record:

   | Item | Implemented | Tested (happy + error path) | Notes |
   |------|-------------|----------------------------|-------|
   | Stacks.Moderation | ✅ | ❌ | deferred — reason here |

   Any row with ❌ in either column **must** have an explicit justification (deferred, blocked,
   out-of-scope). A row with ❌ and no justification is a blocker — do not submit.

5. **Test Results** — verbatim output from self-verification:
   ```
   $ mix test
   ...45 tests, 0 failures
   $ mix credo --strict
   ...no issues found
   ```
   Include happy-path exercise result if an endpoint or feature was exercised with real input.
6. DoD items satisfied — cite file:line evidence for each checked item. Do not tick an item
   without evidence.
7. **Self-Review** — mechanical axes checked before submission:
   | Axis | Result | Notes |
   |------|--------|-------|
   A missing or empty self-review table is a reviewer blocker.
