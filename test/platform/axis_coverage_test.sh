#!/usr/bin/env bash
# test/platform/axis_coverage_test.sh
#
# `scripts/check-axis-coverage.sh`: a changed file of RUNNING CODE that belongs
# to no stack-review axis is a module the reviewers never see — a blind spot the
# width of its own diff.
#
# ⛔ The gate exists because that blindness shipped. The `config/` layer mapped to
# no axis and a storage selector went to production unreviewed (RL-472); a
# measured 129 of one branch's 758 changed files belonged to no axis at all
# (RL-450). The gate computes changed-files minus the axis trees minus an
# allowlist, and anything left is unowned.
#
# ⚠️ And this suite exists because the gate's green run meant nothing until its
# RED run was proven: a set-difference gate is empty when the code is correct AND
# when it is pointed at nothing. The cases below plant each outcome.
#
# The gate reads `git diff --name-only BASE...HEAD`, so every case is a THROWAWAY
# git repo — a base commit plus a planted change, run with AXIS_COVERAGE_BASE
# pinned to that base. The fixtures neither depend on nor disturb the real tree.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-axis-coverage.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a throwaway repo: a base commit, then each argument is a file created and
# committed as the change. Prints "<dir>\t<base-sha>".
build_repo() {
    local dir="$WORK/r$RANDOM$RANDOM"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.test
    git -C "$dir" config user.name t
    printf 'base\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm base
    local base
    base="$(git -C "$dir" rev-parse HEAD)"
    local f
    for f in "$@"; do
        mkdir -p "$dir/$(dirname "$f")"
        printf 'x\n' > "$dir/$f"
    done
    git -C "$dir" add -A
    git -C "$dir" commit -qm change
    printf '%s\t%s' "$dir" "$base"
}

run_gate() { # $1 dir, $2 base-sha
    (cd "$1" && AXIS_COVERAGE_BASE="$2" bash "$GATE" 2>&1)
}

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-axis-coverage.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

test_case "it_passes_against_the_real_tree" "the branch's own changed files are all owned"
OUT_REAL="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
RC_REAL=$?
if [[ "$RC_REAL" -eq 0 ]]; then
    _record_pass "the gate passes against the real tree (exit 0)"
else
    _record_fail "the gate fails against the real tree, so either a file is unowned or the gate is broken: $OUT_REAL"
fi
assert_contains "$OUT_REAL" "belong to a review axis" \
    "the pass states what it checked rather than printing OK alone"

test_case "an_unowned_running_code_file_FAILS" "the defect class, planted"
# `toolbox/` is under no AXIS_PREFIX and no ALLOWLIST_PREFIX — exactly the shape
# of the config/ layer that shipped unreviewed.
read -r DIR BASE < <(build_repo "toolbox/thing.py")
OUT="$(run_gate "$DIR" "$BASE")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    _record_pass "a changed file under no axis fails the gate (exit $RC)"
else
    _record_fail "an unowned running-code file PASSED: $OUT"
fi
assert_contains "$OUT" "toolbox/thing.py" "and the failure names the unowned file"

test_case "a_file_under_an_axis_PASSES" "anti-vacuity for the case above"
# Without this, the failure above would be satisfied by a gate that rejects every
# tree it is pointed at.
read -r DIR BASE < <(build_repo "apps/core/lib/stacks/foo.ex")
OUT_AXIS="$(run_gate "$DIR" "$BASE")"
RC_AXIS=$?
if [[ "$RC_AXIS" -eq 0 ]]; then
    _record_pass "a changed file under an axis tree passes (exit 0)"
else
    _record_fail "a file under apps/core/lib was rejected, so the failure above proves nothing: $OUT_AXIS"
fi

test_case "an_allowlisted_tree_PASSES" "the second anti-vacuity direction"
# A docs change is running-code-free by written decision — it must pass, or the
# gate would demand a reviewer for every README.
read -r DIR BASE < <(build_repo "docs/some-note.md")
OUT_DOC="$(run_gate "$DIR" "$BASE")"
RC_DOC=$?
if [[ "$RC_DOC" -eq 0 ]]; then
    _record_pass "a changed file under an allowlisted tree passes (exit 0)"
else
    _record_fail "an allowlisted docs change was rejected: $OUT_DOC"
fi

test_case "a_generated_tree_PASSES" "a generated artefact is never demanded a reviewer"
# `apps/core/lib/stacks/gen/` is allowlisted (generated) AND sits under an axis
# prefix, so it passes EITHER way — this pins only that a proto regen is never
# flagged, NOT that the allowlist is load-bearing here (the axis match alone would
# pass it). The allowlist's load-bearing case — a tree under NO axis — is
# `an_allowlisted_tree_PASSES` (docs/).
read -r DIR BASE < <(build_repo "apps/core/lib/stacks/gen/proto/foo.ex")
OUT_GEN="$(run_gate "$DIR" "$BASE")"
RC_GEN=$?
if [[ "$RC_GEN" -eq 0 ]]; then
    _record_pass "a generated file under an axis tree still passes (exit 0)"
else
    _record_fail "a generated artefact was demanded a reviewer: $OUT_GEN"
fi

