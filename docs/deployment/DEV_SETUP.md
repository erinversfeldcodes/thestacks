# Development Environment Setup

## Prerequisites

Install [Nix](https://nixos.org/download.html) with flakes enabled.

## Getting Started

```sh
# Enter the dev shell (installs all dependencies)
nix develop

# Copy environment config
cp .env.example .env

# Start all services
just dev
```

## Individual Services

```sh
# Elixir/Phoenix
just test-elixir

# Elm frontend
just test-elm

# Rust scraper
just test-rust

# Python vision service
just test-python

# All linters
just lint

# Format all code
just format
```

## Database

```sh
just db-create    # Create database
just db-migrate   # Run migrations
just db-reset     # Drop + create + migrate
```
