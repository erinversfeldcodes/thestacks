# Brewfile — all Homebrew dependencies for The Stacks
# Install everything: brew bundle
# Check what's missing: brew bundle check

# ── Taps ──────────────────────────────────────────────────────────────────────
tap "bufbuild/buf"           # buf (protobuf toolchain)
tap "oven-sh/bun"            # bun (optional JS runtime, not required)
tap "superfly/tap"           # flyctl
tap "goodwithtech/r"         # dockle

# ── Runtime version manager ───────────────────────────────────────────────────
# mise manages Elixir, Erlang, Node, Python, and Rust at the exact versions
# declared in .mise.toml (mirroring flake.nix / Dockerfiles).
brew "mise"

# ── Nix dev shell activation ─────────────────────────────────────────────────
# direnv + .envrc activates the Nix flake dev shell automatically on cd,
# ensuring all tools match the versions pinned in flake.nix.
brew "direnv"

# ── Database ──────────────────────────────────────────────────────────────────
brew "postgresql@16"

# ── Protobuf ──────────────────────────────────────────────────────────────────
brew "bufbuild/buf/buf"

# ── Task runner ───────────────────────────────────────────────────────────────
brew "just"

# ── Docker / container runtime ────────────────────────────────────────────────
# Colima is a lightweight Docker-compatible runtime for macOS.
brew "colima"
brew "docker"
brew "docker-compose"

# ── Deployment ────────────────────────────────────────────────────────────────
brew "superfly/tap/flyctl"

# ── Security scanning (for scripts/security.sh / CI) ─────────────────────────
brew "gitleaks"
brew "hadolint"
brew "nuclei"
brew "semgrep"
brew "trivy"
brew "trufflehog"
brew "syft"
brew "grype"
brew "goodwithtech/r/dockle"
# checkov installed via pip (see setup.sh); jwt_tool cloned from GitHub (not on PyPI)

# ── Misc dev tools ────────────────────────────────────────────────────────────
brew "gh"
brew "git"
brew "curl"
brew "jq"
