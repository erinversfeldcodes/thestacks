#!/usr/bin/env bash
#
# Runs dbt against a DEPLOYED database, derived from DATABASE_URL.
#
# WHY THIS EXISTS AS A SCRIPT  Three things needed the same sequence and each
# had a different, broken version of it:
#
#   * scripts/test-deployed.sh invoked `dbt run --target preview`. There is no
#     `preview` target — dbt/profiles.yml declares exactly one output — so the
#     command could never resolve, and the script printed FAIL and carried on
#     with exit 0. A script that cannot succeed and cannot fail is worse than
#     no script.
#   * The scheduled refresh did not exist. `DbtRefreshJob`'s crontab entry fired
#     from a machine configured to scale to zero, shelling a binary the runtime
#     image does not contain.
#   * dbt/macros/drop_orphan_relations.sql was written, proven on a dev
#     database, and invoked by nothing. This project has shipped a runner
#     nothing calls before; this is the caller.
#
# THE ORPHAN SWEEP RUNS FIRST, AND THAT ORDER IS THE POINT  Deleting a dbt
# model file does not drop the relation it built, and the model-drift gate
# compares files to the manifest rather than to the database — so it is
# structurally blind to the difference. A dev database held 15 relations in
# `marts` against 4 model files. On a deployed stack that was harmless only
# because dbt had never run there; the first successful refresh is exactly when
# it stops being harmless, and the eleven stale views would then sit in `marts`
# failing on SELECT rather than on build, with every gate green.
#
# ONE TARGET, NOT A PER-ENVIRONMENT ONE  dbt/profiles.yml is entirely env-var
# driven, so the same output serves local and deployed. Adding a `preview`
# target would re-create the class of bug that a name can be written without the
# thing existing. What this script adds instead is a check that the host is
# actually remote, and a line in the log naming the database that was built —
# so "which database did this touch?" is answerable from the output.
#
# Usage:
#   DATABASE_URL=postgres://… bash scripts/dbt-deployed.sh            # build
#   DATABASE_URL=postgres://… bash scripts/dbt-deployed.sh --allow-local
#
# Exit codes: 0 build succeeded · 1 a real failure · 2 nothing was run.

set -uo pipefail

EXIT_NOTHING_RUN=2

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ALLOW_LOCAL=0
if [[ "${1:-}" == "--allow-local" ]]; then
    ALLOW_LOCAL=1
    shift
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "ERROR: DATABASE_URL is required — it is what names the database to build." >&2
    echo "       Nothing was run." >&2
    exit "$EXIT_NOTHING_RUN"
fi

if ! command -v dbt &>/dev/null; then
    echo "SKIP: dbt is not on PATH. Nothing was run — this is a SKIP, not a pass." >&2
    exit "$EXIT_NOTHING_RUN"
fi

# Parsed in python rather than with a regex: a Neon password contains URL-escaped
# characters often enough that a hand-rolled split is a latent outage, and the
# components are passed to dbt as separate env vars anyway.
#
# The parsed values are printed as separate lines and read back here, so the
# password never becomes part of a command line (where `ps` would show it) and
# never reaches GITHUB_ENV.
_parsed="$(DATABASE_URL="$DATABASE_URL" python3 - <<'PY'
import os
import sys
from urllib.parse import unquote, urlparse

parsed = urlparse(os.environ["DATABASE_URL"])
if parsed.scheme not in ("postgres", "postgresql"):
    print(f"unsupported scheme: {parsed.scheme}", file=sys.stderr)
    raise SystemExit(1)

host = parsed.hostname or ""
dbname = (parsed.path or "/").lstrip("/")
if not host or not dbname:
    print("DATABASE_URL is missing a host or a database name", file=sys.stderr)
    raise SystemExit(1)

for value in (
    host,
    str(parsed.port or 5432),
    unquote(parsed.username or ""),
    unquote(parsed.password or ""),
    dbname,
):
    print(value)
PY
)" || {
    echo "ERROR: could not parse DATABASE_URL. Nothing was run." >&2
    exit "$EXIT_NOTHING_RUN"
}

{
    IFS= read -r DBT_HOST
    IFS= read -r DBT_PORT
    IFS= read -r DBT_USER
    IFS= read -r DBT_PASSWORD
    IFS= read -r DBT_DBNAME
} <<< "$_parsed"
unset _parsed

