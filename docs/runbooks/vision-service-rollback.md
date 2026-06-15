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

The vision service and core use proto enum string values for
`AssociationStatus`:

- `ASSOCIATION_STATUS_CONFIRMED` — cover association succeeded
- `ASSOCIATION_STATUS_REJECTED` — cover association rejected (check `reason`)

These strings must match between Python (sender) and Elixir (receiver).
A mismatch causes the catch-all `dispatch_association/2` clause to fire
— associations are silently discarded with a `Logger.warning` and a
`[:stacks, :vision, :unknown_association_status]` telemetry event. No
error is returned to the vision service (it must not retry on app
errors).

### Always deploy Elixir (core) before Python (vision)

- Elixir is backward-compatible: unknown status strings fall to the
  catch-all with a warning and telemetry, not a crash.
- Python is forward-only: it immediately sends the new enum strings
  once deployed.

Deploying Python first creates a window where Elixir receives strings
it does not recognise, silently dropping all cover associations until
Elixir is updated. The composite action's core-then-vision ordering
preserves this invariant during rollback as well.

### Symptoms of a wire format mismatch

1. `[:stacks, :vision, :unknown_association_status]` telemetry events firing.
2. Log lines: `InternalController: unknown status "..." received` in core logs.
3. Cover images not appearing on book editions despite vision service logs showing success.
4. Vision service logs show `200` responses but no DB updates in core.

### Rolling vision back across an enum change

If you need to roll back Python to a pre-enum version while core is on
the new enum strings:

1. **Before rollback:** check `_STATUS_CONFIRMED` and `_STATUS_REJECTED`
   constants in `apps/vision/app/main.py` on the old tag. If they use
   old strings (e.g., `"confirmed"`, `"rejected"`), proceed.
2. **Notify:** alert #ops that cover associations will be silently
   dropped during the window.
3. **Roll back core first** to the version whose `dispatch_association/2`
   accepts the old strings (composite action handles this ordering
   automatically), then roll back vision.
4. **Verify:** send a test association callback with the old status
   string and confirm it is handled (not caught by the catch-all).
5. **Monitor:** watch `[:stacks, :vision, :unknown_association_status]`
   telemetry — it should drop to zero after both services are aligned.

### Verifying wire format alignment

The `InternalController` module attributes `@status_confirmed` and
`@status_rejected` are the authoritative Elixir-side enum strings. They
must match the JSON names of `AssociationStatus` in
`proto/stacks/internal/v1/vision.proto`.

CI catches this indirectly: `internal_controller_test.exs` sends the
expected strings and asserts correct DB behaviour. If the strings
drift, those tests fail.

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
- [ ] **No wire-format telemetry firing.**
      `[:stacks, :vision, :unknown_association_status]` should be flat.

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
- `apps/vision/app/main.py` — `_STATUS_CONFIRMED`, `_STATUS_REJECTED` constants.
- `apps/core/lib/stacks_web/controllers/internal_controller.ex` —
  `@status_confirmed`, `@status_rejected` constants.
- `docs/decisions/006-ambiguous-classification-as-rejection.md`
