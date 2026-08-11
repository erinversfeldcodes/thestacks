"""
Domain-specific Definition of Done templates.

Each domain has a standard set of DoD items that are always included
when creating issues targeting that domain.
"""

DOD_TEMPLATES: dict[str, list[str]] = {
    "elixir": [
        "mix test passing with no new skips",
        "mix credo --strict clean",
        "sobelow scan clean",
        "typespecs on all public functions",
        "events emitted for all state changes",
    ],
    "elm": [
        "elm-test passing",
        "elm-format clean",
        "RemoteData used for all API calls",
        "No unsafe Html.Attributes",
    ],
    "rust": [
        "cargo test passing",
        "cargo fmt clean",
        "cargo clippy -- -D warnings clean",
        "No unwrap() in library code",
    ],
    "python": [
        "pytest passing",
        "ruff format and check clean",
        "type annotations on all public functions",
        "Pydantic v2 models for all request/response schemas",
    ],
    "platform": [
        "Docker build succeeds",
        "flyctl config validate clean",
        "CI workflow syntax valid",
        "No secrets in committed files",
    ],
    "database": [
        "mix test passing (Ecto tests)",
        "All migrations reversible",
        "UUID primary keys on all tables",
        "timestamps(type: :utc_datetime_usec) on all tables",
    ],
}

DOMAIN_AGENTS: dict[str, str] = {
    "elixir": "elixir-agent",
    "elm": "elm-agent",
    "rust": "rust-agent",
    "python": "python-agent",
    "platform": "platform-agent",
    "database": "database-agent",
    "protobuf": "protobuf-agent",
    "partner": "partner-agent",
    "security": "security-agent",
}
