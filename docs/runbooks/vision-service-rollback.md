# Runbook: Vision Service Rollback

**Severity:** P1 (cover identification broken; silent data loss risk if enum wire format mismatches)
**Owner:** Platform operator
**Last reviewed:** 2026-06-10

This runbook covers rolling the Modal vision sidecar (`thestacks-vision`)
back to a previous commit when a recent vision deploy regressed. The
sidecar runs HuggingFace Transformers + `Qwen/Qwen2.5-VL-7B-Instruct` in
bfloat16 on A10G (see `apps/vision/modal_app.py` and ADR 015 for the
inference stack rationale; ADR 001 for why Modal owns inference at all).

For a Modal-side outage where the deploy itself is healthy, read
`modal-outage.md` first. For the broader "core + DB + vision" rollback
procedure that this runbook plugs into, read `manual-rollback.md`.

---

## Two rollback paths

The vision sidecar can be rolled back via two paths, in increasing order
of operator effort:

1. **Composite-action path (preferred).** `gh workflow run
   deploy-production.yml -f manual_rollback=true` invokes
   `.github/actions/rollback-production`, which reads
   `MODAL_PREV_COMMIT` from the second-most-recent `main-<sha>` tag and
   reverts core + (optional DB) + Modal vision in one shot. This is the
   default path — it writes an audit row via `Stacks.Audit.log_rollback/1`
   and fires `[:stacks, :system, :rollback]` telemetry on success. See
   `manual-rollback.md` for the full procedure.
2. **Direct `modal deploy` from a known-good commit (escape hatch).**
   Used when only the vision sidecar is misbehaving and a full
   composite rollback is too heavy, or when the composite action itself
   is broken. Documented below.

---

## Ordering invariant (core → DB → vision)

The composite action runs the three rollback legs in fixed order: core
image first, then Neon DB (optional), then Modal vision. The invariant
is forced by what each direction guarantees:

- **Image N-1 ↔ schema N** is safe by construction. The
  `migration-safety` lint enforces expand-contract migrations, so the
  post-migrate schema is forward-compatible with the previous image.
- **Image N ↔ schema N-1** is unsafe: image N may write columns that
  don't exist in the older schema → INSERT/UPDATE failures.

Modal vision rolls back last because it is stateless w.r.t. the DB
schema (it never reads or writes Postgres). The same ordering applies
when rolling the stack forward — always deploy Elixir (core) before
Python (vision); see "Wire format constraints" below for the symmetric
data-loss case if you don't.

---

## Direct rollback (composite action unavailable)

If the composite action is broken and you need to revert just the Modal
sidecar, run `modal deploy` from a known-good commit:

```bash
# 1. Resolve the previous main-<sha> tag — same logic the composite
#    action uses via record-prev-state.
PREV_TAG=$(git tag --list 'main-*' --sort=-creatordate | sed -n '2p')
PREV_SHA="${PREV_TAG#main-}"

# 2. Check out the previous commit in a worktree (keeps your current
#    branch untouched).
git worktree add /tmp/vision-rollback "$PREV_SHA"
cd /tmp/vision-rollback

# 3. Deploy the prior modal_app.py against the prod Modal app.
modal deploy apps/vision/modal_app.py

# 4. Tear down the worktree.
cd -
git worktree remove /tmp/vision-rollback
```

The prod Modal app is `thestacks-vision` (default `MODAL_APP_NAME` in
`apps/vision/modal_app.py`). Per-PR previews use
`thestacks-vision-<sanitised-branch>` — substitute the right name via
`MODAL_APP_NAME=thestacks-vision-<branch>` when triaging a preview.

**This path does NOT write an audit row.** Follow up with a manual
`Stacks.Audit.log_rollback/1` invocation from a `fly ssh console -a
thestacks-core` remsh so the rollback is still recorded:

```elixir
Stacks.Audit.log_rollback(%{
  failed_sha: "<broken-deploy-sha>",
  target_image: nil,                   # vision-only rollback
  modal_prev_commit: "<rolled-back-to-sha>",
  reason: "<free-form reason>",
  triggered_by: "manual"
})
```

Allowed `triggered_by` values: `"slo-gate"`, `"manual"`,
`"step-failure"`, `"migration-failure"`.

---

## Inspecting Modal state during rollback

```bash
modal app list                                # confirm thestacks-vision exists
modal app logs thestacks-vision               # tail prod logs
modal app stop thestacks-vision-<branch>      # tear down a wedged preview
```

If `modal deploy` itself fails, check Modal status (modal.statuspage.io)
before retrying — see `modal-outage.md` for the outage-vs-deploy-failure
triage.

---

## Wire format constraints (deploy ordering)

> ⚠️ **Rewritten 2026-10-15.** This section ran ~64 lines and described the
> `AssociationStatus` enum crossing from the vision sidecar back to core via a
> callback. **That callback, its endpoint, `dispatch_association/2`, the
> `@status_confirmed`/`@status_rejected` attributes, the `_STATUS_*` constants
> and the `[:stacks, :vision, :unknown_association_status]` telemetry it told
> you to watch have all been deleted** — the cover-verification loop had no
> caller and was removed. Following the old procedure would have meant grepping
> for constants that do not exist and watching a telemetry event that can never
> fire, which is worse than having no procedure.
>
> **The constraint itself survives, on a different enum**, and that is what
> follows.

The vision service and core share one cross-language enum in the surviving
`/analyze` path: **`ClassificationResult`**.

- `CLASSIFICATION_RESULT_BOOK`
- `CLASSIFICATION_RESULT_NOT_BOOK`
- `CLASSIFICATION_RESULT_AMBIGUOUS`

