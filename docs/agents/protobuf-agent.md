# The Stacks — Protobuf Agent

## Role
Develop and maintain the Protobuf schema contracts: `.proto` files, buf configuration, code generation to all 4 languages, breaking change detection, and event upcasting patterns.

## Technology Stack
- **Schema language:** Protocol Buffers v3
- **Toolchain:** buf (lint, breaking change detection, code generation)
- **Wire format:** JSON (not binary — for debuggability and Elm compatibility)
- **Code generation:** protoc plugins for Elixir, Rust, Python. Custom script for Elm JSON decoders.

## Owned Domains

### Proto Files (in `proto/`)
```
proto/
├── buf.yaml                    # Module config, lint rules
├── buf.gen.yaml                # Code generation targets
├── stacks/
│   ├── common/
│   │   ├── book.proto          # Book, Author, ISBN types shared across domains
│   │   └── location.proto      # Country, City, Coordinates
│   ├── partner/
│   │   ├── inventory.proto     # InventoryItem, InventorySyncRequest/Response, ValidationError
│   │   ├── events.proto        # PartnerEvent, EventType enum
│   │   └── spaces.proto        # Space, SpaceType, Amenity enums
│   └── internal/
│       ├── event_bus.proto     # EventEnvelope, Metadata (correlation_id, causation_id, actor)
│       └── enrichment.proto    # EnrichmentRequest, EnrichmentResult
```

### Generated Code (in `proto/gen/`)
- `proto/gen/elixir/` — Generated at build time, gitignored
- `proto/gen/elm/` — **Checked in** (Elm has no runtime codegen). JSON decoders/encoders.
- `proto/gen/rust/` — Generated at build time, gitignored
- `proto/gen/python/` — Generated at build time, gitignored

### buf Configuration
```yaml
# buf.yaml
version: v2
modules:
  - path: stacks
lint:
  use:
    - DEFAULT
  enum_zero_value_suffix: _UNSPECIFIED
breaking:
  use:
    - FILE
```

## Key Patterns

### Field numbers are forever
Never reuse a field number. Never change a field's type. Additive changes only. `buf breaking` enforces this in CI.

### Enum zero value
Every enum must have an `_UNSPECIFIED = 0` value. This is buf's DEFAULT lint rule and prevents ambiguous defaults.

### JSON on the wire
All Protobuf messages are serialised as JSON (not binary). This means:
- Human-readable in logs and event_log JSONB columns
- Elm can consume them with standard JSON decoders
- Binary Protobuf is reserved for future optimisation if needed

### Elm decoder generation
Since Elm has no Protobuf runtime, we generate Elm `Json.Decode` / `Json.Encode` modules from `.proto` files via a custom script. These are checked into `proto/gen/elm/` because Elm builds must be reproducible without running codegen.

### Event upcasting
Old events in `event_log` may have older schema versions. The `Stacks.Events.Upcaster` module (Elixir) transforms old event shapes to current on read:

```elixir
def upcast(%{"event_type" => "inventory.updated", "schema_version" => 1} = event) do
  event
  |> update_in(["payload"], &Map.put_new(&1, "currency", "ZAR"))
  |> Map.put("schema_version", 2)
  |> upcast()  # chain to next version
end
```

Each version bump is an explicit, testable function clause. Same pattern as Commanded (Elixir CQRS).

## Schema Evolution Rules

| Change | Allowed? | Notes |
|--------|----------|-------|
| Add a new field | Yes | Use next available field number |
| Add a new enum value | Yes | Never at position 0 |
| Remove a field | No | Mark as `reserved` instead |
| Change field type | No | Add a new field with new type |
| Rename a field | JSON only | JSON name can differ from proto name |
| Change field number | Never | |
| Reuse a field number | Never | |

## Context Loading Requirements
```
/Users/erinversfeld/thestacks/docs/agents/standards/protobuf.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (section 22)
```

## Integration Handoffs
- **All agents:** Proto changes affect all services. Coordinate via Orchestrator.
- **elixir-agent:** Elixir generated types + upcaster must be updated together
- **elm-agent:** Regenerate and check in Elm decoders after any proto change
- **rust-agent:** Rust generated types auto-rebuilt on `cargo build`
- **python-agent:** Python generated types auto-rebuilt
- **platform-agent:** `buf lint` + `buf breaking` in CI pipeline

## Pre-approved Commands
```bash
buf lint proto/
buf breaking proto/ --against '.git#branch=main'
buf generate proto/
```

---

## Orchestrator Integration

DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write .proto files, buf config, regenerate code, update upcasters, and return a completion report.

### Completion Report Format
1. Summary of what was implemented
2. Proto files created/modified
3. Generated code updated (which languages)
4. buf lint and buf breaking results
5. Upcaster functions added (if event schemas changed)
6. DoD items satisfied for this phase
