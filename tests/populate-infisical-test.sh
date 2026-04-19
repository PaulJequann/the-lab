#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${REPO_ROOT}/scripts/populate-infisical.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fake_git() {
  local bindir="$1"
  local fake_repo_root="$2"

  cat >"${bindir}/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "-C" && "\${3:-}" == "rev-parse" && "\${4:-}" == "--show-toplevel" ]]; then
  printf '%s\n' "${fake_repo_root}"
  exit 0
fi

echo "unexpected git invocation: \$*" >&2
exit 1
EOF

  chmod +x "${bindir}/git"
}

make_fake_kubectl() {
  local bindir="$1"

  cat >"${bindir}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-n" && "${2:-}" == "infisical" && "${3:-}" == "get" && "${4:-}" == "secret" && "${5:-}" == "infisical-admin-identity" ]]; then
  printf 'dG9rZW4=\n'
  exit 0
fi

echo "unexpected kubectl invocation: $*" >&2
exit 1
EOF

  chmod +x "${bindir}/kubectl"
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
  get)
    key="${1:-}"
    case "${key}" in
      homelab/bootstrap/argocd-admin-password-hash)
        printf 'bcrypt-hash\n'
        ;;
      homelab/bootstrap/proxmox-cipassword)
        printf 'cipassword-value\n'
        ;;
      homelab/bootstrap/proxmox-api-token-id)
        printf 'token-id-value\n'
        ;;
      homelab/bootstrap/proxmox-api-token)
        printf 'token-secret-value\n'
        ;;
      homelab/bootstrap/unifi-username)
        printf 'unifi-user\n'
        ;;
      homelab/bootstrap/unifi-password)
        printf 'unifi-pass\n'
        ;;
      *)
        echo "missing fake rbw secret for ${key}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected rbw command: ${cmd}" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${bindir}/rbw"
}

make_fake_sops() {
  local bindir="$1"

  cat >"${bindir}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${2:-}"

case "${target}" in
  */ansible/group_vars/services.sops.yaml)
    cat <<'YAML'
honcho_postgres_password: pg-pass
honcho_redis_password: redis-pass
honcho_auth_jwt_secret: jwt-secret
honcho_webhook_secret: webhook-secret
honcho_llm_anthropic_api_key: anthropic-key
honcho_llm_openai_api_key: openai-key
honcho_llm_gemini_api_key: gemini-key
honcho_llm_groq_api_key: groq-key
honcho_sentry_dsn: sentry-dsn
honcho_llm_openai_compatible_api_key:
honcho_llm_vllm_api_key:
honcho_vector_store_turbopuffer_api_key:
YAML
    ;;
  */ansible/roles/cloudflare/files/cloudflare-tunnel.sops.json)
    printf '{"AccountTag":"abc123"}\n'
    ;;
  *)
    echo "unexpected sops target: ${target}" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${bindir}/sops"
}

make_fake_yq() {
  local bindir="$1"

  cat >"${bindir}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

query="${2:-}"
query="${query#.}"
query="${query%% //*}"

if [[ $# -ge 3 ]]; then
  case "${query}" in
    cloudflare_api_token)
      if [[ "${TEST_CFG_cloudflare_api_token-}" == "__EMPTY__" ]]; then
        printf '\n'
      else
        printf '%s\n' "${TEST_CFG_cloudflare_api_token:-cf-token}"
      fi
      ;;
    glitchtip_secret_key)
      printf 'glitchtip-secret\n'
      ;;
    glitchtip_postgres_user)
      printf 'glitchtip-user\n'
      ;;
    glitchtip_postgres_password)
      printf 'glitchtip-pg-pass\n'
      ;;
    glitchtip_postgres_db)
      printf 'glitchtip-db\n'
      ;;
    glitchtip_data_ip)
      printf '10.0.0.10\n'
      ;;
    glitchtip_postgres_port)
      printf '5432\n'
      ;;
    glitchtip_redis_password)
      printf 'glitchtip-redis-pass\n'
      ;;
    glitchtip_redis_port)
      printf '6379\n'
      ;;
    glitchtip_email_url)
      printf 'smtp://mail.example\n'
      ;;
    glitchtip_admin_username)
      printf 'admin\n'
      ;;
    glitchtip_admin_email)
      printf 'admin@example.com\n'
      ;;
    glitchtip_admin_password)
      printf 'glitchtip-admin-pass\n'
      ;;
    glitchtip_bootstrap_mcp_token)
      printf 'mcp-token\n'
      ;;
    deeptutor_llm_api_key)
      printf 'deeptutor-llm\n'
      ;;
    deeptutor_embedding_api_key)
      printf 'deeptutor-embedding\n'
      ;;
    deeptutor_perplexity_api_key)
      printf 'deeptutor-perplexity\n'
      ;;
    cloudflare_email)
      printf 'cf@example.com\n'
      ;;
    *)
      printf '\n'
      ;;
  esac
  exit 0
