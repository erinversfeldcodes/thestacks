# The Stacks

An open-source, self-hosted book management and discovery platform. Dark-academic-meets-cottage-core aesthetic.

## Architecture

- **Core API**: Elixir + Phoenix (`apps/core/`)
- **Frontend**: Elm SPA (`frontend/`)
- **Vision sidecar**: Python + FastAPI (`apps/vision/`)
- **Bookshop scraper**: Rust + Axum (`apps/scraper/`)
- **Data transforms**: dbt (`dbt/`)
- **Schema contracts**: Protobuf (`proto/`)

## Setup

1. Install [Nix](https://nixos.org/download.html) and enable flakes
2. Enter the dev shell:
   ```sh
   nix develop
   ```
3. Copy environment config:
   ```sh
   cp .env.example .env
   ```
4. Start all services:
   ```sh
   just dev
   ```

## Documentation

See `docs/` for architecture, user stories, and implementation guides.

- `docs/technical-architecture.md` — full system architecture
- `docs/user-stories.md` — feature specifications
- `docs/implementation-mapping.md` — story-to-code bridge
- `docs/agents/` — agent system for AI-assisted development
