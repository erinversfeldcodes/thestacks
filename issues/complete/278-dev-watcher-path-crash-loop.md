# Issue #278: Phoenix Dev Asset Watcher Crash-Loops on a Doubled Path

## Summary
`apps/core/config/dev.exs:34` builds the esbuild watcher's working directory as
`Path.expand("../apps/core/assets", __DIR__)`, which resolves to
`<repo>/apps/core/apps/core/assets` — a path that does not exist. Every `mix phx.server` in dev
spawns the watcher, fails, and restarts it, flooding the log with `:watcher_command_error`
stacktraces. Live asset rebuilds are silently dead in dev.

## User Stories
None — developer-tooling defect.

## Goal
`mix phx.server` starts with no watcher errors and rebuilds assets on file change.

## Scope Check
- More than 3 controllers? No — one config line.
- More than 2 new endpoints? No — none.
- More than ~300 lines of production code? No — one line.
- Combines unrelated concerns? No.

## Wiring
Router wiring: implementation-only — a dev-environment config fix with no user-facing surface.

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements

`apps/core/config/dev.exs:33-35`:

```elixir
watchers: [
  node: ["build.js", "--watch", cd: Path.expand("../apps/core/assets", __DIR__)]
]
```

`__DIR__` is `<repo>/apps/core/config`. `Path.expand("../apps/core/assets", __DIR__)` therefore
yields `<repo>/apps/core/apps/core/assets`. The correct expression is
`Path.expand("../assets", __DIR__)` → `<repo>/apps/core/assets`, which is where `build.js` lives.

Observed verbatim from `/tmp/stacks-phoenix.log` during the #270 live drive:

```
** (stop) :watcher_command_error
    (phoenix 1.8.9) lib/phoenix/endpoint/watcher.ex:55: Phoenix.Endpoint.Watcher.watch/2
    (elixir 1.18.4) lib/task/supervised.ex:101: Task.Supervised.invoke_mfa/2
Function: &Phoenix.Endpoint.Watcher.watch/2
    Args: ["node", ["build.js", "--watch", {:cd, "/Users/erinversfeld/thestacks/apps/core/apps/core/assets"}]]
spawn: Could not cd to /Users/erinversfeld/thestacks/apps/core/apps/core/assets
[error] Task #PID<0.784.0> started from CoreWeb.Endpoint terminating
```

This repeats continuously. It is **cwd-independent** — `Path.expand/2` is anchored to `__DIR__`, so
`just dev` (which runs `mix phx.server` from the repo root) hits it identically.

Impact: the log noise masks real errors during live drives (a Completion Bar §4 concern — "logs are
clean under the live drive"), and dev asset hot-rebuild does not work, so developers must run
`cd apps/core/assets && npm run deploy` manually after every frontend edit.

## Reviewer Context
- `just dev` (`justfile:22-23`) already runs `npm run deploy` once at startup, which is why the broken
  watcher has gone unnoticed — the initial build succeeds and only the *watch* is dead.
- The asset build lives at `apps/core/assets/build.js`; `npm run deploy` maps to
  `node build.js --production` (`apps/core/assets/package.json`).
- Verify the fix under the pinned toolchain (`just run mix phx.server`), never bare `mix`.

## Test Audit
Compact format — a dev-only config fix.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Config correctness | yes | ❌ — nothing asserts the watcher path resolves to an existing directory. Add an assertion that `Application.get_env(:core, CoreWeb.Endpoint)[:watchers]`'s `:cd` exists, or a `just doctor` check. |
| 1–13 (app/US layers) | no | n/a — dev-environment config only; no runtime, data, or user-facing surface. |

Verdict: ❌ — one punch item.

## Definition of Done
- [ ] `dev.exs` watcher `cd` resolves to `<repo>/apps/core/assets` — evidence: `mix phx.server` startup log free of `:watcher_command_error`
- [ ] Editing a `frontend/src/*.elm` file triggers a rebuild in a running `just dev` — evidence: watcher output observed
- [ ] A guard prevents regression — evidence: test or `just doctor` check asserting the watcher directory exists
- [ ] Standards compliance verified (`just verify` passes)
- [ ] **Test audit (embedded above) is GREEN** — 0 ❌, 0 ⚠️
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — each item with an evidence token

## Dependencies
None. Discovered by the #270 live drive.

## Agent Assignment
`elixir-agent` or `platform-agent`

## Progress Notes
Filed 2026-07-21 by the #270 live-drive gate. The error was observed in `/tmp/stacks-phoenix.log`
while standing up the local stack; it is pre-existing and unrelated to US-1.2.5/US-1.2.1, but it is
the only non-clean entry in the server log for that drive.
