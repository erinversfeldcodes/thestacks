# Issue #015: Claude Code Hooks for Automated Standards Enforcement

## Summary
Standards enforcement (formatting, linting, security scanning) currently relies on the reviewer reading tool output and flagging violations after implementation. Claude Code hooks can shift this enforcement to the point of action — blocking bad writes before they land, not after.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
Standards violations never survive a file write or commit. Entire reviewer revision cycles caused by formatting or credo failures are eliminated. The reviewer's attention is freed for substantive concerns (correctness, performance, security, alternatives) rather than catching things a linter would have caught.

## Technical Requirements

### 15.1 — PreToolUse Hooks (enforce before write)

Claude Code's `PreToolUse` hook fires before a tool call is executed. A failing hook blocks the tool call and returns the error to the agent, which must fix the issue before retrying.

**Elixir formatting:**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'echo \"$CLAUDE_TOOL_INPUT\" | python3 -c \"import json,sys; p=json.load(sys.stdin).get(\\\"file_path\\\",\\\"\\\"); print(p)\" | grep -q \"\\.exs\\?$\" && cd apps/core && mix format --check-formatted \"$CLAUDE_TOOL_INPUT_FILE_PATH\" 2>&1 || true'"
          }
        ]
      }
    ]
  }
}
```

The practical implementation: after each Elixir file write, run `mix format --check-formatted` on the written file. If it fails, the hook output is fed back to the agent as an error, prompting it to re-format before the session continues.

**Approach:** Rather than blocking writes (which would break incremental edits), use a `PostToolUse` hook on Edit/Write for `.ex`/`.exs` files that runs the formatter and fails loudly if formatting is off. The agent sees the failure and corrects it before moving on.

### 15.2 — PostToolUse Hooks (enforce after write)

`PostToolUse` hooks fire after a tool call completes. Suitable for checks that need to see the final file state.

**Per-file checks after edit/write:**

| File type | Hook command |
|-----------|-------------|
| `*.ex`, `*.exs` | `mix format --check-formatted <file>` in `apps/core/` |
| `*.elm` | `elm-format --validate <file>` in `frontend/` |
| `*.rs` | `cargo fmt --check` in `apps/scraper/` |
| `*.py` | `ruff format --check <file>` + `ruff check <file>` in `apps/vision/` |
| `*.proto` | `buf lint proto/` |

Each hook should:
1. Detect the file type from the path
2. Run the appropriate formatter check
3. Exit non-zero with a clear message if the file is not formatted

**Credo after Elixir writes:**
Run `mix credo --strict <file>` after any `.ex`/`.exs` write. Credo issues are surfaced immediately rather than accumulated until the reviewer runs them.

### 15.3 — Stop Hook (pre-commit gate)

Claude Code's `Stop` hook fires when the agent is about to stop responding (end of task). Use this as a pre-commit gate — if the agent has made file changes, run the full lint suite before allowing the session to conclude.

```json
{
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "command": "scripts/hooks/lib/pre-stop-lint.sh"
      }
    ]
  }
}
```

`scripts/hooks/lib/pre-stop-lint.sh`:
- Detects which file types were changed (git diff --name-only)
- Runs the appropriate lint checks for changed files only
- Exits non-zero with a summary if any check fails
- The agent sees the failure and must fix before the session ends

### 15.4 — Hook Configuration File

All hooks live in `.claude/settings.json` (project-level, checked in) so they apply to every agent session without per-session setup.

The hooks file should be structured so each hook is:
- Scoped to specific file patterns where possible (no need to run `mix format` after a Python write)
- Fast — hooks that add >2s to every tool call will be disabled in practice
- Informative on failure — exit messages should name the file and the specific violation

### 15.5 — Hook Error Message Format

Hook failures should output in a format the agent can act on immediately:

```
HOOK FAIL: mix format --check-formatted apps/core/lib/stacks/books.ex
Run: cd apps/core && mix format apps/core/lib/stacks/books.ex
```

Not just an exit code — the agent needs to know what command to run to fix it.

### 15.6 — Extended PostToolUse Hooks

Additional per-file checks to add to `post-tool-lint.sh`:

| File type | Check | Command |
|-----------|-------|---------|
| `*.py` | Type checking | `mypy <file> --ignore-missing-imports` (in `apps/vision/`) |
| `*.rs` | Clippy | `cargo clippy -- -D warnings` (full crate; fast on warm toolchain) |
| `Dockerfile*` | Linting | `hadolint <file>` |
| Any file | Secret detection | `gitleaks detect --no-git --source <file> --log-level error` |
| `*.sql`, `*_migration*.exs` | SQL linting | `sqlfluff lint <file>` (skip gracefully if sqlfluff not installed) |

**Secret detection note:** `gitleaks` runs on every write regardless of file type. It is the last line of defence before a secret is committed. It must be fast — `--no-git --source <file>` scans only the single file, not the repo, so it completes in <0.5s.

**mypy note:** Run only on files inside `apps/vision/` (the only Python in the project). Skip gracefully if mypy is not installed.

**sqlfluff note:** Run on `.sql` files and on Elixir migration files (`.exs` under `priv/repo/migrations/`). Skip gracefully if sqlfluff not installed.

### 15.7 — Extended Stop Hook Checks

Additional full-suite checks to add to `pre-stop-lint.sh` when relevant file types change:

| Trigger | Check | Command |
|---------|-------|---------|
| Any `.ex`/`.exs` change | Dependency audit | `mix deps.audit` in `apps/core/` |
| Any `Dockerfile*` change | IaC scan | `checkov -f <file> --quiet` (skip if checkov not installed) |
| Any `Dockerfile*` change | Hadolint (full) | `hadolint <file>` |
| Any `.rs` change | Dependency audit | `cargo audit` in `apps/scraper/` |
| Any `package*.json` change | npm audit | `npm audit --audit-level=high` in the relevant directory |

## Definition of Done

- [x] `.claude/settings.json` created with `PostToolUse` hooks for Elixir, Elm, Rust, Python, and Protobuf files
- [x] Each hook is scoped to the correct file extensions
- [x] Each hook outputs a fix command on failure, not just an error
- [x] `Stop` hook runs per-language lint on changed files before session ends
- [x] Hook script `scripts/hooks/lib/pre-stop-lint.sh` implemented
- [x] PostToolUse: `mypy` added for Python files
- [x] PostToolUse: `cargo clippy` added for Rust files (graceful skip if cargo absent)
- [x] PostToolUse: `hadolint` added for Dockerfiles
- [x] PostToolUse: `gitleaks` secret scan added for all files
- [x] PostToolUse: `sqlfluff` added for SQL files (graceful skip if absent; migration .exs excluded — sqlfluff cannot parse Elixir)
- [x] Stop hook: `mix deps.audit` added for Elixir changes
- [x] Stop hook: `cargo audit` added for Rust changes
- [x] Stop hook: `checkov` added for Dockerfile changes (graceful skip if absent)
- [x] Stop hook: `npm audit` added for package.json changes
- [x] Hooks tested: deliberately mis-formatted Elixir file triggers PostToolUse hook (exit 2, fix command shown) and pre-commit hook (exit 1, blocks commit)
- [x] Hook execution time verified: PostToolUse Elixir check 0.376s pass / 0.487s fail on warm shell — well under 2s DoD limit
- [x] Git pre-commit hook (`scripts/hooks/pre-commit`) added; installed via `just install-hooks`

## Dependencies
- Claude Code CLI must be in use (hooks are a Claude Code feature)
- Language toolchains must be available in the shell where Claude Code runs (mix, elm-format, cargo fmt, ruff, buf, mypy, hadolint, gitleaks)
- Optional: sqlfluff, checkov (hooks skip gracefully if absent)

## Agent Assignment
- **platform-agent** (`docs/agents/platform-agent.md`) for hook scripts and `.claude/settings.json`
- **Reviewer**: platform-reviewer

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques gap analysis.
- 2026-03-13: Implemented by platform-agent. Reviewer returned NEEDS_REVISION (1 cycle): credo removed from PostToolUse, REPO_ROOT fallback added, sobelow added to Stop hook, untracked files added to diff. One regression (unquoted REPO_ROOT in sobelow bash -c) fixed directly.
- 2026-03-13: §15.6 and §15.7 extended hooks implemented by platform-agent. Reviewer returned NEEDS_REVISION (1 cycle): sqlfluff removed from .exs migration files (cannot parse Elixir), cargo clippy wrapped in `command -v cargo` graceful-skip guard.
- 2026-03-13: git pre-commit hook added (`scripts/hooks/pre-commit`). All DoD items verified: misformatted file triggers hook with correct exit codes and fix commands; PostToolUse timing 0.376s (pass) / 0.487s (fail) on warm shell. Issue complete.