fi

input="$(cat)"
value="$(printf '%s\n' "${input}" | awk -F': ' -v k="${query}" '$1 == k { print substr($0, length($1) + 3); exit }')"
printf '%s\n' "${value}"
EOF

  chmod +x "${bindir}/yq"
}

make_fake_infisical() {
  local bindir="$1"

  cat >"${bindir}/infisical" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "secrets" && "${2:-}" == "set" ]]; then
  printf '%s\n' "$*" >>"${INFISICAL_LOG}"
  exit 0
fi

echo "unexpected infisical invocation: $*" >&2
exit 1
EOF

  chmod +x "${bindir}/infisical"
}

setup_fake_repo() {
  local tempdir
  tempdir="$(mktemp -d)"

  mkdir -p \
    "${tempdir}/bin" \
    "${tempdir}/repo/scripts" \
    "${tempdir}/repo/terraform/unifi" \
    "${tempdir}/repo/ansible/group_vars" \
    "${tempdir}/repo/ansible/roles/cloudflare/files"

  cp "${SCRIPT_PATH}" "${tempdir}/repo/scripts/populate-infisical.sh"
  chmod +x "${tempdir}/repo/scripts/populate-infisical.sh"

  : >"${tempdir}/repo/config.yaml"
  cat >"${tempdir}/repo/terraform/unifi/terraform.tfvars" <<'EOF'
iot_wlan_passphrase = "iot-passphrase"
EOF
  : >"${tempdir}/repo/ansible/group_vars/services.sops.yaml"
  : >"${tempdir}/repo/ansible/roles/cloudflare/files/cloudflare-tunnel.sops.json"

  make_fake_git "${tempdir}/bin" "${tempdir}/repo"
  make_fake_kubectl "${tempdir}/bin"
  make_fake_rbw "${tempdir}/bin"
  make_fake_sops "${tempdir}/bin"
  make_fake_yq "${tempdir}/bin"
  make_fake_infisical "${tempdir}/bin"

  printf '%s\n' "${tempdir}"
}

run_populate() {
  local tempdir="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  PATH="${tempdir}/bin:${PATH}" \
  INFISICAL_PROJECT_ID=project-id \
  INFISICAL_API_URL=https://infisical.local.bysliek.com \
  INFISICAL_LOG="${tempdir}/infisical.log" \
  TEST_CFG_cloudflare_api_token="${TEST_CFG_cloudflare_api_token-}" \
  bash "${tempdir}/repo/scripts/populate-infisical.sh" --dry-run >"${stdout_file}" 2>"${stderr_file}"
}

test_fails_fast_when_required_source_is_empty() {
  local tempdir stdout_file stderr_file
  tempdir="$(setup_fake_repo)"
  stdout_file="${tempdir}/stdout"
  stderr_file="${tempdir}/stderr"

  if TEST_CFG_cloudflare_api_token="__EMPTY__" run_populate "${tempdir}" "${stdout_file}" "${stderr_file}"; then
    fail "populate script should fail when a required source resolves empty"
  fi
}

test_uses_canonical_proxmox_api_token_item() {
  local tempdir stdout_file stderr_file
  tempdir="$(setup_fake_repo)"
  stdout_file="${tempdir}/stdout"
  stderr_file="${tempdir}/stderr"

  run_populate "${tempdir}" "${stdout_file}" "${stderr_file}" \
    || fail "populate script should accept the canonical proxmox-api-token Bitwarden item"
}

main() {
  test_fails_fast_when_required_source_is_empty
  test_uses_canonical_proxmox_api_token_item
}

main "$@"