Python sends these strings in the `/analyze` response body; core reads them in
`Stacks.Moderation.classification_outcome/1`
(`apps/core/lib/stacks/moderation.ex:127-130`). They must match.

### Always deploy Elixir (core) before Python (vision)

Unchanged, and for the same reason as before — only the failure mode differs.

- **Elixir is tolerant:** `classification_outcome/1` ends in a
  `defp classification_outcome(_), do: :unknown` catch-all, so an unrecognised
  classification string degrades rather than crashing. ⚠️ **But it degrades
  silently** — there is no warning and no telemetry on that clause, which is the
  gap this section used to cover for the other enum. Treat `:unknown` outcomes
  showing up in moderation results as the signal.
- **Python is forward-only:** it sends the new strings as soon as it is deployed.

Deploying Python first creates a window where core classifies every image as
`:unknown`. The composite action's core-then-vision ordering preserves the
invariant during rollback too.

### Symptoms of a wire format mismatch

1. Uploaded images resolving to no book while the sidecar logs `200` responses.
2. Moderation outcomes landing as `:unknown` rather than book / not_a_book /
   ambiguous.
3. No DB updates in core despite healthy vision logs.

Note what is NOT a symptom any more: cover images failing to appear on editions.
Nothing writes a cover from the sidecar — `store_cover/3` and the association
loop were deleted together.

### Rolling vision back across an enum change

1. **Before rollback:** check the `_CLF_*` constants in
   `apps/vision/app/main.py` on the old tag against the three strings above.
2. **Roll back core first** if the old sidecar sends different strings, so the
   receiver is the tolerant side for the whole window.
3. **Verify:** POST a known book image to `/analyze` and confirm the response
   `classification` is one of the three strings, and that core resolves a book
   from it.
4. **Monitor:** moderation outcomes, since the catch-all is silent.

### Verifying wire format alignment

`scripts/check-enum-coverage.py` is the gate: it compares each proto enum
against the Elixir and Python code that handles it. `ClassificationResult` is
covered there, with one recorded exemption at
`apps/core/lib/mix/tasks/eval.vision.ex:156`.

⚠️ The old version of this section claimed CI caught enum drift "indirectly"
via `internal_controller_test.exs`. That test file no longer contains any
association tests, so that claim is now false in two ways — cite the enum
coverage gate instead.

---

## Post-rollback verification

- [ ] **Modal app reports the prior commit.** `modal app list` shows
      `thestacks-vision` and the rollback log shows `==> Deploying with
      MODAL_PREV_COMMIT=<sha>`.
- [ ] **`/health` returns 200.** From core, via the URL in
      `Application.get_env(:stacks, :vision_service_url)`.
- [ ] **A test upload identifies a known book.** Expect a 15–30 s cold
      start; subsequent uploads should be faster.
- [ ] **Audit row written.** Whether via the composite action's
      `log-audit` step or a manual remsh call:
      ```sql
      SELECT occurred_at, action, resource_id
        FROM audit.audit_log
       WHERE action = 'system.rollback'
       ORDER BY occurred_at DESC
       LIMIT 1;
      ```
- [ ] **`[:stacks, :system, :rollback]` telemetry visible in Axiom.**
- [ ] **Classification strings align.** ⚠️ This step used to read "no
      wire-format telemetry firing — `[:stacks, :vision, :unknown_association_status]`
      should be flat." That event no longer exists (deleted 2026-10-15 with the
      association loop), and a checklist item that can never fail is worse than
      none. There is no telemetry on the surviving enum's catch-all, so check it
      by behaviour instead: upload a known book image and confirm it resolves to
      a book rather than landing as `:unknown`.

---

## Related

- [`docs/runbooks/manual-rollback.md`](manual-rollback.md) — full
  composite-action rollback procedure (core + DB + vision).
- [`docs/runbooks/modal-outage.md`](modal-outage.md) — when the deploy
  is healthy but Modal itself is degraded.
- [`docs/decisions/001-modal-over-together-ai.md`](../decisions/001-modal-over-together-ai.md)
  — why Modal owns vision inference.
- [`docs/decisions/015-vision-service-architecture.md`](../decisions/015-vision-service-architecture.md)
  — current inference stack (HF Transformers + Qwen2.5-VL-7B-Instruct
  on A10G, post-2026-05 rollback of the vLLM/H100 experiment).
- [`issues/complete/137-rollback-action-composite.md`](../../issues/complete/137-rollback-action-composite.md)
  — design rationale, data-loss contract, and ordering invariant for the
  composite action.
- [`.github/actions/rollback-production/action.yml`](../../.github/actions/rollback-production/action.yml)
  — composite action contract; `MODAL_PREV_COMMIT` input semantics.
- [`.github/workflows/tag-main.yml`](../../.github/workflows/tag-main.yml)
  — stamps `main-<sha>` tags after every successful prod deploy; source
  of truth for `MODAL_PREV_COMMIT` resolution.
- [`apps/core/lib/stacks/audit.ex`](../../apps/core/lib/stacks/audit.ex)
  — `Stacks.Audit.log_rollback/1`, the audit + telemetry helper.
- `proto/stacks/internal/v1/vision.proto` — canonical enum definition.
- `apps/vision/app/main.py` — the `_CLF_*` classification constants.
- `apps/core/lib/stacks/moderation.ex` — `classification_outcome/1`, the Elixir
  side of the enum, including its silent catch-all.
  ⚠️ This list pointed at `_STATUS_CONFIRMED`/`_STATUS_REJECTED` and
  `@status_confirmed`/`@status_rejected` until 2026-10-15. All four were deleted
  with the association callback; an operator following them would have found
  nothing.
- `docs/decisions/006-ambiguous-classification-as-rejection.md`
