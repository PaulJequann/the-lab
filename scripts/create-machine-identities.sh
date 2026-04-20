#!/usr/bin/env bash
# Provision the three machine identities described in plan §A.7:
#   1. Kubernetes Operator Identity   (K8s Auth)        — read /kubernetes/*
#   2. Ansible Identity                (Universal Auth)  — read /ansible/*, /kubernetes/argocd/*, /kubernetes/glitchtip/*
#   3. Terraform Identity              (Universal Auth)  — read /terraform/*, /ansible/proxmox/*
#
# Idempotent: re-running is safe. Existing identities are reused; auth
# attachments are skipped if already configured. Universal Auth client
# secrets are generated only once unless --rotate is passed (in which case
# new secrets replace the rbw-stored values).
#
# Authentication: reads the admin-identity token from the K8s Secret
# infisical/infisical-admin-identity created by A.4.5. No hardcoded creds.
#
# Usage:
#   source scripts/load-bootstrap-secrets.sh
#   export INFISICAL_PROJECT_ID=<the-lab-project-id>
#   scripts/create-machine-identities.sh                # create / refresh
#   scripts/create-machine-identities.sh --rotate       # re-issue UA secrets
#
# Outputs (post-run):
#   - Three machine identities visible in the Infisical UI under the org
#   - Universal-auth client_id / client_secret pairs for Ansible + Terraform
#     written to Bitwarden under homelab/bootstrap/infisical-{ansible,terraform}-client-{id,secret}
#   - K8s Auth identity ID printed to stdout (use for InfisicalSecret CRDs)
#
# Prerequisites: bash 4+, kubectl, jq, curl, rbw (unlocked, RBW_PROFILE=bootstrap).

set -uo pipefail

# ----------------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------------

ROTATE=false
ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
OPERATOR_SA_NAMESPACE="${OPERATOR_SA_NAMESPACE:-infisical-operator}"
OPERATOR_SA_NAME="${OPERATOR_SA_NAME:-infisical-opera-controller-manager}"
KUBERNETES_HOST="${KUBERNETES_HOST:-https://kubernetes.default.svc.cluster.local}"
TOKEN_REVIEWER_NS="${TOKEN_REVIEWER_NS:-infisical}"
TOKEN_REVIEWER_SECRET="${TOKEN_REVIEWER_SECRET:-infisical-token-reviewer-token}"

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------

_fail() { echo "ERROR: $*" >&2; exit 1; }
_log()  { echo "[$(date +%H:%M:%S)] $*" >&2; }

for cmd in kubectl jq curl rbw; do
  command -v "$cmd" >/dev/null 2>&1 || _fail "$cmd not in PATH"
done

[ -n "${INFISICAL_API_URL:-}" ] || \
  _fail "INFISICAL_API_URL not set. Source scripts/load-bootstrap-secrets.sh first."
[ -n "${INFISICAL_PROJECT_ID:-}" ] || \
  _fail "INFISICAL_PROJECT_ID not set. Export the the-lab project's ID."

if ! RBW_PROFILE=bootstrap rbw unlocked >/dev/null 2>&1; then
  _fail "rbw agent is locked. Run: RBW_PROFILE=bootstrap rbw unlock"
fi
export RBW_PROFILE=bootstrap

_log "[auth] Reading admin-identity token from infisical/infisical-admin-identity..."
ADMIN_TOKEN="$(
  kubectl -n infisical get secret infisical-admin-identity \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d
)" || _fail "could not read infisical-admin-identity Secret"
[ -n "$ADMIN_TOKEN" ] || _fail "admin token is empty"

API="${INFISICAL_API_URL%/}"
[ "${API: -4}" = "/api" ] || API="${API}/api"

# ----------------------------------------------------------------------------
# HTTP helpers
# ----------------------------------------------------------------------------

_api() {
  # _api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  local args=( -sS -X "$method" -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" )
  if [ -n "$body" ]; then args+=( -d "$body" ); fi
  curl "${args[@]}" "${API}${path}"
}

_check() {
  # Echo body unchanged unless it parses as an Infisical error envelope.
  local body="$1" ctx="$2"
  if jq -e '.statusCode // .error // .message' >/dev/null 2>&1 <<<"$body"; then
    if jq -e '.statusCode and (.statusCode != 200 and .statusCode != 201)' >/dev/null 2>&1 <<<"$body"; then
      echo "$body" >&2
      _fail "$ctx failed"
    fi
  fi
  printf '%s' "$body"
}

# ----------------------------------------------------------------------------
# Resolve org from project
# ----------------------------------------------------------------------------

