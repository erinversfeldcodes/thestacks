#!/usr/bin/env bash
# Refuse a pipeline whose exit status is read but can be 141 instead of the
# answer.
#
# ⛔ WHY THIS GATE EXISTS — a security scan that reported "clean" on a critical
# finding. The shape:
#
#     if echo "$scan_out" | grep -q "[critical]"; then   # under set -o pipefail
#
# `grep -q` exits on its FIRST match and closes the pipe. `echo` is still
# writing, so it takes SIGPIPE and dies with 141. Under `pipefail` the
# PIPELINE's status is that 141, not grep's 0 — so the `if` goes FALSE **on a
# match** and the else branch runs. Measured on a 300KB payload: match first →
# rc=141, match last → rc=0.
#
# That size-dependence is what makes it so dangerous. It needs the payload to
# exceed the pipe buffer with the match inside it, so it is invisible on small
# inputs, intermittent near the boundary (it was first found as a 2-in-6 flake),
# and reliable only once the output is big — i.e. it arrives exactly when a
# scanner has the most to report. Auditing payload sizes is the wrong fix; the
# form is wrong at any size, and a here-string costs nothing.
#
# ⚠️ Scope: the first sweep for this looked only at `scripts/check-*.sh`, which
# is why the integration gate and the deploy gate kept the bug for another
# round. Completeness here is a fact about the hazard, not about a directory,
# so this gate reads every pipefail-bearing shell script in the repo.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Consumers that may exit before the producer has finished writing. `head` and
# `grep -m<n>` always do; `grep -q` does on a match; `sed …q` and `awk …exit`
# do on their condition. The `-[a-zA-Z]*q` spelling is deliberate: `grep -Eq`
# and `grep -iq` are the same defect as `grep -qE`, and a pattern that only
# caught the one spelling already in the tree would miss the next one.
#
# ⚠️ The leading `[^|]` is load-bearing: without it this matches the `||` in
# `cmd_a || grep -q PAT file`, which has no pipe at all. Two such sites read as
# hazards in the first run of this gate, and a gate with false positives gets
# an exemption list bolted on — which is how the predecessor to this family of
# checks ended up with eight free-text reasons, seven of them untrue.
# ⛔ SPLIT BY WHAT THE CONSUMER DOES WITH THE ANSWER, not by surrounding syntax.
# The first version of this gate asked "is the status read?" and answered it
# from syntax alone (`if`/`elif`/`while`/`&&`/`||`), which exempted every BARE
# pipeline — and under `set -e` the shell consumes a bare pipeline's status with
# no syntax at all. That hid real hazards in ~70 scripts.
#
# STATUS-ONLY consumer: the answer travels in the exit status and NOWHERE else.
# 141 is indistinguishable from "no match", so there is no safe way to pipe into
# it — not even `|| true`, which discards the only output it has.
CONSUMER_STATUS_ONLY='[^|]\| *grep [^|]*-[a-zA-Z]*q'

# OUTPUT consumer: the answer is on stdout and is CORRECT even when the producer
# is killed — `head -5` still printed its five lines. Only the status is
# poisoned, so these are hazards exactly when the status is consumed.
CONSUMER_OUTPUT='[^|]\| *(grep [^|]*-m *[0-9]|head( |$)|sed -n [^|]*q|awk [^|]*exit)'

# ⛔ MEASURED, because the rule is not guessable. Under `set -euo pipefail`, with
# a producer guaranteed to take SIGPIPE (`yes | head -1`):
#
#     bare pipeline            -> rc=141, script DIES
#     X="$(cmd | head -1)"     -> rc=141, script DIES   (assignment)
#     echo "$(cmd | head -1)"  -> rc=0,   survives      (argument: outer wins)
#     if cmd | head -1; then   -> rc=0,   survives, but `if` READS the status
#     cmd | head -1 || true    -> rc=0,   survives, status discarded
#
# So the status is consumed by: a bare pipeline, an assignment from one, or a
# syntactic read. It is NOT consumed by a pipeline in argument position, which
# is why `success "$(brew --version | head -1)"` is correctly left alone.
STATUS_READ_SYNTACTICALLY='^[[:space:]]*(if|elif|while|until|!)[[:space:]]|^[[:space:]]*(\|\||&&)|(\|\||&&)[[:space:]]*$'
STATUS_DISCARDED='\|\|[[:space:]]*(true|echo|:|\{)'

