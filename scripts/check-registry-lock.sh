#!/usr/bin/env bash
#
# check-registry-lock.sh — Reject PRs that modify registry.lock.json.
#
# registry.lock.json is updated only by publish-index (github-actions bot) on main
# after release verification. Contributors must not edit it in pull requests.
#
# Usage:
#   ./scripts/check-registry-lock.sh <base-ref-or-sha>   # e.g. origin/main or PR base SHA
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${ROOT_DIR}/registry.lock.json"
BASE_REF="${1:?usage: check-registry-lock.sh <base-ref-or-sha>}"

if [[ ! -f "${LOCK_FILE}" ]]; then
  echo "registry.lock.json not found: ${LOCK_FILE}" >&2
  exit 1
fi

if ! git -C "${ROOT_DIR}" rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "Error: cannot resolve base ref: ${BASE_REF}" >&2
  exit 1
fi

CHANGED="$(git -C "${ROOT_DIR}" diff --name-only "${BASE_REF}" HEAD -- registry.lock.json)"
if [[ -n "${CHANGED}" ]]; then
  echo "Error: pull requests must not modify registry.lock.json." >&2
  echo "  This file is written automatically when publish-index runs on main." >&2
  echo "  Revert changes to registry.lock.json and push again." >&2
  exit 1
fi

echo "registry.lock.json unchanged (base ${BASE_REF})"
