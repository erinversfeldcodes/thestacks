#!/usr/bin/env bash
# CI running, report formatting, and PR description updating.
# Source this file; do not execute directly.

# _strip_ansi <string>
_strip_ansi() {
    sed 's/\x1b\[[0-9;]*[mK]//g'
}

# _parse_ci_output <output>
# Emits a markdown table of check results.
_parse_ci_output() {
    local output
    output="$(echo "$1" | _strip_ansi)"

    local table
    table="| Check | Status |"$'\n'"| --- | --- |"

    while IFS= read -r line; do
        if [[ "$line" =~ ^PASS[[:space:]]+(.*) ]]; then
            table+=$'\n'"| ${BASH_REMATCH[1]} | ✅ passed |"
        elif [[ "$line" =~ ^FAIL[[:space:]]+(.*) ]]; then
            table+=$'\n'"| ${BASH_REMATCH[1]} | ❌ failed |"
        fi
    done <<< "$output"

    echo "$table"
}

# _replace_sentinel <current_body> <new_section>
# Replaces everything between (and including) the sentinel comments with new_section.
_replace_sentinel() {
    local body="$1"
    local new_section="$2"

    local body_file new_file out_file
    body_file="$(mktemp)"
    new_file="$(mktemp)"
    out_file="$(mktemp)"

    printf '%s\n' "$body"        > "$body_file"
    printf '%s\n' "$new_section" > "$new_file"

    awk -v newfile="$new_file" '
        /<!-- ci-summary-start -->/ {
            while ((getline line < newfile) > 0) print line
            close(newfile)
            skip=1; next
        }
        /<!-- ci-summary-end -->/ { skip=0; next }
        !skip                     { print }
    ' "$body_file" > "$out_file"

    cat "$out_file"
    rm -f "$body_file" "$new_file" "$out_file"
}

# run_ci_and_get_section <repo_root>
# Runs `just ci`, prints output to the terminal, and returns the formatted
# ci-summary sentinel block (including the sentinel comments) on stdout.
# Shared by create_issue_and_pr (first push) and update_pr_ci_summary (subsequent pushes).
run_ci_and_get_section() {
    local repo_root="$1"

    local tmpfile
    tmpfile="$(mktemp)"
    just --justfile "$repo_root/justfile" ci 2>&1 | tee /dev/tty > "$tmpfile" || true
    local ci_output
    ci_output="$(cat "$tmpfile")"
    rm -f "$tmpfile"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M')"

    local table
    table="$(_parse_ci_output "$ci_output")"

    cat <<EOF
<!-- ci-summary-start -->
${table}

_Last run: ${timestamp} · push \`--no-verify\` to skip_
<!-- ci-summary-end -->
EOF
}

# update_pr_ci_summary <branch> <pr_num>
# Used on subsequent pushes — updates the CI summary section of an open PR.
# pr_num is passed in from the pre-push hook to avoid a redundant gh pr list call.
update_pr_ci_summary() {
    local branch="$1"
    local pr_num="$2"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    echo "[hook] Running CI checks for PR #${pr_num} (push --no-verify to skip)..." >&2

    local ci_section
    ci_section="$(run_ci_and_get_section "$repo_root")"

    local current_body
    current_body="$(gh pr view "$pr_num" --json body --jq '.body')"

    local new_body
    new_body="$(_replace_sentinel "$current_body" "$ci_section")"

    echo "[hook] Updating PR #${pr_num} CI summary..." >&2
    gh pr edit "$pr_num" --body "$new_body"
    echo "[hook] Done." >&2
}
