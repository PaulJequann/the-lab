#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

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

render_templates() {
  local data_file="${1:-${REPO_ROOT}/config.yaml}"

  python3 "${REPO_ROOT}/scripts/render.py" \
    --input "${REPO_ROOT}/templates/kubernetes" \
    --output "${TMPDIR}/kubernetes" \
    --data "${data_file}"
}

write_config_variant() {
  local output_file="$1"
  local enabled="$2"

  python3 - "${REPO_ROOT}/config.yaml" "${output_file}" "${enabled}" <<'PY'
import sys
import yaml

src, dst = sys.argv[1], sys.argv[2]
enabled = sys.argv[3].lower() == "true"
with open(src) as f:
    data = yaml.safe_load(f)

data["homeassistant_fast_local_enabled"] = enabled
data["sonarr_fast_local_enabled"] = enabled
data["radarr_fast_local_enabled"] = enabled
data["overseerr_fast_local_enabled"] = enabled

with open(dst, "w") as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY
}

test_default_render_is_staged_only() {
  local staged_config="${TMPDIR}/staged-config.yaml"
  write_config_variant "${staged_config}" false
  render_templates "${staged_config}"

  local local_path_manifest="${TMPDIR}/kubernetes/infrastructure/local-path-storage/local-path-provisioner.yaml"
  local homeassistant_values="${TMPDIR}/kubernetes/apps/homeassistant/values.yaml"
  local media_pvcs="${TMPDIR}/kubernetes/apps/media/fast-local-pvcs.yaml"
  local sonarr_app="${TMPDIR}/kubernetes/bootstrap/apps/sonarr.yaml"

  assert_contains 'name: fast-local' "${local_path_manifest}"
  assert_contains '"node": "gpop"' "${local_path_manifest}"
  assert_contains '"node": "jamahl"' "${local_path_manifest}"
  assert_contains '/home/fast-local' "${local_path_manifest}"

  assert_contains 'name: sonarr-fast-local' "${media_pvcs}"
  assert_contains 'name: radarr-fast-local' "${media_pvcs}"
  assert_contains 'name: overseerr-fast-local' "${media_pvcs}"
  assert_contains 'storageClassName: fast-local' "${media_pvcs}"

  assert_contains 'storageClass: nfs-csi' "${homeassistant_values}"
  assert_contains 'storageClass: nfs-csi' "${sonarr_app}"
}

test_cutover_render_uses_fast_local_claims() {
  local cutover_config="${TMPDIR}/cutover-config.yaml"
  write_config_variant "${cutover_config}" true
  render_templates "${cutover_config}"

  local homeassistant_values="${TMPDIR}/kubernetes/apps/homeassistant/values.yaml"
  local sonarr_app="${TMPDIR}/kubernetes/bootstrap/apps/sonarr.yaml"
  local radarr_app="${TMPDIR}/kubernetes/bootstrap/apps/radarr.yaml"
  local overseerr_app="${TMPDIR}/kubernetes/bootstrap/apps/overseerr.yaml"

  assert_contains 'existingClaim: homeassistant-fast-local' "${homeassistant_values}"
  assert_contains 'storageClassName: fast-local' "${TMPDIR}/kubernetes/apps/homeassistant/templates/fast-local-pvc.yaml"

  assert_contains 'existingClaim: sonarr-fast-local' "${sonarr_app}"
  assert_contains 'existingClaim: radarr-fast-local' "${radarr_app}"
  assert_contains 'existingClaim: overseerr-fast-local' "${overseerr_app}"
  assert_contains 'kubernetes.io/hostname: gpop' "${sonarr_app}"
  assert_contains 'kubernetes.io/hostname: jamahl' "${radarr_app}"
  assert_contains 'kubernetes.io/hostname: jamahl' "${overseerr_app}"
}

main() {
  test_default_render_is_staged_only
  test_cutover_render_uses_fast_local_claims
}

main "$@"
