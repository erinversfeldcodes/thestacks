---
name: scope-request
description: Turn a vague request into a scoped, buildable brief — investigate the actual code and docs, right-size against the Scope Check, and ask the human the few clarifying questions that actually change the outcome. Use before creating an issue or starting non-trivial work, or when a request is under-specified ("add X", "fix the Y flow") and you need to pin down surface, boundaries, and success criteria.
---

# scope-request

Good scoping is investigation first, questions second. Read the code and docs before asking the
human anything — most "questions" are answerable from the tree, and the human's time should go to
the genuine forks only. The output is a short brief: goal, affected surfaces, user story (or an
explicit story-less rationale), boundaries, dependencies, and open questions resolved.

## Steps

1. **Investigate the code.** Locate the real surfaces the request touches. Use `Grep`/`Glob` for
   targeted lookups; delegate a broad sweep to an `Explore` agent when it spans many files or naming
   conventions. Establish: which modules/controllers/plugs/components are involved, what already
   exists vs. what's new, and the blast radius. Verify claims against the tree — never scope on
   assumption (an agent saying a path is "checked in" is not proof; `git ls-files` is).

2. **Investigate the docs.** Check the canonical references for intent and constraints:
   `docs/technical-architecture.md` (architecture + threat model), `docs/user-stories.md` and
   `docs/user_stories/US-*.md` (the story this serves + its per-layer spec),
   `docs/implementation-mapping.md` (story → components), `docs/agents/standards/` (the rules the
   work must satisfy), and the relevant agent `.md` for domain conventions.

3. **Right-size against the Scope Check.** Flag a split if the work touches >3 controllers, adds >2
   endpoints, exceeds ~300 LOC of production code, or combines unrelated concerns. One issue = one
   concern. If it's too big, propose the smallest coherent first slice and list the rest as
   follow-ons.

4. **Ask only the clarifying questions that change the outcome.** After investigating, you will have
   a small set of genuine forks — resolve them with `AskUserQuestion`, recommending a default. Good
   candidates: ambiguous success criteria, which user story it serves (if unclear or none), wiring
   (user-facing now vs. implementation-only wired later), in-scope vs. deferred edge cases, and how
   the behaviour should be **validated** (especially where browser E2E is the wrong tool — see
   `write-validation-test`). Do not ask what the code already answers.

5. **Produce the brief.** A short synthesis: Goal · Affected surfaces (file:line where known) ·
   User story or "none — <why still validatable>" · In scope / Out of scope · Dependencies ·
   Validation approach per behaviour · Resolved decisions. This feeds `create-issue` directly, or
   scopes the work before you start.

## Rules
- Investigate before asking. A clarifying question the tree already answers wastes the human's turn.
- Recommend a default with every question; don't offer a bare menu.
- Surface, don't bury: if investigation contradicts the request's premise ("the X flow" doesn't
  exist, or already works), say so before scoping further.
- Scope-lock: a second concern discovered while scoping becomes its own follow-up, not a bigger brief.
