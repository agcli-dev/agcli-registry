#!/usr/bin/env bash
#
# sync-capsules-to-oss.sh — Mirror capsule tarballs from index.json into OSS.
#
# Checks:
#   - Required OSS env vars and ossutil on PATH
#   - index.json has a capsules[] array; each entry has group, name, version, dist.url, integrity.sha256
#   - Path segments match registry naming rules; version is valid semver
#   - Downloaded bytes match integrity.sha256 before upload
#
# Flow:
#   1. Load index.json (local or INDEX_URL)
#   2. For each capsule (optional MAX_CAPSULES limit): upload if missing at the versioned key
#   3. Prune (unless PRUNE_RETENTION=false): delist cleanup + keep at most MAX_VERSIONS_PER_CAPSULE
#
# OSS layout (no OSS_PREFIX):
#   capsules/<group>/<name>/v<version>/capsule.tar.gz
#
# Retention (PRUNE_RETENTION=true, default):
#   - Packages removed from index: delete oss://<bucket>/capsules/<group>/<name>/ entirely
#   - Packages still in index: keep the index version plus the newest (MAX_VERSIONS_PER_CAPSULE - 1)
#     other versions by semver; delete older OSS version directories
#
# Environment:
#   OSS_ACCESS_KEY_ID, OSS_ACCESS_KEY_SECRET, OSS_ENDPOINT, OSS_BUCKET — required
#   OSS_REGION       — optional; derived from OSS_ENDPOINT if unset (ossutil 2.x V4 signing)
#   INDEX_URL        — optional HTTPS URL to fetch index.json
#   DRY_RUN          — "true" to print planned uploads/deletes only (default: true)
#   MAX_CAPSULES     — max entries to process; 0 = no limit
#   MAX_VERSIONS_PER_CAPSULE — versions to retain per group/name (default: 3)
#   PRUNE_RETENTION  — "false" to skip post-sync prune (default: true)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ossutil-env.sh
source "${SCRIPT_DIR}/ossutil-env.sh"

ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INDEX_FILE="${ROOT_DIR}/index.json"

DRY_RUN="${DRY_RUN:-true}"
MAX_CAPSULES="${MAX_CAPSULES:-0}"
MAX_VERSIONS_PER_CAPSULE="${MAX_VERSIONS_PER_CAPSULE:-3}"
PRUNE_RETENTION="${PRUNE_RETENTION:-true}"
INDEX_URL="${INDEX_URL:-}"

GROUP_RE='^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'
NAME_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
CAPSULE_OBJECT_RE='^capsules/([^/]+)/([^/]+)/v([^/]+)/capsule\.tar\.gz$'

if ! ossutil_ensure_env; then
  exit 1
fi

if ! command -v ossutil &>/dev/null; then
  echo "Error: ossutil not found in PATH." >&2
  echo "Run ./scripts/install-ossutil.sh to install." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq not found in PATH." >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 not found in PATH (required for semver retention)." >&2
  exit 1
fi

if ! [[ "${MAX_VERSIONS_PER_CAPSULE}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: MAX_VERSIONS_PER_CAPSULE must be a positive integer." >&2
  exit 1
fi

echo "Using ossutil ($(ossutil version 2>&1 | head -1))"
echo "  Region: ${OSS_REGION}"
echo "  Endpoint: ${OSS_ENDPOINT}"
echo "  Retention: max ${MAX_VERSIONS_PER_CAPSULE} version(s) per package (prune=${PRUNE_RETENTION})"

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

validate_path_segment() {
  local kind="$1" value="$2" re="$3"
  if [[ -z "${value}" ]] || [[ "${value}" == "unknown" ]]; then
    return 1
  fi
  [[ "${value}" =~ ${re} ]]
}

capsule_object_key() {
  local group="$1" name="$2" version="$3"
  echo "capsules/${group}/${name}/v${version}/capsule.tar.gz"
}

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

    group=$(jq -r ".capsules[$i].group // empty" "${INDEX_FILE}")
    name=$(jq -r ".capsules[$i].name // empty" "${INDEX_FILE}")
    url=$(jq -r ".capsules[$i].dist.url // empty" "${INDEX_FILE}")
    sha=$(jq -r ".capsules[$i].integrity.sha256 // empty" "${INDEX_FILE}")
    version=$(jq -r ".capsules[$i].version // empty" "${INDEX_FILE}")

    if [[ -z "${group}" ]] || [[ -z "${name}" ]] || [[ -z "${version}" ]]; then
      echo "Skip entry #${i}: missing group, name, or version"
      skipped=$((skipped + 1))
      continue
    fi

    if ! validate_path_segment "group" "${group}" "${GROUP_RE}"; then
      echo "Skip ${group}/${name}@${version}: invalid group for OSS path"
      skipped=$((skipped + 1))
      continue
    fi

    if ! validate_path_segment "name" "${name}" "${NAME_RE}"; then
      echo "Skip ${group}/${name}@${version}: invalid name for OSS path"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ -z "${url}" ]] || [[ -z "${sha}" ]]; then
      echo "Skip ${group}/${name}@${version}: missing dist.url or integrity.sha256"
      skipped=$((skipped + 1))
      continue
    fi

    if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "Skip ${group}/${name}@${version}: invalid sha256 format"
      skipped=$((skipped + 1))
      continue
    fi

    key=$(capsule_object_key "${group}" "${name}" "${version}")
    oss_uri="oss://${OSS_BUCKET}/${key}"
    tmp_file="${WORK_DIR}/${sha}.tgz"

    processed=$((processed + 1))
    echo "Processing ${group}/${name}@${version} -> ${oss_uri}"

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
      echo "Integrity mismatch for ${group}/${name}@${version}: expected=${sha}, got=${actual_sha}" >&2
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

