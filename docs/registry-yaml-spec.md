# agcli-registry Registry YAML Specification

This document defines **file locations, formats, and fields** for the two declarative YAML types in agcli-registry:

| File | Purpose |
|------|---------|
| [`groups.yaml`](../groups.yaml) | Register publisher **groups** (trust tier and owners) |
| `capsules/<group>/<name>.yaml` | Declare a single **capsule** index entry (minimal metadata; distribution and integrity are derived by CI) |

Implementation reference: [`scripts/registry.sh`](../scripts/registry.sh) ([`registry_market.py`](../scripts/registry_market.py)), [`registry_release.py`](../scripts/registry_release.py), [`check-capsule-ownership.sh`](../scripts/check-capsule-ownership.sh). Verified release proofs are stored in [`registry.lock.json`](../registry.lock.json) at the repository root.

> **Difference from source-repo `capsule.yaml`**  
> `capsules/<group>/<name>.yaml` is a **market index declaration** pointing at a tarball on GitHub Releases. `capsule.yaml` (or `api.yml`) inside the capsule source repo is **package identity and runtime config** — see [capsule-release-guide.md](capsule-release-guide.md). They align via `group`, `name`, `version`, and the Release tag.

---

## 1. Overview

```text
groups.yaml                    capsules/<group>/<name>.yaml
     │                                      │
     │  groups.<group>.tier ────────────────┼──► capsules[].publisher_tier
     │  groups.<group>.owners ◄──sync──► CODEOWNERS capsules/<group>/
     │                                      │
     └─ group must be registered first ─────┘  otherwise package YAML fails CI
```

- Every `capsules/<group>/` directory name must exist as a key under `groups` in `groups.yaml`.
- Every registered group must have a `capsules/<group>/` line in [`.github/CODEOWNERS`](../.github/CODEOWNERS), and the **owner sets must match `groups.yaml` exactly** (see §2.4).
- A package is identified in the registry as **`group/name@version`**.

---

## 2. `groups.yaml`

### 2.1 Location

Repository root, fixed filename:

```text
groups.yaml
```

### 2.2 Root structure

| Field | Type | Required | Description |
|-------|------|:--------:|-------------|
| `schema_version` | string | Recommended | Documented version; use `"0.1.0"`. **Not validated by CI today** |
| `groups` | mapping | **Yes** | Group name → group configuration object |

The root must be a **mapping** containing a `groups` key whose value is a mapping (object).

Example:

```yaml
schema_version: "0.1.0"

groups:
  official:
    tier: verified
    owners:
      - "@agcli-dev/maintainers"
  mycompany:
    tier: community
    owners:
      - "@zhangsan"
```

### 2.3 `groups.<group>` entry

`<group>` is the mapping **key** and the `capsules/<group>/` directory name.

| Field | Type | Required | Description |
|-------|------|:--------:|-------------|
| `tier` | string | **Yes** | Publisher trust level (see §2.5) |
| `owners` | list of string | **Yes** | Non-empty list; each entry is a GitHub user or team, must start with `@` |

**`<group>` key constraints** (same as the `capsules/<group>/` directory name):

| Rule | Description |
|------|-------------|
| Regex | `^[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?$` |
| Forbidden | Must not start with `_`; must not contain `/` |
| Examples | `official`, `mycompany`, `acme.corp` |

**`owners` entry format:**

- User: `"@username"`
- Team in the **same org**: `"@org/team-slug"`
- CODEOWNERS can only reference teams within the same organization; external contributors must use individual `@username` (see CODEOWNERS header comments)

### 2.4 Consistency with `.github/CODEOWNERS`

`groups.yaml` is the **source of truth** for group registration; CODEOWNERS drives PR review and ownership CI. Both must stay **in sync**:

