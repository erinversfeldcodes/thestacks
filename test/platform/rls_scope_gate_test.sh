#!/usr/bin/env bash
# test/platform/rls_scope_gate_test.sh
#
# `scripts/check-rls-scope.sh` — the gate that is supposed to catch a module
# querying a row-level-secured table without establishing a scope.
#
# ⛔ WHY THIS SUITE EXISTS. The gate's allowlist used to hold eight free-text
# reasons, SEVEN of which were factually false, and every one was a real refused
# query on a deployed stack. They were replaced with a machine-checked KIND per
# entry — and then the allowlist was correctly emptied, which left the verifier
# with **zero coverage**: `verify_kind`, `DIRECT_QUERY_FORMS` and `DEFINERS`
# were never executed by any run, and the per-kind anti-vacuity check compared
# 0 resolved against 0 declared and passed.
#
# ⚠️ The guard was written for "the pattern behind a kind stopped matching". The
# vacuity arrived instead by EMPTYING THE INPUT, which it did not model. So the
# machinery that will decide the next allowlist entry had no live caller, no
# test, and a guard that could not notice.
#
# Re-adding entries to fix that would be wrong — an empty allowlist is the
# honest state. `RLS_SCOPE_TEST_ALLOWLIST` is a seam read only from the
# environment, so this suite can drive each kind and each query form against
# real modules without any committed entry hiding in the gate.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-rls-scope.sh"
cd "$REPO_ROOT" || exit 1

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-rls-scope.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below is exercising the real thing"
fi

# ⚠️ `DRIVES` counts the allowlist entries this suite actually pushed through
# the verifier, and is asserted against a floor at the end. Without it, deleting
# two of the `run_gate` calls below leaves the suite reporting N-minus-2 passes
# and still green — the gate under test has an anti-vacuity floor, and until now
# the suite testing it did not. A suite that shrinks silently is the same defect
# class as the gate whose allowlist emptied silently.
DRIVES=0

run_gate() {
    OUT="$(RLS_SCOPE_TEST_ALLOWLIST="${1:-}" bash "$GATE" 2>&1)"
    RC=$?
    [[ -n "${1:-}" ]] && DRIVES=$((DRIVES + 1))
    return 0
}

test_case "the_clean_tree_passes" "a baseline, so a red below means something"
run_gate ""
if [[ $RC -eq 0 ]]; then
    _record_pass "the gate is green on the committed tree"
else
    _record_fail "the gate is already red, so every case below is uninterpretable: ${OUT}"
fi

# ── the three kinds, each driven against a module that contradicts it ────────
#
# ⚠️ Each case asserts the verifier REFUSES a false claim. That is the half that
# matters: a kind that cannot refuse is the prose allowlist again, wearing a
# machine-checked costume.

test_case "no_queries_is_checked" "a module that makes Repo calls cannot claim it"
run_gate "shelving.ex=no-queries"
assert_exit_nonzero "$RC" "the false claim is refused"
assert_contains "$OUT" "claims no-queries but makes a Repo call" \
    "and the message names what was actually found"

test_case "definer_is_checked" "a module that calls no definer function cannot claim one"
# `insights.ex` scopes its reads and calls no `op.*` definer at all, so a
# `definer` claim over it must fail on the FIRST half — "calls no definer" —
# rather than on the direct-query half tested below.
run_gate "insights.ex=definer"
assert_exit_nonzero "$RC" "the false claim is refused"
assert_contains "$OUT" "calls no op" "and says which half failed"

test_case "definer_also_refuses_a_direct_query" \
    "calling a definer does not license querying the table directly as well"
# `social/social.ex` does both: it asks `op.blocked_pair` AND queries the
# secured schemas directly. A `definer` claim over it must fail on the second
# half, which is the one the three query forms exist to catch.
run_gate "social/social.ex=definer"
assert_exit_nonzero "$RC" "the claim is refused"
assert_contains "$OUT" "also queries a secured schema directly" \
    "and names the direct query rather than only the missing definer"

test_case "policy_kind_is_proved_against_the_migrations" \
    "a named policy that no migration creates cannot license anything"
run_gate "shelving.ex=policy:a_policy_that_does_not_exist"
assert_exit_nonzero "$RC" "an unbacked policy name is refused"
assert_contains "$OUT" "which no migration creates" "and says the policy is absent"

