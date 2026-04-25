#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKFILE="${REPO_ROOT}/Taskfile.yml"
CONFIG="${REPO_ROOT}/config.yaml"
GROUP_VARS="${REPO_ROOT}/ansible/group_vars/services.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"

  if ! grep -Fq -- "${needle}" "${file}"; then
    fail "expected to find '${needle}' in ${file}"
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"

  if grep -Fq -- "${needle}" "${file}"; then
    fail "did not expect to find '${needle}' in ${file}"
  fi
}

test_phase3_enables_infisical_database_without_production_cutover() {
  assert_contains "enable_infisical_db: true" "${CONFIG}"
  assert_contains "services_data_enable_infisical_db: True" "${GROUP_VARS}"

  assert_contains "INFISICAL_DATA_IP: 10.0.10.85" "${TASKFILE}"
  assert_not_contains "INFISICAL_DATA_IP: 10.0.10.86" "${TASKFILE}"
}

test_rehearsal_task_uses_services_data_postgres_and_redis() {
  assert_contains "  phase3-infisical-rehearsal:" "${TASKFILE}"
  assert_contains "INFISICAL_REHEARSAL_NS: infisical-rehearsal" "${TASKFILE}"
  assert_contains "SERVICES_DATA_IP: 10.0.10.86" "${TASKFILE}"
  assert_contains "helm upgrade --install infisical-rehearsal" "${TASKFILE}"
  assert_contains 'postgresql://infisical:${DB_PW_ENC}@{{.SERVICES_DATA_IP}}:5432/infisical?sslmode=disable' "${TASKFILE}"
  assert_contains 'redis://:${REDIS_PW_ENC}@{{.SERVICES_DATA_IP}}:6379' "${TASKFILE}"
  assert_contains "redis.enabled=false" "${TASKFILE}"
  assert_contains "tokenReviewer.enabled=false" "${TASKFILE}"
  assert_contains "helm uninstall infisical-rehearsal" "${TASKFILE}"
  assert_contains "dropdb --if-exists infisical" "${TASKFILE}"
}

main() {
  test_phase3_enables_infisical_database_without_production_cutover
  test_rehearsal_task_uses_services_data_postgres_and_redis
}

main "$@"
