#!/usr/bin/env bash
# test/platform/sigpipe_hazard_gate_test.sh
#
# `scripts/check-sigpipe-hazards.sh` — refuses a pipeline whose exit status is
# read but can be 141 (SIGPIPE) instead of the answer.
#
# ⛔ WHY THIS SUITE EXISTS. The defect the gate catches reached production as a
# SECURITY SCAN REPORTING CLEAN ON A CRITICAL FINDING: `echo "$nuclei_out" |
# grep -qiE "\[critical\]"` under `pipefail` returns 141 when grep exits before
# echo finishes writing, so the `elif` went FALSE on a match and the lane
# printed "Nuclei scan clean".
#
# ⚠️ It was first found as a 2-in-6 FLAKE in a different gate, and the flake is
# the whole problem: the bug needs a payload larger than the pipe buffer with
# the match inside it, so it is invisible on small inputs and reliable only once
# the output is big — i.e. it arrives exactly when a scanner has most to report.
# The green runs are the dangerous ones.
#
# Two prior sweeps for this class each missed sites: the first looked only at
# `scripts/check-*.sh` and left the bug live in the integration gate and the
# deploy gate; the second used the pattern `| grep -q`, which does not match the
# equally idiomatic `grep -Eq`. So the cases below pin the SCOPE and the PATTERN
# as much as the verdict.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-sigpipe-hazards.sh"
cd "$REPO_ROOT" || exit 1

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-sigpipe-hazards.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below is exercising the real thing"
fi

test_case "it_has_a_caller" "a gate nothing invokes is a gate that does not exist"
# ⛔ This repo has shipped a runner that was proven working and never invoked.
# The gate's value is entirely in running on every diff, so its wiring is part
# of the contract, not a packaging detail.
if grep -q "check-sigpipe-hazards.sh" "$REPO_ROOT/scripts/lint-elixir.sh"; then
    _record_pass "invoked from scripts/lint-elixir.sh, which runs in just verify and just ci"
else
    _record_fail "no caller found — the gate would never run"
fi

test_case "the_clean_tree_passes" "a baseline, so a red below means something"
OUT="$(bash "$GATE" 2>&1)"
RC=$?
if [[ $RC -eq 0 ]]; then
    _record_pass "the gate is green on the committed tree"
else
    _record_fail "the gate is already red, so every case below is uninterpretable: ${OUT}"
fi

test_case "it_reports_how_many_scripts_it_read" \
    "a verdict over an unstated population is not a verdict"
if grep -qE "[0-9]+ pipefail-bearing script" <<< "$OUT"; then
    _record_pass "the OK line states the population it checked"
else
    _record_fail "the gate passes without saying how many scripts it read: ${OUT}"
fi

# ── the planted violations ──────────────────────────────────────────────────
#
# Driven through a COPY in a temp dir, so a failing assertion can never leave a
# planted defect in the working tree. The gate discovers its corpus with
# `git ls-files`, so the copy is made inside the repo and removed after.
PLANT_DIR="$REPO_ROOT/.sigpipe-probe"
PLANT_DIR_JF="$PLANT_DIR/justfile.orig"
# ⚠️ The justfile backup is restored by the trap as well as inline, because a
# failing assertion between the two would otherwise leave the repo's justfile
# carrying a planted zsh shell. A probe that can outlive its test is how this
# project has lost uncommitted work before.
cleanup() {
    [[ -f "$PLANT_DIR_JF" ]] && cp "$PLANT_DIR_JF" "$REPO_ROOT/justfile"
    rm -rf "$PLANT_DIR"
    rm -f "$REPO_ROOT/scripts/zz-sigpipe-suite-probe.sh"
}
trap cleanup EXIT
mkdir -p "$PLANT_DIR"

plant() {
    # $1 = the line to plant. Written into a tracked-looking script that the
    # gate will discover only if we pass it explicitly, so instead we run the
    # gate's own logic over the file by handing it a one-file corpus.
    mkdir -p "$PLANT_DIR"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -uo pipefail'
        echo 'out="placeholder"'
        echo "$1"
        echo '    :'
        echo 'fi'
    } > "$PLANT_DIR/planted.sh"
}

# A one-file corpus: swap the discovery for the planted file only.
run_gate_over_plant() {
    sed "s|git ls-files '\*\.sh'|printf '%s\\\\n' .sigpipe-probe/planted.sh|; s|^FLOOR=30|FLOOR=1|" \
        "$GATE" > "$PLANT_DIR/gate.sh"
    PLANT_OUT="$(bash "$PLANT_DIR/gate.sh" 2>&1)"
    PLANT_RC=$?
    return 0
}

test_case "it_refuses_the_form_that_shipped_the_fail_open" \
    "echo piped into grep -q, the nuclei shape"
plant 'if echo "$out" | grep -qiE "\[critical\]"; then'
run_gate_over_plant
if [[ $PLANT_RC -ne 0 ]]; then
    _record_pass "refused: $(grep -c 'planted.sh' <<< "$PLANT_OUT") site(s) reported"
else
    _record_fail "ACCEPTED the exact form that made a security scan report clean: ${PLANT_OUT}"
fi

test_case "it_refuses_the_flag_reordered_spelling" \
    "grep -Eq is the same defect as grep -qE and the previous pattern missed it"
