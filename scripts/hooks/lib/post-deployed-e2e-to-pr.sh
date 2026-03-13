#!/usr/bin/env bash
# scripts/hooks/lib/post-deployed-e2e-to-pr.sh
#
# Called by the deploy-preview GitHub Actions job after deploy-preview.sh runs.
# Reads the deploy-preview output (written to /tmp/deploy-preview-output.txt
# by the preceding step) and posts the results to the open PR in the
# <!-- deployed-e2e-summary-start/end --> sentinel block.
#
# Required env vars:
#   GH_TOKEN   — GitHub token (secrets.GITHUB_TOKEN in Actions)
#   PR_NUMBER  — PR number (github.event.pull_request.number)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Source shared helpers
# shellcheck source=scripts/hooks/lib/update-pr-ci.sh
source "$REPO_ROOT/scripts/hooks/lib/update-pr-ci.sh"

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "ERROR: GH_TOKEN not set." >&2
    exit 1
fi

if [[ -z "${PR_NUMBER:-}" ]]; then
    echo "ERROR: PR_NUMBER not set." >&2
    exit 1
fi

# The deploy-preview step writes its output to /tmp/deploy-preview-output.txt
OUTPUT_FILE="/tmp/deploy-preview-output.txt"
if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "WARNING: $OUTPUT_FILE not found — no deploy preview output to post." >&2
    exit 0
fi

deploy_output="$(cat "$OUTPUT_FILE")"
timestamp="$(date '+%Y-%m-%d %H:%M')"
table="$(_parse_ci_output "$deploy_output")"

deployed_e2e_section="$(cat <<EOF
<!-- deployed-e2e-summary-start -->
${table}

_Last deployed: ${timestamp}_
<!-- deployed-e2e-summary-end -->
EOF
)"

current_body="$(gh pr view "${PR_NUMBER}" --json body --jq '.body')"

# Inject or replace the deployed-e2e sentinel block
if echo "$current_body" | grep -q "<!-- deployed-e2e-summary-start -->"; then
    new_body="$(_replace_deployed_e2e_sentinel "$current_body" "$deployed_e2e_section")"
else
    new_body="${current_body}

${deployed_e2e_section}"
fi

gh pr edit "${PR_NUMBER}" --body "$new_body"
echo "PR #${PR_NUMBER} deployed E2E summary updated."
