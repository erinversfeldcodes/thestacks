# Issue #358: `e2e_warmup_guard_test.sh` never terminates — two stub defects, no service bug

## Summary
Reported by #337 as "ran 15+ minutes with no tally". Diagnosed by the lead 2026-07-31: **the test hangs forever, and the code under test is fine.** Both defects are in the test's own stubs.

The suite reaches `# === remote_mode_healthy ===` and never leaves it. No `curl` process exists while it hangs — it is spinning in shell, with a `sleep 3` per iteration, so it burns wall-clock rather than CPU and produces no output.

## Root cause 1 — the stubbed clock is a constant, so a deadline derived from it is never reached
`test/platform/e2e_warmup_guard_test.sh` stubs `date` to return `1000` on the first call and **`100000` on every call thereafter**. That is correct for `wait_for_health`, whose deadline is computed *before* the jump (`1000 + 60 = 1060`), so the very next check trips it instantly — which is exactly what the stub's comment describes.

But `warm_remote_preview` runs a **second** loop after `wait_for_health` (`scripts/test-e2e.sh`, the login-POST warm added for Issue #269), and that loop computes its deadline from the *already-jumped* clock:

```bash
local deadline=$(( $(date +%s) + 60 ))     # 100000 + 60 = 100060
while [[ $(date +%s) -lt $deadline ]]; do  # 100000 < 100060 → true, forever
    ...
    sleep 3
done
```

The stub returns `100000` for every subsequent call, so the condition is **permanently true**. The loop cannot exit by timeout.

## Root cause 2 — the stubbed curl emits nothing, so the success branch is unreachable
The loop's exit condition is a non-empty, non-502, non-000 HTTP code:

```bash
code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST … )"
if [[ -n "$code" && "$code" != "502" && "$code" != "000" ]]; then return 0; fi
```

The stub is `curl() { echo "call $*" >> "$CURL_LOG"; return 0; }` — it appends to a log file and **writes nothing to stdout**, ignoring `-w "%{http_code}"`. So `code` is always the empty string, `-n "$code"` is false, and the early return can never fire. Even with a clock that advanced, this test case would run the full 60s and then *fail* rather than pass.

Together: unreachable success branch **and** a deadline that never arrives.

## What is NOT wrong
- **`warm_remote_preview` is correct.** In production, real `curl -w "%{http_code}"` prints a status and real `date` advances, so both exits work.
- **`wait_for_health` is correct**, including its deliberate no-`sleep` comment — real curl's `--max-time 2` paces it. (⚠️ Worth noting separately: against a host that *refuses* instantly rather than hanging, that loop is a hot spin for the full timeout. Bounded, so not this bug, but not free either.)
- The 14 suites ahead of this one, including all four migration suites, are green.

## User Stories
None — test-harness correctness.

## Scope Check
One test file's stubs. Small.

## Wiring
Router wiring: none.

## Technical Requirements
1. **Make the clock stub monotonic**, not a two-value step. Returning `base + N*step` per call satisfies both loops: `wait_for_health`'s deadline (computed early) still trips quickly, and any loop computing its deadline later still reaches it. A stub that models "time passes" rather than "time has jumped" is the general fix.
2. **Make the curl stub honour `-w`** — or at minimum return a settable status code on stdout so the caller's parse succeeds. The current stub can only ever exercise failure paths for any caller that reads curl's output, which silently narrows what the suite can test.
3. **Bound the suite.** A harness test that can hang forever will hang CI. Wrap the run (or each case) in a hard timeout so a future stub defect fails loudly instead of stalling — the failure mode here was *no output at all*, which is the worst kind.
4. **Then assert what the test claims to.** `remote_mode_healthy` currently asserts `warm_remote_preview` returns 0 in the healthy case; with the stubs fixed, verify it actually does, and that the login-POST warm is exercised rather than skipped.

## Reviewer Context
- ⚠️ **`test/platform/run_all.sh` runs this suite** — until it is fixed, a full platform-test run does not terminate. That is the practical urgency, not the correctness of the code under test.
- The stub design is sound in intent; the comment explaining the clock jump is accurate about `wait_for_health` and simply predates the second loop `warm_remote_preview` grew. Fix the stub, don't remove the technique.
- Related: #175 (the warmup guard this tests), #269 (the login-POST warm that added the second loop), #337 (reported the hang).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Harness | yes | ❌ the suite terminates — probe: run it, it must finish |
| Harness | yes | ❌ `remote_mode_healthy` passes for the right reason (success branch reached, not timed out) |
| Harness | yes | ❌ a hard timeout turns a future hang into a failure |
| Others | no | n/a |

## Definition of Done
- [ ] Clock stub monotonic — evidence: diff
- [ ] curl stub returns a status on stdout — evidence: diff
- [ ] Suite terminates and `run_all.sh` completes — evidence: tally + wall-clock
- [ ] `remote_mode_healthy` reaches the success branch — evidence: assertion on the warm message
- [ ] `staff-review` verdict recorded below

## Dependencies
None. Reported by **#337**; diagnosed by the lead. Needs an owner wave assignment.

## Agent Assignment
devops / platform-test agent.

## Progress Notes
Filed 2026-07-31 by the lead, after the owner asked to determine whether the hang was a script bug or a service bug. **It is a script bug — two of them, both in the stubs.** Diagnosis method: ran the suite in the background, watched it stall at `remote_mode_healthy`, confirmed no `curl` process was alive (so it was not blocked on the network), then read `warm_remote_preview` and found the second loop whose deadline derives from the stubbed constant clock. Process killed; nothing else was affected.
