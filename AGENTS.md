# The Stacks — Agent System Configuration

## Plan Directory
plans/

## Issue Directory
issues/

## Invocation Model
Agents are plain .md files. Invoke the Orchestrator as:
  "You are The Stacks Orchestrator.
   Load: docs/agents/orchestrator-agent.md
   Task: Issue #NNN or [description]"

## Agent Registry

### Implementation Agents

| Agent | File | Domain |
|---|---|---|
| orchestrator | docs/agents/orchestrator-agent.md | System conductor — plans, delegates, reviews |
| researcher | docs/agents/orchestrator/researcher-agent.md | Research subagent — codebase + doc analysis |
| reviewer (generic) | docs/agents/orchestrator/reviewer-agent.md | Review subagent — DoD + standards verdict |
| elixir-agent | docs/agents/elixir-agent.md | Phoenix, Oban, EDA, contexts, partner API |
| elm-agent | docs/agents/elm-agent.md | Elm SPA, shelves, spines, cork board, partner dashboard |
| python-agent | docs/agents/python-agent.md | FastAPI vision service (Modal), content moderation |
| rust-agent | docs/agents/rust-agent.md | Bookshop price scraper, TOML config |
| database-agent | docs/agents/database-agent.md | PostgreSQL, Ecto, dbt, migrations, schemas |
| platform-agent | docs/agents/platform-agent.md | Fly.io, Docker, Nix/Flox, CI/CD, GitHub Actions |
| partner-agent | docs/agents/partner-agent.md | Partner API, dashboard, CSV import, validation |
| protobuf-agent | docs/agents/protobuf-agent.md | Proto files, buf, code generation, upcasting |
| security-agent | docs/agents/security-agent.md | GDPR, auth, AI safety, scanning, threat model |
| principle-engineer | docs/agents/principle-engineer-agent.md | Code quality audit, architectural review |
| staff-engineer | docs/agents/staff-engineer-agent.md | Design conscience — stewardship surveys (Design Ledger), simplification, test-truthfulness audits, phase assessments, advisory shadow reviews; Ousterhout/Zen/Czaplicki-Feldman-Kelley-Cro lens; economy + shift-detection-left; evidence by read, run, **and driving the product itself** |
| testing-coordinator | docs/agents/testing-coordinator-agent.md | 12-layer test strategy, 4 environments |

### Review Agents

Stack-specific reviewers. Each critiques code against three axes: (1) task DoD, (2) language community standards, (3) project coding standards per `docs/agents/standards/`.

| Reviewer | File | Reviews Work By |
|---|---|---|
| elixir-reviewer | docs/agents/reviewers/elixir-reviewer.md | elixir-agent, partner-agent (Elixir portions) |
| elm-reviewer | docs/agents/reviewers/elm-reviewer.md | elm-agent |
| ux-reviewer | docs/agents/reviewers/ux-reviewer.md | elm-agent (user experience, not code quality) |
| contract-reviewer | docs/agents/reviewers/contract-reviewer.md | elixir-agent, elm-agent, protobuf-agent (cross-boundary data shapes) |
| rust-reviewer | docs/agents/reviewers/rust-reviewer.md | rust-agent |
| python-reviewer | docs/agents/reviewers/python-reviewer.md | python-agent |
| database-reviewer | docs/agents/reviewers/database-reviewer.md | database-agent |
| platform-reviewer | docs/agents/reviewers/platform-reviewer.md | platform-agent |
| protobuf-reviewer | docs/agents/reviewers/protobuf-reviewer.md | protobuf-agent |

### Review Protocol

1. Implementation agent completes its task and produces a completion report
2. Orchestrator invokes the matching review agent with the completion report, DoD, and file list
3. Reviewer returns a verdict: APPROVED, NEEDS_REVISION, or FAILED
4. **Human mediates**: orchestrator presents the review to the human, who decides whether to accept, request further changes, or override
5. If NEEDS_REVISION: implementer acts on feedback, reviewer re-reviews (max 2 cycles before human escalation)

### Reviewer Routing

| Implementation Agent | Reviewer(s) |
|---|---|
| elixir-agent | elixir-reviewer + contract-reviewer (when touching API endpoints or events) |
| elm-agent | elm-reviewer + ux-reviewer + contract-reviewer (when touching decoders or API calls) |
| rust-agent | rust-reviewer + contract-reviewer (scraper API contract) |
| python-agent | python-reviewer + contract-reviewer (vision service contract) |
| database-agent | database-reviewer |
| platform-agent | platform-reviewer |
| protobuf-agent | protobuf-reviewer + contract-reviewer |
| partner-agent | elixir-reviewer + protobuf-reviewer + contract-reviewer |

## Domain Routing Table

