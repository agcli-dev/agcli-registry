"""Shared pytest fixtures for registry script unit tests."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


@pytest.fixture
def repo_root(tmp_path: Path) -> Path:
    """Minimal registry tree: groups.yaml + one capsule under official/."""
    groups = tmp_path / "groups.yaml"
    groups.write_text(
        """schema_version: "0.1.0"
groups:
  official:
    tier: verified
    owners:
      - "@agcli-dev/maintainers"
""",
        encoding="utf-8",
    )
    capsule_dir = tmp_path / "capsules" / "official"
    capsule_dir.mkdir(parents=True)
    (capsule_dir / "hello-world.yaml").write_text(
        """name: hello-world
version: 1.0.0
repository: https://github.com/agcli/hello-world
""",
        encoding="utf-8",
    )
    return tmp_path