| Check | Description |
|-------|-------------|
| Forward | Every group key in `groups.yaml` has a CODEOWNERS line `capsules/<group>/` |
| Reverse | Every CODEOWNERS `capsules/<group>/` rule has a `groups.yaml` entry |
| Owners | For each shared group, the `owners` list (as a set) must **exactly match** the `@` tokens on the CODEOWNERS line |

CODEOWNERS line format (must match the CI parser regex):

```text
capsules/<group>/  @owner1 @owner2
```

- Path is `capsules/<group>/` (trailing slash).
- At least one `@` owner; multiple owners are space-separated.
- Place group rules **near the end** of the file (last match wins).

When onboarding a new group, maintainers update **both** `groups.yaml` and CODEOWNERS. External contributors usually open two separate PRs — see [onboard-new-group.md](onboard-new-group.md).

### 2.5 `tier` (trust level)

`tier` is the **publisher group** trust level. Only two values are supported:

| Value | Meaning |
|-------|---------|
| `community` | Community package (default trust) |
| `verified` | Verified publisher (maintainers reviewed identity / ownership) |

- CI **requires** each group's `tier` to be one of these values.
- If `tier` is omitted, merge logic treats the group as `community`; **explicit `tier` in `groups.yaml` is recommended**.
- `index.json` uses `publisher_tier`, copied from the group's `tier` (see §3.4).

### 2.6 CI checks (`groups.yaml`)

Run by `registry.sh merge` before package validation:

- Valid YAML; root contains a `groups` mapping
- Each `groups.<name>` is an object with a valid `tier` and non-empty `owners` list
- Each owner string starts with `@`

Additional checks from `check-capsule-ownership.sh` (on PRs):

- `groups.yaml` ↔ CODEOWNERS bidirectional registration and matching owner sets
- PRs that touch `capsules/<group>/*.yaml`: each affected group must be in CODEOWNERS; multi-group PRs must share at least one common `@owner`, or be split

### 2.7 Examples

#### 2.7.1 New group in `groups.yaml`

```yaml
schema_version: "0.1.0"

groups:
  mycompany:
    tier: community
    owners:
      - "@zhangsan"
```

Matching CODEOWNERS line:

```text
capsules/mycompany/  @zhangsan
```

#### 2.7.2 Package declaration (minimal)

```yaml
version: 1.0.0
summary: "Short description"
repository: "https://github.com/myteam/hello-world"
```

#### 2.7.3 Package declaration (recommended)

```yaml
name: hello-world
version: 1.0.0
summary: "Example capsule package"
repository: "https://github.com/myteam/hello-world"
```

#### 2.7.4 Reference entry

See [`capsules/official/hello-world.yaml`](../capsules/dev.agcli/hello-world.yaml).

---

## 3. `capsules/` package declaration YAML

### 3.1 Path

```text
capsules/<group>/<name>.yaml
```

| Part | Source | Written to `index.json` |
|------|--------|-------------------------|
| `group` | Parent directory `<group>/` | `capsules[].group` |
| `name` | Filename `<name>.yaml` (no extension) | `capsules[].name` |

Rules:

- **One YAML file = one package**; do not declare multiple packages in one file.
- Extension must be **`.yaml`** (not `.yml`).
- Only `capsules/<group>/*.yaml` is scanned; dotfiles are ignored.
- `<group>` must be registered in [`groups.yaml`](../groups.yaml), or CI fails.
- `(group, name)` must be unique across the repository.

### 3.2 Naming constraints

**`name` (filename stem)**

| Rule | Description |
|------|-------------|
| Regex | `^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$` |
| Charset | Lowercase letters, digits, and hyphen `-` only |
| Examples | `hello-world`, `cli-tools` |

> `group` directory constraints: see §2.3 (same as `groups.yaml` keys).

### 3.3 YAML format

- Root must be a **mapping** (object); empty files are invalid.
- Encoding: **UTF-8** recommended.
- Use YAML scalars for string fields.
- **Only fields listed below** are read; other top-level keys are ignored and do not appear in `index.json`.

