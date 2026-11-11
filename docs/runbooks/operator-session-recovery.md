# Runbook: An operator cannot sign in to their own platform

**Severity:** P1 (the platform owner has no administrative access)
**Owner:** Platform operator (this is the runbook for recovering yourself)
**Last reviewed:** 2026-11-07

---

## When to use this runbook

Use this when **you** — a platform operator — cannot establish a session, while
the platform itself is serving readers normally. The distinguishing symptom is
that `/api/health` is fine and other people are using the site; the fault is in
your own session state, not in the stack.

⛔ **This is the lockout ADR-024 §8 names as the one change in the
session-transport wave that can lock the owner out of production.** The session
moved from a bearer token the client held to an `HttpOnly` cookie the server
sets, and a cookie that is refused looks exactly like being signed out: there is
no token to inspect, no header to retry with, and nothing in the browser you can
read to tell the two apart.

Symptoms that fit:

- Signing in appears to succeed, and the next request is 401.
- Signing in succeeds in a private window but not your normal one, or the
  reverse.
- A session that worked before a deploy stops working after it, for you only.

Symptoms that do **not** fit — use another runbook:

- Authenticated requests failing for *everyone* → `auth-session-family-outage.md`
  (the fail-closed family gate).
- Sign-in rejected with a credentials error rather than a later 401 → an ordinary
  wrong password; use the reset flow.

## Preconditions

You need **all** of these. The task cannot be run from CI or a workflow, by
design.

| Precondition | Why |
|---|---|
| Shell access to the running machine (`fly ssh console -a <app>`) | the guard is set on the invocation, which needs a shell |
| The operator's **email address** | the task resolves the account by email, not by id |
| Your own name or handle, for the audit row | the task refuses without an actor |
| A reason, in words | recorded with the row; the task refuses without one |

⚠️ **You do not need, and will not be given, a session.** The task clears stale
session state so that an ordinary sign-in works; it does not mint a credential.
A release task that handed out a session over `rpc` would be a more attractive
target than the lockout it fixes.

## What to do

```sh
fly ssh console -a <app>

# Base64(JSON), so the reason text crosses the rpc boundary with no shell or
# Elixir injection surface.
#
# ⛔ `tr -d '\n'` IS LOAD-BEARING. `base64` wraps at 76 columns and this payload
# is longer than that, so without it the argument arrives containing a newline.
# The task now tolerates one, but older builds raise `ArgumentError` here.
PAYLOAD=$(printf '%s' \
  '{"email":"you@example.com","actor":"your-name","reason":"cookie transport refused after deploy","confirm":"yes-recover-this-operator"}' \
  | base64 | tr -d '\n')

/app/bin/core rpc "Stacks.Release.recover_operator_access(\"$PAYLOAD\")"
```

⛔ **THE CONFIRMATION IS A FIELD IN THE PAYLOAD, NOT AN ENVIRONMENT VARIABLE —
AND THIS CORRECTS AN EARLIER VERSION OF THIS RUNBOOK THAT COULD NOT WORK.**

This page used to say `STACKS_OPERATOR_RECOVERY=1 /app/bin/core rpc …`. That can
never succeed: `rpc` evaluates inside the **already-running node**, which does
not see the invoking shell's environment. Measured on a deployed stack
2026-11-07 — with the variable set, `printenv` in the shell read `1` while
`System.get_env("STACKS_OPERATOR_RECOVERY")` evaluated inside the node read
**nil**. The task refused every time, on the one path standing between an
operator and a permanent lockout.

⚖️ `"confirm":"yes-recover-this-operator"` does the job the variable was meant to
do — nobody types it by accident, so a stray `rpc` in a script or a workflow
cannot fire it — and it crosses the boundary by construction, because it travels
inside the argument.

⚠️ **`rpc`, never `eval`.** `eval` starts a second BEAM, which OOMs a 512 MB
machine and reports nothing useful — roughly eleven seconds and an `EOF`.

## What you will see

On success, one line:

```
OPERATOR_RECOVERY_OK user_id=<uuid> email=you@example.com actor=your-name
```

Then sign in normally. The old session state is gone, so the sign-in starts
clean.

On refusal, one of:

| Message | Meaning |
|---|---|
| `refusing to recover operator access: add "confirm":"yes-recover-this-operator" …` | the guard; the payload carried no confirmation, or a different one. ⚠️ Setting an environment variable will NOT help — see above. |
| `OPERATOR_RECOVERY_ERROR no user with email=…` | the address does not resolve — check for a typo before assuming the account is gone |
| `operator recovery aborted: actor is required` | the audit row cannot be written without naming who acted |

## What it does, exactly

1. Revokes every live session family for that user (`revoked_at` set).
2. Deletes every one of their `guardian_tokens` rows, so no existing access
   token survives.
3. Writes an `operator.access_recovered` audit row against the subject, with the
   **actor** and the **reason** in its encrypted metadata.

⚖️ Steps 1–2 are `Stacks.Accounts.revoke_all_user_sessions/1`, the same function
a password change uses. This task is the operator-facing door onto it, not a
second implementation.

## Why the guard is weaker than the seeding guard

⚠️ **And why it is not an env var at all.** `Stacks.Release.seed_live/0` is gated
on `STACKS_E2E_TEST_HELPERS`, an env the preview stack is **deployed** with and
production never carries — because seeding
production is never correct, so the gate should be impossible to satisfy there.

⛔ That pattern would make this task useless. Recovering an operator **is**
correct on production, which is the only place the lockout matters. So the gate
is one you set on the invocation: it cannot fire from a stray `rpc` in a script
or a workflow, but it can always be satisfied by someone who means to, standing
at a shell.

## After

- Read the audit row back, so the record is confirmed rather than assumed.
- If the cause was a deploy, say so on the deploy's issue: a transport fault that
  locked out one operator will lock out the next.
