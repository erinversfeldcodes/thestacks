#!/usr/bin/env bash
# A workflow nobody's pull request depends on can stay red indefinitely.
#
# ⚠️ WHAT NOTHING CHECKED. Eleven of this repository's fifteen workflows have no
# `pull_request` trigger, so no PR ever goes red because of them: the backup
# dump, the staging reseed, production deploy, billing-metrics refresh, branch
# cleanup, both GDPR operator tools, the scheduled core jobs and dbt refresh,
# scorecard and tag-main. Nothing watched their conclusions.
#
# The staging reseed was red for TWO MONTHS and three consecutive runs before a
# human went looking. It failed deterministically — a missing data-corrections
# step meant a constraint validation aborted every time — so it was never going
# to recover on its own, and the only thing between that and a permanent silent
# failure was somebody happening to check.
#
# ⛔ A STALE RED IS NOT A LIVE RED, and conflating them is how this kind of
# check gets switched off. The GDPR lookup tool's last recorded run is a failure
# from 2026-07-19 (`app thestacks-core has no started VMs` — it could not reach a
# machine scaled to zero). That was diagnosed and fixed on 2026-08-12, in a
# commit that added a health-poll warm-up. The workflow simply has not been
# dispatched since, so its last conclusion is still that July red, and reporting
# it as a live failure would be wrong.
#
# So the question is not "is the latest run red" but "is the latest run red AND
# has the definition not changed since". A red that the current definition has
# superseded is reported, loudly, as unverified — because nobody knows whether it
# works now — but it does not fail the check.
#
# ⚠️ Scheduled workflows run from the DEFAULT BRANCH only. A scheduled workflow
# that exists on a feature branch has correctly never run, and reporting that as
# a problem would cry wolf on every unmerged one. The population is therefore
# what the default branch holds, not what the working tree holds.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

DEFAULT_BRANCH="${WORKFLOW_HEALTH_DEFAULT_BRANCH:-origin/main}"

# A fixture path makes the classification logic testable without a network or a
# token. Unset — the normal case — the data comes from `gh`.
FIXTURE="${WORKFLOW_HEALTH_FIXTURE:-}"

