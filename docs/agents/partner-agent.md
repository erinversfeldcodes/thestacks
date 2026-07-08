# The Stacks — Partner Agent

## Role
Develop and maintain the partner integration system: the inbound API for bookshops/reading groups/cafes (registration, approval, inventory sync, third-space events), the admin moderation surface for approving partners, and content validation. Today the agent is Elixir-side only — there is no Elm partner dashboard.

## Technology Stack
- **API:** Phoenix JSON controllers under `/api/partner/` (key-authenticated) and `/api/admin/partners` (admin-authenticated)
- **Auth:** API key in `Authorization: Bearer stacks_pk_<hex>` header, Argon2 hash stored in `op.partners.hmac_secret`; raw key returned ONCE on approval / rotation
- **Validation:** Protobuf-generated Ecto schemas + context-level changesets and business rules (positive price, future event start, ends_after_starts)
- **Events:** Partner actions emit to the `event_log` via `Stacks.Events.emit_safe/1`

## Owned Domains

### Partner API (Elixir side)
- `Stacks.Partners` context (`apps/core/lib/stacks/partners.ex`) — registration, approval/rejection, API key generation + rotation + Argon2 auth, inventory sync (ISBN → `BookEdition` resolution, upsert), and partner-scoped third-space event CRUD via `Stacks.Enrichment.ThirdSpaceEvent`
- `Stacks.Partners.Partner` / `Stacks.Partners.InventoryItem` — proto-generated Ecto schemas at `apps/core/lib/stacks/gen/partners/` (do not hand-edit; regenerate via `mix proto.sync`)

### Controllers (`apps/core/lib/stacks_web/controllers/`, module namespace `StacksWeb`)
- `PartnerRegistrationController` — public `POST /api/partners/register`
- `PartnerController` — admin `GET /api/admin/partners`, `PUT /api/admin/partners/:id/approve`, `PUT /api/admin/partners/:id/reject`
- `PartnerInventoryController` — key-auth `POST /api/partner/inventory`, `POST /api/partner/inventory/import` (CSV), `GET /api/partner/inventory`
- `PartnerEventController` — key-auth `POST/GET /api/partner/events`, `DELETE /api/partner/events/:id`

### API Endpoints
| Method | Path | Auth | Notes |
|--------|------|------|-------|
| `POST` | `/api/partners/register` | public + `:rate_limit_public` | Returns pending partner; admin must approve before key issuance |
| `GET` | `/api/admin/partners` | admin + MFA | List pending/approved/rejected |
| `PUT` | `/api/admin/partners/:id/approve` | admin + MFA | Returns raw API key ONCE |
| `PUT` | `/api/admin/partners/:id/reject` | admin + MFA | |
| `POST` | `/api/partner/inventory` | partner key | JSON sync; returns `{synced, unresolved}` |
| `POST` | `/api/partner/inventory/import` | partner key | CSV import |
| `GET` | `/api/partner/inventory` | partner key | List items for this partner |
| `POST` | `/api/partner/events` | partner key | Requires linked `third_space_id` |
| `GET` | `/api/partner/events` | partner key | |
| `DELETE` | `/api/partner/events/:id` | partner key | |

### Partner Plug Pipeline
The `:partner_auth` pipeline in `CoreWeb.Router` is a single plug:
```
plug StacksWeb.PartnerAuthPlug  # extract Bearer token, lookup by prefix, Argon2.verify_pass
```
Layered on the standard `:api` pipeline. Public registration goes through `:rate_limit_public`; admin approval goes through `:admin` + `:rate_limit_admin`. There is no dedicated `PartnerRateLimiter` plug yet.

## Key Patterns

### One-directional data flow
Partners push in, never see user data. There is no partner-facing metrics API or dashboard today; aggregate/anonymised reporting is future work.