### 3.4 Fields

#### Declared in package YAML

| Field | Type | Required | Description |
|-------|------|:--------:|-------------|
| `name` | string | No | If present, must match filename `<name>` |
| `version` | string | **Yes** | [Semver](https://semver.org/) (e.g. `1.0.0`); must match the Release tag version segment (see §4). On update, must be **greater than** the version in `registry.lock.json` for the same `group/name`, or unchanged with the same release coordinates |
| `summary` | string | Recommended | One-line summary for search and listings; max **250** characters |
| `repository` | string | **Yes** | GitHub source repository URL (see §4.1) |

#### Derived by CI into `index.json`

Package YAML must **not** declare `dist`, `integrity`, or `publisher_tier`. The merge step derives them:

| `index.json` field | Source |
|--------------------|--------|
| `dist.type` | Always `tarball` |
| `dist.url` | Derived from `repository` + `name` + `version` (see §4.2) |
| `integrity.sha256` | Verified from Release assets (see §4.3) |
| `publisher_tier` | `tier` for the group in `groups.yaml` |

### 3.5 Example

```yaml
name: hello-world
version: 1.0.0
summary: "Short description"
repository: "https://github.com/myteam/hello-world"
```

---

## 4. `repository` and derived fields (L1 / L2)

### 4.1 `repository`

Must be the GitHub repository root URL:

```text
https://github.com/<owner>/<repo>
```

Optional suffix: `/.git` or `/`. Owner and repo names are compared case-insensitively when deriving URLs.

### 4.2 `dist.url` derivation

`dist.url` is always:

```text
https://github.com/<owner>/<repo>/releases/download/<name>/v<version>/capsule.tar.gz
```

`<owner>/<repo>` come from `repository`; `<name>` and `<version>` from the file path and YAML.

Implementation: [`derive_release_urls()`](../scripts/registry_release.py) in `registry_release.py`.

### 4.3 `integrity.sha256` derivation and verification

The sidecar URL is always:

```text
https://github.com/<owner>/<repo>/releases/download/<name>/v<version>/capsule.tar.gz.sha256
```

For each package that must be verified, CI:

1. Downloads `capsule.tar.gz` and `capsule.tar.gz.sha256`
2. Validates `.sha256` content: a single line of 64 lowercase hex digits (trailing newline allowed)
3. Computes SHA-256 of the tarball and compares it to the sidecar file
4. Inspects the tarball without extracting to disk: rejects path traversal, symlinks, and entries outside root `capsule.yaml` + `scripts/`; enforces size limits; reads root `capsule.yaml` and checks `group`, `name`, and `version` (**L2**)
5. Writes `integrity.sha256` into the merged `index.json` on success

### 4.4 Other URL rules

- Must use **`https`**
- Must be an **absolute URL** with a host

---

## 5. Identity alignment

These four layers must agree (L2 tarball check follows CI behavior in `registry_market.py`):

```text
groups.yaml key              →  capsules/<group>/ directory name
capsules/<group>/<name>.yaml →  group, name (path) + version field
repository + derived URLs    →  same GitHub repo and Release layout
source-repo capsule.yaml     →  name, group, version
```

All packages that share the same `repository` must belong to the **same** `group` — see [capsule-release-guide.md](capsule-release-guide.md).

---

## 6. Merged `index.json`

### 6.1 Top level

`index.json` is a UTF-8 JSON object:

| Field | Type | Required | Description |
|-------|------|:--------:|-------------|
| `schema_version` | string | **Yes** | Index format version; currently `0.1.0` |
| `capsules` | array | **Yes** | Package entries; one per `capsules/<group>/<name>.yaml` |

Constraints:

- Top level must include `schema_version` and `capsules`.
- Each entry is uniquely identified by `group/name@version`.
- `capsules` is sorted by `group`, `name`, `version` for stable output.

### 6.2 `capsules[]` entry fields

After verification, each package YAML becomes one array element:

| Field | Source |
|-------|--------|
| `group` | Directory name |
| `name` | Filename stem |
| `version` | Package YAML |
| `repository` | Package YAML (trimmed) |
| `dist` | CI-derived (`type=tarball`, `url` per §4.2) |
| `integrity` | CI verification (§4.3) |
| `publisher_tier` | `groups.yaml` → `tier` |
| `summary` | Package YAML when non-empty |

`schema_version` at the top of `index.json` is set by the merge script, not in package YAML.

### 6.3 Example `index.json`

```json
{
  "schema_version": "0.1.0",
  "capsules": [
    {
      "group": "official",
      "name": "hello-world",
      "version": "1.0.0",
      "repository": "https://github.com/agcli/hello-world",
      "dist": {
        "type": "tarball",
        "url": "https://github.com/agcli/hello-world/releases/download/hello-world/v1.0.0/capsule.tar.gz"
      },
      "integrity": {
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      "publisher_tier": "verified",
      "summary": "Official agcli sample capsule"
    }
  ]
}
```

---

## 7. `registry.lock.json` (release proofs)

`registry.lock.json` at the repository root stores per-`group/name` **verified release proofs** (`version`, `repository`, `dist`, `integrity`). `index.json` is generated by CI and is not committed; the lock file is committed for incremental verification.

| Scenario | Behavior |
|----------|----------|
| `publish-index` (`main`) | Re-download and verify capsules changed in the push; reuse lock for others |
| `validate-index` (PR) | Trust only the **base branch** lock (`--trust-base-lock-only`); force verify changed capsules |
| `audit-index` (scheduled) | `--verify-all` — ignore lock cache, verify every capsule |

**Do not edit** `registry.lock.json` by hand. `publish-index` commits updates after a successful publish (via a dedicated GitHub App; see [ci-workflows.md — Registry lock bot](ci-workflows.md#registry-lock-bot-github-app)). PRs that modify it fail [`check-registry-lock.sh`](../scripts/check-registry-lock.sh).

### 7.1 Lock entry example

```json
{
  "schema_version": "0.1.0",
  "entries": {
    "official/hello-world": {
      "version": "1.0.0",
      "repository": "https://github.com/agcli/hello-world",
      "dist": {
        "type": "tarball",
        "url": "https://github.com/agcli/hello-world/releases/download/hello-world/v1.0.0/capsule.tar.gz"
      },
      "integrity": {
        "sha256": "..."
      }
    }
  }
}
```

When `version`, `repository`, or the derived `dist.url` changes, the cache entry is invalidated and CI re-downloads the release and updates the lock.

---

## 8. CI summary

| Script | Role |
|--------|------|
| `registry.sh merge` | Structure validation; incremental or full release verification; writes `index.json` |
| `registry.sh merge --structure-only` | `groups.yaml` and package YAML structure only (no network) |
| `check-capsule-ownership.sh` | `groups.yaml` ↔ CODEOWNERS; PR group ownership rules |
| `check-registry-lock.sh` | PRs must not modify `registry.lock.json` |

Local commands:

```bash
pip3 install pyyaml
bash ./scripts/registry.sh merge --structure-only
git fetch origin main
bash ./scripts/check-capsule-ownership.sh origin/main
bash ./scripts/registry.sh merge --trust-base-lock-only \
  --base-lock-file <(git show origin/main:registry.lock.json) \
  --force-verify mygroup/mypkg
```

---

## 9. Related documentation

| Document | Topics |
|----------|--------|
| [contributing.md](contributing.md) | Submission flow, PRs, CI troubleshooting |
| [onboard-new-group.md](onboard-new-group.md) | New group onboarding and CODEOWNERS |
| [capsule-release-guide.md](capsule-release-guide.md) | Source-repo `capsule.yaml`, Releases, tarballs |
| [ci-workflows.md](ci-workflows.md) | GitHub Actions workflows |
