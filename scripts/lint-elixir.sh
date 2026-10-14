#!/usr/bin/env bash
#
# lint-elixir.sh — the Elixir lane's gates and tools. Every one of them runs.
#
# WHY IT LOOKS LIKE THIS
#
#   It used to be a bare list under `set -euo pipefail`, which aborts the whole lane at the first
#   non-zero exit. With seven gate scripts ahead of `mix format`, `mix credo`, sobelow, dialyzer and
#   the dependency audit, one finding in the first gate meant none of the rest ran — so failures
#   came off one per run, and a reader had no way to tell "the remaining checks passed" from "the
#   remaining checks never executed". Both printed the same thing: nothing.
#
#   The Elm lane was rewritten around exactly this defect and its header documents two observed
#   fail-open paths. This is the same harness, for the same reasons:
#
#     * every gate runs even after an earlier one fails, so one run tells you everything;
#     * a sub-script is parse-checked with the interpreter that will run it, so "does not parse" is
#       reported as itself rather than as whatever the parser eventually chokes on — an unparseable
#       gate has never run, whatever a green log claimed;
#     * the run ends with a roster naming every gate and tool and its outcome.
#
#   Nothing in here may print SKIP. A gate that cannot run is a failure.
#
#   ⚠️ `set -e` is deliberately NOT set. Each step's status is captured and recorded instead. The
#   script still exits non-zero if anything failed — see the summary at the bottom.

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
# exit 0.
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

# A tool run from the umbrella root.
step() {
    local name="$1"
    local code
    shift
    printf '\n=== %s ===\n' "$name"
    "$@"
    code=$?
    if [[ $code -eq 0 ]]; then
        record pass "$name"
    else
        record fail "$name" "exited $code"
    fi
}

# A tool run inside apps/core.
step_in_core() {
    local name="$1"
    local code
    shift
    printf '\n=== %s ===\n' "$name"
    (cd apps/core && "$@")
    code=$?
    if [[ $code -eq 0 ]]; then
        record pass "$name"
    else
        record fail "$name" "exited $code"
    fi
}

gate check-outbound-test-default.sh
gate check-route-clients.sh
gate check-mapping-truth.sh
gate check-public-route-metering.sh
gate check-oban-queue-drift.sh
gate check-dbt-model-drift.sh
gate check-phase-scheme.sh

step "mix format --check-formatted" mix format --check-formatted
step "mix credo --strict" mix credo --strict

# The resolver eval replays recorded cases through the real pick logic and exits
# 1 on a regression against its pinned expectations. It has been able to gate
# since it was written; until it was called here it gated nothing — the same
# shape as a scanner that runs and whose result no one reads. It is offline and
# sub-second, so there is no reason for it not to be here.
step "mix eval.resolver" mix eval.resolver

# Build/refresh the PLT from the UMBRELLA ROOT before analysing the child.
#
# `mix dialyzer` inside an umbrella child prints "In an Umbrella child, not
# checking PLT..." and runs with `check_plt: false` — so it will happily analyse
# against a PLT built before the dependency list changed, and report functions
# from newly-added deps as though they do not exist. That is not hypothetical:
# this lane failed for over a week with `SweetXml.xpath/2 does not exist` while
# `{:sweet_xml, "~> 0.7"}` sat in apps/core/mix.exs, because the PLT predated it.
# Running `--plt` from the root is what actually refreshes it; from the child it
# is a no-op. It is fast when the PLT is already current.
#
# Sequenced before the child analysis on purpose: if the refresh fails, the
# analysis below is reported separately rather than silently running against a
# stale PLT.
step "mix dialyzer --plt" mix dialyzer --plt
step_in_core "mix dialyzer" mix dialyzer
step_in_core "mix sobelow" mix sobelow --config

# cowlib GHSA-g2wm-735q-3f56 (low, cookie request header injection in
# cow_cookie:cookie/1) has no patched release as of 2026-05-20 — affects
# all 2.9.0..2.16.1. We don't construct cookies via cow_cookie:cookie/1
# from untrusted input, so the advisory is non-exploitable here. Revisit
# this suppression after every cowlib bump; remove once upstream ships a
# fix.
step "mix deps.audit" mix deps.audit --ignore-advisory-ids GHSA-g2wm-735q-3f56

printf '\n=== lint-elixir summary (%s) ===\n' "$BASH_ID"
if [[ ${#PASSED[@]} -gt 0 ]]; then
    for name in "${PASSED[@]}"; do printf '  pass  %s\n' "$name"; done
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    for name in "${FAILED[@]}"; do printf '  FAIL  %s\n' "$name"; done
    printf '\n%d of %d Elixir gate(s) failed.\n' "${#FAILED[@]}" "$((${#PASSED[@]} + ${#FAILED[@]}))"
    exit 1
fi

printf '\nAll %d Elixir gates passed.\n' "${#PASSED[@]}"
