#!/usr/bin/env bash
set -euo pipefail

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

build_descriptor() {
    local dest="$1"
    buf build "$REPO_ROOT/proto" -o "$dest"
}

generate_to() {
    local dest="$1"
    local desc_file="$2"
    python3 "$GENERATOR" --output-dir "$dest" < "$desc_file"
    if command -v elm-format &>/dev/null; then
        elm-format --yes "$dest" 2>/dev/null || true
    elif npx --no-install elm-format --help &>/dev/null 2>&1; then
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

    if [[ -d "$OUTPUT_DIR" ]] && diff -r --brief "$GEN_DIR" "$OUTPUT_DIR" >/dev/null 2>&1; then
        echo "==> Elm proto gen is up to date."
        exit 0
    fi

    CLASS="$(bash "$REPO_ROOT/scripts/generated-file-class.sh" "$OUTPUT_DIR")"
    if [[ "$CLASS" == "ignored" ]]; then
        mkdir -p "$OUTPUT_DIR"
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

if [[ -d "$OUTPUT_DIR" ]] && [[ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
    OLDEST_GEN="$(find "$OUTPUT_DIR" -type f -name '*.elm' | head -1)"
    if [[ -n "$OLDEST_GEN" ]]; then
        STALE=false
        while IFS= read -r -d '' proto_file; do
            if [[ "$proto_file" -nt "$OLDEST_GEN" ]]; then
                STALE=true
                break
            fi
        done < <(find "$REPO_ROOT/proto" -name '*.proto' -print0 2>/dev/null)
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
