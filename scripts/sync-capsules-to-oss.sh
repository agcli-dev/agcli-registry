#!/usr/bin/env bash
#
# sync-capsules-to-oss.sh — Mirror capsule tarballs from index.json into OSS (content-addressed).
#
# Checks:
#   - Required OSS env vars and ossutil on PATH
#   - index.json has a capsules[] array; each entry has dist.url and integrity.sha256
#   - Downloaded bytes match integrity.sha256 before upload
#
# Flow:
#   1. Load index.json (local or INDEX_URL)
#   2. For each capsule (optional MAX_CAPSULES limit): skip if oss://<bucket>/capsules/by-hash/<aa>/<sha>.tgz exists
#   3. Download from dist.url, verify hash, upload to OSS unless DRY_RUN=true
#
# OSS layout (no OSS_PREFIX):
#   capsules/by-hash/<first-2-hex-of-sha>/<full-sha>.tgz
#
# Environment:
#   OSS_ACCESS_KEY_ID, OSS_ACCESS_KEY_SECRET, OSS_ENDPOINT, OSS_BUCKET — required
#   OSS_REGION       — optional; derived from OSS_ENDPOINT if unset (ossutil 2.x V4 signing)
#   INDEX_URL        — optional HTTPS URL to fetch index.json
#   DRY_RUN          — "true" to print planned uploads only (default: true)
#   MAX_CAPSULES     — max entries to process; 0 = no limit
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ossutil-env.sh
source "${SCRIPT_DIR}/ossutil-env.sh"

ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INDEX_FILE="${ROOT_DIR}/index.json"

DRY_RUN="${DRY_RUN:-true}"
MAX_CAPSULES="${MAX_CAPSULES:-0}"
INDEX_URL="${INDEX_URL:-}"

if ! ossutil_ensure_env; then
  exit 1
fi

if ! command -v ossutil &>/dev/null; then
  echo "Error: ossutil not found in PATH." >&2
  echo "Run ./scripts/install-ossutil.sh to install." >&2
  exit 1
fi

echo "Using ossutil ($(ossutil version 2>&1 | head -1))"
echo "  Region: ${OSS_REGION}"
echo "  Endpoint: ${OSS_ENDPOINT}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [[ -n "${INDEX_URL}" && "${INDEX_URL}" != file://* ]]; then
  if ! [[ "${INDEX_URL}" =~ ^https:// ]]; then
    echo "Error: INDEX_URL must use https: ${INDEX_URL}" >&2
    exit 1
  fi
  curl -fsSL "${INDEX_URL}" -o "${WORK_DIR}/index.json"
  INDEX_FILE="${WORK_DIR}/index.json"
fi

jq -e '.capsules and (.capsules | type == "array")' "${INDEX_FILE}" >/dev/null
echo "Index capsules: $(jq '.capsules | length' "${INDEX_FILE}")"

total=$(jq '.capsules | length' "${INDEX_FILE}")
limit="${MAX_CAPSULES}"
processed=0
uploaded=0
skipped=0
failed=0

if [[ "${total}" -eq 0 ]]; then
  echo "No capsules in index, nothing to sync."
else
  for i in $(seq 0 $((total - 1))); do
    if [[ "${limit}" != "0" ]] && [[ "${processed}" -ge "${limit}" ]]; then
      break
    fi

    url=$(jq -r ".capsules[$i].dist.url // empty" "${INDEX_FILE}")
    sha=$(jq -r ".capsules[$i].integrity.sha256 // empty" "${INDEX_FILE}")
    name=$(jq -r ".capsules[$i].name // \"unknown\"" "${INDEX_FILE}")
    version=$(jq -r ".capsules[$i].version // \"unknown\"" "${INDEX_FILE}")

    if [[ -z "${url}" ]] || [[ -z "${sha}" ]]; then
      echo "Skip ${name}@${version}: missing dist.url or integrity.sha256"
      skipped=$((skipped + 1))
      continue
    fi

    if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "Skip ${name}@${version}: invalid sha256 format"
      skipped=$((skipped + 1))
      continue
    fi

    key="capsules/by-hash/${sha:0:2}/${sha}.tgz"
    oss_uri="oss://${OSS_BUCKET}/${key}"
    tmp_file="${WORK_DIR}/${sha}.tgz"

    processed=$((processed + 1))
    echo "Processing ${name}@${version} -> ${oss_uri}"

    if ossutil stat "${oss_uri}" >/dev/null 2>&1; then
      echo "Already exists, skip upload: ${oss_uri}"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY_RUN=true, planned upload: ${url} -> ${oss_uri}"
      continue
    fi

    if ! curl -fL --connect-timeout 5 --max-time 120 "${url}" -o "${tmp_file}"; then
      echo "Download failed: ${url}" >&2
      failed=$((failed + 1))
      rm -f "${tmp_file}"
      continue
    fi

    actual_sha=$(sha256_file "${tmp_file}")
    if [[ "${actual_sha}" != "${sha}" ]]; then
      echo "Integrity mismatch for ${name}@${version}: expected=${sha}, got=${actual_sha}" >&2
      failed=$((failed + 1))
      rm -f "${tmp_file}"
      continue
    fi

    if ossutil cp "${tmp_file}" "${oss_uri}" \
      --force \
      --content-type "application/gzip" \
      --cache-control "public, max-age=31536000, immutable"; then
      uploaded=$((uploaded + 1))
    else
      echo "Upload failed: ${oss_uri}" >&2
      failed=$((failed + 1))
    fi
    rm -f "${tmp_file}"
  done
fi

{
  echo "### Sync To OSS Result"
  echo ""
  echo "- processed: ${processed}"
  echo "- uploaded: ${uploaded}"
  echo "- skipped: ${skipped}"
  echo "- failed: ${failed}"
  echo "- dry_run: ${DRY_RUN}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo ""
echo "Sync complete: processed=${processed} uploaded=${uploaded} skipped=${skipped} failed=${failed} dry_run=${DRY_RUN}"

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
