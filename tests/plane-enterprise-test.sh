#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/config.yaml"
APPS_PROJECT="${REPO_ROOT}/kubernetes/bootstrap/projects/apps.yaml"
APPSET="${REPO_ROOT}/kubernetes/bootstrap/applicationsets/cluster-apps.yaml"
PLANE_CHART="${REPO_ROOT}/kubernetes/apps/plane/Chart.yaml"
PLANE_VALUES="${REPO_ROOT}/kubernetes/apps/plane/values.yaml"
PLANE_INGRESS="${REPO_ROOT}/kubernetes/apps/plane/templates/plane-ingress.yaml"
PLANE_SECRET="${REPO_ROOT}/kubernetes/apps/plane/templates/secrets/plane.infisicalsecret.yaml"
SERVICES_PLAYBOOK="${REPO_ROOT}/ansible/playbooks/services-data.yml"
SERVICES_VARS="${REPO_ROOT}/ansible/group_vars/services.yaml"
IDENTITIES_SCRIPT="${REPO_ROOT}/scripts/create-machine-identities.sh"

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

test_plane_config_and_argocd_destination_are_rendered() {
  assert_contains 'plane_namespace: "plane"' "${CONFIG}"
  assert_contains 'plane_chart_version: "2.3.2"' "${CONFIG}"
  assert_contains "namespace: 'plane'" "${APPS_PROJECT}"
  assert_contains "releaseName: >-" "${APPSET}"
  assert_contains "plane-app" "${APPSET}"
}

test_plane_wrapper_disables_chart_ingress_and_local_postgres() {
  assert_contains "name: plane" "${PLANE_CHART}"
  assert_contains "repository: https://helm.plane.so/" "${PLANE_CHART}"
  assert_contains "plane-enterprise:" "${PLANE_VALUES}"
  assert_contains "enabled: false" "${PLANE_VALUES}"
  assert_contains "tls_secret_name: plane-tls" "${PLANE_VALUES}"
  assert_contains "local_setup: false" "${PLANE_VALUES}"
  assert_contains "app_env_existingSecret: plane-app-secrets" "${PLANE_VALUES}"
  assert_contains "silo_env_existingSecret: plane-silo-secrets" "${PLANE_VALUES}"
}

test_plane_infisical_secret_and_wait_jobs_are_rendered() {
  assert_contains "kind: InfisicalSecret" "${PLANE_SECRET}"
  assert_contains "secretsPath: /kubernetes/plane" "${PLANE_SECRET}"
  assert_contains "secretName: plane-app-secrets" "${PLANE_SECRET}"
  assert_contains "secretName: plane-live-secrets" "${PLANE_SECRET}"
  assert_contains "secretName: plane-silo-secrets" "${PLANE_SECRET}"
  assert_contains "secretName: plane-doc-store-secrets" "${PLANE_SECRET}"
  assert_contains "name: wait-for-plane-app-secrets" "${PLANE_SECRET}"
  assert_contains "name: wait-for-plane-doc-store-secrets" "${PLANE_SECRET}"
}

test_plane_custom_cilium_ingress_routes_expected_services() {
  assert_contains "kind: Ingress" "${PLANE_INGRESS}"
  assert_contains "ingressClassName: cilium" "${PLANE_INGRESS}"
  assert_contains "cert-manager.io/cluster-issuer: cloudflare-cluster-issuer" "${PLANE_INGRESS}"
  assert_contains "host: plane.local.bysliek.com" "${PLANE_INGRESS}"
  assert_contains "secretName: plane-tls" "${PLANE_INGRESS}"
  assert_contains "name: plane-app-web" "${PLANE_INGRESS}"
  assert_contains "name: plane-app-api" "${PLANE_INGRESS}"
  assert_contains "name: plane-app-minio" "${PLANE_INGRESS}"
  assert_contains "number: 9000" "${PLANE_INGRESS}"
}

test_services_data_provisions_plane_database_from_infisical() {
  assert_contains "services_data_enable_plane_db: True" "${SERVICES_VARS}"
  assert_contains "Fetch Plane DB credentials from Infisical" "${SERVICES_PLAYBOOK}"
  assert_contains "path='/kubernetes/plane'" "${SERVICES_PLAYBOOK}"
  assert_contains "'name': 'plane'" "${SERVICES_PLAYBOOK}"
  assert_contains "'user': 'plane'" "${SERVICES_PLAYBOOK}"
  assert_contains "_plane_infisical.POSTGRES_PASSWORD" "${SERVICES_PLAYBOOK}"
}

test_machine_identity_grants_ansible_plane_path() {
  assert_contains '"/kubernetes/plane/**"' "${IDENTITIES_SCRIPT}"
}

test_no_plaintext_plane_secret_values_are_committed() {
  assert_not_contains "POSTGRES_PASSWORD:" "${CONFIG}"
  assert_not_contains "MINIO_ROOT_PASSWORD:" "${CONFIG}"
  assert_not_contains "SECRET_KEY:" "${CONFIG}"
}

main() {
  test_plane_config_and_argocd_destination_are_rendered
  test_plane_wrapper_disables_chart_ingress_and_local_postgres
  test_plane_infisical_secret_and_wait_jobs_are_rendered
  test_plane_custom_cilium_ingress_routes_expected_services
  test_services_data_provisions_plane_database_from_infisical
  test_machine_identity_grants_ansible_plane_path
  test_no_plaintext_plane_secret_values_are_committed
}

main "$@"
