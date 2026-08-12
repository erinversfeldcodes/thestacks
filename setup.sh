#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

SKIP_DB=false
for arg in "$@"; do
    [[ "$arg" == "--no-db" ]] && SKIP_DB=true
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}${BOLD}[setup]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[warn]${RESET}  $*"; }
fail()    { echo -e "${RED}${BOLD}[fail]${RESET}  $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${RESET}"; }

step "Homebrew"
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"  # nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    success "Homebrew $(brew --version | head -1 | awk '{print $2}') already installed"
fi

step "Git LFS"
if command -v git-lfs &>/dev/null || git lfs version &>/dev/null 2>&1; then
    info "Pulling LFS objects (textures, concept images)..."
    git lfs pull
    success "LFS objects up to date"
else
    warn "git-lfs not installed — texture images will be stubs. Install via: brew install git-lfs"
fi

step "Homebrew packages (Brewfile)"
info "Running brew bundle..."
brew bundle
success "All Brewfile packages installed"

PG_BIN="$(brew --prefix postgresql@16)/bin"
export PATH="$PG_BIN:$PATH"

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

step "Nix"
if command -v nix &>/dev/null; then
    success "Nix $(nix --version | awk '{print $NF}') already installed"
else
    info "Installing Nix (Determinate Systems installer)..."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix/tag/v3.21.5 \
        | sh -s -- install --no-confirm  # nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
    if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
        # shellcheck disable=SC1091
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    success "Nix installed"
fi

step "direnv (Nix dev shell activation)"
if command -v direnv &>/dev/null; then
    if [[ ! -f "$REPO_ROOT/.envrc" ]]; then
        echo "use flake" > "$REPO_ROOT/.envrc"
        info "Created .envrc"
    fi
    direnv allow "$REPO_ROOT" 2>/dev/null || true
    success "direnv configured — Nix dev shell activates on cd"

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

step "Runtime versions (mise)"

eval "$(mise activate bash)" 2>/dev/null || true

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

step "Elixir (hex, rebar, deps)"
info "Installing hex and rebar..."
mix local.hex --force --if-missing
mix local.rebar --force --if-missing

info "Installing Mix dependencies..."
mix deps.get

success "Elixir dependencies installed"

step "Ecto proto schemas"
if command -v buf &>/dev/null; then
    info "Generating Ecto schemas + dbt models from .proto definitions..."
    (cd apps/core && mix proto.sync)
    success "Ecto schemas generated to apps/core/lib/stacks/gen/"
else
    warn "buf not installed — skipping proto.sync (run: brew install bufbuild/buf/buf)"
fi

step "Elm / Node"
info "Installing npm packages in frontend/..."
(cd frontend && npm ci)
success "Elm tooling installed"

SQUAWK_PINNED_VERSION="2.47.0"
if ! command -v squawk &>/dev/null; then
    info "Installing squawk-cli@${SQUAWK_PINNED_VERSION} globally..."
    npm install -g "squawk-cli@${SQUAWK_PINNED_VERSION}"
    success "squawk-cli installed"
else
    success "squawk-cli already available"
fi

step "Elm proto decoders"
if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]] && command -v buf &>/dev/null; then
    info "Generating Elm decoders from .proto schemas..."
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh"
    success "Elm proto decoders generated in proto/gen/elm/"
else
    warn "Skipping Elm proto generation (buf or gen-elm-proto.sh not found)"
fi

step "Python 3.12 virtualenv (apps/vision)"
VENV_DIR="$REPO_ROOT/apps/vision/.venv"

PYTHON_BIN="$(mise which python 2>/dev/null || command -v python3.12 || command -v python3)"

if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtualenv at apps/vision/.venv..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
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

step "Project toolchain venv at .venv-tools/ (dbt-postgres, sqlfluff, checkov, dbt-checkpoint, jwt_tool)"

TOOLS_VENV="$REPO_ROOT/.venv-tools"

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

"$TOOLS_PIP" install --upgrade --quiet pip

