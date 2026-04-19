#!/usr/bin/env bash
# One-shot migration of secrets from repo sources into self-hosted Infisical.
#
# Source of truth: docs/plans/secret-management-redesign.md §A.5 (inventory table)
#
# Contract (per A.5):
#   - Reads INFISICAL_TOKEN from the K8s Secret infisical/infisical-admin-identity
#     created by A.4.5 (`infisical bootstrap --output k8-secret`).
#   - Reads INFISICAL_API_URL + Bitwarden bootstrap values from the environment
#     (source scripts/load-bootstrap-secrets.sh first).
#   - Decrypts SOPS sources in-memory only (never to disk).
#   - Aborts fast on the first failed write; prints key names (not values).
#   - --dry-run prints every intended write without executing it.
#
# Usage:
#   source scripts/load-bootstrap-secrets.sh
#   export INFISICAL_PROJECT_ID=<homelab-project-id>   # see README / .infisical.json
#   scripts/populate-infisical.sh --dry-run
#   scripts/populate-infisical.sh
#
# Prerequisites: bash 4+, kubectl, sops, yq, rbw (unlocked, RBW_PROFILE=bootstrap),
# infisical CLI. Run from the workstation, not the devcontainer (needs rbw).

set -uo pipefail

# ----------------------------------------------------------------------------
# Args / config
# ----------------------------------------------------------------------------

DRY_RUN=false
ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------

_fail() { echo "ERROR: $*" >&2; exit 1; }

for cmd in kubectl sops yq rbw infisical git; do
  command -v "$cmd" >/dev/null 2>&1 || _fail "$cmd not in PATH"
done

[ -n "${INFISICAL_API_URL:-}" ] || \
  _fail "INFISICAL_API_URL not set. Source scripts/load-bootstrap-secrets.sh first."
[ -n "${INFISICAL_PROJECT_ID:-}" ] || \
  _fail "INFISICAL_PROJECT_ID not set. Export the homelab project's ID (see Infisical UI or .infisical.json)."

# Admin-identity token from the K8s Secret created by A.4.5
echo "[auth] Reading admin-identity token from infisical/infisical-admin-identity..."
INFISICAL_TOKEN="$(
  kubectl -n infisical get secret infisical-admin-identity \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d
)" || _fail "could not read infisical-admin-identity Secret (is the cluster reachable? is Infisical bootstrapped?)"
[ -n "$INFISICAL_TOKEN" ] || _fail "infisical-admin-identity Secret contained an empty token"
export INFISICAL_TOKEN

# Ensure rbw is usable (loader unlocks it; double-check here so an unlocked
# agent that later timed out surfaces clearly).
if ! RBW_PROFILE=bootstrap rbw unlocked >/dev/null 2>&1; then
  _fail "rbw agent is locked. Run: RBW_PROFILE=bootstrap rbw unlock"
fi
export RBW_PROFILE=bootstrap

# ----------------------------------------------------------------------------
# Counters / audit trail
# ----------------------------------------------------------------------------

WRITTEN=0
SKIPPED=0
FAILED=0

is_empty_secret_value() {
  local value="${1:-}"
  [ -z "$value" ] || [ "$value" = "null" ] || [ "$value" = "~" ]
}

# Idempotently create every folder component of the given path.
# `infisical secrets set` does NOT auto-create folders and 404s on missing
# parents. The CLI's `secrets folders create` exits 0 on success and nonzero
# on failure; "already exists" is a nonzero failure we treat as success.
ensure_folder() {
  local full_path="$1"
  local parent="/"
  local name stderr rc
  IFS='/' read -r -a components <<<"${full_path#/}"
  for name in "${components[@]}"; do
    [ -z "$name" ] && continue
    if $DRY_RUN; then
      parent="${parent%/}/${name}"
      continue
    fi
    stderr="$(infisical secrets folders create \
      --projectId "$INFISICAL_PROJECT_ID" \
      --env "$ENV_SLUG" \
      --path "$parent" \
      --name "$name" 2>&1 >/dev/null)"
    rc=$?
    if [ $rc -ne 0 ] && ! grep -q "already exists" <<<"$stderr"; then
      echo "  [FAIL]   ensure_folder ${parent%/}/${name}" >&2
      echo "${stderr}" >&2
      _fail "failed ensuring folder ${parent%/}/${name}; aborting migration."
    fi
    parent="${parent%/}/${name}"
  done
}

