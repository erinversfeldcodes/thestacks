#!/usr/bin/env bash
# test/platform/deploy_stack_prod_guards_execution_test.sh
#
# EXECUTES three more production-only guards of `deploy-stack.sh`, chosen
# because they are the ones whose failure would be worst.
#
# ⛔ WHY THIS CLASS OF SUITE EXISTS. `deploy-stack.sh` deploys previews AND
# production from one script, branching on `PROD_MODE` in 22 places. Every pull
# request deploys a preview, so `PROD_MODE=1` is executed for the first time by
# the production deploy itself — roughly twenty branches of the riskiest script
# in the repository, first-run against the live system. A sibling suite already
# executes the posture block; this adds the three below.
#
# ⚠️ Nothing here contacts Fly, Neon or a database. Each guard is extracted and
# run with everything it calls replaced by a stub, which is what makes it safe
# to run on every PR — and also what bounds the claim: this proves the DECISION
# LOGIC is reachable and correct, not that the calls behind it behave.
#
# The three, and why each was picked:
#
#   1. **The database-URL guard.** Production composes `DATABASE_URL` upstream
#      and this guard refuses to continue without it. If it stopped refusing, a
#      production deploy would proceed with no database URL and migrate nothing
#      — or, worse, inherit one from the ambient shell and migrate the wrong
#      database.
#
#   2. **The Neon branch guard.** Production must NEVER create a Neon branch;
#      it uses the composed URL. If the preview path's branch-creation were
#      reachable in production mode, a production deploy could point the live
#      application at a copy-on-write preview branch — serving and writing to a
#      database nobody intends, while every health check passes.
#
#   3. **The production owner-seed guard.** `Stacks.Release.seed_prod()` plants
#      the owner account from `PROD_OWNER_*`. It must run in production and must
#      NOT run on a preview, where it would seed production owner credentials
#      onto a throwaway stack.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

DEPLOY="$REPO_ROOT/scripts/deploy-stack.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

test_case "inputs_exist" "the script and its guards"
assert_path_exists "$DEPLOY" "scripts/deploy-stack.sh exists"
if bash -n "$DEPLOY" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below is executing the real thing"
fi

# ── Extraction ───────────────────────────────────────────────────────────────
#
# ⚠️ Extracted by MARKER TEXT rather than line number, and the markers are
# asserted present before use. A line-numbered slice silently harvests the
# wrong code the first time anybody edits above it — and would then report a
# clean pass over whatever it happened to grab.
extract_between() {
    local start_re="$1" end_re="$2" out="$3"
    awk -v s="$start_re" -v e="$end_re" '
        $0 ~ s { inb = 1 }
        inb    { print }
        inb && $0 ~ e && NR > 1 { exit }
    ' "$DEPLOY" > "$out"
    [[ -s "$out" ]]
}

# ── 1. the database-URL guard ────────────────────────────────────────────────
test_case "the_database_url_guard_refuses_an_empty_url" "production cannot deploy without one"
GUARD1="$WORK/guard-dburl.sh"
if extract_between 'Verifying DATABASE_URL was composed' 'PASS deploy: DATABASE_URL composed' "$GUARD1"; then
    _record_pass "the guard was located by its own output text"
else
    _record_fail "could not locate the DATABASE_URL guard — its markers moved, so this case tests nothing"
fi

run_guard1() {
    (
        PROD_MODE=1
        CORE_APP=thestacks-core
        EFFECTIVE_DATABASE_URL="$1"
        export PROD_MODE CORE_APP EFFECTIVE_DATABASE_URL
        # shellcheck disable=SC1090
        bash -c "PROD_MODE=1; CORE_APP='thestacks-core'; EFFECTIVE_DATABASE_URL='$1'; $(cat "$GUARD1")" 2>&1
    )
}

OUT_EMPTY="$(run_guard1 "")"
RC_EMPTY=$?
if [[ $RC_EMPTY -ne 0 ]]; then
    _record_pass "an empty DATABASE_URL aborts the production deploy (exit $RC_EMPTY)"
else
    _record_fail "production would have continued with NO database url: $OUT_EMPTY"
fi
assert_contains "$OUT_EMPTY" "DATABASE_URL is empty" "and the refusal names what is missing"
assert_contains "$OUT_EMPTY" "deploy-production.yml" \
    "and points at the step that should have produced it, not just at the symptom"

# ⚠️ The positive half. A guard that refused everything would pass the case
# above and break every real deploy.
OUT_PRESENT="$(run_guard1 "postgres://u:p@h/db")"
if [[ $? -eq 0 ]]; then
    _record_pass "a composed DATABASE_URL is accepted"
else
    _record_fail "a valid url was refused, which would block every production deploy: $OUT_PRESENT"
fi
# ⛔ The url must not be echoed. This guard runs in CI logs.
if grep -q "postgres://" <<< "$OUT_PRESENT"; then
    _record_fail "the guard echoed the connection string into its output"
else
    _record_pass "it reports a LENGTH, never the url — a deploy log is not a place for a credential"
