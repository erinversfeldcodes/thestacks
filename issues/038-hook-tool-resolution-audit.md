# Issue #038: Hook & Script Tool Resolution Audit

## Summary
Git hooks and CI scripts assume tools are globally installed, but project-local tools (elm-format in `node_modules/.bin/`, ruff in `.venv/bin/`, modal via pip) aren't on PATH. This causes silent failures or blocked commits. Audit all hooks and scripts to use a consistent project-local-first resolution pattern.

## User Stories
N/A — developer tooling infrastructure.

## Goal
Every hook and script resolves tools from project-local installations first (`node_modules/.bin/`, `.venv/bin/`), falls back to PATH, and skips gracefully with a message if the tool isn't available. No hook failure should ever be caused by a tool not being on PATH when it's installed in the project.

## Technical Requirements

### Files to audit

**Git hooks:**
- `.claude/hooks/post-tool-lint.sh` — elm-format, ruff, mypy, hadolint, cargo
- `scripts/hooks/pre-commit` — elm-format, ruff, cargo, hadolint, mix, buf
- `scripts/hooks/lib/pre-stop-lint.sh` — elm-format, ruff, cargo, hadolint, mix, buf, checkov

**CI scripts:**
- `scripts/lint-elm.sh` — elm-format, elm-review (uses `npx` — OK)
- `scripts/lint-python.sh` — ruff, mypy (uses `.venv/bin/` — OK)
- `scripts/test-elm.sh` — elm-test (uses `npx` — OK)
- `scripts/security.sh` — semgrep, gitleaks, trivy, checkov, hadolint, trufflehog, syft, grype, dockle
- `scripts/cleanup-preview.sh` — modal (`python3 -m modal` — OK), flyctl

**MCP tools:**
- `scripts/mcp/project_tools.py` — `subprocess.run` commands for mix, elm-test, cargo, pytest

### Resolution pattern to apply

For each tool, use this pattern (already applied to elm-format in pre-commit during #011):
```bash
if [[ -x "${REPO_ROOT}/frontend/node_modules/.bin/elm-format" ]]; then
    ELM_FORMAT="${REPO_ROOT}/frontend/node_modules/.bin/elm-format"
elif command -v elm-format > /dev/null 2>&1; then
    ELM_FORMAT="elm-format"
else
    ELM_FORMAT=""
fi
```

### Known issues to fix

1. **elm-format** — partially fixed in #011 (pre-commit only). Still hardcoded in `post-tool-lint.sh` and `pre-stop-lint.sh`.
2. **modal CLI** — `scripts/cleanup-preview.sh` uses `modal app delete` which doesn't exist. Correct command: `modal app stop`. Fixed in working tree during #007 and #011 but keeps getting lost because the fix was never committed.
3. **Security tools** — `trufflehog`, `syft`, `grype`, `dockle`, `dbt-checkpoint` added to Brewfile/setup.sh in #007 but may not be committed on all branches.
4. **project_tools.py** — `subprocess.run` uses `shell=True` with string commands. Fixed to use list commands in #011 but keeps reverting (same uncommitted-fix problem).

## Definition of Done
- [ ] All three hook scripts use project-local-first resolution for: elm-format, ruff, mypy, cargo, mix
- [ ] `scripts/cleanup-preview.sh` uses `modal app stop` (not `modal app delete`)
- [ ] `scripts/mcp/project_tools.py` uses list-based `subprocess.run` (no `shell=True`)
- [ ] `Brewfile` and `setup.sh` include all security scanning tools
- [ ] All hooks pass locally: `bash .claude/hooks/post-tool-lint.sh`, pre-commit on Elm/Python/Rust files
- [ ] CI scripts pass: `scripts/lint-elm.sh`, `scripts/lint-python.sh`, `scripts/security.sh`

## Dependencies
None.

## Agent Assignment
- **platform-agent** (`docs/agents/platform-agent.md`)
- **Reviewer**: platform-reviewer

## Progress Notes
<!-- Updated by agents during execution -->
