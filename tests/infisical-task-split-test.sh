#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKFILE="${REPO_ROOT}/Taskfile.yml"
ANSIBLE_TASKS="${REPO_ROOT}/.taskfiles/AnsibleTasks.yml"

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

test_infisical_tasks_are_split() {
  assert_contains "  deploy-infisical-data:" "${TASKFILE}"
  assert_contains "  update-infisical-data:" "${TASKFILE}"
  assert_contains "  redeploy-infisical-secrets:" "${TASKFILE}"

  assert_contains "task ansible:bootstrap-infisical-data" "${TASKFILE}"
  assert_contains "task ansible:update-infisical-data" "${TASKFILE}"
  assert_contains "  apply-infisical-bootstrap-secrets:" "${TASKFILE}"
  assert_contains "internal: true" "${TASKFILE}"

  assert_contains 'run_system_updates=false' "${ANSIBLE_TASKS}"
  assert_contains 'run_system_updates=true' "${ANSIBLE_TASKS}"

  assert_not_contains "  create-infisical-k8s-secrets:" "${TASKFILE}"
  assert_not_contains "task apply-infisical-bootstrap-secrets" "${TASKFILE}"
}

main() {
  test_infisical_tasks_are_split
}

main "$@"