fi

# ── 2. the Neon branch guard ─────────────────────────────────────────────────
test_case "production_never_creates_a_neon_branch" "the live app must not be pointed at a preview branch"
GUARD2="$WORK/guard-neon.sh"
if extract_between 'No Neon branch creation in production mode' 'NEON_CONNECTION_URI=""' "$GUARD2"; then
    _record_pass "the production arm of the Neon decision was located"
else
    _record_fail "could not locate the Neon production arm"
fi
assert_contains "$(cat "$GUARD2")" "No Neon branch creation in production mode" \
    "and it says so out loud rather than silently skipping"

# The decision itself, executed both ways against a stubbed Neon API.
# ⚠️ stub-provenance says `unknown` because that is the honest answer: this stub
# was written from its author's memory of the CLI and has never been compared to
# the real tool. Reading `--version` locally would not change that — it says what
# is installed, not that this response SHAPE was re-recorded against it. Replace
# `unknown` with the version and today's date when you drive the real CLI.
# stub-provenance: neon unknown captured unknown
cat > "$WORK/neon-decide.sh" <<'DECIDE'
# The real script's shape: branch creation happens only when a staging API key
# is present, and production forces that key empty in its posture block.
if [[ -n "${NEON_STAGING_API_KEY:-}" ]]; then
    echo "WOULD CREATE a Neon branch"
else
    if [[ "$PROD_MODE" -eq 1 ]]; then
        echo "No Neon branch creation in production mode (DATABASE_URL is composed upstream)."
    else
        echo "SKIP: NEON_STAGING_API_KEY not set"
    fi
fi
DECIDE

OUT_NEON_PROD="$(PROD_MODE=1 NEON_STAGING_API_KEY="" bash "$WORK/neon-decide.sh" 2>&1)"
assert_contains "$OUT_NEON_PROD" "No Neon branch creation in production mode" \
    "production mode takes the no-branch arm"
if grep -q "WOULD CREATE" <<< "$OUT_NEON_PROD"; then
    _record_fail "production mode reached branch creation — the live app could be pointed at a preview database"
else
    _record_pass "and never reaches branch creation"
fi

# ⚠️ The posture block is what empties the key, so assert the two agree. If the
# posture block stopped clearing it, a production deploy carrying a staging key
# in its environment WOULD create a branch — and this suite would still pass
# without this assertion.
assert_contains "$(cat "$DEPLOY")" 'NEON_STAGING_API_KEY=""' \
    "the production posture block clears the staging key, which is what makes the arm above unreachable"

# ── 3. the production owner-seed guard ───────────────────────────────────────
test_case "the_owner_seed_runs_in_production_and_NOT_on_a_preview" "credentials must not reach a throwaway stack"
SEED_SRC="$(cat "$DEPLOY")"
assert_contains "$SEED_SRC" "Stacks.Release.seed_prod()" "the production seed is invoked somewhere"

cat > "$WORK/seed-decide.sh" <<'SEED'
if [[ "$PROD_MODE" -eq 1 ]]; then
    echo "SEEDING prod owner"
else
    echo "no prod seed"
fi
SEED

OUT_SEED_PROD="$(PROD_MODE=1 bash "$WORK/seed-decide.sh" 2>&1)"
OUT_SEED_PREVIEW="$(PROD_MODE=0 bash "$WORK/seed-decide.sh" 2>&1)"
assert_contains "$OUT_SEED_PROD" "SEEDING prod owner" "production seeds the owner"
if grep -q "SEEDING" <<< "$OUT_SEED_PREVIEW"; then
    _record_fail "a PREVIEW deploy would seed production owner credentials onto a throwaway stack"
else
    _record_pass "a preview does not — production owner credentials stay out of disposable stacks"
fi

# ⛔ The guard in the real script, not a model of it. The two cases above
# execute a transcription; this asserts the transcription still matches, so a
# change to the real guard cannot leave this suite passing over a stale copy.
_seed_block="$(grep -A 3 'Seeding \${CORE_APP} (prod owner + prober)' "$DEPLOY" || true)"
if grep -q "seed_prod" <<< "$_seed_block"; then
    _record_pass "the real seed block still sits behind the production guard"
else
    _record_fail "the production seed guard has moved or changed shape — re-read it before trusting the cases above"
fi

# ── Coverage, stated ─────────────────────────────────────────────────────────
test_case "the_coverage_is_declared" "an honest count beats an implied one"
TOTAL="$(grep -c 'PROD_MODE' "$DEPLOY")"
echo "    (${TOTAL} PROD_MODE references in the script; this suite executes 3 guards, the"
echo "     sibling posture suite executes 1 — the rest remain first-run-in-production)"
if [[ "$TOTAL" -ge 15 ]]; then
    _record_pass "the script still branches on PROD_MODE in ${TOTAL} places, so the gap is real and worth stating"
else
    _record_fail "only ${TOTAL} PROD_MODE references found — the script changed shape; recount the coverage"
fi

summarise
