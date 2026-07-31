#!/usr/bin/env bash
set -euo pipefail

# gen-elm-proto.sh — Generate Elm decoders/encoders from Protobuf schemas.
#
# Reads .proto files via `buf build`, pipes the JSON descriptor to
# gen-elm-proto.py which produces one .elm module per .proto file.
# Runs elm-format on the output so generated code is always format-clean.
#
# Usage:
#   scripts/gen-elm-proto.sh           # generate into proto/gen/elm/
#   scripts/gen-elm-proto.sh --check   # verify generated code is up to date

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_ROOT/scripts/gen-elm-proto.py"
OUTPUT_DIR="$REPO_ROOT/proto/gen/elm"

if ! command -v buf &>/dev/null; then
    echo "ERROR: 'buf' is not installed." >&2
    echo "  macOS: brew install bufbuild/buf/buf" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: 'python3' is not installed." >&2
    exit 1
fi

# Build JSON descriptor to a temp file (buf infers format from .json extension)
build_descriptor() {
    local dest="$1"
    buf build "$REPO_ROOT/proto" -o "$dest"
}

# Generate Elm files into a directory and run elm-format on them
generate_to() {
    local dest="$1"
    local desc_file="$2"
    python3 "$GENERATOR" --output-dir "$dest" < "$desc_file"
    # Run elm-format so generated code is always format-clean
    if command -v elm-format &>/dev/null; then
        elm-format --yes "$dest" 2>/dev/null || true
    elif npx --no-install elm-format --help &>/dev/null 2>&1; then
        # --no-install: use only the locally-installed (lockfile-pinned)
        # elm-format; never fetch an unpinned copy from the registry.
        npx --no-install elm-format --yes "$dest" 2>/dev/null || true
    else
        echo "WARNING: elm-format not found; generated code may not be format-clean." >&2
    fi
}

if [[ "${1:-}" == "--check" ]]; then
    echo "==> Checking Elm proto gen is up to date..."
    TMPDIR_CHECK="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_CHECK"' EXIT

    DESC_FILE="$TMPDIR_CHECK/descriptor.json"
    GEN_DIR="$TMPDIR_CHECK/gen"

    build_descriptor "$DESC_FILE"
    generate_to "$GEN_DIR" "$DESC_FILE"

    # Diff against current output
    if [[ -d "$OUTPUT_DIR" ]] && diff -r --brief "$GEN_DIR" "$OUTPUT_DIR" >/dev/null 2>&1; then
        echo "==> Elm proto gen is up to date."
        exit 0
    fi

    # Drifted (or absent). Whether that is a defect depends entirely on whether
    # the output is tracked — see scripts/generated-file-class.sh (Issue #354).
    CLASS="$(bash "$REPO_ROOT/scripts/generated-file-class.sh" "$OUTPUT_DIR")"
    if [[ "$CLASS" == "ignored" ]]; then
        mkdir -p "$OUTPUT_DIR"
        # --delete so a module dropped from proto/ disappears here too; a
        # self-heal that leaves stale files behind would never converge.
        rsync -a --delete "$GEN_DIR/" "$OUTPUT_DIR/"
        echo "REGENERATED: proto/gen/elm/ was out of date — gitignored, so this" >&2
        echo "             can only be local staleness; regenerated and continuing." >&2
        exit 0
    fi

    echo "ERROR: Elm proto gen is out of date ($CLASS). Diff:" >&2
    diff -r -u "$OUTPUT_DIR" "$GEN_DIR" 2>&1 || true
    echo "" >&2
    echo "Run: scripts/gen-elm-proto.sh" >&2
    exit 1
fi

# ── Staleness check: skip regeneration if output is newer than all inputs ─────
if [[ -d "$OUTPUT_DIR" ]] && [[ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
    # Find the oldest generated file
    OLDEST_GEN="$(find "$OUTPUT_DIR" -type f -name '*.elm' | head -1)"
    if [[ -n "$OLDEST_GEN" ]]; then
        STALE=false
        # Check if any .proto file is newer than the oldest generated file
        while IFS= read -r -d '' proto_file; do
            if [[ "$proto_file" -nt "$OLDEST_GEN" ]]; then
                STALE=true
                break
            fi
        done < <(find "$REPO_ROOT/proto" -name '*.proto' -print0 2>/dev/null)
        # Check if the generator script itself is newer
        if [[ "$GENERATOR" -nt "$OLDEST_GEN" ]]; then
            STALE=true
        fi
        if [[ "$STALE" == "false" ]]; then
            echo "==> Elm proto gen is up to date (skipping regeneration)."
            exit 0
        fi
    fi
fi

echo "==> Generating Elm code from proto schemas..."
TMPFILE="$(mktemp /tmp/buf-desc-XXXXXX.json)"
trap 'rm -f "$TMPFILE"' EXIT
build_descriptor "$TMPFILE"
generate_to "$OUTPUT_DIR" "$TMPFILE"
echo "==> Done."
