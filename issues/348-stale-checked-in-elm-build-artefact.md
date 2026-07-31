# Issue #348: `frontend/index.html` is a stale, tracked Elm build artefact

## Summary
Found by #343. `frontend/index.html` is **39,680 lines of checked-in Elm build output**, tracked in git, and already stale: it still contains the `lookupByIsbn` function that #343 deleted from the source. It is the only remaining grep hit for that symbol in the repo.

It is **not served** — the app loads `app.js` produced by esbuild (`apps/core/priv/static/assets/` is build output; `frontend/css/main.css` is the only CSS source). So this is dead output under version control.

## Why it is worth an issue rather than a quiet delete
A stale build artefact that contains deleted code poisons every future `grep`. This campaign has repeatedly used repo-wide greps as evidence — "the DIY flow is gone: 0 matches", "no module under `lib/` matches `Mock*`" — and a 39k-line stale copy of the frontend is exactly the thing that turns a clean grep into a false positive or a false alarm. It also inflates every diff that touches it and every secret-scanner run.

## User Stories
None — repository hygiene.

## Goal
Build output is not tracked. A grep over the repo reflects the code that exists.

## Scope Check
One file plus a `.gitignore` entry. Trivial — but verify before deleting (see requirements).

## Wiring
Router wiring: none.

## Feature-Completeness Pre-Check
n/a.

## Technical Requirements
1. **Verify it is genuinely unserved before deleting.** Confirm nothing references `frontend/index.html` — the Phoenix static pipeline, `esbuild` config, any script in `scripts/`, the Dockerfiles, or a deploy step. The memory note says the browser loads `app.js` from esbuild and that `apps/core/assets/index.html` is the served template, but **verify rather than trust it**: a deploy that 404s its own index page is a bad way to find out.
2. **Delete it and add the path to `.gitignore`** if unserved. If some path *does* consume it, then it is generated output being consumed as a source — say so, and the fix is to generate it at build time instead.
3. **Check for siblings.** Look for other tracked build output under `frontend/` and `apps/core/priv/static/` and report what you find. `git ls-files` is the authority here, not the filesystem — this project has been bitten before by assuming a generated file's tracked status (see the "verify gitignore claims" convention).
4. **Re-run the campaign's grep-based claims** afterwards if the file went away, so their counts stay true.

