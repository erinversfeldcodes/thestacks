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
# is how a finished wave came to read as in-flight with every one of its items
# complete, every DoD ticked and every review recorded. Understating is the
# more expensive direction: a fresh pass reads `in_progress` and goes looking
# for work that does not exist.
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
  "current_wave": "probe",
  "waves": {
    "probe": {
      "title": "Probe",
      "status": "in_progress",
      "items": {
        "alpha": {
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

# ── 2b–2d. a RECORDED review is not necessarily a CURRENT one ────────────────
#
# ⛔ The guard originally tested only for the PRESENCE of a stack's key, which
# reproduced inside itself the failure it exists to prevent. Measured on the
# real campaign: all five core stacks carried a verdict dated 2026-10-14 whose
# recorded `range` was the literal text "<sha>..HEAD" — and `HEAD` is a moving
# target stored as a string, so the row kept READING as current while 166
# further commits touching 178 files in those stacks landed behind it. The axis
# was reported as covered for a week of unreviewed work, and the row's own text
# is what made it invisible.
#
# ⚠️ Case 2c is the anti-vacuity half and is not optional: a staleness check
# that fired on everything would pass 2b and 2d while making the guard useless,
# and "always red" is as uninformative as "always green".

test_case "a_review_with_no_sha_is_UNKNOWN" "a range ending in HEAD is not evidence of currency"
assert_contains "$OUT" "records no \`reviewed_at_sha\`" \
    "the string-only verdict above is reported as UNKNOWN rather than silently accepted"
assert_exit_nonzero "$RC" "and UNKNOWN is a violation — an unanswerable check is not a satisfied one"

DIR="$(new_sandbox sha_current '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "SHA_PLACEHOLDER"}}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "an elixir commit"
CURRENT_SHA="$(git -C "$DIR" rev-parse HEAD)"
python3 - "$DIR/plans/probe-campaign-state.json" "$CURRENT_SHA" <<'PY'
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("SHA_PLACEHOLDER", sha))
PY

test_case "a_review_at_the_current_sha_satisfies" "the green half — this must not fire on everything"
run_gate "$DIR"
assert_not_contains "$OUT" "is STALE" \
    "nothing changed under apps/core/lib since the reviewer saw it, so the review stands"
assert_not_contains "$OUT" "records no \`reviewed_at_sha\`" \
    "and a recorded SHA is not reported as missing"

DIR="$(new_sandbox sha_stale '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "SHA_PLACEHOLDER"}}')"
STALE_SHA="$(git -C "$DIR" rev-parse main)"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "an elixir commit the reviewer never saw"
python3 - "$DIR/plans/probe-campaign-state.json" "$STALE_SHA" <<'PY'
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("SHA_PLACEHOLDER", sha))
PY

test_case "a_review_predating_a_change_is_STALE" "work landing after a review is unreviewed work"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a stale review is a violation, not a warning"
assert_contains "$OUT" "elixir review is STALE" "the stack is named"
assert_contains "$OUT" "apps/core/lib/probe.ex" \
    "and so is the file the reviewer never saw — a count alone is the thing that gets ignored"

# ── 3. a declared diff_range wins over the working tree ──────────────────────
#
# The historical-campaign case. The working tree touches elixir; the declared
# range touches only proto. The guard must answer about the RANGE.
DIR="$(new_sandbox sha_uncommitted '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "SHA_PLACEHOLDER"}}')"
CURRENT_SHA="$(git -C "$DIR" rev-parse HEAD)"
python3 - "$DIR/plans/probe-campaign-state.json" "$CURRENT_SHA" <<'PY'
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("SHA_PLACEHOLDER", sha))
PY
# ⛔ UNCOMMITTED work under the stack's paths, with the review recorded at the
# CURRENT HEAD — so `diff SHA..HEAD` is empty and the committed-only version of
# the staleness check read this as covered.
echo 'defmodule Uncommitted do' > "$DIR/apps/core/lib/uncommitted.ex"

test_case "uncommitted_work_makes_a_current_review_STALE" \
    "a review recorded at HEAD does not cover work that is not in HEAD yet"
# ⛔ The same asymmetry the branch-diff path above was already fixed for, one
# leg over: that path unions committed + worktree + untracked, and this one
# compared against HEAD alone. So an in-flight wave — which is exactly what
# uncommitted work means — could have every stack reported as reviewed while
# the reviewer had seen none of it.
run_gate "$DIR"
assert_exit_nonzero "$RC" "uncommitted work in a reviewed stack is unreviewed work"
assert_contains "$OUT" "elixir review is STALE" "the stack is named"
assert_contains "$OUT" "apps/core/lib/uncommitted.ex" \
    "and so is the uncommitted file — a count alone is the thing that gets ignored"

DIR="$(new_sandbox sha_orphan '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "SHA_PLACEHOLDER"}}')"
# ⚠️ The elixir file is REQUIRED and its absence is what made the first version
# of this case vacuous. The staleness block only runs for stacks the wave
# actually touched, so with no `apps/core/lib` change the ancestry check was
# never reached — and the case still "passed" its exit-code assertion, because
# the gate was exiting nonzero for an unrelated reason. Measured by running the
# case against the gate WITHOUT the ancestry check, where it also passed.
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "an elixir commit, so the elixir stack is in scope"
# ⛔ A SHA that RESOLVES but is not on this branch's history. Built by
# re-committing HEAD's tree with no parent, so it is a real, readable object
# reachable by nothing.
ORPHAN_SHA="$(git -C "$DIR" commit-tree "$(git -C "$DIR" rev-parse 'HEAD^{tree}')" -m "orphan")"
python3 - "$DIR/plans/probe-campaign-state.json" "$ORPHAN_SHA" <<'PY'
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("SHA_PLACEHOLDER", sha))
PY

