#!/usr/bin/env bash
set -euo pipefail

cd apps/scraper

cargo test

if ! command -v cargo-llvm-cov &>/dev/null; then
    echo "ERROR: cargo-llvm-cov is not installed. Run ./setup.sh to install it." >&2
    exit 1
fi

echo "==> Running Rust coverage (threshold: 80%)..."
cargo llvm-cov --fail-under-lines 80 --summary-only