test_case "an_unknown_kind_is_refused" "the kind vocabulary is closed"
run_gate "shelving.ex=totally-made-up"
assert_exit_nonzero "$RC" "an unrecognised kind is refused"

test_case "a_declared_entry_that_never_resolves_is_refused" \
    "⛔ the anti-vacuity case the original guard could not see"
# An entry for a module the discovery predicate never reaches excludes nothing
# and tells a reader something untrue. This is how the one TRUE entry in the old
# allowlist (`events/registry.ex`, which makes no Repo call) was found to be
# dead on the check's first run.
run_gate "events/registry.ex=no-queries"
assert_exit_nonzero "$RC" "an entry that resolves against no discovered module is refused"
assert_contains "$OUT" "resolved" "and reports declared-versus-resolved"

# ── the comment-stripping guarantee, and the SIGPIPE bug it introduced ───────

test_case "the_pass_fail_grep_strips_comments" \
    "a scope call named only in prose must not satisfy the gate"
# ⚠️ Five recorded cases in this repository of an absence assertion satisfied by
# the comment explaining the pattern it bans. The pass/fail grep here was the
# last one in this file reading its own prose as evidence.
assert_contains "$(cat "$GATE")" "code_only=" \
    "the module check strips comments into a variable before matching"

test_case "⛔_the_strip_does_not_use_a_pipe_into_grep_q" \
    "pipefail plus grep -q is a size-dependent false failure"
# ⛔ MEASURED. `sed … | grep -qE …` under `set -o pipefail` reports 141: grep
# exits on its first match, closes the pipe, sed takes SIGPIPE, and the
# PIPELINE's status is the failure. It bit `shelving.ex` alone — the largest
# file, where the match comes early and sed still has ~1300 lines to write —
# while every smaller file finished writing first and passed. A gate that fails
# on file size is worse than one that fails consistently.
# ⛔ Asserted over the WHOLE gate, not just the strip sites. The flake that
# found this was in `verify_kind`, which used `printf '%s' "$code" | grep -qE`
# — grep exits on its first match, printf takes SIGPIPE, the pipeline returns
# 141, the `if` goes FALSE, and a false allowlist claim is ACCEPTED. Measured
# at 2 failures in 6 runs before the fix and 0 in 12 after, because whether
# printf finishes writing before grep exits depends on the file's size.
#
# ⚠️ A gate that accepts a false claim intermittently is worse than one that
# fails: the green runs are the dangerous ones.
# ⚠️ The pattern is deliberately wider than the form that caused the flake.
# `-q` leading was an accident of how that line happened to be written: the
# hazard is a property of ANY early-exiting consumer, so `grep -Eq`, `grep -iq`
# and `grep -Fq` are the same defect and all read as equally idiomatic. It also
# covers the non-grep consumers — `grep -m1`, `head`, `sed …q`, `awk …exit` —
# because the next instance will not be a grep just because this one was.
EARLY_EXIT_CONSUMER='\| *(grep [^|]*-[a-zA-Z]*q|grep [^|]*-m *[0-9]|head( |$)|sed -n [^|]*q|awk [^|]*exit)'
PIPE_INTO_GREPQ="$(grep -cE "$EARLY_EXIT_CONSUMER" "$GATE" || true)"
PIPE_IN_PROSE="$(sed 's/#.*//' "$GATE" | grep -cE "$EARLY_EXIT_CONSUMER" || true)"
if [[ "${PIPE_IN_PROSE:-0}" -eq 0 ]]; then
    _record_pass "no executable pipe into an early-exiting consumer anywhere in the gate (${PIPE_INTO_GREPQ} mention(s), all in comments)"
else
    _record_fail "${PIPE_IN_PROSE} executable pipe(s) into an early-exiting consumer remain; under pipefail each returns 141 on an early match, which ACCEPTS a false claim"
fi

test_case "the_widened_pattern_still_catches_the_original_form" \
    "an absence assertion is only as good as its pattern"
# ⛔ Anti-vacuity for the assertion above. Widening a pattern can silently
# break it, and an absence check that matches nothing reports clean — so prove
# the pattern still fires on the exact line that caused the flake, and on the
# flag-reordered spelling that the previous narrower pattern would have missed.
_variants_caught=0
for _variant in \
    'printf "%s" "$code" | grep -qE "$PAT"' \
    'printf "%s" "$code" | grep -Eq "$PAT"' \
    'echo "$out" | grep -iq EXPLOIT' \
    'cat "$f" | head -5' \
    'git ls-tree -r main | grep -m1 proto'
