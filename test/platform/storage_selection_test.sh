#!/usr/bin/env bash
# test/platform/storage_selection_test.sh
#
# `scripts/check-storage-selection-is-deliberate.sh`: which object-storage
# backend an environment uses must be a declaration, never a side effect of
# whether a credential happens to be lying around.
#
# ⚠️ The defect this gate ends was MEASURED, not imagined. `config/runtime.exs`
# read `if r2_account_id = System.get_env("R2_ACCOUNT_ID")` for seven months:
#
#   - every developer machine with credentials in `.env` therefore selected R2
#     and read, wrote and DELETED objects in the shared bucket. Of 25 keys
#     sampled from it, 13 had rows in the PRODUCTION database.
#   - a deployed stack WITHOUT those secrets silently fell back to
#     Stacks.Storage.Local, writing reader photos to a container filesystem
#     with no volume behind it, on a machine that stops when idle. The preview
#     stack was in exactly that state, and no gate reported it.
#
# ⚖️ Local is NOT banned, and that restraint is the point. The Stacks is
# self-hosted; an operator on one machine with a real disk needs no object
# storage, and banning Local would generalise one deployment's accident into a
# rule that makes the platform worse for the people running it themselves. What
# the gate refuses is choosing it by ACCIDENT.
#
# ⛔ Every assertion below plants a real violation, because a gate attested
# clean against a tree that never violated it proves nothing. Assertion 6 is
# here twice over: its first version grepped for `"local"` anywhere and PASSED
# a planted violation, matching the refusal message that advises setting
# STORAGE_BACKEND=local rather than the value actually accepted.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-storage-selection-is-deliberate.sh"
RUNTIME="$REPO_ROOT/config/runtime.exs"
SELECTION="$REPO_ROOT/apps/core/lib/stacks/storage/selection.ex"
SELECTION_TEST="$REPO_ROOT/apps/core/test/stacks/storage/selection_test.exs"

test_case "inputs_exist" "the gate and the files it reads are present and parse"
assert_path_exists "$GATE" "the gate exists"
assert_path_exists "$SELECTION" "the selection module exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "the gate parses under $(bash --version | head -1)"
else
    _record_fail "the gate does NOT parse, so it has never run here"
fi

test_case "it_passes_against_the_real_tree" "the tree satisfies the gate today"
OUT="$(cd "$REPO_ROOT" && bash scripts/check-storage-selection-is-deliberate.sh 2>&1)"
assert_exit_zero $? "the gate passes on the real tree"
assert_contains "$OUT" "storage selection is deliberate" "and says so"

# ---------------------------------------------------------------------------
# Planted violations. Each restores from a snapshot taken inside this test, so
# a failure part-way cannot leave the tree modified.
# ---------------------------------------------------------------------------
SNAP="$(mktemp -d)"
cp "$RUNTIME" "$SNAP/runtime.exs"
cp "$SELECTION" "$SNAP/selection.ex"
cp "$SELECTION_TEST" "$SNAP/selection_test.exs"

restore_all() {
    cp "$SNAP/runtime.exs" "$RUNTIME"
    cp "$SNAP/selection.ex" "$SELECTION"
    cp "$SNAP/selection_test.exs" "$SELECTION_TEST"
}
# ⛔ Restore on ANY exit, including a failed assertion or an interrupt: a
# planted violation left behind would look exactly like a real defect to the
# next reader, and worse, to the next gate run.
trap 'restore_all; rm -rf "$SNAP"' EXIT

plant() {
    # plant <file> <needle> <replacement> — refuses silently-missed anchors.
    python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
path, needle, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
s = p.read_text()
if s.count(needle) != 1:
    sys.exit(f"anchor appears {s.count(needle)} times, expected 1: {needle[:60]}")
p.write_text(s.replace(needle, replacement))
PY
}

probe() {
    # probe <label> — runs the gate, expects a refusal naming the right thing.
    local label="$1" expected="$2" out rc
    out="$(cd "$REPO_ROOT" && bash scripts/check-storage-selection-is-deliberate.sh 2>&1)"
    rc=$?
    test_case "$label" "a planted violation is refused"
    assert_exit_nonzero $rc "the gate refuses it"
    assert_contains "$out" "$expected" "and the refusal names what is wrong"
    restore_all
}

plant "$RUNTIME" "Selection.choose" "Selection.pick"
probe "plant_runtime_stops_delegating" "no longer calls Stacks.Storage.Selection.choose"

plant "$RUNTIME" "  case Stacks.Storage.Selection.choose" \
      "  if a = System.get_env(\"R2_ACCOUNT_ID\") do
    config :core, :storage, Stacks.Storage.R2
  end

  case Stacks.Storage.Selection.choose"
probe "plant_credential_read_as_intent" "inside a credential-presence check"

plant "$SELECTION" 'declared(env, "R2_BUCKET_NAME")}}' \
      'Map.get(env, "R2_BUCKET_NAME", "stacks-images")}}'
probe "plant_default_bucket" "default bucket name is being supplied"

plant "$SELECTION" "|> String.trim()" ""
probe "plant_blank_counts_as_present" "no longer treats a blank value as absent"

plant "$SELECTION_TEST" "requires UPLOAD_DIR" "requires a durable path"
probe "plant_untested_refusal" "no test asserts the refusal"

plant "$SELECTION" '      "local" -> local(env, deployed?)' \
      '      "filesystem" -> local(env, deployed?)'
probe "plant_local_no_longer_permitted" "no longer accepts STORAGE_BACKEND=local as a case clause"

test_case "tree_is_restored" "no planted violation survives this test"
OUT="$(cd "$REPO_ROOT" && bash scripts/check-storage-selection-is-deliberate.sh 2>&1)"
assert_exit_zero $? "the gate passes again, so every plant was reverted"

test_case "the_gate_is_wired_into_the_lane_that_runs_the_gates" "it is not an orphan"
# A gate nothing invokes is the defect class this project keeps finding.
LANE="$(cat "$REPO_ROOT/scripts/lint-elixir.sh" 2>/dev/null)"
assert_contains "$LANE" "gate check-storage-selection-is-deliberate.sh" \
    "scripts/lint-elixir.sh invokes it"

summarise
