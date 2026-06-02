# Onboard a New Group and Publish Your First Package

This guide covers **first-time publishing** on agcli-registry: register `capsules/<group>/`, then submit your first capsule declaration.

> Already onboarded? For new packages or version bumps, use [contributing.md](contributing.md).

---

## Why two phases?

| Phase | Goal |
|-------|------|
| **A. Onboard group** | Add the group to `groups.yaml` and `.github/CODEOWNERS` so CI and review know who owns `capsules/<group>/` |
| **B. Publish capsule** | Add `capsules/<group>/<name>.yaml` after Phase A is merged |

If you add package YAML under an unregistered group, **validate-index** fails with `group not registered in groups.yaml`, and **check-capsule-ownership** fails if CODEOWNERS has no line for that group.

Schema reference: [registry-yaml-spec.md](registry-yaml-spec.md).

---

## Process overview

```text
Contributor                     Maintainer                     After merge
  │                              │                              │
  ├─① Plan group name + owners   │                            │
  ├─② Open onboarding Issue ────►├─③ PR: groups.yaml + CODEOWNERS
  │                              ├─ merge ─────────────────────► group ready
  ├─④ Publish GitHub Release     │                            │
  ├─⑤ Fork + capsule YAML PR ───►├─ group owner review + CI   │
  │                              ├─ merge ─────────────────────► index live
  └─⑥ Clients search/install    │                             │
```

---

## Phase A: Apply for a new group

### A.1 What to prepare

| Item | Description |
|------|-------------|
| **Group name** | Directory name under `capsules/`. Pattern: `[a-zA-Z0-9][a-zA-Z0-9._-]*`, must not start with `_`, no `/` |
| **GitHub owners** | `@username` or, for teams in the **same org**, `@org/team-slug` |
| **Tier** | `community` (default) or `verified` (extra maintainer review) |
| **Capsule repo** | Public GitHub repository URL you will list in package YAML |
| **First package name (optional)** | Lowercase + digits + `-`, e.g. `hello-cli` |

You do not need a market YAML file yet. You **do** need a clear plan for who approves PRs under `capsules/<group>/`.

### A.2 Submit an onboarding Issue

In this repository: **Issues → New issue → Apply for New Group Onboarding**.

The form collects group name, GitHub identity, requested tier, repository link, and optional first package name. Read the checklist in the template before submitting.

Maintainers will open a dedicated onboarding PR (they do not publish your tarball for you).

### A.3 Maintainer onboarding PR

Example branch: `chore: onboard group mycompany`.

1. **Add to `groups.yaml`:**

   ```yaml
   schema_version: "0.1.0"

   groups:
     mycompany:
       tier: community
       owners:
         - "@zhangsan"
   ```

   Use `tier: verified` only after identity review. The field in YAML is `tier`; it becomes `publisher_tier` in `index.json`.

2. **Append to `.github/CODEOWNERS`** (later rules override earlier ones):

   ```text
   capsules/mycompany/  @zhangsan
   ```

   Multiple owners:

   ```text
   capsules/mycompany/  @myorg/publishers @zhangsan
   ```

   Owner sets must match `groups.yaml` exactly (same `@` tokens, as a set).

3. **Optional:** add `capsules/mycompany/.gitkeep`, or let the first package PR create the directory.

4. Review and merge to `main`.

**Review checklist:**

- Group name is not confusing or misleading (e.g. impersonating `official`)
- Applicant identity is credible
- `verified` tier is justified if requested
- `groups.yaml` owners and CODEOWNERS owners are identical

---

## Phase B: Publish the first package

After Phase A is merged.

### B.1 Publish the Release (source repo)

Follow [capsule-release-guide.md](capsule-release-guide.md):

- Tag: `<name>/v<version>` (e.g. `hello-cli/v1.0.0`)
- Assets: `capsule.tar.gz` and `capsule.tar.gz.sha256` at the paths CI derives

### B.2 Create the market YAML

Path:

