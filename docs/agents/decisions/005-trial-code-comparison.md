# Code Comparison: Issue #005 Across Trial Branches
**Issue**: #024 (Agent Teams Evaluation)
**Date**: 2026-03-13
**Branches compared**: `trial/005-current-orchestrator`, `trial/005-agent-teams`, `trial/005-hybrid`
**Status**: historical — see `agent-teams-evaluation.md` for the final decision

---

## Overview

All three branches implemented the same Issue #005 (Neon Preview Branch Data Isolation) with the same scope: deploy script changes, seed gate, env docs, and topology documentation. The Agent Teams and Hybrid branches produced **identical code**. The Current Orchestrator branch diverged in several ways, including one functional bug.

---

## File-by-File Comparison

### `scripts/deploy-preview.sh`

#### Parent branch resolution placement

- **Current Orchestrator**: Resolves parent branch in a standalone section **before** the `NEON_API_KEY` guard (line 88). Sets `NEON_PARENT_BRANCH` and `NEON_PARENT_BRANCH_ID` even when no API key is present.
- **Agent Teams & Hybrid**: Resolves parent branch **inside** the `NEON_API_KEY` guard, immediately before stale branch cleanup. Only runs when the API key exists.

**Verdict**: Agent Teams/Hybrid is correct. Resolving a parent branch without an API key is a no-op that clutters output.

#### Header comment placement

- **Current Orchestrator**: `NEON_PARENT_BRANCH` listed after `NEON_API_KEY` (logical grouping with Neon vars).
- **Agent Teams & Hybrid**: Listed after `SECRET_KEY_BASE`, before `GITHUB_HEAD_REF`.

**Verdict**: Current Orchestrator's grouping is slightly more logical, but the difference is cosmetic.

#### Echo messaging style

- **Current Orchestrator**: `"==> Resolving parent branch '${NEON_PARENT_BRANCH}'..."` → `"Resolved: ${NEON_PARENT_BRANCH} → ${NEON_PARENT_BRANCH_ID}"`
- **Agent Teams & Hybrid**: `"Parent branch: ${NEON_PARENT_BRANCH}"` → `"Parent branch ID: ${NEON_PARENT_BRANCH_ID}"`

**Verdict**: Current Orchestrator's phrasing is more descriptive (shows the resolution as an action with before/after). Minor difference.

#### Seed invocation — `ALLOW_SEEDS` (functional bug)

- **Current Orchestrator**: Does **not** update the `fly machine exec` seed command (line 292). Seeds are invoked without `ALLOW_SEEDS=true`:
  ```bash
  "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.seed()'\""
  ```
- **Agent Teams & Hybrid**: Updates the seed command to pass the env var:
  ```bash
  "/bin/sh -c \"ALLOW_SEEDS=true /app/bin/core eval 'Stacks.Release.seed()'\""
  ```

**Verdict**: **Current Orchestrator has a functional bug.** The seed gate blocks `seed/0` when `ALLOW_SEEDS` is not set. In the Current Orchestrator's version, `seed/0` also allows seeds when `MIX_ENV != "prod"`, which masks the bug in dev/test but would surface in any environment where `MIX_ENV=prod` (which Fly.io releases use). The Agent Teams/Hybrid branches caught this because their stricter gate requires `ALLOW_SEEDS=true` unconditionally, forcing them to update the caller.

This is the most significant finding in the comparison: **the current orchestrator treated deploy script and seed gate as independent phases and missed the integration point where they connect.**

---

### `apps/core/lib/stacks/release.ex`

#### Gate logic

- **Current Orchestrator**:
  ```elixir
  defp seeds_allowed? do
    System.get_env("ALLOW_SEEDS") == "true" or System.get_env("MIX_ENV") != "prod"
  end
  ```
  Seeds run freely in dev/test without any env var. Only blocked when `MIX_ENV=prod` and `ALLOW_SEEDS` is unset.

- **Agent Teams & Hybrid**:
  ```elixir
  defp seeds_allowed?, do: System.get_env("ALLOW_SEEDS") == "true"
  ```
  Seeds are blocked everywhere unless explicitly opted in. Simpler, stricter.

**Verdict**: Both are defensible designs. The Current Orchestrator's approach is more ergonomic for local dev (no env var needed). The Agent Teams/Hybrid approach is safer (explicit opt-in everywhere) and avoids the integration bug described above. The stricter gate forces all callers to be explicit, which is a better safety default for a release module.

#### Warning message

- **Current Orchestrator**: `"Seeds blocked in production. Set ALLOW_SEEDS=true to override."`
- **Agent Teams & Hybrid**: `"Seeds are disabled (ALLOW_SEEDS != \"true\"). Skipping."`

