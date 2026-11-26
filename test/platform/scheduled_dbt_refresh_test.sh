#!/usr/bin/env bash
# test/platform/scheduled_dbt_refresh_test.sh
#
# The daily warehouse refresh, and the one thing about it that is not an
# engineering preference: its cadence is a GDPR commitment.
#
# docs/runbooks/gdpr-erase-user.md tells an operator — and through them a data
# subject — that warehouse copies of an erased user's data disappear within 24
# hours. Nothing makes that true except this workflow's `cron`. The promise was
# already wrong once, in the opposite direction: the runbook quoted ≤24h on the
# strength of an Oban crontab entry that could not possibly have run, and the
# claim was satisfied only by there being no warehouse at all.
#
# So the coupling is asserted here rather than left to whoever edits the cron
# remembering a paragraph in a different file.
#
# The rest of this suite covers the three ways a scheduled refresh can be green
# and useless: no concurrency guard, the orphan sweep not actually invoked, and
# no far-end assertion that the build produced anything.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/scheduled-dbt-refresh.yml"
RUNNER="$REPO_ROOT/scripts/dbt-deployed.sh"
RUNBOOK="$REPO_ROOT/docs/runbooks/gdpr-erase-user.md"

test_case "files_exist" "the workflow, its runner and the runbook are all present"
assert_path_exists "$WORKFLOW" "the scheduled refresh workflow exists"
assert_path_exists "$RUNNER" "the deployed-dbt runner exists"
assert_path_exists "$RUNBOOK" "the erasure runbook exists"

WF="$(cat "$WORKFLOW" 2>/dev/null)"

# --- the cadence IS the erasure SLA ---------------------------------------

