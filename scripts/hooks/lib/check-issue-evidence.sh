#!/usr/bin/env bash
# check-issue-evidence.sh — completion-tracking integrity for changed issue files.
#
# Enforces docs/agents/standards/completion-bar.md §9 (evidence tokens) and §10
# (no phantom #NNN) at the edit boundary — the mechanical half of the enforcement
# that stops "documentation lies" (a checked [x] that was never proven; a #NNN with
# no backing file). The adversarial half is the `completion-audit` skill.
#
# Scoped to ADDED lines in changed issues/*.md (git diff vs HEAD; whole file for
# new/untracked). Legacy content is never re-flagged — only the current turn's new
# claims. Bash 3.2-safe (macOS): no mapfile, no associative arrays.
#
# Called by scripts/hooks/lib/pre-stop-lint.sh. Exits non-zero (with a report) on
# any violation, which the Stop hook surfaces back to the agent. Can be run
# standalone for testing: scripts/hooks/lib/check-issue-evidence.sh [REPO_ROOT]
set -uo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
cd "$REPO_ROOT" 2>/dev/null || exit 0

ISSUE_FILES=$(
  { git diff --name-only HEAD 2>/dev/null
    git diff --name-only --cached 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | grep -E '^issues/.*\.md$' | sort -u
)
[[ -z "$ISSUE_FILES" ]] && exit 0

# Emit the ADDED lines of a file (without the leading +). Tracked → diff vs HEAD;
# new/untracked → the whole file.
added_lines() {
  local f="$1"
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    git diff --unified=0 HEAD -- "$f" 2>/dev/null \
      | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^\+//'
  else
    cat "$f" 2>/dev/null
  fi
}

# A concrete evidence token: a `code`/command/file span, a test-file pattern, a
# .spec.ts, a date, a #ref, a numeric result (`231 tests`, `52 panels`), or an
# explicit evidence:/proven: marker. Generic prose ("done", "works") is NOT a token.
has_evidence() {
  # shellcheck disable=SC2016  # regex is literal by design — no shell expansion wanted
  printf '%s' "$1" | grep -qE '`[^`]+`|_test\.(exs|ex)|\.spec\.ts|[0-9]{4}-[0-9]{2}-[0-9]{2}|#[0-9]+|[0-9]+ (tests?|passed|panels?|series|failures?|families|checks?)|evidence:|proven:'
}

# A backing issue file exists for #NNN?  (bash glob, nullglob off → literal on miss)
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

    # §9 — a newly-checked DoD box that cites no evidence token.
    if printf '%s' "$line" | grep -qiE '^[[:space:]]*-[[:space:]]*\[x\]'; then
      if ! has_evidence "$line"; then
        add_violation "  [§9 no-evidence] ${f}:"
        add_violation "      ${line}"
      fi
    fi

    # §10 — a tracking/deferral ref to #NNN with no backing issue file (phantom).
    # Conservative: only deferral phrasings, never a bare/PR ref like 'PR #322'.
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
