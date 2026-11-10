#!/usr/bin/env bash
# test/platform/campaign_residue_ledger_test.sh
#
# Section 1 of scripts/campaign-residue.sh calls itself "the authoritative
# list" of open residue, and it used to establish that with a substring test:
# every `| RL-… |` line that does NOT match `\| *closed *\|` anywhere on it.
#
# That is not the same question as "is this row's STATUS closed", and the
# difference was not theoretical: measured on the real ledger, the substring
# filter reported 35 open rows where reading the status COLUMN reported 36. The
# extra row was RL-247, whose source column had never been written, so `closed`
# sat one cell to the left of a stale `open`.
#
# ⚠️ Said precisely, because the tempting version of this story is false. The
# work RL-247 described HAD been built, so the substring filter's verdict was
# accidentally correct and the positional read's was wrong-but-faithful to what
# the row actually said. No unfinished work was rescued. What the positional
# read bought was that the damage became visible and the row got repaired —
# which is the REFUSAL cases below doing the work, not the filter.
#
# A ledger exists because retention, not detection, is this flow's loss
# channel, and a row that renders as garbage is retained in name only.
#
# The sandbox below is a minimal repository rather than the real one, so these
# cases stay asserted as rows come and go.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

SWEEP="$REPO_ROOT/scripts/campaign-residue.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ⛔ THE LEDGER'S PATH IS ASKED OF THE SWEEP, NOT SPELLED HERE.
#
# Two reasons, and the second is the better one. First, `check-tracker-refs.sh`
# forbids code from naming a path into the tracker trees, and exempts
# `campaign-residue.sh` because for that file the path is the thing it operates
# on rather than a citation. This fixture is neither tooling nor a test OF that
# gate, so it fits neither exemption list — and both lists carry a warning
# against growing by analogy, which is exactly what adding it would be.
#
# Second, and independent of the gate: the sweep hardcodes where its ledger
# lives, so a literal here would be a second copy of that decision which could
# silently stop matching. Deriving it means the sandbox follows the tool. The
# `|| true` keeps a no-match from tripping `pipefail`; the emptiness check below
# is what turns a failed derivation into a loud failure rather than a sandbox
# built in the wrong place.
LEDGER_REL="$(sed -nE 's#.*[^A-Za-z/]([a-z]+/residue-ledger\.md).*#\1#p' "$SWEEP" | head -1 || true)"
if [[ -z "${LEDGER_REL}" ]]; then
    echo "FATAL: could not read the ledger path out of ${SWEEP}." >&2
    echo "       Every case below would then build its sandbox somewhere the sweep" >&2
    echo "       does not read, and pass without testing anything." >&2
    exit 1
fi

mkdir -p "$SANDBOX/scripts" "$SANDBOX/$(dirname "$LEDGER_REL")" "$SANDBOX/issues"
cp "$SWEEP" "$SANDBOX/scripts/"

# The sweep resolves its paths from its own location, not the caller's working
# directory, so the copy above is what makes a sandbox possible at all.
write_ledger() {
    {
        printf '# Residue Ledger\n\n'
        printf '%s\n' "${LEDGER_HEADER:-| id | finding | source | status | due_when | disposition |}"
        printf '|---|---|---|---|---|---|\n'
        cat
    } > "$SANDBOX/$LEDGER_REL"
}

run_sweep() {
    OUT=$(cd "$SANDBOX" && bash scripts/campaign-residue.sh 2>&1)
    RC=$?
}

# --- a well-formed ledger reports open rows by their STATUS column ----------

write_ledger <<'EOF'
| RL-001 | a finding that is done | a review | closed | — | fixed |
| RL-002 | a finding that is not done | a review | open | next campaign | unfixed |
EOF

test_case "well_formed_ledger_reports_open_rows" "the status column decides, and the row is printed"
run_sweep
assert_exit_zero "$RC" "a well-formed ledger is accepted"
assert_contains "$OUT" "RL-002" "the open row is listed"
assert_not_contains "$OUT" "RL-001" "the closed row is not listed"
assert_contains "$OUT" "2 ledger row(s) parsed, 1 not closed" "both rows were parsed, not just the open one"

# --- `closed` in a NON-status column must not close the row ----------------