CRON="$(printf '%s\n' "$WF" | grep -oE '^ *- cron: "[^"]+"' | head -1 | sed 's/.*"\(.*\)"/\1/')"

test_case "cron_is_daily" "the schedule runs at least once a day"
# Fields: minute hour dom month dow. Daily means dom, month and dow are all
# unrestricted and the hour is a single value — anything else is a longer
# interval than the runbook promises.
dom="$(echo "$CRON" | awk '{print $3}')"
mon="$(echo "$CRON" | awk '{print $4}')"
dow="$(echo "$CRON" | awk '{print $5}')"
hour="$(echo "$CRON" | awk '{print $2}')"

if [[ "$dom" == "*" && "$mon" == "*" && "$dow" == "*" && "$hour" != *","* && "$hour" != *"/"* ]]; then
    _record_pass "cron '$CRON' fires once every day"
else
    _record_fail "cron '$CRON' does not fire daily — the runbook's 24-hour erasure window is no longer true. Change the runbook too."
fi

test_case "runbook_states_the_same_cron" "the runbook quotes the cron it depends on"
# The literal cron string, so an edit to the workflow that is not mirrored in
# the runbook fails here. Asserting "the runbook mentions 24 hours" would not:
# that sentence survives any cadence change.
assert_contains "$(cat "$RUNBOOK" 2>/dev/null)" "$CRON" \
    "the runbook names the actual cron expression ('$CRON'), so a cadence change cannot land without it"

test_case "runbook_points_at_the_gauge" "the runbook says how to check the refresh ran"
assert_contains "$(cat "$RUNBOOK" 2>/dev/null)" \
    "stacks_dbt_refresh_last_success_timestamp_seconds" \
    "the runbook names the freshness gauge rather than telling the reader to trust a green badge"

# --- the three ways a scheduled job is green and useless -------------------

test_case "concurrency_guard" "two runs cannot overlap"
assert_contains "$WF" "concurrency:" "the workflow declares a concurrency group"
assert_contains "$WF" "cancel-in-progress: false" \
    "an in-flight build is allowed to finish rather than being killed mid-write"

test_case "orphan_sweep_is_invoked" "the orphan sweep has a caller"
# ⚠️ The macro existed, was proven on a dev database, and was invoked by
# nothing. A runner with no caller is this project's recurring defect, so the
# assertion is on the INVOCATION, not on the macro file existing.
assert_path_exists "$REPO_ROOT/dbt/macros/drop_orphan_relations.sql" "the macro exists"
assert_contains "$(cat "$RUNNER" 2>/dev/null)" "run-operation drop_orphan_relations" \
    "the runner invokes the orphan sweep"
assert_contains "$(cat "$RUNNER" 2>/dev/null)" "dry_run: false" \
    "the sweep is run in apply mode, not only reported"

test_case "sweep_precedes_build" "orphans are dropped BEFORE models are built"
# Order matters: building first leaves stale relations in place for the whole
# run, reading from sources that no longer exist, failing on SELECT rather than
# on build and therefore invisible to every gate.
sweep_line="$(grep -n "run-operation drop_orphan_relations --args" "$RUNNER" | head -1 | cut -d: -f1)"
build_line="$(grep -n '^if ! dbt build' "$RUNNER" | head -1 | cut -d: -f1)"
if [[ -n "$sweep_line" && -n "$build_line" && "$sweep_line" -lt "$build_line" ]]; then
    _record_pass "the sweep (line $sweep_line) runs before the build (line $build_line)"
else
    _record_fail "could not establish that the sweep precedes the build (sweep=$sweep_line build=$build_line)"
fi

# ⚠️ The daily pass must be a FULL refresh, and this is a correctness and
# erasure assertion rather than a preference.
#
# Both incremental marts window on the surviving rows' created_at/updated_at. A
# DELETE upstream updates no surviving row, so a deleted entity never enters the
# window and its mart row persists forever. Measured: a book's read_count read
# 3, one placement was hard-deleted (what an account erasure's FK cascade does),
# the true count became 2, an incremental refresh selected nothing, and the mart
# still read 3. With --full-refresh it reads 2.
#
# So without this flag every erasure permanently inflates the community read
# count of every book that user had shelved — silently, and with
# `test_mart_community_read_count_excludes_removed` passing throughout, because
# that test covers the soft-removal path rather than the deletion one.
test_case "daily_pass_is_a_full_refresh" "the daily runner rebuilds rather than appends"
assert_contains "$(cat "$RUNNER" 2>/dev/null)" "dbt build --full-refresh" \
    "the daily refresh is a full rebuild, so a deleted row cannot persist in an incremental mart"

test_case "far_end_assertion" "the run checks the database, not just dbt's exit code"
assert_contains "$WF" "marts.mart_community_read_count" \
    "the workflow queries the mart it is supposed to have built"
assert_contains "$WF" "the marts schema holds no relations" \
    "an empty marts schema after a successful build fails the run"

test_case "freshness_gauge_pushed" "the run publishes a far-end value"
assert_contains "$WF" "stacks_dbt_refresh_last_success_timestamp_seconds" \
    "the workflow pushes the freshness gauge"
assert_contains "$WF" "stacks_dbt_refresh_mart_rows" \
    "the row count is published too, so a persistent empty mart is visible"

# --- the runner refuses to build a local database -------------------------

test_case "local_host_refused" "a deployed runner will not quietly build localhost"
# The phantom `--target preview` it replaces could never resolve; the failure
# mode of the replacement is the mirror image — succeeding against a database
# nobody deploys. Exit 2 is "nothing was run", distinct from 0 and from 1.
OUT="$(DATABASE_URL="postgres://u:p@localhost:5432/x" bash "$RUNNER" 2>&1)"
RC=$?
if [[ "$RC" -eq 2 ]]; then
    _record_pass "exit 2 (nothing ran), distinct from 0 and from a build failure"
else
    _record_fail "expected exit 2 for a local DATABASE_URL, got $RC"
fi
assert_contains "$OUT" "Nothing was run" "the output says in words that nothing happened"

test_case "missing_url_refused" "no DATABASE_URL means nothing runs"
OUT="$(env -u DATABASE_URL bash "$RUNNER" 2>&1)"
RC=$?
if [[ "$RC" -eq 2 ]]; then
    _record_pass "exit 2 with no DATABASE_URL"
else
    _record_fail "expected exit 2 with no DATABASE_URL, got $RC"
fi

# --- the dbt version is one fact ------------------------------------------

test_case "dbt_version_pinned_once" "the workflow and setup.sh install the same dbt"
assert_path_exists "$REPO_ROOT/dbt/requirements.txt" "the pin file exists"
assert_contains "$WF" "pip install --quiet -r dbt/requirements.txt" \
    "the workflow installs from the pin file"
assert_contains "$(cat "$REPO_ROOT/setup.sh" 2>/dev/null)" "dbt/requirements.txt" \
    "setup.sh installs from the same pin file, so a developer's dbt matches production's"

summarise
