#!/usr/bin/env bash
# The vision eval inside deploy-stack.sh compiles the core app on the deploying
# machine (`mix eval.vision`), and the core app does not compile without the
# proto-generated Ecto schemas. The script once generated those AFTER the eval:
# every PR passed, because the preview workflow pre-generated them in a step of
# its own, and the first production deploy — whose workflow did not — died in
# the eval with "Stacks.Accounts.User.__struct__/1 is undefined" and rolled
# back. The script must own that prerequisite itself, before any caller's
# ordering can matter, and these pin that it does.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

SCRIPT="$REPO_ROOT/scripts/deploy-stack.sh"

line_of() {
    grep -n -- "$1" "$SCRIPT" | head -1 | cut -d: -f1
}

GEN_LINE="$(line_of 'Generating Ecto schemas from proto')"
EVAL_LINE="$(line_of 'Scoring the deployed vision model')"
# ⚠️ The landmark is the Modal section's CONDITION, not a particular spelling of
# it. This grepped for `if [[ -z "${SKIP_VISION:-}" ]]` until that presence test
# was replaced: `SKIP_VISION=0` is non-empty, so the obvious way to write "do not
# skip" turned the skip ON and dropped the vision deploy. The condition now reads
# the VALUE via `vision_skipped`, and this landmark follows it rather than
# pinning the defect's spelling.
MODAL_IF_LINE="$(line_of 'if ! vision_skipped && ')"

test_case "eval_prereq_present" "the script still generates the Ecto schemas and still scores the model"
RC=0; [[ -n "$GEN_LINE" && -n "$EVAL_LINE" && -n "$MODAL_IF_LINE" ]] || RC=1
assert_exit_zero "$RC" "all three landmarks found (gen=${GEN_LINE:-none} eval=${EVAL_LINE:-none} modal=${MODAL_IF_LINE:-none})"

test_case "schemas_before_eval" "the Ecto schemas are generated before the vision eval compiles the app"
RC=0; [[ -n "$GEN_LINE" && -n "$EVAL_LINE" && "$GEN_LINE" -lt "$EVAL_LINE" ]] || RC=1
assert_exit_zero "$RC" "Ecto codegen (line ${GEN_LINE:-?}) precedes the eval (line ${EVAL_LINE:-?})"

test_case "schemas_unconditional" "the schemas are generated outside the Modal block, so a vision-less deploy gets them too"
RC=0; [[ -n "$GEN_LINE" && -n "$MODAL_IF_LINE" && "$GEN_LINE" -lt "$MODAL_IF_LINE" ]] || RC=1
assert_exit_zero "$RC" "Ecto codegen (line ${GEN_LINE:-?}) precedes the Modal section (line ${MODAL_IF_LINE:-?})"

test_case "schemas_generated_once" "the block was moved, not copied — one generation per deploy"
COUNT="$(grep -c -- 'Generating Ecto schemas from proto' "$SCRIPT")"
RC=0; [[ "$COUNT" -eq 1 ]] || RC=1
assert_exit_zero "$RC" "exactly one Ecto codegen block (found ${COUNT})"

# The same class, one layer down: the rollback redeploys the vision app from
# a FRESH CLONE of the previous commit, and the vision app imports
# proto-generated Python at startup. The first production rollback shipped a
# clone with none of it; the rolled-back vision app crash-looped on
# ModuleNotFoundError while the rollback reported success.
ROLLBACK="$REPO_ROOT/scripts/rollback-production.sh"
rb_line_of() {
    grep -n -- "$1" "$ROLLBACK" | head -1 | cut -d: -f1
}
RB_CHECKOUT_LINE="$(rb_line_of 'git checkout "\$MODAL_PREV_COMMIT"')"
RB_GEN_LINE="$(rb_line_of 'gen_python_proto.py --language python')"
RB_DEPLOY_LINE="$(rb_line_of 'modal deploy "\$WORK_DIR/stacks-rollback/apps/vision/modal_app.py"')"

test_case "rollback_generates_vision_protos" "the rollback generates the vision app's Python protos in the clone it deploys from"
RC=0; [[ -n "$RB_GEN_LINE" && -n "$RB_CHECKOUT_LINE" && -n "$RB_DEPLOY_LINE" ]] || RC=1
assert_exit_zero "$RC" "generator call present between checkout and deploy (checkout=${RB_CHECKOUT_LINE:-none} gen=${RB_GEN_LINE:-none} deploy=${RB_DEPLOY_LINE:-none})"

test_case "rollback_protos_after_checkout_before_deploy" "…and in that order"
RC=0; [[ -n "$RB_GEN_LINE" && "$RB_CHECKOUT_LINE" -lt "$RB_GEN_LINE" && "$RB_GEN_LINE" -lt "$RB_DEPLOY_LINE" ]] || RC=1
assert_exit_zero "$RC" "checkout (${RB_CHECKOUT_LINE:-?}) < codegen (${RB_GEN_LINE:-?}) < modal deploy (${RB_DEPLOY_LINE:-?})"