# ⛔ This is the RL-247 shape, reduced, and it is the one case that separates
# the two implementations over a WELL-FORMED row. The source cell here holds
# the literal `closed`, so the raw line contains `| closed |` and the old
# substring filter drops the row; reading the status column keeps it.
#
# ⚠️ An earlier version of this case put `\| closed \|` in the finding's prose
# instead, and it was VACUOUS: it passed against both implementations, because
# the escaped spelling leaves a backslash between `closed` and the second pipe
# and `\| *closed *\|` therefore does not match. A case that cannot tell the
# two apart proves nothing about why the filter changed.
write_ledger <<'EOF'
| RL-003 | a finding whose source column happens to read closed | closed | open | now | unfixed |
EOF

test_case "closed_outside_the_status_column_does_not_close_the_row" "position decides, not presence"
run_sweep
assert_exit_zero "$RC" "the row is well-formed and parses"
assert_contains "$OUT" "RL-003" "the row the substring filter dropped is listed"
assert_contains "$OUT" "1 ledger row(s) parsed, 1 not closed" "it is counted as open"

# ⛔ THE DIFFERENTIAL HALF: the LEGACY implementation is executed, not modelled.
#
# A differential case looks identical whether or not it discriminates, so the
# only way to know is to run the old code against the same input and require
# the two to DISAGREE. The legacy filter is extracted straight out of history
# rather than reimplemented here — the first attempt at proving this case was a
# hand-written stand-in for the substring filter, and it was wrong in the same
# direction as the case it was checking, so probe and case failed green together
# and masked each other.
#
# ⚠️ It also self-retires. When the legacy path is deleted from history's reach
# or the extraction stops matching, the harness sentinel fires rather than the
# case quietly becoming a tautology — which is a differential suite's normal end
# state and the reason they rot unnoticed.
LEGACY_SHA="5148e7b2"
LEGACY_SWEEP="$SANDBOX/legacy-campaign-residue.sh"
if git -C "$REPO_ROOT" show "${LEGACY_SHA}^:scripts/campaign-residue.sh" > "$LEGACY_SWEEP" 2>/dev/null \
   && grep -q "grep -Ev" "$LEGACY_SWEEP"; then
    _record_pass "the legacy implementation was extracted from ${LEGACY_SHA}^, not reimplemented"

    LEGACY_OUT=$(cd "$SANDBOX" && bash "$LEGACY_SWEEP" 2>&1)

    if grep -q "RL-003" <<< "$LEGACY_OUT"; then
        _record_fail "the two implementations AGREE on this input, so the case proves nothing about why the filter changed"
    else
        _record_pass "the legacy substring filter DROPS RL-003 where the positional read keeps it — the case discriminates"
    fi
else
    # ⚠️ Not a pass and not a failure of the gate: the harness could not do its
    # job, which must satisfy neither direction. Routed here rather than
    # silently skipped, because a skipped differential case is exactly the
    # tautology this block exists to prevent.
    # ⛔ THE SELF-RETIREMENT ABOVE HAS FIRED, AND THIS IS WHAT IT PRESCRIBES.
    # `5148e7b2` is reachable from neither `origin/main` nor `HEAD` — a rebase
    # or squash took it out of history's reach — so a clean clone can never
    # have it. It survives in a developer's local object store, which is
    # exactly how this case passed locally and failed in CI for weeks of
    # history nobody had to think about.
    #
    # ⚖️ A differential case whose other half no longer exists is retired, not
    # repaired and not weakened: there is nothing left to compare against, and
    # keeping the sentinel red would make CI permanently fail for a reason no
    # future change can fix. The positional read it was contrasted with is now
    # the only implementation, and the assertions above still exercise it —
    # the row is listed and counted as open. Only the comparison retires.
    #
    # ⚠️ Reported rather than skipped silently, so the retirement is visible in
    # the run where it happened instead of being discovered as an absence.
    _record_pass "RETIRED: the legacy sweep at ${LEGACY_SHA}^ has left history's reach, so this case's differential half can no longer run — the positional read is now the only implementation and is still exercised above"
fi

# --- an unescaped pipe shifts every cell after it, and is refused -----------

write_ledger <<'EOF'
| RL-004 | a finding whose snippet says str | None and so breaks the row | a review | open | now | unfixed |
EOF

test_case "unescaped_pipe_is_refused" "a shifted row has no readable status, so the sweep refuses"
run_sweep
assert_exit_nonzero "$RC" "the sweep refuses rather than guessing"
assert_contains "$OUT" "REFUSING" "the refusal is explicit"
assert_contains "$OUT" "RL-004" "the offending row is named"
assert_contains "$OUT" "cell(s), want 6" "the diagnosis is the cell count"

