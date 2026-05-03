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
    syft . -o cyclonedx-json \
        --exclude ./apps/scraper/target \
        --exclude ./apps/vision/.venv \
        --exclude ./_build \
        --exclude ./.claude/worktrees \
        2>/dev/null > /tmp/stacks-sbom.json
    grype sbom:/tmp/stacks-sbom.json --fail-on high
    rm -f /tmp/stacks-sbom.json
else
    echo "SKIP: syft/grype not installed (brew install syft grype)"
fi

# dbt-checkpoint quality gates moved to scripts/lint-dbt.sh (runs in dbt CI group).
# See: just lint-dbt

# Dockle — CIS Docker Benchmark for each Dockerfile.
#
# Each image is built with BuildKit enabled (required by Dockerfile.core's
# `RUN --mount=type=cache` directives), saved to a tarball, then scanned by
# dockle. Build/save failures are surfaced as script failures — the previous
# `&& \` chain swallowed them because `set -e` is suspended for non-final
# commands in `&&` lists (per bash(1)).
_dockle_image() {
    local name="$1"
    local dockerfile="$2"
    local tar="/tmp/${name}.tar"

    if ! DOCKER_BUILDKIT=1 docker build -q -t "$name" -f "$dockerfile" .; then
        echo "FAIL dockle: docker build failed for $dockerfile" >&2
        return 1
    fi
    if ! docker save "$name" -o "$tar"; then
        echo "FAIL dockle: docker save failed for $name" >&2
        docker rmi "$name" 2>/dev/null || true
        return 1
    fi
    local rc=0
    dockle --exit-code 1 --exit-level WARN --input "$tar" || rc=$?
    rm -f "$tar"
    docker rmi "$name" 2>/dev/null || true
    return "$rc"
}

if command -v dockle &>/dev/null; then
    if command -v docker &>/dev/null; then
        # Dockerfile.core uses `RUN --mount=type=cache` (BuildKit-only).
        # The legacy builder rejects it; `DOCKER_BUILDKIT=1 docker build`
        # also fails if the buildx CLI plugin isn't installed (colima's
        # default ships without it). Probe before attempting the build
        # so the SKIP path is taken cleanly rather than failing mid-run.
        # Install via `brew install docker-buildx && mkdir -p \
        #   ~/.docker/cli-plugins && ln -s \
        #   "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" \
        #   ~/.docker/cli-plugins/docker-buildx`.
        if docker buildx version &>/dev/null; then
            echo "Running dockle CIS benchmark..."
            _dockle_image stacks-dockle-core deploy/Dockerfile.core
            # The scraper image cross-compiles Rust to x86_64-linux-musl.
            # On non-Linux/x86_64 hosts (typically darwin/arm64 dev
            # laptops) the cargo-chef stage hits a ring@0.17.x
            # `musl-gcc -m64` mismatch before dockle ever runs. Skip
            # the local scan on those hosts; CI runs on Linux/x86_64
            # and exercises this gate properly.
            if [[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]]; then
                _dockle_image stacks-dockle-scraper deploy/Dockerfile.scraper
            else
                echo "SKIP: dockle scraper image — host $(uname -s)/$(uname -m) cannot cross-build to x86_64-linux-musl reliably (ring@0.17 musl-gcc -m64 mismatch). CI gates this on Linux/x86_64."
            fi
        else
            echo "SKIP: dockle — docker buildx plugin not installed. Dockerfile.core requires BuildKit (RUN --mount=type=cache). Install via 'brew install docker-buildx' on macOS or rely on CI to gate this."
        fi
    else
        echo "SKIP: docker not available — cannot run dockle (dockle requires a built image)"
    fi
else
    echo "SKIP: dockle not installed (brew install goodwithtech/r/dockle)"
fi
