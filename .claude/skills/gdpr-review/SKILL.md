---
name: gdpr-review
description: Review a diff / PR / branch for GDPR-breaching introductions BEFORE it merges — new personal data that erasure or export misses, new event payloads or dbt models that leak PII, new user-data endpoints without an auth or consent gate, or new user-FKs that erasure can't reach. Answers "does this change keep The Stacks' GDPR guarantees intact?". Use when reviewing any change that touches migrations, Ecto schemas, event emitters, controllers/routes, dbt models, or anything handling user data.
---

# gdpr-review

The gate this codebase learned it needed the hard way. In the #121 GDPR epic, a new
personal-data column (`op.post_comments.body`, user-authored free text) was left out of
account erasure — it survived **seven per-issue reviews and a GREEN schema-guard test**,
and only fell to a deep Principal-Engineer trace of the assembled diff. That is exactly the
regression this skill exists to catch on every future PR: a change that quietly introduces
personal data (or a new PII path) without wiring it into the erasure / export / consent /
no-leak machinery.

GDPR is a **standing invariant of the whole system**, not a feature. A change is GDPR-safe
only if every new piece of personal data it introduces is *reachable by erasure*, *included
in export*, *gated where required*, and *kept out of places it must not leak*. This skill
proves that, per-diff.

## When to use
- Reviewing ANY PR / branch / diff — as a mandatory lens alongside code-review — that touches:
  migrations, `apps/core/lib/stacks/gen/**` schemas or the proto/manifest, `Events.emit*` call
  sites, controllers/`router.ex`, `dbt/models/**`, workers, or anything reading/writing user data.
- Before opening a PR for a feature that stores, emits, exports, or displays user data.
- When a `test-audit` or PE review is unsure whether a new table/column/event is a GDPR concern.
- Periodically as a full-codebase sweep (scope: "audit").

## The Stacks GDPR machinery (what each new PII surface must satisfy)
Ground every finding in these — cite the file:line the change must touch, not generic GDPR.

- **4-tier data classification** (CLAUDE.md, `docs/technical-architecture.md`): public · personal ·
  sensitive · external-personal. Classify every new column/table. `personal`/`sensitive` triggers
  the obligations below.
- **Right to erasure** — `Stacks.GDPR.Deletion.delete_user_data/1` (`apps/core/lib/stacks/gdpr/deletion.ex`),
  run by `AccountDeletionJob` (`max_attempts: 1`). A user's personal data is erased either by a
  Postgres FK `on_delete: :delete_all` cascade off `repo.delete(user)`, or by an explicit atomic
  `Ecto.Multi` step. **Free-text/user-authored content must be DELETED or anonymised — `:nilify_all`
  removes the *reference*, not the *content* (the #185/post_comments lesson).**
- **Erasure schema-guard** — `apps/core/test/stacks/gdpr/deletion_test.exs` "erasure completeness —
  schema-level guard": every `op.*` FK to `op.users` must be CASCADE, or SET NULL **only** for an
  allowlisted table with a written justification (e.g. `transactions` = financial-retention). A new
  bare-`nilify` user-FK must fail this guard.
- **Right to export** — `Stacks.GDPR.Export.export_user_data/2` (`export.ex`): the user's personal
  data must appear in the export payload. Vectors/opaque blobs are summarised, never dumped
  (`embeddings_summary` is `select`-only — no raw vector).
- **event_log PII contract** — event payloads are **UUID-only** (no names/email/free-text). Erasure
  scrubs the user's rows via `:scrub_event_log` (user-aggregate + cross-aggregate by payload
  `user_id`/`author_id`/`seller_id`). A new `Events.emit*` call carrying PII either drops it to
  UUIDs OR is added to the scrub's key coverage. `event_log` rows are never deleted (immutable).
- **Audit log** — `Stacks.Audit`: append-only (DB trigger, GUC-gated erasure), IPs SHA-256-hashed,
  `metadata` Cloak-encrypted, never surfaced raw.