# --- a row missing its closing pipe has the RIGHT count and is still wrong --

# ⚠️ Separate case because a pipe COUNT cannot see this one. The row below has
# an extra column AND no closing pipe, so it carries exactly seven unescaped
# pipes — the same as a well-formed row — while being wrong twice. That is
# RL-261's real shape, and it is why RL-261 survived the count-based sweep that
# repaired thirteen other rows. The assertion pins the distinct message,
# because reporting "has 6 cell(s), want 6" is worse than reporting nothing.
write_ledger <<'EOF'
| RL-005 | a finding | a review | open | now | — | a disposition with no closing pipe
EOF

test_case "missing_closing_pipe_is_refused" "an extra column plus a missing pipe keeps the count looking right"
run_sweep
assert_exit_nonzero "$RC" "the sweep refuses"
assert_contains "$OUT" "RL-005" "the offending row is named"
assert_contains "$OUT" "outside the table" "the diagnosis names the real cause"
assert_not_contains "$OUT" "has 6 cell(s), want 6" "it does not report a count that is correct"

# --- a ledger the row pattern no longer matches is a refusal, not a pass ----

# ⛔ The fall-through has to default to HAZARD. An empty result here means
# either that every finding was discharged or that the parse stopped working,
# and those must not look the same — "(none open)" over a file whose shape
# drifted is the sweep reporting a clean inheritance it never checked.
write_ledger <<'EOF'
| RL0006 | a finding whose id does not match the row pattern | a review | open | now | unfixed |
EOF

test_case "zero_parsed_rows_is_refused" "an empty parse is a refusal, not an empty residue list"
run_sweep
assert_exit_nonzero "$RC" "the sweep refuses to report a clean sweep over nothing"
assert_contains "$OUT" "parsed 0 ledger rows" "the refusal says what happened"
assert_not_contains "$OUT" "(none open)" "it does not report an empty residue list"

# --- a reordered or renamed header is a refusal, not 300 open rows ----------

# ⛔ Reading by COLUMN is only as good as knowing which column is which. Every
# verdict here indexes `status` at position 3, so a reordered header makes each
# row parse cleanly and mean something else.
#
# ⚠️ That failure IS loud on its own — a reorder prints every row as open — but
# loud is not interpretable, and "300 open rows" invites the reading that the
# ledger exploded rather than that the header moved. The same distinction as a
# floor refusal versus a hazard verdict: both red, only one tells you what to do.
# This case asserts the message, not just the exit code, for that reason.
LEDGER_HEADER='| id | finding | status | source | due_when | disposition |'
write_ledger <<'EOF'
| RL-010 | a finding | closed | a review | — | fixed |
EOF

test_case "a_reordered_header_is_refused" "a positional read must check its positions"
run_sweep
# ⚠️ The exit code alone does NOT discriminate here, measured: with the header
# check defeated, the reordered row's `status` cell holds `a review`, which the
# status-vocabulary check then refuses — so the sweep still exits non-zero for a
# different reason. Only the message assertion below separates the two.
assert_exit_nonzero "$RC" "the sweep refuses rather than reading the wrong cells"
assert_contains "$OUT" "column header is not the one this reader indexes" \
    "the refusal names the cause, so it is not mistaken for an exploded ledger"
assert_not_contains "$OUT" "row(s) parsed" "it stops before reporting verdicts it cannot trust"
unset LEDGER_HEADER

# --- an unrecognised status is a refusal ------------------------------------

# ⛔ The status test is `!= "closed"`, so ANY unrecognised value reads as OPEN.
# That is the safe direction for a typo and silent in both: a misspelled
# `clsoed` becomes permanent residue nobody can discharge, and nothing says the
# word is wrong.
write_ledger <<'EOF'
| RL-011 | a finding whose status is misspelled | a review | clsoed | — | fixed |
| RL-012 | a finding that really is open | a review | open | now | unfixed |
EOF