_log "[discover] Looking up org for project ${INFISICAL_PROJECT_ID}..."
PROJECT_JSON="$(_api GET "/v1/workspace/${INFISICAL_PROJECT_ID}")"
ORG_ID="$(jq -r '.workspace.orgId // .workspace.organization // empty' <<<"$PROJECT_JSON")"
[ -n "$ORG_ID" ] || { echo "$PROJECT_JSON" >&2; _fail "could not resolve orgId from project"; }
_log "[discover] orgId=${ORG_ID} env=${ENV_SLUG}"

# ----------------------------------------------------------------------------
# Identity helpers
# ----------------------------------------------------------------------------

_get_identity_id_by_name() {
  # Lookup identity by name within the org. Returns empty if not found.
  local name="$1"
  local resp
  resp="$(_api GET "/v2/organizations/${ORG_ID}/identity-memberships?limit=100")"
  jq -r --arg n "$name" '
    (.identityMemberships // .identities // []) | .[] |
    select((.identity.name // .name) == $n) |
    (.identity.id // .id)
  ' <<<"$resp" | head -n1
}

_create_identity() {
  # Idempotent: create only if absent. Echoes identityId.
  local name="$1"
  local existing
  existing="$(_get_identity_id_by_name "$name")"
  if [ -n "$existing" ]; then
    _log "  [identity] '${name}' already exists (id=${existing})"
    printf '%s' "$existing"; return 0
  fi
  _log "  [identity] creating '${name}'..."
  local body resp
  body="$(jq -c -n --arg n "$name" --arg o "$ORG_ID" '{name:$n, organizationId:$o, role:"no-access"}')"
  resp="$(_api POST "/v1/identities" "$body")"
  resp="$(_check "$resp" "create identity ${name}")"
  jq -r '.identity.id' <<<"$resp"
}

_attach_to_project() {
  local id="$1"
  _log "  [project] attaching ${id} to project ${INFISICAL_PROJECT_ID}..."
  local resp
  resp="$(_api POST "/v1/projects/${INFISICAL_PROJECT_ID}/identity-memberships/${id}" '{"role":"no-access"}')"
  # Already-attached returns 400 with a recognisable message — treat as OK
  if jq -e '.statusCode == 400 and (.message // "" | tostring | test("already"; "i"))' >/dev/null 2>&1 <<<"$resp"; then
    _log "  [project] already attached"
    return 0
  fi
  _check "$resp" "attach identity ${id} to project" >/dev/null
}

_add_privilege() {
  # _add_privilege identityId slug "[<perm-json>,...]"
  local id="$1" slug="$2" perms="$3"
  local body resp
  body="$(jq -c -n --arg id "$id" --arg p "$INFISICAL_PROJECT_ID" --arg s "$slug" --argjson perms "$perms" \
    '{identityId:$id, projectId:$p, slug:$s, type:{isTemporary:false}, permissions:$perms}')"
  resp="$(_api POST "/v2/identity-project-additional-privilege" "$body")"
  if jq -e '.statusCode == 400 and (.message // "" | tostring | test("exists|duplicate"; "i"))' >/dev/null 2>&1 <<<"$resp"; then
    _log "    [privilege] '${slug}' already exists"
    return 0
  fi
  _check "$resp" "create privilege ${slug}" >/dev/null
  _log "    [privilege] '${slug}' created"
}

_grant_read_paths() {
  # Build a permissions array granting `read` + `describe-secret` on a list of
  # secret-path globs scoped to ENV_SLUG. Then create one privilege per path
  # so later edits are surgical.
  local id="$1"; shift
  for path_glob in "$@"; do
    local slug
    slug="read-$(printf '%s' "$path_glob" | tr '/*' '--' | sed 's/^-*//;s/-*$//')"
    local perms
    perms="$(jq -c -n --arg env "$ENV_SLUG" --arg path "$path_glob" '
      [
        {subject:"secrets",         action:"read",           conditions:{environment:$env, secretPath:{"$glob":$path}}},
        {subject:"secrets",         action:"describeSecret", conditions:{environment:$env, secretPath:{"$glob":$path}}},
        {subject:"secret-folders",  action:"read",           conditions:{environment:$env, secretPath:{"$glob":$path}}}
      ]')"
    _add_privilege "$id" "$slug" "$perms"
  done
}

# ----------------------------------------------------------------------------
# 1. Kubernetes Operator Identity (K8s Auth)
# ----------------------------------------------------------------------------

_log "[1/3] Kubernetes Operator Identity"
OP_ID="$(_create_identity "k8s-operator")"
_attach_to_project "$OP_ID"

_log "  [k8s-auth] waiting for token-reviewer JWT in ${TOKEN_REVIEWER_NS}/${TOKEN_REVIEWER_SECRET}..."
for _ in $(seq 1 30); do
  TR_JWT="$(kubectl -n "$TOKEN_REVIEWER_NS" get secret "$TOKEN_REVIEWER_SECRET" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$TR_JWT" ] && break
  sleep 2
done
[ -n "$TR_JWT" ] || _fail "token-reviewer Secret never populated"

# Configure K8s Auth (POST is upsert per the operator docs — re-running updates)
K8S_BODY="$(jq -c -n \
  --arg host "$KUBERNETES_HOST" \
  --arg ns "$OPERATOR_SA_NAMESPACE" \
  --arg sa "$OPERATOR_SA_NAME" \
  --arg jwt "$TR_JWT" \
  '{kubernetesHost:$host, allowedNamespaces:$ns, allowedNames:$sa, allowedAudience:"", tokenReviewerJwt:$jwt, tokenReviewMode:"api"}')"
RESP="$(_api POST "/v1/auth/kubernetes-auth/identities/${OP_ID}" "$K8S_BODY")"
if jq -e '.statusCode == 400 and (.message // "" | tostring | test("already"; "i"))' >/dev/null 2>&1 <<<"$RESP"; then
  _log "  [k8s-auth] already attached — updating config"
  RESP="$(_api PATCH "/v1/auth/kubernetes-auth/identities/${OP_ID}" "$K8S_BODY")"
fi
_check "$RESP" "attach k8s-auth to operator identity" >/dev/null
_log "  [k8s-auth] configured (allowedNamespaces=${OPERATOR_SA_NAMESPACE}, allowedNames=${OPERATOR_SA_NAME})"

_grant_read_paths "$OP_ID" "/kubernetes/**" "/canary/**"

echo ""
echo "==> K8s Operator identity ID: ${OP_ID}"
echo "    (use this in InfisicalSecret CRDs as authentication.kubernetesAuth.identityId)"
echo ""

# ----------------------------------------------------------------------------
# 2 + 3. Universal Auth identities
# ----------------------------------------------------------------------------

_attach_universal_auth() {
  local id="$1"
  local resp
  resp="$(_api POST "/v1/auth/universal-auth/identities/${id}" '{}')"
  if jq -e '.statusCode == 400 and (.message // "" | tostring | test("already"; "i"))' >/dev/null 2>&1 <<<"$resp"; then
    _log "  [ua] already attached — fetching existing config"
    resp="$(_api GET "/v1/auth/universal-auth/identities/${id}")"
  fi
  _check "$resp" "attach universal auth" >/dev/null
  jq -r '.identityUniversalAuth.clientId' <<<"$resp"
}

_get_or_create_client_secret() {
  # Echoes "<id>:<value>" for the managed client secret. If --rotate or no
  # managed secret exists, generates a new one (value only available on
  # creation; old secrets are revoked).
  local id="$1" marker="managed-by-create-machine-identities-sh"
  local list resp existing_id
  list="$(_api GET "/v1/auth/universal-auth/identities/${id}/client-secrets")"
  existing_id="$(jq -r --arg m "$marker" '
    (.clientSecretData // []) | .[] |
    select(.description == $m and (.isClientSecretRevoked // false) == false) |
    .id' <<<"$list" | head -n1)"

  if [ -n "$existing_id" ] && [ "$ROTATE" = "false" ]; then
    _log "  [ua] reusing managed client secret (id=${existing_id}); pass --rotate to issue a new one"
    printf '%s:KEEP' "$existing_id"
    return 0
  fi

  if [ -n "$existing_id" ] && [ "$ROTATE" = "true" ]; then
    _log "  [ua] revoking old managed client secret (id=${existing_id})"
    _api POST "/v1/auth/universal-auth/identities/${id}/client-secrets/${existing_id}/revoke" '{}' >/dev/null || true
  fi

  _log "  [ua] generating new client secret"
  resp="$(_api POST "/v1/auth/universal-auth/identities/${id}/client-secrets" \
    "$(jq -c -n --arg d "$marker" '{description:$d, ttl:0, numUsesLimit:0}')")"
  resp="$(_check "$resp" "create client secret")"
  local sid="$(jq -r '.clientSecretData.id' <<<"$resp")"
  local sval="$(jq -r '.clientSecret' <<<"$resp")"
  printf '%s:%s' "$sid" "$sval"
}

_rbw_set() {
  # rbw add/edit only invoke $EDITOR when stdin is a TTY. Two issues:
  #   1. EDITOR must be an exec'able binary (no shell expansion), so we
  #      drop a tiny wrapper script that copies our pre-populated value
  #      file over the temp file rbw passes as $1.
  #   2. Bash command tooling and CI environments don't have a TTY, so
  #      we wrap the rbw call in `script(1)` to fake one.
  local entry="$1" value="$2"
  if [ "$value" = "KEEP" ]; then
    _log "  [rbw] ${entry} unchanged (existing secret reused)"
    return 0
  fi
  local tmp helper subcmd
  tmp="$(mktemp)"
  helper="$(mktemp)"
  printf '%s\n' "$value" > "$tmp"
  cat > "$helper" <<WRAP
#!/usr/bin/env sh
cp "${tmp}" "\$1"
WRAP
  chmod +x "$helper"
  if rbw get "$entry" >/dev/null 2>&1; then
    _log "  [rbw] updating ${entry}"
    subcmd="edit"
  else
    _log "  [rbw] creating ${entry}"
    subcmd="add"
  fi
  # Force a PTY so rbw invokes the editor.
  EDITOR="$helper" script -q -c "EDITOR='$helper' RBW_PROFILE='${RBW_PROFILE:-default}' rbw $subcmd '$entry'" /dev/null >/dev/null
  shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
  rm -f "$helper"
}

_provision_ua_identity() {
  # _provision_ua_identity NAME RBW_PREFIX PATH_GLOB...
  local name="$1" prefix="$2"; shift 2
  _log "[$3/3] ${name}"   # caller injects the index in $3 — overridden below
  local id client_id sec sid sval
  id="$(_create_identity "$name")"
  _attach_to_project "$id"
  client_id="$(_attach_universal_auth "$id")"
  _grant_read_paths "$id" "$@"
  sec="$(_get_or_create_client_secret "$id")"
  sid="${sec%%:*}"; sval="${sec#*:}"
  _rbw_set "homelab/bootstrap/infisical-${prefix}-client-id" "$client_id"
  _rbw_set "homelab/bootstrap/infisical-${prefix}-client-secret" "$sval"
  echo ""
  echo "==> ${name} identity ID: ${id}"
  echo "    client_id  -> rbw: homelab/bootstrap/infisical-${prefix}-client-id"
  echo "    client_sec -> rbw: homelab/bootstrap/infisical-${prefix}-client-secret"
  echo ""
}

_log "[2/3] Ansible Identity (Universal Auth)"
ANS_ID="$(_create_identity "ansible")"
_attach_to_project "$ANS_ID"
ANS_CLIENT_ID="$(_attach_universal_auth "$ANS_ID")"
_grant_read_paths "$ANS_ID" "/ansible/**" "/kubernetes/argocd/**" "/kubernetes/glitchtip/**"
ANS_SEC="$(_get_or_create_client_secret "$ANS_ID")"
ANS_SID="${ANS_SEC%%:*}"; ANS_SVAL="${ANS_SEC#*:}"
_rbw_set "homelab/bootstrap/infisical-ansible-client-id" "$ANS_CLIENT_ID"
_rbw_set "homelab/bootstrap/infisical-ansible-client-secret" "$ANS_SVAL"
echo ""
echo "==> Ansible identity ID: ${ANS_ID}"
echo ""

_log "[3/3] Terraform Identity (Universal Auth)"
TF_ID="$(_create_identity "terraform")"
_attach_to_project "$TF_ID"
TF_CLIENT_ID="$(_attach_universal_auth "$TF_ID")"
_grant_read_paths "$TF_ID" "/terraform/**" "/ansible/proxmox/**"
TF_SEC="$(_get_or_create_client_secret "$TF_ID")"
TF_SID="${TF_SEC%%:*}"; TF_SVAL="${TF_SEC#*:}"
_rbw_set "homelab/bootstrap/infisical-terraform-client-id" "$TF_CLIENT_ID"
_rbw_set "homelab/bootstrap/infisical-terraform-client-secret" "$TF_SVAL"
echo ""
echo "==> Terraform identity ID: ${TF_ID}"
echo ""

_log "Done."
echo ""
echo "Summary:"
echo "  Operator (K8s Auth)   : ${OP_ID}"
echo "  Ansible (Universal)   : ${ANS_ID}"
echo "  Terraform (Universal) : ${TF_ID}"
echo ""
echo "Next: scripts/create-machine-identities.sh outputs above are the IDs you"
echo "      hardcode into InfisicalSecret CRD manifests (operator) and pass via"
echo "      INFISICAL_CLIENT_ID/SECRET to ansible + terraform via rbw lookup."
