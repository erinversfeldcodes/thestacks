# The Stacks — Code Quality Standards

## Philosophy

Inspired by John Ousterhout's "A Philosophy of Software Design":

1. **Complexity is the enemy** — The greatest limitation in writing software is our ability to understand the systems we create
2. **Deep modules** — Best modules provide powerful functionality yet simple interfaces
3. **Clarity over cleverness** — Code should be obvious, not clever
4. **Consistency** — Similar things should look similar, different things should look different
5. **Avoid over-engineering** — Three similar lines of code is better than a premature abstraction

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
- `mix credo --strict` — all checks must pass
- `mix sobelow` — no high-severity findings

---

## Elm Conventions

### The Elm Architecture (TEA)
Every page follows Model-Update-View. No exceptions.

### RemoteData for All API Calls
Never use raw `Maybe` for API state. Always use `RemoteData` (NotAsked | Loading | Failure e | Success a).

### No Ports Unless Absolutely Necessary
Ports break Elm's type safety guarantee. Use elm/file for uploads (typed port API). Everything else should be pure Elm.

### Formatting
- `elm-format` — mandatory, no exceptions. It's opinionated and that's the point.

### Naming
- Pages: `Page.Shelf.Library`, `Page.Partner.Dashboard`
- Components: `Components.Spine`, `Components.CorkBoard`
- API types: `Api.Generated.*` for Protobuf-generated decoders

---

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
- `ruff` for both linting and formatting (replaces black + flake8 + isort)
- `mypy` or `pyright` for type checking

### Testing
- `pytest` with fixtures
- `Atheris` for fuzzing (image input parsing)

---

## SQL / dbt Conventions

### Naming
- All lowercase, snake_case
- Tables: plural nouns (`books`, `partners`, `shelf_placements`)
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
