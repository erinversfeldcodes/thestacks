# Evaluation: Claude Code Agent Teams — Comparative Trial
**Issue**: #024
**Date**: 2026-03-13
**Status**: In Progress — trial protocol defined, awaiting execution

---

## Approach

Rather than deciding from documentation alone, we run the same real issue through all three orchestration approaches and compare results empirically.

**Test case**: Issue #005 — Neon Preview Branch Data Isolation
- Touches platform (deploy scripts, env vars), Elixir (seed policy), documentation, and Neon infrastructure
- Well-scoped with clear DoD items (7 checkboxes)
- Multi-domain: platform-agent primary, with elixir-agent touchpoint
- Requires real external service interaction (Neon API)

**Three branches, one issue each:**

| Branch | Approach | Description |
|--------|----------|-------------|
| `trial/005-current-orchestrator` | Current prompt-engineered orchestrator | Full orchestrator protocol as-is (Issues #014–#023) |
| `trial/005-agent-teams` | Claude Code Agent Teams | Experimental Agent Teams with teammates per specialist |
| `trial/005-hybrid` | Hybrid | Agent Teams for parallel specialist phases + orchestrator for planning, gates, and mandatory stops |

All three branches start from the same commit on `main`.

---

## Agent Teams Documentation Summary

### What Agent Teams Offers
- **Peer-to-peer messaging**: Teammates message each other directly via a mailbox system
- **Shared task list**: All agents see task status and can claim available work
- **Distributed context windows**: Each teammate has its own context window
- **Plan approval per teammate**: Lead can require plan approval before implementation
- **MCP tool access**: Teammates inherit the lead's MCP server configuration
- **Automatic delivery**: Messages arrive automatically at recipients

### How Teammates Are Defined
- Spawned dynamically via natural language in the lead's prompt (no config files)
- Teammates receive only the spawn prompt (not the lead's conversation history)
- Teammates automatically load project context (CLAUDE.md, MCP servers, skills)

### Current Status
- **Experimental** — disabled by default, requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- Known limitations around session resumption, task coordination, and shutdown behavior

---

## Success Measures

Each branch is scored across these dimensions after implementing Issue #005. Measures are designed to be **observable and comparable**, not subjective.

### 1. Correctness (pass/fail)
- All 7 DoD items from Issue #005 satisfied
- `deploy-preview.sh` creates branches from `staging`, not `main`
- Production seed call gated correctly
- Documentation created and accurate

### 2. Revision Cycles (lower is better)
- Count of times the specialist was sent back (NEEDS_REVISION or regression gate failure)
- Measures how well the approach prevents rework

### 3. Human Intervention Count (lower is better)
- Number of times the human had to step in beyond the mandatory stops
- Includes: resolving conflicts, fixing broken state, correcting agent mistakes, clarifying ambiguity
- Excludes: mandatory stop approvals (those are expected)

### 4. Mandatory Stop Fidelity (pass/fail)
- Did the approach pause for human approval at all required points?
- Did any agent proceed past a checkpoint without explicit human confirmation?
- For Agent Teams: did any teammate continue working while the human was reviewing another teammate's output?

### 5. Total Wall-Clock Time (lower is better)
- Start: first agent invocation
- End: all DoD items satisfied and committed
- Includes human review time at mandatory stops

### 6. Context Window Efficiency (lower is better)
- Approximate token usage across all agent invocations
- For current orchestrator: single session tokens
- For Agent Teams: sum of lead + all teammate tokens
- For hybrid: sum of orchestrator + teammate tokens

### 7. File Conflict Safety (pass/fail)
- Did any agent overwrite another agent's uncommitted changes?
- Were worktrees used effectively to prevent conflicts?
- For Agent Teams: did teammates step on each other's files?

### 8. State Recoverability (pass/fail)
- If the session were interrupted mid-implementation, could work resume?
- Is there a state file or equivalent that captures progress?
- For Agent Teams: would `/resume` restore the full team state?

### 9. Code Quality (subjective — human assessed)
- Is the resulting code clean, well-structured, and idiomatic?
- Are tests adequate?
- Would the code pass the existing reviewer protocol?

### 10. Auditability (subjective — human assessed)
- Can the human trace what happened, in what order, and why?
- Is there a clear record of decisions, approvals, and agent outputs?

---

## Scoring Protocol

After all three branches complete Issue #005:

1. **Quantitative measures** (1–6): Raw numbers, directly comparable
2. **Binary measures** (7–8): Pass/fail per branch
3. **Qualitative measures** (9–10): Human scores 1–5 per branch

**Decision rule:**
- If one branch fails any binary measure (4, 7, 8), it's eliminated unless the failure is attributable to a fixable bug rather than a design limitation
- Among remaining branches, the one with the best combined quantitative score wins
- Ties broken by qualitative scores
- Human has final override authority

---

## Theoretical Decision Matrix (pre-trial)

Based on documentation review, here are the **expected** outcomes. The trial will confirm or refute these.

| Dimension | Current Orchestrator (expected) | Agent Teams (expected) | Hybrid (expected) |
|-----------|-------------------------------|----------------------|-------------------|
| Mandatory stop fidelity | ✅ Pass | ⚠️ Risk — no team-wide pause | ✅ Pass (orchestrator handles) |
| Specialist isolation | ✅ Worktrees | ❌ Shared directory | ✅ Worktrees for specialists |
| Context efficiency | Medium (single window) | Best (distributed) | Medium-high |
| Session resumption | ✅ State files | ❌ Teammates lost on resume | ✅ State files for orchestrator |
| Parallel execution | Good (Agent tool) | Best (native) | Best (native for specialists) |
| Stability | High | Low (experimental) | Medium |

**The trial exists to challenge these expectations with real evidence.**

---

## Trial Execution Plan

### Pre-trial Setup
1. Create three branches from the same `main` commit
2. Enable `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` for branches 2 and 3
3. Ensure Neon API access is configured in all three environments
4. Start a fresh timing log for each branch

### Branch 1: Current Orchestrator
- Invoke the standard orchestrator: `You are The Stacks Orchestrator. Load: docs/agents/orchestrator-agent.md. Task: Issue #005`
- Follow the full protocol: planning → test-first → implement → regression gate → review → commit
- Record all measures as the trial proceeds

### Branch 2: Agent Teams
- Start a Claude Code session with Agent Teams enabled
- Prompt the lead to create a team for Issue #005
- Let the team self-organize (don't impose the orchestrator protocol)
- Observe: does it pause for human approval? Does it handle file isolation? Does it coordinate effectively?
- Record all measures

### Branch 3: Hybrid
- Start with the orchestrator for planning and mandatory stops
- For implementation phases, use Agent Teams to spawn specialist teammates
- Orchestrator handles: planning, gates (regression, spec coverage), review delegation, human stops
- Agent Teams handles: parallel specialist execution within a phase
- Record all measures

### Post-trial
1. Score all three branches against the 10 measures
2. Write results to this document
3. Make the final decision based on evidence

---

## Results

_To be filled in after trial execution._

### Branch 1: Current Orchestrator
| Measure | Result |
|---------|--------|
| Correctness | |
| Revision cycles | |
| Human interventions | |
| Mandatory stop fidelity | |
| Wall-clock time | |
| Context efficiency | |
| File conflict safety | |
| State recoverability | |
| Code quality (1-5) | |
| Auditability (1-5) | |

### Branch 2: Agent Teams
| Measure | Result |
|---------|--------|
| Correctness | |
| Revision cycles | |
| Human interventions | |
| Mandatory stop fidelity | |
| Wall-clock time | |
| Context efficiency | |
| File conflict safety | |
| State recoverability | |
| Code quality (1-5) | |
| Auditability (1-5) | |

### Branch 3: Hybrid
| Measure | Result |
|---------|--------|
| Correctness | |
| Revision cycles | |
| Human interventions | |
| Mandatory stop fidelity | |
| Wall-clock time | |
| Context efficiency | |
| File conflict safety | |
| State recoverability | |
| Code quality (1-5) | |
| Auditability (1-5) | |

---

## Final Decision

_To be filled in after results analysis._

---

## References
- Claude Code Agent Teams documentation
- Claude Code Subagents documentation
- Issue #005 — Neon Preview Branch Data Isolation (test case)
- Issue #022 — Worktree Isolation (current parallel execution approach)
- Issue #017 — Structured State Files (current session resumption)
