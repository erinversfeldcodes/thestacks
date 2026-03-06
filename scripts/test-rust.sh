#!/usr/bin/env bash
set -euo pipefail

(cd apps/scraper && cargo test)
