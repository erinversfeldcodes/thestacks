# Issue #300: local dialyzer ran OTP 27 while CI/prod ran OTP 28 — dialyzer results diverged

## Summary
CI's `lint-elixir` job builds its dialyzer PLT on Erlang/OTP 28 (`dialyxir_erlang-28.5.0.3_elixir-1.18.4_deps-test.plt`), which matches the prod Docker image (`hexpm/elixir:1.18.4-erlang-28.x`) and the `.versions` pin (`OTP_VERSION=28`). The outlier was **local**: `flake.nix` listed `erlang_28`, but its `pkgs.elixir_1_18` was built against nixpkgs' DEFAULT beam (OTP 27), and the Elixir wrapper runs on ITS bundled erlang regardless of any `erlang_28` also on PATH — so `mix`/`mix dialyzer` silently ran OTP 27 (erts 15.2.7.7) and built an OTP-27 PLT. Dialyzer emits different warnings per OTP (opaque-type internals changed for `MapSet`/`:sets` in 28), so locally-green dialyzer did not predict CI — PR #393 failed CI on a `contract_with_opaque` error in untouched code that OTP 27 never reports, and CI showed 6 "unnecessary" ignore-file skips that OTP 27 didn't. Fix (Option B, owner-approved): wire the flake's Elixir onto OTP 28 (`beam.packages.erlang_28.elixir_1_18`) so local == CI == prod, all OTP 28.

## User Stories
None — CI/toolchain parity (infra). Surfaced on PR #393 (2026-07-26); the immediate error was fixed code-side (`b76fa3f3`, mirroring `22dcd53f`), but the divergence remains.

## Goal
Local and CI dialyzer agree: both run OTP 28, so `just ci` green predicts the `lint-elixir` job — and the dialyzer gate keeps matching the shipped runtime (prod is OTP 28), so it still catches OTP-28-only issues like the one PR #393 hit. Achieved by binding the flake's Elixir to OTP 28 (`beam.packages.erlang_28.elixir_1_18`) rather than downgrading CI to 27. `.versions` remains the single source of truth (already consumed by the workflow's `versions` job and `scripts/ci.sh`); a new drift guard fails the local gate if the flake's running Elixir/OTP ever diverges from `.versions` again. `.dialyzer_ignore.exs` was re-baselined on OTP 28: the 6 filters CI reported as unnecessary are dead on 28 and were removed, leaving one live filter.

## Scope Check
- More than 3 controllers? No (workflow/flake config only).
- More than 2 new endpoints? No.
- More than ~300 LOC? No.
- Unrelated concerns? No (toolchain parity only).

## Wiring
Infra-only: `.github/workflows/*` Erlang/Elixir setup + possibly `flake.nix` / a shared versions file.

## Feature-Completeness Pre-Check
n/a — no user stories (CI/toolchain work). Validation path: after the change, a deliberately-introduced OTP-28-only dialyzer trigger (e.g. an opaque `MapSet.t()` return spec on a two-clause function) must produce the SAME verdict locally and in CI; remove the trigger after proving parity.

## Technical Requirements
- Identify where the Actions workflow selects Erlang/OTP (`erlef/setup-beam` version inputs or the runner image) and align it with `flake.nix`'s pin, or vice versa.
- One source of truth for the version pair, consumed by both flake and workflow, so future bumps can't drift.
- Re-baseline `.dialyzer_ignore.exs` against the agreed OTP and prune/keep entries accordingly (document which OTP each entry needs).
- CI PLT cache key must include the OTP/Elixir versions (verify it already does).