install_tool() {
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
if ! "$TOOLS_PIP" show sqlfluff-templater-dbt &>/dev/null; then
    info "Installing sqlfluff-templater-dbt into .venv-tools/..."
    "$TOOLS_PIP" install --quiet sqlfluff-templater-dbt
fi
install_tool "checkov" "checkov"

if [[ ! -x "$TOOLS_VENV/bin/check-model-has-description" ]]; then
    info "Installing dbt-checkpoint from GitHub into .venv-tools/..."
    "$TOOLS_PIP" install --quiet \
        "git+https://github.com/dbt-checkpoint/dbt-checkpoint.git@v2.0.8"
    success "dbt-checkpoint installed"
else
    success "dbt-checkpoint already in venv"
fi

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

export PATH="$TOOLS_VENV/bin:$PATH"

success "Project toolchain venv ready at .venv-tools/"

step "Rust (rustfmt, clippy, cargo-audit, cargo-llvm-cov)"

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

if [[ "$SKIP_DB" == "true" ]]; then
    warn "Skipping database setup (--no-db)"
else
    step "PostgreSQL"

    for other in 14 15 17 18; do
        if brew services list 2>/dev/null | grep -qE "^postgresql@${other}\s+started"; then
            warn "Stopping postgresql@${other} (aligning local on the canonical postgresql@16)..."
            brew services stop "postgresql@${other}" >/dev/null 2>&1 || true
        fi
    done
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
    server_ver_num="$(psql -h localhost -p 5432 -U postgres -d postgres -tAc "show server_version_num" 2>/dev/null || echo 0)"
    if [[ "$server_ver_num" -lt 160000 || "$server_ver_num" -ge 170000 ]]; then
        warn "The server on :5432 reports version_num=$server_ver_num, not postgresql@16. Check 'brew services list' — a non-@16 server may be holding the port."
    fi
    success "PostgreSQL (postgresql@16) is running"

    if ! psql -h localhost -p 5432 -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
        info "Creating 'postgres' superuser role (fresh cluster)..."
        psql -h localhost -p 5432 -d postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER;" >/dev/null 2>&1 \
            && success "'postgres' role created" \
            || warn "Could not create 'postgres' role — run manually: psql -d postgres -c \"CREATE ROLE postgres WITH LOGIN SUPERUSER;\""
    fi

    info "Ensuring application DB roles (stacks_app / stacks_dbt / stacks_readonly)..."
    psql -h localhost -p 5432 -U postgres -d postgres >/dev/null 2>&1 <<'SQL' \
        && success "application DB roles present" \
        || warn "Could not ensure stacks_* roles — see create_db_roles migration"
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='stacks_app') THEN
    CREATE ROLE stacks_app LOGIN PASSWORD 'stacks_app_dev';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='stacks_dbt') THEN
    CREATE ROLE stacks_dbt LOGIN PASSWORD 'stacks_dbt_dev';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='stacks_readonly') THEN
    CREATE ROLE stacks_readonly NOLOGIN;
  END IF;
END $$;
SQL

    PGVECTOR_VERSION="v0.8.0"
    PG_SHAREDIR="$("$PG_BIN/pg_config" --sharedir)"
    if [[ -f "$PG_SHAREDIR/extension/vector.control" ]]; then
        success "pgvector already installed for postgresql@16"
    else
        info "Building pgvector $PGVECTOR_VERSION for postgresql@16 from source..."
        PGVECTOR_TMP="$(mktemp -d)"
        if git clone --depth 1 --branch "$PGVECTOR_VERSION" \
                https://github.com/pgvector/pgvector.git "$PGVECTOR_TMP" 2>/dev/null \
            && make -C "$PGVECTOR_TMP" PG_CONFIG="$PG_BIN/pg_config" \
            && make -C "$PGVECTOR_TMP" PG_CONFIG="$PG_BIN/pg_config" install; then
            success "pgvector $PGVECTOR_VERSION installed for postgresql@16"
        else
            warn "pgvector build failed — vector (op.embeddings) migrations will fail until it is installed. See https://github.com/pgvector/pgvector#installation"
        fi
        rm -rf "$PGVECTOR_TMP"
    fi

    info "Clearing stale _build cache..."
    rm -rf "$REPO_ROOT/_build"

    info "Resetting dev database (stacks_dev)..."
    MIX_ENV=dev mix ecto.drop --quiet 2>/dev/null || true
    MIX_ENV=dev mix ecto.create --quiet
    MIX_ENV=dev mix ecto.migrate --quiet

    info "Loading seed fixtures..."
    MIX_ENV=dev mix run apps/core/priv/repo/seeds.exs
    success "Dev database ready with seed data"

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

step "act (GitHub Actions local runner)"
if command -v act &>/dev/null; then
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

step "Git hooks"
bash "$REPO_ROOT/scripts/install-hooks.sh"
success "Git hooks installed"

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
