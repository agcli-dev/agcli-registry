# Security Policy

## Supported Versions

As a package index repository, the "version" that matters is the published
`index.json` / `index.meta.json` on the registry endpoint. We support the
latest published index only.

## Reporting a Vulnerability

We take security issues seriously, especially those that could affect the
integrity of the package index (e.g., package substitution, SHA-256 collision,
or unauthorized modifications to `index.json`).

**Please do not report security vulnerabilities through public GitHub Issues.**

Instead, please report them through one of the following channels:

- **GitHub Security Advisories** (preferred):
  [Report a vulnerability](../../security/advisories/new)
- **Email**: Send a detailed report to the maintainer team via the contact
  information in [CODEOWNERS](.github/CODEOWNERS)

### What to Include

To help us respond quickly, please provide:

1. **Description** of the vulnerability and its potential impact
2. **Steps to reproduce** or proof of concept
3. **Affected components** (e.g., CI pipeline, index generation, package
   declaration validation, registry endpoint)
4. **Suggested fix** (if you have one)

### Response Timeline

| Stage | Expected Time |
|-------|---------------|
| Acknowledgment | Within 48 hours |
| Initial assessment | Within 5 business days |
| Status update | Every 7 days until resolved |
| Patch / Advisory | Depends on severity; critical issues prioritized |

### Disclosure Policy

- We follow **coordinated (responsible) disclosure**: we ask that you do not
  publicly disclose the issue until a fix has been deployed and an advisory has
  been published.
- Once the fix is deployed, we will publish a GitHub Security Advisory and
  credit the reporter (unless they prefer to remain anonymous).

## Security Model

This repository enforces several layers of protection:

| Layer | Mechanism |
|-------|-----------|
| Package integrity | Every package declaration requires `integrity.sha256`; CI validates the hash against the downloaded tarball |
| Origin verification | `dist.url` must be a GitHub Release asset from the declared `repository` |
| Ownership control | [CODEOWNERS](.github/CODEOWNERS) enforces per-group review; CI checks that the PR author is authorized for the changed group |
| Index integrity | `index.json.asc` is an OpenPGP detached signature from the registry key in [`keys/registry-signing.pub`](keys/registry-signing.pub); `index.meta.json` contains a SHA-256 hash of `index.json` for a secondary check |
| CI pipeline | All changes to `capsules/` must pass `validate-index.yml` and `check-capsule-ownership.yml` before merge |

If you believe any of these layers can be bypassed, please report it
immediately using the channels above.
