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
            # cargo-llvm-cov needs llvm-cov + llvm-profdata to compute Rust
            # coverage. Nix-managed Rust isn't rustup-managed, so the standard
            # `rustup component add llvm-tools-preview` path doesn't apply.
            # Pulling `llvm` into the devShell and exporting LLVM_COV /
            # LLVM_PROFDATA in shellHook gives cargo-llvm-cov the binaries it
            # discovers via env-var contract.
            llvm

            # Python
            python312
            python312Packages.pip
            python312Packages.mypy

            # Database
            postgresql_16

            # Protobuf
            buf

            # dbt + sqlfluff + dbt-checkpoint + checkov + jwt_tool live in
            # `.venv-tools/`, materialised by `./setup.sh`. shellHook prepends
            # that venv to PATH so the same wrappers and libs travel together
            # in every shell (interactive, hook subshell, --command).

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

            # Project toolchain venv. setup.sh owns its creation + the pip
            # installs (sqlfluff, dbt-postgres, dbt-checkpoint, checkov,
            # jwt_tool). shellHook just exposes it on PATH so every subshell
            # — including non-direnv contexts like the pre-push hook — sees
            # the same wrappers backed by a single Python and site-packages.
            if [[ -d "$PWD/.venv-tools/bin" ]]; then
              export PATH="$PWD/.venv-tools/bin:$PATH"
            else
              echo "warning: .venv-tools/ not found — run \`./setup.sh\` to install dbt/sqlfluff/checkov/dbt-checkpoint."
            fi

            # cargo-llvm-cov contract: read LLVM tools from env vars when not
            # using rustup. Nix's `llvm` package puts these on PATH inside
            # the devShell, so resolving with `command -v` is safe.
            if command -v llvm-cov &> /dev/null; then
              export LLVM_COV="$(command -v llvm-cov)"
              export LLVM_PROFDATA="$(command -v llvm-profdata)"
            fi

            echo "The Stacks dev environment loaded."
            echo "Run 'just dev' to start all services."
          '';
        };
      });
}
