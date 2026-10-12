#!/usr/bin/env bash
#
# lint-elm.sh — the Elm lane's gates. Every one of them fails LOUD.
#
# WHY IT LOOKS LIKE THIS
#
#   It used to be a bare list of `bash scripts/check-*.sh` lines under `set -e`, and it had two
#   fail-open paths, both observed:
#
#   1. `set -e` plus a sub-script that does not PARSE. check-prose-assertions.sh did not parse
#      under bash 3.2 — which is every macOS /bin/bash — so the run aborted at the second gate and
#      the seven gates below it never ran. The log showed bash's own syntax error quoting a line of
#      Python and named no gate; what it did not show was that the CSS gate, the orphan gate and
#      the ports gate had not run at all. "It passed" and "it never ran" printed the same thing.
#
#   2. elm-review sat behind `if command -v npx && npx elm-review --version; then … else echo
#      SKIP; fi`. An unresolvable linter printed SKIP and the script exited 0 — a clean pass for a
#      gate that had not run.
#
#   So: every gate runs even after an earlier one fails (one run tells you everything, instead of
#   peeling failures off one per run); a sub-script is parse-checked with the same interpreter that
#   will run it, so "does not parse" is reported as itself rather than as whatever the parser
#   eventually chokes on; and the run ends with a roster naming every gate and its outcome.
#
#   Nothing in here may print SKIP. A gate that cannot run is a failure.
#
# elm-review is a declared, pinned devDependency, so `npx` runs the installed binary.
#   It previously ran via `npx --yes`, which resolves and downloads it from the registry on
#   every run: network-dependent, and unpinned, so a new major could change what this gate
#   enforces with no commit here. Declaring it also brought its dependency tree under
#   `npm audit`, which immediately reported three high-severity advisories — `npx --yes` had
#   been running that same code all along, just where nothing could see it. The patched
#   transitive version is forced by an `overrides` entry in frontend/package.json.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

BASH_ID="$(bash --version | head -1)"

PASSED=()
FAILED=()

record() { # record pass|fail <name> [detail]
    if [[ "$1" == pass ]]; then
        PASSED+=("$2")
    else
        FAILED+=("$2 — $3")
        printf '\nFAIL  %s — %s\n' "$2" "$3"
    fi
}

# A gate script: it must exist, it must parse under the interpreter that will run it, and it must
# exit 0. `bash -n` runs first because a parse failure is a different defect from a finding, and
# saying so is the whole point — an unparseable gate has never run, whatever any green log claimed.
gate() {
    local script="$1"
    local path="scripts/$script"
    local code
    printf '\n=== %s ===\n' "$script"
    if [[ ! -f "$path" ]]; then
        record fail "$script" "gate script not found at $path"
        return
    fi
    if ! bash -n "$path"; then
        record fail "$script" "does NOT PARSE under $BASH_ID — so it has never run here"
        return
    fi
    bash "$path"
    code=$?
    if [[ $code -eq 0 ]]; then
        record pass "$script"
    else
        record fail "$script" "exited $code"
    fi
}

# A tool run inside frontend/. Same contract, no parse phase.
step() {
    local name="$1"
    local code
    shift
    printf '\n=== %s ===\n' "$name"
    (cd frontend && "$@")
    code=$?
    if [[ $code -eq 0 ]]; then
        record pass "$name"
    else
        record fail "$name" "exited $code"
    fi
}

gate gen-elm-proto.sh
gate check-e2e-vacuous-guards.sh
gate check-prose-assertions.sh
gate check-orphan-classes.sh
gate check-admin-token-routing.sh
gate check-session-expiry-coverage.sh
gate check-component-dispatch.sh
gate check-route-reachability.sh
gate check-http-timeouts.sh
gate check-ports-wired.sh
gate check-css.sh
gate check-css-values.sh

step "elm-format --validate" npx elm-format --validate src/
step "npm audit" npm audit
step "elm-review" npx elm-review --config elm-review src/ tests/

printf '\n=== lint-elm summary (%s) ===\n' "$BASH_ID"
if [[ ${#PASSED[@]} -gt 0 ]]; then
    for name in "${PASSED[@]}"; do printf '  pass  %s\n' "$name"; done
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    for name in "${FAILED[@]}"; do printf '  FAIL  %s\n' "$name"; done
    printf '\n%d of %d Elm gate(s) failed.\n' "${#FAILED[@]}" "$((${#PASSED[@]} + ${#FAILED[@]}))"
    exit 1
fi

printf '\nAll %d Elm gates passed.\n' "${#PASSED[@]}"