do
    if grep -qE "$EARLY_EXIT_CONSUMER" <<< "$_variant"; then
        _variants_caught=$((_variants_caught + 1))
    else
        _record_fail "the widened pattern does NOT catch: ${_variant}"
    fi
done
if [[ "${_variants_caught}" -eq 5 ]]; then
    _record_pass "the pattern catches all 5 spellings, including the flag-reordered 'grep -Eq' the narrow version missed"
fi

test_case "the_anti_vacuity_floor_on_discovery_is_present" \
    "a discovery pattern that stops matching must not read as clean"
assert_contains "$(cat "$GATE")" "too few to be this codebase" \
    "the module floor is declared"

test_case "this_suite_drove_every_kind_it_claims_to" \
    "the suite needs the same anti-vacuity floor as the gate it tests"
# ⛔ The floor is the count of allowlist entries actually pushed through the
# verifier: three kinds (no-queries, definer, policy:NAME), plus the unknown
# kind, plus the second definer module, plus the no-queries contradiction = 6.
# Raise it when a case is added; a DROP means somebody deleted coverage, and
# this is the assertion that makes that a failing run rather than a quieter one.
# ── check 3: a test must not supply the scope its subject establishes ───────
#
# ⛔ The defect class this closes reads as correct at every line, which is why
# it needed a gate rather than review. MEASURED three times in one session: a
# case named for a production function establishing its own scope wrapped that
# function in an outer `Scope.with_user`, so the TEST supplied the precondition
# and the case stayed green with the subject's scoping removed entirely — 7 of 7
# against the planted historical defect.
#
# ⚠️ BUILT ON A MEASURED BASE RATE, because three narrower proposals in this
# area were refuted by measurement first: 22 `Scope.with_user` sites across
# `apps/core/test`, of which ZERO enclose a call whose own body establishes a
# scope. Zero legitimate instances is what makes a gate the right shape here.
NEST_FIXTURES="$(mktemp -d)"
trap 'rm -rf "$NEST_FIXTURES"' EXIT

# The forbidden shape, which is the historical defect reduced.
mkdir -p "$NEST_FIXTURES/bad"
cat > "$NEST_FIXTURES/bad/nested_scope_test.exs" <<'BADFIXTURE'
defmodule Probe do
  test "a scoped Shelving READ runs entirely within the scope" do
    owner = insert(:user)

    result =
      Scope.with_user(owner.id, fn ->
        AppRole.as_app_role(fn ->
          Stacks.Shelving.get_bookshelf_shelves(owner.id, "library")
        end)
      end)

    refute match?({:error, _}, result)
  end
end
BADFIXTURE

# ⛔ AND THE PERMITTED SHAPE, which is the half that decides whether this gate
# is usable. A test that wraps a RAW QUERY in a scope is correct — the four RLS
# isolation pairs do exactly that, because there the scope is the precondition
# and the POLICY is the subject. A gate that flagged both would have to be
# turned off.
mkdir -p "$NEST_FIXTURES/good"
cat > "$NEST_FIXTURES/good/scoped_query_test.exs" <<'GOODFIXTURE'
defmodule Probe do
  test "op.bookshelves: the owner sees their own row and NOT another user's" do
    owner = insert(:user)

    count =
      Scope.with_user(owner.id, fn ->
        AppRole.as_app_role(fn ->
          %{rows: [[n]]} = SQL.query!(Repo, "SELECT count(*) FROM op.bookshelves", [])
          n
        end)
      end)

    assert count >= 1
  end
end
GOODFIXTURE

test_case "a_test_that_supplies_its_subject_s_scope_is_refused" \
    "the planted red — the historical defect reduced to its shape"
OUT="$(RLS_SCOPE_EXTRA_TEST_DIR="$NEST_FIXTURES/bad" bash "$GATE" 2>&1)"
RC=$?
assert_exit_nonzero "$RC" "the forbidden shape is refused"
assert_contains "$OUT" "supply a scope their subject must establish" "the refusal names the condition"
assert_contains "$OUT" "wraps get_bookshelf_shelves" \
    "and names the enclosed function, so the fix is at a line rather than in a file"
assert_contains "$OUT" "Drop the wrapper" "and says what to do"

