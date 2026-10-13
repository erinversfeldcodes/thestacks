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
# shellcheck disable=SC2016  # a literal grep pattern, not an expansion
MODAL_IF_LINE="$(line_of 'if \[\[ -z "\${SKIP_VISION:-}" \]\]')"

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

summarise
