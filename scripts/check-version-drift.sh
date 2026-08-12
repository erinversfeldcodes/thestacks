#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.versions" ]]; then
    echo "version-drift: .versions not found at $REPO_ROOT — cannot check." >&2
    exit 1
fi
# shellcheck source=../.versions
source "$REPO_ROOT/.versions"

if ! command -v elixir >/dev/null 2>&1; then
    echo "version-drift: elixir not on PATH — skipping toolchain check."
    exit 0
fi

actual_otp="$(elixir --eval 'IO.write(System.otp_release())' 2>/dev/null)"
actual_elixir_full="$(elixir --eval 'IO.write(System.version())' 2>/dev/null)"
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
