#!/usr/bin/env bash
# Load bootstrap secrets from Bitwarden cloud into the current shell.
# NOTE: this script is sourced, so it intentionally does NOT `set -u`/`set -e`
# — those options would leak into the caller's interactive shell and cause
# unrelated breakage (e.g. prompt plugins that reference optional vars).
# Error handling is done explicitly below with `|| return 1`.
#
# Usage:
#   source scripts/load-bootstrap-secrets.sh [group...]
#
# Groups:
#   terraform   - Proxmox and UniFi credentials + Terraform machine identity
#                 (TF_VAR_* env vars, including TF_VAR_infisical_client_id/secret)
#   ansible     - Ansible machine identity (INFISICAL_CLIENT_ID/SECRET env vars)
#   infisical   - Infisical application secrets (INFISICAL_* env vars)
#   all         - All groups
#
# Examples:
#   source scripts/load-bootstrap-secrets.sh
#   source scripts/load-bootstrap-secrets.sh all
#   source scripts/load-bootstrap-secrets.sh terraform infisical
#   source scripts/load-bootstrap-secrets.sh ansible
#   source scripts/load-bootstrap-secrets.sh infisical
#
# Prerequisites:
#   - rbw installed with the 'bootstrap' profile configured
#   - rbw agent unlocked (run: RBW_PROFILE=bootstrap rbw unlock)

_bootstrap_fail() {
  echo "Error: $*" >&2
  return 1 2>/dev/null || exit 1
}

_bootstrap_require_secret() {
  local env_name="$1"
  local secret_path="$2"
  local secret_value=""

  if ! secret_value="$(rbw get "${secret_path}")"; then
    _bootstrap_fail "could not load ${secret_path} from Bitwarden."
    return 1
  fi

  if [[ -z "${secret_value}" ]]; then
    _bootstrap_fail "Bitwarden returned an empty value for ${secret_path}."
    return 1
  fi

  export "${env_name}=${secret_value}"
}

_bootstrap_load_terraform() {
  _bootstrap_require_secret TF_VAR_pm_api_token_id homelab/bootstrap/proxmox-api-token-id || return 1
  _bootstrap_require_secret TF_VAR_pm_api_token_secret homelab/bootstrap/proxmox-api-token || return 1
  _bootstrap_require_secret TF_VAR_cipassword homelab/bootstrap/proxmox-cipassword || return 1
  _bootstrap_require_secret TF_VAR_unifi_username homelab/bootstrap/unifi-username || return 1
  _bootstrap_require_secret TF_VAR_unifi_password homelab/bootstrap/unifi-password || return 1
  _bootstrap_require_secret TF_VAR_infisical_client_id homelab/bootstrap/infisical-terraform-client-id || return 1
  _bootstrap_require_secret TF_VAR_infisical_client_secret homelab/bootstrap/infisical-terraform-client-secret || return 1
  echo "  [terraform] TF_VAR_pm_api_token_id, TF_VAR_pm_api_token_secret, TF_VAR_cipassword, TF_VAR_unifi_username, TF_VAR_unifi_password, TF_VAR_infisical_client_id, TF_VAR_infisical_client_secret"
  echo "  [terraform] NOTE: terraform/unifi also needs TF_VAR_iot_wlan_passphrase."
  echo "             Export manually before running that root (stored at /terraform/unifi/iot_wlan_passphrase in Infisical)."
}

_bootstrap_load_ansible() {
  _bootstrap_require_secret INFISICAL_CLIENT_ID homelab/bootstrap/infisical-ansible-client-id || return 1
  _bootstrap_require_secret INFISICAL_CLIENT_SECRET homelab/bootstrap/infisical-ansible-client-secret || return 1
  _bootstrap_require_secret ANSIBLE_CIPASSWORD homelab/bootstrap/proxmox-cipassword || return 1
  echo "  [ansible] INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, ANSIBLE_CIPASSWORD"
}

_bootstrap_load_infisical() {
  _bootstrap_require_secret INFISICAL_DB_PASSWORD homelab/bootstrap/infisical-db-password || return 1
  _bootstrap_require_secret INFISICAL_ENCRYPTION_KEY homelab/bootstrap/infisical-encryption-key || return 1
  _bootstrap_require_secret INFISICAL_AUTH_SECRET homelab/bootstrap/infisical-auth-secret || return 1
  _bootstrap_require_secret INFISICAL_REDIS_PASSWORD homelab/bootstrap/infisical-redis-password || return 1
  echo "  [infisical] INFISICAL_DB_PASSWORD, INFISICAL_ENCRYPTION_KEY, INFISICAL_AUTH_SECRET, INFISICAL_REDIS_PASSWORD"
}

# --- main ---

if [[ $# -eq 0 ]]; then
  set -- all
fi

if ! command -v rbw &>/dev/null; then
  echo "Error: rbw is not installed or not in PATH."
  echo "This script must be run from the host workstation, not the devcontainer."
  echo "Install: pacman -S rbw"
  _bootstrap_fail "rbw is required."
  return 1 2>/dev/null || exit 1
fi

export RBW_PROFILE=bootstrap
export INFISICAL_API_URL="${INFISICAL_API_URL:-https://infisical.local.bysliek.com}"

# Ensure the agent is unlocked
if ! rbw unlocked 2>/dev/null; then
  echo "rbw agent is locked. Unlocking (will prompt for master password)..."
  rbw unlock
fi

echo "Loading bootstrap secrets from Bitwarden..."

for group in "$@"; do
  case "$group" in
    terraform)
      _bootstrap_load_terraform || return 1 2>/dev/null || exit 1
      ;;
    ansible)
      _bootstrap_load_ansible || return 1 2>/dev/null || exit 1
      ;;
    infisical)
      _bootstrap_load_infisical || return 1 2>/dev/null || exit 1
      ;;
    all)
      _bootstrap_load_terraform || return 1 2>/dev/null || exit 1
      _bootstrap_load_ansible || return 1 2>/dev/null || exit 1
      _bootstrap_load_infisical || return 1 2>/dev/null || exit 1
      ;;
    *)
      echo "Unknown group: $group" >&2
      echo "Available groups: terraform, ansible, infisical, all" >&2
      _bootstrap_fail "invalid bootstrap secret group."
      return 1 2>/dev/null || exit 1
      ;;
  esac
done

echo "Done."