# The guard the phantom target never had. A deployed refresh that silently
# built localhost would report success having touched nothing anyone deploys —
# the same shape of green-on-nothing this script replaces.
if [[ "$ALLOW_LOCAL" -ne 1 ]]; then
    case "$DBT_HOST" in
        localhost | 127.0.0.1 | ::1 | *.localhost | *.test)
            echo "ERROR: DATABASE_URL points at '$DBT_HOST', which is local." >&2
            echo "       This script exists to build a DEPLOYED warehouse; pass" >&2
            echo "       --allow-local if a local build is really what you want." >&2
            echo "       Nothing was run." >&2
            exit "$EXIT_NOTHING_RUN"
            ;;
    esac
fi

# Connect as the least-privilege warehouse role when its password is supplied,
# keeping only the host/port/database from DATABASE_URL.
#
# ⚠️ This is the strongest available assertion that the warehouse grants are
# real. For months every grant was aimed at a role that did not exist on any
# deployed database, and because each one is wrapped in
# `IF EXISTS (SELECT FROM pg_roles …)` the migrations granted nothing and
# reported success. Running the build AS `stacks_dbt` means a missing grant
# fails the build instead of passing silently — the privileges are exercised
# rather than described.
#
# The password cannot come from the Neon API: Neon stores credentials only for
# roles it created itself, and `stacks_dbt` is created by a migration. So it is
# held as a secret on both sides, which is the cost of this posture and is worth
# stating rather than discovering.
#
# Absent, the run falls back to DATABASE_URL's own role — which is the database
# owner on a Neon stack. That is a wider blast radius, so it says so.
if [[ -n "${STACKS_DBT_DB_PASSWORD:-}" ]]; then
    DBT_USER="stacks_dbt"
    DBT_PASSWORD="$STACKS_DBT_DB_PASSWORD"
else
    echo "NOTE: STACKS_DBT_DB_PASSWORD is unset — connecting as DATABASE_URL's own role"
    echo "      (the database owner on a Neon stack), so the warehouse grants are not"
    echo "      exercised by this run."
fi

export DBT_HOST DBT_PORT DBT_USER DBT_PASSWORD DBT_DBNAME

# Named in the log, because the whole failure this replaces was not knowing
# which database a green run had built. The password is not printed and is not
# part of any command line.
echo "dbt target: ${DBT_USER}@${DBT_HOST}:${DBT_PORT}/${DBT_DBNAME}"
echo ""

cd "$REPO_ROOT/dbt"

echo "=== dbt deps ==="
if ! dbt deps; then
    echo "ERROR: dbt deps failed." >&2
    exit 1
fi

# Report first, then drop. The report is what goes in the run log; the drop is
# what makes the build correct. Splitting them means the log says what was
# removed even when the removal itself is uneventful.
echo ""
echo "=== dbt run-operation drop_orphan_relations (report) ==="
if ! dbt run-operation drop_orphan_relations; then
    echo "ERROR: the orphan-relation report failed. Refusing to build on top of" >&2
    echo "       a warehouse whose contents could not be enumerated." >&2
    exit 1
fi

echo ""
echo "=== dbt run-operation drop_orphan_relations (apply) ==="
if ! dbt run-operation drop_orphan_relations --args '{dry_run: false}'; then
    echo "ERROR: dropping orphan relations failed." >&2
    exit 1
fi

# `build` rather than `run` then `test`: it interleaves them so a model whose
# test fails does not have its downstream models built on top of it. The old
# script ran them separately AND treated a failing test as a warning, so a mart
# could be built from data its own test rejected.
#
# `--full-refresh`, and this is not belt-and-braces — it is what makes the
# warehouse's correctness and its erasure guarantee true.
#
# Both incremental marts key their window on the surviving rows'
# `created_at`/`updated_at`. A DELETE upstream updates no surviving row, so a
# deleted entity never enters the window and its mart row persists forever.
# Measured on a development database: a book's `read_count` read 3, one of its
# placements was hard-deleted (which is exactly what an account erasure's FK
# cascade does), the true count became 2, an incremental refresh ran and
# selected nothing (`INSERT 0 0`), and the mart still read **3**.
#
# So without this flag every account erasure permanently inflates the community
# read count of every book that user had shelved, with no error anywhere — and
# `test_mart_community_read_count_excludes_removed` passes throughout, because
# it covers the soft-removal (`removed_at`) path rather than the deletion one.
#
# The cost is acceptable precisely here: this is the DAILY pass over 150-ish and
# 169-ish rows, and its job is to make the warehouse true. The event-driven
# selective refresh (`DbtRefreshJob`) stays incremental for latency — it answers
# "this changed just now", not "everything is correct".
echo ""
echo "=== dbt build --full-refresh ==="
if ! dbt build --full-refresh; then
    echo "ERROR: dbt build failed." >&2
    exit 1
fi

echo ""
echo "dbt build succeeded against ${DBT_HOST}/${DBT_DBNAME}"
