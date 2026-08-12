#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$REPO_ROOT/apps/core"
TASK_DIR="$CORE_DIR/lib/mix/tasks"

if (cd "$CORE_DIR" && mix compile --no-start 2>/dev/null); then
    cd "$CORE_DIR" && mix proto.sync "$@"
    exit $?
fi

echo "==> App won't compile yet — bootstrapping proto.sync in script mode..."

cd "$CORE_DIR"

mix deps.compile jason --no-deps-check 2>/dev/null || true

export CLOAK_KEY="${CLOAK_KEY:-$(openssl rand -base64 32)}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 64)}"
export DATABASE_URL="${DATABASE_URL:-ecto://localhost/stacks_dev}"
export VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-dummy_secret_for_codegen_only}"
export VISION_SERVICE_URL="${VISION_SERVICE_URL:-http://localhost:8000}"
export GUARDIAN_SECRET_KEY="${GUARDIAN_SECRET_KEY:-dummy_guardian_key_for_codegen}"

mix run --no-compile --no-start -e '
  task_dir = "lib/mix/tasks/proto_sync"
  for dep <- ~w(type_mapper.ex descriptor.ex manifest.ex), do: Code.compile_file(Path.join(task_dir, dep))
  for file <- Path.wildcard(Path.join(task_dir, "*.ex")) |> Enum.sort() do
    Code.compile_file(file)
  end
  Code.compile_file("lib/mix/tasks/proto_sync.ex")

  args = System.argv()
  Mix.Tasks.Proto.Sync.run(args)
' -- "$@"
