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
            flyctl
          ];

          shellHook = ''
            # Install dbt-postgres via pip if not already available
            if ! command -v dbt &> /dev/null; then
              echo "Installing dbt-postgres..."
              pip install --quiet dbt-postgres
            fi
            echo "The Stacks dev environment loaded."
            echo "Run 'just dev' to start all services."
          '';
        };
      });
}