# ⛔ AND THE SCOPE PRIMITIVES ARE EXEMPT BY DESIGN, not by accident. A test
# whose subject is `Stacks.Scope` must nest a scope inside a scope, and
# `scope_test.exs` has four such cases. MEASURED: they already escaped, but only
# because `with_user`'s body calls internal helpers rather than
# `Scope.with_user`, so the pattern never matched it — while `Scope.set!` DOES
# match and is defined in the same file. The exemption therefore rested on which
# primitive each test happened to call, and one refactor of `with_user` would
# have redded all four. This fixture is that refactor's shape, today.
mkdir -p "$NEST_FIXTURES/primitive"
cat > "$NEST_FIXTURES/primitive/nesting_semantics_test.exs" <<'PRIMITIVEFIXTURE'
defmodule Probe do
  test "the same user nested is a pass-through, not a second transaction" do
    owner = insert(:user)

    Scope.with_user(owner.id, fn ->
      Scope.set!(owner.id)
      assert Scope.current() == owner.id
    end)
  end
end
PRIMITIVEFIXTURE

test_case "a_test_whose_subject_is_Scope_itself_may_nest" \
    "forbidding this would forbid testing the thing — and the exemption was accidental until now"
OUT="$(RLS_SCOPE_EXTRA_TEST_DIR="$NEST_FIXTURES/primitive" bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" \
    "nesting a scope primitive inside a scope is how Scope's own nesting semantics are tested"
assert_contains "$OUT" "no test wraps a scope-establishing call" "and it reports clean rather than silently"

# ⛔ A COMMENT NAMING AN ESTABLISHER IS NOT A CALL TO ONE — in EITHER half of
# this check, and the live instance was in the half nobody was looking at.
#
# MEASURED: `Social.blocked?/2` deliberately does NOT establish a scope (a
# reviewed decision — wrapping it took the public blog listing from a bounded 13
# queries to 43), and the comment recording that decision names
# `Stacks.Scope.with_user/2`. So the gate classified `blocked?` as an
# establisher **because of the comment saying it deliberately is not one**, and
# any test calling it inside a scope was a false positive. Stripping drops the
# establisher set from 52 to 50.
mkdir -p "$NEST_FIXTURES/prose"
cat > "$NEST_FIXTURES/prose/prose_only_test.exs" <<'PROSEFIXTURE'
defmodule Probe do
  test "a blocked viewer sees nothing" do
    viewer = insert(:user)

    visible =
      Scope.with_user(viewer.id, fn ->
        # Deliberately unscoped itself — see Stacks.Scope.with_user/2 for why,
        # and note that get_bookshelf_shelves(owner, "library") is NOT called
        # here; this line exists to be read, not run.
        Social.blocked?(viewer.id, other_id)
      end)

    assert visible == false
  end
end
PROSEFIXTURE

test_case "an_establisher_named_only_in_a_comment_does_not_flag" \
    "a gate reading its own subject matter as configuration — this repo's most-recorded failure"
OUT="$(RLS_SCOPE_EXTRA_TEST_DIR="$NEST_FIXTURES/prose" bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" \
    "neither the commented call syntax nor blocked? (an establisher only by its own comment) may flag"
assert_contains "$OUT" "50 such functions known" \
    "and the establisher set is the STRIPPED one — 52 included two functions matched only in prose"

# ⛔ THE WINDOW IS BOUNDED AT THE ENCLOSING BLOCK, not a flat 14 lines. A fixed
# window reads past the closing `end` into the NEXT test, and `scope_test.exs`
# has three-line tests — so 14 lines reaches well into the following one. The
# bleed was invisible only because the one function it could have picked up was
# not yet in the establisher set: one accident suppressing two defects.
mkdir -p "$NEST_FIXTURES/bleed"
cat > "$NEST_FIXTURES/bleed/cross_block_test.exs" <<'BLEEDFIXTURE'
defmodule Probe do
  test "a scope wrapper with nothing of interest inside it" do
    owner = insert(:user)

    Scope.with_user(owner.id, fn ->
      assert Scope.current() == owner.id
    end)
  end

  test "a separate test that legitimately calls a self-scoping context" do
    owner = insert(:user)
    assert {:ok, _} = Stacks.Shelving.get_bookshelf_shelves(owner.id, "library")
  end
end
BLEEDFIXTURE

test_case "a_call_in_the_NEXT_test_is_not_read_as_enclosed" \
    "a window with no block bound reaches into code the wrapper does not enclose"
