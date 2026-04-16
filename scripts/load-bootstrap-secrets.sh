#!/usr/bin/env bash
# Load bootstrap secrets from Bitwarden cloud into the current shell.
#
# Usage:
#   source scripts/load-bootstrap-secrets.sh <group> [group...]
#
# Groups:
#   terraform   - Proxmox and UniFi credentials (TF_VAR_* env vars)
#   infisical   - Infisical application secrets (INFISICAL_* env vars)
#   all         - All groups
#
# Examples:
#   source scripts/load-bootstrap-secrets.sh all
#   source scripts/load-bootstrap-secrets.sh terraform infisical
#   source scripts/load-bootstrap-secrets.sh infisical
#
# Prerequisites:
#   - rbw installed with the 'bootstrap' profile configured
#   - rbw agent unlocked (run: RBW_PROFILE=bootstrap rbw unlock)

_bootstrap_load_terraform() {
  export TF_VAR_pm_api_token_id=$(rbw get homelab/bootstrap/proxmox-api-token-id)
  export TF_VAR_pm_api_token_secret=$(rbw get homelab/bootstrap/proxmox-api-token)
  export TF_VAR_cipassword=$(rbw get homelab/bootstrap/proxmox-cipassword)
  export TF_VAR_unifi_username=$(rbw get homelab/bootstrap/unifi-username)
  export TF_VAR_unifi_password=$(rbw get homelab/bootstrap/unifi-password)
  echo "  [terraform] TF_VAR_pm_api_token_id, TF_VAR_pm_api_token_secret, TF_VAR_cipassword, TF_VAR_unifi_username, TF_VAR_unifi_password"
}

_bootstrap_load_infisical() {
  export INFISICAL_DB_PASSWORD=$(rbw get homelab/bootstrap/infisical-db-password)
  export INFISICAL_ENCRYPTION_KEY=$(rbw get homelab/bootstrap/infisical-encryption-key)
  export INFISICAL_AUTH_SECRET=$(rbw get homelab/bootstrap/infisical-auth-secret)
  export INFISICAL_REDIS_PASSWORD=$(rbw get homelab/bootstrap/infisical-redis-password)
  echo "  [infisical] INFISICAL_DB_PASSWORD, INFISICAL_ENCRYPTION_KEY, INFISICAL_AUTH_SECRET, INFISICAL_REDIS_PASSWORD"
}

# --- main ---

if [[ $# -eq 0 ]]; then
  echo "Usage: source scripts/load-bootstrap-secrets.sh <group> [group...]"
  echo ""
  echo "Groups: terraform, infisical, all"
  return 1 2>/dev/null || exit 1
fi

if ! command -v rbw &>/dev/null; then
  echo "Error: rbw is not installed or not in PATH."
  echo "This script must be run from the host workstation, not the devcontainer."
  echo "Install: pacman -S rbw"
  return 1 2>/dev/null || exit 1
fi

export RBW_PROFILE=bootstrap

# Ensure the agent is unlocked
if ! rbw unlocked 2>/dev/null; then
  echo "rbw agent is locked. Unlocking (will prompt for master password)..."
  rbw unlock
fi

echo "Loading bootstrap secrets from Bitwarden..."

for group in "$@"; do
  case "$group" in
    terraform)
      _bootstrap_load_terraform
      ;;
    infisical)
      _bootstrap_load_infisical
      ;;
    all)
      _bootstrap_load_terraform
      _bootstrap_load_infisical
      ;;
    *)
      echo "Unknown group: $group"
      echo "Available groups: terraform, infisical, all"
      return 1 2>/dev/null || exit 1
      ;;
  esac
done

echo "Done."
