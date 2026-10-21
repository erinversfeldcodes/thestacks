#!/usr/bin/env bash
# test/platform/never_serialized_test.sh
#
# scripts/check-never-serialized.sh refuses a credential in any JSON
# serializer, generated or hand-written.
#
# ⛔ WHY IT EXISTS. An Argon2 password hash and four single-use auth tokens are
# kept out of the generated serializer by one list in `proto/persisted.exs` —
# the `User` entry's `skip_fields`. Deleting one line from that list and
# regenerating is a perfectly self-consistent change, and MEASURED, with
# `:password_hash` removed:
#
#   check-api-only-is-skipped.sh        green  (correct — it has a column)
#   mix proto.sync --check              green  (the tree IS regenerated)
#   check-protojson-completeness.sh     RED, and the message said
#       "user drops password_hash … Either carry the field in the serializer,
#        or add the pair to BASELINE"
#
# The one gate that fired gave advice that would have either serialized the hash
# or pinned it as an accepted omission. That remediation text has since been
# corrected to list the never-serialize disposition first, and this gate is what
# actually enforces it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-never-serialized.sh"
GATE_SRC="$(cat "$GATE" 2>/dev/null)"

run_gate() {
    OUT=$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)
    RC=$?
}

# --- the real tree is clean ------------------------------------------------

test_case "the_real_tree_is_clean" "no serializer carries a credential today"
run_gate
assert_exit_zero "$RC" "the gate passes over the repository as it stands"
assert_contains "$OUT" "credential field(s) absent from" "and says what it compared"
assert_contains "$OUT" "deliberately out of scope" "and reports the fields it does NOT enforce"

# --- the list lives in the gate, not in the manifest it protects -----------

# ⛔ The single most important property. If the list were read from
# `proto/persisted.exs`, deleting the entry would delete the assertion, and the
# gate would go green on exactly the change it exists to refuse.
test_case "the_expectation_is_not_read_from_the_thing_it_guards" "a guard cannot source its expectations from its subject"
assert_contains "$GATE_SRC" "NEVER_SERIALIZE = [" "the list is declared in the gate"
assert_contains "$GATE_SRC" "password_hash" "and names the hash explicitly"
assert_not_contains "$GATE_SRC" "persisted.exs\", encoding" "the gate does not read the manifest for its expectations"

# --- a credential emitted by the generated serializer is refused -----------

# ⚠️ Planted in the GENERATED file rather than by editing the manifest and
# regenerating. Both reach the same state, but editing `persisted.exs` would
# need a `mix compile --force` to take effect (`mix proto.sync` declares
# `@requirements []` and runs against whatever is in `_build`), and a probe that
# silently does not apply is how a broken predicate once produced a
# byte-identical tree and read as "nothing changed".
GEN="$REPO_ROOT/apps/core/lib/stacks/gen/proto_json.ex"
GEN_BACKUP="$(mktemp)"
cp "$GEN" "$GEN_BACKUP"
restore_gen() { cp "$GEN_BACKUP" "$GEN"; rm -f "$GEN_BACKUP"; }
trap restore_gen EXIT

python3 - "$GEN" <<'PLANT'
import re
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = "      id: struct.id,\n"
assert src.count(needle) >= 1, "could not find an anchor to plant after"
src = src.replace(needle, needle + "      password_hash: struct.password_hash,\n", 1)
open(path, "w", encoding="utf-8").write(src)
PLANT

test_case "a_credential_in_the_generated_file_is_refused" "the emission is caught, not the manifest entry"
run_gate
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "password_hash\` is EMITTED" "it says the generated side emits it"
assert_contains "$OUT" "no baseline to add the pair to" "and offers no escape, unlike the completeness gate"

restore_gen
cp "$GEN" "$GEN_BACKUP" 2>/dev/null || GEN_BACKUP="$(mktemp)" && cp "$GEN" "$GEN_BACKUP"

test_case "the_restore_is_clean" "the planted emission is gone again"
run_gate
assert_exit_zero "$RC" "the gate passes once the plant is removed"

# --- a credential named in a hand-written take-list is refused -------------

HAND="$REPO_ROOT/apps/core/lib/stacks_web/proto_json.ex"
HAND_BACKUP="$(mktemp)"
cp "$HAND" "$HAND_BACKUP"
restore_both() {
    cp "$GEN_BACKUP" "$GEN" 2>/dev/null || true
    cp "$HAND_BACKUP" "$HAND" 2>/dev/null || true
    rm -f "$GEN_BACKUP" "$HAND_BACKUP"
}
trap restore_both EXIT

python3 - "$HAND" <<'PLANT'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = "  @listing_seller_fields [:id, :display_name]"
assert src.count(needle) == 1, "anchor moved — this case would pass for the wrong reason"
src = src.replace(needle, "  @listing_seller_fields [:id, :display_name, :password_reset_token]", 1)
open(path, "w", encoding="utf-8").write(src)
PLANT

test_case "a_credential_in_a_hand_written_take_list_is_refused" "the second half of the check"
run_gate
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "named in a hand-written serializer" "it says where"
assert_contains "$OUT" "password_reset_token" "and which token"

restore_both

test_case "both_restores_are_clean" "the suite leaves the tree as it found it"
run_gate
assert_exit_zero "$RC" "the gate passes again"

# --- a credential named only in a COMMENT is not a violation ---------------

# ⛔ Both files under inspection discuss these names in prose. A gate that read
# its own subject's documentation as a violation could never ship, and this
# repository has five recorded instances of exactly that.
test_case "comment_stripping_is_present" "prose naming a credential is not an emission"
assert_contains "$GATE_SRC" "def strip_comments" "comments are stripped before matching"
assert_contains "$GATE_SRC" "interpolation" "and `#{` is preserved rather than eaten"

# --- an unparsed input is a refusal, not a pass ----------------------------

# ⛔ Every check here is an ABSENCE, and an absence is also what an unparsed file
# produces. Both populations are floored for that reason.
test_case "both_populations_are_floored" "an absence check over nothing is refused"
assert_contains "$GATE_SRC" "parsed only" "an undersized parse refuses"
assert_contains "$GATE_SRC" "passes trivially" "and says why that is not a pass"
assert_contains "$GATE_SRC" "NEVER_SERIALIZE list is empty" "an empty expectation list also refuses"

summarise
