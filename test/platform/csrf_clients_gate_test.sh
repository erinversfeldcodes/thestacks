#!/usr/bin/env bash
# test/platform/csrf_clients_gate_test.sh
#
# `scripts/check-csrf-clients.sh` — every non-browser client that writes to our
# own API carries the CSRF proof, and that stays true.
#
# ⛔ WHY THE GATE EXISTS, because it decides what these cases must prove. CSRF
# enforcement was sized from the SERVER's routes and the E2E harness's writes.
# Nine shell write-sites were never enumerated, and the first one to run broke a
# deploy with a message that named the wrong cause:
#
#     FAIL warmup: could not authenticate as warmup user (HTTP 403)
#         Check PROBE_SEED_EMAIL / PROBE_SEED_PASSWORD.
#
# ⚠️ Two of those nine were worse than a broken deploy: the IDOR cross-user
# DELETE checks treat 403 as "denied", and an unproven request is refused with
# 403 — so they would have reported the exploit blocked over a stack with no
# authorization at all.
#
# ⛔ So the case that matters is NOT "does it pass on a clean tree". It is
# whether it refuses a newly-added unproven client, INCLUDING one whose URL is
# assembled from variables — the gate's first version classified by a literal
# `/api/` in the source text and was silently blind to `"$BASE_URL${SMOKE_PATH}"`.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-csrf-clients.sh"
LINT="$REPO_ROOT/scripts/lint-elixir.sh"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

