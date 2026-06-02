#!/usr/bin/env bats
# Integration tests for scripts/check-capsule-ownership.sh (isolated temp repos).

setup() {
  REGISTRY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  OWNERSHIP_SCRIPT="${REGISTRY_ROOT}/scripts/check-capsule-ownership.sh"
  TEST_REPO="$(mktemp -d)"
  cd "${TEST_REPO}" || exit 1

  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"

  mkdir -p .github scripts capsules/official
  cp "${OWNERSHIP_SCRIPT}" scripts/check-capsule-ownership.sh
  chmod +x scripts/check-capsule-ownership.sh
}

teardown() {
  rm -rf "${TEST_REPO}"
}

write_groups() {
  cat > groups.yaml <<'EOF'
schema_version: "0.1.0"
groups:
  official:
    tier: verified
    owners:
      - "@team-a"
  acme:
    tier: community
    owners:
      - "@team-b"
EOF
}

write_codeowners() {
  cat > .github/CODEOWNERS <<'EOF'
capsules/official/  @team-a
capsules/acme/  @team-b
EOF
}

initial_commit() {
  write_groups
  write_codeowners
  git add -A
  git commit -q -m "initial"
}

run_ownership() {
  local base="${1:-HEAD~1}"
  run bash scripts/check-capsule-ownership.sh "${base}"
}

@test "passes when groups.yaml and CODEOWNERS match and no capsule yaml changes" {
  initial_commit
  run_ownership
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
}

@test "fails when group is in groups.yaml but missing from CODEOWNERS" {
  initial_commit
  cat >> groups.yaml <<'EOF'
  orphan:
    tier: community
    owners:
      - "@orphan"
EOF
  git add groups.yaml
  git commit -q -m "add orphan group"

  run_ownership
  [ "$status" -eq 1 ]
  [[ "$output" == *"not declared in .github/CODEOWNERS"* ]] || [[ "$stderr" == *"not declared"* ]]
}

@test "fails when CODEOWNERS declares a group not in groups.yaml" {
  initial_commit
  echo "capsules/extra/  @extra" >> .github/CODEOWNERS
  git add .github/CODEOWNERS
  git commit -q -m "add extra codeowners line"

  run_ownership
  [ "$status" -eq 1 ]
  [[ "$output" == *"not registered in groups.yaml"* ]] || [[ "$stderr" == *"not registered"* ]]
}

@test "fails when owners differ between groups.yaml and CODEOWNERS" {
  initial_commit
  sed -i.bak 's/@team-a/@team-x/' .github/CODEOWNERS
  rm -f .github/CODEOWNERS.bak
  git add .github/CODEOWNERS
  git commit -q -m "drift owners"

  run_ownership
  [ "$status" -eq 1 ]
  [[ "$output" == *"mismatched owners"* ]] || [[ "$stderr" == *"mismatched owners"* ]]
}

@test "passes when PR changes capsule in a declared group" {
  initial_commit
  echo 'version: 1.0.0
repository: https://github.com/acme/pkg
' > capsules/official/widget.yaml
  git add capsules/official/widget.yaml
  git commit -q -m "add capsule"

  run_ownership
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

@test "fails when PR touches capsule group without CODEOWNERS line" {
  initial_commit
  mkdir -p capsules/unknown
  echo 'version: 1.0.0
repository: https://github.com/acme/pkg
' > capsules/unknown/widget.yaml
  git add capsules/unknown/widget.yaml
  git commit -q -m "unknown group capsule"

  run_ownership
  [ "$status" -eq 1 ]
  [[ "$output" == *"not declared in .github/CODEOWNERS"* ]] || [[ "$stderr" == *"not declared"* ]]
}

@test "fails when PR spans multiple groups with no common owner" {
  initial_commit
  mkdir -p capsules/acme
  echo 'version: 1.0.0
repository: https://github.com/acme/a
' > capsules/official/a.yaml
  echo 'version: 1.0.0
repository: https://github.com/acme/b
' > capsules/acme/b.yaml
  git add capsules/
  git commit -q -m "multi group"

  run_ownership
  [ "$status" -eq 1 ]
  [[ "$output" == *"no common CODEOWNERS"* ]] || [[ "$stderr" == *"no common CODEOWNERS"* ]]
}
