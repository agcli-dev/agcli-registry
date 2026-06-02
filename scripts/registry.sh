#!/usr/bin/env bash
#
# registry.sh — Market registry CLI (validate, merge index, update lock).
#
# Subcommands:
#   merge   Build index.json from capsule YAML; verify releases; optionally update registry.lock.json
#
# Examples:
#   ./scripts/registry.sh merge --structure-only
#   ./scripts/registry.sh merge --write-lock
#   ./scripts/registry.sh merge --trust-base-lock-only --base-lock-file /tmp/base-lock.json \
#       --force-verify official/hello-world
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "${ROOT_DIR}/scripts/registry_market.py" --root "${ROOT_DIR}" "$@"