OUT="$(RLS_SCOPE_EXTRA_TEST_DIR="$NEST_FIXTURES/bleed" bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" \
    "the self-scoping call sits in a sibling test, outside the wrapper — it must not be attributed to it"
assert_contains "$OUT" "wrapper site(s) scanned" \
    "and the site count proves the wrapper WAS seen, so this is a bound rather than a miss"

test_case "a_test_that_wraps_a_raw_query_is_permitted" \
    "the discriminator — is the scope the thing under test, or the precondition for it?"
OUT="$(RLS_SCOPE_EXTRA_TEST_DIR="$NEST_FIXTURES/good" bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" \
    "wrapping SQL.query! in a scope is CORRECT — the isolation pairs do it, and flagging it would retire this gate"
assert_contains "$OUT" "no test wraps a scope-establishing call" "and it is reported as clean rather than silently"

# ⚠️ The override is ADDITIVE, asserted rather than assumed. If it replaced the
# scan root it could be pointed at an empty directory and report a clean corpus
# of nothing — the vacuity the gate's own floor exists to refuse, reachable
# through the seam added to test it.
test_case "the_test_seam_cannot_narrow_the_corpus" \
    "a seam that can empty the population is a bypass, not a fixture"
EMPTY_DIR="$(mktemp -d)"
OUT="$(RLS_SCOPE_EXTRA_TEST_DIR="$EMPTY_DIR" bash "$GATE" 2>&1)"
RC=$?
rmdir "$EMPTY_DIR"
assert_exit_zero "$RC" "an empty extra directory adds nothing and the real corpus is still scanned"
assert_contains "$OUT" "such functions known" \
    "the establisher count is still reported, so the real corpus was read rather than replaced"

# ⚠️ And the gate's own anti-vacuity floor, driven. A clean result is only
# meaningful while the establisher set is populated; an empty one would make
# every test read as innocent.
test_case "the_gate_refuses_a_thin_establisher_set" \
    "no establishers means every test looks innocent, which is not the same as clean"
OUT="$(RLS_SCOPE_MIN_ESTABLISHERS=100000 bash "$GATE" 2>&1)"
RC=$?
assert_exit_nonzero "$RC" "a floor the corpus cannot meet is a refusal"
assert_contains "$OUT" "scope-establishing function(s); expected at least" \
    "the refusal quotes both the found count and the floor"
assert_contains "$OUT" "nothing was read rather than nothing is wrong" \
    "and says why a clean result under an empty set would be empty of content"

# ⚠️ The seam is RAISE-ONLY, driven rather than trusted. If it could lower the
# floor it would be a way to make the gate's own anti-vacuity check pass over a
# corpus it never read — a bypass wearing a fixture's clothes.
# ⛔ AND THE SEAM MUST NOT BE ABLE TO LOWER THE FLOOR, which needed the gate to
# PRINT the floor it used before it could be asserted at all.
#
# ⚠️ MEASURED: the first version of this case asserted only that a zero
# override still exited 0, and it was VACUOUS — removing the raise-only guard
# entirely left it green, because a corpus that clears both the declared floor
# and the lowered one behaves identically either way. No run could tell the two
# implementations apart while the only observable was the exit code.
#
# So the gate now reports the floor in use on success, and this asserts the
# VALUE rather than the outcome. Same shape as the dispatch count one file over:
# a property is only checkable once something outside the check reports it.
test_case "the_floor_seam_cannot_lower_the_floor" \
    "a seam that can weaken a guard is not a test seam"
OUT="$(RLS_SCOPE_MIN_ESTABLISHERS=0 bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" "a zero override leaves the declared floor in place and the tree still passes"
assert_contains "$OUT" "floor 20" \
    "and the floor REPORTED is the declared one, not the override — asserting the exit code alone cannot tell these apart"

EXPECTED_DRIVES=6
if [[ "${DRIVES}" -eq "${EXPECTED_DRIVES}" ]]; then
    _record_pass "drove ${DRIVES} allowlist entries through the verifier"
elif [[ "${DRIVES}" -lt "${EXPECTED_DRIVES}" ]]; then
    _record_fail "only ${DRIVES} of ${EXPECTED_DRIVES} kinds were driven — coverage was deleted, not merely reduced"
else
    _record_fail "drove ${DRIVES}, expected ${EXPECTED_DRIVES} — raise EXPECTED_DRIVES deliberately when adding a case"
fi

summarise