## Reviewer Context
- ⚠️ **Verify tracked-vs-ignored with `git ls-files`**, not by looking at `.gitignore` — agents get this wrong and it fails silently. (`frontend/index.html` was confirmed tracked this way.)
- Deleting checked-in output can break a build that quietly depended on it; run `bash scripts/build-assets.sh` (or the project's equivalent) and a preview deploy before declaring done.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Build | yes | ✅ clean `node build.js --production` green after removal; output byte-identical to the pre-deletion baseline |
| Unit | yes | ✅ `page_controller_test.exs` + `robots_txt_test.exs` — 8 tests, 0 failures |
| Live drive | yes | ✅ Phoenix on :4000, `/` and the deep link `/catalogue` both serve the shell; Elm boots, routes, and renders seeded books; console clean |
| Deploy | yes | ⏳ deferred to the batch's integration deploy — but `deploy/Dockerfile.core` provably never receives `frontend/` (its COPY list is explicit and the Elm build runs on the host) |
| Repo hygiene | yes | ✅ `git ls-files` survey done; one sibling class found (see Progress Notes) |

## Definition of Done
- [x] Confirmed unserved, with the evidence that proves it — evidence: the greps/config checked
- [x] Deleted and gitignored (or the consuming path named and fixed) — evidence: diff
- [x] Sibling tracked-build-output survey reported — evidence: `git ls-files` output
- [ ] Preview deploy serves the SPA — evidence: deploy log + a loaded page (local deploy done and green; Fly preview deferred to the batch integration deploy)
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#343**. Independent; needs an owner wave assignment. Fits naturally beside the Wave 2 deletion work in spirit.

## Agent Assignment
elm-agent / devops.

## Progress Notes
Filed 2026-07-31 by the lead from #343's finding 4. Independently confirmed: `git ls-files --error-unmatch frontend/index.html` succeeds (tracked), `wc -l` → 39,680, and `grep -c lookupByIsbn` → 2 after the symbol was deleted from all source.

### 2026-07-31 — implemented (elm-agent/devops)

**What the file actually was.** `elm make src/Main.elm --output=index.html` output: a self-contained
dev page (`<pre id="elm">`, `Elm.Main.init`, an "Initialization Error" handler) with the whole
compiled program inlined. It has no `<link>` to a stylesheet and no port wiring, so it could not have
rendered the real app even when fresh. At 1.17 MB it was the largest tracked *text* file in the repo —
bigger than `technical-architecture.md` (268 KB) and `main.css` (148 KB), beaten only by the
`images/*.PNG` vision fixtures.

**Unserved — re-derived independently, not taken on trust.** The served chain is
`apps/core/assets/index.html` (442 B shell) → copied to `apps/core/priv/static/index.html` by
`apps/core/assets/build.js` → sent by `CoreWeb.PageController.index/2` via `send_file`. `Plug.Static`
(`endpoint.ex:17-21`) has `only: ~w(assets textures favicon.ico robots.txt uploads)` — `index.html` is
not in it, so PageController is the *only* way any index is served. Checked and found no reference to
`frontend/index.html` in: the Phoenix static pipeline, `build.js`/esbuild config, `apps/core/config/dev.exs`'s
watcher, every script under `scripts/` (incl. `deploy-stack.sh`, `test-e2e.sh`, `ci.sh`), all three
Dockerfiles, `.dockerignore`, `e2e/playwright.config.ts`, and both deploy workflows. `deploy/Dockerfile.core`
never copies `frontend/` at all — the Elm build runs on the host (lines 30-33 explain why), so the
Docker context provably cannot contain it.

**The one consumer, and what it says.** `frontend/package.json`'s `start` script was
`elm make src/Main.elm --output=elm.js && open index.html` — it built `elm.js` and then opened a file
that ignores `elm.js` entirely. So it did not consume this as a build input; it opened whatever stale
copy happened to be committed. Already broken before this change; removed. (`build` and `test` kept —
`build` is the typecheck `docs/agents/elm-agent.md:102` documents.)

**Proof the build never depended on it.** Recorded sha256 of the three build outputs, deleted the file,
wiped `elm-stuff/` + `priv/static/{assets,index.html,textures}`, rebuilt with `node build.js --production`:
byte-identical.

| file | before | after |
|------|--------|-------|
| `priv/static/index.html` | `e7331ab4…` | `e7331ab4…` |
| `priv/static/assets/app.js` | `1b3188bd…` | `1b3188bd…` |
| `priv/static/assets/app.css` | `26426feb…` | `26426feb…` |

**Proof it still serves.** `mix phx.server` (dev): `GET /` → 200 `text/html` 442 B with the real shell;
`GET /catalogue` (client-side route, exercises the catch-all) → 200 442 B; `/assets/app.js` → 200,
`/assets/app.css` → 200. Driven in Chrome: the SPA boots, routes to Catalogue, and renders seeded books
from the API. Console clean apart from Elm's expected dev-mode notice. `page_controller_test.exs` +
`robots_txt_test.exs`: 8 tests, 0 failures.

**Grep is clean.** `lookupByIsbn` now has **0 matches** across `frontend/src`, `frontend/tests`, `e2e/`,
and `apps/`. Every remaining hit is prose in `docs/`, `issues/`, `plans/` describing the symbol's history —
which is what a grep over this repo should now report.

**Sibling survey (`git ls-files`, not the filesystem, not `.gitignore`).**
- Under `frontend/`: `frontend/index.html` was the only tracked build output. The rest is source
  (`css/main.css`, `elm.json`, `package*.json`, `src/`, `tests/`, `elm-review/`) plus 16 git-lfs
  texture PNGs, which are source-of-record assets, not regenerable output. `frontend/elm.js` and
  `frontend/public/elm.js` are correctly ignored and untracked.
- Under `apps/core/priv/static/`: 17 tracked files. `robots.txt` is source. **The other 16 are
  `uploads/*.jpg` — runtime output from `Stacks.Storage.Local` (`local.ex:78`, default
  `priv/static/uploads`), committed in `12c9b8dd`/`4f3a533a`.** `.gitignore:93` already declares
  `apps/core/priv/static/uploads/` ignored, but the rule was added afterwards and **gitignore does not
  untrack** — exactly the failure mode the Reviewer Context warns about. Nothing references them: no
  code, test, fixture or seed mentions any of the 16 UUIDs, and `seeds.exs:1138` points at a different
  path (`uploads/seeds/book-cover-001.jpg`). Left in place per scope-lock and **raised as a follow-up** —
  they are user-uploaded photographs living in git, which is GDPR-adjacent as well as untidy.
  Remediation is `git rm --cached "apps/core/priv/static/uploads/"*.jpg` (index-only; history would
  need a separate rewrite).
- `proto/gen/` and `apps/core/lib/stacks/gen/` are correctly untracked (0 tracked files each).

**Two unrelated observations, not acted on.**
1. `docs/user_stories/US-1.1.5-manual-isbn-entry.md` still documents the `lookupByIsbn` flow in the
   present tense ("the current Elm `Api.lookupByIsbn` function calls the GET endpoint") — doc drift
   left by #343, now the loudest remaining hit for the symbol.
2. `scripts/test-e2e.sh`'s header still claims it "Serves the pre-built Elm frontend on :4001" and that
   `BASE_URL` defaults to `:4001`. It does neither — it starts Phoenix on :4000 only, and
   `playwright.config.ts` defaults to `:4000`. Stale comment; harmless but misleading during recon.

**Environment note:** `frontend/public/textures/*.png` are git-lfs pointers in a fresh worktree
(131-132 B each), so background textures are absent in a local worktree drive. Not a regression and not
caused by this change — `just bootstrap-worktree` does not run `git lfs pull`.
