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

# ── 6. a recorded SHA must say where it came from ───────────────────────────
#
# ⛔ The failure this closes actually happened, and every existing check passed
# through it. A recording script set `reviewed_at_sha` from the DISPATCH's
# head_sha for three axes — which assumes the reviewer reviewed the tip it was
# handed. Two had replied at an earlier commit and one at a different one, so
# all three read as having reviewed work they never saw, and the campaign
# UNDERSTATED its own staleness.
#
# ⚠️ Ancestry could not catch it: a dispatch head is a real ancestor of HEAD. A
# claim about what arrived in a message cannot be verified from inside a state
# file, so the requirement is that the claim be STATED — which turns a silent
# assumption into a sentence someone has to write.
#
# ⚠️ Driven, not grepped. This case was first written as four
# `assert_contains` over the gate's own SOURCE, which asserts the sentences
# exist and says nothing about whether the check runs — the precise instrument
# defect this suite keeps catching elsewhere. The red/green pair below differs
# only in the presence of the provenance field.
DIR="$(new_sandbox sha_unprovenanced '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "SHA_PLACEHOLDER"}}')"
# ⚠️ The elixir file is what puts `elixir` in the changed-stack set, and without
# it the per-stack loop never runs for elixir at all — so the gate still exited
# nonzero (other violations exist in this sandbox) while the provenance check
# had not executed. The exit status was satisfied for the wrong reason, and the
# green half below was then passing vacuously against a needle absent from both.
# Committed, so the review SHA can be HEAD and the review is current, not stale.
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "an elixir commit the review is current for"
UNPROV_SHA="$(git -C "$DIR" rev-parse HEAD)"
python3 - "$DIR/plans/probe-campaign-state.json" "$UNPROV_SHA" <<'PY'
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("SHA_PLACEHOLDER", sha))
PY

test_case "an_unprovenanced_sha_is_refused" "ancestry cannot see a SHA the reviewer never reported"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a SHA with no provenance is a violation"
assert_contains "$OUT" "with no provenance" "the refusal names the condition"
assert_contains "$OUT" "elixir review names" "and the stack it applies to"
assert_contains "$OUT" "ancestry cannot see it" \
    "and says why the ancestry check above it is not sufficient"

# ⚠️ THE ANTI-VACUITY HALF. Without it this case passes against a check that
# refuses every review, provenanced or not — and that is not a hypothetical: the
# sandbox above is at the current SHA with nothing changed under apps/core, so
# the ONLY thing standing between it and a clean report is the provenance field.
python3 - "$DIR/plans/probe-campaign-state.json" <<'PY'
import json, sys

path = sys.argv[1]
state = json.load(open(path))
entry = state["domain_reviews"]["elixir"]
entry["reviewed_at_sha_provenance"] = {"kind": "quoted_from_reply", "detail": "the reply said so"}
json.dump(state, open(path, "w"), indent=2)
PY

test_case "a_provenanced_sha_satisfies" "the green half — this must not fire on everything"
run_gate "$DIR"
assert_contains "$OUT" "Wave probe" "the gate ran and rendered the wave"
assert_not_contains "$OUT" "with no provenance" \
    "the same sandbox passes once the field is present — so the refusal is about provenance and nothing else"

# ⛔ And the check must not SHORT-CIRCUIT the staleness check below it. It was
# first written ending in `continue`, by symmetry with every refusal above it —
# but those end the stack's checks because staleness is genuinely uncomputable
# past them, and this one is not. MEASURED: the `continue` broke two existing
# staleness cases, reporting the weaker finding and hiding the stronger one.
DIR="$(new_sandbox sha_unprovenanced_and_stale '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "SHA_PLACEHOLDER"}}')"
BOTH_SHA="$(git -C "$DIR" rev-parse main)"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "an elixir commit the reviewer never saw"
python3 - "$DIR/plans/probe-campaign-state.json" "$BOTH_SHA" <<'PY'
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
with open(path, "w") as f:
    f.write(body.replace("SHA_PLACEHOLDER", sha))
PY

test_case "both_defects_are_reported_together" "a missing provenance note must not hide staleness"
run_gate "$DIR"
assert_contains "$OUT" "with no provenance" "the provenance violation is reported"
assert_contains "$OUT" "elixir review is STALE" "and the staleness violation is reported too"
assert_contains "$OUT" "apps/core/lib/probe.ex" \
    "naming the file — the finding a short-circuit here would have swallowed"

# ⚠️ The older key name stays accepted, because rows already on disk use it.
python3 - "$DIR/plans/probe-campaign-state.json" <<'PY'
import json, sys

path = sys.argv[1]
state = json.load(open(path))
state["domain_reviews"]["elixir"]["sha_provenance"] = "reconstructed: from the dispatch log"
json.dump(state, open(path, "w"), indent=2)
PY

