# The Stacks — Elixir Agent

## Role
Develop and maintain the Phoenix/Elixir core: API endpoints, Oban job workers, event-driven architecture, contexts, supervision trees, and the partner API. This is the heart of The Stacks.

## Technology Stack
- **Framework:** Phoenix 1.7+ (JSON API mode, no LiveView)
- **Language:** Elixir 1.17+ with OTP 27
- **Database:** Ecto for PostgreSQL (3 schemas: op, wh, audit)
- **Job queue:** Oban (job processing + event bus)
- **Auth:** Guardian JWT (HS256)
- **Rate limiting:** GenServer sliding window + token bucket
- **Circuit breakers:** Fuse library
- **Password hashing:** Argon2 (argon2_elixir)

## Owned Domains

### Contexts (bounded domains in `apps/core/lib/core/`)
- `Stacks.Books` — CRUD, ISBN resolution, enrichment orchestration
- `Stacks.Shelving` — Shelf placements, history tracking, shelf transitions
- `Stacks.Partners` — Registration, approval, API key management, inventory/event/space ingest
- `Stacks.Partners.Inventory` — Inventory sync, CSV import, ISBN resolution for unknowns
- `Stacks.Partners.Events` — Event creation, updates, archival
- `Stacks.Partners.Spaces` — Space registration, updates
- `Stacks.Partners.Validation` — Schema validation, blocklist, ISBN checksum
- `Stacks.Partners.Metrics` — Aggregate engagement queries
- `Stacks.Events` — Event bus: emit/1, replay/3, subscriber registry, upcaster
- `Stacks.Enrichment` — Fan-out to scrapers, review aggregation, author intelligence
- `Stacks.Moderation` — Content moderation pipeline (4-step)
- `Stacks.ThirdSpaces` — Cork board, user-submitted spaces
- `Stacks.GDPR` — Export, deletion, consent, retention
- `Stacks.Search` — Book/author search
- `Stacks.Audit` — Immutable audit logging
- `Stacks.Marketplace` — Listings, offers, transactions (future)

### Controllers (in `apps/core/lib/core_web/`)
- `BookController`, `ShelfController`, `SearchController`
- `PartnerAPI.InventoryController`, `PartnerAPI.EventController`, `PartnerAPI.SpaceController`, `PartnerAPI.MetricsController`
- `PartnerDashboard.*` (web form equivalents of API endpoints)
- `GDPRController`, `MetricsController`, `FeedController`

### Oban Workers (in `apps/core/lib/core/workers/`)
- Vision + ISBN: `IdentifyBookJob`, `EnrichBookJob`
- Enrichment: `FetchReviewsJob`, `TriggerPriceScrapeJob`, `DiscoverAuthorSourcesJob`, `FetchAuthorRSSJob`
- Discovery: `SourceDiscoveryJob`, `ScoreSourceJob`, `DiscoverThirdSpacesJob`, `DiscoverBookstoreEventsJob`
- Partner: `PartnerISBNResolveJob`, `ArchivePartnerEventsJob`, `PartnerMetricsSnapshotJob`, `PartnerApprovalNotificationJob`
- Moderation: `ModerationPipelineJob`
- Events: `EventSubscriberWorker`
- GDPR: `DataExportJob`, `AccountDeletionJob`, `ImageRetentionJob`
- Feeds: `RegenerateFeedJob`
- Marketplace: `ListingExpiryJob`, `PaymentCallbackJob`, `ShipmentTrackingJob`
- Metrics: `MetricsSnapshotJob`

### Plugs (in `apps/core/lib/core_web/plugs/`)
- `SecurityHeadersPlug`, `RateLimiterPlug`, `CORSPlug`
- `PartnerAuthPlug` (API key extraction, hash verification, status check)
- `PartnerRateLimiterPlug` (100/min, 10k/day per partner)
- `SchemaValidationPlug` (Protobuf-generated JSON schema validation)
- `RequestSizeValidation`

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
/Users/erinversfeld/thestacks/docs/agents/standards/code-quality.md
/Users/erinversfeld/thestacks/docs/agents/standards/testing.md
/Users/erinversfeld/thestacks/docs/agents/standards/security.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (sections 1-7, 10, 18, 21, 23)
/Users/erinversfeld/thestacks/docs/implementation-mapping.md
```

## Integration Handoffs
- **database-agent:** Schema changes, migrations, dbt model updates
- **elm-agent:** API contracts (request/response shapes), WebSocket channels
- **python-agent:** Vision sidecar HTTP interface, health checks
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
mix ecto.migrate
mix ecto.rollback
mix ecto.reset
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
- Update Progress Notes in the issue file
- Return a structured completion report

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. Test commands run and results
4. DoD items satisfied for this phase
