#!/usr/bin/env bash
#
# check-capsule-ownership.sh — Enforce group ownership and groups.yaml ↔ CODEOWNERS consistency.
#
# Checks:
#   - Every group in groups.yaml has a matching CODEOWNERS line (capsules/<group>/), and vice versa
#   - Owner sets are identical for each shared group
#   - PRs that touch capsules/<group>/*.yaml: each affected group must be declared in CODEOWNERS
#   - PRs touching multiple groups: CODEOWNERS must share at least one common @owner
#
# Flow:
#   1. Parse .github/CODEOWNERS and groups.yaml
#   2. git diff BASE_SHA..HEAD under capsules/ to find touched groups
#   3. Report mismatches or missing declarations; exit non-zero on failure
#
# Usage:
#   ./scripts/check-capsule-ownership.sh <base-sha>   # e.g. origin/main in PR CI
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEOWNERS="${ROOT_DIR}/.github/CODEOWNERS"
GROUPS_FILE="${ROOT_DIR}/groups.yaml"
BASE_SHA="${1:-${BASE_SHA:-HEAD~1}}"

if [[ ! -f "${CODEOWNERS}" ]]; then
  echo "CODEOWNERS not found: ${CODEOWNERS}" >&2
  exit 1
fi

if [[ ! -f "${GROUPS_FILE}" ]]; then
  echo "groups.yaml not found: ${GROUPS_FILE}" >&2
  exit 1
fi

python3 - <<'PY' "${CODEOWNERS}" "${GROUPS_FILE}" "${BASE_SHA}" "${ROOT_DIR}"
import re
import subprocess
import sys
from pathlib import Path

codeowners_path = Path(sys.argv[1])
groups_file = Path(sys.argv[2])
base_sha = sys.argv[3]
root_dir = Path(sys.argv[4])

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required. Install with: pip install pyyaml")

try:
    with open(groups_file) as f:
        groups_data = yaml.safe_load(f)
except yaml.YAMLError as e:
    raise SystemExit(f"{groups_file.name}: invalid YAML: {e}")

if not isinstance(groups_data, dict) or "groups" not in groups_data:
    raise SystemExit(f"{groups_file.name}: must contain 'groups' mapping")

registered_groups = groups_data["groups"]
if not isinstance(registered_groups, dict):
    raise SystemExit(f"{groups_file.name}: 'groups' must be a mapping")

GROUP_LINE = re.compile(
    r"^\s*capsules/(?P<group>[^/\s#]+)/\s+(?P<owners>.+?)\s*(?:#.*)?$"
)
OWNER_TOKEN = re.compile(r"@[^\s#]+")


def parse_codeowners(path: Path) -> dict[str, set[str]]:
    groups: dict[str, set[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = GROUP_LINE.match(line)
        if not match:
            continue
        group = match.group("group")
        owners = set(OWNER_TOKEN.findall(match.group("owners")))
        if owners:
            groups[group] = owners
    return groups


def changed_groups(base: str) -> set[str]:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(root_dir), "diff", "--name-only", base, "HEAD", "--", "capsules/"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return set()

    groups: set[str] = set()
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        match = re.match(r"capsules/([^/]+)/[^/]+\.yaml$", line)
        if match:
            groups.add(match.group(1))
    return groups


declared = parse_codeowners(codeowners_path)
touched = changed_groups(base_sha)

errors: list[str] = []

codeowners_groups = set(declared.keys())
groups_yaml_groups = set(registered_groups.keys())

in_codeowners_not_yaml = sorted(codeowners_groups - groups_yaml_groups)
if in_codeowners_not_yaml:
    errors.append(
        "The following group(s) are declared in .github/CODEOWNERS "
        "but not registered in groups.yaml:\n"
        f"    {', '.join(in_codeowners_not_yaml)}\n"
        "  Add corresponding entries to groups.yaml."
    )

in_yaml_not_codeowners = sorted(groups_yaml_groups - codeowners_groups)
if in_yaml_not_codeowners:
    hints = "\n".join(
        f"    capsules/{g}/  @owner"
        for g in in_yaml_not_codeowners
    )
    errors.append(
        "The following group(s) are registered in groups.yaml "
        "but not declared in .github/CODEOWNERS:\n"
        f"    {', '.join(in_yaml_not_codeowners)}\n"
        "  Add corresponding lines to .github/CODEOWNERS, e.g.:\n"
        f"{hints}"
    )

for gname in sorted(codeowners_groups & groups_yaml_groups):
    yaml_owners = set(registered_groups[gname].get("owners", []))
    codeowners_owners = declared[gname]
    if yaml_owners and yaml_owners != codeowners_owners:
        errors.append(
            f"Group '{gname}' has mismatched owners between groups.yaml and CODEOWNERS:\n"
            f"    groups.yaml:  {', '.join(sorted(yaml_owners))}\n"
            f"    CODEOWNERS:   {', '.join(sorted(codeowners_owners))}\n"
            "  Please keep them in sync."
        )

if not touched:
    print("capsule ownership check skipped (no capsule yaml changes)")
    if errors:
        print("\ngroups.yaml / CODEOWNERS consistency issues:", file=sys.stderr)
        for i, msg in enumerate(errors, 1):
            print(f"{i}. {msg}\n", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

undeclared = sorted(g for g in touched if g not in declared)
if undeclared:
    hints = "\n".join(
        f"    capsules/{g}/  @your-team-or-user"
        for g in undeclared
    )
    errors.append(
        "The following group(s) are not declared in .github/CODEOWNERS:\n"
        f"    {', '.join(undeclared)}\n"
        "  Add an explicit owner line before submitting capsule changes, e.g.:\n"
        f"{hints}\n"
        "  See docs/repo-management.md §5 and docs/contributing.md Appendix A."
    )

if len(touched) > 1:
    owner_sets = [declared[g] for g in sorted(touched) if g in declared]
    if len(owner_sets) == len(touched):
        common = set.intersection(*owner_sets) if owner_sets else set()
        if not common:
            detail = "\n".join(
                f"    capsules/{g}/ → {', '.join(sorted(declared[g]))}"
                for g in sorted(touched)
            )
            errors.append(
                "This PR modifies multiple capsule groups with no common CODEOWNERS:\n"
                f"{detail}\n"
                "  Split into separate PRs (one group each), or add a shared @owner to each group's line."
            )

if errors:
    print("Capsule ownership check failed:\n", file=sys.stderr)
    for i, msg in enumerate(errors, 1):
        print(f"{i}. {msg}\n", file=sys.stderr)
    sys.exit(1)

if len(touched) == 1:
    group = next(iter(touched))
    owners = ", ".join(sorted(declared[group]))
    print(f"capsule ownership check passed (group={group}, owners={owners})")
else:
    common = set.intersection(*(declared[g] for g in touched))
    print(
        "capsule ownership check passed "
        f"(groups={', '.join(sorted(touched))}, common owners={', '.join(sorted(common))})"
    )
PY