## Definition of Done
- [ ] Local `mix dialyzer` and CI `lint-elixir` run the same OTP+Elixir pair (evidence: PLT filenames match). Local (flake) now builds `dialyxir_erlang-28.4.2_elixir-1.18.4_deps-test.plt`; CI (setup-beam) builds `dialyxir_erlang-28.5.0.3_elixir-1.18.4_deps-test.plt` — same OTP-28 major + Elixir 1.18.4, erlang patch floats (nixpkgs-locked vs setup-beam-latest). Left for the orchestrator to confirm against the post-push CI log.
- [x] Version pair has a single source of truth shared by flake + workflow (evidence: `.versions` is the source; consumed by ci.yml's `versions` job → `setup-beam` and by `scripts/ci.sh`; `flake.nix` now bound to OTP 28 to match; `scripts/check-version-drift.sh` enforces flake↔`.versions` agreement inside the dev shell and is wired into `verify`/`ci.sh`)
- [x] `.dialyzer_ignore.exs` re-baselined with per-entry OTP rationale (evidence: OTP-28 `mix dialyzer` local run showed `Skipped: 7, Unnecessary Skips: 6`; the 6 dead filters removed with rationale, 1 live `ExUnit` filter kept; re-run shows `Unnecessary Skips: 0` / "passed successfully"). CI-side "0 unnecessary skips" confirmation left for the orchestrator's post-push CI log.
- [ ] Parity evidence: post-change CI log shows a PLT filename with the same erlang/elixir pair as local plus an identical clean dialyzer profile (0 errors / 0 unnecessary). _(amended 2026-07-26: the temporary OTP-sensitive trigger-push cycle is replaced by PLT-identity + identical-profile evidence — orchestrator.)_ Left for the orchestrator to confirm against the post-push CI log.

## Dependencies
None. Context: PR #393 CI failure (run 30191475089); fix commit `b76fa3f3`; sibling pattern `22dcd53f`.

## Agent Assignment
platform-agent

## Priority
P2 (local gates can't predict CI dialyzer until fixed)

## Progress Notes
- 2026-07-26: Filed by the orchestrator after the PR #393 `lint-elixir` failure; immediate code fix landed separately.
- 2026-07-26 (platform-agent): Investigation corrected the premise — the flake was NOT deliberately on OTP 27; it declared `erlang_28` but `pkgs.elixir_1_18` ran on nixpkgs' default OTP-27 beam, so LOCAL mix/dialyzer was the outlier (OTP 27) while CI/prod/`.versions` were all OTP 28. Owner chose Option B (align UP to 28). Implemented: (1) `flake.nix` Elixir bound to `beam.packages.erlang_28.elixir_1_18` (OTP 28 confirmed: `mix` reports `System.otp_release()=28`, erts 16.3.1); (2) rebuilt `_build` from scratch under OTP 28, PLT now `dialyxir_erlang-28.4.2_elixir-1.18.4_deps-test.plt`; (3) `.dialyzer_ignore.exs` re-baselined on 28 (6 dead filters removed, 1 kept) → dialyzer green, 0 unnecessary; (4) `mix.exs` gains `list_unused_filters: true` to enforce 0-unnecessary going forward; (5) CI `mix`/`dialyzer` cache keys now include the OTP+Elixir pair so an OTP bump invalidates stale `_build`/PLT; (6) new `scripts/check-version-drift.sh` drift guard wired into `verify` + `ci.sh`; (7) CLAUDE.md toolchain line corrected to OTP 28. Local verification green (dialyzer, format, canary `blog_test` 35/0, actionlint, drift-guard both directions). Two DoD boxes needing the post-push CI log left unticked. No commits/pushes.
- 2026-07-26 (platform-agent, FLAG): Discovered a latent, out-of-scope caching bug — CI's dedicated `dialyzer` cache uses `path: priv/plts`, but this umbrella writes PLTs to `_build/<env>/`, so that cache stores nothing; the PLT is actually cached (now correctly OTP-keyed) via the `mix` cache of `_build`. Recommend a follow-up to fix or drop the redundant `priv/plts` cache. Also: local erlang patch (28.4.2, nixpkgs-locked) vs CI (28.5.0.3, setup-beam) floats; dialyzer verdicts are stable across 28.x patches, but exact-patch lockstep isn't enforced.