# ⛔ ANY assignment, not just one whose entire RHS is the substitution — and the
# difference was a P1 in the previous version of this gate. It paired a
# deliberately NARROW "is this an assignment" test with a broad "is this an
# argument" test meaning SAFE, in that order, so every assignment shape the
# narrow test declined to match fell through and was silently exempted.
#
# MEASURED, all four under `set -euo pipefail` with a SIGPIPE'd producer, all
# rc=141 and all dying:
#
#     X="prefix$(cmd | head -1)"      X="${V:-$(cmd | head -1)}"
#     X[0]="$(cmd | head -1)"         arr+=("$(cmd | head -1)")
#
# The general rule, which is the finding rather than the four shapes: **a
# deliberately-narrow inclusion test is only safe when the fall-through defaults
# to HAZARD.** Here it defaulted to safe, so narrowness became exemption.
# ⚠️ Anchored at any point a STATEMENT can begin, not just at line start — and
# that was a second instance of the same hole, found by testing the rule against
# itself rather than by review. An assignment inside a `case` arm or a
# `then`/`else`/`do` branch is not at line start, so the line-anchored version
# fell through to argument position and was exempted. Both MEASURED at rc=141
# under `set -euo pipefail`:
#
#     case x in x) V="$(cmd | head -1)" ;; esac
#     if true; then V="$(cmd | head -1)"; fi
#
# ⚠️ Known over-match, in the safe direction: `A=1 CMD "$(cmd | head -1)"` — a
# variable prefixed onto a command — reads as an assignment here and is actually
# argument position (measured rc=0). No such site exists in the corpus; if one
# appears it will be a false positive rather than a miss, which is the direction
# this gate is supposed to err in.
IS_ASSIGNMENT='(^|;|&&|\|\||\bthen|\belse|\bdo|\{|\))[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?='

# ⚠️ A declaring BUILTIN discards the substitution's status, because the
# builtin's own status is the command's. MEASURED: `local X="$(cmd | head -1)"`,
# and the same with `export` and `declare`, all rc=0 and all surviving under
# `set -e` — unlike the bare `X="$(…)"` form, which dies.
#
# These were already exempt in the previous version, but for the WRONG reason
# (they failed the narrow assignment test and fell through to safe). Branching
# on them explicitly keeps the right outcome once the fall-through is inverted.
IS_BUILTIN_DECL='^[[:space:]]*(local|export|declare|readonly|typeset)[[:space:]]'

# ⚠️ Files whose JOB is to contain the banned form as DATA, with the reason
# stated. This is the exemption list the reviewer asked for, and it is kept to
# whole files rather than line numbers deliberately: line numbers rot on the
# next edit, and a rotted exemption silently covers something else. Every entry
# here is a file that tests this pattern and must therefore spell it.
# ⛔ ONE place the corpus is defined, and that is not tidiness. It was two call
# sites — the scan loop and the floor's denominator — and the suite isolates the
# corpus by substituting the discovery, so it neutralised one and left the other
# reaching the real repository. The suite's own anti-vacuity check caught it,
# which is the only reason it did not silently half-work.
#
# Tracked AND untracked-but-not-ignored: `git ls-files` alone cannot see a new
# script, and this gate was invisible to ITSELF until it was committed — the run
# that first included it found two violations in its own guidance text.
discover_shell_scripts() {
    { git ls-files '*.sh'; git ls-files --others --exclude-standard '*.sh'; } | sort -u
}

# ⚠️ A CHECKED claim, not a bare list. Each exempted file is exempt because its
# job is to spell the banned form as test data — so the exemption is only valid
# while that is still true, and the cheapest proof of it is that the file still
# references this gate. A test file that stops testing this gate and keeps its
# exemption is a blind spot with a reason attached, which is worse than no
# reason at all: the next reader trusts it.
#
# ⛔ `scripts/check-sigpipe-hazards.sh` is NOT in this list. Exempting the gate
# wholesale would hide a real hazard in its own executable code, and it does not
# need the exemption: every pipeline in it is already a here-string, so the only
# matches are the pattern DEFINITIONS and the GUIDE heredoc. Those are handled
# by the narrower rule below rather than by a file-wide pass.
FIXTURE_FILES=(
    # Plants the banned form to prove this gate refuses it.
    "test/platform/sigpipe_hazard_gate_test.sh"
    # Carries five spellings of it as anti-vacuity data for its own pattern.
    "test/platform/rls_scope_gate_test.sh"
)

