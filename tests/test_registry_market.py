"""Unit tests for registry_market.py core logic."""

from __future__ import annotations

import io
import tarfile
from pathlib import Path

import pytest
import yaml

from registry_market import (
    SUMMARY_MAX_LENGTH,
    CapsuleDecl,
    compare_semver,
    extract_sha256_from_file,
    is_allowed_tar_member,
    is_valid_semver,
    lock_entry_matches,
    normalize_tar_member_path,
    scan_capsules,
    validate_group,
    validate_groups,
    validate_name,
    validate_tar_identity,
    validate_version_policy,
)


def _tar_member(name: str, content: bytes, *, mode: int = 0o644) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name=name)
    info.size = len(content)
    info.mode = mode
    return info


def build_tarball(files: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, content in files.items():
            tf.addfile(_tar_member(name, content), io.BytesIO(content))
    return buf.getvalue()


def make_decl(**overrides) -> CapsuleDecl:
    defaults = dict(
        group="official",
        name="hello-world",
        version="1.0.0",
        repository="https://github.com/agcli/hello-world",
        dist_url="https://github.com/agcli/hello-world/releases/download/hello-world/v1.0.0/capsule.tar.gz",
        sha_url="https://github.com/agcli/hello-world/releases/download/hello-world/v1.0.0/capsule.tar.gz.sha256",
        publisher_tier="verified",
        summary=None,
        rel_path="capsules/official/hello-world.yaml",
    )
    defaults.update(overrides)
    return CapsuleDecl(**defaults)


@pytest.mark.parametrize(
    "version,valid",
    [
        ("1.0.0", True),
        ("0.0.0", True),
        ("12.34.56-beta.1", True),
        ("1.0.0+build", True),
        ("1.0", False),
        ("v1.0.0", False),
        ("01.0.0", False),
    ],
)
def test_is_valid_semver(version: str, valid: bool) -> None:
    assert is_valid_semver(version) is valid


@pytest.mark.parametrize(
    "a,b,sign",
    [
        ("2.0.0", "1.9.9", 1),
        ("1.0.0", "1.0.0-beta.1", 1),
        ("1.0.0-beta.2", "1.0.0-beta.1", 1),
        ("1.0.0", "1.0.0", 0),
        ("1.0.0-alpha", "1.0.0-beta", -1),
    ],
)
def test_compare_semver(a: str, b: str, sign: int) -> None:
    assert compare_semver(a, b) == sign


def test_extract_sha256_from_file() -> None:
    good = b"abcd" * 16
    assert extract_sha256_from_file(good) == good.decode()
    assert extract_sha256_from_file(b"  " + good + b"\n") == good.decode()
    assert extract_sha256_from_file(b"not-hex") is None


@pytest.mark.parametrize(
    "path,error_substr",
    [
        ("../etc/passwd", "traversal"),
        ("/etc/passwd", "absolute"),
        ("foo/../bar", "traversal"),
        ("", "empty"),
    ],
)
def test_normalize_tar_member_path_rejects(path: str, error_substr: str) -> None:
    norm, err = normalize_tar_member_path(path)
    assert norm is None
    assert err is not None
    assert error_substr in err


def test_normalize_tar_member_path_ok() -> None:
    norm, err = normalize_tar_member_path("./scripts/./run.sh")
    assert err is None
    assert norm == "scripts/run.sh"


def test_is_allowed_tar_member() -> None:
    root_yaml = tarfile.TarInfo("capsule.yaml")
    root_yaml.type = tarfile.REGTYPE
    assert is_allowed_tar_member("capsule.yaml", root_yaml)

    script = tarfile.TarInfo("scripts/run.sh")
    script.type = tarfile.REGTYPE
    assert is_allowed_tar_member("scripts/run.sh", script)

    readme = tarfile.TarInfo("README.md")
    readme.type = tarfile.REGTYPE
    assert not is_allowed_tar_member("README.md", readme)

    symlink = tarfile.TarInfo("scripts/link")
    symlink.type = tarfile.SYMTYPE
    assert not is_allowed_tar_member("scripts/link", symlink)


def test_validate_tar_identity_ok() -> None:
    capsule_yaml = yaml.dump(
        {"group": "official", "name": "hello-world", "version": "1.0.0"}
    ).encode()
    tar = build_tarball(
        {
            "capsule.yaml": capsule_yaml,
            "scripts/run.sh": b"#!/bin/sh\necho hi\n",
        }
    )
    err = validate_tar_identity(
        "official/hello-world@1.0.0", tar, "official", "hello-world", "1.0.0"
    )
    assert err is None


def test_validate_tar_identity_mismatch() -> None:
    capsule_yaml = yaml.dump(
        {"group": "official", "name": "hello-world", "version": "9.9.9"}
    ).encode()
    tar = build_tarball({"capsule.yaml": capsule_yaml})
    err = validate_tar_identity(
        "label", tar, "official", "hello-world", "1.0.0"
    )
    assert err is not None
    assert "identity mismatch" in err


def test_validate_tar_identity_disallowed_file() -> None:
    capsule_yaml = yaml.dump(
        {"group": "g", "name": "n", "version": "1.0.0"}
    ).encode()
    tar = build_tarball({"capsule.yaml": capsule_yaml, "evil.txt": b"x"})
    err = validate_tar_identity("label", tar, "g", "n", "1.0.0")
    assert err is not None
    assert "disallowed" in err


def test_lock_entry_matches() -> None:
    decl = make_decl()
    entry = {
        "version": "1.0.0",
        "repository": "https://github.com/agcli/hello-world",
        "dist": {"type": "tarball", "url": decl.dist_url},
        "integrity": {"sha256": "a" * 64},
    }
    assert lock_entry_matches(entry, decl)
    assert not lock_entry_matches({**entry, "version": "2.0.0"}, decl)


def test_validate_version_policy_rejects_downgrade() -> None:
    decl = make_decl(version="1.0.0")
    prior = {
        "official/hello-world": {
            "version": "2.0.0",
            "repository": decl.repository,
            "dist": {"type": "tarball", "url": decl.dist_url},
            "integrity": {"sha256": "b" * 64},
        }
    }
    errors = validate_version_policy([decl], prior)
    assert len(errors) == 1
    assert "must be greater than" in errors[0]


def test_validate_version_policy_same_version_metadata_change() -> None:
    decl = make_decl(version="1.0.0", repository="https://github.com/agcli/other")
    prior = {
        "official/hello-world": {
            "version": "1.0.0",
            "repository": "https://github.com/agcli/hello-world",
            "dist": {"type": "tarball", "url": decl.dist_url},
            "integrity": {"sha256": "c" * 64},
        }
    }
    errors = validate_version_policy([decl], prior)
    assert len(errors) == 1
    assert "bump version" in errors[0]


def test_validate_group_and_name() -> None:
    with pytest.raises(ValueError, match="group"):
        validate_group("_hidden", "capsules/_hidden")
    with pytest.raises(ValueError, match="name"):
        validate_name("Bad_Name", "capsules/g/Bad_Name.yaml")


def test_validate_groups() -> None:
    path = Path("groups.yaml")
    errors = validate_groups(path, {"groups": {"x": {"tier": "bogus", "owners": []}}})
    assert any("tier must be" in e for e in errors)
    assert any("owners must be" in e for e in errors)


def test_scan_capsules(repo_root: Path) -> None:
    groups_file = repo_root / "groups.yaml"
    with open(groups_file, encoding="utf-8") as f:
        groups_data = yaml.safe_load(f)
    capsules, errors = scan_capsules(
        repo_root / "capsules", groups_file, groups_data["groups"]
    )
    assert errors == []
    assert len(capsules) == 1
    assert capsules[0].lock_key == "official/hello-world"


def test_scan_capsules_rejects_summary_over_max_length(repo_root: Path) -> None:
    capsule = repo_root / "capsules" / "official" / "hello-world.yaml"
    capsule.write_text(
        f"""name: hello-world
version: 1.0.0
summary: "{'x' * (SUMMARY_MAX_LENGTH + 1)}"
repository: https://github.com/agcli/hello-world
""",
        encoding="utf-8",
    )
    groups_file = repo_root / "groups.yaml"
    with open(groups_file, encoding="utf-8") as f:
        groups_data = yaml.safe_load(f)
    _, errors = scan_capsules(
        repo_root / "capsules", groups_file, groups_data["groups"]
    )
    assert len(errors) == 1
    assert "summary must be at most" in errors[0]
