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
# hardcoded local stacks_dev and migrate a developer's machine instead.
PREVIEW_BLOCK="$(sed -n "${PREVIEW_MIGRATE_LINE:-1},$((${PREVIEW_MIGRATE_LINE:-1} + 24))p" "$SCRIPT")"

# ⛔ THE MIGRATE LINE ITSELF, NOT THE BLOCK. `assert_contains "$PREVIEW_BLOCK"
# "MIX_ENV=prod"` was satisfied by any of three occurrences in the window, so a
# probe that stripped it from the deps.get line left the assertion GREEN. A
# string that appears somewhere nearby is not the same claim as the command
# under test carrying it.
MIGRATE_INVOCATION="$(grep -E "MIX_ENV=prod.*mix ecto\.migrate" <<< "$PREVIEW_BLOCK")"
[[ -n "$MIGRATE_INVOCATION" ]]
assert_exit_zero $? "the ecto.migrate invocation ITSELF carries MIX_ENV=prod — :prod is the only env whose runtime config reads DATABASE_URL, so a dev-mode migrate would target the hardcoded local stacks_dev instead"

MIGRATE_URL_LINE="$(grep -E "DATABASE_URL=\"\\$\{NEON_CONNECTION_URI\}\"" <<< "$PREVIEW_BLOCK")"
[[ -n "$MIGRATE_URL_LINE" ]]
assert_exit_zero $? "and it is pointed at the preview's own branch rather than an ambient database"

# ⬛ The failure must STOP the deploy. A preview that carries on after its own
# migrations failed has a schema that is neither staging's nor main's.
assert_contains "$PREVIEW_BLOCK" "exit 1" "a migration that cannot apply to cloned staging data stops the deploy — that is what a merge would do to production"

summarise
