# Issue #300: CI runs OTP 28 while the flake pins OTP 27 — dialyzer results diverge

## Summary
GitHub Actions' `lint-elixir` job builds its dialyzer PLT on Erlang/OTP 28.5 (`dialyxir_erlang-28.5.0.3_elixir-1.18.4_deps-test.plt`) while `flake.nix` pins the local toolchain to Elixir 1.18.4 / OTP 27. Dialyzer emits different warnings per OTP (opaque-type internals changed for `MapSet`/`:sets` in 28), so a locally-green `just ci` does not predict the CI dialyzer result — PR #393 failed CI on a `contract_with_opaque` error in untouched code that OTP 27 never reports, and CI showed 6 "unnecessary" ignore-file skips that are presumably load-bearing on 27.

## User Stories
None — CI/toolchain parity (infra). Surfaced on PR #393 (2026-07-26); the immediate error was fixed code-side (`b76fa3f3`, mirroring `22dcd53f`), but the divergence remains.

## Goal
Local and CI dialyzer agree: both run the same OTP (preferably the flake-pinned version), so `just ci` green predicts the `lint-elixir` job. Either pin the Actions Erlang/OTP setup to the flake's versions (single source of truth — e.g. read versions from one file consumed by both `flake.nix` and the workflow), or deliberately move the flake to OTP 28 (larger change: rebuild PLTs, re-audit the `.dialyzer_ignore.exs` entries whose necessity differs across OTPs — CI reported 6 unnecessary skips on 28 while a local OTP 27 run reports 0 skipped/0 unnecessary, i.e. the warning sets genuinely differ).

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
- [ ] Local `just run mix dialyzer` and CI `lint-elixir` run the same OTP+Elixir pair (evidence: PLT filenames match)
- [ ] Version pair has a single source of truth shared by flake + workflow (evidence: file + both consumers cited)
- [ ] `.dialyzer_ignore.exs` re-baselined with per-entry OTP rationale; CI reports 0 unnecessary skips (evidence: CI run)
- [ ] Parity proven via a temporary OTP-sensitive trigger showing identical verdicts local vs CI (evidence: both outputs)

## Dependencies
None. Context: PR #393 CI failure (run 30191475089); fix commit `b76fa3f3`; sibling pattern `22dcd53f`.

## Agent Assignment
platform-agent

## Priority
P2 (local gates can't predict CI dialyzer until fixed)

## Progress Notes
- 2026-07-26: Filed by the orchestrator after the PR #393 `lint-elixir` failure; immediate code fix landed separately.
