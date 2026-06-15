# Development Environment Setup

## Prerequisites

One of the following:

- **macOS / Homebrew path** (recommended): the bootstrap script will install
  [Homebrew](https://brew.sh), [`mise`](https://mise.jdx.dev/), `just`, `buf`,
  PostgreSQL 16, and language runtimes from the `Brewfile` and `.mise.toml`.
- **Nix path**: install [Nix](https://nixos.org/download.html) with flakes
  enabled and run `nix develop` to enter a shell with every dependency pinned
  by `flake.nix`.

## Getting Started

```sh
# One-shot bootstrap (Homebrew + mise + venvs + DB).
# Idempotent — safe to re-run. Use --no-db to skip database steps.
bash setup.sh

# Or, on the Nix path:
nix develop

# Copy environment config and fill in secrets
cp .env.example .env

# Install Claude Code hook scripts (sets execute bits)
just install-hooks

# Start all services (Phoenix, vision sidecar, scraper if built)
just dev
```

`just dev` runs migrations, regenerates Ecto + Elm proto bindings, builds
frontend assets, and opens http://localhost:4000.

## Tests

```sh
just test            # all suites (elixir, elm, rust, python, dbt)
just test-elixir
just test-elm
just test-rust
just test-python
just test-dbt
just test-e2e        # Playwright — requires `just dev` running
```

## Lint & Format

```sh
just lint            # all linters (check only)
just format          # auto-fix formatting + fixable lint
just verify          # full pre-merge gate (lint + tests + proto drift + dbt)
just ci              # run every CI check locally in CI order
```

## Database

```sh
just db-create    # Create database
just db-migrate   # Run migrations
just db-reset     # Drop + create + migrate + seed
```

## Project Tools MCP Server

The local MCP server in `scripts/mcp/` exposes issue and plan helpers to
Claude Code (see `CLAUDE.md`). `setup.sh` provisions its venv automatically;
on a Nix-only setup do this once after cloning:

```sh
python3 -m venv scripts/mcp/.venv
scripts/mcp/.venv/bin/pip install -r scripts/mcp/requirements.txt
```
