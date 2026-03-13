# Evaluation: Claude Code Agent Teams — Comparative Trial
**Issue**: #024
**Date**: 2026-03-13
**Status**: Complete

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

### Consolidated Scoring

| # | Measure | Current Orchestrator | Agent Teams | Hybrid |
|---|---------|---------------------|-------------|--------|
| 1 | Correctness | **PASS** | **PASS** | **PASS** |
| 2 | Revision cycles | 0 | 0 | 0 |
| 3 | Human interventions | 0 | 1 | 0 |
| 4 | Mandatory stop fidelity | **PASS** | **PASS (qualified)** | **PASS** |
| 5 | Wall-clock time | ~18 min | ~2h 10m* | ~15 min |
| 6 | Context efficiency | ~42k tokens + orchestrator | Medium-high (3 windows) | Medium-high (3 windows) |
| 7 | File conflict safety | **PASS** | **PASS** | **PASS** |
| 8 | State recoverability | **PASS** | **FAIL** | **PASS (qualified)** |
| 9 | Code quality (1–5) | Pending human | Pending human | Pending human |
| 10 | Auditability (1–5) | Pending human | Pending human | Pending human |

*Agent Teams wall-clock time was dominated by an external blocker (Modal billing HTTP 429) causing two failed deploy cycles. Implementation time alone was ~6 min, comparable to the other approaches.

### Branch 1: Current Orchestrator

Full report: [`005-current-orchestrator.md`](005-current-orchestrator.md)

- All 7 DoD items satisfied, 9/9 E2E tests passed on first deploy attempt.
- Zero revision cycles, zero human interventions.
- Mandatory stops enforced by orchestrator protocol. State file tracked all phases.
- **Code quality caveat**: the code comparison ([`005-trial-code-comparison.md`](005-trial-code-comparison.md)) revealed a **functional bug** — the deploy script does not pass `ALLOW_SEEDS=true` when invoking `seed/0` on the preview machine. This is masked by the lenient gate (`MIX_ENV != "prod"` fallback) but would fail in any environment where `MIX_ENV=prod`. The orchestrator treated deploy script and seed gate as independent phases and missed the integration point.
- Friction: executed on wrong branch (labeling), credential leak in env check, Neon root branch naming assumption. All fixable bugs.

### Branch 2: Agent Teams

Full report: [`005-agent-teams-report.md`](005-agent-teams-report.md)

- All 7 DoD items satisfied after the lead caught and fixed the `ALLOW_SEEDS` integration gap between teammate outputs.
- Zero revision cycles. One human intervention (correcting misattributed E2E failure — lead blamed "known flaky tests" when the actual cause was Modal billing 429).
- Mandatory stops were enforced by the lead's prompting, not by any native Agent Teams mechanism. This worked but is fragile.
- **State recoverability: FAIL.** This is a design limitation of Agent Teams — there is no session resumption for teams. `/resume` does not restore teammates or their progress. The state file was written post-hoc, not maintained during execution.
- Wall-clock time inflated by external blocker (3 deploy attempts). Implementation time was competitive (~6 min).
- The lead self-initiated the `ALLOW_SEEDS` fix after reviewing both teammates' outputs — Agent Teams provided no mechanism to surface this automatically.

### Branch 3: Hybrid

Full report: [`005-hybrid.md`](005-hybrid.md)

- All 7 DoD items satisfied. 9/9 E2E tests passed on first deploy attempt.
- Zero revision cycles, zero human interventions.
- Mandatory stops enforced by orchestrator protocol (not dependent on Agent Teams behavior).
- State file maintained by orchestrator throughout, updated at each phase transition. Qualified pass: teammate work-in-progress would still be lost on interruption, but the orchestrator's state file provides a recovery point.
- **Key advantage**: the orchestrator embedded the `ALLOW_SEEDS=true` cross-cutting concern in the platform-agent's prompt at spawn time, preventing the integration gap proactively rather than catching it after the fact.
- Fastest wall-clock time (~15 min) and cleanest execution (single deploy attempt, zero retries).

---

## Code Comparison Summary

Full analysis: [`005-trial-code-comparison.md`](005-trial-code-comparison.md)

The Agent Teams and Hybrid branches produced **identical code**. The Current Orchestrator diverged in several ways:

| Dimension | Current Orchestrator | Agent Teams & Hybrid |
|-----------|---------------------|---------------------|
| Functional correctness | **Bug**: missing `ALLOW_SEEDS=true` in deploy seed invocation | Correct |
| Seed gate design | Lenient (`ALLOW_SEEDS` OR `MIX_ENV != prod`) | Strict (`ALLOW_SEEDS` only) |
| Moduledoc updated | No | Yes |
| Parent resolution scoping | Outside API key guard (runs when unnecessary) | Inside guard (correct) |
| Topology doc | Verbose (66 lines), some duplication | Concise (48 lines), practical |

The stricter gate in Agent Teams/Hybrid forced the deploy script to explicitly pass `ALLOW_SEEDS=true`, which prevented the integration bug. The lenient gate in Current Orchestrator masked the missing flag, creating a latent failure that would surface in production-like environments.

---

## Applying the Decision Rule

### Step 1: Binary measure elimination

Per the scoring protocol: "If one branch fails any binary measure (4, 7, 8), it's eliminated unless the failure is attributable to a fixable bug rather than a design limitation."

