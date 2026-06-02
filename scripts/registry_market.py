#!/usr/bin/env python3
"""Market registry: validate capsule declarations, verify releases, merge index and lock."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
import tempfile
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPTS_DIR))
from registry_release import derive_release_urls, validate_repository

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required. Install with: pip install pyyaml")

LOCK_SCHEMA_VERSION = "0.1.0"
INDEX_SCHEMA_VERSION = "0.1.0"
VALID_PUBLISHER_TIERS = {"verified", "community"}
SUMMARY_MAX_LENGTH = 250

# Semver 2.0 core + optional pre-release; build metadata (+...) is not part of precedence.
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\w.]+))?(?:\+[\w.]+)?$"
)


def is_valid_semver(version: str) -> bool:
    return SEMVER_RE.match(version) is not None


def parse_semver(version: str) -> tuple[int, int, int, str | None]:
    m = SEMVER_RE.match(version)
    if not m:
        raise ValueError(f"invalid semver: {version!r}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)


def compare_prerelease(a: str | None, b: str | None) -> int:
    """Return positive if a > b. Release (no prerelease) outranks any prerelease."""
    if a is None and b is None:
        return 0
    if a is None:
        return 1
    if b is None:
        return -1
    ids_a = a.split(".")
    ids_b = b.split(".")
    length = max(len(ids_a), len(ids_b))
    for i in range(length):
        if i >= len(ids_a):
            return -1
        if i >= len(ids_b):
            return 1
        da, db = ids_a[i], ids_b[i]
        na, nb = da.isdigit(), db.isdigit()
        if na and nb:
            ia, ib = int(da), int(db)
            if ia != ib:
                return 1 if ia > ib else -1
        elif na != nb:
            return -1 if na else 1
        elif da != db:
            return 1 if da > db else -1
    return 0


def compare_semver(a: str, b: str) -> int:
    """Return positive if a > b, zero if equal, negative if a < b."""
    ma, mi, pa, pre_a = parse_semver(a)
    mb, mi_b, pb, pre_b = parse_semver(b)
    if (ma, mi, pa) != (mb, mi_b, pb):
        ta, tb = (ma, mi, pa), (mb, mi_b, pb)
        return 1 if ta > tb else -1
    return compare_prerelease(pre_a, pre_b)


def validate_version_policy(
    capsules: list[CapsuleDecl], prior_entries: dict[str, dict]
) -> list[str]:
    errors: list[str] = []
    for decl in capsules:
        entry = prior_entries.get(decl.lock_key)
        if not isinstance(entry, dict):
            continue
        prior_version = entry.get("version")
        if not isinstance(prior_version, str) or not is_valid_semver(prior_version):
            continue
        ordering = compare_semver(decl.version, prior_version)
        if ordering < 0:
            errors.append(
                f"{decl.rel_path}: version {decl.version!r} must be greater than "
                f"published version {prior_version!r} for {decl.lock_key}"
            )
        elif ordering == 0 and not lock_entry_matches(entry, decl):
            errors.append(
                f"{decl.rel_path}: version {decl.version!r} is already published for "
                f"{decl.lock_key}; bump version to ship a new release"
            )
    return errors


@dataclass
class CapsuleDecl:
    group: str
    name: str
    version: str
    repository: str
    dist_url: str
    sha_url: str
    publisher_tier: str
    summary: str | None
    rel_path: str

    @property
    def lock_key(self) -> str:
        return f"{self.group}/{self.name}"

    @property
    def label(self) -> str:
        return f"{self.group}/{self.name}@{self.version}"


def extract_sha256_from_file(content: bytes) -> str | None:
    text = content.decode("utf-8", errors="replace").strip()
    if re.fullmatch(r"[0-9a-f]{64}", text):
        return text
    return None


# Tarball inspection limits (L2 identity check; no extraction to disk).
MAX_TARBALL_BYTES = 50 * 1024 * 1024
MAX_TAR_MEMBER_COUNT = 256
MAX_TAR_MEMBER_BYTES = 10 * 1024 * 1024
MAX_CAPSULE_YAML_BYTES = 256 * 1024


def normalize_tar_member_path(name: str) -> tuple[str | None, str | None]:
    """Return (normalized relative path, error). Rejects traversal and absolute paths."""
    if not name or name != name.strip():
        return None, "empty or whitespace path"
    if name.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", name):
        return None, "absolute path"
    if "\x00" in name:
        return None, "NUL byte in path"
    parts: list[str] = []
    for part in Path(name).parts:
        if part == "..":
            return None, "path traversal (..)"
        if part != ".":
            parts.append(part)
    norm = "/".join(parts)
    if not norm:
        return None, "empty path"
    return norm, None


def is_allowed_tar_member(norm: str, member: tarfile.TarInfo) -> bool:
    """Allow only capsule.yaml at archive root and scripts/ tree (see capsule-release-guide)."""
    if member.isdir():
        return norm == "scripts" or norm.startswith("scripts/")
    if member.issym() or member.islnk() or member.ischr() or member.isblk() or member.isfifo():
        return False
    if not member.isfile():
        return False
    if norm == "capsule.yaml":
        return True
    return norm.startswith("scripts/") and len(norm) > len("scripts/")


def open_tar_archive(path: str) -> tarfile.TarFile:
    kwargs: dict = {"mode": "r:gz"}
    if sys.version_info >= (3, 12):
        kwargs["filter"] = "data"
    return tarfile.open(path, **kwargs)


def read_limited_text(
    tf: tarfile.TarFile, member: tarfile.TarInfo, limit: int, label: str, path_label: str
) -> tuple[str | None, str | None]:
    if member.size > limit:
        return None, (
            f"{label}: {path_label} exceeds size limit "
            f"({member.size} bytes, max {limit})"
        )
    stream = tf.extractfile(member)
    if stream is None:
        return None, f"{label}: failed to read {path_label} from tarball"
    data = stream.read(limit + 1)
    if len(data) > limit:
        return None, f"{label}: {path_label} exceeds size limit (max {limit} bytes)"
    try:
        return data.decode("utf-8"), None
    except UnicodeDecodeError:
        return None, f"{label}: {path_label} is not valid UTF-8"


def validate_tar_identity(
    label: str, tar_bytes: bytes, expected_group: str, expected_name: str, expected_version: str
) -> str | None:
    if len(tar_bytes) > MAX_TARBALL_BYTES:
        return (
            f"{label}: tarball exceeds size limit "
            f"({len(tar_bytes)} bytes, max {MAX_TARBALL_BYTES})"
        )

    with tempfile.NamedTemporaryFile(suffix=".tar.gz") as tmp:
        tmp.write(tar_bytes)
        tmp.flush()
        with open_tar_archive(tmp.name) as tf:
            members = tf.getmembers()
            if len(members) > MAX_TAR_MEMBER_COUNT:
                return (
                    f"{label}: tarball has too many entries "
                    f"({len(members)}, max {MAX_TAR_MEMBER_COUNT})"
                )

            capsule_member: tarfile.TarInfo | None = None
            for member in members:
                norm, path_error = normalize_tar_member_path(member.name)
                if path_error:
                    return f"{label}: tarball unsafe path {member.name!r}: {path_error}"

                assert norm is not None
                if member.size > MAX_TAR_MEMBER_BYTES:
                    return (
                        f"{label}: tarball member {norm!r} exceeds size limit "
                        f"({member.size} bytes, max {MAX_TAR_MEMBER_BYTES})"
                    )
                if not is_allowed_tar_member(norm, member):
                    return f"{label}: tarball contains disallowed entry: {norm!r}"

                if norm == "capsule.yaml" and member.isfile():
                    if capsule_member is not None:
                        return (
                            f"{label}: tarball must contain exactly one root capsule.yaml"
                        )
                    capsule_member = member

            if capsule_member is None:
                return f"{label}: capsule.tar.gz does not contain root capsule.yaml"

            yaml_text, read_error = read_limited_text(
                tf, capsule_member, MAX_CAPSULE_YAML_BYTES, label, "capsule.yaml"
            )
            if read_error:
                return read_error

            assert yaml_text is not None
            try:
                capsule_data = yaml.safe_load(yaml_text)
            except Exception as e:
                return f"{label}: capsule.yaml in tarball is invalid YAML: {e}"

    if not isinstance(capsule_data, dict):
        return f"{label}: capsule.yaml in tarball must be a mapping"
    t_group = capsule_data.get("group")
    t_name = capsule_data.get("name")
    t_version = capsule_data.get("version")
    if t_group != expected_group or t_name != expected_name or t_version != expected_version:
        return (
            f"{label}: tarball capsule.yaml identity mismatch "
            f"(expected {expected_group}/{expected_name}@{expected_version}, "
            f"got {t_group}/{t_name}@{t_version})"
        )
    return None


def verify_release_network(decl: CapsuleDecl) -> tuple[dict, dict]:
    try:
        with urllib.request.urlopen(decl.sha_url, timeout=30) as resp:
            sha_file = resp.read()
    except Exception as e:
        raise ValueError(f"{decl.rel_path}: failed to download sha256 file: {e}") from e

    sha256 = extract_sha256_from_file(sha_file)
    if sha256 is None:
        raise ValueError(
            f"{decl.rel_path}: sha256 file content invalid for {decl.label} "
            "(must be single 64-char lowercase hex)"
        )

    try:
        with urllib.request.urlopen(decl.dist_url, timeout=90) as resp:
            tar_bytes = resp.read()
    except Exception as e:
        raise ValueError(f"{decl.rel_path}: failed to download tarball: {e}") from e

    actual_sha256 = hashlib.sha256(tar_bytes).hexdigest()
    if actual_sha256 != sha256:
        raise ValueError(
            f"{decl.rel_path}: tarball sha256 mismatch "
            f"(expected {sha256}, got {actual_sha256})"
        )

    tar_identity_error = validate_tar_identity(
        decl.label, tar_bytes, decl.group, decl.name, decl.version
    )
    if tar_identity_error:
        raise ValueError(f"{decl.rel_path}: {tar_identity_error}")

    dist = {"type": "tarball", "url": decl.dist_url}
    integrity = {"sha256": sha256}
    return dist, integrity


def lock_entry_matches(entry: dict, decl: CapsuleDecl) -> bool:
    if not isinstance(entry, dict):
        return False
    if entry.get("version") != decl.version:
        return False
    repo = entry.get("repository")
    if not isinstance(repo, str) or repo.strip() != decl.repository.strip():
        return False
    dist = entry.get("dist")
    if not isinstance(dist, dict) or dist.get("type") != "tarball":
        return False
    if dist.get("url") != decl.dist_url:
        return False
    integrity = entry.get("integrity")
    if not isinstance(integrity, dict):
        return False
    sha = integrity.get("sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        return False
    return True


def lock_entry_from_proof(decl: CapsuleDecl, dist: dict, integrity: dict) -> dict:
    return {
        "version": decl.version,
        "repository": decl.repository.strip(),
        "dist": dist,
        "integrity": integrity,
    }


def load_lock(path: Path) -> dict:
    if not path.is_file():
        return {"schema_version": LOCK_SCHEMA_VERSION, "entries": {}}
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: lock file must be a JSON object")
    if data.get("schema_version") != LOCK_SCHEMA_VERSION:
        raise SystemExit(
            f"{path}: unsupported schema_version {data.get('schema_version')!r} "
            f"(expected {LOCK_SCHEMA_VERSION})"
        )
    entries = data.get("entries")
    if not isinstance(entries, dict):
        raise SystemExit(f"{path}: 'entries' must be an object")
    return data


def write_lock(path: Path, entries: dict[str, dict]) -> None:
    payload = {
        "schema_version": LOCK_SCHEMA_VERSION,
        "entries": dict(sorted(entries.items())),
    }
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")


def validate_group(value: str, rel_path: str) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{rel_path}: group must be non-empty string")
    if value.startswith("_"):
        raise ValueError(f"{rel_path}: group '{value}' must not start with '_'")
    if "/" in value:
        raise ValueError(f"{rel_path}: group must not contain '/'")
    if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?", value):
        raise ValueError(f"{rel_path}: group must be alphanumeric with hyphens, dots, underscores")


def validate_name(value: str, rel_path: str) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{rel_path}: name must be non-empty string")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value):
        raise ValueError(f"{rel_path}: name must be lowercase alphanumeric with hyphens")


def validate_groups(groups_file: Path, groups_data: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(groups_data, dict) or "groups" not in groups_data:
        return [f"{groups_file.name}: must contain 'groups' mapping"]
    registered_groups = groups_data["groups"]
    if not isinstance(registered_groups, dict):
        return [f"{groups_file.name}: 'groups' must be a mapping"]
    for gname, gval in registered_groups.items():
        if not isinstance(gval, dict):
            errors.append(f"{groups_file.name}: groups.{gname} must be a mapping")
            continue
        tier = gval.get("tier")
        if not isinstance(tier, str) or tier not in VALID_PUBLISHER_TIERS:
            errors.append(
                f"{groups_file.name}: groups.{gname}.tier must be one of {sorted(VALID_PUBLISHER_TIERS)}"
            )
        owners = gval.get("owners")
        if not isinstance(owners, list) or not owners:
            errors.append(f"{groups_file.name}: groups.{gname}.owners must be a non-empty list")
        elif not all(isinstance(o, str) and o.startswith("@") for o in owners):
            errors.append(f"{groups_file.name}: groups.{gname}.owners entries must start with '@'")
    return errors


def scan_capsules(capsules_dir: Path, groups_file: Path, registered_groups: dict) -> tuple[list[CapsuleDecl], list[str]]:
    errors: list[str] = []
    capsules: list[CapsuleDecl] = []
    repo_to_group: dict[str, str] = {}

    if not capsules_dir.is_dir():
        return [], [f"capsules directory not found: {capsules_dir}"]

    for group_dir in sorted(capsules_dir.iterdir()):
        if not group_dir.is_dir() or group_dir.name.startswith("."):
            continue

        group = group_dir.name
        rel_group = f"capsules/{group}"
        try:
            validate_group(group, rel_group)
        except ValueError as e:
            errors.append(str(e))
            continue

        if group not in registered_groups:
            errors.append(f"capsules/{group}: group not registered in groups.yaml")
            continue

        group_tier = registered_groups[group].get("tier", "community")

        for yaml_file in sorted(group_dir.glob("*.yaml")):
            if yaml_file.name.startswith("."):
                continue

            name = yaml_file.stem
            rel_path = str(yaml_file.relative_to(capsules_dir.parent))

            try:
                with open(yaml_file, encoding="utf-8") as f:
                    data = yaml.safe_load(f)
            except yaml.YAMLError as e:
                errors.append(f"{rel_path}: invalid YAML: {e}")
                continue

            if data is None:
                errors.append(f"{rel_path}: empty file")
                continue
            if not isinstance(data, dict):
                errors.append(f"{rel_path}: must be a mapping")
                continue

            try:
                validate_name(name, rel_path)
            except ValueError as e:
                errors.append(str(e))
                continue

            yaml_name = data.get("name")
            if yaml_name is not None:
                if not isinstance(yaml_name, str):
                    errors.append(f"{rel_path}: name must be a string")
                    continue
                if yaml_name != name:
                    errors.append(
                        f"{rel_path}: name '{yaml_name}' does not match filename '{name}.yaml'"
                    )
                    continue

            version = data.get("version")
            if not isinstance(version, str) or not version:
                errors.append(f"{rel_path}: version must be non-empty string")
                continue
            if not is_valid_semver(version):
                errors.append(
                    f"{rel_path}: version must follow semver (e.g. 1.0.0, 1.2.3-beta.1)"
                )
                continue

            summary = data.get("summary")
            if summary is not None and not isinstance(summary, str):
                errors.append(f"{rel_path}: summary must be a string")
                continue
            if isinstance(summary, str) and len(summary) > SUMMARY_MAX_LENGTH:
                errors.append(
                    f"{rel_path}: summary must be at most {SUMMARY_MAX_LENGTH} characters "
                    f"(got {len(summary)})"
                )
                continue

            repository = data.get("repository")
            repo_errors, owner, repo = validate_repository(rel_path, repository)
            if repo_errors:
                errors.extend(repo_errors)
                continue
            assert owner is not None and repo is not None
            repo_key = f"{owner.lower()}/{repo.lower()}"
            prev_group = repo_to_group.get(repo_key)
            if prev_group is None:
                repo_to_group[repo_key] = group
            elif prev_group != group:
                errors.append(
                    f"{rel_path}: repository '{repository}' is already associated "
                    f"with group '{prev_group}', cannot also belong to '{group}'"
                )
                continue

            dist_url, sha_url = derive_release_urls(owner, repo, name, version)
            capsules.append(
                CapsuleDecl(
                    group=group,
                    name=name,
                    version=version,
                    repository=repository.strip(),
                    dist_url=dist_url,
                    sha_url=sha_url,
                    publisher_tier=group_tier,
                    summary=summary if isinstance(summary, str) else None,
                    rel_path=rel_path,
                )
            )

    pairs = [(p.group, p.name) for p in capsules]
    dups = [k for k, v in Counter(pairs).items() if v > 1]
    if dups:
        dup_str = ", ".join([f"({g}, {n})" for g, n in dups])
        errors.append(f"duplicate (group, name): {dup_str}")

    return capsules, errors


def load_trust_entries(args: argparse.Namespace, lock_file: Path) -> dict[str, dict]:
    if args.trust_base_lock_only:
        if not args.base_lock_file:
            return {}
        base_lock = load_lock(Path(args.base_lock_file))
        return base_lock.get("entries", {})
    local_lock = load_lock(lock_file)
    return dict(local_lock.get("entries", {}))


def build_index_entry(decl: CapsuleDecl, dist: dict, integrity: dict) -> dict:
    entry = {
        "group": decl.group,
        "name": decl.name,
        "version": decl.version,
        "repository": decl.repository,
        "dist": dist,
        "integrity": integrity,
        "publisher_tier": decl.publisher_tier,
    }
    if decl.summary:
        entry["summary"] = decl.summary
    return entry


def run_merge(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    capsules_dir = root / "capsules"
    groups_file = root / "groups.yaml"
    index_file = root / "index.json"
    lock_file = root / args.lock_file

    if not groups_file.is_file():
        print(f"groups.yaml not found: {groups_file}", file=sys.stderr)
        return 1

    try:
        with open(groups_file, encoding="utf-8") as f:
            groups_data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"{groups_file.name}: invalid YAML: {e}", file=sys.stderr)
        return 1

    group_errors = validate_groups(groups_file, groups_data)
    if group_errors:
        for e in group_errors:
            print(f"  \u2717 {e}", file=sys.stderr)
        return 1

    registered_groups = groups_data["groups"]
    capsules, errors = scan_capsules(capsules_dir, groups_file, registered_groups)
    if errors:
        for e in errors:
            print(f"  \u2717 {e}", file=sys.stderr)
        print(f"structure validation failed ({len(errors)} error(s))", file=sys.stderr)
        return 1

    print(f"structure validation passed ({len(capsules)} capsules)")

    if args.trust_base_lock_only and not args.base_lock_file:
        print("--trust-base-lock-only requires --base-lock-file", file=sys.stderr)
        return 1

    trust_entries = load_trust_entries(args, lock_file)
    version_errors = validate_version_policy(capsules, trust_entries)
    if version_errors:
        for e in version_errors:
            print(f"  \u2717 {e}", file=sys.stderr)
        print(f"version validation failed ({len(version_errors)} error(s))", file=sys.stderr)
        return 1

    if args.structure_only:
        print("structure-only mode (no release verification)")
        return 0

    force_verify: set[tuple[str, str]] = set()
    for item in args.force_verify:
        if "/" in item:
            force_verify.add(tuple(item.split("/", 1)))

    new_lock_entries: dict[str, dict] = {}
    index_capsules: list[dict] = []
    verify_errors: list[str] = []

    for decl in capsules:
        key = decl.lock_key
        use_lock = (
            not args.verify_all
            and (decl.group, decl.name) not in force_verify
            and key in trust_entries
            and lock_entry_matches(trust_entries[key], decl)
        )

        try:
            if use_lock:
                entry = trust_entries[key]
                dist = entry["dist"]
                integrity = entry["integrity"]
                print(f"  \u2713 {decl.label}: reused lock proof")
            else:
                dist, integrity = verify_release_network(decl)
                print(f"  \u2713 {decl.label}: release verified (download)")
            new_lock_entries[key] = lock_entry_from_proof(decl, dist, integrity)
            index_capsules.append(build_index_entry(decl, dist, integrity))
        except ValueError as e:
            verify_errors.append(str(e))

    if verify_errors:
        for e in verify_errors:
            print(f"  \u2717 {e}", file=sys.stderr)
        print(f"release verification failed ({len(verify_errors)} error(s))", file=sys.stderr)
        return 1

    index_capsules.sort(key=lambda p: (p["group"], p["name"], p["version"]))
    index_data = {"schema_version": INDEX_SCHEMA_VERSION, "capsules": index_capsules}

    with open(index_file, "w", encoding="utf-8", newline="\n") as f:
        json.dump(index_data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"merged {len(index_capsules)} capsules into {index_file}")

    if args.write_lock:
        write_lock(lock_file, new_lock_entries)
        print(f"updated {lock_file}")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Market registry validate and merge")
    parser.add_argument(
        "--root",
        default=".",
        help="Repository root (default: current directory)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    merge_p = sub.add_parser("merge", help="Validate declarations and build index.json")
    merge_p.add_argument(
        "--structure-only",
        action="store_true",
        help="Validate groups and capsule YAML only; no network",
    )
    merge_p.add_argument(
        "--write-lock",
        action="store_true",
        help="Write registry.lock.json with verified release proofs",
    )
    merge_p.add_argument(
        "--lock-file",
        default="registry.lock.json",
        help="Lock file path relative to repo root (default: registry.lock.json)",
    )
    merge_p.add_argument(
        "--base-lock-file",
        help="Optional lock snapshot (e.g. from origin/main) for PR incremental verify",
    )
    merge_p.add_argument(
        "--trust-base-lock-only",
        action="store_true",
        help="Only trust --base-lock-file entries for cache hits (PR safety)",
    )
    merge_p.add_argument(
        "--force-verify",
        action="append",
        default=[],
        metavar="group/name",
        help="Always download and verify this capsule (repeatable)",
    )
    merge_p.add_argument(
        "--verify-all",
        action="store_true",
        help="Ignore lock cache; verify every capsule (audit)",
    )
    merge_p.set_defaults(func=run_merge)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