test_case "a_sha_that_is_not_an_ancestor_is_refused" \
    "the check could see files-changed-since but never a WRONG sha"
# ⛔ MEASURED, and it is why this case exists rather than the obvious one. The
# orphan's `diff ORPHAN..HEAD` returns **zero files**, because it carries HEAD's
# own tree — so the staleness check alone reads it as "nothing changed, the
# review is current" and passes. A wrong SHA is therefore indistinguishable
# from a perfectly current one by diff, and that failure is UPSTREAM of the one
# the rest of this block tests: a dispatch computed against the wrong base once
# told four reviewers their ranges were too narrow and told a fifth it had
# nothing to review. Ancestry is the signal that does not depend on trusting
# whoever wrote the SHA down.
run_gate "$DIR"
# ⚠️ No bare `assert_exit_nonzero` here, deliberately. Measured: it passes
# against a gate with NO ancestry check at all, because this sandbox exits
# nonzero for an unrelated reason — so it would be a third assertion that
# cannot fail on the thing it names, in a block whose whole subject is checks
# that pass for the wrong reason. The message assertion is the discriminating
# one (verified red without the check), and it implies the nonzero exit, since
# the gate only prints this line as a violation.
assert_contains "$OUT" "NOT an ancestor of HEAD" "the reason is named, not just the stack"
assert_not_contains "$OUT" "is STALE" \
    "and it is NOT reported as merely stale — the diff is meaningless, not current"

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
# A real wave sat at `in_progress` with six of six items complete, every DoD
# ticked and every review recorded — and the roll-up called it in-flight, which
# is what a fresh pass reads and believes.
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
items = state["waves"]["probe"]["items"]
items["beta"] = {"status": "not_started", "informal": True, "note": "still to do", "title": "second"}
json.dump(state, open(path, "w"), indent=2)
PY2

test_case "a_wave_with_work_left_is_not_reported" "the mirror check does not fire on a real in-flight wave"
run_gate "$DIR"
# ⚠️ Presence anchor first. A bare absence assertion is satisfied by a gate that
# produced NOTHING — a crash, a missing state file, a changed slug — and would
# then report the opposite of what it claims. This project has the rule written
# down because a wait-for-absence once passed that way.
assert_contains "$OUT" "Wave probe" "the gate ran and rendered the wave"
assert_not_contains "$OUT" "of its items are done" \
    "one item is not_started, so this wave is legitimately in_progress"

summarise