- **Agent Teams** fails Measure 8 (State Recoverability). This is a **design limitation** of Agent Teams — there is no built-in session resumption for teams, and this cannot be fixed by configuration or prompting. Per the decision rule, this eliminates Agent Teams as a standalone approach.
- **Current Orchestrator** and **Hybrid** pass all binary measures.

### Step 2: Quantitative comparison (remaining branches)

| Measure | Current Orchestrator | Hybrid | Winner |
|---------|---------------------|--------|--------|
| Correctness | PASS (with latent bug) | PASS | **Hybrid** |
| Revision cycles | 0 | 0 | Tie |
| Human interventions | 0 | 0 | Tie |
| Mandatory stop fidelity | PASS | PASS | Tie |
| Wall-clock time | ~18 min | ~15 min | **Hybrid** |
| Context efficiency | ~42k + orchestrator | Medium-high (3 windows) | Comparable |

The Hybrid approach wins on correctness (no integration bug) and wall-clock time (~15 min vs ~18 min). Both share zero revision cycles and zero human interventions.

### Step 3: Code quality tiebreaker

The code comparison gives a clear edge to the Hybrid approach:
- No functional bugs vs. one latent bug in Current Orchestrator
- Stricter, safer seed gate
- Better documentation (moduledoc update)
- More concise topology doc
- Correct scoping of parent branch resolution

### Step 4: Qualitative measures

Code quality and auditability scores are deferred to the human. Both the Current Orchestrator and Hybrid approaches produced adequate audit trails (state files, plan files, reports). The Hybrid's proactive integration gap prevention is a qualitative advantage.

---

## Theoretical Predictions vs. Actual Results

| Dimension | Predicted (Current Orchestrator) | Actual | Predicted (Agent Teams) | Actual | Predicted (Hybrid) | Actual |
|-----------|--------------------------------|--------|------------------------|--------|-------------------|--------|
| Mandatory stop fidelity | Pass | **Pass** | Risk | **Pass (qualified)** | Pass | **Pass** |
| Specialist isolation | Worktrees | **No worktrees needed** | Shared dir (risk) | **Pass (disjoint files)** | Worktrees | **No worktrees needed** |
| Context efficiency | Medium | **Better than expected** | Best | **Medium-high** | Medium-high | **Medium-high** |
| Session resumption | State files | **Pass** | Teammates lost | **FAIL (confirmed)** | State files | **Pass (qualified)** |
| Parallel execution | Good | **Good** | Best | **Good** | Best | **Good** |
| Stability | High | **High** | Low | **Stable (better than expected)** | Medium | **High** |

Key surprises:
- Agent Teams was more stable than expected (no crashes)
- Agent Teams context efficiency was worse than expected (lead accumulated diagnostic context)
- All three approaches handled file isolation without worktrees (this issue had naturally disjoint file sets — a harder test case with overlapping files would differentiate them)

---

## Final Decision

### Recommendation: Hybrid

The Hybrid approach is the strongest overall:

1. **Best code quality.** Identical output to Agent Teams, superior to Current Orchestrator (no integration bug, stricter safety, better docs).
2. **Best process metrics.** Zero revision cycles, zero human interventions, fastest wall-clock time, single-attempt deploy success.
3. **Passes all binary measures.** State recoverability via orchestrator state files (unlike pure Agent Teams). Mandatory stops enforced by protocol (unlike Agent Teams where it depends on lead behavior).
4. **Preserves parallelism.** Agent Teams teammates execute specialist work in parallel with distributed context windows, keeping the orchestrator window lean.
5. **Proactive integration management.** The orchestrator has full context of all phases and can embed cross-cutting concerns in teammate prompts — the most important finding of this trial.

### What to adopt

- **Use Agent Teams teammates for parallel specialist phases** where file sets are disjoint. The distributed context windows and true parallel execution are genuine advantages.
- **Keep the orchestrator protocol for everything else**: planning, mandatory stops, regression gates, review, state management, and cross-cutting concern identification.
- **Do not use Agent Teams as a standalone approach.** The lack of session resumption is a design limitation, and mandatory stop enforcement depends entirely on lead discipline rather than system guarantees.

### Caveats and limitations of this trial

1. **Single test case.** Issue #005 had naturally disjoint file sets across phases. A test case with overlapping files would stress worktree isolation — an area where the approaches may diverge more significantly.
2. **External blocker.** The Modal billing 429 disproportionately affected the Agent Teams wall-clock time. Implementation speed was comparable across all three approaches.
3. **Qualitative scores pending.** Code quality and auditability scores are deferred to the human. The quantitative evidence alone is sufficient for the recommendation, but human override authority applies.
4. **Agent Teams is experimental.** The feature may mature and address current limitations (session resumption, mandatory stop enforcement). This decision should be revisited when Agent Teams exits experimental status.

---

## References
- [`005-current-orchestrator.md`](005-current-orchestrator.md) — Current Orchestrator trial report
- [`005-agent-teams-report.md`](005-agent-teams-report.md) — Agent Teams trial report
- [`005-hybrid.md`](005-hybrid.md) — Hybrid trial report
- [`005-trial-code-comparison.md`](005-trial-code-comparison.md) — Code comparison across branches
- Issue #005 — Neon Preview Branch Data Isolation (test case)
- Issue #022 — Worktree Isolation (current parallel execution approach)
- Issue #017 — Structured State Files (current session resumption)
- Claude Code Agent Teams documentation
