#!/usr/bin/env bash
# Creates a GitHub issue and draft PR for a branch on its first push.
# Source this file; do not execute directly.

# shellcheck source=scripts/hooks/lib/issue-file.sh
source "$(git rev-parse --show-toplevel)/scripts/hooks/lib/issue-file.sh"

create_issue_and_pr() {
    local branch="$1"

    local issue_file
    issue_file="$(find_issue_file "$branch")"

    if [[ -z "$issue_file" ]]; then
        echo "[hook] No issue file found for branch '$branch' — skipping issue/PR creation." >&2
        echo "[hook] Create issues/${branch}.md from issues/TEMPLATE.md to enable auto-creation." >&2
        return 0
    fi

    local title
    title="$(extract_issue_title "$issue_file")"
    if [[ -z "$title" ]]; then
        title="$branch"
    fi

    echo "[hook] Creating GitHub issue: $title" >&2
    local issue_url
    issue_url="$(gh issue create \
        --title "$title" \
        --body-file "$issue_file" \
        2>&1)"

    if [[ $? -ne 0 ]] || [[ -z "$issue_url" ]]; then
        echo "[hook] WARNING: Failed to create GitHub issue. Skipping PR creation." >&2
        return 0
    fi

    local issue_num
    issue_num="$(echo "$issue_url" | grep -oE '[0-9]+$')"
    echo "[hook] Issue #${issue_num} created: $issue_url" >&2

    local pr_body
    pr_body="$(build_pr_description "$issue_file" "$issue_num")"

    echo "[hook] Creating draft PR: $title" >&2
    local pr_url
    pr_url="$(gh pr create \
        --draft \
        --title "$title" \
        --body "$pr_body" \
        --base main \
        2>&1)"

    if [[ $? -ne 0 ]]; then
        echo "[hook] WARNING: Failed to create draft PR." >&2
        return 0
    fi

    echo "[hook] Draft PR created: $pr_url" >&2
}
