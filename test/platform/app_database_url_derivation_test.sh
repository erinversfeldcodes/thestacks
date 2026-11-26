#!/usr/bin/env bash
# test/platform/app_database_url_derivation_test.sh
#
# `scripts/deploy-stack.sh` derives `APP_DATABASE_URL` — the least-privilege
# runtime connection — from the owner URL by substituting the role and password.
#
# ⛔ Why derived rather than configured, and why that needs a gate. The host and
# database differ per environment: every preview gets its own Neon branch. A
# literal value in `.env` or a GitHub secret would point every preview at
# whichever branch it was written for — and that is a WORSE failure than not
# setting it at all, because the application would start, serve, and write to
# the wrong database. "It works" and "it is correct" come apart completely.
#
# So the rewrite has to keep the host, the port, the database and the query
# string (`sslmode`, channel binding) and change only the credentials. These
# cases pin exactly that, including the shapes that break naive string
# surgery: a password containing URL metacharacters, a URL with an explicit
# port, and an input that is not a URL at all.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

DEPLOY="$REPO_ROOT/scripts/deploy-stack.sh"
DEPLOY_SRC="$(cat "$DEPLOY" 2>/dev/null)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ⚠️ The derivation is its own script now, so this suite RUNS it rather than
# extracting it from the deploy script by string markers. The extraction was a
# test whose first job was parsing the thing it tested — it would have reported
# a clean pass over nothing the moment those markers moved.
DERIVE="$REPO_ROOT/scripts/lib/derive-app-database-url.py"

derive() {
    EFFECTIVE_DATABASE_URL="$1" STACKS_APP_DB_PASSWORD="$2" python3 "$DERIVE"
}

test_case "inputs_exist" "the deploy script and the extracted derivation"
assert_path_exists "$DEPLOY" "scripts/deploy-stack.sh exists"
if bash -n "$DEPLOY" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi
assert_path_exists "$DERIVE" "scripts/lib/derive-app-database-url.py exists"

# ⛔ RUNS it under bare `python3`, which is what the deploy script calls — and
# not `ast.parse`, which is what used to be here. A 3.10-only annotation
# (`str | None`) PARSES fine on 3.9 and raises `TypeError` at import, so the
# parse check passed on the one interpreter where the file was unusable. The
# caller's `|| APP_DATABASE_URL_VALUE=""` then swallowed it, the deploy set no
# secret, and the stack ran as the owner with every least-privilege grant
# decorative. The system python3 on macOS is 3.9, so this is the live case, not
# a hypothetical one.
#
# Invoked with no environment, where the contract is a clean exit and no output.
DERIVE_SMOKE="$(python3 "$DERIVE" 2>&1)"
DERIVE_SMOKE_RC=$?
if [[ $DERIVE_SMOKE_RC -eq 0 && -z "$DERIVE_SMOKE" ]]; then
    _record_pass "it RUNS under $(python3 --version 2>&1), the interpreter the deploy script calls"
else
    _record_fail "it does not run under $(python3 --version 2>&1) (rc=$DERIVE_SMOKE_RC): ${DERIVE_SMOKE:-no output}. Every case below would derive nothing and the deploy would silently keep the owner role"
fi
assert_not_contains "$DEPLOY_SRC" "PYEOF" \
    "the deploy script no longer embeds the derivation in a heredoc, so shellcheck can see past it"

test_case "the_host_and_database_survive" "only the credentials change"
# ⛔ The case that matters most. If the host were rewritten, a preview deploy
# would point the application at a different branch's data and nothing would
# look wrong.
OUT="$(derive 'postgresql://neondb_owner:ownerpw@ep-spring-star-an06svfm.c-6.us-east-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require' 'apppw')"
assert_contains "$OUT" "ep-spring-star-an06svfm.c-6.us-east-1.aws.neon.tech" "the host is unchanged"
assert_contains "$OUT" "/neondb" "the database is unchanged"
assert_contains "$OUT" "sslmode=require" "sslmode survives"
assert_contains "$OUT" "channel_binding=require" "every query parameter survives, not just the first"
assert_contains "$OUT" "stacks_app:" "the role is the least-privilege one"
assert_not_contains "$OUT" "neondb_owner" "the owner role is gone"
assert_not_contains "$OUT" "ownerpw" "the owner password is gone"

