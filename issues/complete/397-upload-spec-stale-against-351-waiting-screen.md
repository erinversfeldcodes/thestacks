# Issue #397: upload.spec.ts asserts the pre-#351 waiting screen — the Modal project has been red-invisible since the rework

**Status:** Complete (2026-08-10)
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
- [x] `upload.spec.ts` re-validated line-by-line against the post-#351 upload
      surface — evidence: 8 sites moved to `toContainText("Reading your
      photo...")` on the container (robust to the sending→reading transition
      and the #351 leave-note second paragraph); the duplicate-notice test now
      asserts the notice on the completion card, the FIRST place the one-hop
      manual path (#343) can say it — the pre-submit notice it used to expect
      never existed on this path
- [x] The full `upload` project green against a preview with vision deployed —
      evidence: **16/16 passed** (upload-project5 run, 2026-08-10, deploy8
      preview with Modal vision; real Qwen inference, no mocks). Two
      world-drift causes fixed en route: the "nonexistent" fixture
      9780000000019 now RESOLVES on Open Library (the gate working — fixture
      replaced with 9789991234564, chosen by probing BOTH catalogues empty;
      even unallocated-group ISBNs collide with junk records), and a stack
      whose Neon credentials have died reads as total E2E failure (fresh auth
      after any redeploy is part of the procedure)
- [x] Together model retirement checked against every configured model —
      evidence: vision runs Qwen on Modal directly (unaffected);
      `TogetherClient`'s two request builders both used the retired
      `Llama-3-8b-chat-hf`, now single-sourced (`@model`) and pointed at
      `Llama-3.3-70B-Instruct-Turbo` — the smallest surviving serverless
      Llama, established by LIVE probes (3.1-8B-Turbo and 3.2-3B refuse
      identically; 3.3-70B-Turbo answers)
- [x] The chromium/upload project split documented in the spec header so the
      next rework knows these tests do not run routinely — evidence: header
      block in upload.spec.ts naming the gap and its cost

## Why this is not Wave 11 scope
Wave 11 touches no upload/vision code (scope-lock: new discoveries become new
issues). The wave's `just ci` evidence cites this issue as the one non-green
e2e project, with all 16 code gates and the chromium project green.

## Progress Notes
- 2026-08-10: Filed from the Wave 11 close-out. Diagnosis evidence in
  `#321`'s "just ci" notes; failing-run log preserved in the session
  scratchpad (`ci-final3.log`).
- 2026-08-10 (close): Owner pulled #397 into Wave 11. All four boxes done;
  final evidence run 16/16 green on real inference. staff-review verdict:
  **LGTM** — the fixture corrections encode their reasoning in place
  (probe-chosen ISBN, notice asserted where the architecture can produce it),
  and the header note is what keeps this file from going stale invisibly
  again.
