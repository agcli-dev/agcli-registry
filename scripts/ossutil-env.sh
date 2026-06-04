#!/usr/bin/env bash
#
# ossutil-env.sh — Validate OSS credentials and export ossutil 2.x env (region, endpoint).
#
# Usage (from another script):
#   source "$(dirname "${BASH_SOURCE[0]}")/ossutil-env.sh"
#   ossutil_ensure_env
#
ossutil_ensure_env() {
  local missing=()
  for var in OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_ENDPOINT OSS_BUCKET; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required environment variables: ${missing[*]}" >&2
    return 1
  fi

  local ep="${OSS_ENDPOINT}"
  ep="${ep#https://}"
  ep="${ep#http://}"
  export OSS_ENDPOINT="${ep}"

  if [[ -z "${OSS_REGION:-}" ]]; then
    if [[ "${ep}" =~ ^oss-([a-z0-9-]+)-internal\.aliyuncs\.com$ ]]; then
      export OSS_REGION="${BASH_REMATCH[1]}"
    elif [[ "${ep}" =~ ^oss-([a-z0-9-]+)\.aliyuncs\.com$ ]]; then
      export OSS_REGION="${BASH_REMATCH[1]}"
    else
      echo "Error: OSS_REGION is not set and could not be derived from OSS_ENDPOINT." >&2
      echo "  Set OSS_REGION (e.g. cn-hangzhou) or use endpoint oss-<region>.aliyuncs.com" >&2
      return 1
    fi
  fi

  export OSS_REGION
  return 0
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
