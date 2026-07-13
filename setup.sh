#!/usr/bin/env bash
# setup.sh — one-shot bootstrap for The Stacks development environment.
#
# Idempotent: safe to run multiple times. Each step checks whether it is
# already complete before doing work.
#
# What this script does:
#   1. Install Homebrew (if missing)
#   2. brew bundle (installs Brewfile: mise, postgresql@16, buf, just, colima, …)
#   3. Install runtimes via mise (Elixir 1.18.1, Erlang 27, Node 22, Python 3.12, Rust 1.87)
#   4. Install Elixir tooling (hex, rebar, deps)
#   5. Install Elm tooling (npm deps in frontend/)
#   6. Create Python 3.12 virtualenv for apps/vision and install pip deps
#   6b. Create Python 3.13+ virtualenv for scripts/mcp (project tools MCP server)
#   7. Install pip-based global tools (dbt-postgres, sqlfluff, checkov, dbt-checkpoint)
#   8. Install Rust components (rustfmt, clippy, llvm-tools-preview), cargo-audit, cargo-llvm-cov
#   9. Ensure PostgreSQL is running and create the dev database + run migrations
#  10. Load seed fixtures into the dev database
#  11. Print a summary of what is ready
#
# Usage:
#   ./setup.sh            full setup
#   ./setup.sh --no-db    skip database steps (useful for CI prep containers)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

SKIP_DB=false
for arg in "$@"; do
    [[ "$arg" == "--no-db" ]] && SKIP_DB=true
