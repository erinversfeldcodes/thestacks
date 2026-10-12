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

summarise