if [[ -z "$FIXTURE" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "FAIL workflow-health: the GitHub CLI is not available." >&2
        echo "       Nothing was checked. This is a refusal, not a pass." >&2
        exit 1
    fi
fi

python3 - "$DEFAULT_BRANCH" "$FIXTURE" <<'PY'
import json
import re
import subprocess
import sys

default_branch, fixture = sys.argv[1], sys.argv[2]

WORKFLOW_DIR = ".github/workflows"


def run(args):
    proc = subprocess.run(args, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def workflows_on_default_branch():
    code, out, _ = run(["git", "ls-tree", "-r", "--name-only", default_branch, WORKFLOW_DIR])
    if code != 0:
        # No default-branch ref (a shallow clone, a fresh fork). Fall back to the
        # working tree and say so, rather than silently checking nothing.
        print(
            f"NOTE: {default_branch} is not available; falling back to the working tree.",
            file=sys.stderr,
        )
        code, out, _ = run(["git", "ls-files", WORKFLOW_DIR])
        if code != 0:
            return []
    return [line for line in out.splitlines() if line.endswith((".yml", ".yaml"))]


def triggers(path):
    code, out, _ = run(["git", "show", f"{default_branch}:{path}"])
    if code != 0:
        try:
            out = open(path, encoding="utf-8").read()
        except OSError:
            return set()
    block = re.search(r"^on:\s*\n(.*?)(?=^\S)", out, re.S | re.M)
    body = block.group(1) if block else ""
    return {
        name
        for name in ("pull_request", "push", "schedule", "workflow_dispatch", "workflow_call",
                     "workflow_run")
        if re.search(rf"^\s{{2}}{name}:", body, re.M)
    }


def last_modified(path):
    code, out, _ = run(["git", "log", "-1", "--format=%cI", default_branch, "--", path])
    if code != 0 or not out.strip():
        return None
    return out.strip()


def latest_run(name):
    if fixture:
        with open(fixture, encoding="utf-8") as handle:
            return json.load(handle).get(name)
    code, out, err = run(
        ["gh", "run", "list", "--workflow", name, "--limit", "1",
         "--json", "conclusion,createdAt,event"]
    )
    if code != 0:
        raise SystemExit(
            f"FAIL workflow-health: `gh run list` failed for {name}: {err.strip()}\n"
            "       Nothing was checked for this workflow. This is a refusal, not a pass."
        )
    rows = json.loads(out or "[]")
    if not rows:
        return None
    row = rows[0]
    return {
        "conclusion": row.get("conclusion") or "running",
        "createdAt": row.get("createdAt"),
        "event": row.get("event"),
    }


paths = workflows_on_default_branch()

# ⚠️ Anti-vacuity. Every verdict below is a loop over this list, and an empty
# list produces a clean pass having examined nothing — the exact shape this
# repository keeps finding in its own gates.
if len(paths) < 5:
    print(
        f"FAIL workflow-health: found only {len(paths)} workflow file(s) on {default_branch}.",
        file=sys.stderr,
    )
    print(
        "This repository has far more than that, so a number this low means the enumeration\n"
        "is broken rather than that the workflows are gone.",
        file=sys.stderr,
    )
    raise SystemExit(1)

live_red = []
stale_red = []
never_ran = []
watched = 0

for path in sorted(paths):
    name = path.rsplit("/", 1)[-1]
    trig = triggers(path)

    # A workflow in PR CI already fails somebody's pull request. This check is
    # for the ones that cannot.
    #
    # ⛔ BUT a workflow can have BOTH, and then only half of it is watched. The
    # first version of this check excluded anything with a `pull_request`
    # trigger, which let exactly the hole it was built to close stay open:
    # `cleanup-preview.yml` is PR-triggered AND scheduled, its SCHEDULED job had
    # been failing with `flyctl not on PATH`, and no pull request ever goes red
    # for that job because it is `if: github.event_name != 'pull_request'`.
    # `codeql.yml` has the same shape. So a schedule is always watched; only a
    # purely PR-triggered workflow is skipped.
    if "pull_request" in trig and "schedule" not in trig:
        continue

    watched += 1
    run_info = latest_run(name)

    if run_info is None:
        # Only notable for a workflow that is supposed to fire on its own. A
        # dispatch-only operator tool has correctly never run.
        if "schedule" in trig:
            never_ran.append(name)
        continue

    if run_info["conclusion"] != "failure":
        continue

    changed = last_modified(path)
    created = run_info["createdAt"]

    if changed and created and changed > created:
        stale_red.append((name, created[:10], changed[:10]))
    else:
        live_red.append((name, created[:10] if created else "?", run_info.get("event") or "?"))

if watched == 0:
    print(
        "FAIL workflow-health: every workflow on the default branch is PR-triggered, so this\n"
        "check examined nothing. That is not this repository's shape — the enumeration or the\n"
        "trigger parse has drifted.",
        file=sys.stderr,
    )
    raise SystemExit(1)

for name, created, changed in stale_red:
    print(f"UNVERIFIED {name}: last run failed on {created}, but the workflow changed {changed}.")
    print("           That result predates the current definition, so it says nothing about")
    print("           whether it works now. Dispatch it to find out.")

for name in never_ran:
    print(f"NOTE {name}: scheduled but has never run. Expected while it is newly merged;")
    print("     a problem if it has been on the default branch for more than a day.")

if live_red:
    # Flushed before the failure block so the notes above do not land after it in
    # a log that interleaves the two streams. A reader working out what failed
    # should not have to reorder the output themselves.
    sys.stdout.flush()
    print(
        f"\nFAIL workflow-health: {len(live_red)} workflow(s) are failing with no fix since:",
        file=sys.stderr,
    )
    for name, created, event in live_red:
        print(f"  {name:<34} failed {created} (triggered by {event})", file=sys.stderr)
    print(
        "\nNo pull request goes red for any of these, so nothing else will tell you. The\n"
        "staging reseed sat in exactly this state for two months and three runs: it failed\n"
        "deterministically every time and was never going to recover on its own.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"\nOK: {watched} workflow(s) outside PR CI checked; none failing with the current "
    f"definition ({len(stale_red)} unverified, {len(never_ran)} not yet run)."
)
PY