| Keywords | Delegate To |
|---|---|
| Phoenix, Elixir, OTP, Oban, context, GenServer, supervision, event bus | elixir-agent |
| Elm, frontend, shelf, spine, cork board, reading pile, UI, SPA | elm-agent |
| vision, FastAPI, Python, Modal, Qwen, image classification | python-agent |
| Rust, scraper, price, bookshop, TOML, ISBN extraction | rust-agent |
| database, PostgreSQL, Ecto, migration, schema, dbt, SQL | database-agent |
| Fly.io, Docker, Nix, Flox, CI/CD, GitHub Actions, deployment | platform-agent |
| partner, inventory sync, CSV import, partner API, partner dashboard | partner-agent |
| Protobuf, proto, buf, schema contract, code generation, upcasting | protobuf-agent |
| GDPR, security, auth, Guardian, JWT, AI safety, rate limiting, scanning | security-agent |
| code quality, architecture review, tech debt, standards compliance | principle-engineer |
| design review, design debt, taste, simplification, deletion, deep module, legibility, refactor direction, stewardship, over-mocked tests, "do these tests guarantee anything", phase assessment, roadmap drift, missing user stories, product coherence, aesthetic drift, "is this delightful", "would we love this" | staff-engineer |
| testing, E2E, Playwright, elm-program-test, chaos, load, k6 | testing-coordinator |
| UX, usability, mobile, responsive, accessibility experience, delight, tone, copy | ux-reviewer |
| API shape, event payload, decoder, contract, breaking change, JSON shape, inter-service | contract-reviewer |

## Shared Standards
- Code quality: docs/agents/standards/code-quality.md
- **Code-quality exemplars (the calibration set): docs/agents/reference/exemplars.md** — real code
  and talks by Czaplicki, Feldman, Kelley, and Cro, used to judge "is this good enough?" by
  comparison rather than assertion. Citations must be fetched and verified before use, never
  quoted from memory.
- Testing: docs/agents/standards/testing.md
- Security: docs/agents/standards/security.md
- Protobuf: docs/agents/standards/protobuf.md
- Migrations: docs/agents/standards/migrations.md
- Dashboards (ops Grafana): docs/agents/standards/dashboards.md
- **Completion bar (the exit criterion for any issue/epic): docs/agents/standards/completion-bar.md** —
  every deliverable driven live (real signal observed), every claim carries an evidence token, no
  structure-only gate as proof, no phantom `#NNN`. Enforced mechanically by the `check-issue-evidence`
  Stop hook and the `completion-audit` skill (below), not on the honour system.

## Completion Skills (enforce the bar — run before any "done"/PR-open)
- `feature-completeness` — is each named story (or infra/observability deliverable) actually *built* +
  driven live? Runs at planning + before authoring tests.
- `test-audit` — is each of the 13 layers *tested*? The embedded audit that must be GREEN at exit.
- `completion-audit` — the epic-wide **adversarial** "prove it is NOT done" gate over the whole
  deliverable; gates the orchestrator's Phase 3. Automates the "is this really done?" sweep.
- `verify-and-followup` — run the gates, report with evidence, file residuals as tracked issues.
- `staff-review` — the Staff Engineer's **advisory** shadow review of a diff (design/taste +
  test-truthfulness lens, not a gate); runs inside `finalize-pr` before the PR body is written,
  and on demand via `/staff-review`.
- `staff-survey` — the Staff Engineer's stewardship pass over **existing** code: rewrite sketches,
  simplification candidates goal-checked against `notes/`, and mutation-probed test verdicts
  (KEEP/STRENGTHEN/REWRITE/REMOVE). Produces a Design Ledger; issues only after a human stop.
- `staff-campaign` — the Staff Engineer's **Mode D**: the full range applied across the codebase,
  composed into one sequenced **Remediation Plan** (root-cause clusters, leverage ranking,
  dependency-ordered waves). The only mode that synthesises the others; plans, never implements.
- `staff-execute` — the Staff Engineer's **Mode E**: builds a campaign's plan wave by wave. **The
  only mode that writes production code.** Runs until `just wave-status <slug>` reports the wave
  green, stopping for exactly three things — an untaken decision, an irreversible action, or a
  discovery that changes the plan's shape — and never to report progress. Every item gets a real
  `issues/NNN-*.md` before any code, and progress lives in `plans/<slug>-state.json` so a fresh pass
  resumes without being told anything. Added 2026-07-28: Modes A–D all end at a report, so "now
  implement the plan" had no harness and drifted into continuous pausing plus waves declared
  finished that weren't.
- `staff-phase-audit` — the Staff Engineer's assessment of a **phase** of
  `docs/implementation-mapping.md` against `notes/` and against reality. Uniquely asks whether the
  **story set itself** is complete (missing recovery/unhappy-path/second-actor stories), alongside
  a built-and-genuinely-tested roll-up. Commissions `feature-completeness` and `test-audit` as
  inputs rather than duplicating them.

## Canonical References
- Architecture: docs/technical-architecture.md
- User stories: docs/user-stories.md
- Implementation mapping: docs/implementation-mapping.md
