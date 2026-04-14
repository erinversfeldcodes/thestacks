#!/usr/bin/env bash
# scripts/gen-ecto-proto.sh — Generate Ecto schemas + dbt models from proto.
#
# Bootstraps the proto.sync Mix task modules WITHOUT compiling the full app.
# This breaks the chicken-and-egg: the app needs generated schemas to compile,
# but `mix proto.sync` needs the app to compile first.
#
# Usage:
#   scripts/gen-ecto-proto.sh          # Generate all files
#   scripts/gen-ecto-proto.sh --check  # Check for drift without writing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$REPO_ROOT/apps/core"
TASK_DIR="$CORE_DIR/lib/mix/tasks"

# If the app compiles cleanly, prefer the Mix task (faster, uses compiled beam).
if (cd "$CORE_DIR" && mix compile --no-start 2>/dev/null); then
    cd "$CORE_DIR" && mix proto.sync "$@"
    exit $?
fi

# Fallback: load just the proto_sync modules + Jason via elixir script mode.
# This works even when the app has missing modules (e.g., during bootstrap).
echo "==> App won't compile yet — bootstrapping proto.sync in script mode..."

cd "$CORE_DIR"

# Ensure deps are compiled (Jason is required for descriptor parsing).
mix deps.compile jason --no-deps-check 2>/dev/null || true

# Provide dummy env vars so runtime.exs doesn't crash (we don't start the app).
# Covers both dev and prod required vars — codegen doesn't use any of these.
export CLOAK_KEY="${CLOAK_KEY:-$(openssl rand -base64 32)}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 64)}"
export DATABASE_URL="${DATABASE_URL:-ecto://localhost/stacks_dev}"
export VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-dummy_secret_for_codegen_only}"
export VISION_SERVICE_URL="${VISION_SERVICE_URL:-http://localhost:8000}"
export GUARDIAN_SECRET_KEY="${GUARDIAN_SECRET_KEY:-dummy_guardian_key_for_codegen}"

# Use mix run with --no-compile to skip app compilation but still have Mix available.
# The --no-start flag prevents starting the app (we don't need the DB).
# We eval a script that loads just the proto_sync modules.
mix run --no-compile --no-start -e '
  # Load proto_sync modules in dependency order
  task_dir = "lib/mix/tasks/proto_sync"
  for mod <- ~w(manifest.ex type_mapper.ex descriptor.ex ecto_generator.ex dbt_generator.ex migration_generator.ex schema_yml_generator.ex drift_checker.ex) do
    Code.compile_file(Path.join(task_dir, mod))
  end
  Code.compile_file("lib/mix/tasks/proto_sync.ex")

  args = System.argv()
  Mix.Tasks.Proto.Sync.run(args)
' -- "$@"