- **Consent** — `Stacks.GDPR.Consent` + `StacksWeb.Plugs.ConsentCheck` (feature-parameterised):
  features requiring consent (analytics, writing-assistant) gate on it (403). A user-supplied
  consent `type` must be whitelisted before it reaches telemetry/consent (cardinality + injection).
- **Warehouse / dbt** — personal free-text must NOT enter the `wh`/staging models: exclude it from
  the `stg_*` model and mark the column, but still declare it on the source (`retrieval_log.query`
  is the pattern). `wh`-schema models must be anonymised.
- **Retention** — 30-day image retention (`ImageRetention`); consent timestamps recorded.
- **Partner boundary** — partner→platform is one-directional; partners never see user data.

## The review — per changed data surface
For the diff, enumerate every NEW or MODIFIED: (a) `op.*` column/table, (b) `Events.emit*` payload,
(c) user-data endpoint/route, (d) dbt model, (e) worker touching user data. For each, verify:

1. **Classify.** Is it personal/sensitive? (free-text, name, email, location, IP, user-authored
   content, behavioural history = personal.) If public/non-personal, note why and move on.
2. **Erasure reachable?** Trace whether `delete_user_data/1` reaches it — a cascading user-FK, or an
   explicit Multi step. For free-text, confirm it's DELETED/anonymised, not just author-nulled. If
   not reachable → **P0** (right-to-erasure breach). Confirm the schema-guard would fail on it if
   unhandled.
3. **Export included?** Personal data the user can request should appear in `export_user_data/2`
   (or a justified exclusion). Missing → P1.
4. **event_log / audit leak?** New emit payloads UUID-only? New audit writes hash IPs / encrypt
   metadata / expose nothing raw? PII in a payload not covered by the scrub → P1.
5. **Gated?** User-data endpoints behind `:authenticated`; consent-requiring features behind
   `ConsentCheck`; user-supplied consent/feature values whitelisted. Missing gate → P0/P1 by severity.
6. **Warehouse leak?** New/changed dbt model or a new column flowing to `wh`/staging — is personal
   free-text excluded? Leak → P1.
7. **Retention / consent timestamp / partner boundary** as applicable.

## Output
- A concise **GDPR-review verdict**: PASS / CONCERNS / FAIL, plus a findings table:

  | Change (file:line) | Data class | Erasure | Export | Leak (event/audit/dbt) | Gate | Verdict |
  |--------------------|-----------|---------|--------|------------------------|------|---------|

- Each finding cites the exact contract it violates + the file:line the fix must touch. Severity:
  **P0** = personal data unreachable by erasure, or an ungated sensitive surface (breach on merge);
  **P1** = missing export / a PII leak into event_log/audit/warehouse / missing consent gate;
  **P2** = a guard/contract not future-proofed (holds today, regresses silently later).
- If the change introduces **no** personal-data surface, say so explicitly (a clean PASS is a real
  result — don't manufacture findings).
- For anything less than PASS, recommend: fix-in-PR (preferred for P0) or a tracked follow-up issue
  (`create-issue`), and require the PR body to state any accepted residue honestly (never claim
  "erasure complete" while a personal table is missed).

## Relationship to other skills
- Runs as a **lens during code-review** (and belongs in the review checklist for data-touching PRs),
  complementary to `feature-completeness` ("is it built?") and `test-audit` ("is it tested?"). This
  one asks "**is it GDPR-safe?**".
- A P0/P1 finding becomes a `create-issue` spin-out when it can't be fixed in the PR.
- `write-validation-test` turns a finding into a regression test (e.g. an erasure test proving the
  new column's PII is gone after `delete_user_data/1`, or a schema-guard extension).

## Scale
Reviewing many PRs / a full sweep → fan out one agent per PR (or per subsystem), each producing its
own verdict table. Spot-check that each cited erasure/export/scrub path actually exists.
