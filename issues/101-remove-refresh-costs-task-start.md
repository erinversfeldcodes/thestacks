# Issue #101: Remove Task.start + Process.sleep from Application.start

## Summary
`application.ex` uses `Task.start` with `Process.sleep(5_000)` to enqueue an initial `RefreshCostsJob` after boot. This is fragile — if Oban takes longer than 5 seconds to start, the job insertion fails silently.

## Goal
Remove the `Task.start` block. The daily cron (`0 6 * * *`) already handles recurring cost refresh. If an immediate refresh on boot is needed, use a more reliable mechanism.

## Scope Check
- Remove ~6 lines from application.ex
- ~5 min

## Technical Requirements
- Remove the `Task.start` block from `application.ex`
- If immediate-on-boot refresh is genuinely needed, consider `Oban.insert` in a supervised `handle_continue` callback, or just rely on the daily cron
- Verify RefreshCostsJob tests still pass

## Definition of Done
- [ ] No `Task.start` or `Process.sleep` in application.ex
- [ ] Costs still refresh on the daily cron schedule
- [ ] `just verify` passes

## Priority
P2 — fix during Wave E

## Agent Assignment
elixir-agent
