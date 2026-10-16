#!/usr/bin/env bash
# test/platform/scheduled_core_jobs_test.sh
#
# The workflow that runs the duties the core node cannot schedule for itself.
#
# `deploy/fly.core.toml` sets `min_machines_running = 0`, and `Oban.Plugins.Cron`
# computes due jobs on a tick from a RUNNING node with no catch-up pass — so an
# Oban crontab entry fires only if something else happened to wake the machine
# in that minute. A machine woken at 06:03 never runs the 06:00 entry.
#
# This suite covers the ways THIS workflow could be green and useless, which are
# not the same as the dbt refresh's:
#
#   1. The run does not know which duty it owes. Two cron expressions feed one
#      job, so a mistyped one would silently run the wrong duty every night and
#      report success.
#   2. `fly ssh console -C` returns the SSH exit status, which is not reliably
#      the remote command's. An rpc whose task raised can therefore exit 0, so
#      the sentinel line has to be checked as well.
#   3. The metric is stamped for work that did not happen — an `if: always()`
#      on the push step, or a push that writes an empty payload and succeeds.
#
# The pairing invariant (a duty removed from the crontab has a workflow running
# it) lives in `apps/core/test/core/scheduled_duty_pairing_test.exs`, because it
# has to read the Oban config.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/scheduled-core-jobs.yml"
RELEASE="$REPO_ROOT/apps/core/lib/stacks/release.ex"
CONFIG="$REPO_ROOT/apps/core/config/config.exs"

test_case "files_exist" "the workflow, the release tasks and the Oban config are present"
assert_path_exists "$WORKFLOW" "the scheduled-core-jobs workflow exists"
assert_path_exists "$RELEASE" "the release module exists"
assert_path_exists "$CONFIG" "the Oban config exists"

WF="$(cat "$WORKFLOW" 2>/dev/null)"
REL="$(cat "$RELEASE" 2>/dev/null)"

# ⚠️ The workflow with its COMMENTS STRIPPED, for absence assertions only.
#
# This is not tidiness. The `if: always()` assertion below failed on first run
# — correctly — because the workflow's own comment explains why `if: always()`
# would be wrong, and a search over the whole file found that sentence. A gate
# that reads a comment as configuration is this repository's most frequently
# repeated defect, and it has now happened to a lint, to a YAML verifier, to an
# async-declaration check and to this suite.
#
# Presence assertions deliberately keep using the full text: a sentinel string
# or a cron expression is real wherever it appears, and stripping comments there
# would only make the needles harder to find.
WF_CODE="$(printf '%s\n' "$WF" | sed 's/[[:space:]]*#.*$//')"

# ── the duties are actually invoked ──────────────────────────────────────────

test_case "each_duty_calls_a_release_task" "the workflow runs named release tasks, not inline code"
assert_contains "$WF" "Stacks.Release.refresh_costs()" \
    "the costs duty invokes its release task"
assert_contains "$WF" "Stacks.Release.discover_bookstore_events()" \
    "the bookstore-events duty invokes its release task"

test_case "the_release_tasks_exist" "every task the workflow names is defined"
assert_contains "$REL" "def refresh_costs" "refresh_costs/0 is defined"
assert_contains "$REL" "def discover_bookstore_events" "discover_bookstore_events/0 is defined"

# ── an rpc that failed must not read as success ──────────────────────────────
#
# What each check catches, measured against the deployed node on 2026-10-16
# rather than assumed:
#
#   * The exit code is real evidence. `rpc 'raise "..."'` came back as exit 1
#     with the stacktrace on stdout.
#   * It does NOT catch a task that RETURNS a failure instead of raising —
#     `{:error, _}` leaves `rpc` exiting 0. That is why the release task raises,
#     and why the sentinel is checked too: it is printed only on the success
#     path, so its absence catches any quiet-failure route, including one added
#     later by someone making the task "more forgiving".
#
# Both are asserted because they fail on different things, not because either
# is unreliable.

test_case "exit_code_is_checked" "a non-zero rpc exit fails the step"
assert_contains "$WF" 'if [[ $rc -ne 0 ]]; then' "the rpc exit code is tested"

test_case "sentinel_is_checked" "a missing completion line fails the step"
assert_contains "$WF" "COSTS_REFRESH_ITEMS" "the costs step looks for its sentinel"
assert_contains "$WF" "BOOKSTORE_EVENTS_SWEEP ok" "the sweep step looks for its sentinel"

test_case "the_release_tasks_emit_those_sentinels" "the sentinels the workflow greps for are printed"
# ⚠️ Both halves, in both files. A grep for a sentinel the task never prints is
# a step that always fails; a task printing a sentinel nobody greps for is a
# step that always passes. Either way the pair has to agree, and only checking
# one side cannot tell.
assert_contains "$REL" 'IO.puts("COSTS_REFRESH_ITEMS' "refresh_costs prints its sentinel"
assert_contains "$REL" 'IO.puts("BOOKSTORE_EVENTS_SWEEP ok")' "the sweep prints its sentinel"