test_case "AXIS_PREFIXES_mirror_STACK_PATHS" "⚠️ the drift the gate's own comment invites catching"
# The gate duplicates wave-status.sh's STACK_PATHS because a bash gate cannot
# safely parse the Python dict. A tree mapped to an axis there but absent here is
# a file the gate would call unowned though a reviewer owns it — a false FAIL
# that would push someone to allowlist a reviewed tree. Assert every STACK_PATHS
# value is covered by an AXIS_PREFIXES entry.
WAVE="$REPO_ROOT/scripts/wave-status.sh"
GATE_SRC="$(cat "$GATE")"
# Extract the STACK_PATHS dict VALUES only — isolate the dict block, drop each
# line's key (everything up to its first colon), then harvest quoted strings.
# This excludes the keys ("elixir", …) and every other quoted path elsewhere in
# the file (such as `origin/main`) that is not a review-axis tree.
mapfile -t STACK_TREES < <(
    awk '/STACK_PATHS *= *\{/{f=1;next} /^\}/{f=0} f' "$WAVE" 2>/dev/null \
        | sed 's/^[^:]*://' \
        | grep -oE '"[^"]+"' | tr -d '"' | sort -u
)
missing=""
for t in "${STACK_TREES[@]}"; do
    # Covered if some AXIS_PREFIXES or ALLOWLIST line contains this tree as a
    # prefix. A here-string, not a pipe into grep -q: under pipefail an
    # early-exiting grep -q SIGPIPEs the producer and the pipeline reports 141,
    # which would read as "no match" on a match (check-sigpipe-hazards.sh).
    if ! grep -qF "\"$t" <<<"$GATE_SRC"; then
        # tolerate a trailing-slash difference (STACK_PATHS "apps/core/lib" vs gate "apps/core/lib/")
        if ! grep -qF "\"${t%/}/" <<<"$GATE_SRC"; then
            missing="${missing} ${t}"
        fi
    fi
done
if ((${#STACK_TREES[@]} < 15)); then
    # ⛔ Anti-vacuity floor on the VALUE count, not the key count. STACK_TREES is
    # the dict's VALUES (the path tuples — ~19 today, several per stack), not its
    # 7 keys. The check is a set-difference, empty when every tree is mirrored AND
    # when the parse dropped most values; a floor of <15 catches a parse that
    # skipped trees (which the mirror loop would then silently not check) while
    # still allowing the dict to shift by a value or two.
    _record_fail "extracted only ${#STACK_TREES[@]} STACK_PATHS value(s) — the dict has ~19 (several per stack); a count this low means the parse dropped trees the mirror check then skips"
elif [[ -z "$missing" ]]; then
    _record_pass "every STACK_PATHS tree is mirrored in the gate (${#STACK_TREES[@]} checked)"
else
    _record_fail "STACK_PATHS trees absent from the gate's AXIS_PREFIXES/ALLOWLIST:${missing} — a reviewed tree the gate would call unowned"
fi

test_case "an_unresolvable_base_FAILS" "⚠️ the gate fails CLOSED when it cannot compute the changed set"
# A base ref that does not resolve must FAIL, not pass as "0 changed files" — a
# shallow CI checkout that never fetched origin/main is exactly that case.
read -r DIR BASE < <(build_repo "apps/core/lib/stacks/foo.ex")
OUT_NOBASE="$(cd "$DIR" && AXIS_COVERAGE_BASE=refs/does-not-exist bash "$GATE" 2>&1)"
RC_NOBASE=$?
if [[ "$RC_NOBASE" -ne 0 ]]; then
    _record_pass "an unknown base ref fails the gate (exit $RC_NOBASE)"
else
    _record_fail "an unknown base ref PASSED — the gate computed an empty changed set and called it clean: $OUT_NOBASE"
fi
assert_contains "$OUT_NOBASE" "does not resolve" "and the failure says the base is the problem"

test_case "AXIS_PREFIXES_reverse_mirror" "⚠️ the OTHER drift direction — a gate axis prefix absent from STACK_PATHS"
# The mirror check above proves STACK_PATHS ⊆ gate. This proves the reverse: gate
# AXIS_PREFIXES ⊆ STACK_PATHS. An axis tree added to the gate but NOT to
# wave-status.sh's STACK_PATHS would pass coverage here as "owned" yet never stale
# a reviewer in wave-status — the RL-472 blind spot reopened via the OTHER list.
# (ALLOWLIST entries legitimately are not in STACK_PATHS, so only the axis
# prefixes are checked.) The gate's own "Keep them equal" is enforced in full now.
mapfile -t AXIS_VALS < <(
    awk '/^AXIS_PREFIXES=\(/{f=1;next} /^\)/{f=0} f' "$GATE" 2>/dev/null \
        | grep -oE '"[^"]+"' | tr -d '"' | sort -u
)
rev_missing=""
for p in "${AXIS_VALS[@]}"; do
    pt="${p%/}"
    found=0
    for t in "${STACK_TREES[@]}"; do
        [[ "${t%/}" == "$pt" ]] && {
            found=1
            break
        }
    done
    [[ $found -eq 0 ]] && rev_missing="${rev_missing} ${p}"
done
if ((${#AXIS_VALS[@]} < 15)); then
    _record_fail "extracted only ${#AXIS_VALS[@]} AXIS_PREFIXES — the array parse drifted"
elif [[ -z "$rev_missing" ]]; then
    _record_pass "every gate AXIS_PREFIX is a STACK_PATHS tree (${#AXIS_VALS[@]} checked)"
else
    _record_fail "gate AXIS_PREFIXES absent from wave-status STACK_PATHS:${rev_missing} — owned by the gate but staling no reviewer"
fi

summarise