test_case "the_older_key_name_is_accepted" "rows already on disk use the shorter spelling"
run_gate "$DIR"
assert_contains "$OUT" "elixir review is STALE" "the gate still ran and still reports staleness"
assert_not_contains "$OUT" "with no provenance" \
    "the shorter key name satisfies the requirement, so existing rows do not all turn red at once"

# ── 7. a preview DRIVE goes stale the same way a review does ────────────────
#
# ⛔ A wave whose verification predates its own changes is not verified. One
# wave was marked complete on a preview deploy that predated every row-level-
# security fix in it, plus 4122 passing tests run as a superuser that bypasses
# the policies entirely; five stack reviews then found 6 P0 and 20 P1 in that
# wave's own work, none of which any local instrument could see.
#
# ⚠️ THREE STATES, and only a FALSE claim fails. A stale drive record claims
# something checkable and wrong, so it is a violation. NO record is not a claim
# at all — it is reported on every run but does not fail, because making absence
# fatal would turn every wave closed before this mechanism existed permanently
# red, which is how a useful check gets deleted.

# A sandbox whose wave is COMPLETE (so the drive check runs at all) with a
# satisfied elixir review (so the drive finding is the only one in play).
drive_sandbox() {
    local name="$1" drive_json="$2" dir sha
    dir="$(new_sandbox "$name" '{"elixir": {"verdict": "LGTM", "reviewed_at_sha": "REVIEW_SHA", "reviewed_at_sha_provenance": "quoted_from_reply: the reply said so"}}')"
    echo 'defmodule Probe do' > "$dir/apps/core/lib/probe.ex"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "running code the drive and review both cover"
    sha="$(git -C "$dir" rev-parse HEAD)"
    python3 - "$dir/plans/probe-campaign-state.json" "$sha" "$drive_json" <<'DRIVEFIX'
import json, sys

path, sha, drive = sys.argv[1], sys.argv[2], sys.argv[3]
state = json.loads(open(path).read().replace("REVIEW_SHA", sha))
state["waves"]["probe"]["status"] = "complete"
if drive != "NONE":
    state["waves"]["probe"]["preview_drive"] = json.loads(drive.replace("DRIVE_SHA", sha))
json.dump(state, open(path, "w"), indent=2)
DRIVEFIX
    printf '%s' "$dir"
}

test_case "a_complete_wave_with_no_drive_is_REPORTED_not_failed" \
    "absence is a gap, not a false claim — and making it fatal is how a check gets deleted"
DIR="$(drive_sandbox drive_absent NONE)"
run_gate "$DIR"
assert_contains "$OUT" "no preview drive recorded" "the gap is stated on every run"
assert_contains "$OUT" "superuser test role bypasses" \
    "and says why local green is not sufficient evidence"
assert_not_contains "$OUT" "preview drive is STALE" \
    "but an absent record is not reported as a stale one"

test_case "a_current_drive_with_provenance_satisfies" \
    "the green half — this must not fire on everything"
DIR="$(drive_sandbox drive_current '{"at_sha": "DRIVE_SHA", "at_sha_provenance": "reconstructed: read off the deployed stack"}')"
run_gate "$DIR"
assert_contains "$OUT" "drive current as of" "a drive covering the current tree is reported as current"
assert_not_contains "$OUT" "preview drive is STALE" "and not as stale"
assert_not_contains "$OUT" "with no provenance" "and not as unprovenanced"

test_case "a_drive_predating_running_code_is_STALE" \
    "a drive that never saw this code cannot be its verification"
DIR="$(drive_sandbox drive_stale '{"at_sha": "DRIVE_SHA", "at_sha_provenance": "reconstructed: read off the deployed stack"}')"
echo 'defmodule Later do' > "$DIR/apps/core/lib/later.ex"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "running code that landed after the drive"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a stale drive is a violation, not a warning"
assert_contains "$OUT" "preview drive is STALE" "the condition is named"
assert_contains "$OUT" "apps/core/lib/later.ex" \
    "and so is the file the drive never saw — a count alone is the thing that gets ignored"

# ⚠️ THE DISCRIMINATING HALF. A drive must be spent by a change to code that
# RUNS, not by a change to a gate or a test. Without this case the check passes
# while firing on every wave that touched `test/platform`, which would make it
# useless and then removed.
test_case "a_test_only_change_does_not_spend_a_drive" \
    "a drive is evidence about running behaviour, so only running code spends it"
