# Runbook: Vision Service Rollback

**Severity:** P1 (silent data loss risk if enum wire format mismatches)
**Owner:** Platform operator
**Last reviewed:** 2026-03-26

---

## Background

The vision service and core use proto enum string values for `AssociationStatus`:
- `ASSOCIATION_STATUS_CONFIRMED` — cover association succeeded
- `ASSOCIATION_STATUS_REJECTED` — cover association rejected (check `reason`)

These strings must match between Python (sender) and Elixir (receiver). A mismatch causes
the catch-all `dispatch_association/2` clause to fire — associations are silently discarded
with a `Logger.warning` and a `[:stacks, :vision, :unknown_association_status]` telemetry
event. No error is returned to the vision service (it must not retry on app errors).

---

## Deploy Ordering

**Always deploy Elixir (core) before Python (vision).**

- Elixir is backward-compatible: unknown status strings fall to the catch-all with a warning
  and telemetry, not a crash.
- Python is forward-only: it immediately sends the new enum strings once deployed.

Deploying Python first creates a window where Elixir receives strings it does not recognise,
silently dropping all cover associations until Elixir is updated.

---

## Symptoms of a Wire Format Mismatch

1. `[:stacks, :vision, :unknown_association_status]` telemetry events firing.
2. Log lines: `InternalController: unknown status "..." received` in core logs.
3. Cover images not appearing on book editions despite vision service logs showing success.
4. Vision service logs show `200` responses but no DB updates in core.

---

## Rolling Back the Vision Service

If you need to roll back the Python vision service to a pre-enum version while core is on
the new enum strings:

1. **Before rollback:** check `_STATUS_CONFIRMED` and `_STATUS_REJECTED` constants in
   `apps/vision/app/main.py` on the old tag. If they use old strings (e.g., `"confirmed"`,
   `"rejected"`), proceed to step 2.
2. **Notify:** alert #ops that cover associations will be silently dropped during the window.
3. **Roll back core first** to the version whose `dispatch_association/2` accepts the old
   strings, then roll back vision.
4. **Verify:** send a test association callback with the old status string and confirm it
   is handled (not caught by the catch-all).
5. **Monitor:** watch `[:stacks, :vision, :unknown_association_status]` telemetry — it
   should drop to zero after both services are aligned.

---

## Verifying Wire Format Alignment

The `InternalController` module attributes `@status_confirmed` and `@status_rejected` are
the authoritative Elixir-side enum strings. They must match the JSON names of `AssociationStatus`
in `proto/stacks/internal/v1/vision.proto`.

CI catches this indirectly: `internal_controller_test.exs` sends the expected strings and
asserts correct DB behaviour. If the strings drift, those tests fail.

---

## Related

- `proto/stacks/internal/v1/vision.proto` — canonical enum definition
- `apps/vision/app/main.py` — `_STATUS_CONFIRMED`, `_STATUS_REJECTED` constants
- `apps/core/lib/stacks_web/controllers/internal_controller.ex` — `@status_confirmed`, `@status_rejected`
- `docs/decisions/006-ambiguous-classification-as-rejection.md`
