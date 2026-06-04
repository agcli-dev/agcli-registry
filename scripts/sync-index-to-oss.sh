#!/usr/bin/env bash
#
# sync-index-to-oss.sh — Upload index.json, index.json.asc, and index.meta.json to Alibaba Cloud OSS.
#
# Checks:
#   - Required OSS credentials and ossutil available
#   - index.json and index.meta.json exist in repo root (validated upstream by registry.sh merge)
#
# Flow:
#   1. Resolve object keys: index.json and index.meta.json at bucket root, or under OSS_PREFIX/
#   2. ossutil cp both files with --cache-control no-cache (private objects; CDN uses OSS private origin)
#
# Environment:
#   OSS_ACCESS_KEY_ID, OSS_ACCESS_KEY_SECRET, OSS_ENDPOINT, OSS_BUCKET — required
#   OSS_PREFIX       — optional key prefix (e.g. "market" → oss://<bucket>/market/index.json)
#   DRY_RUN          — "true" to skip upload (default: false)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_FILE="${ROOT_DIR}/index.json"
SIG_FILE="${ROOT_DIR}/index.json.asc"
META_FILE="${ROOT_DIR}/index.meta.json"
DRY_RUN="${DRY_RUN:-false}"

missing=()
for var in OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_ENDPOINT OSS_BUCKET; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required environment variables: ${missing[*]}" >&2
  echo "" >&2
  echo "See docs/setupdocs/oss-and-cdn-setup.md for configuration instructions." >&2
  exit 1
fi

OSS_PREFIX="${OSS_PREFIX:-}"

if ! command -v ossutil &>/dev/null; then
  echo "Error: ossutil not found in PATH." >&2
  echo "Run ./scripts/install-ossutil.sh to install." >&2
  exit 1
fi

echo "Using ossutil ($(ossutil version 2>&1 | head -1))"

if [[ ! -f "${INDEX_FILE}" ]]; then
  echo "Error: index.json not found: ${INDEX_FILE}" >&2
  exit 1
fi

if [[ ! -f "${SIG_FILE}" ]]; then
  echo "Error: index.json.asc not found: ${SIG_FILE}" >&2
  exit 1
fi

if [[ ! -f "${META_FILE}" ]]; then
  echo "Error: index.meta.json not found: ${META_FILE}" >&2
  exit 1
fi

# Validation is done during the merge step (registry.sh merge)

if [[ -n "${OSS_PREFIX}" ]]; then
  OSS_PREFIX="${OSS_PREFIX%/}"
  INDEX_OSS_URI="oss://${OSS_BUCKET}/${OSS_PREFIX}/index.json"
  SIG_OSS_URI="oss://${OSS_BUCKET}/${OSS_PREFIX}/index.json.asc"
  META_OSS_URI="oss://${OSS_BUCKET}/${OSS_PREFIX}/index.meta.json"
else
  INDEX_OSS_URI="oss://${OSS_BUCKET}/index.json"
  SIG_OSS_URI="oss://${OSS_BUCKET}/index.json.asc"
  META_OSS_URI="oss://${OSS_BUCKET}/index.meta.json"
fi

upload_file() {
  local src="$1" dst="$2"
  echo "  ${src} -> ${dst}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] skipped"
    return 0
  fi

  ossutil cp "${src}" "${dst}" \
    --force \
    --cache-control "no-cache"

  echo "  OK"
}

echo ""
echo "Syncing index files to OSS..."
echo "  Bucket: ${OSS_BUCKET}"
echo "  Endpoint: ${OSS_ENDPOINT}"
echo "  DRY_RUN: ${DRY_RUN}"
echo ""

upload_file "${INDEX_FILE}" "${INDEX_OSS_URI}"
upload_file "${SIG_FILE}" "${SIG_OSS_URI}"
upload_file "${META_FILE}" "${META_OSS_URI}"

echo ""
echo "Sync complete."
