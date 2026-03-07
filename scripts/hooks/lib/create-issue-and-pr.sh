#!/usr/bin/env bash
# Creates a GitHub issue and draft PR for a branch on its first push.
# Source this file; do not execute directly.

# shellcheck source=scripts/hooks/lib/issue-file.sh
source "$(git rev-parse --show-toplevel)/scripts/hooks/lib/issue-file.sh"

create_issue_and_pr() {
    local branch="$1"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

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

    # Check whether a GitHub issue with this title already exists — handles the
    # case where a previous push created the issue but failed before creating the PR.
    # Avoids creating a duplicate issue on retry.
    local issue_num
    issue_num="$(gh issue list --search "\"$title\"" --json number,title \
        --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null | head -1)"

    if [[ -n "$issue_num" ]]; then
        echo "[hook] Found existing GitHub issue #${issue_num}: $title" >&2
    else
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

        issue_num="$(echo "$issue_url" | grep -oE '[0-9]+$')"
        echo "[hook] Issue #${issue_num} created: $issue_url" >&2
    fi

    # Run CI before creating the PR so it opens with real results, not a placeholder.
    # run_ci_and_get_section is provided by update-pr-ci.sh, sourced in pre-push.
    echo "[hook] Running CI checks before creating PR (push --no-verify to skip)..." >&2
    local ci_section
    ci_section="$(run_ci_and_get_section "$repo_root")"

    local pr_body
    pr_body="$(build_pr_description "$issue_file" "$issue_num" "$ci_section")"

    # We cannot push the branch from within the pre-push hook — doing so advances
    # the remote ref, which causes git's outer push to fail with a ref-lock error.
    # Instead, spawn a background process that polls git ls-remote until the outer
    # push lands the branch on the remote, then creates the PR.
    #
    # Variables are captured in the subshell at spawn time, so closing over
    # branch/title/pr_body is safe even after this function returns.
    (
        attempts=0
        while [[ $attempts -lt 20 ]]; do
            if git ls-remote --exit-code origin "refs/heads/${branch}" &>/dev/null 2>&1; then
                pr_url="$(gh pr create \
                    --draft \
                    --title "$title" \
                    --body "$pr_body" \
                    --base main \
                    --head "$branch" \
                    2>/dev/null)"
                if [[ -n "$pr_url" ]]; then
                    echo "[hook] Draft PR created: $pr_url" >&2
                else
                    echo "[hook] WARNING: Failed to create draft PR. Run 'git push' again to retry." >&2
                fi
                break
            fi
            sleep 2
            ((attempts++))
        done
        if [[ $attempts -ge 20 ]]; then
            echo "[hook] WARNING: Timed out waiting for branch '$branch' on remote. Run 'git push' again to create the PR." >&2
        fi
    ) &
    disown $!

    echo "[hook] PR creation running in background — check GitHub in a moment." >&2
}
