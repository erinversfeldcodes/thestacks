# The Stacks — Agent System Configuration

## Plan Directory
plans/

## Issue Directory
issues/

## Invocation Model
Agents are plain .md files. Invoke the Orchestrator as:
  "You are The Stacks Orchestrator.
   Load: docs/agents/orchestrator-agent.md
   Task: Issue #NNN or [description]"

## Agent Registry

| Agent | File | Domain |
|---|---|---|
| orchestrator | docs/agents/orchestrator-agent.md | System conductor — plans, delegates, reviews |
| researcher | docs/agents/orchestrator/researcher-agent.md | Research subagent — codebase + doc analysis |
| reviewer | docs/agents/orchestrator/reviewer-agent.md | Code review subagent |
| elixir-agent | docs/agents/elixir-agent.md | Phoenix, Oban, EDA, contexts, partner API |
| elm-agent | docs/agents/elm-agent.md | Elm SPA, shelves, spines, cork board, partner dashboard |
| python-agent | docs/agents/python-agent.md | FastAPI vision sidecar, content moderation |
| rust-agent | docs/agents/rust-agent.md | Bookshop price scraper, TOML config |
| database-agent | docs/agents/database-agent.md | PostgreSQL, Ecto, dbt, migrations, schemas |
| platform-agent | docs/agents/platform-agent.md | Fly.io, Docker, Nix/Flox, CI/CD, GitHub Actions |
| partner-agent | docs/agents/partner-agent.md | Partner API, dashboard, CSV import, validation |
| protobuf-agent | docs/agents/protobuf-agent.md | Proto files, buf, code generation, upcasting |
| security-agent | docs/agents/security-agent.md | GDPR, auth, AI safety, scanning, threat model |
| principle-engineer | docs/agents/principle-engineer-agent.md | Code quality audit, architectural review |
| testing-coordinator | docs/agents/testing-coordinator-agent.md | 12-layer test strategy, 4 environments |

## Domain Routing Table

| Keywords | Delegate To |
|---|---|
| Phoenix, Elixir, OTP, Oban, context, GenServer, supervision, event bus | elixir-agent |
| Elm, frontend, shelf, spine, cork board, reading pile, UI, SPA | elm-agent |
| vision, FastAPI, Python, Together AI, Replicate, image classification | python-agent |
| Rust, scraper, price, bookshop, TOML, ISBN extraction | rust-agent |
| database, PostgreSQL, Ecto, migration, schema, dbt, SQL | database-agent |
| Fly.io, Docker, Nix, Flox, CI/CD, GitHub Actions, deployment | platform-agent |
| partner, inventory sync, CSV import, partner API, partner dashboard | partner-agent |
| Protobuf, proto, buf, schema contract, code generation, upcasting | protobuf-agent |
| GDPR, security, auth, Guardian, JWT, AI safety, rate limiting, scanning | security-agent |
| code quality, architecture review, tech debt, standards compliance | principle-engineer |
| testing, E2E, Playwright, elm-program-test, chaos, load, k6 | testing-coordinator |

## Shared Standards
- Code quality: docs/agents/standards/code-quality.md
- Testing: docs/agents/standards/testing.md
- Security: docs/agents/standards/security.md
- Protobuf: docs/agents/standards/protobuf.md

## Canonical References
- Architecture: docs/technical-architecture.md
- User stories: docs/user-stories.md
- Implementation mapping: docs/implementation-mapping.md
