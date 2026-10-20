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

# The derivation, extracted from the deploy script so the test drives the real
# logic rather than a copy of it. ⚠️ Extracting by markers means an edit that
# changes the derivation changes what is tested; a hand-copied duplicate would
# have gone stale silently, which is this repository's own recorded lesson about
# instruments that drift from the thing they measure.
DERIVE="$WORK/derive.py"
python3 - "$DEPLOY" "$DERIVE" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = src.index("<<'PYEOF'") + len("<<'PYEOF'")
end = src.index("PYEOF", start)
body = src[start:end]

if "urlsplit" not in body or "stacks_app" not in body:
    print("FAIL: the extracted block is not the URL derivation", file=sys.stderr)
    raise SystemExit(1)

pathlib.Path(sys.argv[2]).write_text(body, encoding="utf-8")
PY

if [[ -s "$DERIVE" ]]; then
    _record_pass_setup=1
fi

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
if [[ -s "$DERIVE" ]]; then
    _record_pass "the derivation block was extracted from the real script"
else
    _record_fail "could not extract the derivation — the markers moved, so every case below would be testing nothing"
fi

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