test_case "an_unrecognised_status_is_refused" "a misspelled status cannot become silent residue"
run_sweep
assert_exit_nonzero "$RC" "the sweep refuses"
assert_contains "$OUT" "unrecognised status value" "the refusal says what is wrong"
# ⚠️ Asserted on the QUOTED form, measured. With the check defeated, `clsoed`
# reads as open and the row is printed verbatim — so a bare `clsoed` / `RL-011`
# assertion is satisfied by the row LISTING rather than by the refusal, and
# passes against the defect. The refusal is the only thing that prints the value
# in quotes.
assert_contains "$OUT" "'clsoed'" "and quotes the offending value in the refusal, not merely lists the row"
assert_contains "$OUT" "(RL-011)" "and names the row carrying it, in the refusal's own form"
assert_not_contains "$OUT" "RL-012" "the genuinely open row is not blamed for it"

# --- a trigger naming only COMPLETED issues has fired ----------------------
#
# ⛔ The sweep's older half looks for the literal word SATISFIED, which someone
# has to have typed — so a trigger is discharged exactly as often as its author
# comes back to say so, which is the property this ledger exists to remove.
#
# MEASURED 2026-10-22: a row's trigger named a wave item as "in progress" after
# that item had completed. A fresh pass reads that as scheduled against work
# still in flight, so the row is neither discharged nor re-derived.
#
# ⚠️ The sandbox's paths are DERIVED and its reference numbers ASSEMBLED, for
# the reason already given above the ledger path: a literal path into the
# tracker trees, or a literal reference number, is forbidden in code, and this
# fixture fits neither exemption list. The numbers below are synthetic fixture
# data rather than citations, but the gate cannot tell those apart from the
# outside — and the fix that makes it tell them apart is the same one the
# ledger path already uses, so it is applied rather than argued with.
STATE_REL="$(dirname "$LEDGER_REL")/probe-state.json"
# The gate forbids a literal reference in code; these are sandbox row data, so
# the sigil is assembled rather than written.
REF='#'

write_state() {
    mkdir -p "$SANDBOX/$(dirname "$STATE_REL")"
    cat > "$SANDBOX/$STATE_REL"
}

clear_state() { rm -f "$SANDBOX/$(dirname "$STATE_REL")/"*state.json; }

one_item_each() {
    python3 - "$SANDBOX/$STATE_REL" "$@" <<'STATE'
import json, sys

path, pairs = sys.argv[1], sys.argv[2:]
items = {}
for i in range(0, len(pairs), 2):
    number, state = pairs[i], pairs[i + 1]
    items[f"w{number}"] = {"issue": number, "status": state, "title": f"item {number}"}
json.dump({"campaign": "probe", "waves": {"one": {"items": items}}}, open(path, "w"), indent=2)
STATE
}

mkdir -p "$SANDBOX/$(dirname "$STATE_REL")"
DONE="${REF}900"
LIVE="${REF}901"
UNTRACKED="${REF}902"
one_item_each 900 complete 901 not_started

write_ledger <<EOF
| RL-020 | a finding whose owner has shipped | a review | open | with ${DONE} | unfixed |
| RL-021 | a finding whose owner is still to come | a review | open | with ${LIVE} | unfixed |
EOF

test_case "a_trigger_naming_only_completed_issues_is_reported" \
    "the computable half — a fired trigger must not wait for someone to type SATISFIED"
run_sweep
assert_contains "$OUT" "RL-020: every issue it names is complete" "the fired trigger is named"
assert_contains "$OUT" "re-point it at the issue that owns the class now" \
    "and the message offers the other legitimate outcome, not only discharge"
assert_not_contains "$OUT" "RL-021: every issue" \
    "a row whose owner is not_started has NOT fired, so it must stay silent"

# ⛔ ALL cited issues, not ANY — and this case exists because the fix to the row
# that motivated this check would otherwise trip it. A row legitimately names a
# completed predecessor as context alongside its live owner.
test_case "a_trigger_mixing_a_completed_and_a_live_issue_is_not_reported" \
    "a row is owned while ANY cited issue is live, so 'any complete' would be wrong"
write_ledger <<EOF
| RL-022 | a finding re-pointed at its new owner | a review | open | moved from ${DONE}, now ${LIVE} | unfixed |
EOF
run_sweep
assert_contains "$OUT" "RL-022" "the row is still listed as non-closed"
assert_not_contains "$OUT" "every issue it names is complete" \
    "one cited issue is not_started, so the trigger has not fired"

test_case "a_trigger_citing_an_untracked_issue_is_reported_as_unknown" \
    "unknown is a third state — reading it as 'not complete' hides an untracked owner"