```text
capsules/<group>/<name>.yaml
```

Example `capsules/mycompany/hello-cli.yaml`:

```yaml
name: hello-cli
version: 1.0.0
summary: "Short description for search"
repository: "https://github.com/mycompany/hello-cli"
```

Do **not** add `dist` or `integrity` — CI derives URLs and SHA-256 from the Release. See [contributing.md §2–§3](contributing.md#2-step-1-prepare-the-yaml-file).

### B.3 Local self-check (optional)

```bash
git fetch origin main
./scripts/check-capsule-ownership.sh origin/main
bash ./scripts/registry.sh merge --structure-only
bash ./scripts/registry.sh merge --force-verify mycompany/hello-cli
rm -f index.json index.meta.json
```

Expect ownership output like: `capsule ownership check passed (group=mycompany, owners=...)`.

### B.4 Open the package PR

```bash
git checkout -b add-mycompany-hello-cli
git add capsules/mycompany/hello-cli.yaml
git commit -m "feat: add mycompany/hello-cli v1.0.0"
git push origin add-mycompany-hello-cli
```

Suggested title: `feat: add mycompany/hello-cli v1.0.0`

### B.5 Checks before merge

| Check | Description |
|-------|-------------|
| **Check Capsule Ownership** | Group declared; owners aligned; no forbidden multi-group mix |
| **Validate Market Index** | Structure + full download verify for `mycompany/hello-cli` |
| **Code owner review** | Approver listed on `capsules/mycompany/` in CODEOWNERS |
| **Maintainers** | May be required by branch protection on top of group owners |

CI failures: [contributing.md §9](contributing.md#9-common-ci-errors).

### B.6 After merge

- **publish-index** updates `index.json`, `index.meta.json`, and `registry.lock.json` (if needed), deploys to `https://registry.agcli.dev/`, syncs OSS
- **sync-capsules-to-oss** mirrors tarball assets after a successful publish

Package `mycompany/hello-cli` becomes installable from the registry.

---

## After onboarding

Add packages, bump versions, or remove entries using [contributing.md §8](contributing.md#8-update-or-remove-a-package). No second onboarding Issue is required.

Avoid one PR that changes unrelated groups unless those groups share a CODEOWNERS owner.

---

## FAQ

### `group not registered in groups.yaml` or ownership check failed

Phase A is not done yet. Wait for the onboarding PR to merge, or ask a maintainer to open it.

### Can onboarding and the first package be one PR?

**Maintainers only** may combine `groups.yaml`, CODEOWNERS, and `capsules/<group>/*.yaml` in a single PR. External contributors should use two PRs.

### Owners outside your GitHub org?

List individual usernames in CODEOWNERS, e.g. `capsules/acme/  @zhangsan`. You cannot reference another org's teams.

### `community` vs `verified` tier?

Declared as `tier` in `groups.yaml`. It maps to `publisher_tier` in `index.json`. Default to `community` unless you have been approved for `verified`.

### Do I put `dist.url` or `integrity` in package YAML?

No. The merger derives release URLs and verifies integrity from GitHub Release assets. See [registry-yaml-spec.md](registry-yaml-spec.md) §4.

---

## Related documentation

- [contributing.md](contributing.md) — Routine package PRs
- [registry-yaml-spec.md](registry-yaml-spec.md) — Full schema
- [ci-workflows.md](ci-workflows.md) — Automation behavior
- [capsule-release-guide.md](capsule-release-guide.md) — Source repo releases

---

## Appendix: Issue template (plain text)

If the GitHub form is unavailable, open an Issue with:

```markdown
## Apply for New Group Onboarding

- **Group name**: (e.g. `mycompany`)
- **GitHub identity**: (e.g. `@zhangsan` or `@myorg/publishers`)
- **Requested tier**: community / verified
- **Project / repository link**:
- **Planned first package name** (optional):
- **Additional notes**:

I have read docs/onboard-new-group.md and will submit package YAML only after the group registration PR is merged.
```
