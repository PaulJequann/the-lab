#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/config.yaml"
MONITORING_PROJECT="${REPO_ROOT}/kubernetes/bootstrap/projects/monitoring.yaml"
SERVICES_GROUP_VARS="${REPO_ROOT}/ansible/group_vars/services.yaml"
SERVICES_PLAYBOOK="${REPO_ROOT}/ansible/playbooks/services-data.yml"
MACHINE_IDENTITIES="${REPO_ROOT}/scripts/create-machine-identities.sh"

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

test_services_data_resources_are_sized_for_observability() {
  local block
  block="$(yq eval '.terraform_service_lxcs."services-data"' "${CONFIG}")"

  grep -Fq "disk_size: 120G" <<<"${block}" || fail "services-data disk_size must be 120G"
  grep -Fq "cores: 4" <<<"${block}" || fail "services-data cores must be 4"
  grep -Fq "memory_mb: 6144" <<<"${block}" || fail "services-data memory_mb must be 6144"
}

test_grafana_postgres_contract_is_rendered() {
  assert_contains 'grafana_postgres_db: "grafana"' "${CONFIG}"
  assert_contains 'grafana_postgres_user: "grafana"' "${CONFIG}"
  assert_contains "grafana_postgres_port: 5432" "${CONFIG}"
  assert_contains "services_data_enable_grafana_db: true" "${CONFIG}"

  assert_contains "grafana_postgres_db: grafana" "${SERVICES_GROUP_VARS}"
  assert_contains "grafana_postgres_user: grafana" "${SERVICES_GROUP_VARS}"
  assert_contains "grafana_postgres_port: 5432" "${SERVICES_GROUP_VARS}"
  assert_contains "services_data_enable_grafana_db: True" "${SERVICES_GROUP_VARS}"

  assert_contains "Fetch Grafana DB credentials from Infisical" "${SERVICES_PLAYBOOK}"
  assert_contains "path='/kubernetes/grafana'" "${SERVICES_PLAYBOOK}"
  assert_contains "'name': grafana_postgres_db" "${SERVICES_PLAYBOOK}"
  assert_contains "'user': grafana_postgres_user" "${SERVICES_PLAYBOOK}"
  assert_contains "'password': _grafana_infisical.POSTGRES_PASSWORD" "${SERVICES_PLAYBOOK}"
  assert_contains '"/kubernetes/grafana/**"' "${MACHINE_IDENTITIES}"
}

test_plane_external_postgres_alignment_remains_enabled() {
  assert_contains 'plane_postgres_db: "plane"' "${CONFIG}"
  assert_contains 'plane_postgres_user: "plane"' "${CONFIG}"
  assert_contains "plane_postgres_host: \"10.0.10.86\"" "${CONFIG}"
  assert_contains "plane_postgres_port: 5432" "${CONFIG}"
  assert_contains "enable_plane_db: true" "${CONFIG}"
}

test_monitoring_project_allows_phase_repositories_and_namespaces() {
  assert_contains "https://victoriametrics.github.io/helm-charts/" "${MONITORING_PROJECT}"
  assert_contains "https://grafana.github.io/helm-charts" "${MONITORING_PROJECT}"
  assert_contains "https://grafana-community.github.io/helm-charts" "${MONITORING_PROJECT}"
  assert_contains "https://open-telemetry.github.io/opentelemetry-helm-charts" "${MONITORING_PROJECT}"
  assert_contains "https://unpoller.github.io/helm-chart" "${MONITORING_PROJECT}"

  for namespace in victoria-metrics-stack victoria-logs alloy otel-collector unpoller karma tempo beyla; do
    assert_contains "namespace: ${namespace}" "${MONITORING_PROJECT}"
  done
}

main() {
  test_services_data_resources_are_sized_for_observability
  test_grafana_postgres_contract_is_rendered
  test_plane_external_postgres_alignment_remains_enabled
  test_monitoring_project_allows_phase_repositories_and_namespaces
}

main "$@"
