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
            erlang_27
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
            # Install flyctl from GitHub releases (superfly/homebrew-tap is abandoned)
            if ! command -v flyctl &> /dev/null && ! test -x "$HOME/.local/bin/flyctl"; then
              bash scripts/install-flyctl.sh
            fi
            # Install Python-based tools via pip if not already available
            if ! command -v dbt &> /dev/null; then
              echo "Installing dbt-postgres..."
              pip install --quiet dbt-postgres
            fi
            if ! command -v dbt-checkpoint &> /dev/null; then
              echo "Installing dbt-checkpoint..."
              pip install --quiet dbt-checkpoint
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