done

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}${BOLD}[setup]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[warn]${RESET}  $*"; }
fail()    { echo -e "${RED}${BOLD}[fail]${RESET}  $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── 1. Homebrew ────────────────────────────────────────────────────────────────
step "Homebrew"
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"  # nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
    # Add brew to PATH for the rest of this script (Apple Silicon)
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    success "Homebrew $(brew --version | head -1 | awk '{print $2}') already installed"
fi

# ── 1b. Git LFS — pull large binary assets (textures, images) ─────────────────
# Without this, texture files in frontend/public/textures/ are 132-byte LFS
# pointer stubs, causing blank bookshelves and missing wallpapers in the UI.
step "Git LFS"
if command -v git-lfs &>/dev/null || git lfs version &>/dev/null 2>&1; then
    info "Pulling LFS objects (textures, concept images)..."
    git lfs pull
    success "LFS objects up to date"
else
    warn "git-lfs not installed — texture images will be stubs. Install via: brew install git-lfs"
fi

# ── 2. Brewfile ────────────────────────────────────────────────────────────────
step "Homebrew packages (Brewfile)"
info "Running brew bundle..."
brew bundle
success "All Brewfile packages installed"

# Ensure postgresql@16 bin is on PATH (keg-only formula)
PG_BIN="$(brew --prefix postgresql@16)/bin"
export PATH="$PG_BIN:$PATH"

# ── 2a. Docker buildx CLI plugin ─────────────────────────────────────────────
# `brew install docker-buildx` (in Brewfile) drops the binary at
# $(brew --prefix docker-buildx)/bin/docker-buildx, but `docker buildx`
# only auto-discovers plugins in ~/.docker/cli-plugins/. Symlinking
# bridges the two so Dockerfile.core's BuildKit-only `RUN --mount=...`
# syntax actually works locally — and so scripts/security.sh's dockle
# stage runs the real CIS scan instead of taking its skip path.
# Idempotent: ln -sf overwrites any stale link without erroring.
step "Docker buildx CLI plugin"
if command -v docker &>/dev/null && brew list docker-buildx &>/dev/null; then
    BUILDX_BIN="$(brew --prefix docker-buildx)/bin/docker-buildx"
    BUILDX_PLUGIN="$HOME/.docker/cli-plugins/docker-buildx"
    mkdir -p "$HOME/.docker/cli-plugins"
    if [[ -x "$BUILDX_BIN" ]]; then
        ln -sf "$BUILDX_BIN" "$BUILDX_PLUGIN"
        if docker buildx version &>/dev/null; then
            success "docker buildx ready ($(docker buildx version | head -1 | awk '{print $2}'))"
        else
            warn "Symlinked docker-buildx but \`docker buildx version\` still fails — investigate manually"
        fi
    else
        warn "docker-buildx binary not at $BUILDX_BIN — brew install may have failed"
    fi
else
    warn "docker or docker-buildx not installed — Dockerfile.core (BuildKit) won't build locally"
fi

# ── 2b. Nix ──────────────────────────────────────────────────────────────────
# flake.nix pins exact tool versions (Elixir, OTP, Node, Python) matching
# CI and Docker. Nix is required for direnv's `use flake` to work.
step "Nix"
if command -v nix &>/dev/null; then
    success "Nix $(nix --version | awk '{print $NF}') already installed"
else
    info "Installing Nix (Determinate Systems installer)..."
    # Pinned installer version (supply-chain: no floating installer). Bump
    # deliberately; see https://github.com/DeterminateSystems/nix-installer/releases
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix/tag/v3.21.5 \
        | sh -s -- install --no-confirm  # nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
    # Source Nix for the rest of this script
    if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
        # shellcheck disable=SC1091
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    success "Nix installed"
fi

# ── 2c. direnv + Nix dev shell ────────────────────────────────────────────────
# Ensures every terminal session uses the exact tool versions from flake.nix
# — no version drift between local and CI/Docker.
step "direnv (Nix dev shell activation)"
if command -v direnv &>/dev/null; then
    # Create .envrc if missing
    if [[ ! -f "$REPO_ROOT/.envrc" ]]; then
        echo "use flake" > "$REPO_ROOT/.envrc"
        info "Created .envrc"
    fi
    direnv allow "$REPO_ROOT" 2>/dev/null || true
    success "direnv configured — Nix dev shell activates on cd"

    # Ensure direnv hook is in the shell profile
    SHELL_RC="$HOME/.zshrc"
    if [[ -f "$SHELL_RC" ]] && ! grep -q 'direnv hook' "$SHELL_RC" 2>/dev/null; then
        echo '' >> "$SHELL_RC"
        echo '# direnv — auto-activate Nix dev shell on cd (added by setup.sh)' >> "$SHELL_RC"
        echo 'eval "$(direnv hook zsh)"' >> "$SHELL_RC"
        info "Added direnv hook to ~/.zshrc"
        warn "Restart your shell (or run: source ~/.zshrc) to activate"
    elif [[ -n "${DIRENV_DIR:-}" ]]; then
        success "direnv hook active in this shell"
    else
        success "direnv hook already in ~/.zshrc"
    fi
else
    warn "direnv not found (expected from brew bundle) — skipping Nix shell setup"
fi

# ── 3. Runtime versions via mise ──────────────────────────────────────────────
step "Runtime versions (mise)"

# Activate mise in this shell session
eval "$(mise activate bash)" 2>/dev/null || true

# Trust the project's .mise.toml (non-interactive)
mise trust --yes "$REPO_ROOT/.mise.toml" 2>/dev/null || true

info "Installing runtimes declared in .mise.toml..."
mise install

# Reload mise shims so subsequent commands use the right versions.
# Temporarily relax strict mode — mise activate generates shell code that
# references unset variables on second activation.
set +eu
eval "$(mise activate bash)" 2>/dev/null || true
set -eu
hash -r

success "Runtimes installed:"
mise current 2>/dev/null | sed 's/^/         /'

# ── 4. Elixir tooling ─────────────────────────────────────────────────────────
step "Elixir (hex, rebar, deps)"
info "Installing hex and rebar..."
mix local.hex --force --if-missing
mix local.rebar --force --if-missing

info "Installing Mix dependencies..."
mix deps.get

success "Elixir dependencies installed"

# ── 4b. Generate Ecto schemas from proto ────────────────────────────────────
step "Ecto proto schemas"
if command -v buf &>/dev/null; then
    info "Generating Ecto schemas + dbt models from .proto definitions..."
    (cd apps/core && mix proto.sync)
    success "Ecto schemas generated to apps/core/lib/stacks/gen/"
else
    warn "buf not installed — skipping proto.sync (run: brew install bufbuild/buf/buf)"
fi

# ── 5. Elm / Node tooling ─────────────────────────────────────────────────────
step "Elm / Node"
info "Installing npm packages in frontend/..."
(cd frontend && npm ci)
success "Elm tooling installed"

# squawk-cli — lints Postgres migrations for safety issues (runs in CI).
# Install locally so `scripts/security-squawk.sh` doesn't skip silently.
# Pinned to 2.47.0 to match the version pinned in
# .github/workflows/ci.yml (migration-safety job). Bump both in lockstep.
SQUAWK_PINNED_VERSION="2.47.0"
if ! command -v squawk &>/dev/null; then
    info "Installing squawk-cli@${SQUAWK_PINNED_VERSION} globally..."
    npm install -g "squawk-cli@${SQUAWK_PINNED_VERSION}"
    success "squawk-cli installed"
else
    success "squawk-cli already available"
fi

# ── 5b. Generate Elm proto decoders ──────────────────────────────────────────
step "Elm proto decoders"
if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]] && command -v buf &>/dev/null; then
    info "Generating Elm decoders from .proto schemas..."
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh"
    success "Elm proto decoders generated in proto/gen/elm/"