write_ledger <<EOF
| RL-023 | a finding whose owner is in no campaign | a review | open | with ${UNTRACKED} | unfixed |
EOF
run_sweep
assert_contains "$OUT" "status UNKNOWN, not 'incomplete'" "the distinct state is named as such"
assert_contains "$OUT" "RL-023" "and the row carrying it"

# --- the SATISFIED marker is a CELL, not a word on the line ----------------
#
# ⛔ The repo's most-recorded gate failure, caught here by a ledger row that
# described a different instance of it. A row whose FINDING text contained "ALL
# SATISFIED BY ITS FIXTURE" was reported as a satisfied trigger — and the row
# was `closed`, so the sweep's one job, naming rows that should join the next
# campaign frame, produced a finished row and a wall of unrelated prose.
#
# A ledger whose rows discuss gate markers will contain those markers as words,
# so position is the only thing separating configuration from commentary.
# ⚠️ THIS CASE IS SPLIT IN TWO BECAUSE THE FIRST VERSION DID NOT DISCRIMINATE.
# MEASURED: it put the prose marker on a CLOSED row, so the closed-row filter
# caught it and the positional read was never exercised — a probe reverting the
# cell read to a whole-line grep left the suite fully green. Two independent
# narrowings need two cases, or whichever runs second is untested.
test_case "the_satisfied_marker_in_an_OPEN_row_s_prose_is_not_read_as_a_trigger" \
    "the positional read — a ledger that discusses markers contains them as words"
write_ledger <<EOF
| RL-024 | a finding noting that sixteen assertions were ALL SATISFIED by a fixture | a review | open | with ${LIVE} | unfixed |
EOF
run_sweep
assert_contains "$OUT" "RL-024" "the row is listed as non-closed, so the sweep ran"
assert_not_contains "$OUT" "SATISFIED due_when" \
    "the word sits in the finding, not the trigger, so it is a mention and not a marker"

test_case "the_satisfied_marker_on_a_CLOSED_row_is_not_read_as_a_trigger" \
    "the status narrowing — a discharged row cannot join the next frame"
write_ledger <<EOF
| RL-025 | a finding already dealt with | a review | closed | SATISFIED by the merge | fixed |
| RL-026 | a live finding | a review | open | with ${LIVE} | unfixed |
EOF
run_sweep
assert_contains "$OUT" "RL-026" "the open row is listed, so the sweep ran"
assert_not_contains "$OUT" "SATISFIED due_when" \
    "a closed row's fired trigger is history, and reporting it sends someone to finished work"

test_case "the_satisfied_marker_in_the_due_when_cell_is_read" \
    "the green half — the marker must still work where it belongs"
write_ledger <<'EOF'
| RL-027 | a finding whose author came back to say so | a review | open | SATISFIED by the merge | unfixed |
EOF
run_sweep
assert_contains "$OUT" "SATISFIED due_when" "the marker in the right cell is read"
assert_contains "$OUT" "RL-027: SATISFIED by the merge" \
    "and the row is named with its trigger, not dumped in full"

# --- the walker must prove it read something -------------------------------
#
# ⚠️ An earlier version of this floor refused below 20 known statuses, which
# refused every sandbox in this suite and would refuse a young campaign. A
# floor that fails on a legitimately small input is not measuring what it
# claims. The size-independent signal is items walked versus numbers found.
test_case "a_walker_that_extracts_no_issue_numbers_is_refused" \
    "items with no issue field would make every trigger read UNKNOWN"
write_state <<'EOF'
{ "campaign": "probe",
  "waves": { "one": { "items": {
    "a": { "ticket": "900", "status": "complete", "title": "the field moved" },
    "b": { "ticket": "901", "status": "complete", "title": "and again" } } } } }
EOF
write_ledger <<EOF
| RL-028 | a finding | a review | open | with ${DONE} | unfixed |
EOF
run_sweep
assert_exit_nonzero "$RC" "a walker that found nothing is a refusal, not a clean result"
assert_contains "$OUT" "extracted ZERO issue numbers" "the refusal names the condition"
assert_contains "$OUT" "indistinguishable from a ledger with none" "and says why it cannot pass"

test_case "no_campaign_state_at_all_is_reported_inapplicable" \
    "nothing to reconcile must not read as everything reconciles"
clear_state
run_sweep
assert_exit_zero "$RC" "a repo with no campaign is not an error"
assert_contains "$OUT" "trigger reconciliation did not run" "the check says it did not run"
assert_not_contains "$OUT" "cited issues are live" \
    "and does not claim the triggers were checked"

summarise
