# Capsule Release Guide

Publish capsules from a **public** GitHub source repo using tags and GitHub Actions. agcli-registry CI then verifies your Release assets when you open a registry PR.

**Registry PR (separate repo):** only `version`, `summary`, and `repository` — see [contributing.md](contributing.md).  
**This guide:** source repo layout, `capsule.yaml`, and Release assets.

---

## Checklist

| Step | Requirement |
|------|-------------|
| 1 | Public repo with `<package-name>/capsule.yaml` (or `api.yml`) + optional `scripts/` |
| 2 | `name`, `group`, `version` in `capsule.yaml` aligned with registry path and tag |
| 3 | Actions: **Read and write** workflow permissions |
| 4 | Tag `<package-name>/v<version>` → workflow uploads `capsule.tar.gz` + `capsule.tar.gz.sha256` |
| 5 | PR to `capsules/<group>/<name>.yaml` in agcli-registry |

---

## Source repository layout

```text
<your-repo>/
├── hello-world/
│   ├── capsule.yaml      # packaged
│   └── scripts/          # packaged (optional)
├── .github/workflows/release.yml
└── README.md             # not packaged
```

- Directory name = `capsule.yaml` `name` = registry file `capsules/<group>/<name>.yaml`.
- Multiple packages: multiple top-level directories, **same `group`** in every `capsule.yaml` (one GitHub repo → one registry group).

---

## `capsule.yaml`

Required fields:

| Field | Must match |
|-------|------------|
| `name` | Directory name, Release tag prefix, registry filename |
| `group` | `capsules/<group>/` in agcli-registry |
| `version` | Tag version segment (`hello-world/v1.0.0` → `1.0.0`) |

```yaml
name: hello-world
group: myteam
version: 1.0.0
summary: "Example capsule"
entry: scripts/main.rhai
```

Registry CI downloads the tarball and checks these fields against the tag and registry path.

---

## Release workflow

`.github/workflows/release.yml` — copy as-is; package name comes from the tag:

```yaml
name: Release Capsule

on:
  push:
    tags:
      - '**/v*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v5

      - name: Extract package name and version
        id: info
        run: |
          TAG="${{ github.ref_name }}"
          PKG_NAME=$(echo "$TAG" | cut -d'/' -f1)
          VERSION=$(echo "$TAG" | sed 's|.*/v||')
          echo "pkg=${PKG_NAME}" >> "$GITHUB_OUTPUT"
          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"

      - name: Build capsule tarball
        run: tar czf capsule.tar.gz -C "${{ steps.info.outputs.pkg }}" capsule.yaml scripts/

      - name: Generate SHA256 signature
        run: sha256sum capsule.tar.gz | awk '{print $1}' > capsule.tar.gz.sha256

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            capsule.tar.gz
            capsule.tar.gz.sha256
          generate_release_notes: true
```

**Tag format (required):** `<package-name>/v<version>` — e.g. `hello-world/v1.0.0`. Bare `v1.0.0` tags are not supported.

**Publish:**

```bash
git commit -am "chore: bump hello-world to 1.0.0"
git push
git tag hello-world/v1.0.0
git push origin hello-world/v1.0.0
```

Confirm the Release lists both assets under **Releases**.

---

## Release assets

| File | Content |
|------|---------|
| `capsule.tar.gz` | Only `capsule.yaml` and `scripts/` (no README, tests, or outer directory name) |
| `capsule.tar.gz.sha256` | One line: 64 lowercase hex chars (no `SHA256 (...)` prefix) |

CI expects these URLs (derived from your registry YAML; you do not paste them in the YAML):

```text
.../releases/download/<name>/v<version>/capsule.tar.gz
.../releases/download/<name>/v<version>/capsule.tar.gz.sha256
```

After the Release exists:

```yaml
# capsules/myteam/hello-world.yaml
version: 1.0.0
summary: "Short description"
repository: "https://github.com/myteam/my-capsules"
```

CI verifies the download, hash, and tarball `capsule.yaml`, then writes `dist` and `integrity` into `index.json`.

---

## FAQ

**Wrong release?** Do not overwrite assets. Tag a new version (e.g. `v1.0.1`) and bump the registry YAML in a PR.

**Actions: `tar: not found`?** Tag prefix must match an existing package directory in the repo.

**Actions: permission errors?** Enable **Read and write** for workflows.

**One package in the repo?** Still use `<package-name>/v<version>` tags.

---

## See also

- [contributing.md](contributing.md) — Registry PR flow
- [onboard-new-group.md](onboard-new-group.md) — Register `group` first
- [registry-yaml-spec.md](registry-yaml-spec.md) — Full schema