test_case "skip_vision_reads_its_value_not_its_presence" "the flag's off-switch must not be its on-switch"
# ⛔ `SKIP_VISION` was tested with `-n`/`-z` at FOUR sites, so any non-empty value
# meant skip — and `SKIP_VISION=0`, the obvious way to say "do not skip", turned
# the skip on and silently dropped the vision deploy from the stack.
#
# ⚠️ Driven by extracting the real helper and calling it DIRECTLY. An earlier
# version of this probe called it inside `$(...)`, where the helper's `exit 1`
# refusal kills the subshell with status 1 — indistinguishable from `return 1`,
# so a refusal read as "deploy". The command substitution has to go.
VS_PROBE="$(mktemp)"
cat > "$VS_PROBE" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
eval "$(awk '/^vision_skipped\(\) \{/,/^\}/' "$2")"
export SKIP_VISION="$1"
if vision_skipped; then echo "skip"; else echo "deploy"; fi
PROBE

for case_pair in "1:skip" "true:skip" "YES:skip" "0:deploy" "false:deploy" "no:deploy"; do
    value="${case_pair%%:*}"
    want="${case_pair##*:}"
    got="$(bash "$VS_PROBE" "$value" "$SCRIPT" 2>&1)"
    if [[ "$got" == "$want" ]]; then
        _record_pass "SKIP_VISION=${value} -> ${want}"
    else
        _record_fail "SKIP_VISION=${value} -> ${got}, expected ${want}"
    fi
done

# An unrecognised value must REFUSE rather than pick a side, because the wrong
# guess either spends on Modal unexpectedly or ships a stack with no vision.
for bad in off banana; do
    out="$(bash "$VS_PROBE" "$bad" "$SCRIPT" 2>&1)"
    rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q 'neither true nor false' <<< "$out"; then
        _record_pass "SKIP_VISION=${bad} is refused, not guessed"
    else
        _record_fail "SKIP_VISION=${bad} gave exit ${rc} and output: ${out}"
    fi
done
rm -f "$VS_PROBE"

# ── the preview migrates its own branch, before anything reads the schema ────

test_case "preview_migrates_its_own_branch" "a preview is a rehearsal of the merge, not a copy of staging"

PREVIEW_MIGRATE_LINE="$(grep -n "Applying this branch's migrations to the preview Neon branch" "$SCRIPT" | head -1 | cut -d: -f1)"

# ⚠️ `assert_lt` and `assert_not_empty` DO NOT EXIST in lib/assert.sh, and an
# earlier version of this block called them. The suite reported "14 passed, 0
# failed" while bash printed `command not found` three times — the assertions
# never ran and never failed anything. Only the five helpers that exist are
# used here, and each numeric comparison goes through a real `[[ ]]` test whose
# exit code `assert_exit_zero` can actually read.
[[ -n "${PREVIEW_MIGRATE_LINE:-}" ]]
assert_exit_zero $? "the preview migration block exists — without it a preview inherits staging's schema and never advances it"

# ⛔ ORDER IS THE WHOLE POINT. Before the generated schemas the app cannot
# compile, so the migration could not run; after the eval it is too late for
# the gate that reads the tables. Both bounds are asserted because either one
# alone permits the placement that fails.
[[ "${GEN_LINE:-0}" -lt "${PREVIEW_MIGRATE_LINE:-0}" ]]
assert_exit_zero $? "codegen (line ${GEN_LINE:-?}) precedes the preview migration (line ${PREVIEW_MIGRATE_LINE:-?}) — the app cannot compile before it"

[[ "${PREVIEW_MIGRATE_LINE:-0}" -lt "${EVAL_LINE:-0}" ]]
assert_exit_zero $? "the preview migration (line ${PREVIEW_MIGRATE_LINE:-?}) precedes the vision eval (line ${EVAL_LINE:-?}) — the eval reads op.ai_spend through the budget check"

# ⚠️ `MIX_ENV=prod` is load-bearing, not incidental: `config/runtime.exs` reads
# DATABASE_URL only in :prod, so a dev-mode migrate would silently target the
# hardcoded local stacks_dev instead.
#
# ⬛ THE WINDOW IS COMPUTED, NOT GUESSED. An earlier version of these three
# assertions read a fixed 24 lines from the block's first line; when the block
# grew to supply prod config explicitly, all three failed on the window rather
# than on the invariant. A sed range ending at the block's own `fi` cannot go
# stale that way.
PREVIEW_END="$(awk -v s="${PREVIEW_MIGRATE_LINE:-1}" 'NR>=s && /^fi$/ {print NR; exit}' "$SCRIPT")"
[[ -n "$PREVIEW_END" ]]
assert_exit_zero $? "the preview migration block has a terminating fi, so its extent is computable rather than assumed"
PREVIEW_BLOCK="$(sed -n "${PREVIEW_MIGRATE_LINE:-1},${PREVIEW_END:-1}p" "$SCRIPT")"