test_case "a_failed_costs_refresh_raises" "the release task fails loudly rather than reporting"
# A task that returned `{:error, _}` quietly would leave the rpc exiting 0 with
# no sentinel; raising is what makes the exit code mean something.
assert_contains "$REL" 'raise "costs refresh failed' "refresh_costs raises on failure"

test_case "zero_rows_is_a_failure" "a refresh that wrote nothing is not a success"
# The far-end assertion. This project has shipped a pipeline that was green for
# months while delivering nothing, so the count comes from the table and a zero
# fails rather than being reported.
assert_contains "$WF" "costs refresh wrote no rows" "an empty platform_costs fails the step"

# ── the run knows which duty it owes ─────────────────────────────────────────

test_case "the_plan_step_refuses_the_unknown" "an unrecognised trigger fails instead of defaulting"
# ⚠️ The failure this guards is quiet. Two cron expressions feed one job and are
# matched as strings, so a typo in either would fall through to the default
# branch. Defaulting there would run the wrong duty every night and report
# success for it; refusing turns the typo into a red run on the first fire.
assert_contains "$WF" "cannot tell what to run" "the plan step errors on an unknown trigger"

test_case "both_schedules_are_declared" "each duty keeps the cadence its crontab entry had"
assert_contains "$WF" 'cron: "0 6 * * *"' "costs stays daily at 06:00, as the Oban entry was"
assert_contains "$WF" 'cron: "30 7 * * 1"' "the sweep stays Monday 07:30, as the Oban entry was"

test_case "every_declared_cron_is_matched_by_the_plan_step" "no schedule can fire with no duty"
# The real coupling, checked rather than eyeballed: each `- cron:` expression
# must appear again in the plan step's `case`. A schedule added above without a
# branch below fires nightly straight into the refusal.
CRONS="$(printf '%s\n' "$WF" | grep -oE '^ *- cron: "[^"]+"' | sed 's/.*"\(.*\)"/\1/')"
CRON_COUNT=0
UNMATCHED=""
while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    CRON_COUNT=$((CRON_COUNT + 1))
    # The branch form is `"<cron>:"*)`, so search for the expression followed by
    # a colon — distinct from the `- cron:` declaration itself.
    if [[ "$WF" != *"\"${c}:\""* ]]; then
        UNMATCHED="${UNMATCHED}${c}; "
    fi
done <<<"$CRONS"

if [[ "$CRON_COUNT" -lt 2 ]]; then
    _record_fail "found $CRON_COUNT cron expression(s) in the workflow — expected at least two, so this sweep is not reading the schedule block it is written for"
elif [[ -n "$UNMATCHED" ]]; then
    _record_fail "these cron expressions have no branch in the plan step, so they would fire into the refusal: ${UNMATCHED}"
else
    _record_pass "all $CRON_COUNT declared schedules have a matching branch"
fi

# ── the metric must not outrun the work ──────────────────────────────────────

test_case "the_push_is_not_unconditional" "a failed run does not stamp a success timestamp"
# `if: always()` here would write `last_success` after a failed step, which is
# the one thing the gauge must never say. `success()` is the implicit default,
# so the assertion is that nothing overrides it.
assert_not_contains "$WF_CODE" "if: always()" \
    "no step runs unconditionally — a last_success gauge stamped after a failure is worse than no gauge"

test_case "the_comment_stripping_did_not_eat_the_file" "the absence assertion above looked at real content"
# Anti-vacuity for the stripped corpus: an over-eager `sed` would leave an empty
# string, in which every absence assertion passes. The `if:` conditions are the
# load-bearing lines in this workflow, so their survival is the right witness.
assert_contains "$WF_CODE" "steps.plan.outputs.costs == 'true'" \
    "the stripped corpus still carries the step conditions, so it is not empty"

test_case "an_empty_payload_fails" "a push with nothing in it is not a successful push"
assert_contains "$WF" "no metrics to push" \
    "an empty metrics payload fails rather than curling an empty body successfully"

test_case "each_duty_pushes_its_own_gauge" "a skipped duty's gauge stops moving"
assert_contains "$WF" "stacks_costs_refresh_last_success_timestamp_seconds" \
    "the costs duty has a last_success gauge"
assert_contains "$WF" "stacks_bookstore_events_sweep_last_success_timestamp_seconds" \
    "the sweep has its own last_success gauge"

# ── the node has to be awake for any of this ─────────────────────────────────

test_case "the_app_is_woken_over_http" "the wake step uses the only mechanism that works"
# ⚠️ `fly ssh console` does NOT trigger Fly's auto-start — only HTTP through the
# proxy does — so an rpc against a sleeping app dies with "no started VMs".
# Asserting the mechanism, not merely that some wake step exists.
assert_contains "$WF" "/api/health" "the wake step hits the health endpoint over HTTP"
assert_contains "$WF" "did not come up after" "a node that never wakes fails the run"

# ── concurrency ──────────────────────────────────────────────────────────────

test_case "runs_do_not_overlap" "two runs cannot reach the node at once"
assert_contains "$WF" "concurrency:" "a concurrency group is declared"
assert_contains "$WF" "cancel-in-progress: false" \
    "an in-flight run is not cancelled — a half-finished cost upsert is worse than a late one"

summarise