set_secret() {
  # $1 = Infisical path (e.g. /kubernetes/glitchtip)
  # $2 = key name
  # $3 = value
  # $4 = optional mode: required (default) or nullable
  local path="$1" key="$2" value="${3:-}" mode="${4:-required}"

  if is_empty_secret_value "$value"; then
    if [ "$mode" = "nullable" ]; then
      echo "  [skip]   ${path}/${key}  (null/empty)"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    FAILED=$((FAILED + 1))
    _fail "required source for ${path}/${key} resolved empty; aborting migration."
  fi

  if $DRY_RUN; then
    printf '  [dryrun] %s/%s  (%d bytes)\n' "$path" "$key" "${#value}"
    WRITTEN=$((WRITTEN + 1))
    return 0
  fi

  ensure_folder "$path"

  if infisical secrets set --projectId "$INFISICAL_PROJECT_ID" \
       --env "$ENV_SLUG" --path "$path" "${key}=${value}" >/dev/null 2>&1; then
    echo "  [ok]     ${path}/${key}"
    WRITTEN=$((WRITTEN + 1))
  else
    echo "  [FAIL]   ${path}/${key}" >&2
    FAILED=$((FAILED + 1))
    _fail "failed writing ${path}/${key}; aborting migration. Re-run with --dry-run to audit remaining writes."
  fi
}

# ----------------------------------------------------------------------------
# Source readers (structural; no plaintext leaks to terminal)
# ----------------------------------------------------------------------------

# config.yaml: plaintext key read via yq. Missing keys return empty (set_secret skips).
cfg() {
  yq -r ".$1 // \"\"" "$REPO_ROOT/config.yaml"
}

# SOPS-encrypted YAML file: decrypt in-memory, extract one key.
# Decryption failure is fatal (likely missing Age key or corrupt file).
sops_val() {
  # $1 = path relative to repo root, $2 = key name
  local decrypted
  if ! decrypted="$(sops -d "$REPO_ROOT/$1" 2>&1)"; then
    _fail "sops decryption failed for $1: $decrypted"
  fi
  printf '%s' "$decrypted" | yq -r ".$2 // \"\""
}

# SOPS-encrypted JSON file: decrypt in-memory, return full content verbatim.
sops_blob() {
  local decrypted
  if ! decrypted="$(sops -d "$REPO_ROOT/$1" 2>&1)"; then
    _fail "sops decryption failed for $1: $decrypted"
  fi
  printf '%s' "$decrypted"
}

# Bitwarden bootstrap item (RBW_PROFILE=bootstrap already exported).
# Missing items are fatal — every Bitwarden item this script references is required.
bw() {
  local value
  if ! value="$(rbw get "homelab/bootstrap/$1" 2>&1)"; then
    _fail "Bitwarden item homelab/bootstrap/$1 not found (rbw: $value). Create it first."
  fi
  if [ -z "$value" ]; then
    _fail "Bitwarden item homelab/bootstrap/$1 returned an empty value."
  fi
  printf '%s' "$value"
}

# Parse a single `<key> = "<value>"` line from a .tfvars file
tfvar() {
  # $1 = tfvars path relative to repo root, $2 = key
  awk -F'"' -v k="$2" '$0 ~ "^[[:space:]]*"k"[[:space:]]*="{print $2; exit}' \
    "$REPO_ROOT/$1"
}

# ----------------------------------------------------------------------------
# Inventory — mirrors A.5 inventory table in secret-management-redesign.md
# ----------------------------------------------------------------------------

mode_banner="$($DRY_RUN && echo 'DRY-RUN' || echo 'LIVE')"
echo ""
echo "=========================================="
echo "Infisical population — mode: $mode_banner"
echo "  API:     $INFISICAL_API_URL"
echo "  Env:     $ENV_SLUG"
echo "  Project: $INFISICAL_PROJECT_ID"
echo "=========================================="

echo ""
echo "[/kubernetes/cert-manager]"
set_secret /kubernetes/cert-manager cloudflare_api_token "$(cfg cloudflare_api_token)"

echo ""
echo "[/kubernetes/argocd]"
# admin_password_hash: pre-hashed bcrypt provided by operator via Bitwarden.
# NOTE: requires a new Bitwarden item homelab/bootstrap/argocd-admin-password-hash
# holding the output of: htpasswd -bnBC 10 "" <password> | tr -d ':\n' | sed 's/$2y/$2a/'
set_secret /kubernetes/argocd admin_password_hash "$(bw argocd-admin-password-hash)"

echo ""
echo "[/kubernetes/glitchtip]"
# Raw components only — InfisicalSecret CRD composes DATABASE_URL / MAINTENANCE_DATABASE_URL
# / REDIS_URL via spec.template.data at operator reconcile time.
set_secret /kubernetes/glitchtip SECRET_KEY            "$(cfg glitchtip_secret_key)"
set_secret /kubernetes/glitchtip POSTGRES_USER         "$(cfg glitchtip_postgres_user)"
set_secret /kubernetes/glitchtip POSTGRES_PASSWORD     "$(cfg glitchtip_postgres_password)"
set_secret /kubernetes/glitchtip POSTGRES_DB           "$(cfg glitchtip_postgres_db)"
set_secret /kubernetes/glitchtip DB_HOST               "$(cfg glitchtip_data_ip)"
set_secret /kubernetes/glitchtip DB_PORT               "$(cfg glitchtip_postgres_port)"
set_secret /kubernetes/glitchtip REDIS_PASSWORD        "$(cfg glitchtip_redis_password)"
set_secret /kubernetes/glitchtip REDIS_PORT            "$(cfg glitchtip_redis_port)"
set_secret /kubernetes/glitchtip EMAIL_URL             "$(cfg glitchtip_email_url)"
set_secret /kubernetes/glitchtip ADMIN_USERNAME        "$(cfg glitchtip_admin_username)"
set_secret /kubernetes/glitchtip ADMIN_EMAIL           "$(cfg glitchtip_admin_email)"
set_secret /kubernetes/glitchtip ADMIN_PASSWORD        "$(cfg glitchtip_admin_password)"
set_secret /kubernetes/glitchtip BOOTSTRAP_MCP_TOKEN   "$(cfg glitchtip_bootstrap_mcp_token)"

