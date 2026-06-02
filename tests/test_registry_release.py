"""Unit tests for registry_release.py."""

from __future__ import annotations

import pytest

from registry_release import derive_release_urls, parse_github_repository, validate_repository


@pytest.mark.parametrize(
    "url,expected",
    [
        ("https://github.com/agcli/hello-world", ("agcli", "hello-world")),
        ("https://github.com/Org/Repo.git/", ("Org", "Repo")),
        ("  https://github.com/foo/bar  ", ("foo", "bar")),
    ],
)
def test_parse_github_repository_valid(url: str, expected: tuple[str, str]) -> None:
    assert parse_github_repository(url) == expected


@pytest.mark.parametrize(
    "url",
    [
        "",
        "not-a-url",
        "https://gitlab.com/foo/bar",
        "https://github.com/only-one-segment",
        "http://github.com/foo/bar",
    ],
)
def test_parse_github_repository_invalid(url: str) -> None:
    assert parse_github_repository(url) is None


def test_validate_repository_missing() -> None:
    errors, owner, repo = validate_repository("capsules/x/a.yaml", None)
    assert errors
    assert owner is None
    assert repo is None


def test_validate_repository_invalid_url() -> None:
    errors, owner, repo = validate_repository(
        "capsules/x/a.yaml", "https://example.com/o/r"
    )
    assert any("repository must be" in e for e in errors)
    assert owner is None


def test_validate_repository_ok() -> None:
    errors, owner, repo = validate_repository(
        "capsules/x/a.yaml", "https://github.com/acme/tool"
    )
    assert errors == []
    assert owner == "acme"
    assert repo == "tool"


def test_derive_release_urls() -> None:
    dist, sha = derive_release_urls("acme", "tool", "my-capsule", "2.1.0")
    assert dist.endswith("/my-capsule/v2.1.0/capsule.tar.gz")
    assert sha.endswith("/my-capsule/v2.1.0/capsule.tar.gz.sha256")
    assert "github.com/acme/tool/releases/download" in dist
