# Registry index signing key

OpenPGP public key used to verify detached signatures on published `index.json`.

| Field | Value |
|-------|--------|
| UID | `agcli-registry <security@agcli.dev>` |
| Fingerprint | `23B9CC59441A191422534AE6898CEF30E287ABC3` |
| Key ID | `898CEF30E287ABC3` |

## Published artifacts

After each publish on `main`, CI writes:

- `index.json` — market index
- `index.json.asc` — detached armored signature over **raw** `index.json` bytes
- `index.meta.json` — SHA-256 of `index.json` plus `signing` metadata

## Verify locally

```bash
curl -fsSL "https://registry.agcli.dev/index.json" -o /tmp/index.json
curl -fsSL "https://registry.agcli.dev/index.json.asc" -o /tmp/index.json.asc
gpg --import keys/registry-signing.pub
gpg --verify /tmp/index.json.asc /tmp/index.json
```

Expect: `Good signature from "agcli-registry <security@agcli.dev>"`.

Private key material lives only in GitHub Actions secrets (`REGISTRY_GPG_*`); never commit it.
