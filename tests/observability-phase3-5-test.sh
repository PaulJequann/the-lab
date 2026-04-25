#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DEFAULTS="${REPO_ROOT}/ansible/roles/services_data/defaults/main.yaml"
SERVICES_TASKS="${REPO_ROOT}/ansible/roles/services_data/tasks/main.yaml"
SERVICES_HANDLERS="${REPO_ROOT}/ansible/roles/services_data/handlers/main.yaml"
SERVICES_VARS="${REPO_ROOT}/ansible/group_vars/services.yaml"
MACHINE_IDENTITIES="${REPO_ROOT}/scripts/create-machine-identities.sh"
PLANE_VALUES="${REPO_ROOT}/kubernetes/apps/plane/values.yaml"
PLANE_SECRET="${REPO_ROOT}/kubernetes/apps/plane/templates/secrets/plane.infisicalsecret.yaml"
PLANE_INGRESS="${REPO_ROOT}/kubernetes/apps/plane/templates/plane-ingress.yaml"
VMSTACK_CHART="${REPO_ROOT}/kubernetes/monitoring/victoria-metrics-stack/Chart.yaml"
VMSTACK_VALUES="${REPO_ROOT}/kubernetes/monitoring/victoria-metrics-stack/values.yaml"
VMSTACK_TEMPLATES="${REPO_ROOT}/kubernetes/monitoring/victoria-metrics-stack/templates"
VLOGS_CHART="${REPO_ROOT}/kubernetes/monitoring/victoria-logs/Chart.yaml"
VLOGS_TEMPLATES="${REPO_ROOT}/kubernetes/monitoring/victoria-logs/templates"

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

test_services_data_observability_services_are_declared() {
  assert_contains "services_data_observability_enabled: True" "${SERVICES_VARS}"
  assert_contains "services_data_victoria_metrics_version: v1.140.0" "${SERVICES_DEFAULTS}"
  assert_contains "services_data_victoria_logs_version: v1.50.0" "${SERVICES_DEFAULTS}"
  assert_contains "services_data_tempo_version: 2.10.1" "${SERVICES_DEFAULTS}"
  assert_contains "services_data_garage_version: v2.3.0" "${SERVICES_DEFAULTS}"
  assert_contains "f98d317942bb341151a2775162016bb50cf86b865d0108de03eb5db16e2120cd" "${SERVICES_DEFAULTS}"

  assert_contains "victoria-metrics-prod" "${SERVICES_TASKS}"
  assert_contains "victoria-logs-prod" "${SERVICES_TASKS}"
  assert_contains "tempo_{{ services_data_tempo_version }}_linux_amd64.tar.gz" "${SERVICES_TASKS}"
  assert_contains "garagehq.deuxfleurs.fr/_releases" "${SERVICES_TASKS}"
  assert_contains "garage.toml" "${SERVICES_TASKS}"
  assert_contains "tempo.yaml" "${SERVICES_TASKS}"
  assert_contains "Restart victoria-metrics" "${SERVICES_HANDLERS}"
  assert_contains "Restart victoria-logs" "${SERVICES_HANDLERS}"
  assert_contains "Restart garage" "${SERVICES_HANDLERS}"
  assert_contains "Restart tempo" "${SERVICES_HANDLERS}"
}

test_machine_identities_cover_garage_plane_secret_path() {
  assert_contains '"/services-data/garage/plane/**"' "${MACHINE_IDENTITIES}"
}

test_plane_uses_garage_not_chart_minio() {
  assert_contains "docstore_bucket: plane-uploads" "${PLANE_VALUES}"
  assert_contains "use_storage_proxy: true" "${PLANE_VALUES}"
  assert_contains "local_setup: false" "${PLANE_VALUES}"
  assert_not_contains "volumeSize: 3Gi" "${PLANE_VALUES}"

  assert_contains "name: plane-doc-store-secrets" "${PLANE_SECRET}"
  assert_contains "secretsPath: /services-data/garage/plane" "${PLANE_SECRET}"
  assert_contains "AWS_REGION" "${PLANE_SECRET}"
  assert_contains "AWS_S3_ENDPOINT_URL" "${PLANE_SECRET}"
  assert_contains "AWS_ACCESS_KEY_ID" "${PLANE_SECRET}"
  assert_contains "AWS_SECRET_ACCESS_KEY" "${PLANE_SECRET}"
  assert_not_contains "USE_MINIO" "${PLANE_SECRET}"
  assert_not_contains "MINIO_ROOT_USER" "${PLANE_SECRET}"
  assert_not_contains "MINIO_ROOT_PASSWORD" "${PLANE_SECRET}"

  assert_not_contains "plane-app-minio" "${PLANE_INGRESS}"
  assert_not_contains "number: 9000" "${PLANE_INGRESS}"
}

test_victoria_metrics_stack_is_rendered() {
  assert_contains "name: victoria-metrics-stack" "${VMSTACK_CHART}"
  assert_contains "victoria-metrics-k8s-stack" "${VMSTACK_CHART}"
  assert_contains "version: 0.74.1" "${VMSTACK_CHART}"

  assert_contains "vmsingle:" "${VMSTACK_VALUES}"
  assert_contains "enabled: false" "${VMSTACK_VALUES}"
  assert_contains "http://vmsingle-external:8428/api/v1/write" "${VMSTACK_VALUES}"
  assert_contains "grafana-secrets" "${VMSTACK_VALUES}"
  assert_contains "GF_DATABASE_TYPE" "${VMSTACK_VALUES}"
  assert_contains "VictoriaLogs" "${VMSTACK_VALUES}"
  assert_contains "http://victoria-logs.victoria-logs.svc.cluster.local:9428" "${VMSTACK_VALUES}"
  assert_contains "Tempo" "${VMSTACK_VALUES}"

  assert_contains "kind: InfisicalSecret" "${VMSTACK_TEMPLATES}/grafana.infisicalsecret.yaml"
  assert_contains "name: vmsingle-external" "${VMSTACK_TEMPLATES}/vmsingle-external.yaml"
  assert_contains "ip: 10.0.10.86" "${VMSTACK_TEMPLATES}/vmsingle-external.yaml"
  assert_contains "grafana.local.bysliek.com" "${VMSTACK_TEMPLATES}/ingresses.yaml"
  assert_contains "vmui.local.bysliek.com" "${VMSTACK_TEMPLATES}/ingresses.yaml"
  assert_contains "alertmanager.local.bysliek.com" "${VMSTACK_TEMPLATES}/ingresses.yaml"
}

test_victoria_logs_bridge_is_rendered() {
  assert_contains "name: victoria-logs" "${VLOGS_CHART}"
  assert_contains "name: victoria-logs" "${VLOGS_TEMPLATES}/victoria-logs-external.yaml"
  assert_contains "ip: 10.0.10.86" "${VLOGS_TEMPLATES}/victoria-logs-external.yaml"
  assert_contains "port: 9428" "${VLOGS_TEMPLATES}/victoria-logs-external.yaml"
  assert_contains "vlogs.local.bysliek.com" "${VLOGS_TEMPLATES}/ingress.yaml"
}

main() {
  test_services_data_observability_services_are_declared
  test_machine_identities_cover_garage_plane_secret_path
  test_plane_uses_garage_not_chart_minio
  test_victoria_metrics_stack_is_rendered
  test_victoria_logs_bridge_is_rendered
}

main "$@"
