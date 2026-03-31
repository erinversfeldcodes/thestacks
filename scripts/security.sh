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
hadolint deploy/Dockerfile.scraper

# Infrastructure-as-code scanning
checkov --directory deploy/

# Vulnerability scanning (filesystem)
trivy fs . --severity CRITICAL,HIGH --exit-code 1 \
    --skip-dirs apps/vision/.venv \
    --skip-files apps/core/erl_crash.dump

# TruffleHog — deep entropy-based secret scanning
# .env and .env.* are gitignored local secret files — legitimate storage for dev credentials,
# not a leak. Exclude them from filesystem scan. Exclude compiled artifacts to keep scan fast.
if command -v trufflehog &>/dev/null; then
    trufflehog filesystem . --only-verified --fail \
        -x .trufflehog-exclude
else
    echo "SKIP: trufflehog not installed (brew install trufflehog)"
fi

# Syft + Grype — SBOM generation and CVE scanning
if command -v syft &>/dev/null && command -v grype &>/dev/null; then
    syft . -o cyclonedx-json > /tmp/stacks-sbom.json
    grype sbom:/tmp/stacks-sbom.json --fail-on high
    rm -f /tmp/stacks-sbom.json
else
    echo "SKIP: syft/grype not installed (brew install syft grype)"
fi

# dbt-checkpoint quality gates moved to scripts/lint-dbt.sh (runs in dbt CI group).
# See: just lint-dbt

# Dockle — CIS Docker Benchmark for each Dockerfile
if command -v dockle &>/dev/null; then
    if command -v docker &>/dev/null; then
        echo "Running dockle CIS benchmark..."
        docker build -q -t stacks-dockle-core -f deploy/Dockerfile.core . && \
            docker save stacks-dockle-core -o /tmp/stacks-dockle-core.tar && \
            dockle --exit-code 1 --exit-level WARN --input /tmp/stacks-dockle-core.tar
        docker build -q -t stacks-dockle-scraper -f deploy/Dockerfile.scraper . && \
            docker save stacks-dockle-scraper -o /tmp/stacks-dockle-scraper.tar && \
            dockle --exit-code 1 --exit-level WARN --input /tmp/stacks-dockle-scraper.tar
        docker rmi stacks-dockle-core stacks-dockle-scraper 2>/dev/null || true
        rm -f /tmp/stacks-dockle-core.tar /tmp/stacks-dockle-scraper.tar
    else
        echo "SKIP: docker not available — cannot run dockle (dockle requires a built image)"
    fi
else
    echo "SKIP: dockle not installed (brew install goodwithtech/r/dockle)"
fi
