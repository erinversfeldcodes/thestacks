#!/usr/bin/env bash
#
# Rotate the `stacks_app` / `stacks_dbt` role passwords on ONE database.
#
# These roles are created by migration 20261016150000, which treats an absent
# password as "create the role NOLOGIN". Because a migration runs ONCE, a run
# without the passwords leaves the roles permanently unusable and no later
# migration repairs them — so this script exists to set them directly.
#
# ⛔ NOTHING HERE PRINTS A CREDENTIAL. The passwords arrive in the environment,
# are interpolated into DDL (`ALTER ROLE ... PASSWORD` cannot be parameterised),
# and every psql stream is redirected to a file that is never shown. Only a
# verdict is echoed. Redacting the command you compose does not redact what the
# tool prints back.
#
# Usage:
#   set -a; source .env; set +a
#   STACKS_APP_DB_PASSWORD=... STACKS_DBT_DB_PASSWORD=... \
#     TARGET_DATABASE_URL="postgres://owner:...@host/db" \
#     bash scripts/rotate-db-role-passwords.sh
#
# For staging, pass --resolve-staging instead of TARGET_DATABASE_URL and the
# script asks Neon for the staging branch's owner URI (needs NEON_STAGING_*).
#
# ⚠️ RUN THIS AGAINST PRODUCTION TOO. `deploy-production.yml` builds prod's
# APP_DATABASE_URL from the same GitHub secret, so rotating the secret without
# rotating prod's role breaks production at its next deploy.
set -euo pipefail

# ── validate BEFORE touching anything ───────────────────────────────────────
# The same shape the migration enforces. Checked here so a bad value is a
# refusal rather than a role nobody can log in as.
PATTERN='^[A-Za-z0-9._~-]{24,128}$'
for var in STACKS_APP_DB_PASSWORD STACKS_DBT_DB_PASSWORD; do
    value="$(printenv "$var" || true)"
    if [[ -z "$value" ]]; then
        echo "FAIL: $var is not set." >&2
        exit 1
    fi
    if ! [[ "$value" =~ $PATTERN ]]; then
        # ⚖️ Says WHAT is wrong without echoing the value: length is safe to
        # report, the characters are not.
        echo "FAIL: $var is ${#value} chars and must match [A-Za-z0-9._~-]{24,128}." >&2
        exit 1
    fi
done
echo "PASS: both passwords match the shape the migration enforces."

TARGET="${TARGET_DATABASE_URL:-}"
if [[ "${1:-}" == "--resolve-staging" ]]; then
    : "${NEON_STAGING_API_KEY:?NEON_STAGING_API_KEY is required to resolve staging}"
    : "${NEON_STAGING_PROJECT_ID:?NEON_STAGING_PROJECT_ID is required to resolve staging}"
    API="https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}"
    BRANCH_ID="$(curl -sfL -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" "${API}/branches" |
        python3 -c "
import json,sys
bs=json.load(sys.stdin).get('branches',[])
m=[b['id'] for b in bs if b.get('name')=='staging']
print(m[0] if m else '')")"
    [[ -n "$BRANCH_ID" ]] || { echo "FAIL: staging branch not found." >&2; exit 1; }
    TARGET="$(curl -sfL -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
        "${API}/connection_uri?branch_id=${BRANCH_ID}&database_name=neondb&role_name=neondb_owner" |
        python3 -c "import json,sys; print(json.load(sys.stdin).get('uri',''))")"
    echo "Resolved the staging owner URI for ${BRANCH_ID} (not printed)."
fi

if [[ -z "$TARGET" ]]; then
    echo "FAIL: set TARGET_DATABASE_URL, or pass --resolve-staging." >&2
    exit 1
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# ⚖️ `stacks_readonly` is deliberately absent. The migration calls
# ensure_nologin_role for it on purpose, so granting it LOGIN here would break
# the intent rather than restore it.
for pair in "stacks_app:STACKS_APP_DB_PASSWORD" "stacks_dbt:STACKS_DBT_DB_PASSWORD"; do
    role="${pair%%:*}"
    pw="$(printenv "${pair##*:}")"
    if psql "$TARGET" -v ON_ERROR_STOP=1 -q \
        -c "ALTER ROLE ${role} WITH LOGIN PASSWORD '${pw}'" >"$OUT" 2>&1; then
        echo "PASS: ${role} now has LOGIN and the supplied password."
    else
        echo "FAIL: could not alter ${role}." >&2
        grep -qiE "permission denied|must be superuser" "$OUT" && echo "  reason: insufficient privilege" >&2
        grep -qiE "does not exist" "$OUT" && echo "  reason: role does not exist on this database" >&2
        exit 1
    fi
done

psql "$TARGET" -At -q -c "
    SELECT rolname || ' login=' || rolcanlogin || ' haspw=' || (rolpassword IS NOT NULL)
    FROM pg_authid
    WHERE rolname IN ('stacks_app','stacks_dbt','stacks_readonly')
    ORDER BY rolname" >"$OUT" 2>&1 ||
    { echo "FAIL: verification query failed." >&2; exit 1; }
echo "--- verified:"
grep -E "^stacks_" "$OUT"
