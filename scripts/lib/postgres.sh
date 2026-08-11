#!/usr/bin/env bash

_find_pg_isready() {
    if command -v pg_isready &>/dev/null; then
        echo "pg_isready"
        return
    fi
    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null)" || brew_prefix=""
    if [[ -n "$brew_prefix" ]]; then
        local candidate
        for candidate in "$brew_prefix"/opt/postgresql*/bin/pg_isready; do
            if [[ -x "$candidate" ]]; then
                echo "$candidate"
                return
            fi
        done
    fi
    echo ""
}

_postgres_ready() {
    local pg_isready
    pg_isready="$(_find_pg_isready)"
    if [[ -n "$pg_isready" ]]; then
        "$pg_isready" -h localhost -p 5432 -q 2>/dev/null
    else
        nc -z localhost 5432 2>/dev/null
    fi
}

ensure_postgres() {
    if _postgres_ready; then
        return 0
    fi

    echo "PostgreSQL is not running. Attempting to start it..."

    if [[ "$(uname)" == "Darwin" ]]; then
        local svc
        svc=$(brew services list 2>/dev/null | awk '/^postgresql/ {print $1}' | head -1)
        if [[ -n "$svc" ]]; then
            brew services start "$svc"
        else
            echo "ERROR: No Homebrew postgresql service found. Install with: brew install postgresql@16" >&2
            exit 1
        fi
    elif command -v systemctl &>/dev/null; then
        sudo systemctl start postgresql
    else
        echo "ERROR: Cannot start PostgreSQL automatically on this platform. Start it manually and re-run." >&2
        exit 1
    fi

    echo "Waiting for PostgreSQL to accept connections..."
    local attempts=20
    until _postgres_ready; do
        if [[ $attempts -le 0 ]]; then
            echo "ERROR: PostgreSQL did not become ready in time." >&2
            exit 1
        fi
        sleep 1
        ((attempts--))
    done
    echo "PostgreSQL is ready."
}
