#!/usr/bin/env bash

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

if echo "$current_body" | grep -q "<!-- deployed-e2e-summary-start -->"; then
    new_body="$(_replace_deployed_e2e_sentinel "$current_body" "$deployed_e2e_section")"
else
    new_body="${current_body}

${deployed_e2e_section}"
fi

gh pr edit "${PR_NUMBER}" --body "$new_body"
echo "PR #${PR_NUMBER} deployed E2E summary updated."
