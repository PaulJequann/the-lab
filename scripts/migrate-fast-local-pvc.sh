#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config.yaml"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/tmp/fast-local-migration-${TIMESTAMP}"
RESTORE_REPLICAS=false

usage() {
  cat <<'EOF'
Usage:
  scripts/migrate-fast-local-pvc.sh [--backup-dir DIR] [--restore-replicas] APP [APP...]

Cold-copy app data from the existing NFS PVC to the staged fast-local PVC.

Behavior:
  - scales the workload down to 0 replicas
  - mounts both source and destination PVCs on the target node
  - writes a local tar backup under /tmp by default
  - copies data with tar preserving file metadata
  - leaves the workload scaled down unless --restore-replicas is set

Apps:
  homeassistant
  sonarr
  radarr
  overseerr
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

cfg() {
  yq -r "$1" "${CONFIG_FILE}"
}

wait_for_no_pods() {
  local namespace="$1"
  local workload="$2"
  local timeout="${3:-180}"
  local elapsed=0

  while (( elapsed < timeout )); do
    if ! kubectl -n "${namespace}" get pods -o name 2>/dev/null | grep -Eq "^pod/${workload}(-|$)"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  fail "timed out waiting for pods for ${namespace}/${workload} to terminate"
}

resolve_app() {
  local app="$1"

  case "${app}" in
    homeassistant)
      APP_NAMESPACE="$(cfg '.homeassistant_namespace')"
      APP_KIND="statefulset"
      APP_WORKLOAD="homeassistant"
      SOURCE_CLAIM="homeassistant"
      TARGET_CLAIM="$(cfg '.homeassistant_fast_local_claim_name')"
      TARGET_NODE="$(cfg '.homeassistant_node_name')"
      MOUNT_PATH="/config"
      ;;
    sonarr)
      APP_NAMESPACE="$(cfg '.media_namespace')"
      APP_KIND="deployment"
      APP_WORKLOAD="sonarr"
      SOURCE_CLAIM="sonarr"
      TARGET_CLAIM="$(cfg '.sonarr_fast_local_claim_name')"
      TARGET_NODE="$(cfg '.sonarr_fast_local_node_name')"
      MOUNT_PATH="/config"
      ;;
    radarr)
      APP_NAMESPACE="$(cfg '.media_namespace')"
      APP_KIND="deployment"
      APP_WORKLOAD="radarr"
      SOURCE_CLAIM="radarr"
      TARGET_CLAIM="$(cfg '.radarr_fast_local_claim_name')"
      TARGET_NODE="$(cfg '.radarr_fast_local_node_name')"
      MOUNT_PATH="/config"
      ;;
    overseerr)
      APP_NAMESPACE="$(cfg '.media_namespace')"
      APP_KIND="deployment"
      APP_WORKLOAD="overseerr"
      SOURCE_CLAIM="overseerr"
      TARGET_CLAIM="$(cfg '.overseerr_fast_local_claim_name')"
      TARGET_NODE="$(cfg '.overseerr_fast_local_node_name')"
      MOUNT_PATH="/config"
      ;;
    *)
      fail "unsupported app: ${app}"
      ;;
  esac
}