**Verdict**: Each message accurately describes its respective gate logic. The Agent Teams/Hybrid message is more precise — the gate isn't production-specific.

#### Moduledoc

- **Current Orchestrator**: No changes to `@moduledoc`.
- **Agent Teams & Hybrid**: Added a `## Seed gating` section explaining the `ALLOW_SEEDS` requirement.

**Verdict**: Agent Teams/Hybrid is better. Documenting the new behavior where developers will find it (the moduledoc) is good practice.

#### Function style

- **Current Orchestrator**: Multi-line `defp seeds_allowed? do ... end` (3 lines).
- **Agent Teams & Hybrid**: One-liner `defp seeds_allowed?, do: ...`.

**Verdict**: One-liner is more idiomatic Elixir for a single-expression function. Minor.

---

### `.env.example`

- **Current Orchestrator** (6 lines added):
  ```
  # Parent Neon branch that preview branches fork from.
  # Default: "staging" — a branch containing only fixture/seed data, not production data.
  # Set up the staging branch once: neonctl branches create --name staging --project-id $NEON_PROJECT_ID
  # See docs/deployment/NEON_BRANCH_TOPOLOGY.md for the full branch topology.
  NEON_PARENT_BRANCH=staging
  ```

- **Agent Teams & Hybrid** (4 lines added):
  ```
  # Name of the Neon branch used as parent for preview branches.
  # Preview branches inherit this branch's data (fixture data only — no production data).
  # Default: staging. See docs/deployment/NEON_BRANCH_TOPOLOGY.md for the branch hierarchy.
  NEON_PARENT_BRANCH=staging
  ```

**Verdict**: Current Orchestrator includes the `neonctl` setup command inline, which is helpful but duplicates the topology doc. Agent Teams/Hybrid is more concise and avoids duplication. Both are adequate.

---

### `docs/deployment/NEON_BRANCH_TOPOLOGY.md`

- **Current Orchestrator** (66 lines): Includes both CLI and API curl examples for creating the staging branch. Has a "How deploy-preview.sh uses it" section (5-step walkthrough). Includes a "Production seed protection" note. Setup seed command uses `mix run` directly rather than the release binary.

- **Agent Teams & Hybrid** (48 lines, identical to each other): More concise. Includes a "Why Three Tiers?" section explaining Neon's copy-on-write model. Lifecycle table is cleaner. Setup uses `fly ssh console` with `ALLOW_SEEDS=true`. No API curl example (CLI only).

**Verdict**: Agent Teams/Hybrid is tighter and more practical. The "Why Three Tiers?" framing is more useful than the Current Orchestrator's step-by-step walkthrough of deploy-preview.sh internals (which developers can read in the script itself). The seed command in Agent Teams/Hybrid is also consistent with the gate logic (`ALLOW_SEEDS=true`), while the Current Orchestrator's `mix run` approach bypasses the release module entirely.

---

## Summary

| Dimension | Current Orchestrator | Agent Teams | Hybrid |
|-----------|---------------------|-------------|--------|
| Functional correctness | **Bug**: missing `ALLOW_SEEDS=true` in deploy seed invocation | Correct | Correct |
| Gate design | Lenient (env var OR non-prod) | Strict (env var only) | Strict (env var only) |
| Moduledoc updated | No | Yes | Yes |
| Parent resolution scope | Outside API key guard | Inside guard | Inside guard |
| Topology doc quality | Verbose (66 lines), some duplication | Concise (48 lines), practical | Concise (48 lines), practical |
| `.env.example` | Slightly more helpful (inline setup cmd) | Concise, no duplication | Concise, no duplication |
| Deploy echo style | More descriptive | Adequate | Adequate |
| Agent Teams vs Hybrid code | N/A | **Identical** | **Identical** |

### Key Finding

The Agent Teams and Hybrid branches produced identical code despite using different orchestration approaches. Both caught the `ALLOW_SEEDS` integration gap that the Current Orchestrator missed. This suggests that the orchestration approach had a measurable impact on code correctness — specifically, the approaches that ran inside a single session (Agent Teams lead + teammates, or Hybrid orchestrator + teammates) maintained better cross-file awareness than the Current Orchestrator's fully separated subagent invocations.

### Best Code

The Agent Teams/Hybrid code is the stronger implementation:
- No functional bugs
- Stricter, safer seed gate
- Better documentation (moduledoc update)
- More concise topology doc
- Correct scoping of parent branch resolution
- Consistent `ALLOW_SEEDS=true` usage across all touchpoints (gate, deploy script, topology doc setup instructions)
