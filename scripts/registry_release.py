"""GitHub Release URL derivation and repository validation for the market registry."""

from __future__ import annotations

import re

GITHUB_REPO_RE = re.compile(
    r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?/?$"
)


def parse_github_repository(url: str) -> tuple[str, str] | None:
    if not isinstance(url, str) or not url.strip():
        return None
    match = GITHUB_REPO_RE.match(url.strip())
    if not match:
        return None
    return match.group("owner"), match.group("repo")


def validate_repository(rel_path: str, repository) -> tuple[list[str], str | None, str | None]:
    """Validate repository and return (errors, owner, repo)."""
    errors: list[str] = []
    if not isinstance(repository, str) or not repository.strip():
        errors.append(
            f"{rel_path}: repository is required (https://github.com/<owner>/<repo>)"
        )
        return errors, None, None

    repo_parts = parse_github_repository(repository)
    if not repo_parts:
        errors.append(
            f"{rel_path}: repository must be https://github.com/<owner>/<repo> "
            f"(got {repository!r})"
        )
        return errors, None, None

    owner, repo = repo_parts
    return errors, owner, repo


def derive_release_urls(owner: str, repo: str, name: str, version: str) -> tuple[str, str]:
    """Return (dist_url, sha_url) for the enforced release convention."""
    dist_url = (
        f"https://github.com/{owner}/{repo}/releases/download/"
        f"{name}/v{version}/capsule.tar.gz"
    )
    sha_url = (
        f"https://github.com/{owner}/{repo}/releases/download/"
        f"{name}/v{version}/capsule.tar.gz.sha256"
    )
    return dist_url, sha_url
