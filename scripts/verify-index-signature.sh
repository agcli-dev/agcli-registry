#!/usr/bin/env bash
#
# verify-index-signature.sh — Verify index.json against index.json.asc using the registry public key.
#
# Usage:
#   ./scripts/verify-index-signature.sh [index.json] [index.json.asc]
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_FILE="${1:-${ROOT_DIR}/index.json}"
SIG_FILE="${2:-${ROOT_DIR}/index.json.asc}"
PUBKEY_FILE="${ROOT_DIR}/keys/registry-signing.pub"

for f in "${INDEX_FILE}" "${SIG_FILE}" "${PUBKEY_FILE}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Error: file not found: ${f}" >&2
    exit 1
  fi
done

gpg --import "${PUBKEY_FILE}" 2>/dev/null || true
gpg --verify "${SIG_FILE}" "${INDEX_FILE}"