SANDBOX=""
cleanup() { [[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# The gate walks `scripts/` and `.github/` relative to its own repo root, so a
# sandbox is a whole fake tree. `filler` exists so each case fails on the thing
# it asserts rather than on the gate's own floors.
new_sandbox() {
    cleanup
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/scripts" "$SANDBOX/.github/workflows"
    cp "$GATE" "$SANDBOX/scripts/check-csrf-clients.sh"

    # FOUR correctly-proven clients, not one: the gate floors on how many
    # in-scope calls it classified, so a thinner fixture would make every case
    # below refuse on the floor instead of on the thing it asserts — and look
    # like it was passing for the right reason when the gate was broken.
    cat > "$SANDBOX/scripts/good.sh" <<'SH'
JAR="$(mktemp)"
curl -s -o /dev/null --cookie-jar "$JAR" "$BASE_URL/"
PROOF="$(awk '$6 == "stacks_csrf" { print $7 }' "$JAR" | tail -1)"
curl -s -X POST "$BASE_URL/api/auth/login" \
  -b "$JAR" \
  -H "X-CSRF-Token: $PROOF" \
  -d '{}'
curl -s -X POST "$BASE_URL/api/upload/init" \
  -b "$JAR" \
  -H "X-CSRF-Token: $PROOF" \
  -d '{}'
curl -s -X DELETE "$BASE_URL/api/placements/$ID" \
  -b "$JAR" \
  -H "X-CSRF-Token: $PROOF"
curl -s -X POST "$CORE_URL${SMOKE_PATH}" \
  -b "$JAR" \
  -H "X-CSRF-Token: $PROOF"
SH
    # Third-party writes, which must stay out of scope.
    cat > "$SANDBOX/scripts/foreign.sh" <<'SH'
curl -sL -X POST "https://console.neon.tech/api/v2/projects/$PROJECT/branches" -H "Authorization: Bearer $NEON_API_KEY"
curl -s -X DELETE "https://api.machines.dev/v1/apps/$APP" -H "Authorization: Bearer $FLY_API_TOKEN"
SH
    local i
    for ((i = 0; i < 40; i++)); do
        printf 'curl -s "$BASE_URL/api/health"\ncurl -s "$BASE_URL/api/catalogue"\ncurl -s -o /dev/null "$BASE_URL/"\n' \
            > "$SANDBOX/scripts/filler$i.sh"
    done
}

run_gate() {
    OUT="$(cd "$SANDBOX" && bash scripts/check-csrf-clients.sh 2>&1)"
    RC=$?
}

test_case "gate_exists" "the script its caller invokes is present"
assert_path_exists "$GATE" "scripts/check-csrf-clients.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below exercises the real thing"
fi

# ── the green half, so a refusal below means something ──────────────────────
test_case "a_proven_client_passes" \
    "without this every refusal below could be satisfied by the fixture"
new_sandbox
run_gate
assert_exit_zero "$RC" "a tree whose only API write carries the proof is clean"
assert_contains "$OUT" "carry the CSRF proof" "and it reports what it permitted"

test_case "a_third_party_write_is_not_in_scope" \
    "a proof means nothing to Neon or Fly, and sending one would leak it"
assert_not_contains "$OUT" "foreign.sh" \
    "the Neon and Fly writes are out of scope, not violations"

# ── THE CASE THE GATE EXISTS FOR ────────────────────────────────────────────
test_case "a_new_unproven_client_is_refused" \
    "nine of these existed and the first to run broke a deploy"
new_sandbox
cat > "$SANDBOX/scripts/new_client.sh" <<'SH'
curl -s -X POST "$BASE_URL/api/upload/init" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}'
SH
run_gate
assert_exit_nonzero "$RC" "the unproven write is refused"
assert_contains "$OUT" "new_client.sh" "the refusal names the file"
assert_contains "$OUT" "without the proof" "and the condition"
assert_contains "$OUT" "ambiguous" \
    "and says why it matters — a 403 on a write names the wrong cause"

# ⛔ THE BLIND SPOT A PROBE FOUND, which is why classification is by host
# variable and not by a literal path.
test_case "an_unproven_client_whose_path_is_a_variable_is_refused" \
    "the gate's first version was silently blind to exactly this"
new_sandbox
cat > "$SANDBOX/scripts/varpath.sh" <<'SH'
curl -sf -X POST \
  -H "X-Internal-Token: $TOKEN" \
  "$BASE_URL${SMOKE_PATH}"
SH
run_gate
assert_exit_nonzero "$RC" "a URL assembled from variables is still our API"
assert_contains "$OUT" "varpath.sh" "the refusal names the file"

test_case "a_workflow_step_is_scanned_too" \
    "two of the nine lived in .github/workflows, not in scripts/"
new_sandbox
cat > "$SANDBOX/.github/workflows/thing.yml" <<'YML'
jobs:
  x:
    steps:
      - run: |
          curl -s -X DELETE "${CORE_URL}/api/placements/${PLACEMENT}" \
            -H "Authorization: Bearer ${U2}"
YML
run_gate
assert_exit_nonzero "$RC" "a yml step is a client like any other"
assert_contains "$OUT" "thing.yml" "the refusal names the workflow"

# ── a comment is not a client ───────────────────────────────────────────────
#
# ⛔ THIS REPOSITORY'S MOST-RECORDED GATE FAILURE: a gate reading its own subject
# matter as configuration. Every comment explaining this rule contains the
# header name — including the ones now sitting beside each fixed call site.
test_case "a_comment_mentioning_the_header_is_not_a_client" \
    "the text explaining the rule must not satisfy it"
new_sandbox
cat > "$SANDBOX/scripts/commented.sh" <<'SH'
# Always send -H "X-CSRF-Token: $PROOF" on a write, or it is refused.
curl -s -X POST "$BASE_URL/api/upload/init" -d '{}'
SH
run_gate
assert_exit_nonzero "$RC" \
    "the comment must NOT satisfy the gate for the call beneath it"
assert_contains "$OUT" "commented.sh" "the unproven call is still reported"

# ── floors are on what was READ ─────────────────────────────────────────────
test_case "a_corpus_below_the_file_floor_is_refused_though_clean" \
    "a findings floor is satisfied by almost-total corpus loss"
new_sandbox
rm -f "$SANDBOX/scripts/"filler*.sh
run_gate
assert_exit_nonzero "$RC" "two scripts is not a scanned tree, whatever the findings say"
assert_contains "$OUT" "scanned only" "the refusal quotes what it read"

test_case "the_sub_floor_corpus_contained_no_violations" \
    "so the refusal above is about the population, not a finding"
assert_not_contains "$OUT" "without the proof" \
    "nothing in the small corpus is a violation — the floor is what refused it"

test_case "a_tree_with_no_in_scope_clients_is_refused" \
    "zero in-scope calls means the scope rule stopped recognising our API"
new_sandbox
rm -f "$SANDBOX/scripts/good.sh"
run_gate
assert_exit_nonzero "$RC" "a clean result over nothing classified is not a pass"
assert_contains "$OUT" "in scope" "the refusal names the condition"

# ———————————————————————— callers ————————————————————————
test_case "caller_lint" "the lint runner invokes the gate"
if [[ -f "$LINT" ]]; then
    assert_contains "$(cat "$LINT")" "check-csrf-clients.sh" \
        "lint-elixir.sh runs it, beside its route-side twin"
else
    _record_fail "lint-elixir.sh not found at $LINT"
fi

test_case "caller_ci" "CI reaches the gate"
if [[ -f "$CI_YML" ]]; then
    assert_contains "$(cat "$CI_YML")" "lint-elixir.sh" \
        "ci.yml runs lint-elixir.sh, which runs this gate"
else
    _record_fail "ci.yml not found at $CI_YML"
fi

# ———————————————————————— the real tree ————————————————————————
test_case "the_real_tree_has_no_unproven_clients" "the invariant holds as it stands"
OUT="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" "the gate passes over scripts/ and .github/"
assert_contains "$OUT" "all carry the CSRF proof" "and says what it permitted"

summarise
