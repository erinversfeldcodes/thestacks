#!/usr/bin/env bash
# test/platform/ci_migration_safety_job_test.sh
#
# Covers DoD: "`migration-safety` job added to `ci.yml` and runs on all PRs
# that touch `apps/core/priv/repo/migrations/`".
#
# Light structural check: parse .github/workflows/ci.yml and confirm:
#   1. a job named `migration-safety` exists.
#   2. that job references the three Phase 2 scripts:
#        - scripts/security-squawk.sh  (updated destructive rules)
#        - scripts/lint-migrations.sh   (new)
#        - scripts/check-schema-diff.sh (new)
#
# This is a placeholder that WILL FAIL until the workflow is wired up in the
# Phase 2 implementation step. We use python + PyYAML so no extra dependency
# is needed on the dev host (Python is already required by other CI scripts).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

test_case "ci_yml_exists" "ci.yml must be present"
if [[ -f "$CI_YML" ]]; then
    _record_pass "ci.yml exists at $CI_YML"
else
    _record_fail "ci.yml not found at $CI_YML"
    summarise
    exit $?
fi

test_case "migration_safety_job" "job exists with the three expected scripts"
PARSE_OUT=$(python3 - "$CI_YML" <<'PY' 2>&1
import sys, re

path = sys.argv[1]
with open(path) as f:
    txt = f.read()

job_re = re.compile(r"^\s{2,4}migration-safety:\s*$", re.MULTILINE)
if not job_re.search(txt):
    print("MISSING_JOB")
    sys.exit(1)

# 2. Isolate the job body (everything from `migration-safety:` until the next
#    top-level job key at the same indent).
match = job_re.search(txt)
start = match.start()
indent = re.match(r"^(\s+)", match.group(0)).group(1)
rest = txt[match.end():]
next_sibling = re.search(rf"^{indent}\S", rest, re.MULTILINE)
body = rest[: next_sibling.start()] if next_sibling else rest

missing = []
for script in (
    "scripts/security-squawk.sh",
    "scripts/lint-migrations.sh",
    "scripts/check-schema-diff.sh",
):
    if script not in body:
        missing.append(script)

if missing:
    print("MISSING_SCRIPTS:" + ",".join(missing))
    sys.exit(2)

print("OK")
PY
)
RC=$?
assert_exit_zero "$RC" "migration-safety job present and references all three scripts"
if [[ "$PARSE_OUT" == MISSING_JOB* ]]; then
    _record_fail "no top-level \`migration-safety:\` job in ci.yml"
elif [[ "$PARSE_OUT" == MISSING_SCRIPTS:* ]]; then
    _record_fail "migration-safety job is missing script refs: ${PARSE_OUT#MISSING_SCRIPTS:}"
fi

summarise