echo ""
echo "[/kubernetes/deeptutor]"
set_secret /kubernetes/deeptutor LLM_BINDING_API_KEY        "$(cfg deeptutor_llm_api_key)"
set_secret /kubernetes/deeptutor EMBEDDING_BINDING_API_KEY  "$(cfg deeptutor_embedding_api_key)"
set_secret /kubernetes/deeptutor PERPLEXITY_API_KEY         "$(cfg deeptutor_perplexity_api_key)"

echo ""
echo "[/ansible/cloudflare]"
# tunnel_json: full JSON blob, materialized by Ansible cloudflare role at runtime.
set_secret /ansible/cloudflare tunnel_json "$(sops_blob ansible/roles/cloudflare/files/cloudflare-tunnel.sops.json)"
# email: SECRET, no current consumer; retained per operator direction for future use.
set_secret /ansible/cloudflare email "$(cfg cloudflare_email)"

echo ""
echo "[/ansible/proxmox]"
# Infisical mirror of Bitwarden bootstrap values; Terraform identity reads via cross-scope.
set_secret /ansible/proxmox cipassword        "$(bw proxmox-cipassword)"
set_secret /ansible/proxmox api_token_id      "$(bw proxmox-api-token-id)"
set_secret /ansible/proxmox api_token_secret  "$(bw proxmox-api-token)"

echo ""
echo "[/ansible/services]"
SERVICES_FILE="ansible/group_vars/services.sops.yaml"
set_secret /ansible/services honcho_postgres_password        "$(sops_val "$SERVICES_FILE" honcho_postgres_password)"
set_secret /ansible/services honcho_redis_password           "$(sops_val "$SERVICES_FILE" honcho_redis_password)"
set_secret /ansible/services honcho_auth_jwt_secret          "$(sops_val "$SERVICES_FILE" honcho_auth_jwt_secret)"
set_secret /ansible/services honcho_webhook_secret           "$(sops_val "$SERVICES_FILE" honcho_webhook_secret)"
set_secret /ansible/services honcho_llm_anthropic_api_key    "$(sops_val "$SERVICES_FILE" honcho_llm_anthropic_api_key)"
set_secret /ansible/services honcho_llm_openai_api_key       "$(sops_val "$SERVICES_FILE" honcho_llm_openai_api_key)"
set_secret /ansible/services honcho_llm_gemini_api_key       "$(sops_val "$SERVICES_FILE" honcho_llm_gemini_api_key)"
set_secret /ansible/services honcho_llm_groq_api_key         "$(sops_val "$SERVICES_FILE" honcho_llm_groq_api_key)"
set_secret /ansible/services honcho_sentry_dsn               "$(sops_val "$SERVICES_FILE" honcho_sentry_dsn)"

# Nullable honcho keys — skipped when null/empty by set_secret()
set_secret /ansible/services honcho_llm_openai_compatible_api_key      "$(sops_val "$SERVICES_FILE" honcho_llm_openai_compatible_api_key)" nullable
set_secret /ansible/services honcho_llm_vllm_api_key                   "$(sops_val "$SERVICES_FILE" honcho_llm_vllm_api_key)" nullable
set_secret /ansible/services honcho_vector_store_turbopuffer_api_key   "$(sops_val "$SERVICES_FILE" honcho_vector_store_turbopuffer_api_key)" nullable

echo ""
echo "[/terraform/unifi]"
set_secret /terraform/unifi username              "$(bw unifi-username)"
set_secret /terraform/unifi password              "$(bw unifi-password)"
set_secret /terraform/unifi iot_wlan_passphrase   "$(tfvar terraform/unifi/terraform.tfvars iot_wlan_passphrase)"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

echo ""
echo "=========================================="
echo "Migration summary (mode: $mode_banner):"
printf "  Written: %d\n" "$WRITTEN"
printf "  Skipped: %d\n" "$SKIPPED"
printf "  Failed:  %d\n" "$FAILED"
echo "=========================================="

if $DRY_RUN; then
  echo ""
  echo "Dry run complete — no writes executed."
  echo "Re-run without --dry-run to apply."
fi

exit 0
