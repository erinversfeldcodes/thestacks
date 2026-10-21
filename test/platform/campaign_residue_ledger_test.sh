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
        printf '| id | finding | source | status | due_when | disposition |\n'
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

summarise