DIR="$(drive_sandbox drive_tests_only '{"at_sha": "DRIVE_SHA", "at_sha_provenance": "reconstructed: read off the deployed stack"}')"
mkdir -p "$DIR/test/platform" "$DIR/scripts"
echo 'echo hi' > "$DIR/test/platform/some_suite.sh"
echo 'echo hi' > "$DIR/scripts/some-gate.sh"
git -C "$DIR" add -A
git -C "$DIR" commit -qm "a gate and a suite, no running code"
run_gate "$DIR"
assert_contains "$OUT" "drive current as of" \
    "a scripts/test-only change leaves the drive current — it changed nothing a browser saw"
assert_not_contains "$OUT" "preview drive is STALE" "so it must not be reported stale"

test_case "a_drive_sha_must_say_where_it_came_from" \
    "ancestry cannot prove anyone actually drove it"
DIR="$(drive_sandbox drive_unprovenanced '{"at_sha": "DRIVE_SHA"}')"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a drive sha with no provenance is a violation"
assert_contains "$OUT" "with no provenance" "the refusal names the condition"
assert_contains "$OUT" "at_sha_provenance" "and the field that satisfies it"

test_case "a_recorded_non_drive_is_accepted_with_its_reason" \
    "a wave with no user-facing surface is a legitimate row, not a hole"
DIR="$(drive_sandbox drive_declined '{"not_driven": "no user-facing surface - gates and tracking only"}')"
run_gate "$DIR"
assert_contains "$OUT" "not driven, by record" "the recorded decision is surfaced"
assert_contains "$OUT" "no user-facing surface" "together with the reason given"
assert_not_contains "$OUT" "no preview drive recorded" \
    "and it is not also reported as an unexplained gap"

# ── 8. provenance is a KIND plus detail, not free text ──────────────────────
#
# ⛔ A predecessor guard in this repository carried eight free-text allowlist
# reasons and SEVEN of them were untrue. Presence-only prose cannot be checked
# and cannot be falsified later, so it decays into a field people fill in to get
# past the gate.
#
# ⚠️ The enum does NOT buy verification — nothing here can confirm what arrived
# in a message. It buys SPECIFICITY: "quoted_from_reply" is a definite claim
# someone can be shown wrong about, where "I got this from the reviewer somehow"
# is not, and being able to be wrong in public is the property this field is for.

test_case "free_text_provenance_is_refused" "prose that cannot be falsified is not provenance"
DIR="$(drive_sandbox prov_free_text NONE)"
python3 - "$DIR/plans/probe-campaign-state.json" <<'FREETEXT'
import json, sys

path = sys.argv[1]
state = json.load(open(path))
state["domain_reviews"]["elixir"]["reviewed_at_sha_provenance"] = (
    "I am fairly sure the reviewer mentioned this commit at some point"
)
json.dump(state, open(path, "w"), indent=2)
FREETEXT
run_gate "$DIR"
assert_exit_nonzero "$RC" "provenance with no recognised kind is a violation"
assert_contains "$OUT" "no provenance of a recognised kind" "the refusal names the condition"
assert_contains "$OUT" "quoted_from_reply" "and lists the kinds that satisfy it"
assert_contains "$OUT" "cannot be falsified" "and says why prose is not enough"

test_case "both_provenance_spellings_are_accepted" \
    "rows already on disk use the string form, so it must keep working"
for SPELLING in dict string; do
    DIR="$(drive_sandbox "prov_$SPELLING" NONE)"
    python3 - "$DIR/plans/probe-campaign-state.json" "$SPELLING" <<'SPELL'
import json, sys

path, spelling = sys.argv[1], sys.argv[2]
state = json.load(open(path))
entry = state["domain_reviews"]["elixir"]
if spelling == "dict":
    entry["reviewed_at_sha_provenance"] = {"kind": "reconstructed", "detail": "from the log"}
else:
    entry["reviewed_at_sha_provenance"] = "reconstructed: from the log"
json.dump(state, open(path, "w"), indent=2)
SPELL
    run_gate "$DIR"
    if ! grep -q "recognised kind" <<< "$OUT"; then
        _record_pass "the $SPELLING spelling satisfies the requirement"
    else
        _record_fail "the $SPELLING spelling was refused: $OUT"
    fi
done

test_case "an_unrecognised_kind_is_refused" "the enum is closed, or it is just prose with a colon"
DIR="$(drive_sandbox prov_bad_kind NONE)"
python3 - "$DIR/plans/probe-campaign-state.json" <<'BADKIND'
import json, sys

path = sys.argv[1]
state = json.load(open(path))
state["domain_reviews"]["elixir"]["reviewed_at_sha_provenance"] = {
    "kind": "probably_fine",
    "detail": "a kind nobody declared",
}
json.dump(state, open(path, "w"), indent=2)
BADKIND
run_gate "$DIR"
assert_exit_nonzero "$RC" "a kind outside the enum is a violation"
assert_contains "$OUT" "recognised kind" "so the enum is closed rather than advisory"

summarise
