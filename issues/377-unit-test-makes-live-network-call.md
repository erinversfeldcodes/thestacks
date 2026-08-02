# Issue #377: A unit test reaches the public internet, and the timeout that was supposed to bound it doesn't

## Summary
Found by the #373 agent during Wave 7, while hunting an intermittent full-suite failure it had twice
truncated away. Root-caused, located, and reported rather than dismissed as flake.

`DiscoverAuthorSourcesJobTest` **looks** mocked — it sets up `MockBraveClient` — but the job it drives
then probes the discovered URL for a feed with a **real network call**
(`apps/core/lib/stacks/workers/discover_author_sources_job.ex:137-140`):

```elixir
defp try_fetch_feed(url) do
  req = Finch.build(:head, url)
  case Finch.request(req, Stacks.Finch, receive_timeout: 5_000) do
```

The mock returns `https://authorsite.com` — a **real, resolvable third-party domain** — so the suite
issues a live HEAD request to a host nobody here controls.

## Why the 5 s bound does not save it
`receive_timeout` bounds only the **receive** phase. The TLS **connect** is unbounded, so when the
handshake hangs the call runs to ExUnit's 60 s test timeout:

```
1) test perform/1 with author_id discovers website for an author
   ** (ExUnit.TimeoutError) test timed out after 60000ms
   stacktrace:
     (ssl 11.5.4) ssl_gen_statem.erl:290: :ssl_gen_statem.handshake/2
     (ssl 11.5.4) ssl.erl:2315: :ssl.connect/4
     (mint 1.9.1) lib/mint/core/transport/ssl.ex:345: Mint.Core.Transport.SSL.connect/4
     (finch 0.23.0) lib/finch/http1/pool.ex:52: Finch.HTTP1.Pool.request/6
```

It passes when the connection fails fast and times out when the handshake hangs — which is why it
reads as flake. ⚠️ The function's `rescue` clause does not help: a hang is not an exception.

## Why this is worse than a flaky test
1. **The suite is not hermetic.** Every local and CI run makes an outbound request to a domain
   outside this project's control. What that host returns — or how long it takes — is part of our
   build's behaviour.
2. **It costs a whole run 60 s and a red result**, intermittently, for reasons unrelated to any diff.
   That is exactly the shape that teaches people to disbelieve the suite. ⚠️ Several Wave 7 agents
   reported intermittent failures they attributed to DB contention; those were mostly genuine
   contention (`too_many_connections`, Postgrex/Finch pool exhaustion under ~10 concurrent suites),
   but **this one is a distinct, reproducible cause** and should not be folded into that bucket.
3. **The fix pattern already exists in this codebase and simply was not applied here.** Commit
   `419da150`'s own message is *"uses swappable fetcher"* — for RSS polling. The seam exists; this
   probe just doesn't use it.

## User Stories
None — test-suite integrity. Protects every run.

## Scope Check
One function's transport seam plus its test wiring. Single concern.

## Technical Requirements
1. **Make the feed probe swappable in test**, the way RSS polling already is (`419da150`). ⚠️ Prefer
   this over merely tightening timeouts: a bounded live call is still a live call, and still makes
   the suite depend on a third party.
2. **Bound the connect phase regardless** — `conn_opts: [timeout: …]` — because production has the
   same hole. ⚠️ This is not only a test bug: a hung TLS handshake to a discovered author URL will
   park a production Oban worker for however long the peer keeps the socket open.
3. **Prove the suite makes no outbound request from this path.** A test asserting the mock was called
   is not enough; assert the real transport is never reached.
4. **Consider whether other jobs have the same shape.** This was found by accident. ⚠️ A sweep for
   `Finch.request` / `Finch.build` outside a swappable client is cheap and would say whether this is
   one site or a class. Report the count either way.

## Reviewer Context
- ⚠️ **Do not "fix" this by deleting or skipping the test.** It covers a real behaviour; the defect is
  the un-seamed transport, not the assertion.
- ⚠️ `receive_timeout` vs connect timeout is the trap. Anyone reading `receive_timeout: 5_000` will
  reasonably assume the call is bounded at 5 s. It isn't. Whatever you do, leave a comment saying so.
- Pre-existing: introduced by `55dc80bc` / `419da150`. **Untouched by #373's diff** — verified by the
  finder (`git diff --cached --name-only | grep -i discover` returns nothing).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir | yes | ❌ the feed probe is swappable; the suite reaches no real host — probe by asserting on the transport |
| Elixir | yes | ❌ connect phase bounded — probe by pointing at a black-holed host and asserting it returns, not hangs |
| Regression | yes | ❌ full suite runs N times with no 60 s timeout from this test |
| Sweep | yes | ❌ count of other un-seamed `Finch` call sites reported |

## Definition of Done
- [ ] Feed probe swappable in test — evidence: diff + the test asserting no real transport
- [ ] Connect phase bounded in production too — evidence: diff + probe against a black-holed host
- [ ] Suite runs clean across repeated seeds — evidence: the runs
- [ ] Sweep count of similar un-seamed call sites reported — evidence: the number
- [ ] `staff-review` verdict recorded below

## Dependencies
Found during **#373**, independent of it. No blocker. ⚠️ Worth doing before the campaign's remaining
integration gates, since it makes `just ci` intermittently and inexplicably red.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-08-02 by the lead, from the #373 agent's root-cause. The agent caught its own earlier
reporting error — it had twice piped full-suite runs through `tail -25` and discarded the failure
block, then reported the suite as clean. It re-ran with complete capture, reproduced the failure at
seed 760943, and retracted the earlier claim unprompted. Lead verified the mechanism directly:
`try_fetch_feed` at `discover_author_sources_job.ex:137-140` calls `Finch.request` with
`receive_timeout: 5_000` only, and the test at `discover_author_sources_job_test.exs:19` feeds it the
real domain `https://authorsite.com` while mocking solely the Brave search hop.
