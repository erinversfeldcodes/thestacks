#!/usr/bin/env bash
# test/platform/book_adapter_coverage_test.sh
#
# `scripts/check-book-adapter-coverage.sh`: a book payload key the SPA's
# hand-written adapter does not read is a field decoded and thrown away.
#
# ⛔ Three fields were lost that way — `language`, `bisac_codes` and
# `community_read_count` were serialised, decoded correctly by the generated
# proto decoder, and then dropped by `Types.Book.fromProtoBook`, which builds
# the app record field by field. No decoder fails, no error is logged, and no
# view can reference them because no record field exists to reference. Nothing
# computed the difference, so the next proto field added to `Book` would have
# gone the same way on the day it landed.
#
# Every case below is driven against a FIXTURE pair, not the repository's own
# files, so the suite neither depends on nor disturbs the real payload.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-book-adapter-coverage.sh"
GATE_SRC="$(cat "$GATE" 2>/dev/null)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Builds a fixture pair. $1 = extra atoms for the Map.take, $2 = extra `pb.x`
# reads for the adapter. The eight base keys clear the gate's anti-vacuity
# floors, so each case below is about its own rule.
build_fixture() {
    local extra_keys="$1" extra_reads="$2" dir="$WORK/t$RANDOM$RANDOM"
    mkdir -p "$dir/apps/core/lib/stacks_web" "$dir/frontend/src/Types"

    cat > "$dir/apps/core/lib/stacks_web/proto_json.ex" <<ELIXIR
defmodule StacksWeb.ProtoJSON do
  def book(book, opts \\\\ []) do
    Gen.book(book)
    |> Map.take([
      :id,
      :title,
      :description,
      :subjects,
      :visibility_tier${extra_keys}
    ])
    |> Map.merge(%{
      author: author(book.author),
      editions: editions,
      edition_count: 1,
      primary_edition: nil
    })
    |> maybe_put_read_count(opts)
  end

  defp maybe_put_read_count(payload, opts) do
    case Keyword.fetch(opts, :community_read_count) do
      {:ok, count} -> Map.put(payload, :community_read_count, count)
      :error -> payload
    end
  end
end
ELIXIR

    cat > "$dir/frontend/src/Types/Book.elm" <<ELM
module Types.Book exposing (Book, fromProtoBook)


fromProtoBook : Proto.Book -> Book
fromProtoBook pb =
    { id = pb.id
    , title = pb.title
    , author = pb.author
    , description = pb.description
    , editions = pb.editions
    , primaryEdition = pb.primaryEdition
    , editionCount = pb.editionCount
    , subjects = pb.subjects
    , visibilityTier = pb.visibilityTier${extra_reads}
    }


somethingElse : Int
somethingElse =
    1
ELM

    printf '%s' "$dir"
}

run_gate() {
    (cd "$1" && bash "$GATE" 2>&1)
}

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-book-adapter-coverage.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

test_case "it_passes_against_the_real_tree" "the repository's own adapter is complete"
OUT_REAL="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
RC_REAL=$?
if [[ "$RC_REAL" -eq 0 ]]; then
    _record_pass "the gate passes (exit 0)"
else
    _record_fail "the gate fails against the real tree: $OUT_REAL"
fi
assert_contains "$OUT_REAL" "declared exception" \
    "the pass states the exception count, so a growing list is visible in the output"

test_case "a_dropped_key_FAILS" "the defect class, planted"
# A new proto field reaching the payload is the real risk path: it arrives via
# `Gen.book` into the `Map.take` and the adapter says nothing about it.
DIR="$(build_fixture ',
      :newly_added_field' '')"
OUT="$(run_gate "$DIR")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    _record_pass "a payload key the adapter ignores fails the gate (exit $RC)"
else
    _record_fail "a dropped key PASSED: $OUT"
fi
assert_contains "$OUT" "newly_added_field" "and the failure names it"

test_case "a_carried_key_PASSES" "anti-vacuity for the case above"
# Without this the failure above would be satisfied by a gate that rejects
# every tree it is pointed at.
DIR="$(build_fixture ',
      :newly_added_field' '
    , newlyAddedField = pb.newlyAddedField')"
OUT_OK="$(run_gate "$DIR")"
RC_OK=$?
if [[ "$RC_OK" -eq 0 ]]; then
    _record_pass "a key the adapter reads passes (exit 0)"
