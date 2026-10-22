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

# ⚠️ DECLARED HERE, far from the case that reads it, on the guard-bypassability
# gate's instruction. Strictly its finding was a false positive — the
# `SystemExit(0)` it flagged is inside an embedded python heredoc and exits that
# interpreter, not this script — but the fix it asks for costs nothing, and
# arguing with a gate to avoid moving a constant is the wrong trade when the
# gate's own header records that narrowing it previously produced zero true
# positives. It also matches the rule this suite enforces on `wave-status.sh`
# one file over: declarations above the flow that uses them.
#
# What it counts: fixtures that set `declares_dispatches`, turning off the
# harness default that keeps other cases from testing the dispatch count by
# accident. See the case at the end of this file for why an undeclared opt-out
# is an allowlist with unstated reasons.
EXPECTED_DISPATCH_OPT_OUTS=3

# A sandbox repo with one commit on `main`, a feature branch at the same commit,
# and a campaign state whose single item is COMPLETE — which is what switches
# the campaign-level stack guard on. `informal` keeps the item from needing a
# backing issue file, so the only thing under test is the stack guard.
#
# ⛔ THE WAVE IS MARKED COMPLETE, AND THAT IS LOAD-BEARING FOR EVERY EXIT-CODE
# ASSERTION IN THIS FILE. It used to say `in_progress` while its only item was
# done, which is itself a violation — so the gate exited NON-ZERO on every run
# of this sandbox, and all sixteen `assert_exit_nonzero` cases below were
# satisfied by the FIXTURE rather than by the check under test. MEASURED: under
# a probe that neutered the dispatch reconciliation entirely, its exit
# assertion still passed; only the message assertions caught it.
#
# ⚠️ The comment at the ancestry case already recorded "a bare
# assert_exit_nonzero passes here" for one case — noticing the symptom without
# fixing the cause, which left the other fifteen reading as evidence. A clean
# baseline is what makes a non-zero exit mean anything, so the one case that
# genuinely tests the understated-wave roll-up sets `in_progress` back
# explicitly rather than relying on this default.
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
      "status": "complete",
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

# ⛔ A MANDATORY FIELD DIRTIES EVERY FIXTURE THAT PREDATES IT, and that is how
# a clean baseline silently stops being one. MEASURED: adding the `dispatches`
# reconciliation put a standing violation into all sixteen sandboxes that do
# not declare it, so their exit codes went back to being satisfied by the
# fixture — the exact vacuity the wave status above was just fixed to remove,
# reintroduced one commit later by a different field.
#
# So the harness reconciles the field for any case that does not speak about
# it, leaving each case testing the one thing it means to. A case that IS about
# the dispatch count sets `declares_dispatches` and is left alone — opting out
# by declaration rather than by the absence the default would paper over.
normalise_dispatches() {
    python3 - "$1/plans/probe-campaign-state.json" <<'NORMALISE'
import json, sys

path = sys.argv[1]
state = json.load(open(path))
# ⚠️ Read, never consumed. Several cases call run_gate TWICE against the same
# fixture — popping the flag would make the second call take the default path
# and quietly test something the first did not.
if state.get("declares_dispatches"):
    raise SystemExit(0)
for entry in (state.get("domain_reviews") or {}).values():
    if not isinstance(entry, dict) or "dispatches" in entry:
        continue
    log = [e for e in (entry.get("reviews") or []) if isinstance(e, dict) and e.get("sha")]
    if not log and entry.get("reviewed_at_sha"):
        log = [{"sha": entry["reviewed_at_sha"]}]
    count = len(log) + entry.get("declines", 0) + (1 if entry.get("dispatch_in_flight") else 0)
    entry["dispatches"] = count
    # ⛔ EVERY mandatory field of this check must be filled here, not just the
    # first one. MEASURED: making `dispatches_baseline` mandatory re-dirtied
    # all sixteen fixtures a THIRD time — the normaliser supplied `dispatches`
    # and not the baseline, so the exit assertions silently went back to being
    # satisfied by the fixture. The canary case below is what caught it.
    entry["dispatches_baseline"] = count
json.dump(state, open(path, "w"), indent=2)
NORMALISE
}

