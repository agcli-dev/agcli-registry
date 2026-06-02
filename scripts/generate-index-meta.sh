#!/usr/bin/env bash
#
# generate-index-meta.sh — Write index.meta.json with a SHA-256 digest of index.json.
#
# Checks:
#   - index.json must exist in repo root
#
# Flow:
#   1. Hash index.json (SHA-256, lowercase hex)
#   2. Write index.meta.json: schema_version, hash, updated_at (UTC)
#
# Output:
#   index.meta.json — clients can compare hash against the downloaded index.json
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_FILE="${ROOT_DIR}/index.json"
META_FILE="${ROOT_DIR}/index.meta.json"

if [[ ! -f "${INDEX_FILE}" ]]; then
  echo "index.json not found: ${INDEX_FILE}" >&2
  exit 1
fi

HASH="$(python3 - <<'PY' "${INDEX_FILE}"
import hashlib
import sys

with open(sys.argv[1], "rb") as f:
    print(hashlib.sha256(f.read()).hexdigest())
PY
)"

python3 - <<'PY' "${META_FILE}" "${HASH}"
import json
import sys
from datetime import datetime, timezone

meta_file, hash_value = sys.argv[1], sys.argv[2]
payload = {
    "schema_version": "0.1.0",
    "hash": hash_value,
    "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(meta_file, "w", encoding="utf-8", newline="\n") as f:
    json.dump(payload, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

echo "generated ${META_FILE}"
