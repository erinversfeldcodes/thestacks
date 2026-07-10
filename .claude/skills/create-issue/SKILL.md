---
name: create-issue
description: Create a well-scoped Stacks issue from a request — investigate the code and docs, ask clarifying questions, right-size the scope, draft from issues/TEMPLATE.md, and embed a baseline test audit with a validation path for every behaviour. Use for "/create-issue", "open a ticket", "file an issue", "cut an issue for X", or when a discovery/scope-creep finding needs a tracked home.
---

# create-issue

Turns a request into a ticket that is **scoped, buildable, and validatable**. The output is an
`issues/NNN-slug.md` file that already carries its own baseline test audit — so "what does done
look like, and how will we prove it?" is answered before anyone writes code.

Do not shortcut to writing the file. A good ticket is mostly investigation + scoping; the writing
is the easy part.

## Steps

1. **Scope it first — use the `scope-request` skill.** Investigate the relevant code and docs,
   apply the Scope Check (max 3 controllers / 2 endpoints / ~300 LOC / no mixed concerns), and ask
   the human targeted clarifying questions. Come out with: the goal, the affected surfaces, the
   user story (or an explicit "none — <why still validatable>"), dependencies, and whether it needs
   splitting. If it should be split, propose the split and create the *first* issue only.

2. **Get the next number and a draft.** Prefer the MCP tools over hand-editing:
   `mcp__project-tools__next_issue_number()`, then `mcp__project-tools__draft_issue(title,
   roadmap_context, domains)` — it pulls domain DoD templates, derives the agent assignment, and
   scans for dependencies. Fall back to copying `issues/TEMPLATE.md` if the MCP server is absent.

3. **Fill the template** (`issues/TEMPLATE.md`): Summary, User Stories, Goal, Scope Check (tick the
   splits you cleared), Wiring (router/UI vs implementation-only), Technical Requirements,
   Reviewer Context (non-obvious conventions the reviewer will need).

4. **Embed a baseline test audit — use the `test-audit` skill.** Compact format for
   harness/CI/single-plug/security issues; full 13-layer × US format for feature issues. The
   baseline is the work queue (mostly `❌`). Every behaviour named in Technical Requirements gets a
   cell.

5. **Give every behaviour a validation path — required unless justified.** For each behaviour, name
   *how it will be proven*. Where Playwright/browser E2E is the wrong tool (backend-only, security
   invariant, harness change), that is NOT a reason to skip validation — specify an acceptance or
   live-stack test that reaches the state the way a real user would (see `write-validation-test`).
   Anything without a path is a punch-list item or an explicit `n/a` with a one-line reason.

6. **Write the DoD** from the template's defaults plus issue-specific, measurable criteria —
   including the "validation path per behaviour" and "test audit is GREEN" items.

7. **Create the file** via `mcp__project-tools__create_issue(...)` (or write `issues/NNN-slug.md`).
   The slug must match the intended branch name (lowercase, hyphens).

8. **Present the draft to the human and STOP.** Show the title, scope decision, the audit verdict
   (baseline counts + 2-3 key gaps), and the agent assignment. Wait for approval or edits before it
   enters the backlog.

## Rules
- One concern per issue. If scoping surfaces a second concern, it becomes its own ticket, not a
  bigger one (scope-lock).
- Never invent test names in the audit — cite real files or mark `❌`/`n/a` (see `test-audit`).
- "None" user stories is allowed for infra/harness work, but the validation-path requirement still
  applies — story-less does not mean test-less.
- Don't guess the roadmap. If the request references a user story or roadmap phase you can't find,
  ask (that's a `scope-request` clarifying question), don't fabricate one.
