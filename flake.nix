{
  description = "The Stacks - book management platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Elixir / Erlang
            elixir_1_18
            erlang_28
            rebar3

            # Frontend
            nodejs_22
            elmPackages.elm
            elmPackages.elm-format
            elmPackages.elm-test

            # Rust
            rustc
            cargo
            clippy
            rustfmt
            cargo-audit
            cargo-fuzz

            # Python
            python312
            python312Packages.pip
            python312Packages.mypy

            # Database
            postgresql_16

            # Protobuf
            buf

            # dbt — installed via pip in shellHook for reliable postgres adapter support

            # Tools
            just
            ruff
            # flyctl is NOT installed via nixpkgs — the superfly/homebrew-tap has not
            # been updated in ~2 years. Use scripts/install-flyctl.sh instead.

            # Security toolchain
            gitleaks
            semgrep
            hadolint
            trivy
            trufflehog
            syft
            grype
            nuclei
          ];

          shellHook = ''
            # Marker so scripts can detect "this command is already running
            # inside the project devShell" without relying on Nix's
            # implementation-specific `IN_NIX_SHELL` semantics. Set early so
            # subshells inherit it. Used by scripts/hooks/lib/update-pr-ci.sh
            # to skip the `nix develop --command` re-entry in the pre-push
            # hook when the operator is already in the dev shell.
            export STACKS_DEV_SHELL=1

            # Nixpkgs-unstable packages `semgrep` as a Python 3.13 application,
            # which means entering this dev-shell appends every Python 3.13
            # dependency (pydantic-core, attrs, etc.) to PYTHONPATH. The
            # project's own venv is Python 3.12 (see `python312` above plus
            # apps/vision/pyproject.toml requires-python = ">=3.12"), so the
            # venv's interpreter picks up 3.13-compiled .so files from Nix's
            # PYTHONPATH, fails to import pydantic_core._pydantic_core, and
            # pytest breaks with a cryptic ABI-mismatch trace.
            #
            # Venvs are Python's designated isolation boundary, but the
            # language honours PYTHONPATH over the venv's own site-packages,
            # so no venv-side patch fixes this. We unset PYTHONPATH here
            # instead — Nix-packaged Python tools (semgrep, the checkov
            # install etc.) have wrapper scripts that set their own
            # PYTHONPATH at invocation time, so they still work.
            unset PYTHONPATH

            # Install flyctl from GitHub releases (superfly/homebrew-tap is abandoned)
            if ! command -v flyctl &> /dev/null && ! test -x "$HOME/.local/bin/flyctl"; then
              bash scripts/install-flyctl.sh
            fi
            # Install Python-based tools via pip if not already available
            if ! command -v dbt &> /dev/null; then
              echo "Installing dbt-postgres..."
              pip install --quiet dbt-postgres
            fi
            # dbt-checkpoint installs check-model-has-description and friends;
            # there's no `dbt-checkpoint` binary, so check for a known one instead.
            if ! command -v check-model-has-description &> /dev/null; then
              echo "Installing dbt-checkpoint..."
              pip install --quiet 'git+https://github.com/dbt-checkpoint/dbt-checkpoint.git@v2.0.8' 2>/dev/null || \
                echo "  (skipped: pip blocked by PEP 668 — install via setup.sh outside Nix shell)"
            fi
            if ! command -v jwt_tool &> /dev/null; then
              echo "Installing jwt_tool..."
              pip install --quiet jwt_tool
            fi
            # checkov is Python-based; install via pip for reliable version management
            if ! command -v checkov &> /dev/null; then
              echo "Installing checkov..."
              pip install --quiet checkov
            fi
            echo "The Stacks dev environment loaded."
            echo "Run 'just dev' to start all services."
          '';
        };
      });
}
