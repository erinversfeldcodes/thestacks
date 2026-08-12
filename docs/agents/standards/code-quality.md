# The Stacks — Code Quality Standards

## Philosophy

Inspired by John Ousterhout's "A Philosophy of Software Design":

1. **Complexity is the enemy** — The greatest limitation in writing software is our ability to understand the systems we create
2. **Deep modules** — Best modules provide powerful functionality yet simple interfaces
3. **Clarity over cleverness** — Code should be obvious, not clever
4. **Consistency** — Similar things should look similar, different things should look different
5. **Avoid over-engineering** — Three similar lines of code is better than a premature abstraction

---

## Agent Deliverable Conventions

Apply to every specialist, reviewer, and the orchestrator:

- **Large deliverables go to a file, not the chat.** Audits, review reports, plans, and multi-section analyses are written to a file (`plans/<slug>.md`, an issue's embedded `## Test Audit` section, or `docs/`) and the agent returns a **concise summary** — verdict, key findings, and where the full artifact lives. Printing a long report inline risks output-token truncation and loses the artifact.
- **Evidence over assertion.** "Tests pass" / "verify passes" is never a report. Cite the number (`2259 tests, 0 failures`), the `file:line`, or the specific gate output. A claim a reviewer cannot re-check is not done.
- **Never invent a citation.** Every `✅` or reference to a test, function, or line must be something you verified by grep/Read — not inferred from a name.

---

## Elixir Conventions

### Contexts as Bounded Domains
Each context (e.g., `Stacks.Books`, `Stacks.Partners`) is a public API boundary. Internal modules are private.

```elixir
# Good: context exposes a clean interface
Stacks.Books.create(attrs)
Stacks.Books.get_by_isbn(isbn)

# Bad: reaching into internal modules
Stacks.Books.ISBNResolver.resolve(text)  # This is internal
```

### Pattern Matching over Conditionals
```elixir
# Good
def handle_result({:ok, book}), do: {:ok, book}
def handle_result({:error, :not_found}), do: {:error, "Book not found"}
def handle_result({:error, reason}), do: {:error, "Failed: #{reason}"}

# Bad
def handle_result(result) do
  if elem(result, 0) == :ok do
    ...
  end
end
```

### Ecto.Multi for Multi-Step Operations
Any operation that writes to multiple tables or emits events should use `Ecto.Multi` for transactional safety.

### With Clauses for Pipelines
```elixir
with {:ok, text} <- Vision.extract(images),
     {:ok, isbn} <- ISBNResolver.resolve(text),
     {:ok, book} <- Books.create(%{isbn: isbn}) do
  {:ok, book}
end
```

### Formatting & Linting
- `mix format` — mandatory, no exceptions
- `mix credo --strict` — all checks must pass (warnings are failures; exits 16 on warnings)
- `mix sobelow` — no high-severity findings
- `mix dialyzer` — type checking; warnings configured in `apps/core/.dialyzer_ignore.exs`
- `mix proto.sync --check` — fails the build if generated Ecto schemas, migrations, or dbt staging models drift from `proto/`

### Testing
- `mix test` from `apps/core/` (umbrella app, not root)
- `mix coveralls` for coverage; `minimum_coverage: 80` configured in `apps/core/mix.exs`

---

## Elm Conventions

### The Elm Architecture (TEA)
Every page follows Model-Update-View. No exceptions.

### RemoteData for All API Calls
Never use raw `Maybe` for API state. Always use `RemoteData` (NotAsked | Loading | Failure e | Success a).

### No Ports Unless Absolutely Necessary
Ports break Elm's type safety guarantee. Use elm/file for uploads (typed port API). Everything else should be pure Elm.

### Formatting & Linting
- `elm-format` — mandatory, no exceptions. It's opinionated and that's the point.
- `elm-review` — runs against `src/` and `tests/` (config in `frontend/elm-review/`)

### Testing
- `elm-test` for unit + integration tests under `frontend/tests/`

### Naming
- Pages: `Page.Bookshelf`, `Page.Bookshelf.ReadingPile`, `Page.Settings.AgeVerification`
- Components: `Components.Spine`, `Components.ISBNInput`
- Generated types: `proto/gen/elm/` (sourced via `source-directories` in `frontend/elm.json`)

---

## CSS Conventions

`frontend/css/main.css` is the single stylesheet source; everything under
`apps/core/priv/static/assets/` is build output. Three gates guard it, all wired into
`scripts/lint-elm.sh` and running in `just ci` / the CI lint-elm job (Issues #301, #306, #319):
`check-orphan-classes.sh` (a class exists in the DOM but has no rule), `check-css.sh`
(well-formedness, `[class*=]` bans, specificity/cascade-order traps), and `check-css-values.sh`
(token-value drift).

### Design tokens (Wave 9 / #319)
- Every reusable value lives behind a token: the spacing scale (`--space-1…7`), the type scale
  (`--size-xs…8xl`), radii (`--radius-sm/md/lg/pill`), shadows, the palette, and the semantic state
  tokens (`--error`/`--error-strong`/`--success`/`--warning`/`--warning-text`).
- **A bare literal equal to a token's value is a bug** — it should be `var(--that-token)`.
  `check-css-values.sh` fails on it, on `var()` of an undefined token, on a fallback that disagrees
  with the token's definition, and on a spacing literal equal to a `--space-*` step. Each dimension is
  a ratchet at its current count — never add a new violation past the budget; migrate to lower it.
- The palette is redefined by five shelf-theme blocks and a page-scoped parchment block. A value maps
  to DIFFERENT token names per theme, so migrate a literal only when the token resolves to that exact
  value in the rule's rendering context — editing one theme block silently forks the others.

### Transitions and reserved space
- **Indicators must never `transition`.** A tab's active underline, a progress dot, a status pip —
  anything whose whole job is to say "this is the current state" — must change instantly. A transition
  on an indicator animates the *lie* (the old state) for the duration and reads as lag (the login-tab
  and progress-dot precedent).
- **Never `transition: all`.** Name the properties you mean (`transition: background-color .2s, color
  .2s`). `all` sweeps in layout and paint properties you never intended to animate, which is both a
  jank source and how an indicator accidentally acquires a transition.
- **Reserve space for state/network-dependent content.** Anything that appears on an async result — an
  inline error, a validation message, a spinner slot — must have its space reserved by layout so the
  surface does not reflow when it arrives (the shift-class pattern from register + upload). A surface
  that jumps when the server answers is a layout bug, not a timing one.

## Rust Conventions

### Error Handling
- `thiserror` for library-level error types (scraper errors, parse errors)
- `anyhow` for application-level error propagation (main.rs, CLI)
- Never `unwrap()` in library code. Always propagate with `?`.

### Formatting & Linting
- `cargo fmt` — mandatory
- `cargo clippy -- -D warnings` — treat all warnings as errors

### Testing
- `cargo test` for unit + integration
- `proptest` for property-based (price parsing, ISBN validation)
- `cargo-fuzz` for fuzz targets (TOML parsing, HTML extraction)

---

## Python Conventions

### Type Hints Everywhere
Every function signature must have type annotations. Pydantic v2 models for all API schemas.

### Formatting & Linting
- `ruff check` for linting AND `ruff format` for formatting — both are enforced in CI (replaces black + flake8 + isort)
- `mypy` (strict mode) for type checking — configured in `apps/vision/pyproject.toml`

### Testing
- `pytest` with fixtures (asyncio mode auto; configured in `apps/vision/pyproject.toml`)
- `Atheris` for fuzzing (image input parsing)

---

## Protobuf Conventions

### Schema as Contract
`.proto` files in `proto/` are the single source of truth for structured data. Generated code for Elixir (Ecto schemas + ProtoJSON), Elm (decoders/encoders), Python (Pydantic v2), Rust (serde), and dbt staging models is regenerated from these files — never hand-edited.

### Formatting & Linting
- `buf lint` — enforces STANDARD + COMMENTS rule sets (configured in `proto/buf.yaml`)
- `buf breaking` — guards FILE-level breaking changes; exemptions tracked in `proto/buf.yaml`
- Field numbers are forever. Never reuse a number. Additive changes only.
- Enum zero value suffix: `_UNSPECIFIED`

### Codegen
- `mix proto.sync` regenerates Ecto schemas, dbt staging models, migrations, ProtoJSON.Gen, schema.yml
- `scripts/gen-elm-proto.sh`, `scripts/gen-python-proto.sh`, `scripts/gen-rust-proto.sh` regenerate the other languages
- `buf generate` is NOT the active codegen path; plugins in `proto/buf.gen.yaml` are commented out intentionally

---

## SQL / dbt Conventions

### Naming
- All lowercase, snake_case
- Tables: plural nouns (`books`, `partners`, `bookshelf_placements`)
- Columns: singular (`book_id`, `price_cents`, `created_at`)
- Enums: `ENUM('value_one', 'value_two')` — snake_case values

### Data Types
- Primary keys: `UUID` (always)
- Timestamps: `TIMESTAMPTZ` (never `TIMESTAMP`)
- Money: `INTEGER` (cents, not float)
- Arrays: `TEXT[]` (for tags, subjects, amenities)
- Flexible data: `JSONB` (validated at application layer)

### dbt Models
- Staging (`stg_*`): One-to-one with source tables, light cleaning only
- Intermediate (`int_*`): Business logic joins and aggregations
- Marts (`mart_*`): Final read models consumed by the API

---

## Cross-cutting Rules

### No Over-engineering
- Don't add features, refactor code, or make "improvements" beyond what was asked
- Don't add error handling for scenarios that can't happen
- Don't create abstractions for one-time operations
- Three similar lines of code is better than a premature abstraction

### Comments
- Comments describe **why**, not **what**
- Don't add docstrings to code you didn't change
- Module-level `@moduledoc` in Elixir for context modules (public API)

### Dependencies
- Prefer stdlib over third-party where reasonable
- Every new dependency must be justified
- Pin versions in mix.exs, Cargo.toml, requirements.txt, elm.json

### Git Hygiene
- One logical change per commit
- Conventional commit messages: `feat(scope): summary`
- Never commit secrets, `.env` files, or generated code (except Elm decoders)

### Automated Enforcement
Claude Code hooks in `.claude/settings.json` enforce these standards automatically:
- **PostToolUse** (per file write/edit) — runs the appropriate formatter/linter check for the edited file (`mix format`, `elm-format`, `cargo fmt`, `ruff`, `buf lint`, plus a `gitleaks` scan on every write).
- **Stop** (end of every response) — runs the full lint suite for all changed files: format + `credo` + `sobelow` (Elixir), `elm-format` + `elm-review` (Elm), `cargo fmt` + `cargo clippy` (Rust), `ruff check` + `ruff format` (Python), `buf lint` (proto), and `mix proto.sync --check` for drift.

If a hook fails, the error and the `Run: ...` fix command are surfaced inline. The session cannot proceed past a Stop hook failure.