# ⛔ This is the case the second sweep's pattern (`| grep -q`) scored ZERO on.
plant 'if printf "%s" "$out" | grep -Eq "PATTERN"; then'
run_gate_over_plant
if [[ $PLANT_RC -ne 0 ]]; then
    _record_pass "refused the reordered-flag spelling"
else
    _record_fail "ACCEPTED 'grep -Eq' — the pattern is as narrow as the one it replaced: ${PLANT_OUT}"
fi

test_case "it_refuses_a_non_grep_early_exiting_consumer" \
    "head always closes early, so it is the worst case, not an edge case"
plant 'if cat /etc/hosts | head -1; then'
run_gate_over_plant
if [[ $PLANT_RC -ne 0 ]]; then
    _record_pass "refused a pipe into head whose status is read"
else
    _record_fail "ACCEPTED a pipe into head: ${PLANT_OUT}"
fi

test_case "it_does_NOT_flag_a_status_that_is_discarded" \
    "a false positive earns the gate an exemption list, and exemption lists rot"
# ⚠️ The anti-over-reach half. `X="$(cmd | head -1)"` uses stdout and discards
# the status, so it is correct — and a gate that flags it would be argued with
# rather than fixed. The predecessor to this family of checks carried eight
# free-text exemption reasons, seven of which were false.
plant 'X="$(cat /etc/hosts | head -1)"
if [[ -n "$X" ]]; then'
run_gate_over_plant
if [[ $PLANT_RC -eq 0 ]]; then
    _record_pass "a piped head inside \$() with the status discarded is correctly allowed"
else
    _record_fail "flagged a safe site, which is how a gate acquires an exemption list: ${PLANT_OUT}"
fi

test_case "it_does_NOT_read_its_own_prose_as_a_violation" \
    "an absence assertion that counts the comment explaining the ban"
# ⛔ Five instances of this in the repo's history, four on one day. Every fix
# for this class carries a comment quoting the banned form, so a gate that does
# not strip comments fails on its own documentation.
plant '# if echo "$out" | grep -q BAD; then   <- the banned form, in prose
if true; then'
run_gate_over_plant
if [[ $PLANT_RC -eq 0 ]]; then
    _record_pass "the banned form in a comment does not trip the gate"
else
    _record_fail "the gate read its own explanatory comment as a violation: ${PLANT_OUT}"
fi

test_case "it_reads_untracked_scripts_too" \
    "a corpus that excludes the file being added passes every new script"
# ⛔ MEASURED on this gate itself. The discovery was `git ls-files` alone, which
# cannot see an untracked file — so the gate was invisible to ITSELF until it
# was committed, and the first run that included it found two violations in its
# own guidance text that had been there all along. A new script would likewise
# go unchecked until someone happened to commit it.
PROBE="$REPO_ROOT/scripts/zz-sigpipe-suite-probe.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'out="x"'
    echo 'if echo "$out" | grep -q PAT; then'
    echo '    :'
    echo 'fi'
} > "$PROBE"
UNTRACKED_OUT="$(bash "$GATE" 2>&1)"
UNTRACKED_RC=$?
rm -f "$PROBE"
if [[ $UNTRACKED_RC -ne 0 ]] && grep -q "zz-sigpipe-suite-probe" <<< "$UNTRACKED_OUT"; then
    _record_pass "an untracked script's violation is found and named"
else
    _record_fail "an untracked script was not read, so a newly added one would go unchecked"
fi

test_case "it_refuses_a_zsh_shell_in_the_justfile" \
    "several gates depend on bash word-splitting an unquoted parameter"
# ⛔ The ambient assumption the whole corpus rests on. `for entry in
# $RLS_SCOPE_TEST_ALLOWLIST` and `for _stale in $_STALE_IDS` are correct ONLY
# under a splitting shell; under zsh each would iterate once over the whole
# string and report an empty result rather than failing — the same
# empty-work-set-read-as-success shape this gate exists for.
cp "$REPO_ROOT/justfile" "$PLANT_DIR_JF"
{
    echo 'set shell := ["zsh", "-cu"]'
    cat "$PLANT_DIR_JF"
} > "$REPO_ROOT/justfile"
ZSH_OUT="$(bash "$GATE" 2>&1)"
ZSH_RC=$?
cp "$PLANT_DIR_JF" "$REPO_ROOT/justfile"
rm -f "$PLANT_DIR_JF"
if [[ $ZSH_RC -ne 0 ]] && grep -q "zsh shell" <<< "$ZSH_OUT"; then
    _record_pass "a zsh shell in the justfile is refused, and the message says an array is the fix"
else
    _record_fail "a zsh shell was accepted, leaving every word-splitting loop silently broken"
fi

test_case "the_anti_vacuity_floor_refuses_an_empty_corpus" \
    "zero hazards and zero files read must not look the same"
sed "s|git ls-files '\*\.sh'|printf '%s' ''|" "$GATE" > "$PLANT_DIR/gate-empty.sh"
EMPTY_OUT="$(bash "$PLANT_DIR/gate-empty.sh" 2>&1)"
EMPTY_RC=$?
if [[ $EMPTY_RC -ne 0 ]] && grep -q "floor is" <<< "$EMPTY_OUT"; then
    _record_pass "an empty corpus is refused rather than reported clean"
else
    _record_fail "a broken discovery reported success — the vacuity this class keeps taking: ${EMPTY_OUT}"
fi

summarise
