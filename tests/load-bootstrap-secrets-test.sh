#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${REPO_ROOT}/scripts/load-bootstrap-secrets.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "${expected}" != "${actual}" ]]; then
    fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

make_fake_rbw() {
  local bindir="$1"

  cat >"${bindir}/rbw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "${cmd}" in
  unlocked)
    exit 0
    ;;
  unlock)
    exit 0
    ;;
  get)
    key="${1:-}"
    if [[ -n "${RBW_FAIL_ON:-}" && "${key}" == "${RBW_FAIL_ON}" ]]; then
      exit 1
    fi
    if [[ -n "${RBW_EMPTY_ON:-}" && "${key}" == "${RBW_EMPTY_ON}" ]]; then
      exit 0
    fi
    printf 'value-for-%s\n' "${key}"
    ;;
  *)
    echo "unexpected rbw command: ${cmd}" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${bindir}/rbw"
}

run_loader() {
  local tempdir="$1"

  PATH="${tempdir}/bin:${PATH}" \
  HOME="${tempdir}/home" \
  bash -c "
    set -euo pipefail
    source '${SCRIPT_PATH}' ${2:-}
    printf 'TF_VAR_pm_api_token_id=%s\n' \"\${TF_VAR_pm_api_token_id-}\"
    printf 'TF_VAR_pm_api_token_secret=%s\n' \"\${TF_VAR_pm_api_token_secret-}\"
    printf 'TF_VAR_cipassword=%s\n' \"\${TF_VAR_cipassword-}\"
    printf 'TF_VAR_unifi_username=%s\n' \"\${TF_VAR_unifi_username-}\"
    printf 'TF_VAR_unifi_password=%s\n' \"\${TF_VAR_unifi_password-}\"
    printf 'INFISICAL_DB_PASSWORD=%s\n' \"\${INFISICAL_DB_PASSWORD-}\"
    printf 'INFISICAL_ENCRYPTION_KEY=%s\n' \"\${INFISICAL_ENCRYPTION_KEY-}\"
    printf 'INFISICAL_AUTH_SECRET=%s\n' \"\${INFISICAL_AUTH_SECRET-}\"
    printf 'INFISICAL_REDIS_PASSWORD=%s\n' \"\${INFISICAL_REDIS_PASSWORD-}\"
    printf 'INFISICAL_API_URL=%s\n' \"\${INFISICAL_API_URL-}\"
  "
}

test_defaults_to_all_when_no_groups_are_given() {
  local tempdir
  tempdir="$(mktemp -d)"
  mkdir -p "${tempdir}/bin" "${tempdir}/home"
  make_fake_rbw "${tempdir}/bin"

  local output
  output="$(run_loader "${tempdir}")"

  grep -q '^TF_VAR_pm_api_token_id=value-for-homelab/bootstrap/proxmox-api-token-id$' <<<"${output}" \
    || fail "loader should populate terraform secrets by default"
  grep -q '^INFISICAL_DB_PASSWORD=value-for-homelab/bootstrap/infisical-db-password$' <<<"${output}" \
    || fail "loader should populate infisical secrets by default"
  grep -q '^INFISICAL_API_URL=https://infisical.local.bysliek.com$' <<<"${output}" \
    || fail "loader should export the self-hosted Infisical API URL"
}

test_fails_fast_when_rbw_lookup_errors() {
  local tempdir
  tempdir="$(mktemp -d)"
  mkdir -p "${tempdir}/bin" "${tempdir}/home"
  make_fake_rbw "${tempdir}/bin"

  if PATH="${tempdir}/bin:${PATH}" HOME="${tempdir}/home" RBW_FAIL_ON="homelab/bootstrap/infisical-db-password" \
    bash -c "source '${SCRIPT_PATH}' infisical" >/tmp/load-bootstrap-secrets-test.out 2>/tmp/load-bootstrap-secrets-test.err; then
    fail "loader should fail when rbw get exits non-zero"
  fi
}

test_fails_fast_when_rbw_lookup_is_empty() {
  local tempdir
  tempdir="$(mktemp -d)"
  mkdir -p "${tempdir}/bin" "${tempdir}/home"
  make_fake_rbw "${tempdir}/bin"

  if PATH="${tempdir}/bin:${PATH}" HOME="${tempdir}/home" RBW_EMPTY_ON="homelab/bootstrap/infisical-db-password" \
    bash -c "source '${SCRIPT_PATH}' infisical" >/tmp/load-bootstrap-secrets-test.out 2>/tmp/load-bootstrap-secrets-test.err; then
    fail "loader should fail when rbw get returns an empty secret"
  fi
}

main() {
  test_defaults_to_all_when_no_groups_are_given
  test_fails_fast_when_rbw_lookup_errors
  test_fails_fast_when_rbw_lookup_is_empty
}

main "$@"
