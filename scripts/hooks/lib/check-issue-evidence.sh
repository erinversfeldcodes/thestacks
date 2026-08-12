#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
cd "$REPO_ROOT" 2>/dev/null || exit 0

ISSUE_FILES=$(
  { git diff --name-only HEAD 2>/dev/null
    git diff --name-only --cached 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | grep -E '^issues/.*\.md$' \
    | grep -vE '^issues/complete/' \
    | sort -u
)
[[ -z "$ISSUE_FILES" ]] && exit 0

added_lines() {
  local f="$1"
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    git diff --unified=0 HEAD -- "$f" 2>/dev/null \
      | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^\+//'
  else
    cat "$f" 2>/dev/null
  fi
}

has_evidence() {
  # shellcheck disable=SC2016  # regex is literal by design — no shell expansion wanted
  printf '%s' "$1" | grep -qE '`[^`]+`|_test\.(exs|ex)|\.spec\.ts|[0-9]{4}-[0-9]{2}-[0-9]{2}|#[0-9]+|[0-9]+ (tests?|passed|panels?|series|failures?|families|checks?)|evidence:|proven:'
}

issue_file_exists() {
  local n="$1" g
  for g in "issues/${n}-"*.md; do
    [[ -e "$g" ]] && return 0
  done
  return 1
}

VIOLATIONS=""
add_violation() { VIOLATIONS="${VIOLATIONS}$1"$'\n'; }

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if printf '%s' "$line" | grep -qiE '^[[:space:]]*-[[:space:]]*\[x\]'; then
      if ! has_evidence "$line"; then
        add_violation "  [§9 no-evidence] ${f}:"
        add_violation "      ${line}"
      fi
    fi

    refs=$(printf '%s' "$line" \
      | grep -oiE '(see|tracked in|deferred to|spun (out|into)|follow-up[^#]{0,20}|→)[[:space:]]*#[0-9]+' \
      | grep -oE '#[0-9]+' | tr -d '#')
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      if ! issue_file_exists "$n"; then
        add_violation "  [§10 phantom-ref] ${f}: tracking ref #${n} has no issues/${n}-*.md"
        add_violation "      ${line}"
      fi
    done <<< "$refs"
  done <<< "$(added_lines "$f")"
done <<< "$ISSUE_FILES"

if [[ -n "$VIOLATIONS" ]]; then
  echo "ISSUE-EVIDENCE HOOK — completion-bar violations in added lines:"
  printf '%s' "$VIOLATIONS"
  echo "Fix: attach an evidence token to each checked completion claim (test name / command→output /"
  echo "     live-drive artifact / dated gate); point every tracking #NNN at a real issues/NNN-*.md"
  echo "     (create-issue), or document the deferral in the epic. See docs/agents/standards/completion-bar.md"
  echo "     §9–§10, or run .claude/skills/completion-audit/ to reconcile."
  exit 1
fi
exit 0