test_case "an_explicit_port_survives" "localhost and self-hosted shapes"
OUT_PORT="$(derive 'ecto://postgres:postgres@localhost:5432/stacks_dev' 'apppw')"
assert_contains "$OUT_PORT" "localhost:5432" "the port is preserved"
assert_contains "$OUT_PORT" "ecto://" "the scheme is preserved"
assert_contains "$OUT_PORT" "/stacks_dev" "the database is preserved"

test_case "a_password_with_url_metacharacters_is_encoded" "the shape that breaks string surgery"
# ⚠️ `@`, `/`, `?` and `#` in a password each terminate a different part of a
# URL. Interpolating one raw produces a URL that parses — into something else
# entirely — so this fails as a wrong connection rather than as an error.
OUT_META="$(derive 'postgresql://owner:x@db.test/neondb?sslmode=require' 'p@ss/w?rd#1')"
assert_contains "$OUT_META" "@db.test/neondb" "the host and database are still the real ones"
assert_contains "$OUT_META" "sslmode=require" "the query string is still the real one"
assert_not_contains "$OUT_META" "p@ss/w?rd#1" "the raw password is not interpolated"
assert_contains "$OUT_META" "p%40ss%2Fw%3Frd%231" "it is percent-encoded instead"

test_case "a_non_url_yields_NOTHING" "fail closed, not fail wrong"
# ⛔ Empty output means the deploy script does not set the secret, which leaves
# `config/runtime.exs`'s documented fallback to the owner URL in place. The
# alternative — emitting a half-rewritten string — would set the application
# pointing at nothing.
OUT_JUNK="$(derive 'not-a-url' 'apppw')"
if [[ -z "$OUT_JUNK" ]]; then
    _record_pass "an unparseable owner URL produces no app URL"
else
    _record_fail "an unparseable owner URL produced '$OUT_JUNK' — the deploy would set a broken secret rather than leaving the fallback"
fi

test_case "the_deploy_script_wires_it_correctly" "derivation to secret"
assert_contains "$DEPLOY_SRC" 'APP_DATABASE_URL_VALUE:+APP_DATABASE_URL=' \
    "the derived value is staged as the APP_DATABASE_URL secret"
assert_contains "$DEPLOY_SRC" 'if [[ -n "${STACKS_APP_DB_PASSWORD:-}" && -n "${EFFECTIVE_DATABASE_URL}" ]]' \
    "and only when both the password and an owner URL are present"
# ⚠️ `${VAR:+...}` emits nothing when the variable is empty, so an unset value
# means the secret is simply not passed — the fallback holds. That is the
# intended behaviour and it is the same expansion every other optional secret
# in this script uses.
assert_contains "$DEPLOY_SRC" "the documented fallback" \
    "the no-password path says out loud that the owner role is still in use"

test_case "both_deploy_paths_already_carry_the_password" "no CI change was needed"
# The derivation only runs when `STACKS_APP_DB_PASSWORD` reaches the script.
# Both deploying workflows already export it, which is why this needed no
# workflow edit — asserted rather than remembered, because a future workflow
# rewrite that drops it would silently stop setting the secret and the stack
# would quietly revert to the owner role.
CI_SRC="$(cat "$REPO_ROOT/.github/workflows/ci.yml" 2>/dev/null)"
PROD_SRC="$(cat "$REPO_ROOT/.github/workflows/deploy-production.yml" 2>/dev/null)"
assert_contains "$CI_SRC" 'STACKS_APP_DB_PASSWORD: ${{ secrets.STACKS_APP_DB_PASSWORD }}' \
    "the preview deploy job exports the app role password"
assert_contains "$PROD_SRC" 'STACKS_APP_DB_PASSWORD: ${{ secrets.STACKS_APP_DB_PASSWORD }}' \
    "the production deploy job exports the app role password"

summarise
