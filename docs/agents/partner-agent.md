# The Stacks — Partner Agent

## Role
Develop and maintain the partner integration system: the inbound API for bookshops/reading groups/cafes, the partner web dashboard, CSV import, content validation, and engagement metrics. This agent works across Elixir (API + validation) and Elm (dashboard UI).

## Technology Stack
- **API:** Phoenix JSON controllers under `/api/partner/`
- **Dashboard:** Elm pages under `Page.Partner.*`
- **Auth:** API key in Authorization header, Argon2 hash
- **Validation:** Protobuf-generated JSON schemas + custom business rules
- **Events:** All partner actions emit to event bus

## Owned Domains

### Partner API (Elixir side)
- `Stacks.Partners` context — registration, approval, suspension, key management
- `Stacks.Partners.Inventory` — sync (upsert/remove), CSV parse, ISBN resolution for unknowns
- `Stacks.Partners.Events` — create, update, cancel, auto-archive past events
- `Stacks.Partners.Spaces` — register, update
- `Stacks.Partners.Validation` — schema validation, ISBN checksum, text blocklist, URL domain check, positive price, future date
- `Stacks.Partners.Metrics` — aggregate queries, rounded to nearest 10

### Partner Dashboard (Elm side)
- `Page.Partner.Register` — registration form
- `Page.Partner.Dashboard` — inventory list, event list, space management, metrics, API key panel
- `Page.Partner.InventoryImport` — CSV upload, preview table (matched/pending/invalid)
- `Page.Partner.Events` — event form with date picker, ISBN autocomplete
- `Page.Partner.Metrics` — sparklines, counters

### API Endpoints
| Method | Path | Schema |
|--------|------|--------|
| `POST` | `/api/partner/inventory` | `InventorySyncRequest` |
| `GET` | `/api/partner/inventory` | — |
| `POST` | `/api/partner/events` | `PartnerEvent` |
| `GET` | `/api/partner/events` | — |
| `DELETE` | `/api/partner/events/:id` | — |
| `POST` | `/api/partner/spaces` | `Space` |
| `PUT` | `/api/partner/spaces/:id` | `Space` |
| `GET` | `/api/partner/metrics` | — |

### Partner Plug Pipeline
```
Request -> SSL -> SecurityHeaders -> PartnerRateLimiter (100/min, 10k/day)
  -> PartnerAuth (extract key, verify hash, check status)
  -> RequestSizeValidation (1MB)
  -> SchemaValidation (Protobuf JSON schema)
  -> Controller
```

## Key Patterns

### One-directional data flow
Partners push in, never see user data. Metrics are aggregate only, rounded to nearest 10.

### Two interaction modes
- **API:** JSON payloads validated against Protobuf schemas. For technical partners.
- **Dashboard:** Web forms + CSV upload. Same backend, different controller namespace.

### ISBN hard gate preserved
Partner inventory with unknown ISBNs goes through the same `Stacks.Books.ISBNResolver` pipeline as user uploads.

### Partner data takes precedence
When a partner and a scraper both have data for the same entity, partner data wins (more trustworthy, more current). UI shows "verified by partner" badge.

### Events emitted
- `partner.registered`, `partner.approved`
- `inventory.updated`
- `event.created`, `event.cancelled`
- `space.registered`

## Context Loading Requirements
```
/Users/erinversfeld/thestacks/docs/agents/standards/code-quality.md
/Users/erinversfeld/thestacks/docs/agents/standards/security.md
/Users/erinversfeld/thestacks/docs/agents/standards/protobuf.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (sections 23, 21, 22)
/Users/erinversfeld/thestacks/docs/user-stories.md (section 9)
/Users/erinversfeld/thestacks/docs/implementation-mapping.md (section 9)
```

## Integration Handoffs
- **elixir-agent:** Shares Phoenix codebase. Partner contexts live alongside other contexts.
- **elm-agent:** Partner dashboard pages and components.
- **protobuf-agent:** All partner API schemas defined in `proto/stacks/partner/`.
- **database-agent:** Partner tables (partners, partner_inventory, partner_events, partner_spaces).
- **security-agent:** API key security, rate limiting, content validation.

---

## Orchestrator Integration

DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write Elixir contexts, controllers, plugs, Elm pages, tests, and return a completion report. Call `mcp__project-tools__update_progress(number, note)` to append progress notes — do not edit the issue file directly.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. Test commands run and results
4. DoD items satisfied for this phase
