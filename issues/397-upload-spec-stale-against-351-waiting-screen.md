# Issue #397: upload.spec.ts asserts the pre-#351 waiting screen — the Modal project has been red-invisible since the rework

**Status:** Open
**Priority:** P2
**Created:** 2026-08-10
**Surfaced by:** Wave 11's full `just ci` run (the first to execute the `upload` Playwright project since #351 landed)

## Summary

Four sites in `e2e/tests/upload.spec.ts` (lines 33, 116, 322, 392) assert
`upload-loading` shows **"Processing image..."** — copy that #351's
waiting-screen rework deliberately removed (`Page.Upload.elm`'s `viewWaiting`
moduledoc documents the removal verbatim: *"This screen used to be a spinner
and the words `Processing image...`, forever"*). Every routine E2E run uses
`--project=chromium`, which `testIgnore`s `upload*.spec.ts` (the Modal-GPU
gating), so the stale expectations sat unexecuted from #351 until Wave 11's
full-projects `just ci` ran them: **9 failed / 3 retries each**, while the
non-pipeline members of the same file (duplicate-detection, manual-ISBN) pass.

Not all nine may be copy-only: the multi-book identification tests time out at
1.0m per attempt, which could be stale step expectations OR a real vision-path
state (the same run's core logs also show Together refusing
`meta-llama/Llama-3-8b-chat-hf` as `model_not_available` — serverless
retirement — in `PostBookAssociationWorker`, worth checking for shared fallout
in the vision LLM tier).

## Definition of Done
- [ ] `upload.spec.ts` re-validated line-by-line against the post-#351 upload
      surface (waiting copy, SSE progress states, terminal states) — every
      assertion describes the UI that exists
- [ ] The full `upload` project green against a preview with vision deployed —
      or each residual failure attributed to a named external cause with its
      own issue
- [ ] Together model retirement checked against every configured model
      (vision LLM tier + `PostBookAssociationWorker`); retired models replaced
- [ ] The chromium/upload project split documented in the spec header so the
      next rework knows these tests do not run routinely

## Why this is not Wave 11 scope
Wave 11 touches no upload/vision code (scope-lock: new discoveries become new
issues). The wave's `just ci` evidence cites this issue as the one non-green
e2e project, with all 16 code gates and the chromium project green.

## Progress Notes
- 2026-08-10: Filed from the Wave 11 close-out. Diagnosis evidence in
  `#321`'s "just ci" notes; failing-run log preserved in the session
  scratchpad (`ci-final3.log`).
