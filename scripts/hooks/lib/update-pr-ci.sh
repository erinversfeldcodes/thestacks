#!/usr/bin/env bash
# Runs `just ci`, formats results, and updates the open PR's CI summary section.
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

# update_pr_ci_summary <branch>
update_pr_ci_summary() {
    local branch="$1"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    local pr_num
    pr_num="$(gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null)"

    if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
        echo "[hook] No open PR found for branch '$branch' — skipping CI summary update." >&2
        return 0
    fi

    echo "[hook] Running CI checks for PR #${pr_num} (press Ctrl-C to abort, or re-push with --no-verify to skip)..." >&2

    # Run CI, show output on the terminal, capture it.
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

    local new_section
    new_section="$(cat <<EOF
<!-- ci-summary-start -->
${table}

_Last run: ${timestamp} · push \`--no-verify\` to skip_
<!-- ci-summary-end -->
EOF
)"

    local current_body
    current_body="$(gh pr view "$pr_num" --json body --jq '.body')"

    local new_body
    new_body="$(_replace_sentinel "$current_body" "$new_section")"


    echo "[hook] Updating PR #${pr_num} CI summary..." >&2
    gh pr edit "$pr_num" --body "$new_body"
    echo "[hook] Done." >&2
}
