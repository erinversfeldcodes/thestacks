#!/usr/bin/env bash
set -euo pipefail

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

gitleaks detect --source . --config .gitleaks.toml

semgrep scan --config auto --error

hadolint deploy/Dockerfile.core
hadolint deploy/Dockerfile.scraper

checkov --directory deploy/

trivy fs . --severity CRITICAL,HIGH --exit-code 1 \
    --skip-dirs apps/vision/.venv \
    --skip-dirs .venv-tools \
    --skip-dirs scripts/mcp/.venv \
    --skip-dirs .claude/worktrees \
    --skip-files apps/core/erl_crash.dump

if command -v trufflehog &>/dev/null; then
    trufflehog filesystem . --only-verified --fail \
        -x .trufflehog-exclude
else
    echo "SKIP: trufflehog not installed (brew install trufflehog)"
fi

if command -v syft &>/dev/null && command -v grype &>/dev/null; then
    syft . -o cyclonedx-json \
        --exclude ./apps/scraper/target \
        --exclude ./apps/vision/.venv \
        --exclude ./.venv-tools \
        --exclude ./scripts/mcp/.venv \
        --exclude ./_build \
        --exclude ./.claude/worktrees \
        --exclude './deps/*/rebar.lock' \
        2>/dev/null > /tmp/stacks-sbom.json
    grype sbom:/tmp/stacks-sbom.json --fail-on high
    rm -f /tmp/stacks-sbom.json
else
    echo "SKIP: syft/grype not installed (brew install syft grype)"
fi

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
        # The DAEMON, not just the client. `command -v docker` and `docker buildx
        # version` both answer from the CLI alone, so with Docker Desktop stopped
        # every check above passed and the build failed — reported as
        # "FAIL dockle", which reads as a CIS finding against the Dockerfile
        # rather than as "this gate could not run". A gate whose inability to run
        # is indistinguishable from a real finding is worse than one that says so.
        #
        # This only converts an unreachable daemon into a SKIP. In CI the daemon
        # is reachable, so a genuine build failure still fails.
        if ! docker info &>/dev/null; then
            echo "SKIP: dockle — the docker daemon is not reachable (the CLI is installed but nothing is listening), so no image could be built to scan. Start Docker, or rely on CI to gate this."
        elif docker buildx version &>/dev/null; then
            echo "Running dockle CIS benchmark..."
            _dockle_image stacks-dockle-core deploy/Dockerfile.core
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
