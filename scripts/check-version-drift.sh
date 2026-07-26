#!/usr/bin/env bash
# scripts/check-version-drift.sh — fail if the running Elixir toolchain's
# OTP/Elixir versions disagree with the canonical pins in `.versions`.
#
# Why this exists (Issue #300): `.versions` is the single source of truth that
# CI's `versions` job feeds to erlef/setup-beam, so CI ran OTP 28. But the Nix
# dev shell's `elixir` is only bound to OTP 28 if the flake wires it explicitly
# (`beam.packages.erlang_28.elixir_1_18`); a bare `pkgs.elixir_1_18` silently
# runs on nixpkgs' DEFAULT beam (OTP 27) regardless of any `erlang_28` also on
# PATH. That divergence made local `mix dialyzer` (OTP 27) disagree with CI
# (OTP 28) with no signal. This guard is that signal: it runs INSIDE the dev
# shell (where `elixir` is the flake toolchain), so it catches the case a
# nix-less CI runner never can — the flake drifting away from `.versions`.
#
# We query the OTP release via `elixir`/`System.otp_release`, not bare `erl`,
# because #300 was specifically the *Elixir wrapper* binding to the wrong
# erlang; the standalone `erl` on PATH can be correct while the elixir toolchain
# is not.
#
# Wired into `scripts/ci.sh` (the integration gate) and the `verify` recipe.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.versions" ]]; then
    echo "version-drift: .versions not found at $REPO_ROOT — cannot check." >&2
    exit 1
fi
# shellcheck source=../.versions
source "$REPO_ROOT/.versions"

if ! command -v elixir >/dev/null 2>&1; then
    # No Elixir on PATH (e.g. a non-Elixir context). Nothing to compare — the
    # surrounding gate needs Elixir anyway and will fail elsewhere if it's
    # genuinely required. Don't false-fail here.
    echo "version-drift: elixir not on PATH — skipping toolchain check."
    exit 0
fi

# Actual toolchain, as the Elixir wrapper sees it.
actual_otp="$(elixir --eval 'IO.write(System.otp_release())' 2>/dev/null)"
actual_elixir_full="$(elixir --eval 'IO.write(System.version())' 2>/dev/null)"
# `.versions` pins Elixir to major.minor (e.g. 1.18); compare like-for-like.
actual_elixir_mm="${actual_elixir_full%.*}"

ok=1
if [[ "$actual_otp" != "$OTP_VERSION" ]]; then
    echo "version-drift: OTP mismatch — .versions pins OTP_VERSION=${OTP_VERSION}, but the Elixir toolchain runs on OTP ${actual_otp}." >&2
    ok=0
fi
if [[ "$actual_elixir_mm" != "$ELIXIR_VERSION" ]]; then
    echo "version-drift: Elixir mismatch — .versions pins ELIXIR_VERSION=${ELIXIR_VERSION}, but the toolchain is Elixir ${actual_elixir_full} (${actual_elixir_mm})." >&2
    ok=0
fi

if [[ "$ok" -ne 1 ]]; then
    echo "version-drift: FAIL — flake.nix and .versions have drifted. If you bumped .versions, update the flake's" >&2
    echo "               beam.packages.erlang_<OTP>.elixir_<VER> attributes (and Dockerfile base image) to match." >&2
    exit 1
fi

echo "version-drift: OK — Elixir ${actual_elixir_full} / OTP ${actual_otp} matches .versions (Elixir ${ELIXIR_VERSION} / OTP ${OTP_VERSION})."
