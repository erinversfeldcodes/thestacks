# The Stacks — Claude Code Project Configuration

> An open-source, self-hosted book management and discovery platform.
> Dark-academic-meets-cottage-core aesthetic.

## Quick Reference

- **Canonical docs:** `docs/technical-architecture.md` (architecture), `docs/user-stories.md` (features), `docs/implementation-mapping.md` (story-to-code bridge)
- **Agent system:** `docs/agents/` (orchestrator + specialists), `AGENTS.md` (registry + routing)
- **Standards:** `docs/agents/standards/` (code quality, testing, security, protobuf)
- **Issues:** `issues/` (structured task backlog, one `.md` per issue)
- **Plans:** `plans/` (orchestrator-generated implementation plans)
- **Proto schemas:** `proto/` (Protobuf contracts, `buf` config)

## Stack

| Component | Technology | Directory |
|-----------|-----------|-----------|
| Core API + orchestration | Elixir + Phoenix | `apps/core/` |
| Frontend SPA | Elm | `frontend/` |
| Vision model sidecar | Python + FastAPI | `apps/vision/` |
| Bookshop price scraper | Rust microservice | `apps/scraper/` |
| Data transforms | dbt | `dbt/` |
| Schema contracts | Protobuf + buf | `proto/` |
| Infrastructure | Fly.io (JHB), Nix/Flox | `deploy/`, `nix/` |
| Database | PostgreSQL (op, wh, audit schemas) | `apps/core/priv/repo/migrations/` |

## Core Conventions

### ISBN Hard Gate
No book enters the system without a verified ISBN from Open Library or Google Books. This is non-negotiable.

### Event-Driven Architecture
All significant state changes emit events via `Stacks.Events.emit/1` to the `event_log` table. Oban delivers events to registered subscribers. See `docs/technical-architecture.md` section 21.

### Partner Integration
Partners (bookshops, reading groups, cafes) push data via JSON API validated against Protobuf-generated schemas. Partners never see user data. Platform owner approves all partners.

### Protobuf as Schema Contract
`.proto` files in `proto/` are the single source of truth for structured data. `buf lint` and `buf breaking` run in CI. JSON on the wire. Elm decoders are checked in (no runtime codegen).

### GDPR by Default
4-tier data classification (public, personal, sensitive, external personal). Right to erasure, right to export. 30-day image retention. Consent with timestamps.

### Testing Philosophy
12-layer test strategy across 4 execution environments (local offline, local->deployed, CI, CI->deployed). `TEST_TARGET` env var controls mock/real service wiring. See `docs/technical-architecture.md` section 16.

## Agent System

Invoke the orchestrator for multi-phase work:
```
You are The Stacks Orchestrator.
Load: docs/agents/orchestrator-agent.md
Task: Issue #NNN or [description]
```

For narrow, well-understood tasks, invoke a specialist directly:
```
You are The Stacks elixir-agent.
Load: docs/agents/elixir-agent.md
Task: [description]
```

See `AGENTS.md` for the full registry and domain routing table.

## Code Style

- **Elixir:** `mix format`, `mix credo --strict`, Sobelow for security. Contexts as bounded domains. Pattern matching over conditionals.
- **Elm:** `elm-format`. Model-Update-View. No ports unless absolutely necessary. `RemoteData` for all API calls.
- **Rust:** `cargo fmt`, `cargo clippy`. Error handling via `thiserror`/`anyhow`. TOML configs per scraper.
- **Python:** `ruff` for linting/formatting. Type hints everywhere. FastAPI with Pydantic models.
- **SQL/dbt:** Lowercase, snake_case. All tables UUID PKs + TIMESTAMPTZ. dbt models: staging -> intermediate -> marts.
- **Protobuf:** `buf lint`. Field numbers are forever. Never reuse a number. Additive changes only.

## Do Not

- Skip ISBN verification for any book entering the system
- Store partner API keys in plaintext (Argon2 hash only)
- Trust vision model output without validation (always verify ISBNs against Open Library/Google Books)
- Expose user data to partners (one-directional: partner -> platform)
- Delete events from `event_log` (immutable, except GDPR erasure of PII in payloads)
- Use `unsafe-eval` in CSP (Elm doesn't need it)
- Add Kafka, RabbitMQ, or any external message broker (Oban is the event bus)