is_fixture_file() {
    local candidate="$1" fixture
    for fixture in "${FIXTURE_FILES[@]}"; do
        [[ "$candidate" == "$fixture" ]] || continue
        # The claim, checked: it is still a test of this gate's subject.
        if grep -q "check-sigpipe-hazards\|check-rls-scope" "$candidate" 2>/dev/null; then
            return 0
        fi
        # ⚠️ The lapse phrase is kept on ONE line, so a grep for it cannot be
        # defeated by the wrap. A test asserting this message straddled two
        # lines and reported the gate as having accepted what it had refused.
        echo "FAIL check-sigpipe-hazards: a fixture exemption has lapsed." >&2
        echo "  ${candidate} is exempted as a fixture file but no longer references the gate it tests," >&2
        echo "  so its exemption is now hiding whatever the file contains." >&2
        echo "  Remove the exemption, or restore the test." >&2
        exit 1
    done
    return 1
}

# The gate's own file: only the pattern definitions and the printed guidance may
# contain the banned form, because those are data. Anything else in it is code.
is_own_pattern_definition() {
    [[ "$1" == "scripts/check-sigpipe-hazards.sh" ]] || return 1
    grep -qE "^(CONSUMER_STATUS_ONLY|CONSUMER_OUTPUT)=|^      a pipe (from|into)" <<< "$2"
}

FOUND=0
SCANNED=0
EXEMPTED=0
REPORT=""

while IFS= read -r file; do
    # Only scripts where pipefail is actually in effect.
    grep -qE '^[[:space:]]*set .*pipefail' "$file" || continue
    SCANNED=$((SCANNED + 1))

    if is_fixture_file "$file"; then
        EXEMPTED=$((EXEMPTED + 1))
        continue
    fi

    # ⛔ `set -e` is what makes a bare pipeline's status load-bearing, so the
    # predicate below branches on it. Without `-e` an unread status is genuinely
    # discarded: `BASH_ID="$(bash --version | head -1)"` in a `set -uo pipefail`
    # script takes the stdout it wants and nothing ever looks at the 141. Not
    # branching on this was the first rewrite's error — it reported 36 sites, of
    # which 20 were that shape.
    errexit=no
    grep -qE '^[[:space:]]*set -[a-z]*e' "$file" && errexit=yes

    # Strip comments before matching: this gate must not read the prose that
    # explains the banned form as an instance of it. Every fix in the tree
    # carries a comment quoting the bad shape, and an absence check that counts
    # those is the "gates read their own comments as configuration" defect.
    while IFS=: read -r lineno text; do
        [ -n "${lineno:-}" ] || continue

        why=""
        if is_own_pattern_definition "$file" "$text"; then
            why=""
        elif grep -qE "$CONSUMER_STATUS_ONLY" <<< "$text"; then
            # No escape hatch: the status IS the answer.
            why="pipes into grep -q, whose answer is only its exit status"
        elif grep -qE "$CONSUMER_OUTPUT" <<< "$text"; then
            if grep -qE "$STATUS_DISCARDED" <<< "$text"; then
                why=""
            elif grep -qE "$STATUS_READ_SYNTACTICALLY" <<< "$text"; then
                # A syntactic read is a hazard with or without `set -e`.
                why="status read by if/while/&&/||"
            elif [ "$errexit" = no ]; then
                # No `-e`, and nothing reads it: the 141 goes nowhere and the
                # stdout this site wanted is correct.
                why=""
            elif grep -qE "$IS_BUILTIN_DECL" <<< "$text"; then
                # local/export/declare: the builtin's status wins. Measured.
                why=""
            elif grep -qE "$IS_ASSIGNMENT" <<< "$text"; then
                # ⛔ EVERY assignment shape, because this branch is now the one
                # that catches the shapes nobody enumerated. Prefix-concatenated,
                # default-expanded, indexed and append-assigned all die here.
                why="assignment under set -e — the pipeline's status becomes the script's"
            elif grep -qE '\$\(' <<< "$text"; then
                # A command substitution that is NOT an assignment, i.e. argument
                # position: the outer command's status wins. Measured.
                why=""
            else
                why="bare pipeline under set -e — its status is taken with no syntax at all"
            fi
        fi

        [ -n "$why" ] || continue
        FOUND=$((FOUND + 1))
        REPORT="${REPORT}  ${file}:${lineno}  (${why})
    ${text}
"
    done < <(sed 's/#.*//' "$file" | grep -nE "$CONSUMER_STATUS_ONLY|$CONSUMER_OUTPUT" || true)
done < <(discover_shell_scripts)

# ⚠️ Anti-vacuity. If the discovery stops finding scripts — a renamed
# directory, a changed shebang convention, `git ls-files` run outside a repo —
# "0 hazards" is indistinguishable from "0 files read". The floor makes the
# difference visible, which is the failure mode this whole class keeps taking.
#
# ⛔ A FRACTION of the shell corpus, not a constant, and the denominator needs
# no guessing because this gate already computes it: 137 of 147 tracked `.sh`
# files carry `pipefail` today, i.e. 93%. A constant floor of 30 would have sat
# happily through a migration that moved strict mode into a sourced helper and
# took the pipefail-bearing count from 137 to 40 — the discovery eroding by two
# thirds while the gate reported clean.
TOTAL_SH="$(discover_shell_scripts | grep -c . || true)"

