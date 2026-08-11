#!/usr/bin/env bash
set -euo pipefail

if ! cargo audit --version &>/dev/null; then
    echo "cargo-audit not found — installing..."
    cargo install cargo-audit --locked
fi

(cd apps/scraper && cargo fmt --check)
(cd apps/scraper && cargo clippy -- -D warnings)
(cd apps/scraper && cargo audit)