pruned=0
prune_failed=0

if [[ "${PRUNE_RETENTION}" == "true" ]]; then
  echo ""
  echo "Pruning OSS capsule objects (dry_run=${DRY_RUN})..."
  PRUNE_PLAN="${WORK_DIR}/prune-plan.txt"
  : > "${PRUNE_PLAN}"

  export INDEX_FILE OSS_BUCKET MAX_VERSIONS_PER_CAPSULE DRY_RUN PRUNE_PLAN CAPSULE_OBJECT_RE SCRIPT_DIR
  if ! python3 - <<'PY'
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.environ["SCRIPT_DIR"])
from registry_market import compare_semver, is_valid_semver  # noqa: E402

index_file = os.environ["INDEX_FILE"]
bucket = os.environ["OSS_BUCKET"]
max_versions = int(os.environ["MAX_VERSIONS_PER_CAPSULE"])
plan_path = os.environ["PRUNE_PLAN"]
object_re = re.compile(os.environ["CAPSULE_OBJECT_RE"])

with open(index_file, encoding="utf-8") as f:
    index = json.load(f)

index_current: dict[tuple[str, str], str] = {}
for cap in index.get("capsules", []):
    if not isinstance(cap, dict):
        continue
    group = cap.get("group")
    name = cap.get("name")
    version = cap.get("version")
    if isinstance(group, str) and isinstance(name, str) and isinstance(version, str):
        index_current[(group, name)] = version

ls = subprocess.run(
    ["ossutil", "ls", f"oss://{bucket}/capsules/", "-r"],
    capture_output=True,
    text=True,
)
if ls.returncode != 0:
    stderr = (ls.stderr or "").strip()
    if "NoSuchKey" in stderr or ls.returncode == 1:
        sys.exit(0)
    print(stderr or f"ossutil ls failed (exit {ls.returncode})", file=sys.stderr)
    sys.exit(1)

objects: dict[tuple[str, str], set[str]] = {}
for line in ls.stdout.splitlines():
    for token in line.split():
        if not token.startswith("oss://"):
            continue
        key = token.removeprefix(f"oss://{bucket}/")
        m = object_re.match(key)
        if not m:
            continue
        group, name, ver = m.group(1), m.group(2), m.group(3)
        objects.setdefault((group, name), set()).add(ver)

plans: list[tuple[str, str]] = []

for package, versions in sorted(objects.items()):
    if package not in index_current:
        prefix = f"oss://{bucket}/capsules/{package[0]}/{package[1]}/"
        plans.append(("rm-r", prefix))
        continue

    current = index_current[package]
    valid = [v for v in versions if is_valid_semver(v)]
    invalid = sorted(versions - set(valid))
    for ver in invalid:
        plans.append(
            (
                "rm-r",
                f"oss://{bucket}/capsules/{package[0]}/{package[1]}/v{ver}/",
            )
        )

    if current not in versions and is_valid_semver(current):
        valid.append(current)

    if not valid:
        continue

    ranked = sorted(
        valid,
        key=lambda v: (compare_semver(v, "0.0.0"), v),
        reverse=True,
    )
    keep = set(ranked[:max_versions])
    keep.add(current)

    for ver in versions:
        if ver in keep:
            continue
        if not is_valid_semver(ver):
            continue
        plans.append(
            (
                "rm-r",
                f"oss://{bucket}/capsules/{package[0]}/{package[1]}/v{ver}/",
            )
        )

with open(plan_path, "w", encoding="utf-8") as out:
    for action, uri in plans:
        out.write(f"{action}\t{uri}\n")
PY
  then
    echo "Prune plan failed." >&2
    prune_failed=1
  else
    while IFS=$'\t' read -r action uri; do
      [[ -z "${uri}" ]] && continue
      echo "Planned ${action}: ${uri}"
      if [[ "${DRY_RUN}" == "true" ]]; then
        continue
      fi
      if [[ "${action}" == "rm-r" ]]; then
        if ossutil rm -r "${uri}" -f; then
          pruned=$((pruned + 1))
        else
          echo "Delete failed: ${uri}" >&2
          prune_failed=1
        fi
      fi
    done < "${PRUNE_PLAN}"
  fi
fi

{
  echo "### Sync To OSS Result"
  echo ""
  echo "- processed: ${processed}"
  echo "- uploaded: ${uploaded}"
  echo "- skipped: ${skipped}"
  echo "- failed: ${failed}"
  echo "- pruned: ${pruned}"
  echo "- prune_failed: ${prune_failed}"
  echo "- dry_run: ${DRY_RUN}"
  echo "- max_versions_per_capsule: ${MAX_VERSIONS_PER_CAPSULE}"
  echo "- prune_retention: ${PRUNE_RETENTION}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo ""
echo "Sync complete: processed=${processed} uploaded=${uploaded} skipped=${skipped} failed=${failed} pruned=${pruned} dry_run=${DRY_RUN}"

if [[ "${failed}" -gt 0 ]] || [[ "${prune_failed}" -gt 0 ]]; then
  exit 1
fi
