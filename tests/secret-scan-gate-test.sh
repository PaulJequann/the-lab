#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKFILE="${REPO_ROOT}/Taskfile.yml"
PRECOMMIT="${REPO_ROOT}/.pre-commit-config.yaml"
AGENTS="${REPO_ROOT}/AGENTS.md"

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

test_task_test_runs_staged_secret_scan() {
  assert_contains "  scan-secrets:" "${TASKFILE}"
  assert_contains "infisical scan git-changes --staged --redact --no-color --exit-code 1" "${TASKFILE}"
  assert_contains "      - task: scan-secrets" "${TASKFILE}"
}

test_precommit_scan_is_redacted() {
  assert_contains "id: infisical-scan" "${PRECOMMIT}"
  assert_contains "entry: infisical scan git-changes --staged --redact --no-color --exit-code 1" "${PRECOMMIT}"
  assert_not_contains "entry: infisical scan git-changes --staged --verbose" "${PRECOMMIT}"
}

test_agents_documents_secret_scan_gate() {
  assert_contains "infisical scan git-changes --staged --redact --no-color --exit-code 1" "${AGENTS}"
  assert_contains "Never paste scan matches or secret values into chat" "${AGENTS}"
}

main() {
  test_task_test_runs_staged_secret_scan
  test_precommit_scan_is_redacted
  test_agents_documents_secret_scan_gate
}

main "$@"
