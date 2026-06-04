# Contributing: Submit a Package Declaration

> **First time here?** If your team does not have a registered group yet, complete [onboard-new-group.md](onboard-new-group.md) first, then return to this guide.

This guide is for contributors who already have a group in `groups.yaml` and `.github/CODEOWNERS`.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Step 1: Prepare the YAML file](#2-step-1-prepare-the-yaml-file)
3. [Step 2: Publish the GitHub Release](#3-step-2-publish-the-github-release)
4. [Step 3: Local validation (optional)](#4-step-3-local-validation-optional)
5. [Step 4: Open a pull request](#5-step-4-open-a-pull-request)
6. [Step 5: CI and review](#6-step-5-ci-and-review)
7. [Step 6: Merge and publish](#7-step-6-merge-and-publish)
8. [Update or remove a package](#8-update-or-remove-a-package)
9. [Common CI errors](#9-common-ci-errors)
10. [YAML field reference](#10-yaml-field-reference)

---

## 1. Prerequisites

| Requirement | Details |
|-------------|---------|
| **Group registered** | Your `group` exists in `groups.yaml` with a matching `capsules/<group>/` line in CODEOWNERS |
| **Release published** | `capsule.tar.gz` and `capsule.tar.gz.sha256` on GitHub Releases at the paths CI expects (see §3) |
| **Public repository** | `repository` must be a public `https://github.com/<owner>/<repo>` |
| **GitHub account** | For fork and PR |
| **Basic Git** | branch, commit, push (or use the GitHub web UI) |

You do **not** need to put `dist` or `integrity` in the YAML — CI derives them when merging the index.

---

## 2. Step 1: Prepare the YAML file

### 2.1 File location

```text
capsules/<your-group>/<your-package>.yaml
```

| Part | Source | Becomes in `index.json` |
|------|--------|-------------------------|
| `group` | Parent directory name | `group` |
| `name` | Filename without `.yaml` | `name` |

Rules:

- One YAML file = one package
- Extension must be `.yaml` (not `.yml`)
- `group` / `name` / `version` must match `capsule.yaml` inside the published tarball (CI verifies)
- Every package with the same `repository` must use the same `group`

**Good:**

```text
capsules/myteam/hello-world.yaml   → group=myteam, name=hello-world
capsules/acme/deployer.yaml        → group=acme,  name=deployer
```

**Bad:**

```text
capsules/MyTeam/hello.yaml         → group names must match naming rules (no arbitrary caps)
capsules/_private/tool.yaml        → group must not start with _
capsules/acme/my-package.yml       → use .yaml only
```

Full naming rules: [registry-yaml-spec.md](registry-yaml-spec.md).

### 2.2 What to put in the file

**Minimal (required fields):**

```yaml
version: 1.0.0
summary: "Short description for search"
repository: "https://github.com/myteam/hello-world"
```

**Recommended (explicit `name`):**

```yaml
name: hello-world
version: 1.0.0
summary: "Short description for search"
repository: "https://github.com/myteam/hello-world"
```

If you set `name`, it must equal the filename stem. Only these top-level fields are read by the merger: `name`, `version`, `summary`, `repository`. Other keys are ignored.

`publisher_tier` comes from `groups.yaml` (`tier` for your group). Do not try to override it in package YAML.

### 2.3 Naming constraints

| Field | Constraint |
|-------|------------|
| `group` (directory) | `^[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?$`, must not start with `_`, no `/` |
| `name` (filename) | `^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$` — lowercase letters, digits, hyphens |
| `repository` | `https://github.com/<owner>/<repo>` (optional trailing `/` or `.git`) |
| `version` | Non-empty string; must match the Release tag version segment (see §3) |
| `summary` | If set, at most **250** characters |

---

## 3. Step 2: Publish the GitHub Release

Before opening a market PR, publish assets from your capsule source repo.

**Tag format:**

```text
<name>/v<version>
```

Example: package `hello-world` at version `1.0.0` → tag `hello-world/v1.0.0`.

**Required Release assets** (names and paths are fixed):

| File | URL |
|------|-----|
| `capsule.tar.gz` | `https://github.com/<owner>/<repo>/releases/download/<name>/v<version>/capsule.tar.gz` |
| `capsule.tar.gz.sha256` | Same path with `.sha256` suffix; content is one line of 64 lowercase hex digits |

CI downloads both files, checks that the tarball hash matches the `.sha256` file, and reads `capsule.yaml` inside the archive.

Workflow and directory layout: [capsule-release-guide.md](capsule-release-guide.md).

---

## 4. Step 3: Local validation (optional)

```bash
pip3 install pyyaml
git clone https://github.com/agcli-dev/agcli-registry.git
cd agcli-registry
git checkout -b add-my-package

# Edit capsules/<group>/<name>.yaml ...

# Structure only (no network)
bash ./scripts/registry.sh merge --structure-only

# Full verify for your package (needs reachable Release assets)
bash ./scripts/registry.sh merge --force-verify myteam/hello-world

# Preview index (do not commit generated files)
python3 -m json.tool index.json
rm -f index.json index.json.asc index.meta.json
```

**Do not commit** `index.json`, `index.json.asc`, `index.meta.json`, or changes to `registry.lock.json`. PRs that modify `registry.lock.json` fail CI; only the publish workflow updates it on `main`.

Optional ownership check against `main`:

```bash
git fetch origin main
./scripts/check-capsule-ownership.sh origin/main
```

---

## 5. Step 4: Open a pull request

### GitHub web UI

1. Fork [agcli-dev/agcli-registry](https://github.com/agcli-dev/agcli-registry)
2. Add `capsules/<group>/<name>.yaml` via **Add file → Create new file**
3. Commit on a new branch and open a PR

Suggested commit message:

```text
feat: add myteam/hello-world v1.0.0
```

### Command line

```bash
git clone https://github.com/YOUR_USER/agcli-registry.git
cd agcli-registry
git checkout -b add-my-package
mkdir -p capsules/myteam
# create capsules/myteam/hello-world.yaml
git add capsules/myteam/hello-world.yaml
git commit -m "feat: add myteam/hello-world v1.0.0"
git push origin add-my-package
```

Open the PR from your fork on GitHub.

---

## 6. Step 5: CI and review

Two workflows run on pull requests:

| Workflow | What it checks |
|----------|----------------|
| **Check Capsule Ownership** | `groups.yaml` ↔ CODEOWNERS sync; touched groups are registered; multi-group PRs share a common `@owner` |
| **Validate Market Index** | YAML structure; group registered; **release verification** for changed capsules |

Release verification (for each changed `group/name`):

1. Derive `dist.url` and `.sha256` URL from `repository`, `name`, and `version`
2. Download `capsule.tar.gz.sha256` and `capsule.tar.gz`
3. Confirm tarball SHA-256 matches the sidecar file
4. Parse `capsule.yaml` in the tarball; `group`, `name`, `version` must match the declaration

Unchanged capsules reuse proofs from the **base branch** `registry.lock.json` on PRs (incremental verify).

After CI passes, a CODEOWNER for `capsules/<your-group>/` must approve. The default `*` rule may also require maintainer approval depending on branch protection.

---

## 7. Step 6: Merge and publish

After merge to `main`, **Publish Market Index** (when relevant paths change):

1. Merges all capsule YAML into `index.json`
2. Writes `registry.lock.json` (bot commit if changed)
3. Generates `index.meta.json` and signs `index.json` → `index.json.asc` (OpenPGP; see [`keys/README.md`](../keys/README.md))
4. Deploys to GitHub Pages (`https://registry.agcli.dev/`)
5. Syncs index files to OSS

Tarball mirroring to OSS runs via **sync-capsules-to-oss** after a successful publish (or on schedule). Objects are stored at `capsules/<group>/<name>/v<version>/capsule.tar.gz`; the workflow keeps at most three recent versions per package and removes mirrors for delisted packages (see [ci-workflows.md — sync-capsules-to-oss](ci-workflows.md#sync-capsules-to-ossyml)).

Your package is usually visible within a few minutes. Users can run:

```bash
agcli pkg search hello-world
agcli pkg install myteam/hello-world
```

---

## 8. Update or remove a package

### Bump version

1. Publish a new GitHub Release with the new tag and assets (§3)
2. Edit `capsules/<group>/<name>.yaml` — update `version` (and `summary` if needed)
3. PR: `chore: bump myteam/hello-world to v1.1.0`

### Remove a package

1. Delete `capsules/<group>/<name>.yaml`
2. PR: `chore: remove myteam/hello-world`

Removing the index entry does not uninstall the package for existing users; it only stops new installs from the registry.

---

## 9. Common CI errors

### `invalid YAML` / `must be a mapping`

Fix indentation (spaces, not tabs), quote strings with `:`, and use `|` for multi-line blocks with consistent indent.

### `name does not match filename`

Remove `name` from YAML or make it match `<name>.yaml`.

### `duplicate (group, name)`

Another file already declares this pair. Pick a different `name` (filename).

### `group not registered in groups.yaml`

Complete [onboard-new-group.md](onboard-new-group.md) before adding capsules under that group.

### Capsule ownership check failed

Typical causes:

- Group missing from CODEOWNERS or `groups.yaml`
- Owner lists differ between `groups.yaml` and CODEOWNERS
- PR touches multiple groups with no shared `@owner` — split the PR

### `repository is required` / `repository must be https://github.com/...`

Set `repository` to the repo root URL, not a Releases path.

### `failed to download sha256 file` / `failed to download tarball`

Release missing, draft, private repo, or wrong tag/asset names. Confirm both `capsule.tar.gz` and `capsule.tar.gz.sha256` exist at the derived URLs (§3).

### `sha256 file content invalid`

The `.sha256` asset must be exactly 64 lowercase hex characters (one line).

### `tarball sha256 mismatch`

The `.sha256` file does not match the tarball bytes — regenerate and re-upload both assets.

### `capsule.yaml identity mismatch`

Tarball `group` / `name` / `version` disagree with the registry path or YAML `version`.

### `repository ... is already associated with group '...'`

Another group already claims that GitHub repo. One repo → one market group.

### `pull requests must not modify registry.lock.json`

Revert lock file changes in your branch; CI updates it on `main` after publish.

### `structure validation failed`

See the numbered errors in the job log; fix YAML paths and fields per [registry-yaml-spec.md](registry-yaml-spec.md).

---

## 10. YAML field reference

> Full spec: [registry-yaml-spec.md](registry-yaml-spec.md)

| Field | Required | Notes |
|-------|:--------:|-------|
| `name` | No | If set, must match filename stem |
| `version` | Yes | Must match Release tag version part |
| `summary` | Recommended | Shown in search/listing |
| `repository` | Yes | Public GitHub repo URL |

**Written by CI into `index.json` (not in your YAML):**

| Field | Source |
|-------|--------|
| `dist.type` | Always `tarball` |
| `dist.url` | Derived from `repository` + `name` + `version` |
| `integrity.sha256` | Verified from `capsule.tar.gz.sha256` |
| `publisher_tier` | `groups.yaml` → `tier` for your group |

---

## Appendix: Request a new group

See [onboard-new-group.md](onboard-new-group.md). Summary:

1. Open **Issues → Apply for New Group Onboarding**
2. Maintainer merges `groups.yaml` + CODEOWNERS (separate PR for external contributors)
3. Then submit package YAML under `capsules/<group>/` only

Do not add `capsules/<group>/` before the group is registered. Do not combine group onboarding and package YAML in one PR unless you are a maintainer.