else
    _record_fail "a carried key was rejected, so the failure above proves nothing: $OUT_OK"
fi

test_case "camel_case_is_matched_to_snake_case" "the two sides spell fields differently"
# ⚠️ The wire is snake_case and Elm is camelCase, so the comparison has to
# normalise. A gate that compared the raw spellings would report every single
# multi-word field as dropped — permanently red, which gets a gate deleted.
assert_contains "$GATE_SRC" 'Elm field names are camelCase' \
    "the normalisation is explained where it is done"
if printf '%s\n' "$OUT_OK" | grep -q "edition_count"; then
    _record_fail "edition_count was reported dropped even though the adapter reads editionCount"
else
    _record_pass "editionCount satisfies edition_count"
fi

test_case "a_declared_exception_PASSES_and_a_stale_one_FAILS" "the exception list cannot rot"
# `community_read_count` is added by a helper after the pipe and is deliberately
# unread, owned elsewhere. The gate must accept it — and must fail when the
# declaration stops describing the code, or an exception list becomes a place
# where things go to be forgotten.
assert_contains "$GATE_SRC" "community_read_count" "the exception is declared"
assert_contains "$GATE_SRC" "DELETE this" \
    "with the instruction to remove it once the adapter reads the field"

DIR="$(build_fixture '' '
    , communityReadCount = pb.communityReadCount')"
OUT_STALE="$(run_gate "$DIR")"
RC_STALE=$?
if [[ "$RC_STALE" -ne 0 ]]; then
    _record_pass "an exception the adapter now reads fails the gate (exit $RC_STALE)"
else
    _record_fail "the adapter reads community_read_count and the stale declaration passed: $OUT_STALE"
fi
assert_contains "$OUT_STALE" "no longer describe the code" \
    "and the failure says the declaration is stale rather than the code wrong"

test_case "comments_are_not_code" "the sibling gate's own defect, planted here"
# ⛔ `check-protojson-completeness.sh` was defeated by exactly this during this
# change: a comment written to explain a field's REMOVAL spelled the field, and
# the harvest counted it as still carried — a green run for the change the gate
# exists to notice. Both gates strip comments now; this proves it for this one.
DIR="$(build_fixture '
      # Removed deliberately: :ghost_field is no longer carried.' '')"
OUT_COMMENT="$(run_gate "$DIR")"
RC_COMMENT=$?
if [[ "$RC_COMMENT" -eq 0 ]]; then
    _record_pass "an atom named only in a comment is not read as a payload key (exit 0)"
else
    _record_fail "a commented-out atom was harvested as a payload key, which is the sibling gate's defect reproduced here: $OUT_COMMENT"
fi
assert_not_contains "$OUT_COMMENT" "ghost_field" \
    "and the comment's field name appears nowhere in the verdict"

test_case "a_broken_parse_FAILS" "the anti-vacuity floors"
# ⛔ Every verdict is a set difference, empty when the code is correct AND when
# nothing was parsed. The floors are what stop a drifted regex reporting clean.
DIR="$WORK/broken"
mkdir -p "$DIR/apps/core/lib/stacks_web" "$DIR/frontend/src/Types"
printf 'defmodule StacksWeb.ProtoJSON do\nend\n' \
    > "$DIR/apps/core/lib/stacks_web/proto_json.ex"
printf 'module Types.Book exposing (Book)\n' > "$DIR/frontend/src/Types/Book.elm"

OUT_BROKEN="$(run_gate "$DIR")"
RC_BROKEN=$?
if [[ "$RC_BROKEN" -ne 0 ]]; then
    _record_pass "a tree the gate cannot parse fails rather than passing (exit $RC_BROKEN)"
else
    _record_fail "an unparseable tree reported a clean set difference: $OUT_BROKEN"
fi
assert_contains "$OUT_BROKEN" "could not locate" \
    "and the failure says the parse drifted, not that the code is wrong"

test_case "the_limit_of_the_claim_is_recorded" "carrying is not rendering"
# A record field nothing reads is the same defect one layer in, and this gate
# cannot see it. Saying so where the gate is read is what stops a green run
# being taken for "the field reaches a reader".
assert_contains "$GATE_SRC" "An adapter field is not a rendered field" \
    "the gate states what it does not check"

summarise
