#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKFILE="${REPO_ROOT}/Taskfile.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"

  if ! grep -Fq -- "${needle}" <<<"${haystack}"; then
    fail "expected to find '${needle}'"
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"

  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    fail "did not expect to find '${needle}'"
  fi
}

extract_apply_bootstrap_task() {
  awk '
    /^  apply-infisical-bootstrap-secrets:/ { in_task = 1 }
    in_task && /^  deploy-infisical-app:/ { exit }
    in_task { print }
  ' "${TASKFILE}"
}

test_bootstrap_secrets_use_services_data_host_with_rollback_reference() {
  local task_block
  task_block="$(extract_apply_bootstrap_task)"

  assert_contains "INFISICAL_BOOTSTRAP_HOST:" "${task_block}"
  assert_contains "yq eval '.terraform_service_lxcs.\"services-data\".ip' config.yaml" "${task_block}"
  assert_contains "INFISICAL_BOOTSTRAP_ROLLBACK_HOST:" "${task_block}"
  assert_contains "yq eval '.terraform_service_lxcs.\"infisical-data\".ip' config.yaml" "${task_block}"
  assert_contains 'REDIS_URL=redis://:${REDIS_PW_ENC}@{{.INFISICAL_BOOTSTRAP_HOST}}:6379' "${task_block}"
  assert_contains 'connectionString=postgresql://infisical:${DB_PW_ENC}@{{.INFISICAL_BOOTSTRAP_HOST}}:5432/infisical?sslmode=disable' "${task_block}"
  assert_not_contains "INFISICAL_DATA_IP:" "${task_block}"
  assert_not_contains "{{.INFISICAL_DATA_IP}}" "${task_block}"
}

main() {
  test_bootstrap_secrets_use_services_data_host_with_rollback_reference
}

main "$@"
