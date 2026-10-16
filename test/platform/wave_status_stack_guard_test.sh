#!/usr/bin/env bash
# test/platform/wave_status_stack_guard_test.sh
#
# `just wave-status` is this project's stated authority on campaign progress —
# "ask wave-status whether a wave is done, never the human" — and it had no test
# of any kind.
#
# These cases cover its stack-review guard — which reports which stacks a
# campaign touched and demands a recorded review for each — plus the
# wave-level roll-up. The stack guard got things wrong in two ways, both of
# which made it say "nothing to review":
#
#   1. It was BLIND TO UNCOMMITTED WORK, which is exactly what an in-flight wave
#      looks like. With ten files modified and no commits beyond main it
#      reported zero actionable and demanded nothing.
#   2. For a HISTORICAL campaign it measured the wrong range entirely — asked
#      about a campaign whose wave merged two months earlier, it diffed whatever
#      branch happened to be checked out. So the missing review axis that
#      prompted this work was never going to be caught by the instrument built
#      to catch it.
#
# And the roll-up checked only whether a wave OVERCLAIMED — a wave whose every
# item was done while its own status said `in_progress` passed silently, which
# is how wave 1 of the 10-13 campaign came to read as in-flight with all six
# items complete, every DoD ticked and every review recorded.
#
# Each case builds its own throwaway git repository, because the behaviour under
# test IS the diff computation and a test that ran against this checkout would
# be asserting on today's branch.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/wave-status.sh"

test_case "inputs_exist" "the campaign status script is present"
assert_path_exists "$GATE" "scripts/wave-status.sh exists"

SANDBOX_ROOT="$(mktemp -d)"
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

# A sandbox repo with one commit on `main`, a feature branch at the same commit,
# and a campaign state whose single item is COMPLETE — which is what switches
# the campaign-level stack guard on. `informal` keeps the item from needing a
# backing issue file, so the only thing under test is the stack guard.
new_sandbox() {
    local name="$1" reviews="$2" extra="${3:-}"
    local dir="$SANDBOX_ROOT/$name"

    mkdir -p "$dir/plans" "$dir/apps/core/lib" "$dir/proto"
    cp "$GATE" "$dir/wave-status.sh"

    git -C "$dir" init -q
    git -C "$dir" config user.email "platform-test@thestacks.invalid"
    git -C "$dir" config user.name "platform test"
    echo "seed" > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "seed"
    git -C "$dir" branch -q -M main
    git -C "$dir" checkout -qb feature

    cat > "$dir/plans/probe-campaign-state.json" <<EOF
{
  "campaign": "probe-campaign",
  "plan": "plans/probe-campaign.md",
  "status": "in_progress",
  "current_wave": 1,
  "waves": {
    "1": {
      "title": "Probe",
      "status": "in_progress",
      "items": {
        "W1a": {
          "status": "complete",
          "informal": true,
          "note": "a completed item, which is what turns the stack guard on",
          "title": "probe item"
        }
      }
    }
  },
  "domain_reviews": ${reviews}${extra}
}
EOF
    printf '%s' "$dir"
}

run_gate() {
    OUT="$(cd "$1" && bash wave-status.sh probe-campaign 2>&1)"
    RC=$?
}

# ── 1. uncommitted work is in scope ──────────────────────────────────────────
DIR="$(new_sandbox uncommitted '{}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"

test_case "uncommitted_work_is_seen" "an in-flight wave's uncommitted changes count as touched"
run_gate "$DIR"
assert_exit_nonzero "$RC" "the guard fails when a touched stack has no recorded review"
assert_contains "$OUT" "touches elixir" \
    "an uncommitted apps/core/lib change puts elixir in scope — with 0 commits beyond main this previously reported nothing to review"

# ── 2. a recorded review satisfies the demand ────────────────────────────────
DIR="$(new_sandbox reviewed '{"elixir": "LGTM 2026-10-16"}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"

test_case "a_recorded_review_satisfies" "the demand is for a MISSING review, not for every stack"
run_gate "$DIR"
assert_not_contains "$OUT" "touches elixir" \
    "elixir is touched and reviewed, so it must not be demanded again"

# ── 3. a declared diff_range wins over the working tree ──────────────────────
#
# The historical-campaign case. The working tree touches elixir; the declared
# range touches only proto. The guard must answer about the RANGE.
DIR="$(new_sandbox declared_range '{}' ',
  "diff_range": "RANGE_PLACEHOLDER"')"
echo 'syntax = "proto3";' > "$DIR/proto/probe.proto"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "a proto-only commit"
RANGE="$(git -C "$DIR" rev-parse HEAD~1)..$(git -C "$DIR" rev-parse HEAD)"
python3 - "$DIR/plans/probe-campaign-state.json" "$RANGE" <<'PY'
import sys
path, rng = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("RANGE_PLACEHOLDER", rng))
PY
# Working-tree change in a DIFFERENT stack, which the declared range excludes.
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"

test_case "declared_range_wins" "a campaign that declares its range is measured on that range"
run_gate "$DIR"
assert_contains "$OUT" "touches contract" \
    "the declared range is a proto-only commit, so contract is in scope"
assert_not_contains "$OUT" "touches elixir" \
    "the working tree touches elixir but the declared range does not — a historical campaign must not be measured against today's checkout"

# ── 4. an unreadable declared range is UNKNOWN, never a fallback ─────────────
DIR="$(new_sandbox bad_range '{}' ',
  "diff_range": "deadbeefdeadbeef..cafebabecafebabe"')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"

test_case "unreadable_range_is_unknown" "a declared range git cannot read does not fall back"
run_gate "$DIR"
assert_exit_nonzero "$RC" "an unanswerable check is not a satisfied one"
assert_contains "$OUT" "UNKNOWN" "coverage is reported as UNKNOWN"
assert_contains "$OUT" "diff_range" "the message names the declared range as the problem"
assert_not_contains "$OUT" "touches elixir" \
    "it must NOT silently fall back to the branch diff — that fallback is how the wrong range came to be measured"

# ── 5. a wave understating itself is reported, not only one overstating ─────
#
# The roll-up checked only whether a wave claimed MORE than its items support.
# Wave 1 of the 10-13 campaign sat at `in_progress` with six of six items
# complete, every DoD ticked and every review recorded — and the roll-up called
# it in-flight, which is what a fresh pass reads and believes.
DIR="$(new_sandbox stale_wave '{"elixir": "LGTM"}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"

test_case "a_wave_with_all_items_done_is_not_left_in_progress" "an understated wave is reported"
run_gate "$DIR"
assert_contains "$OUT" "ALL 1 of its items are done" \
    "the sandbox wave is in_progress with its only item complete, which the roll-up must report"

# And the mirror must not fire on a wave that genuinely has work left.
python3 - "$DIR/plans/probe-campaign-state.json" <<'PY2'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
items = state["waves"]["1"]["items"]
items["W1b"] = {"status": "not_started", "informal": True, "note": "still to do", "title": "second"}
json.dump(state, open(path, "w"), indent=2)
PY2

test_case "a_wave_with_work_left_is_not_reported" "the mirror check does not fire on a real in-flight wave"
run_gate "$DIR"
# ⚠️ Presence anchor first. A bare absence assertion is satisfied by a gate that
# produced NOTHING — a crash, a missing state file, a changed slug — and would
# then report the opposite of what it claims. This project has the rule written
# down because a wait-for-absence once passed that way.
assert_contains "$OUT" "Wave 1" "the gate ran and rendered the wave"
assert_not_contains "$OUT" "of its items are done" \
    "one item is not_started, so this wave is legitimately in_progress"

summarise
