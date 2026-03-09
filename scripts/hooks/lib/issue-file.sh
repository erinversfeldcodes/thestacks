#!/usr/bin/env bash
# Shared helpers for reading issue files.
# Source this file; do not execute directly.

# find_issue_file <branch>
# Prints the absolute path to the issue file matching the branch name, or empty string.
# Handles branches with a type prefix (refactor/, feat/, fix/, etc.) by stripping
# everything up to and including the first slash before matching.
find_issue_file() {
    local branch="$1"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    # Strip optional type prefix (e.g. refactor/000-slug → 000-slug)
    local slug="${branch#*/}"

    # Exact match on slug: issues/NNN-some-slug.md
    local exact="$repo_root/issues/${slug}.md"
    if [[ -f "$exact" ]]; then
        echo "$exact"
        return
    fi

    # Prefix match by issue number extracted from slug: 042-foo matches issues/042-*.md
    local num
    num="$(echo "$slug" | grep -oE '^[0-9]+')"
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
# Prints the full content of a ## section, preserving line breaks and formatting.
extract_section() {
    local file="$1"
    local heading="$2"
    awk -v h="$heading" '
        $0 ~ ("^## " h) { found=1; next }
        found && /^## /  { exit }
        found            { print }
    ' "$file" | sed 's/^[[:space:]]*$//;s/[[:space:]]*$//'
}

# build_pr_description <issue_file> <gh_issue_number> [ci_section]
# Reads .github/pull_request_template.md and substitutes <!-- pr:field --> markers
# with content extracted from the issue file.
# Goal/Approach/Verification are set once at PR creation and never overwritten —
# only the CI sentinel block is replaced on subsequent pushes via _replace_sentinel.
build_pr_description() {
    local file="$1"
    local issue_num="$2"
    local ci_section="${3:-}"

    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local template="$repo_root/.github/pull_request_template.md"

    if [[ ! -f "$template" ]]; then
        echo "[hook] WARNING: .github/pull_request_template.md not found — PR body will be empty." >&2
        echo "Closes #${issue_num}"
        return
    fi

    local goal approach verification
    goal="$(extract_section "$file" "Goal")"
    approach="$(extract_section "$file" "Technical Requirements")"
    verification="$(extract_section "$file" "Definition of Done")"

    # Write each multi-line substitution to a temp file so awk can insert it cleanly.
    local goal_file approach_file verification_file ci_file
    goal_file="$(mktemp)"
    approach_file="$(mktemp)"
    verification_file="$(mktemp)"
    ci_file="$(mktemp)"

    printf '%s\n' "$goal"         > "$goal_file"
    printf '%s\n' "$approach"     > "$approach_file"
    printf '%s\n' "$verification" > "$verification_file"

    if [[ -n "$ci_section" ]]; then
        printf '%s\n' "$ci_section" > "$ci_file"
    else
        # Keep the placeholder already in the template — write nothing so awk
        # leaves the <!-- pr:* --> marker untouched and the template's own CI
        # sentinel block is preserved as-is.
        : > "$ci_file"
    fi

    awk \
        -v issue_num="$issue_num" \
        -v goal_file="$goal_file" \
        -v approach_file="$approach_file" \
        -v verification_file="$verification_file" \
        -v ci_file="$ci_file" \
        '
        /<!-- pr:issue_num -->/ {
            gsub(/<!-- pr:issue_num -->/, issue_num)
            print; next
        }
        /<!-- pr:goal -->/ {
            while ((getline line < goal_file) > 0) print line
            close(goal_file); next
        }
        /<!-- pr:approach -->/ {
            while ((getline line < approach_file) > 0) print line
            close(approach_file); next
        }
        /<!-- pr:verification -->/ {
            while ((getline line < verification_file) > 0) print line
            close(verification_file); next
        }
        /<!-- ci-summary-start -->/ {
            if (ci_file != "") {
                while ((getline line < ci_file) > 0) print line
                close(ci_file)
                skip=1; next
            }
            print; next
        }
        /<!-- ci-summary-end -->/ {
            if (skip) { skip=0; next }
            print; next
        }
        skip { next }
        { print }
        ' "$template"

    rm -f "$goal_file" "$approach_file" "$verification_file" "$ci_file"
}