else
    warn "Skipping Elm proto generation (buf or gen-elm-proto.sh not found)"
fi

# ── 6. Python virtualenv (apps/vision) ────────────────────────────────────────
step "Python 3.12 virtualenv (apps/vision)"
VENV_DIR="$REPO_ROOT/apps/vision/.venv"

# Use the mise-managed python3.12
PYTHON_BIN="$(mise which python 2>/dev/null || command -v python3.12 || command -v python3)"

if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtualenv at apps/vision/.venv..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    # Recreate if the Python version inside the venv doesn't match 3.12
    VENV_PY_VER="$("$VENV_DIR/bin/python" --version 2>&1 | awk '{print $2}')"
    if [[ "$VENV_PY_VER" != 3.12* ]]; then
        warn "Virtualenv has Python $VENV_PY_VER, expected 3.12 — recreating..."
        rm -rf "$VENV_DIR"
        "$PYTHON_BIN" -m venv "$VENV_DIR"
    else
        success "Virtualenv already exists with Python $VENV_PY_VER"
    fi
fi

info "Installing vision app dependencies into virtualenv..."
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install -r apps/vision/requirements.txt \
                             -r apps/vision/requirements-dev.txt \
                             --quiet

success "Python virtualenv ready at apps/vision/.venv"

# ── 6b. Python virtualenv (scripts/mcp — project tools MCP server) ───────────
step "Python virtualenv (scripts/mcp)"
MCP_VENV_DIR="$REPO_ROOT/scripts/mcp/.venv"
MCP_PYTHON_BIN="$(command -v python3.13 || command -v python3.12 || command -v python3)"

if [[ ! -d "$MCP_VENV_DIR" ]]; then
    info "Creating MCP server virtualenv at scripts/mcp/.venv..."
    "$MCP_PYTHON_BIN" -m venv "$MCP_VENV_DIR"
else
    success "MCP server virtualenv already exists"
fi

info "Installing MCP server dependencies..."
"$MCP_VENV_DIR/bin/pip" install --upgrade pip --quiet
"$MCP_VENV_DIR/bin/pip" install -r scripts/mcp/requirements.txt --quiet
success "MCP server virtualenv ready at scripts/mcp/.venv"