run_migration() {
  local app="$1"
  local original_replicas
  local pod_name="fast-local-migrate-${app}"
  local backup_file
  local manifest_file
  local source_bytes
  local dest_bytes
  local source_count
  local dest_count

  resolve_app "${app}"

  kubectl -n "${APP_NAMESPACE}" get pvc "${SOURCE_CLAIM}" >/dev/null
  kubectl -n "${APP_NAMESPACE}" get pvc "${TARGET_CLAIM}" >/dev/null
  kubectl -n "${APP_NAMESPACE}" get "${APP_KIND}" "${APP_WORKLOAD}" >/dev/null

  original_replicas="$(kubectl -n "${APP_NAMESPACE}" get "${APP_KIND}" "${APP_WORKLOAD}" -o jsonpath='{.spec.replicas}')"
  backup_file="${BACKUP_DIR}/${app}.tar"
  manifest_file="$(mktemp)"

  cat >"${manifest_file}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${APP_NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  containers:
    - name: migrator
      image: busybox:1.36
      command:
        - sh
        - -c
        - sleep 36000
      volumeMounts:
        - name: source
          mountPath: /source
          readOnly: true
        - name: dest
          mountPath: /dest
  volumes:
    - name: source
      persistentVolumeClaim:
        claimName: ${SOURCE_CLAIM}
        readOnly: true
    - name: dest
      persistentVolumeClaim:
        claimName: ${TARGET_CLAIM}
EOF

  trap 'kubectl -n "${APP_NAMESPACE}" delete pod "${pod_name}" --ignore-not-found >/dev/null 2>&1 || true; rm -f "${manifest_file}"' RETURN

  echo "Scaling ${APP_NAMESPACE}/${APP_WORKLOAD} down from ${original_replicas} replicas"
  kubectl -n "${APP_NAMESPACE}" scale "${APP_KIND}/${APP_WORKLOAD}" --replicas=0 >/dev/null
  wait_for_no_pods "${APP_NAMESPACE}" "${APP_WORKLOAD}"

  echo "Starting migration pod ${pod_name} on ${TARGET_NODE}"
  kubectl apply -f "${manifest_file}" >/dev/null
  kubectl -n "${APP_NAMESPACE}" wait --for=condition=Ready "pod/${pod_name}" --timeout=180s >/dev/null

  mkdir -p "${BACKUP_DIR}"
  echo "Writing backup to ${backup_file}"
  kubectl -n "${APP_NAMESPACE}" exec "${pod_name}" -- tar cpf - -C /source . >"${backup_file}"

  echo "Copying ${SOURCE_CLAIM} -> ${TARGET_CLAIM}"
  kubectl -n "${APP_NAMESPACE}" exec "${pod_name}" -- sh -c 'cd /source && tar cpf - . | (cd /dest && tar xpf -)'

  source_bytes="$(kubectl -n "${APP_NAMESPACE}" exec "${pod_name}" -- sh -c 'du -sb /source | cut -f1')"
  dest_bytes="$(kubectl -n "${APP_NAMESPACE}" exec "${pod_name}" -- sh -c 'du -sb /dest | cut -f1')"
  source_count="$(kubectl -n "${APP_NAMESPACE}" exec "${pod_name}" -- sh -c 'find /source | wc -l | tr -d " "')"
  dest_count="$(kubectl -n "${APP_NAMESPACE}" exec "${pod_name}" -- sh -c 'find /dest | wc -l | tr -d " "')"

  echo "Source bytes: ${source_bytes}"
  echo "Dest bytes:   ${dest_bytes}"
  echo "Source paths: ${source_count}"
  echo "Dest paths:   ${dest_count}"

  if [[ "${source_count}" != "${dest_count}" ]]; then
    fail "path count mismatch for ${app}"
  fi

  kubectl -n "${APP_NAMESPACE}" delete pod "${pod_name}" --ignore-not-found >/dev/null
  rm -f "${manifest_file}"
  trap - RETURN

  if [[ "${RESTORE_REPLICAS}" == "true" ]]; then
    echo "Restoring ${APP_NAMESPACE}/${APP_WORKLOAD} to ${original_replicas} replicas"
    kubectl -n "${APP_NAMESPACE}" scale "${APP_KIND}/${APP_WORKLOAD}" --replicas="${original_replicas}" >/dev/null
  else
    cat <<EOF
${app} data copied successfully.
Backup: ${backup_file}
Workload left scaled down for cutover.

Next:
  1. Enable the corresponding *_fast_local_enabled flag in config.yaml
  2. Run task configure
  3. Commit and push the cutover change
  4. Let Argo sync the workload onto ${TARGET_CLAIM} on ${TARGET_NODE}
EOF
  fi
}

main() {
  local apps=()

  need_cmd kubectl
  need_cmd yq

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-dir)
        [[ $# -ge 2 ]] || fail "--backup-dir requires a value"
        BACKUP_DIR="$2"
        shift 2
        ;;
      --restore-replicas)
        RESTORE_REPLICAS=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        apps+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#apps[@]} -gt 0 ]] || {
    usage
    exit 1
  }

  for app in "${apps[@]}"; do
    run_migration "${app}"
  done
}

main "$@"
