#!/usr/bin/env bash
# scripts/install-flyctl.sh — install the latest flyctl binary from GitHub releases.
#
# The superfly/homebrew-tap has not been updated in ~2 years. This script fetches
# the latest release from GitHub and installs it to ~/.local/bin/flyctl.
#
# Usage:
#   scripts/install-flyctl.sh          # install latest
#   scripts/install-flyctl.sh --check  # print current vs latest versions, no install
#
# Installed to: ~/.local/bin/flyctl (ensure this is on your PATH)

set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
BINARY="${INSTALL_DIR}/flyctl"

_latest_version() {
    curl -fsSL "https://api.github.com/repos/superfly/flyctl/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))"
}

_current_version() {
    if command -v flyctl &>/dev/null; then
        flyctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    elif [[ -x "${BINARY}" ]]; then
        "${BINARY}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    else
        echo "not installed"
    fi
}

_download_url() {
    local version="$1"
    local os arch
    os="$(uname -s)"  # Darwin or Linux
    arch="$(uname -m)"  # arm64 or x86_64

    case "${os}" in
        Darwin) os="macOS" ;;
        Linux)  os="Linux" ;;
        *) echo "Unsupported OS: ${os}" >&2; exit 1 ;;
    esac

    echo "https://github.com/superfly/flyctl/releases/download/v${version}/flyctl_${version}_${os}_${arch}.tar.gz"
}

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

latest="$(_latest_version)"
current="$(_current_version)"

echo "flyctl current: ${current}"
echo "flyctl latest:  ${latest}"

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    [[ "${current}" == "${latest}" ]] && echo "Up to date." || echo "Update available."
    exit 0
fi

if [[ "${current}" == "${latest}" ]]; then
    echo "Already up to date — nothing to do."
    exit 0
fi

echo "Installing flyctl v${latest}..."

url="$(_download_url "${latest}")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

curl -fsSL "${url}" -o "${tmpdir}/flyctl.tar.gz"
tar -xzf "${tmpdir}/flyctl.tar.gz" -C "${tmpdir}" flyctl

mkdir -p "${INSTALL_DIR}"
mv "${tmpdir}/flyctl" "${BINARY}"
chmod +x "${BINARY}"
# Also expose as `fly` — both names are used by Fly.io tooling
ln -sf "${BINARY}" "${INSTALL_DIR}/fly"

echo "Installed flyctl v${latest} to ${BINARY} (also linked as fly)"
echo ""
echo "Ensure ~/.local/bin is on your PATH:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"  # add to ~/.zshrc or ~/.bashrc"