# ── 7. Project-local toolchain venv ───────────────────────────────────────────
# Project-local venv at .venv-tools/ owns every pip-installed dev CLI:
# dbt-postgres, sqlfluff (+ dbt templater), checkov, dbt-checkpoint, and the
# Python deps for jwt_tool. Three reasons for a venv over `pip install --user`:
#
#   1. Determinism — wrapper bin and lib site-packages share one Python, so
#      `command -v sqlfluff` and `import sqlfluff` always agree.
#   2. Isolation from mise/system Python user-sites that previously held
#      half-installed copies (wrapper points to mise python; lib in system
#      python; runtime ImportError).
#   3. Reset-friendly — `rm -rf .venv-tools && ./setup.sh` rebuilds clean
#      without touching any user-global Python state.
#
# `flake.nix shellHook` prepends `.venv-tools/bin` to PATH so every shell
# (interactive, hook subshell, `nix develop --command ...`) sees the same
# CLIs without re-running pip.
step "Project toolchain venv at .venv-tools/ (dbt-postgres, sqlfluff, checkov, dbt-checkpoint, jwt_tool)"

TOOLS_VENV="$REPO_ROOT/.venv-tools"

# Pick a Python 3.12 interpreter. Prefer the one currently active (nix's
# python3 inside `nix develop`); fall back to mise.
TOOLS_PYTHON="$(command -v python3.12 || command -v python3 || true)"
if [[ -z "$TOOLS_PYTHON" ]]; then
    err "No python3.12 / python3 found on PATH — install Python 3.12 via mise or run inside \`nix develop\`."
    exit 1
fi

if [[ ! -d "$TOOLS_VENV" ]]; then
    info "Creating project toolchain venv at .venv-tools/ using $TOOLS_PYTHON..."
    "$TOOLS_PYTHON" -m venv "$TOOLS_VENV"
fi

TOOLS_PIP="$TOOLS_VENV/bin/pip"

# Quiet install; -q suppresses the "already satisfied" chatter on re-runs.
"$TOOLS_PIP" install --upgrade --quiet pip

install_tool() {
    # install_tool <pip_package> <command_to_check>
    # Verifies the command resolves to the venv (not a stale wrapper from
    # an earlier --user install elsewhere on PATH). On verification failure,
    # reinstalls — this self-heals partial-install legacy state.
    local package="$1"
    local check_cmd="${2:-$1}"
    local venv_bin="$TOOLS_VENV/bin/$check_cmd"

    if [[ -x "$venv_bin" ]] && "$venv_bin" --version &>/dev/null; then
        success "$check_cmd already in venv"
        return 0
    fi
    info "Installing $package into .venv-tools/..."
    "$TOOLS_PIP" install --quiet "$package"
}

install_tool "dbt-postgres" "dbt"
install_tool "sqlfluff" "sqlfluff"
# sqlfluff-templater-dbt has no separate binary — sqlfluff loads it
# automatically when SQLFLUFF_TEMPLATER=dbt. Install only if missing.
if ! "$TOOLS_PIP" show sqlfluff-templater-dbt &>/dev/null; then
    info "Installing sqlfluff-templater-dbt into .venv-tools/..."
    "$TOOLS_PIP" install --quiet sqlfluff-templater-dbt
fi
install_tool "checkov" "checkov"

# dbt-checkpoint is not on PyPI — install directly from GitHub.
# It installs individual check commands (check-model-has-description, etc.),
# not a single 'dbt-checkpoint' binary.
if [[ ! -x "$TOOLS_VENV/bin/check-model-has-description" ]]; then
    info "Installing dbt-checkpoint from GitHub into .venv-tools/..."
    "$TOOLS_PIP" install --quiet \
        "git+https://github.com/dbt-checkpoint/dbt-checkpoint.git@v2.0.8"
    success "dbt-checkpoint installed"
else
    success "dbt-checkpoint already in venv"
fi

# jwt_tool has no Python package — clone the repo, install its declared
# requirements into the venv, and create a wrapper script.
#
# Always (re-)install from the upstream requirements.txt rather than
# hard-coding a dep list here. jwt_tool has historically added deps
# (most recently `ratelimit`) without bumping a version we'd notice;
# pinning to its requirements.txt makes the install self-correcting on
# `git pull` + setup.sh re-run. pip skips already-satisfied packages so
# the cost on no-op runs is negligible.
JWT_TOOL_DIR="$HOME/.local/share/jwt_tool"
JWT_WRAPPER="$TOOLS_VENV/bin/jwt_tool"
if [[ -d "$JWT_TOOL_DIR/.git" ]]; then
    info "Updating jwt_tool from GitHub..."
    git -C "$JWT_TOOL_DIR" pull --quiet
