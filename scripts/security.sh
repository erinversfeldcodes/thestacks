#!/usr/bin/env bash
set -euo pipefail

# NOTE: CodeQL (static analysis) runs only in CI via .github/workflows/codeql.yml.disabled.
# It requires GitHub-hosted runners and cannot be run locally.

require_tool() {
    local tool="$1"
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: '$tool' is not installed. Install it to run security checks." >&2
        echo "  macOS: brew install $tool" >&2
        exit 1
    fi
}

require_tool gitleaks
require_tool semgrep
require_tool hadolint
require_tool checkov
require_tool trivy

# Secret scanning — scans git history; .gitignore and .gitleaks.toml apply.
# --no-git is intentionally NOT used: it would scan the entire filesystem
# including gitignored .env files that contain valid local dev secrets.
gitleaks detect --source . --config .gitleaks.toml

# SAST
semgrep scan --config auto --error

# Dockerfile linting
hadolint deploy/Dockerfile.core
hadolint deploy/Dockerfile.vision
hadolint deploy/Dockerfile.scraper

# Infrastructure-as-code scanning
checkov --directory deploy/

# Vulnerability scanning (filesystem)
trivy fs . --severity CRITICAL,HIGH --exit-code 1
