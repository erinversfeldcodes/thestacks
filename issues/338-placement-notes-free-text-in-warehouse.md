# Issue #338: Reader's placement `notes` free text flows into the warehouse against house convention

## Summary
Found by #335 and independently confirmed by the lead. `bookshelf_placements.notes` — a reader's personal free-text notes about a book they own — is selected into `dbt/models/staging/stg_bookshelf_placements.sql:14` with no `dbt_exclude`.

Every other user free-text field in this project is excluded from the warehouse by convention:

| Field | Treatment |
|---|---|
| `retrieval_log.query` | `dbt_exclude: true` (`proto/persisted.exs:1185`) |
| `turn_feedback.comment` | `dbt_exclude: true` (`:1162`) |
| `blog_assistant_sessions.topic` | `dbt_exclude: true` (`:1137`) |
| **`bookshelf_placements.notes`** | **not excluded** |

CLAUDE.md's GDPR contract is explicit that free text must be deleted or anonymised, not merely author-nulled, and that personal data is kept out of the warehouse. A note like *"bought this after Dad died"* is exactly the free text the convention exists for.

## User Stories
None directly — a GDPR/data-classification correction protecting every story that writes a placement note.

## Goal
Reader free text either stays out of `wh.*` like its siblings, or its presence there is a recorded, justified decision with the erasure path proven to reach it. Not an oversight either way.

## Scope Check
One proto override + one staging model + whatever downstream `ref()`s the column. Single concern.

## Wiring
Router wiring: none. Data-classification and warehouse surface.

## Feature-Completeness Pre-Check
n/a — no user story. Acceptance is the erasure/warehouse evidence below.

## Technical Requirements
1. **Decide `notes` first**, and record the reasoning. The default per house convention is `dbt_exclude: true` in `proto/persisted.exs`, regenerate, and drop the column from `stg_bookshelf_placements`. If any mart genuinely needs it, that mart is the thing to justify — trace `ref()` before removing.
2. **Then decide the neighbours deliberately.** #335 flagged that `users.email`, `users.display_name` and `users.city` are in the same category and *may* be intentional (a warehouse often needs a user dimension). Reach an explicit verdict per field rather than sweeping them along with `notes` — an unexamined exclusion is the same defect as an unexamined inclusion.
3. **Prove erasure reaches whatever stays.** For any personal field retained in `wh.*`, show `GDPR.Deletion.delete_user_data/1` reaches it (or that the model is a **view** over an already-erased table, which is a real answer — #334 found several staging models are views, so they carry no independent copy).
4. **`gdpr-review` is mandatory** on this diff.

## Reviewer Context
- ⚠️ **Owner ruling 2026-07-30: the GDPR wave (R6) was deliberately STRUCK from the campaign** — "revisit the GDPR findings once everything is implemented." This issue is filed **into that revisit bucket**, not for immediate execution. Do not schedule it ahead of the owner's sequencing.
- Check materialisation before reasoning about erasure: a **view** over `op.bookshelf_placements` needs no separate deletion path; a **table** does.
- `mix proto.sync` owns the generated staging models — change the override in `proto/persisted.exs` and regenerate; do not hand-edit `stg_*.sql`.
- Related: the free-text rule in CLAUDE.md ("free-text must be deleted/anonymised, not just author-nulled").
- Commit: agent commits are DENIED. Stage, one-line message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| GDPR | yes | ❌ `gdpr-review` verdict cited; erasure reaches any retained personal field |
| dbt | yes | ❌ `dbt parse` + downstream `ref()` trace clean after the column change |
| Codegen | yes | ❌ `mix proto.sync --check` green; `lint-proto.sh` all five targets |
| Others | no | n/a |

## Definition of Done
- [ ] `notes` decision made and applied, with reasoning recorded — evidence: diff + rationale
- [ ] Per-field verdict on `email`/`display_name`/`city` — evidence: stated decision each
- [ ] Erasure proven for anything retained — evidence: test name or view-materialisation proof
- [ ] `gdpr-review` PASS — evidence: verdict
- [ ] `dbt parse` + suites green — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
None technical. **Sequenced by owner ruling into the post-implementation GDPR revisit (struck Wave 1 / R6).** Found during #335 (Wave 4).

## Agent Assignment
elixir-agent + dbt, with the `gdpr-review` lens.

## Progress Notes
Filed 2026-07-30 by the lead from #335's finding #3. Independently confirmed: `notes` appears at `stg_bookshelf_placements.sql:14`, and `grep dbt_exclude proto/persisted.exs` shows the three sibling free-text fields all excluded.
