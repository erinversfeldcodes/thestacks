#!/usr/bin/env bash
# check-axis-coverage.sh — every changed file of RUNNING CODE must belong to a
# stack-review axis, or the change is reviewed by nobody.
#
# ⛔ WHY THIS EXISTS. `scripts/wave-status.sh`'s STACK_PATHS maps trees to review
# axes, but nothing asserted the INVERSE: that a changed file is IN one of those
# trees. The `config/` layer mapped to no axis and shipped a production defect
# (a storage selector) while every gate stayed green (RL-472); a measured 129 of
# the branch's 758 changed files belonged to no axis at all (RL-450). A module
# the reviewers never see is a blind spot the width of its own diff.
#
# This gate computes the SET DIFFERENCE: changed files, minus the axis trees,
# minus an explicit allowlist of trees that legitimately carry no code axis
# (docs, campaign paperwork, generated artefacts). Anything left is RUNNING CODE
# owned by no reviewer — a failure, named in the output, not a silent pass.
#
# ⚠️ AXIS_PREFIXES must stay in sync with STACK_PATHS in wave-status.sh. They are
# duplicated deliberately: a bash gate cannot safely parse the Python dict, and a
# drift between them is itself a finding this gate's own test can be extended to
# catch. Keep them equal.
set -euo pipefail

BASE="${AXIS_COVERAGE_BASE:-origin/main}"

# Running-code trees that HAVE a review axis (mirror of STACK_PATHS + config/).
AXIS_PREFIXES=(
  "apps/core/lib/" "apps/core/test/" "config/" "apps/core/config/"   # elixir
  "frontend/src/" "frontend/tests/" "apps/core/assets/" "frontend/css/"  # elm (assets = glue, css = styles)
  "apps/core/priv/repo/" "dbt/"                                       # database
  "proto/"                                                            # contract
  "scripts/" ".github/" "justfile" "test/" "e2e/" "setup.sh"          # platform (test/ harness+fixtures, e2e, setup)
  "apps/vision/"                                                      # python
  "apps/scraper/"                                                     # rust
)

# Trees that legitimately carry NO code axis. An entry here is a written decision
# that a reviewer need not cover the tree — add one only when that is true.
ALLOWLIST_PREFIXES=(
  "docs/" "notes/" "plans/" "issues/" "reports/" "research_notes/"    # paperwork
  "apps/core/lib/stacks/gen/" "proto/gen/" "frontend/src/Proto/"      # generated
  ".gitignore" ".gitleaks.toml" "README" "LICENSE" "flake.nix"        # repo meta
  "flake.lock" ".envrc" "nix/" "deploy/" ".mcp.json" ".tool-versions"
  "AGENTS.md" "CLAUDE.md" "mix.lock" ".claude/"
  "apps/core/priv/eval/" "apps/core/priv/grafana/" "apps/core/priv/static/"  # data/dashboards/static
  ".env.example" "e2e/package" "e2e/tsconfig" "e2e/.gitignore"
  "images/"  # the vision eval corpus (owner-shot photos + dataset planning docs) — data, not code
)

matches_any() { local f="$1"; shift; local p; for p in "$@"; do [[ "$f" == "$p"* || "$f" == "$p" ]] && return 0; done; return 1; }

mapfile -t CHANGED < <(git diff --name-only "$BASE...HEAD" 2>/dev/null || git diff --name-only "$BASE" 2>/dev/null)

unowned=()
for f in "${CHANGED[@]}"; do
  [[ -z "$f" ]] && continue
  matches_any "$f" "${AXIS_PREFIXES[@]}" && continue
  matches_any "$f" "${ALLOWLIST_PREFIXES[@]}" && continue
  unowned+=("$f")
done

if ((${#unowned[@]})); then
  echo "FAIL: ${#unowned[@]} changed file(s) belong to NO review axis and are not allowlisted:" >&2
  printf '   %s\n' "${unowned[@]}" >&2
  echo "Fix: map the tree to an axis in STACK_PATHS (wave-status.sh) + AXIS_PREFIXES here," >&2
  echo "or, if it genuinely needs no code review, add it to ALLOWLIST_PREFIXES with that reason." >&2
  exit 1
fi
echo "OK: all ${#CHANGED[@]} changed file(s) belong to a review axis or an allowlisted tree."
