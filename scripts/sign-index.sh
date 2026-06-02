#!/usr/bin/env bash
#
# sign-index.sh — Detached OpenPGP signature for index.json (CI publish only).
#
# Requires environment (GitHub Actions secrets):
#   REGISTRY_GPG_PRIVATE_KEY  armored secret key
#   REGISTRY_GPG_PASSPHRASE   passphrase for the signing key
#   REGISTRY_GPG_KEY_ID       optional; defaults to fingerprint from keys/registry-signing.pub
#
# Outputs:
#   index.json.asc            detached armored signature
#   index.meta.json           updated with a "signing" object (if meta already exists)
#
# Verifies the signature against keys/registry-signing.pub before exit.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_FILE="${ROOT_DIR}/index.json"
SIG_FILE="${ROOT_DIR}/index.json.asc"
META_FILE="${ROOT_DIR}/index.meta.json"
PUBKEY_FILE="${ROOT_DIR}/keys/registry-signing.pub"

if [[ ! -f "${INDEX_FILE}" ]]; then
  echo "Error: index.json not found: ${INDEX_FILE}" >&2
  exit 1
fi

if [[ ! -f "${PUBKEY_FILE}" ]]; then
  echo "Error: signing public key not found: ${PUBKEY_FILE}" >&2
  exit 1
fi

if [[ -z "${REGISTRY_GPG_PRIVATE_KEY:-}" ]]; then
  echo "Error: REGISTRY_GPG_PRIVATE_KEY is not set" >&2
  exit 1
fi

if [[ -z "${REGISTRY_GPG_PASSPHRASE:-}" ]]; then
  echo "Error: REGISTRY_GPG_PASSPHRASE is not set" >&2
  exit 1
fi

if ! command -v gpg &>/dev/null; then
  echo "Error: gpg not found in PATH" >&2
  exit 1
fi

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "${GNUPGHOME}"
trap 'rm -rf "${GNUPGHOME}"' EXIT

gpg --batch --import "${PUBKEY_FILE}" >/dev/null 2>&1
PUB_FPR="$(gpg --batch --with-colons --show-keys "${PUBKEY_FILE}" | awk -F: '$1=="fpr" {print $10; exit}')"
PUB_UID="$(gpg --batch --with-colons --show-keys "${PUBKEY_FILE}" | awk -F: '$1=="uid" {print $10; exit}')"

if [[ -z "${PUB_FPR}" ]]; then
  echo "Error: could not read fingerprint from ${PUBKEY_FILE}" >&2
  exit 1
fi

KEY_ID="${REGISTRY_GPG_KEY_ID:-}"
if [[ -z "${KEY_ID}" ]]; then
  KEY_ID="${PUB_FPR}"
fi

echo "${REGISTRY_GPG_PRIVATE_KEY}" | gpg --batch --import >/dev/null 2>&1

printf '%s\n' "${REGISTRY_GPG_PASSPHRASE}" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
  --default-key "${KEY_ID}" \
  --detach-sign --armor \
  --output "${SIG_FILE}" \
  "${INDEX_FILE}"

if [[ ! -f "${SIG_FILE}" ]]; then
  echo "Error: signature file was not created: ${SIG_FILE}" >&2
  exit 1
fi

gpg --batch --verify "${SIG_FILE}" "${INDEX_FILE}" 2>&1 | tee /tmp/gpg-verify.log
if ! grep -q "Good signature" /tmp/gpg-verify.log; then
  echo "Error: signature verification failed" >&2
  exit 1
fi

echo "Signed index.json -> index.json.asc (key ${KEY_ID})"

if [[ -f "${META_FILE}" ]]; then
  python3 - <<'PY' "${META_FILE}" "${PUB_FPR}" "${PUB_UID}"
import json
import sys

meta_file, fingerprint, uid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(meta_file, encoding="utf-8") as f:
    meta = json.load(f)
meta["signing"] = {
    "type": "openpgp-detached",
    "file": "index.json.asc",
    "key_fingerprint": fingerprint,
    "key_uid": uid,
}
with open(meta_file, "w", encoding="utf-8", newline="\n") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  echo "Updated ${META_FILE} with signing metadata"
fi