else
    info "Cloning jwt_tool from GitHub..."
    git clone --quiet https://github.com/ticarpi/jwt_tool.git "$JWT_TOOL_DIR"
fi

if [[ -f "$JWT_TOOL_DIR/requirements.txt" ]]; then
    "$TOOLS_PIP" install --quiet -r "$JWT_TOOL_DIR/requirements.txt"
else
    warn "jwt_tool requirements.txt missing — falling back to known dep list"
    "$TOOLS_PIP" install --quiet termcolor cprint pycryptodomex requests ratelimit
fi

printf '#!/usr/bin/env bash\nexec "%s" "%s/jwt_tool.py" "$@"\n' \
    "$TOOLS_VENV/bin/python" "$JWT_TOOL_DIR" > "$JWT_WRAPPER"
chmod +x "$JWT_WRAPPER"
success "jwt_tool installed at .venv-tools/bin/jwt_tool"

# Make the venv visible to the rest of this script.
export PATH="$TOOLS_VENV/bin:$PATH"

success "Project toolchain venv ready at .venv-tools/"

# ── 8. Rust toolchain components ──────────────────────────────────────────────
step "Rust (rustfmt, clippy, cargo-audit, cargo-llvm-cov)"

# Ensure mise-managed cargo is on PATH
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$CARGO_HOME/bin:$PATH"

info "Adding rustfmt and clippy components..."
rustup component add rustfmt clippy 2>/dev/null || warn "rustup not managing this Rust install — components may already be present"

info "Adding llvm-tools-preview component (required by cargo-llvm-cov)..."
rustup component add llvm-tools-preview 2>/dev/null || warn "llvm-tools-preview may already be present"

if ! cargo audit --version &>/dev/null; then
    info "Installing cargo-audit..."
    cargo install cargo-audit --locked
else
    success "cargo-audit $(cargo audit --version | head -1) already installed"
fi

if ! cargo-llvm-cov --version &>/dev/null; then
    info "Installing cargo-llvm-cov..."
    cargo install cargo-llvm-cov --locked
else
    success "cargo-llvm-cov $(cargo-llvm-cov --version | head -1) already installed"
fi

success "Rust toolchain ready"

# ── 9. PostgreSQL ──────────────────────────────────────────────────────────────
if [[ "$SKIP_DB" == "true" ]]; then
    warn "Skipping database setup (--no-db)"
else
    step "PostgreSQL"

    # Start postgresql@16 if not already running
    if ! "$PG_BIN/pg_isready" -h localhost -p 5432 -q 2>/dev/null; then
        info "Starting postgresql@16..."
        brew services start postgresql@16
        info "Waiting for PostgreSQL to be ready..."
        attempts=20
        until "$PG_BIN/pg_isready" -h localhost -p 5432 -q 2>/dev/null; do
            if [[ $attempts -le 0 ]]; then
                fail "PostgreSQL did not start in time. Check: brew services list"
            fi
            sleep 1
            ((attempts--))
        done
    fi
    success "PostgreSQL is running"

    # Drop and recreate the dev database to guarantee a clean state.
    # This is intentional: setup.sh is a bootstrap script, not an upgrade path.
    # Clear _build to avoid "corrupt atom table" from stale beams compiled with
    # a different Elixir/OTP combination (e.g. Homebrew's Elixir vs mise's).
    info "Clearing stale _build cache..."
    rm -rf "$REPO_ROOT/_build"

    info "Resetting dev database (stacks_dev)..."
    MIX_ENV=dev mix ecto.drop --quiet 2>/dev/null || true
    MIX_ENV=dev mix ecto.create --quiet
    MIX_ENV=dev mix ecto.migrate --quiet

    # ── 10. Seed fixtures ──────────────────────────────────────────────────────
    info "Loading seed fixtures..."
    MIX_ENV=dev mix run apps/core/priv/repo/seeds.exs
    success "Dev database ready with seed data"

    # dbt sanity check
    if command -v dbt &>/dev/null; then
        info "Running dbt staging models..."
        env DBT_USER="${DBT_USER:-postgres}" \
            DBT_PASSWORD="${DBT_PASSWORD:-postgres}" \
            DBT_HOST="${DBT_HOST:-localhost}" \
            DBT_PORT="${DBT_PORT:-5432}" \
            DBT_DBNAME="${DBT_DBNAME:-stacks_dev}" \
            bash -c 'cd dbt && dbt run --select staging --quiet' \
            && success "dbt staging models built" \
            || warn "dbt staging run failed — check dbt/logs/ for details"
    fi
