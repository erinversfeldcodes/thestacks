# Runbook: recover an account locked out by a lapsed email change

Operator procedure for a reader who cannot sign in and whose account is in the
**degraded** state.

## What the state is

A reader asked to change their email address. The change parks as `pending_email`
while the account keeps answering on its settled address, and two links go out:
a confirmation link to the new address, and an undo link to the old one.

If neither is used within seven days, a nightly sweep withdraws the account's
confirmed status. The account keeps everything — shelves, placements, posts — but
`RequireConfirmedEmail` now refuses it.

**The reader cannot fix this themselves.** The settings page that would let them
is behind the gate they now fail, and "resend confirmation email" refuses them
for an unrelated reason (that path is gated on account *age*, so an established
account is always past its ceiling and gets `past_renewal_ceiling` — a refusal
whose stated reason has nothing to do with their situation). The undo link in
their old mailbox is otherwise the only way back, and it expires after 30 days,
after which nothing at all can restore the account without this procedure.

## How to recognise it

The reader will describe being told their email isn't confirmed, on an account
they have used for a long time. They may mention having recently tried to change
their email address, or having typo'd the new one.

**Verify before acting** — a degraded account and an abandoned signup look
identical on `email_confirmed` alone, and they are opposites:

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://<host>/api/admin/degraded_accounts | jq
```

Each entry gives `user_id`, the settled `email`, the `pending_email` they were
waiting on, and `pending_email_sent_at`. The list is ordered oldest-first, so the
accounts closest to losing their undo link appear at the top.

If the reader is **not** in this list, they are not degraded and this is the wrong
runbook. In particular, do not reach for it for an unconfirmed *signup* — those
are a different population that the reaper erases by design.

## The recovery

```bash
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<user_id>"}' \
  https://<host>/api/admin/degraded_accounts/restore | jq
```

This does exactly what the reader's undo link would have done: clears the pending
change and confirms the settled address. It answers `{"ok": true, "email": "..."}`
with the address the account now answers on.

It also writes an `admin.account_restored` audit row naming you and your admin
session. That is deliberate — an operator reaching into an account and putting it
back is exactly the kind of action that should leave a trace.

## What the reader experiences afterwards

- They sign in with **their original email address** and their existing password.
  Tell them this explicitly: they may be expecting the new address to work, and it
  does not — the change was abandoned, not completed.
- **All their sessions were revoked**, so any device that was still signed in is
  now signed out. This is intentional: someone reverting an email change may be
  saying "that wasn't me", and a change made from a stolen session is not undone
  while that session is still open. Warn them so it does not read as a fault.
- Their shelves, placements and posts are untouched. Nothing was deleted at any
  point; only confirmed status was withdrawn.
- If they still want to change their email, they can start again from settings
  once signed in.

## Failure modes

| Response | Meaning | What to do |
|---|---|---|
| `404 user_not_found` | No account with that id | Re-check the id from the list above |
| `422 not_degraded` | The account is not in the degraded state | Confirm it appears in `/degraded_accounts`; if it does not, this is a different problem |
| `422 restore_failed` | The update itself failed | Check the logs; the account is unchanged, so it is safe to retry |

## Related

- `Stacks.Accounts.list_degraded_accounts/0` and `restore_degraded_account/1` are
  the functions behind these endpoints.
- `Stacks.Workers.ExpiredEmailChangesJob` is the sweep that creates this state.
- `docs/runbooks/gdpr-erase-user.md` covers erasure, which is a different thing —
  nothing here deletes anything.