### API key handling
- Keys are minted as `stacks_pk_<32 random hex bytes>` and hashed with `Argon2.hash_pwd_salt/1`.
- Only the Argon2 hash and an 8-char `api_key_prefix` are stored. Plaintext keys are returned **once** (on approval or rotation) and never recoverable.
- Lookup uses the prefix to narrow to a single row, then `Argon2.verify_pass/2` confirms the secret; `Argon2.no_user_verify/0` is called on miss to avoid timing leaks.
- Never log raw keys; never accept them in query params.

### ISBN hard gate preserved
Inventory sync resolves each item's ISBN against `Stacks.Books.BookEdition`. Unknown ISBNs are returned to the caller in `{:ok, %{synced, unresolved}}` rather than fabricating a book — the ISBN gate from CLAUDE.md is honoured.

### Events emitted (via `Stacks.Events.emit_safe/1`)
- `partner.inventory_synced` — aggregate `partner`, payload `{synced, unresolved_count}`
- `partner.event_created` — aggregate `third_space_event`, payload `{space_id, title}`
- `partner.event_deleted` — aggregate `third_space_event`, payload `{space_id}`

## Context Loading Requirements
```
./docs/agents/standards/code-quality.md
./docs/agents/standards/security.md
./docs/agents/standards/protobuf.md
./docs/agents/standards/testing.md
./docs/decisions/007-protobuf-as-contract.md
./docs/decisions/014-proto-first-context-interfaces.md
./docs/technical-architecture.md (sections: Authentication & API Security, Data Engineering Pipeline)
./docs/user-stories.md (section 9 — Business & Partner Integration)
./docs/implementation-mapping.md (search for partner)
./issues/complete/145-partner-entity-api-keys.md
./issues/complete/146-partner-inventory-events-api.md
```

## Integration Handoffs
- **elixir-agent:** Shares the Phoenix codebase; `Stacks.Partners` sits alongside other contexts.
- **protobuf-agent:** Partner schemas live at `proto/stacks/internal/v1/partner.proto`; regen via `mix proto.sync`.
- **database-agent:** Tables are `op.partners` and `op.partner_inventory_items` (schemas auto-generated from proto). Third-space events live in `op.third_space_events` (owned by enrichment-agent).
- **security-agent:** API key Argon2 storage, prefix-scoped lookup, rate limiting on registration.

---

## Orchestrator Integration

DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write Elixir contexts, controllers, plugs, Elm pages, tests, and return a completion report. Call `mcp__project-tools__update_progress(number, note)` to append progress notes — do not edit the issue file directly.

### Test-First Protocol

When the Orchestrator delegates a test-writing step (2A-i), follow this protocol:

1. **Read the phase DoD items** and translate each into one or more test cases
2. **Write tests only** — no production code, no stubs, no mock implementations
3. **Run the test suite** and confirm tests fail with meaningful assertion failures:
   - Assertion failures (e.g., "expected X, got Y" or "function not found")
   - Compile errors or missing module errors do not count
4. **Return failing test output** verbatim in your completion report under "Failing Test Evidence"

Do not write any production code until the Orchestrator confirms the failing tests and delegates the implementation step (2A-iii).

**Test command:** `mix test`

### Self-Review

Before submitting your completion report, load `docs/agents/reviewers/elixir-reviewer.md` (and `docs/agents/reviewers/protobuf-reviewer.md` if proto files were touched) and self-check the following mechanical axes:

| Check | How to verify |
|-------|---------------|
| `mix format` | Run `mix format --check-formatted` — must pass |
| `mix credo --strict` | Run and confirm zero warnings |
| Typespecs on public functions | Every public function has `@spec` and `@doc` |
| Partner data isolation | Partners never see user data; data flow is partner → platform only |
| Proto schema compliance | If proto files touched: `buf lint` and `buf breaking` pass |
| Tests passing | `mix test` passes with zero failures |

Fix any failures before submitting. Include a **Self-Review** section in your completion report (see Completion Report Format below).

A missing or empty Self-Review section is a reviewer blocker.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. Test commands run and results
4. DoD items satisfied for this phase
5. **Self-Review** — mechanical axes checked before submission:
   | Axis | Result | Notes |
   |------|--------|-------|
   A missing or empty self-review table is a reviewer blocker.