fi

# ── 11. act (local CI runner) ──────────────────────────────────────────────────
step "act (GitHub Actions local runner)"
if command -v act &>/dev/null; then
    # Create .actrc with default settings if missing
    if [[ ! -f "$REPO_ROOT/.actrc" ]]; then
        cat > "$REPO_ROOT/.actrc" <<'EOF'
-P ubuntu-latest=catthehacker/ubuntu:act-latest
--env GITHUB_TOKEN
EOF
        info "Created .actrc with default runner image"
    fi
    success "act ready — run individual CI jobs with: act -j test-elixir"
else
    warn "act not found (expected from brew bundle)"
fi

# ── 12. Git hooks ──────────────────────────────────────────────────────────────
step "Git hooks"
bash "$REPO_ROOT/scripts/install-hooks.sh"
success "Git hooks installed"

# ── 12. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  The Stacks dev environment is ready.${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Start all services:   just dev"
echo "  Run all tests:        just test"
echo "  Run CI checks:        scripts/ci.sh"
echo "  Format code:          just format"
echo ""
echo "  Python virtualenv:    source apps/vision/.venv/bin/activate"
echo ""

# Remind about tools that need Nix or that weren't installed
MISSING=()
command -v buf      &>/dev/null || MISSING+=("buf (brew install bufbuild/buf/buf)")
command -v semgrep  &>/dev/null || MISSING+=("semgrep (brew install semgrep)")
command -v checkov  &>/dev/null || MISSING+=("checkov (pip install checkov)")
command -v trivy    &>/dev/null || MISSING+=("trivy (brew install trivy)")
command -v gitleaks &>/dev/null || MISSING+=("gitleaks (brew install gitleaks)")
command -v nuclei         &>/dev/null || MISSING+=("nuclei (brew install nuclei)")
command -v trufflehog     &>/dev/null || MISSING+=("trufflehog (brew install trufflehog)")
command -v syft           &>/dev/null || MISSING+=("syft (brew install syft)")
command -v grype          &>/dev/null || MISSING+=("grype (brew install grype)")
command -v dockle         &>/dev/null || MISSING+=("dockle (brew install goodwithtech/r/dockle)")
docker buildx version &>/dev/null     || MISSING+=("docker buildx (brew install docker-buildx; setup.sh symlinks the plugin)")
command -v squawk         &>/dev/null || MISSING+=("squawk-cli (npm install -g squawk-cli)")
command -v check-model-has-description &>/dev/null || MISSING+=("dbt-checkpoint (pip install git+https://github.com/dbt-checkpoint/dbt-checkpoint.git@v2.0.8)")
command -v jwt_tool       &>/dev/null || MISSING+=("jwt_tool (run: git clone https://github.com/ticarpi/jwt_tool ~/.local/share/jwt_tool)")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Optional tools not found (install manually):${RESET}"
    for m in "${MISSING[@]}"; do echo "    • $m"; done
    echo ""
fi

echo -e "  ${BLUE}Prefer Nix?${RESET}  nix develop  (uses flake.nix for exact version pinning)"
echo ""