# ⛔ THE ARRAY AND THE INVOCATION, LINKED. Asserting `MIX_ENV=prod` appears
# somewhere was satisfied by any of three occurrences, and a probe stripping one
# left it green. The env now lives in a `migrate_env` array, so each variable is
# asserted inside that array AND the migrate is asserted to run through it —
# either alone permits an array that nothing passes to mix.
MIGRATE_ENV_BLOCK="$(sed -n "/^preview_mix_env=(/,/^)$/p" "$SCRIPT")"
assert_contains "$MIGRATE_ENV_BLOCK" '"MIX_ENV=prod"' \
    "the migrate env declares MIX_ENV=prod — :prod is the only env whose runtime config reads DATABASE_URL"
# ⛔ A MIGRATION READS MORE THAN THE RUNTIME CONFIG DEMANDS. The role-creation
# migration reads STACKS_APP_DB_PASSWORD and STACKS_DBT_DB_PASSWORD and treats
# their absence as "create the role NOLOGIN with no password". Because a
# migration runs exactly once, applying it from here without them left
# stacks_app at rolcanlogin=false / rolpassword=null, the release's own migrate
# skipped the already-applied version, and the booted app failed every query
# with `28P01 invalid_password for user 'stacks_app'` while the machine
# reported `started`. No unit or integration test could see it; a live drive did.
assert_contains "$MIGRATE_ENV_BLOCK" 'STACKS_APP_DB_PASSWORD=' \
    "the migrate carries the app role's password — without it the role migration creates stacks_app NOLOGIN and no later run will fix it"
assert_contains "$MIGRATE_ENV_BLOCK" 'STACKS_DBT_DB_PASSWORD=' \
    "and the warehouse role's password, for the same once-only reason"

assert_contains "$MIGRATE_ENV_BLOCK" 'STORAGE_BACKEND=local' \
    "and declares local storage, because a schema migration writes no objects and should not hold production storage credentials"

assert_contains "$PREVIEW_BLOCK" 'env "${preview_mix_env[@]}" mix ecto.migrate' \
    "and the migrate actually RUNS through that env — an array nothing passes to mix would satisfy the assertions above on its own"

# ⛔ THE ARRAY IS DEFINED OUTSIDE THE PREVIEW-ONLY BLOCK, BECAUSE PROD READS IT.
# The vision eval expands this array too, and the eval runs in every mode. While
# the declaration sat inside the `if [[ PROD_MODE != 1 ]]` block, a production
# deploy reached that expansion with the array never defined — and this script
# runs under `set -u`, so that is an abort, in the one mode CI never exercises.
# Asserting the ORDER is what keeps a future tidy-up from moving it back in.
ARRAY_LINE="$(grep -n "^preview_mix_env=(" "$SCRIPT" | head -1 | cut -d: -f1)"
[[ -n "$ARRAY_LINE" ]]
assert_exit_zero $? "the preview mix env is declared at column zero, outside any conditional"
[[ "${ARRAY_LINE:-0}" -lt "${PREVIEW_MIGRATE_LINE:-0}" ]]
assert_exit_zero $? "it is declared (line ${ARRAY_LINE:-?}) BEFORE the preview-only block that uses it (line ${PREVIEW_MIGRATE_LINE:-?}), so the eval's expansion cannot hit an unset array on the production path"

# ⚠️ And the one expansion that is no longer protected by that block's own
# emptiness test must carry its own default, or set -u aborts prod.
assert_contains "$MIGRATE_ENV_BLOCK" 'DATABASE_URL=${NEON_CONNECTION_URI:-}' \
    "DATABASE_URL is expanded with a default — hoisting the array above the -n test removed the guarantee that made a bare expansion safe"

# ⬛ The failure must STOP the deploy. A preview that carries on after its own
# migrations failed has a schema that is neither staging's nor main's.
# ⚠️ ANCHORED ON THE ASSIGNMENT, NOT ON THE TASK NAME. A range ending at the
# first literal `mix eval.vision` stops inside the COMMENT that explains the
# invocation, so the window closed before reaching the invocation itself and the
# assertion failed against prose. Comments above a command are part of the
# haystack unless the anchor excludes them.
EVAL_INVOCATION="$(sed -n '/^    EVAL_OUT="\$(cd/,/EVAL_RC=\$?/p' "$SCRIPT")"
assert_contains "$EVAL_INVOCATION" 'env "${preview_mix_env[@]}"' \
    "the vision eval runs through the same preview env — without DATABASE_URL it reached the runner's own localhost:5432 and failed before scoring anything"

assert_contains "$PREVIEW_BLOCK" "exit 1" \
    "a migration that cannot apply to cloned staging data stops the deploy — that is what a merge would do to production"

summarise