# ⛔ A fraction AND an absolute minimum, because a fraction alone is vacuous at
# zero: with an empty corpus `TOTAL_SH / 2` is 0 and `SCANNED=0 >= 0` passes.
# The proportional floor catches gradual erosion (strict mode moving into a
# sourced helper); the absolute one catches total discovery failure, which is
# the case that produces a confident "no hazards" over nothing at all. The
# suite's empty-corpus case found this in the first version of this very check.
ABSOLUTE_MIN=30
FLOOR=$(( TOTAL_SH / 2 ))
[[ "${FLOOR}" -lt "${ABSOLUTE_MIN}" ]] && FLOOR="${ABSOLUTE_MIN}"
if [[ "${SCANNED}" -lt "${FLOOR}" ]]; then
    echo "FAIL check-sigpipe-hazards: only ${SCANNED} of ${TOTAL_SH} shell script(s) carry pipefail; floor is ${FLOOR} (half the corpus)." >&2
    echo "  Either the discovery broke or the convention changed. A clean result from" >&2
    echo "  a broken search is the defect this gate exists to catch, so refusing." >&2
    exit 1
fi

# ⛔ The corpus is safe partly because of a fact outside it: every script here
# is bash-shebanged, and bash word-splits an unquoted parameter. Several gates
# rely on that — `for entry in $RLS_SCOPE_TEST_ALLOWLIST` and
# `for _stale in $_STALE_IDS` are both correct ONLY under a splitting shell.
#
# Under zsh an unquoted parameter is NOT split, so those loops would silently
# iterate once over the whole string: `git diff -- $paths` becomes one pathspec
# matching nothing, exits 0, and reports an empty result. That is this file's
# own failure mode — a work set that is empty for the wrong reason — and it is
# how a reviewer's five stale reviews got dispatched as four narrow ones.
#
# ⚠️ The fix for such a site is an ARRAY, not quoting: `"$paths"` reproduces
# the single-argument bug under bash too, which is the opposite of the
# glob-quoting convention this repo otherwise follows. Nothing in the corpus
# needs changing today; what needs guarding is the ambient assumption.
if grep -qE '^[[:space:]]*set[[:space:]]+shell[[:space:]]*:=' "$REPO_ROOT/justfile" 2>/dev/null; then
    if grep -qE '^[[:space:]]*set[[:space:]]+shell[[:space:]]*:=.*zsh' "$REPO_ROOT/justfile"; then
        echo "FAIL check-sigpipe-hazards: the justfile sets a zsh shell." >&2
        echo "  Several gates rely on an unquoted parameter being word-split, which zsh does" >&2
        echo "  not do — those loops would iterate once over the whole string and report an" >&2
        echo "  empty result rather than failing. Use bash, or convert every such site to an" >&2
        echo "  array (quoting is NOT the fix — it reproduces the bug under bash)." >&2
        exit 1
    fi
fi

if [[ "${FOUND}" -ne 0 ]]; then
    echo "FAIL check-sigpipe-hazards: ${FOUND} pipeline(s) whose status is read can return 141 instead of an answer." >&2
    printf '%s' "${REPORT}" >&2
    cat >&2 <<'GUIDE'

  Under `pipefail`, an early-exiting consumer kills the producer with SIGPIPE
  and the pipeline reports 141 — so the test goes the WRONG WAY on a match.

  Rewrite to drop the pipe. (Described rather than shown: this guidance is
  printed by the gate, not commented out, so spelling the banned form here
  literally would make the gate report itself -- which it did once.)

      a pipe from echo/printf into `grep -q PAT`
          -> drop the producer, feed grep a here-string: grep -q PAT <<< "$out"

      a pipe from any command into `grep -q PAT`
          -> capture first: out="$(cmd || true)", then the here-string form

      a pipe into `head -N` used for truncation
          -> capture, then slice: cmd_out="$(cmd)"; X="${cmd_out:0:2000}"

  If a site is genuinely safe, it still has to stop reading the status. And for
  a status-only consumer there is no such fix: defusing it with a logical-or
  discards the only answer it has, rather than rescuing it.
GUIDE
    exit 1
fi

echo "OK: ${SCANNED} pipefail-bearing script(s) (${EXEMPTED} fixture file(s) exempt by name), no pipeline into an early-exiting consumer whose status is consumed."
