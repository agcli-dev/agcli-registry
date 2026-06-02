#!/usr/bin/env bash
#
# install-ossutil.sh — Install Alibaba ossutil into INSTALL_DIR for CI sync jobs.
#
# Checks:
#   - Supported OS/arch (linux|mac × amd64|arm64)
#   - Downloaded binary matches a pinned SHA-256 for the requested version
#
# Flow:
#   1. Select platform tarball URL for OSSUTIL_VERSION (default 2.2.2)
#   2. curl download, verify checksum, extract ossutil to INSTALL_DIR (default /usr/local/bin)
#
# Usage:
#   ./scripts/install-ossutil.sh [version] [install_dir]
#
set -euo pipefail

OSSUTIL_VERSION="${1:-2.2.2}"
INSTALL_DIR="${2:-/usr/local/bin}"

declare -A KNOWN_HASHES
KNOWN_HASHES["linux/amd64:2.2.2"]="d4308515689144c6b213d4998787abbd232dd6714fc43dedbe87064c2c34dee1"
KNOWN_HASHES["linux/arm64:2.2.2"]="dcadb6aa97ddbae523e427e9397a529a04c2f21b4204065ce30e21d44908faa0"
KNOWN_HASHES["mac/amd64:2.2.2"]="5a0e34e6c439eb0b0ba7b9a67958d5d3b031389437a952a0704520b5acb433d0"
KNOWN_HASHES["mac/arm64:2.2.2"]="d3fafc4c961f7c58083f6b65a698a169992ba87177001f066ec8c2837a30e23e"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${OS}" in
  linux) PLATFORM="linux" ;;
  darwin) PLATFORM="mac" ;;
  *)
    echo "Error: unsupported OS: ${OS}" >&2
    exit 1
    ;;
esac

case "${ARCH}" in
  x86_64|amd64) ARCH_TAG="amd64" ;;
  aarch64|arm64) ARCH_TAG="arm64" ;;
  *)
    echo "Error: unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

SUFFIX="${PLATFORM}-${ARCH_TAG}"
HASH_KEY="${PLATFORM}/${ARCH_TAG}:${OSSUTIL_VERSION}"
DOWNLOAD_URL="https://gosspublic.alicdn.com/ossutil/v2/${OSSUTIL_VERSION}/ossutil-${OSSUTIL_VERSION}-${SUFFIX}.zip"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "Installing ossutil v${OSSUTIL_VERSION} (${SUFFIX})..."

curl -fsSL "${DOWNLOAD_URL}" -o "${TMPDIR}/ossutil.zip"

if [[ -n "${KNOWN_HASHES[${HASH_KEY}]:-}" ]]; then
  actual=$(sha256sum "${TMPDIR}/ossutil.zip" | awk '{print $1}')
  expected="${KNOWN_HASHES[${HASH_KEY}]}"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Error: sha256 mismatch for ossutil zip" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
  echo "  sha256 verified"
else
  echo "  warning: no known hash for ${HASH_KEY}, skipping verification" >&2
fi

unzip -q "${TMPDIR}/ossutil.zip" -d "${TMPDIR}"
chmod +x "${TMPDIR}/ossutil-${OSSUTIL_VERSION}-${SUFFIX}/ossutil"

if [[ -w "${INSTALL_DIR}" ]]; then
  mv "${TMPDIR}/ossutil-${OSSUTIL_VERSION}-${SUFFIX}/ossutil" "${INSTALL_DIR}/ossutil"
else
  sudo mv "${TMPDIR}/ossutil-${OSSUTIL_VERSION}-${SUFFIX}/ossutil" "${INSTALL_DIR}/ossutil"
fi

ossutil version