run_gate() {
    normalise_dispatches "$1"
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
# The one case that wants the understated state, set explicitly — the shared
# sandbox is clean so that the exit codes elsewhere carry information.
python3 - "$DIR/plans/probe-campaign-state.json" <<'UNDERSTATE'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
state["waves"]["probe"]["status"] = "in_progress"
json.dump(state, open(path, "w"), indent=2)
UNDERSTATE

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

# ── 9. the review record is an append-only LOG, not one field ───────────────
#
# ⛔ A single `reviewed_at_sha` cannot distinguish "the newest review" from "a
# review". MEASURED on the real campaign: one axis sat recorded at an earlier
# commit while THREE later reviews existed and were never written down, so the
# staleness check reported reviewed work as unreviewed and the next dispatch
# handed the reviewer work they had already approved.
#
# ⚠️ An empty-per-axis-range check cannot reach this. That catches
# OVER-recording (a sha newer than any real review); under-recording leaves a
# non-empty, plausible range and is blind by construction. The rule that does
# catch it is arithmetic over the log: the entry treated as current must be the
# maximum by ancestry.

log_sandbox() {
    local name="$1" reviews_json="$2" dir base head
    dir="$(new_sandbox "$name" '{"elixir": {"verdict": "LGTM"}}')"
    base="$(git -C "$dir" rev-parse HEAD)"
    echo 'defmodule Probe do' > "$dir/apps/core/lib/probe.ex"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "elixir work the newest review covers"
    head="$(git -C "$dir" rev-parse HEAD)"
    python3 - "$dir/plans/probe-campaign-state.json" "$base" "$head" "$reviews_json" <<'LOGFIX'
import json, sys

path, base, head, reviews = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
state = json.load(open(path))
state["domain_reviews"]["elixir"]["reviews"] = json.loads(
    reviews.replace("BASE_SHA", base).replace("HEAD_SHA", head)
)
json.dump(state, open(path, "w"), indent=2)
LOGFIX
    printf '%s' "$dir"
}

PROV='{"kind": "quoted_from_reply", "detail": "the reply said so"}'

test_case "the_newest_log_entry_is_the_one_measured" \
    "the green half — a log in reply order must not fire"
DIR="$(log_sandbox log_ordered "[{\"sha\": \"BASE_SHA\", \"provenance\": $PROV}, {\"sha\": \"HEAD_SHA\", \"provenance\": $PROV}]")"
run_gate "$DIR"
assert_not_contains "$OUT" "sit LATER on this branch" \
    "the last entry is the newest, so nothing is out of order"
assert_not_contains "$OUT" "review is STALE" \
    "and staleness is measured from the NEWEST entry, so this review is current"

# ⛔ The planted red, and it is the real failure: the older entry is last, so an
# earlier commit is treated as current while a later review is on record.
test_case "an_older_entry_treated_as_current_is_refused" \
    "under-recording measures staleness from too far back and re-sends reviewed work"
DIR="$(log_sandbox log_out_of_order "[{\"sha\": \"HEAD_SHA\", \"provenance\": $PROV}, {\"sha\": \"BASE_SHA\", \"provenance\": $PROV}]")"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a stale current entry is a violation"
assert_contains "$OUT" "sit LATER on this branch" "the refusal names the condition"
assert_contains "$OUT" "re-sends work that was already reviewed" \
    "and states the cost, which is a reviewer's time rather than a false green"

# ── every entry must RESOLVE, or one bogus entry defeats the rule ──────────
#
# ⛔ MEASURED on my own record. I wrote a 40-char sha for this log having been
# given only the short form, inventing 32 hex characters — and the check I used
# to verify it was `git rev-parse --verify <40-hex>`, which ECHOES BACK any
# well-formed hex string rather than resolving it. So the verification passed
# for the wrong reason, on a fabricated value, inside the mechanism built to
# stop fabricated values.
#
# ⚠️ The ancestry rule above asks `merge-base --is-ancestor` of each older
# entry, and that command FAILS for a sha that does not exist — which reads as
# "not a descendant" and is skipped in silence. One bogus entry would therefore
# hide an out-of-order log.
test_case "an_unresolvable_log_entry_is_refused" \
    "a sha that resolves to nothing is skipped by the ancestry rule, so it must refuse first"
BOGUS="81fc33c05e7d1e1e4b3f5d9e8c1a6f2b4d7e0a94"
DIR="$(log_sandbox log_bogus "[{\"sha\": \"$BOGUS\", \"provenance\": $PROV}, {\"sha\": \"HEAD_SHA\", \"provenance\": $PROV}]")"
run_gate "$DIR"
assert_exit_nonzero "$RC" "an unresolvable entry is a violation"
assert_contains "$OUT" "cannot resolve" "the refusal names the condition"
assert_contains "$OUT" "echoes back any well-formed hex string" \
    "and names the check that must NOT be used to verify one"

# ⚠️ The discriminating half: the bogus sha used above must be well-formed, or
# this case would pass against a gate that merely checked the LENGTH.
test_case "the_bogus_sha_is_well_formed" "a length check must not be able to pass this case"
if [[ "${#BOGUS}" -eq 40 ]] && [[ "$BOGUS" =~ ^[0-9a-f]+$ ]]; then
    _record_pass "the planted sha is 40 lowercase hex characters, so only resolution can refuse it"
else
    _record_fail "the planted sha is malformed, so the case above proves nothing about resolution"
fi

test_case "the_legacy_single_field_still_works" \
    "a migration that turns every existing row red is a migration nobody runs"
DIR="$(drive_sandbox log_legacy NONE)"
run_gate "$DIR"
assert_not_contains "$OUT" "cannot resolve" "the single-field form normalises into a one-entry log"
assert_not_contains "$OUT" "sit LATER on this branch" "and a one-entry log has nothing out of order"
assert_not_contains "$OUT" "recognised kind" "with its provenance carried across"

# ── 10. a dispatch base must be BYTE-EQUAL to the newest recorded review ────
#
# ⛔ The reviewer corrected their own framing, and the correction is the point.
# Stating the rule as a property of the LOG ("no entry may be a descendant of
# the current one") checks internal consistency and ties nothing to the base
# actually dispatched from. Non-emptiness of a range is a weak signal because
# many WRONG bases are non-empty — but an inferred base essentially cannot
# ACCIDENTALLY be byte-equal to a recorded 40-character sha.
#
# ⚠️ Both failures this exists for would have been caught by equality and
# neither was caught by ancestry: a sha fabricated by padding a short one, and a
# base silently substituted from the dispatch head.

dispatch_sandbox() {
    local name="$1" dispatch_json="$2" dir base head
    dir="$(new_sandbox "$name" '{"elixir": {"verdict": "LGTM"}}')"
    base="$(git -C "$dir" rev-parse HEAD)"
    echo 'defmodule Probe do' > "$dir/apps/core/lib/probe.ex"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "elixir work"
    head="$(git -C "$dir" rev-parse HEAD)"
    python3 - "$dir/plans/probe-campaign-state.json" "$base" "$head" "$dispatch_json" <<'DISPATCHFIX'
import json, sys

path, base, head, dispatch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
state = json.load(open(path))
e = state["domain_reviews"]["elixir"]
e["reviews"] = [
    {"sha": head, "provenance": {"kind": "quoted_from_reply", "detail": "the reply"}}
]
parsed = json.loads(dispatch.replace("BASE_SHA", base).replace("HEAD_SHA", head))
if parsed is None:
    e.pop("dispatch_in_flight", None)
else:
    e["dispatch_in_flight"] = parsed
json.dump(state, open(path, "w"), indent=2)
DISPATCHFIX
    printf '%s' "$dir"
}

# ⛔ THE CANARY, AND IT IS A STANDING INSTRUMENT RATHER THAN A CASE ABOUT
# DISPATCHES. Every `assert_exit_nonzero` in this file is evidence only while a
# correct fixture exits ZERO, and that property has now been revoked THREE
# TIMES by three different causes: the wave status, then `dispatches`, then
# `dispatches_baseline` — each one a new mandatory requirement that every
# pre-existing fixture silently failed.
#
# ⚠️ It was caught all three times by probing an UNRELATED check and noticing
# its exit assertion had stopped reddening, which is a thing I had to remember
# to do. Asserting it directly is what makes the next mandatory field announce
# itself: this case reds the moment a correct fixture stops being clean, and it
# names the cause rather than leaving sixteen assertions quietly decorative.
test_case "a_correct_fixture_exits_ZERO_so_the_exit_assertions_mean_something" \
    "three mandatory fields have each silently revoked this property"
DIR="$(dispatch_sandbox disp_clean '{"base_sha": "HEAD_SHA", "round": 2}')"
run_gate "$DIR"
assert_exit_zero "$RC" \
    "a fixture with nothing wrong must be GREEN, or every assert_exit_nonzero below is satisfied by the fixture"
assert_contains "$OUT" "Wave probe" "and the gate actually ran, rather than producing nothing"

test_case "a_base_equal_to_the_newest_review_satisfies" "the green half — this must not fire on a correct dispatch"
DIR="$(dispatch_sandbox disp_equal '{"base_sha": "HEAD_SHA", "round": 2}')"
run_gate "$DIR"
assert_not_contains "$OUT" "must be BYTE-EQUAL" "a base matching the newest review passes"
assert_not_contains "$OUT" "records no \`base_sha\`" "and is not reported as missing"

# ⛔ The planted red, and it is the dispatch-head substitution: the base is an
# ANCESTOR of the newest review, so ancestry would accept it and equality does
# not. This is the failure that actually happened.
test_case "a_base_that_is_merely_an_ancestor_is_refused" \
    "ancestry accepts the exact mistake this rule exists to catch"
DIR="$(dispatch_sandbox disp_ancestor '{"base_sha": "BASE_SHA", "round": 2}')"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a base that is not byte-equal is a violation"
assert_contains "$OUT" "must be BYTE-EQUAL" "the refusal names the condition"
assert_contains "$OUT" "re-sends work already approved" "and states what an ancestor base costs"
assert_contains "$OUT" "cannot accidentally match" \
    "and says why equality is the check where ancestry is not"

test_case "a_dispatch_with_no_base_is_refused" "what the reviewer was asked to look at must be recorded"
DIR="$(dispatch_sandbox disp_nobase '{"round": 2}')"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a dispatch with no base is a violation"
assert_contains "$OUT" "records no \`base_sha\`" "the refusal names the condition"

# ⚠️ And no dispatch at all must not fire — most axes have none in flight.
test_case "no_dispatch_in_flight_is_not_a_violation" "an axis between rounds has nothing to check"
DIR="$(dispatch_sandbox disp_none 'null')"
run_gate "$DIR"
assert_not_contains "$OUT" "base_sha" "an absent dispatch is silent, not refused"

# ── the first dispatch is a DECLARED state, not a bypass ───────────────────
#
# ⛔ "Empty log means anything goes" would be this rule skipped by a path rather
# than satisfied — the same shape as a declared count below an early success
# exit, which is the defect its sibling gate was built for.
test_case "an_undeclared_first_dispatch_is_refused" \
    "an empty log must not be a path around the rule"
DIR="$(new_sandbox disp_firstundeclared '{"elixir": {"verdict": "LGTM", "dispatch_in_flight": {"base_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", "round": 1}}}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a dispatch with no recorded review is a violation"
assert_contains "$OUT" "no recorded review to match it against" "the refusal names the condition"
assert_contains "$OUT" "first_dispatch: true" "and names the declaration that would make it legitimate"

test_case "a_declared_first_dispatch_is_accepted" "a genuine first round is a legitimate state"
DIR="$(new_sandbox disp_firstdeclared '{"elixir": {"verdict": "LGTM", "dispatch_in_flight": {"base_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", "round": 1, "first_dispatch": true}}}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
run_gate "$DIR"
assert_contains "$OUT" "first dispatch, no prior review" "the declared state is surfaced"
assert_not_contains "$OUT" "no recorded review to match it against" "and not also reported as a gap"

# ── a campaign that predates the field reports once, and still refuses ─────
#
# ⛔ MEASURED: `wave-status` has never been usable on a finished campaign since
# `reviewed_at_sha` became mandatory — two closed campaigns emitted 5 and 7
# campaign-level violations, every one the same fact. The retrospective case
# `diff_range` exists to serve was blocked by a field postdating the campaigns
# it would be used on.
#
# ⚠️ BOTH HALVES ARE ASSERTED, because collapsing the message is only correct
# while the refusal survives. A finished campaign whose axes were never recorded
# really did ship unreviewed work, and turning that into a pass would be this
# guard's own failure mode — an axis disappearing because nothing demanded it.
test_case "many_axes_with_no_recorded_sha_report_once_and_still_refuse" \
    "one fact about the record, not N problems — and still not a pass"
DIR="$(new_sandbox predates '{"elixir": {"verdict": "LGTM"}, "elm": {"verdict": "LGTM"}, "platform": {"verdict": "LGTM"}}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
echo 'module Probe exposing (x)' > "$DIR/frontend/src/Probe.elm" 2>/dev/null \
    || { mkdir -p "$DIR/frontend/src"; echo 'module Probe exposing (x)' > "$DIR/frontend/src/Probe.elm"; }
mkdir -p "$DIR/scripts"; echo '#!/usr/bin/env bash' > "$DIR/scripts/probe.sh"
run_gate "$DIR"
assert_exit_nonzero "$RC" \
    "UNVERIFIABLE is not a pass — work shipped under a review nobody can place against a commit"
assert_contains "$OUT" "axes record a verdict with no \`reviewed_at_sha\`" "the collapsed message is used"
assert_contains "$OUT" "UNVERIFIABLE from this record" "and says what the state actually is"
assert_contains "$OUT" "not the same as absent and is not a pass" \
    "and refuses the reading that would make this silence a gap"

# ⚠️ The discriminating half: with work still ACTIONABLE, the per-axis messages
# must come back. A live campaign missing a sha is a thing to fix now, named per
# axis; a finished one is a fact about history. Collapsing both would hide the
# live case inside a sentence about the past.
test_case "a_live_campaign_still_reports_each_missing_sha_separately" \
    "the collapse is about finished campaigns, not about tidiness"
python3 - "$DIR/plans/probe-campaign-state.json" <<'STILLGOING'
import json, sys
state = json.load(open(sys.argv[1]))
wave = state["waves"]["probe"]
wave["status"] = "in_progress"
wave["items"]["beta"] = {"status": "not_started", "informal": True, "note": "live work", "title": "second"}
json.dump(state, open(sys.argv[1], "w"), indent=2)
STILLGOING
run_gate "$DIR"
assert_exit_nonzero "$RC" "still a violation"
assert_contains "$OUT" "the elixir review records no \`reviewed_at_sha\`" "elixir is named on its own"
assert_contains "$OUT" "the elm review records no \`reviewed_at_sha\`" "and so is elm"
assert_not_contains "$OUT" "axes record a verdict with no" \
    "the collapsed form must NOT be used while there is work left to do"

# ── 10b. a dispatch must reconcile with a logged reply ─────────────────────
#
# ⛔ THE DEFECT THAT PRODUCED THIS SECTION HAPPENED TWICE, the second time
# AFTER the byte-equality rule above was built for the first. Four reviewer
# replies arrived, were acted on, and were never appended to the log; then one
# more did.
#
# ⚠️ Every check above is blind to it BY CONSTRUCTION, and that is the point
# worth a case rather than a comment. Base-equality compares a dispatch against
# the newest log entry — so when the dispatch is dropped along with the reply,
# there is nothing left to be unequal to, and the log that remains is perfectly
# self-consistent. Ancestry is satisfied, resolution is satisfied, provenance is
# satisfied, staleness is satisfied. The missing entry leaves no trace in any of
# them.
#
# What is absent is a record that the dispatch COMPLETED. So the count of rounds
# sent is declared at dispatch and reconciled against the log length, and the
# green/red pair below is followed by a case asserting that the count is the
# ONLY instrument that reports the defect.

# `baseline`: "" takes the reconciling default, "none" omits the field entirely
# (the mandatory-baseline case), anything else is used verbatim.
# `declines`: "" omits the field, a number records that many declined rounds.
completion_sandbox() {
    local name="$1" dispatches="$2" dispatch_json="$3" baseline="${4:-}" declines="${5:-}" dir base head
    dir="$(new_sandbox "$name" '{"elixir": {"verdict": "LGTM"}}')"
    base="$(git -C "$dir" rev-parse HEAD)"
    echo 'defmodule Probe do' > "$dir/apps/core/lib/probe.ex"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "elixir work the review covers"
    head="$(git -C "$dir" rev-parse HEAD)"
    python3 - "$dir/plans/probe-campaign-state.json" "$base" "$head" \
        "$dispatches" "$dispatch_json" "$baseline" "$declines" <<'COMPLETIONFIX'
import json, sys

path, base, head, dispatches, dispatch, baseline, declines = sys.argv[1:8]
state = json.load(open(path))
# This case is ABOUT the dispatch count, so the harness default must not touch
# it — including the case that tests an absent count, which the default would
# otherwise fill in and hide.
state["declares_dispatches"] = True
e = state["domain_reviews"]["elixir"]
e["reviews"] = [
    {"sha": head, "provenance": {"kind": "quoted_from_reply", "detail": "the reply"}}
]
if dispatches != "":
    e["dispatches"] = json.loads(dispatches)
# ⚠️ The baseline defaults to a RECONCILING value rather than being omitted:
# it is mandatory, so leaving it out of every fixture would make each case test
# the missing-baseline refusal instead of what it names. "none" is the explicit
# opt-out for the one case that IS about its absence.
if baseline == "":
    if dispatches != "":
        e["dispatches_baseline"] = json.loads(dispatches)
elif baseline != "none":
    e["dispatches_baseline"] = json.loads(baseline)
if declines != "":
    e["declines"] = json.loads(declines)
parsed = json.loads(dispatch.replace("BASE_SHA", base).replace("HEAD_SHA", head))
if parsed is not None:
    e["dispatch_in_flight"] = parsed
json.dump(state, open(path, "w"), indent=2)
COMPLETIONFIX
    printf '%s' "$dir"
}

test_case "a_settled_axis_reconciles" \
    "the green half — one dispatch, one logged reply, nothing in flight"
DIR="$(completion_sandbox comp_settled 1 'null')"
run_gate "$DIR"
assert_not_contains "$OUT" "logged replies" "a settled axis is silent"
assert_not_contains "$OUT" "declares no \`dispatches\` count" "and is not reported as undeclared"
# ⚠️ Asserted here so the `assert_exit_nonzero` in the red cases below means
# something. MEASURED: under a probe that neutered the reconciliation, those
# cases' exit assertions still PASSED while only their message assertions
# caught it — the same shape as the four ordering slips this file gates. A
# non-zero exit is only evidence if the green fixture exits ZERO.
assert_exit_zero "$RC" "a reconciled axis leaves the gate green, so a non-zero exit below is evidence"

test_case "an_axis_awaiting_a_reply_reconciles" \
    "the other green half — a round in flight is legitimately one ahead of the log"
DIR="$(completion_sandbox comp_awaiting 2 '{"base_sha": "HEAD_SHA", "round": 2}')"
run_gate "$DIR"
assert_not_contains "$OUT" "logged replies" "an in-flight round is not a gap"

# ⛔ The planted red, and it is the exact shape that happened: the count says a
# round was sent, the log has no reply for it, and nothing is in flight.
test_case "a_dispatch_with_no_logged_reply_is_refused" \
    "a reply read and acted on but never written down is what this exists to catch"
DIR="$(completion_sandbox comp_unlogged 2 'null')"
run_gate "$DIR"
assert_exit_nonzero "$RC" "an unlogged reply is a violation"
assert_contains "$OUT" "declares 2 dispatches against 1 logged replies" \
    "the refusal states both numbers rather than only that they disagree"
assert_contains "$OUT" "never appended" "and names the act that produces it"

# ⛔ THE DISCRIMINATING CASE, and the reason the count had to exist at all. On
# the SAME fixture, every other rule in this guard reads green — so if this
# assertion ever fails because another check started firing, the count has
# stopped being the thing that catches this and the next reader should know.
test_case "the_count_is_the_only_instrument_that_sees_an_unlogged_reply" \
    "every other rule is satisfied by a log that is merely missing an entry"
assert_not_contains "$OUT" "must be BYTE-EQUAL" \
    "base-equality has nothing to compare — the dispatch went with the reply"
assert_not_contains "$OUT" "sit LATER on this branch" \
    "ancestry is satisfied: the remaining entries are in order"
assert_not_contains "$OUT" "cannot resolve" "every remaining entry resolves"
assert_not_contains "$OUT" "no provenance" "every remaining entry is provenanced"
assert_not_contains "$OUT" "review is STALE" \
    "and staleness is satisfied, because the entry that IS there covers HEAD"

test_case "an_undeclared_dispatch_count_is_refused" \
    "an absent counter is this rule skipped rather than satisfied"
DIR="$(completion_sandbox comp_undeclared '' 'null')"
run_gate "$DIR"
assert_exit_nonzero "$RC" "an axis with no declared count is a violation"
assert_contains "$OUT" "declares no \`dispatches\` count" "the refusal names the condition"
assert_contains "$OUT" "UNDETECTABLE" "and says what the absence costs"

# ⚠️ A DECLINE IS THE THIRD OUTCOME, and omitting it made every decline read as
# the defect. Found by a reviewer declining a round the same hour this check
# shipped: the dispatch was answered, correctly, and produced no review entry —
# so the count sat one above the log with nothing in flight, which is exactly
# the signature of a lost reply. A model that cannot represent a legitimate
# outcome reports it as the failure it most resembles.
test_case "a_recorded_decline_settles_a_dispatch" \
    "a declined round is answered, not lost"
DIR="$(completion_sandbox comp_declined 2 'null' '' 1)"
run_gate "$DIR"
assert_exit_zero "$RC" "a dispatch settled by a decline reconciles"
assert_not_contains "$OUT" "never appended" \
    "a decline must not be reported as the reply that was never written down"

# ⛔ And the red half, which is what keeps `declines` from being an escape
# hatch: a decline COUNT does not excuse a missing one. Two dispatches, one
# logged reply, no declines recorded — still the defect.
test_case "a_decline_count_does_not_excuse_an_unlogged_reply" \
    "the third outcome must be recorded to settle a round, not merely available"
DIR="$(completion_sandbox comp_declined_zero 2 'null' '' 0)"
run_gate "$DIR"
assert_exit_nonzero "$RC" "an unrecorded outcome is still a violation"
assert_contains "$OUT" "a logged reply or a recorded decline" \
    "and the refusal names both settling outcomes, so the fix is discoverable"

# ⛔ The baseline is MANDATORY. It was optional, so deleting the field silently
# removed the only guard against a counter reset to match a short log — the
# same shape as a declared count below an early success exit.
test_case "a_dispatch_count_with_no_baseline_is_refused" \
    "an optional guard is one a future edit removes without noticing"
DIR="$(completion_sandbox comp_nobaseline 1 'null' none)"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a count with no baseline is a violation"
assert_contains "$OUT" "no \`dispatches_baseline\`" "the refusal names the missing field"
assert_contains "$OUT" "silent downgrade" "and says why absence is not a smaller claim"

# ⚠️ An axis with NO log and NO dispatch has nothing to reconcile, and
# demanding the counter of it put twelve violations onto two FINISHED campaigns
# whose axes predate the field — this repo's own rule about migrations that red
# every existing row, broken two days after writing it.
#
# ⛔ The narrowing is safe only because another check closes the escape: such an
# axis is already refused for recording no `reviewed_at_sha`, so deleting the
# log to dodge the counter trades one refusal for another. Both halves are
# asserted here, because "absent is fine" is otherwise the exact shape this
# section refuses.
# ⛔ THE ONE STATE WHERE THE TWO PREDICATES CAN DISAGREE, pinned because the
# edit that opens it reads as a bug fix.
#
# `_review_log` returns `[]` for a `reviews` list that is non-empty but whose
# entries all lack a `sha` — the `reviewed_at_sha` fallback sits in the
# else-branch of `if … and log`, so a non-empty malformed list never reaches it.
# Today that axis is refused for recording no `reviewed_at_sha`, which is what
# makes the counter's narrowing safe.
#
# ⚠️ Now consider `seen = current.get("sha") or entry.get("reviewed_at_sha")`,
# which a future reader may well write as a repair for a malformed legacy log.
# `seen` becomes truthy while `has_history` stays false, and the axis passes
# with NO counter at all — the narrowing turned into the escape it was argued
# not to be. The reviewer found this by tracing the line rather than reading the
# comment, which had named the wrong guarantee.
test_case "a_malformed_log_with_a_legacy_sha_is_still_refused" \
    "the narrowing is safe only while has_history and seen read ONE derivation"
DIR="$(new_sandbox comp_malformed '{"elixir": {"verdict": "LGTM"}}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
python3 - "$DIR/plans/probe-campaign-state.json" <<'MALFORMED'
import json, sys
state = json.load(open(sys.argv[1]))
state["declares_dispatches"] = True
e = state["domain_reviews"]["elixir"]
# Non-empty `reviews` whose entries carry NO sha, plus a legacy single field.
e["reviews"] = [{"provenance": {"kind": "quoted_from_reply", "detail": "no sha recorded"}}]
e["reviewed_at_sha"] = "0123456789abcdef0123456789abcdef01234567"
json.dump(state, open(sys.argv[1], "w"), indent=2)
MALFORMED
run_gate "$DIR"
assert_exit_nonzero "$RC" \
    "an axis whose log normalises to empty must still be refused, or the counter's narrowing becomes a green path"
assert_contains "$OUT" "records no \`reviewed_at_sha\`" \
    "and the refusal is the one the narrowing relies on — if this stops firing, the counter stops being demanded too"

test_case "an_axis_with_no_history_is_not_asked_for_a_count" \
    "a field cannot be demanded of records that predate it"
DIR="$(new_sandbox comp_nohistory '{"elixir": {"verdict": "LGTM"}}')"
echo 'defmodule Probe do' > "$DIR/apps/core/lib/probe.ex"
python3 - "$DIR/plans/probe-campaign-state.json" <<'NOHIST'
import json, sys
state = json.load(open(sys.argv[1]))
state["declares_dispatches"] = True
json.dump(state, open(sys.argv[1], "w"), indent=2)
NOHIST
run_gate "$DIR"
assert_not_contains "$OUT" "declares no \`dispatches\` count" \
    "an axis with no log and no dispatch has nothing to reconcile"
assert_contains "$OUT" "records no \`reviewed_at_sha\`" \
    "and is still refused by the check that closes the escape — the narrowing adds no green path"

# ⚠️ A counter that can be reset is a counter that can be made to agree with a
# short log, which would turn the check above into a formality. Monotonicity is
# what makes the baseline mean anything.
test_case "a_dispatch_count_below_its_baseline_is_refused" \
    "a reset counter removes the check instead of satisfying it"
DIR="$(completion_sandbox comp_reset 1 'null' 3)"
run_gate "$DIR"
assert_exit_nonzero "$RC" "a count below its recorded baseline is a violation"
assert_contains "$OUT" "recorded baseline of 3" "the refusal quotes the baseline"
assert_contains "$OUT" "only ever goes up" "and states the invariant"

# ── 11. the sha verifier is self-checked on every run ──────────────────────
#
# ⛔ MEASURED, and the coupling is the lesson. `git rev-parse --verify` RESOLVES
# a short sha and merely ECHOES a full-length one, because 40 hex characters are
# syntactically unambiguous and need no lookup:
#
#     len 12 -> rc=128      len 39 -> rc=128      len 40 -> rc=0, echoed
#
# So **padding a sha removes the check**. I was given a short sha, expanding it
# to 40 characters was the reasonable thing to do, and expanding it is what
# turned a checked input into an unchecked one — at 39 characters the fabricated
# value would have been caught.
#
# ⚠️ And the instrument was easy to trust because its success output IS its
# input: "it resolved" and "it passed through" are byte-identical, so reading
# the output can never distinguish them. Fifteen consecutive OKs was not weak
# evidence, it was zero evidence.
test_case "the_sha_verifier_is_probed_on_every_run" \
    "a verification step is an instrument and needs the same red-run discipline as a gate"
GATE_SRC="$(cat "$GATE")"
assert_contains "$GATE_SRC" "cat-file" "resolution goes through an object lookup"
assert_contains "$GATE_SRC" "^{commit}" \
    "with the peel, which also rejects a sha that exists but is not a commit"
assert_contains "$GATE_SRC" "BOGUS_SHA_PROBE" "and a known-bad input is checked on every run"
assert_contains "$GATE_SRC" "padding a short sha to full length removes" \
    "with the coupling recorded, because that is what stops it recurring"

# ⚠️ Driven, not grepped: the probe must actually discriminate. These are the
# measurements, re-run here so a git upgrade that changed the behaviour would
# red this case rather than silently invalidate the gate's reasoning.
test_case "the_verifier_measurements_still_hold" "a gate's reasoning about a tool must be re-measured, not remembered"
BOGUS="0123456789abcdef0123456789abcdef01234567"
_out=$(git -C "$REPO_ROOT" cat-file -e "${BOGUS}^{commit}" 2>&1); _rc=$?
if [[ $_rc -ne 0 ]]; then
    _record_pass "cat-file -e with the peel REJECTS a fabricated 40-hex sha (rc=$_rc)"
else
    _record_fail "cat-file -e accepted a fabricated sha — the gate's resolver is now vacuous"
fi
_out=$(git -C "$REPO_ROOT" rev-parse --verify "$BOGUS" 2>&1); _rc=$?
if [[ $_rc -eq 0 ]]; then
    _record_pass "and rev-parse --verify still ACCEPTS it, which is why the gate must not use it"
else
    _record_fail "rev-parse --verify now rejects a fabricated sha; the gate's warning is stale and should be re-measured"
fi
_tree=$(git -C "$REPO_ROOT" rev-parse "HEAD^{tree}")
_out=$(git -C "$REPO_ROOT" cat-file -e "${_tree}^{commit}" 2>&1); _rc=$?
if [[ $_rc -ne 0 ]]; then
    _record_pass "and the peel rejects a real TREE object, so the check means 'diffable from'"
else
    _record_fail "the peel accepted a tree object, so it is only checking existence"
fi

# ── 12. definitions live above the main flow, positionally ──────────────────
#
# ⛔ FOUR ORDERING SLIPS IN THIS ONE FILE IN A SINGLE DAY, every one the same
# shape: the script runs top to bottom, its definitions used to be interleaved
# with the flow that uses them, and adding a check meant guessing whether its
# helpers existed yet.
#
# ⚠️ The failure mode is what makes it worth a gate rather than care. The new
# code raises `NameError`, the gate exits NON-ZERO, and a case asserting
# `assert_exit_nonzero` therefore PASSES — so the suite went green on a check
# that had never executed, twice, and the message assertions were the only
# thing that caught it.
#
# So the rule is positional and checkable: nothing below the MAIN FLOW banner
# may define anything.
test_case "no_definition_sits_below_the_main_flow_banner" \
    "a positional rule nothing enforces is a convention, and this one failed four times"
python3 - "$GATE" <<'ORDERING'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

# The embedded python block only; the bash wrapper around it is not in scope.
start = src.index("python3 - ")
start = src.index("\n", start) + 1
end = src.rindex("\nPY\n")
body = src[start:end].split("\n")

BANNER = "# MAIN FLOW — executing code only. No definitions past this line."

# ⛔ EXACTLY ONE MATCH, asserted rather than assumed. The reviewer asked whether
# this check's floor could be satisfied by the wrong REGION, because "MAIN FLOW"
# appears twice in the file — once as the banner and once in the prose above it
# that explains the rule.
#
# MEASURED: the full banner sentence matches once, so the search is right. But
# had it matched the prose mention instead, 7 definitions sit above that point
# against a floor of 8 — so the protection held by a margin of ONE DEFINITION,
# and two more definitions near the top would have silently removed it.
#
# ⚠️ A guard that is correct by margin is a guard that stops being correct
# without anyone touching it. Pinning the match count removes the dependence.
banner_lines = [i for i, l in enumerate(body) if BANNER in l]
if len(banner_lines) != 1:
    print(f"FAIL: the MAIN FLOW banner matches {len(banner_lines)} line(s); expected exactly 1.")
    print("      More than one means the region this check measures is ambiguous, and its")
    print("      floor could be satisfied by the wrong half of the file. Fewer means the")
    print("      banner is gone and there is nothing to measure.")
    raise SystemExit(1)

# ⚠️ No `try` — `next()` cannot raise now that the count above is pinned to
# exactly 1. The guard it used to need is the `!= 1` check, which covers the
# banner being GONE (0 matches) as well as ambiguous (>1). Keeping the handler
# would imply a reachable path that is not, and the next reader would preserve
# it as load-bearing.
banner_at = banner_lines[0]

# A top-level definition: a `def` or an UPPER_SNAKE constant at column zero.
DEFN = re.compile(r"^(def\s+\w+|[A-Z][A-Z0-9_]*\s*=)")
offenders = [
    (i + 1, l[:70]) for i, l in enumerate(body[banner_at:], start=banner_at) if DEFN.match(l)
]
if offenders:
    print(f"FAIL: {len(offenders)} definition(s) sit below the MAIN FLOW banner:")
    for n, text in offenders:
        print(f"  python block line {n}: {text}")
    print("\nMove them into the definitions block above the banner. A definition that works")
    print("today because nothing above it needs one will break the next insertion that does,")
    print("and that break passes an exit-code assertion.")
    raise SystemExit(1)

# ⚠️ Anti-vacuity: if the pattern stopped matching, "no offenders" would be
# indistinguishable from "nothing was read". There must be definitions ABOVE
# the banner for this to have measured anything.
above = [l for l in body[:banner_at] if DEFN.match(l)]
if len(above) < 8:
    print(f"FAIL: only {len(above)} definition(s) found above the banner; expected many.")
    print("      The pattern has probably stopped matching, so a clean result here would")
    print("      mean nothing was read rather than nothing is misplaced.")
    raise SystemExit(1)

print(f"OK: {len(above)} definitions above the banner, 0 below.")
ORDERING
if [[ $? -eq 0 ]]; then
    _record_pass "every constant and helper sits above the banner, and the pattern still matches"
else
    _record_fail "a definition drifted below the main flow — see the FAIL lines above"
fi

# ── the dispatch-count opt-out is a CLAIM, not a convenience ───────────────
#
# ⛔ `declares_dispatches` turns off the harness default that keeps every other
# case from testing the dispatch count by accident. Today two fixtures set it
# and both are genuinely about the count — **correct and unchecked**, which is
# the state an allowlist in this repo was in before seven of its eight stated
# reasons turned out to be false.
#
# ⚠️ The failure it permits lands on the discriminating case directly: a future
# fixture that opts out for convenience silently stops exercising the count
# while reading as a case about it, and every absence assertion still passes
# because nothing fires. Absence assertions cannot notice a check that went
# quiet — that is the whole reason they are paired with a planted red.
#
# Two things are therefore pinned. The number of opt-out sites, so a new one
# must be declared deliberately; and the fact that each of the three count
# refusals is actually ASSERTED somewhere, so the opt-out family cannot drift
# into being all-green. The second is the one that makes the first mean
# something: a declared count of sites that test nothing is just a number.
test_case "the_dispatch_count_opt_out_is_declared_and_exercised" \
    "an opt-out nothing checks is an allowlist with unstated reasons"
SUITE_SRC="$(cat "$0")"
_opt_outs="$(grep -c 'state\["declares_dispatches"\] = True' "$0" || true)"
if [[ "$_opt_outs" -eq "$EXPECTED_DISPATCH_OPT_OUTS" ]]; then
    _record_pass "exactly $EXPECTED_DISPATCH_OPT_OUTS fixture(s) opt out of the dispatch-count default, as declared"
else
    _record_fail "$_opt_outs fixture(s) opt out of the dispatch-count default, expected $EXPECTED_DISPATCH_OPT_OUTS — a new opt-out silently stops testing the count while reading as a case about it; add the case that exercises what it turned off, then update the constant"
fi

# ⚠️ Asserted over this file's own source rather than a run, because each
# refusal is produced by a different fixture and no single run holds all three.
# The claim is "every branch of the count check has a case", which is a
# property of the suite, not of one invocation.
assert_contains "$SUITE_SRC" 'declares no `dispatches` count' \
    "the undeclared-count refusal is asserted by some case"
assert_contains "$SUITE_SRC" 'no `dispatches_baseline`' \
    "the missing-baseline refusal is asserted by some case"
assert_contains "$SUITE_SRC" "a logged reply or a recorded decline" \
    "and the reconciliation refusal, naming both settling outcomes"

summarise
