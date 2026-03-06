#!/usr/bin/env bash
# Shared helpers for reading issue files.
# Source this file; do not execute directly.

# find_issue_file <branch>
# Prints the absolute path to the issue file matching the branch name, or empty string.
find_issue_file() {
    local branch="$1"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    # Exact match: issues/NNN-some-slug.md
    local exact="$repo_root/issues/${branch}.md"
    if [[ -f "$exact" ]]; then
        echo "$exact"
        return
    fi

    # Prefix match by issue number: branch 042-foo matches issues/042-*.md
    local num
    num="$(echo "$branch" | grep -oE '^[0-9]+')"
    if [[ -n "$num" ]]; then
        local found
        found="$(find "$repo_root/issues" -maxdepth 1 -name "${num}-*.md" | head -1)"
        echo "$found"
    fi
}

# extract_issue_title <file>
# Prints the human title from "# Issue #NNN: Title Here"
extract_issue_title() {
    grep -m1 "^# Issue" "$1" | sed 's/^# Issue #[0-9]*:[[:space:]]*//'
}

# extract_section <file> <heading>
# Prints the content of a ## section (strips blank lines, collapses whitespace).
extract_section() {
    local file="$1"
    local heading="$2"
    awk -v h="$heading" '
        $0 ~ ("^## " h) { found=1; next }
        found && /^## /  { exit }
        found && NF      { print }
    ' "$file" | head -10 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# build_pr_description <issue_file> <gh_issue_number>
# Prints the initial PR body (≤100 words of prose + CI sentinel).
build_pr_description() {
    local file="$1"
    local issue_num="$2"

    local goal approach verification
    goal="$(extract_section "$file" "Goal")"
    approach="$(extract_section "$file" "Technical Requirements")"
    verification="$(extract_section "$file" "Definition of Done")"

    # Truncate combined prose to 100 words
    local prose
    prose="$(printf "**Goal**: %s\n\n**Approach**: %s\n\n**Verification**: %s" \
        "$goal" "$approach" "$verification")"

    cat <<EOF
Closes #${issue_num}

${prose}

<!-- ci-summary-start -->
⏳ CI checks not yet run. Push without \`--no-verify\` to run checks.
<!-- ci-summary-end -->
EOF
}
