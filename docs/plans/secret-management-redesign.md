# Secret Management & Template Pipeline Redesign

## Context

The current secrets management in the-lab uses a multi-stage encryption pipeline (config.yaml -> makejinja templates -> SOPS + kubeseal) with three different secret types (SOPS-encrypted YAML, Sealed Secrets, env vars) and five different tools (age, sops, kubeseal, makejinja plugin, envsubst). This has become messy and hard to maintain.

The goal is twofold:

1. **Replace the entire secret pipeline** with self-hosted Infisical as a single source of truth for secrets consumed by Kubernetes apps, Ansible roles, and Terraform configs
2. **Eliminate the makejinja template pipeline** and config.yaml, replacing all `.j2` templates with static manifests

Infisical is not just for this repo — it will be core network infrastructure used by all apps and services on the homelab network.

## Key Decisions

| #   | Decision             | Resolution                                                                        |
| --- | -------------------- | --------------------------------------------------------------------------------- |
| 1   | DR strategy          | TrueNAS PostgreSQL backups on a dedicated Infisical host                          |
| 2   | Shared fate          | Dedicated Infisical LXC — isolated from GlitchTip and all app databases           |
| 3   | Bootstrap trust root | Bitwarden cloud stores the minimal Layer 0 bootstrap secret set                   |
| 4   | Vaultwarden role     | Vaultwarden is a normal homelab app, not a bootstrap dependency                   |
| 5   | Bootstrap UX         | One idempotent Ansible command; no required manual kubectl secret creation        |
| 6   | Why Infisical        | UX + simplicity wins for single-operator homelab over Vault/OpenBao               |
| 7   | Migration order      | Retire ARC first; keep deeptutor in place for now; use cert-manager as the first secret migration target and defer deeptutor redesign work to a later follow-up |
| 8   | Project organization | Single Infisical project with path-based organization, split later if needed      |
| 9   | config.yaml fate     | Eliminate config.yaml + makejinja entirely (Phase B)                              |
| 10  | Phasing              | Two-phase: Phase A replaces secrets and removes SOPS; Phase B removes templates   |
| 11  | ArgoCD ownership     | Exclude operator-managed K8s Secrets from ArgoCD sync                             |
| 12  | SOPS/Age fate        | Remove SOPS and Age from this repo completely during Phase A                      |
| 13  | Redis auth           | Infisical LXC Redis uses `requirepass`; `infisical_redis_password` in Layer 0     |
| 14  | Network encryption   | Plaintext PostgreSQL/Redis on private network (same pattern as glitchtip_data)    |
| 15  | Auth identities      | 3 separate: K8s Auth (operator), Universal Auth (Ansible), Universal Auth (Terraform) — each path-scoped |
| 16  | Identity IDs         | Hardcoded in static InfisicalSecret YAML manifests (not templated)                |
| 17  | ArgoCD exclusion     | Label-based via `app.kubernetes.io/managed-by: infisical-operator` propagated from CRD |
| 18  | BW CLI session       | Pre-extract to env vars via wrapper script; playbook never touches bw directly    |
| 19  | ArgoCD secrets       | Bootstrap-only via Ansible Infisical lookup, NOT operator-managed InfisicalSecrets |
| 20  | Rollback strategy    | Accept K8s Secret persistence; no warm standby. Restore from backup if needed     |
| 21  | Monitoring           | Permanent canary InfisicalSecret + ArgoCD health; no additional monitoring infra  |
| 22  | Infisical LXC IP     | 10.0.10.85 (sequential with glitchtip .83, honcho .84)                            |

## Architecture

### Trust Layers

The bootstrap chain has to terminate outside the homelab. Self-hosted systems such as Vaultwarden and self-hosted Infisical cannot serve as the trust root for rebuilding the lab after a full outage.

Layer 0 is Bitwarden cloud.

- Holds only the minimal bootstrap secret set needed to stand up Infisical.
- Holds any workstation-run credential that cannot be stored inside Infisical itself, such as post-bootstrap machine identity credentials for Ansible and Terraform.
- Lives outside the homelab and survives total homelab loss.
- Is accessed from the workstation through the Bitwarden CLI during bootstrap runs.

Layer 1 is self-hosted Infisical.

- Runs on Kubernetes.
- Uses a dedicated Infisical data host for PostgreSQL and Redis.
- Becomes the source of truth for homelab operational secrets.

Layer 2 is everything else.

- Kubernetes apps
- Ansible roles and playbooks
- Terraform configurations
- Vaultwarden and other self-hosted applications

### Bootstrap Chain

The only secrets that exist outside Infisical are the minimal bootstrap secrets stored in Bitwarden cloud:

```
Bitwarden cloud (Layer 0)
    ├── proxmox_api_token
    ├── infisical_db_password
    ├── infisical_redis_password
    ├── infisical_encryption_key
    ├── infisical_auth_secret
    ├── ansible_machine_identity_client_id/client_secret
    ├── terraform_machine_identity_client_id/client_secret
    └── any remaining workstation-run credential that cannot live in Infisical
      │
      ▼
Workstation unlocks Bitwarden CLI
      │
      ▼
Ansible injects env vars into bootstrap run
      │
      ├── Provisions Infisical data host
      ├── Creates infisical namespace
      ├── Creates infisical-bootstrap Secret
      └── Applies or syncs Infisical ArgoCD application
        │
        ▼
      Infisical starts (Layer 1)
        │
        ├── Infisical Operator → K8s Secrets
        ├── Ansible lookups → playbook vars
        └── Terraform provider → ephemeral resources
```

There is no bootstrap.sops.yaml, no Age key, and no encrypted bootstrap artifact in this repo.

### Infrastructure

```
Dedicated Infisical LXC (10.0.10.85)
    ├── PostgreSQL (Infisical database only)
    ├── Redis
    └── Backups → TrueNAS NFS (independent schedule)

K8s Cluster
    ├── Infisical Server (Helm chart, connects to dedicated LXC)
    ├── Infisical Operator (syncs secrets → native K8s Secrets)
    └── Canary InfisicalSecret for end-to-end health checks
```

### Infisical Project Organization

Single project, path-based:

```
Project: homelab
├── Environment: prod
│   ├── /kubernetes
│   │   ├── /cert-manager     (cloudflare_api_token, cloudflare_email)
│   │   ├── /argocd           (admin_password, repo_credentials, ghcr_registry)
│   │   └── /glitchtip        (db_url, redis_url, secret_key, admin_*, ...)
│   ├── /ansible
│   │   ├── /cloudflare       (email, api_token, domain, tunnel_name)
│   │   ├── /proxmox          (lxc_initial_password)
│   │   └── /services         (honcho_*, glitchtip_* service-level secrets)
│   └── /terraform
│       ├── /cloudflare       (email, apikey, domain)
│       ├── /unifi            (password, api_url, wlan_passphrase)
│       └── /proxmox          (api_token_secret, password, cipassword)
```

Machine identities scoped to paths — each consumer only sees what it needs.

### Vaultwarden Positioning

Vaultwarden remains useful, but it is not part of bootstrap.

- Use Vaultwarden for personal and household credentials, browser autofill, and other non-bootstrap secrets.
- Do not depend on Vaultwarden to recover self-hosted Infisical.
- Treat Vaultwarden as a normal consumer of the homelab secret system, not the root of trust.

### ArgoCD Integration

ArgoCD manages InfisicalSecret CRD manifests (they live in git). The Infisical Operator creates the actual K8s Secrets. To prevent ownership conflicts:

- Add operator-managed K8s Secrets to ArgoCD's resource exclusion list
- ArgoCD owns the CRD lifecycle; Operator owns the Secret lifecycle
- No pruning or drift detection on operator-managed Secrets

---

## Phase 0: Pre-Migration Cleanup ✅

Remove apps that are being decommissioned before starting Infisical work. This reduces migration scope and eliminates dead work.

**Status:** Phase 0 is complete. ARC has been retired from Git, ArgoCD, and the live cluster. DeepTutor remains in place intentionally, and its current deployment health is good enough that the rest of the plan does not need to wait on a redesign or upgrade.

### 0.1 Retire ARC completely ✅

Delete:

- `kubernetes/infrastructure/arc-runners/` (entire directory)
- `templates/kubernetes/infrastructure/arc-runners/` (entire directory)
- `kubernetes/infrastructure/arc-controller/` (entire directory)
- `templates/kubernetes/infrastructure/arc-controller/` (entire directory)
- ARC chart repository entries from the infrastructure ArgoCD project's `spec.sourceRepos`
- the ARC-only ArgoCD repository Secret for `ghcr.io/actions/actions-runner-controller-charts`
- all `arc_*` variables from `config.yaml`
- tracked docs and operator guidance that still describe ARC as a live system

Note:

- The current infrastructure AppProject uses a wildcard destination, so there is no dedicated ARC destination entry to remove.
- If any ARC runner scale set, runner registration, or related GitHub-side configuration still exists, remove that external state as part of Phase 0.

**Important teardown lesson from ARC:**

For controller-owned systems, Git removal is necessary but not always sufficient. ARC creates custom resources with controller-owned finalizers. If the runner scale set resources are still present when the ARC controller disappears, Kubernetes can leave the namespaces stuck in `Terminating` while it waits for cleanup work that no longer has a controller to perform it.

**Recommended live teardown order:**

1. Remove the Git-managed ARC applications and repositories.
2. Confirm the live ARC custom resources are actually disappearing.
3. Only after the scale set and listener resources are gone, confirm the ARC namespaces disappear.
4. If the namespaces stick in `Terminating`, inspect finalizers before assuming the cluster is just slow.

**Monitor ARC teardown:**

```bash
argocd app list | grep -Ei 'arc|runner' || true
kubectl get applications.argoproj.io -A | grep -Ei 'arc|runner' || true

kubectl get autoscalinglisteners.actions.github.com -A 2>/dev/null || true
kubectl get autoscalingrunnersets.actions.github.com -A 2>/dev/null || true
kubectl get ephemeralrunnersets.actions.github.com -A 2>/dev/null || true

kubectl get ns arc-controller arc-system arc-runners 2>/dev/null || true
kubectl get all,sa,role,rolebinding,secret,cm,pvc -A | grep -Ei 'arc-|gha-rs|runner' || true
argocd repo list | grep -Ei 'actions-runner-controller|arc' || true
```

**If an ARC namespace is stuck in `Terminating`, inspect why:**

```bash
kubectl get ns arc-system -o yaml | sed -n '/^status:/,$p'
kubectl get ns arc-runners -o yaml | sed -n '/^status:/,$p'
```

If the status mentions remaining ARC custom resources and ARC finalizers, and the controller is already gone, clear the finalizers on the blocking resources so Kubernetes can finish deletion.

**Example stuck-finalizer cleanup:**

```bash
kubectl -n arc-system patch autoscalinglistener.actions.github.com/<listener-name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'

kubectl -n arc-runners patch autoscalingrunnerset.actions.github.com/<scale-set-name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'

kubectl -n arc-runners patch ephemeralrunnerset.actions.github.com/<runner-set-name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'

kubectl -n arc-runners patch serviceaccount/<name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n arc-runners patch role/<name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n arc-runners patch rolebinding/<name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
```

Only do this after confirming the system is intentionally being retired and the controller is no longer available to clear the finalizers itself.

### 0.2 Keep deeptutor in place and defer redesign work ✅

Keep deeptutor in the homelab for now, but do not let deeptutor upgrade/evaluation block the rest of the secret-management redesign. Deeptutor can be revisited later, after Infisical and the new secret-management patterns are established elsewhere in the cluster.

Keep:

- `kubernetes/apps/deeptutor/`
- `templates/kubernetes/apps/deeptutor/`
- deeptutor entries in the ArgoCD apps project
- `deeptutor_*` variables in `config.yaml` until the app's post-upgrade configuration contract is confirmed

Do now:

- Keep the current deeptutor deployment healthy while the broader plan moves forward.
- Preserve the existing deeptutor manifests, config, secrets, workflow, and namespace until there is a dedicated follow-up for deeptutor.
- Document that deeptutor is intentionally out of the critical path for Phase 0 and the initial Infisical rollout.

Do later, as a separate follow-up:

- Review upstream DeepTutor release notes and deployment changes before changing manifests.
- Upgrade the deployment to the latest upstream release under evaluation at that time.
- Treat the `v1.x` line as a significant app revalidation, not a blind tag bump, because upstream describes it as a major architecture rewrite.
- Pin `deeptutor_image_tag` to the tested release once evaluation succeeds rather than leaving it on `latest`.
- Update manifests, env vars, probes, ports, storage assumptions, and secret references if the upstream runtime contract has changed.
- Decide whether `.github/workflows/deeptutor-builder.yaml` is still needed after the upgrade. The current manifests already point at `ghcr.io/hkuds/deeptutor`, so the custom builder workflow should only survive if there is still a real need for a repo-owned image.

Notes:

- DeepTutor is no longer part of the Phase 0 removal scope.
- DeepTutor is not a blocker for completing Phase 0, Phase A, or the initial Infisical rollout.
- Because `v1.x` may change the application's env var and secret shape, defer DeepTutor's redesign and secret migration work until there is time to evaluate it deliberately.
- If the later evaluation succeeds, DeepTutor becomes a follow-up Kubernetes secret migration candidate instead of part of the current critical path.
- Current baseline check is good enough to defer safely: ArgoCD reports `deeptutor` as `Synced` and `Healthy`, the Kubernetes deployment is `Available=True`, rollout succeeds, the ingress home page returns HTTP `200`, and the backend OpenAPI document is reachable through a direct port-forward.

**Monitor deeptutor while it remains deferred:**

```bash
argocd app get deeptutor
kubectl get applications.argoproj.io -A | grep -Ei 'deeptutor' || true

kubectl -n deeptutor get deploy,pods,svc,ingress,secrets,pvc
kubectl -n deeptutor rollout status deployment/deeptutor --timeout=5m
kubectl -n deeptutor logs deploy/deeptutor --tail=200

curl -sk https://deeptutor.local.bysliek.com/ | head -c 200
```

**Optional direct backend confirmation:**

This is useful when the frontend loads but you want proof that the FastAPI backend is also responding.

```bash
kubectl -n deeptutor port-forward deploy/deeptutor 18001:8001
curl -s http://127.0.0.1:18001/openapi.json | head -c 300
```

If deeptutor becomes unhealthy while it is deferred, inspect the deployment and pod events before deciding whether to upgrade it immediately or leave it for later:

```bash
kubectl -n deeptutor describe deploy deeptutor
kubectl -n deeptutor get events --sort-by=.lastTimestamp | tail -n 30
```

The goal is to distinguish "deeptutor is safely left alone for now" from "deeptutor needs immediate intervention."

### 0.3 Verify ✅

- ArgoCD shows ARC removed / not found, and deeptutor remains synced and healthy on its current deployment
- `task configure` still runs clean
- `arc-runners`, `arc-system`, and `arc-controller` namespaces are gone from the cluster, not merely `Terminating`
- the `deeptutor` namespace is healthy and not stuck in `Terminating`
- No orphaned ARC references remain in templates, config, workflows, or tracked docs; deeptutor references remain intentionally present
- No GitHub-side ARC registrations or scale sets remain
- No ARC custom resources, ARC finalizers, or orphaned ArgoCD repository registrations remain
- The deeptutor follow-up is explicitly deferred and does not gate the rest of the plan

**Current Phase 0 outcome:**

- ARC cleanup is complete in Git, ArgoCD, and the live cluster.
- DeepTutor remains deployed and healthy enough to defer.
- Phase 0 no longer blocks the Infisical rollout.

**Phase 0 completion checks:**

```bash
argocd app list | grep -Ei 'arc|runner' || true
argocd repo list | grep -Ei 'actions-runner-controller|arc' || true
argocd app get deeptutor

kubectl get ns arc-controller arc-system arc-runners 2>/dev/null || true
kubectl get ns deeptutor
kubectl get applications.argoproj.io -A | grep -Ei 'arc|runner' || true
kubectl get applications.argoproj.io -A | grep -Ei 'deeptutor' || true
kubectl get autoscalinglisteners.actions.github.com -A 2>/dev/null || true
kubectl get autoscalingrunnersets.actions.github.com -A 2>/dev/null || true
kubectl get ephemeralrunnersets.actions.github.com -A 2>/dev/null || true
kubectl get all,sa,role,rolebinding,secret,cm,pvc -A | grep -Ei 'arc-|gha-rs|runner' || true
kubectl -n deeptutor get deploy,pods,svc,ingress,secrets,pvc
kubectl -n deeptutor rollout status deployment/deeptutor --timeout=5m
```

---

## Phase A: Infisical Deployment + Secret Migration

### A.1 Define the Bootstrap Contract

The bootstrap contract is the minimum external secret set needed to build Layer 1.

Stored in Bitwarden cloud:

- `proxmox_api_token`
- `infisical_db_password`
- `infisical_redis_password`
- `infisical_encryption_key`
- `infisical_auth_secret`
- `ansible_machine_identity_client_id` / `ansible_machine_identity_client_secret`
- `terraform_machine_identity_client_id` / `terraform_machine_identity_client_secret`
- any remaining bootstrap-only secret still required by the initial provisioning flow

Bootstrap rules:

- Bitwarden cloud is the only external secret dependency.
- No encrypted secret files live in this repo.
- No bootstrap secrets are committed to Git.
- The bootstrap flow must be executable from a clean workstation with Bitwarden CLI access.

**Pre-requisite research (must complete before implementing A.3/A.4):**

- Read the Infisical Helm chart's `values.yaml` to determine the exact `infisical-bootstrap` Secret schema: what keys must it contain, and how does the chart consume them (`envFrom`, `existingSecret`, or inline `infisicalEnv`).
- Document the result as a concrete table: key name, source (Bitwarden item), and injection mechanism.

### A.2 Provision Dedicated Infisical LXC

Create the Infisical host via Ansible, using the Bitwarden-backed bootstrap contract for credentials.

**New Ansible role:** `ansible/roles/infisical_data/`

- Provisions Proxmox LXC (similar pattern to `glitchtip_data`)
- Installs PostgreSQL + Redis
- Creates the `infisical` database and user
- Configures Redis with `requirepass` (password from Layer 0 bootstrap set)
- Configures backups to TrueNAS NFS (independent from GlitchTip backups)
- Network: plaintext PostgreSQL/Redis on private network (same trust boundary as glitchtip_data)

**Host specs:**

- IP: 10.0.10.85
- Cores: 2
- Memory: 1GB
- Disk: 20G on local-lvm

**Backup configuration:**

- Mechanism: `pg_dump` via systemd timer (same pattern as `glitchtip_data` role)
- Schedule: daily (systemd calendar)
- Retention: 14 days to TrueNAS NFS mount
- Backup script, systemd service, and timer managed by Ansible

### A.3 Build a One-Command Bootstrap Flow

Bootstrap should be performed through one idempotent Ansible entrypoint.

**Bitwarden session management:**

A wrapper script (e.g., `scripts/bootstrap-infisical.sh`) handles all Bitwarden interaction upfront. The playbook itself never touches the `bw` CLI directly, which avoids session expiry issues on long-running provisioning runs.

Wrapper script flow:
1. Unlock Bitwarden CLI (`bw unlock`, capture `BW_SESSION`).
2. Extract all Layer 0 values into shell environment variables (`bw get` per item).
3. Run the Ansible playbook with those env vars exported.
4. Lock Bitwarden CLI on completion.

**Playbook steps:**

- Provision the Infisical data host if it does not already exist.
- Create the `infisical` namespace in Kubernetes.
- Create or reconcile the `infisical-bootstrap` Secret in Kubernetes (schema determined by Helm chart research in A.1).
- Only after those prerequisites exist, apply or sync the ArgoCD application for Infisical server.

This replaces the earlier plan to run a one-time `kubectl create secret` command manually.

### A.4 Deploy Infisical Server on K8s

Create `kubernetes/infrastructure/infisical/` with a Helm-based ArgoCD Application.

**Helm chart:** `https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/`

**Helm values:**

```yaml
infisical:
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

postgresql:
  enabled: false # external, on dedicated LXC
redis:
  enabled: false # external, on dedicated LXC

infisicalEnv:
  ENCRYPTION_KEY: <from-bitwarden-bootstrap>
  AUTH_SECRET: <generated-jwt-secret>
  DB_CONNECTION_URI: postgresql://<user>:<pass>@10.0.10.85:5432/infisical
  REDIS_URL: redis://:<redis-password>@10.0.10.85:6379
  SITE_URL: https://infisical.local.bysliek.com
```

**Bootstrap ordering:** The `infisical-bootstrap` Secret must be created by the Ansible bootstrap flow before the ArgoCD application syncs, otherwise the server pods will start without the required connection settings.

**ArgoCD project config:**

- Add Infisical Helm chart repo to `spec.sourceRepos` in infrastructure project
- Add `infisical` namespace to `spec.destinations`

**Ingress:**

- Host: `infisical.local.bysliek.com`
- TLS via cert-manager with existing ClusterIssuer
- IngressClassName: cilium

### A.5 Populate Secrets in Infisical

Manual one-time task: enter all current secret values from the current repo-managed sources into Infisical UI or API, organized by the path structure defined above.

This is a one-time data migration, not a long-term workflow.

**Secret inventory (complete checklist):**

| Infisical Path | Secret Key | Current Source | Migration Step |
|---|---|---|---|
| `/kubernetes/cert-manager` | `cloudflare_api_token` | `config.yaml` | A.9 |
| `/kubernetes/cert-manager` | `cloudflare_email` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `SECRET_KEY` | `config.yaml` (`glitchtip_secret_key`) | A.9 |
| `/kubernetes/glitchtip` | `DATABASE_URL` | composed from `config.yaml` vars | A.9 |
| `/kubernetes/glitchtip` | `MAINTENANCE_DATABASE_URL` | composed from `config.yaml` vars | A.9 |
| `/kubernetes/glitchtip` | `REDIS_URL` | composed from `config.yaml` vars | A.9 |
| `/kubernetes/glitchtip` | `EMAIL_URL` | `config.yaml` (`glitchtip_email_url`) | A.9 |
| `/kubernetes/glitchtip` | `DEFAULT_FROM_EMAIL` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `GLITCHTIP_DOMAIN` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `ADMIN_EMAIL` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `ADMIN_PASSWORD` | `config.yaml` (`glitchtip_admin_password`) | A.9 |
| `/kubernetes/glitchtip` | `BOOTSTRAP_ORG_NAME` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `BOOTSTRAP_PROJECT_NAME` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `BOOTSTRAP_PROJECT_PLATFORM` | `config.yaml` | A.9 |
| `/kubernetes/glitchtip` | `BOOTSTRAP_MCP_TOKEN` | `config.yaml` (`glitchtip_bootstrap_mcp_token`) | A.9 |
| `/kubernetes/glitchtip` | (remaining glitchtip fields) | `config.yaml` | A.9 |
| `/kubernetes/argocd` | `admin_password` | `config.yaml` (`argocd_admin_password`) | A.10 (bootstrap path) |
| `/kubernetes/argocd` | `repo_credentials` | `ansible/roles/argocd/defaults/main.sops.yaml` | A.10 (bootstrap path) |
| `/kubernetes/argocd` | `ghcr_registry` | `ansible/roles/argocd/defaults/main.sops.yaml` | A.10 (bootstrap path) |
| `/ansible/cloudflare` | `email`, `api_token`, `tunnel_json` | `ansible/roles/cloudflare/defaults/main.sops.yaml` | A.10 |
| `/ansible/cert-manager` | (cert-manager role vars) | `ansible/roles/cert-manager/defaults/main.sops.yaml` | A.10 |
| `/ansible/proxmox` | `cipassword` | `ansible/inventory/group_vars/all.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_*`, `glitchtip_*` service secrets | `ansible/group_vars/services.sops.yaml` | A.10 |
| `/terraform/cloudflare` | `cloudflare_email`, `cloudflare_apikey`, `cloudflare_domain` | `terraform/cloudflare/secret.sops.yaml` | A.11 |
| `/terraform/unifi` | `password`, `api_url`, `wlan_passphrase` | `terraform/unifi/` vars | A.11 |
| `/terraform/proxmox` | `api_token_secret`, `password`, `cipassword` | `terraform/proxmox-nodes/` vars | A.11 |

**Deferred (not part of initial population):**

| Infisical Path | Secret Key | Current Source | Notes |
|---|---|---|---|
| `/kubernetes/deeptutor` | `LLM_BINDING_API_KEY` | `config.yaml` | Deferred until deeptutor redesign |
| `/kubernetes/deeptutor` | `EMBEDDING_BINDING_API_KEY` | `config.yaml` | Deferred until deeptutor redesign |
| `/kubernetes/deeptutor` | `PERPLEXITY_API_KEY` | `config.yaml` | Deferred until deeptutor redesign |

### A.6 Deploy Infisical Operator

Create `kubernetes/infrastructure/infisical-operator/` with Helm-based deployment.

**Helm chart:** `https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/` (secrets-operator chart)

**Config:**

```yaml
controllerManager:
  manager:
    env:
      - name: INFISICAL_URL
        value: "http://infisical.infisical.svc.cluster.local:8080"
```

**ArgoCD resource exclusion** (add to ArgoCD configmap):

Use label-based exclusion. The Infisical Operator does not stamp its own identifying label on managed Secrets automatically. Instead, it transfers whatever labels are present on the InfisicalSecret CRD to the managed Secret it creates. The only thing the operator adds automatically is a `secrets.infisical.com/version` annotation.

**Mandatory convention:** Every InfisicalSecret manifest in this repo must carry the label `app.kubernetes.io/managed-by: infisical-operator`. This label propagates to the resulting K8s Secret and enables targeted ArgoCD exclusion.

```yaml
resource.exclusions: |
  - apiGroups: [""]
    kinds: ["Secret"]
    clusters: ["*"]
    labelSelector:
      matchLabels:
        app.kubernetes.io/managed-by: infisical-operator
```

This is precise — only Secrets created by the Infisical Operator (via labeled CRDs) are excluded. ArgoCD's own Secrets in the argocd namespace are unaffected.

**InfisicalSecret manifest template (all CRDs must follow this pattern):**

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: <app>-secrets
  namespace: <namespace>
  labels:
    app.kubernetes.io/managed-by: infisical-operator  # REQUIRED — propagates to managed Secret
spec:
  # ...
```

### A.7 Create Machine Identities

Create three separate machine identities in Infisical, each scoped to the minimum paths it needs:

**1. Kubernetes Operator Identity (K8s Auth)**

- Auth method: Kubernetes Auth (service account tokens)
- Scoped to: `/kubernetes/*` paths in `homelab` project
- Used by: Infisical Operator running in-cluster
- Identity ID is hardcoded into each InfisicalSecret CRD manifest

**2. Ansible Identity (Universal Auth)**

- Auth method: Universal Auth (client_id + client_secret)
- Scoped to: `/ansible/*` and `/kubernetes/argocd/*` paths in `homelab` project
- Used by: Ansible playbooks running on workstation
- `client_id` and `client_secret` stored in Bitwarden cloud Layer 0
- Injected as `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` env vars by the bootstrap wrapper script

**3. Terraform Identity (Universal Auth)**

- Auth method: Universal Auth (client_id + client_secret)
- Scoped to: `/terraform/*` paths in `homelab` project
- Used by: Terraform runs on workstation
- `client_id` and `client_secret` stored in Bitwarden cloud Layer 0
- Passed as `var.infisical_client_id` / `var.infisical_client_secret`

Ansible and Terraform credentials cannot live in Infisical without creating a circular dependency — they must be in Bitwarden.

### A.8 Canary Health Check

Before migrating real applications, create a low-risk canary `InfisicalSecret` in a non-critical namespace.

Purpose:

- Verify the operator can authenticate
- Verify the operator can read from the expected Infisical path
- Verify the target Kubernetes Secret is created and refreshed correctly

The canary InfisicalSecret is **permanent** — it stays deployed after the initial validation and serves as ongoing Infisical health monitoring. If the operator can't reconcile, the canary Secret goes stale, which is visible via ArgoCD and `kubectl describe`.

Do not start real application migration until this canary path works end to end.

### A.9 Migrate Kubernetes Secrets (Per-App)

DeepTutor is part of the retained app set, but its redesign and secret migration are explicitly deferred. Do not let DeepTutor block the initial Infisical rollout or the first wave of Kubernetes secret migrations.

**Migration pattern:**

Before (current):

```jinja2
{{ seal_secret(name="glitchtip-secrets", namespace=glitchtip_namespace, data={
  'SECRET_KEY': glitchtip_secret_key,
  'DATABASE_URL': 'postgresql://...',
}) }}
```

After:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: glitchtip-secrets
  namespace: glitchtip
  labels:
    app.kubernetes.io/managed-by: infisical-operator  # REQUIRED — propagates to managed Secret
spec:
  hostAPI: http://infisical.infisical.svc.cluster.local:8080
  authentication:
    kubernetesAuth:
      identityId: <k8s-operator-identity-id>
      serviceAccountRef:
        name: default
        namespace: glitchtip
  managedSecretReference:
    secretName: glitchtip-secrets
    secretNamespace: glitchtip
    secretType: Opaque
  secretsScope:
    projectSlug: homelab
    envSlug: prod
    secretsPath: /kubernetes/glitchtip
```

The `identityId` is the K8s Operator machine identity created in A.7. It is a public identifier (not a secret) and is hardcoded in each InfisicalSecret manifest.

**Apps to migrate via InfisicalSecret CRDs (in order):**

1. **cert-manager** — 2 secrets (cloudflare_api_token, cloudflare_email). Low secret count, existing certs buffer any issues during migration.
2. **glitchtip** — 10+ secrets (DB, Redis, email, admin creds). Largest migration, most complex.

**Not migrated via InfisicalSecret CRDs:**

- **argo-cd** — ArgoCD secrets are created by the Ansible bootstrap flow (A.10), not by the Infisical Operator. ArgoCD needs its secrets before the operator exists, and having the operator manage Secrets in the argocd namespace risks ownership conflicts with ArgoCD's own secret management. Values are stored in Infisical at `/kubernetes/argocd` for Ansible to look up, but no InfisicalSecret CRD is created in the argocd namespace.

**Deferred follow-up app:**

- **deeptutor** — Revisit after the initial Infisical rollout is proven on other applications. At that point, use the working secret-manager patterns to redesign the app cleanly, upgrade it if desired, and then migrate its secrets with better context.

**Per-app cleanup:**

- Delete the `.secret.yaml.j2` template file
- Delete the rendered SealedSecret YAML
- Remove secret variables from `config.yaml`
- Add InfisicalSecret CRD manifest (static YAML, no template)

### A.10 Migrate Ansible Secrets

**Install:**

```bash
ansible-galaxy collection install infisical.vault
pip install infisicalsdk
```

Split Ansible secret handling into bootstrap-time and steady-state concerns.

Bootstrap-time:

- Use Bitwarden-fed environment variables only for the minimal bootstrap path (Infisical LXC provisioning, namespace creation, bootstrap Secret).
- Do not introduce new repo-encrypted artifacts.

Steady-state:

- Use Infisical lookups for normal Ansible configuration after self-hosted Infisical is healthy.
- Replace `community.sops.load_vars` usage in the current playbooks and roles.
- Cover the current bootstrap password path and the Cloudflare tunnel JSON edge case explicitly so they do not become leftover SOPS holdouts.

**ArgoCD secrets (bootstrap path):**

ArgoCD secrets are NOT managed by the Infisical Operator (see A.9). Instead, the ArgoCD Ansible role uses Infisical lookups to read values from `/kubernetes/argocd` and creates the K8s Secrets directly during the bootstrap/provisioning flow. This means:

- The `argocd` Ansible role replaces its `main.sops.yaml` with Infisical lookups using the Ansible machine identity.
- ArgoCD secrets (admin password, repo creds, GHCR registry) are created as K8s Secrets by Ansible, not by the Infisical Operator.
- ArgoCD continues to manage its own secrets in its namespace without operator interference.

Cloudflare tunnel JSON handling:

- Store the full tunnel JSON document in Infisical as a single secret value.
- During the Ansible run, materialize that value into a temporary or target file on the host at runtime.
- Ensure the role manages the file contents and permissions directly so the JSON blob does not remain as a repo-encrypted artifact.

**Migration pattern:**

Before:

```yaml
# ansible/roles/cloudflare/defaults/main.sops.yaml (SOPS-encrypted)
cloudflare_email: encrypted_value
cloudflare_api_token: encrypted_value
```

After:

```yaml
# ansible/group_vars/all.yml (or role vars)
vars:
  app_secrets: "{{ lookup('infisical.vault.read_secrets',
    as_dict=True,
    universal_auth_client_id=lookup('env','INFISICAL_CLIENT_ID'),
    universal_auth_client_secret=lookup('env','INFISICAL_CLIENT_SECRET'),
    project_id='<project-id>',
    path='/ansible',
    env_slug='prod',
    url='https://infisical.local.bysliek.com') }}"
```

**Roles to migrate:**

- `ansible/roles/argocd/defaults/main.sops.yaml`
- `ansible/roles/cloudflare/defaults/main.sops.yaml`
- `ansible/roles/cert-manager/defaults/main.sops.yaml`
- `ansible/group_vars/services.sops.yaml`
- `ansible/inventory/group_vars/all.sops.yaml`

**Per-role cleanup:**

- Delete `*.sops.yaml` files
- Delete corresponding `.j2` templates
- Remove SOPS-related Ansible configuration

### A.11 Migrate Terraform Secrets

**Add provider:**

```hcl
terraform {
  required_providers {
    infisical = {
      source = "infisical/infisical"
    }
  }
}

provider "infisical" {
  host          = "https://infisical.local.bysliek.com"
  client_id     = var.infisical_client_id
  client_secret = var.infisical_client_secret
}
```

**Use ephemeral resources (Terraform 1.10+):**

```hcl
ephemeral "infisical_secret" "cloudflare_api" {
  name         = "CLOUDFLARE_API_KEY"
  env_slug     = "prod"
  workspace_id = var.infisical_workspace_id
  folder_path  = "/terraform/cloudflare"
}
```

Keeps secrets out of `terraform.tfstate` entirely.

**Configs to migrate:**

- `terraform/cloudflare/secret.sops.yaml`
- `terraform/unifi/` (UniFi controller credentials)
- `terraform/proxmox-nodes/` (Proxmox API tokens)

**Cleanup:**

- Delete all `secret.sops.yaml` in terraform/
- Remove SOPS provider configuration

### A.12 Phase A Cleanup

#### A.12.1 ArgoCD helm-secrets Teardown

The ArgoCD deployment has deep helm-secrets integration that requires a dedicated teardown. This is effectively a full ArgoCD Helm values rewrite.

**Remove from `ansible/roles/argocd/templates/argocd-helm-values.yaml.j2`:**

- All 11 `HELM_SECRETS_*` environment variables (`HELM_SECRETS_CURL_PATH`, `HELM_SECRETS_SOPS_PATH`, `HELM_SECRETS_VALS_PATH`, `HELM_SECRETS_KUBECTL_PATH`, `HELM_SECRETS_BACKEND`, `HELM_SECRETS_VALUES_ALLOW_SYMLINKS`, `HELM_SECRETS_VALUES_ALLOW_ABSOLUTE_PATH`, `HELM_SECRETS_VALUES_ALLOW_PATH_TRAVERSAL`, `HELM_SECRETS_WRAPPER_ENABLED`, `HELM_SECRETS_DECRYPT_SECRETS_IN_TMP_DIR`, `HELM_SECRETS_HELM_PATH`)
- The init container that downloads helm-secrets, SOPS, and Age binaries
- The Age key Secret volume mount (`helm-secrets-private-keys`)
- The custom `helm.sh` wrapper script setup

**Remove from `ansible/roles/argocd/tasks/main.yaml`:**

- The "Create age key secret for helm-secrets" task

**Remove from `ansible/roles/argocd/defaults/main.sops.yaml` (file deleted entirely in A.10):**

- `helm_secrets_age_key_secret_name`
- `helm_secrets_age_key_secret_namespace`

**Remove from `config.yaml`:**

- `helm_secrets_age_key_secret_name`
- `helm_secrets_age_key_name`

**Verify after teardown:**

- ArgoCD starts without the init container or volume mounts
- All existing ArgoCD Applications still sync successfully
- No `helm-secrets-private-keys` Secret remains in the argocd namespace

#### A.12.2 Sealed Secrets Removal

- Delete `kubernetes/core/sealed-secrets/` (entire directory)
- Delete `templates/kubernetes/core/sealed-secrets/` if it exists
- Remove `SealedSecret` from the apps ArgoCD project whitelist (`kubernetes/bootstrap/projects/apps.yaml` line 57)
- Remove `bitnami-labs/sealed-secrets` chart repo from core ArgoCD project's `spec.sourceRepos`
- Delete `.sealed-secrets-public-cert.pem`
- Remove `seal_secret()` function from `makejinja/plugin.py`
- Remove `kubeseal_version` and `sealed_secrets_chart_version` from `config.yaml`

#### A.12.3 SOPS/Age Removal

- Delete root `.sops.yaml` (the `templates/.sops.yaml` and `tmpl/.sops.yaml` survive until Phase B deletes those directories)
- Delete `.taskfiles/SecretTasks.yaml`
- Remove `encrypt-secrets` task from `Taskfile.yml`
- Remove `sops_age_key_file` and any Age-related variables from `config.yaml`
- Remove all secret values from `config.yaml` (non-secret variables remain)

#### A.12.4 Remaining Cleanup

- Remove `build_helm_secrets_path()` function from `makejinja/plugin.py`
- Remove any `community.sops` references from Ansible requirements or configuration
- Verify no `.sops.yaml`, `.secret.yaml`, or Age key references remain in tracked files

**What survives Phase A:**

- `config.yaml` (non-secret variables only)
- `makejinja` (renders non-secret templates, minus `seal_secret` and `build_helm_secrets_path`)
- `templates/.sops.yaml` and `tmpl/.sops.yaml` (dead files, removed with their parent directories in Phase B)

Nothing from the old SOPS or Age toolchain is functional after Phase A.

---

## Phase B: Eliminate Template Pipeline

Replace all remaining `.j2` templates with static files and remove makejinja + config.yaml entirely.

### B.1 Convert Kubernetes Templates

For each file in `templates/kubernetes/**/*.j2`:

- Render the template one final time with current values
- Replace Jinja2 expressions with literal values
- Move from `templates/kubernetes/` to `kubernetes/` (or confirm the static file is already correct)
- Delete the `.j2` source

Non-secret variables (chart versions, domains, CIDRs, namespaces) become hardcoded in the static manifests. Changes to these values mean editing the manifest directly.

### B.2 Convert Ansible Templates

For each file in `templates/ansible/**/*.j2`:

- Render with current values
- Replace with static Ansible vars files
- Non-secret config goes into `group_vars/` or role `defaults/` as plain YAML

### B.3 Convert Terraform Templates

For each file in `templates/terraform/**/*.j2`:

- Render with current values
- Replace with static `.tfvars` or variable definitions

### B.4 Remove Template Infrastructure

Delete:

- `templates/` directory (entire tree)
- `makejinja/` directory (binary + plugin)
- `makejinja.toml`
- `config.yaml`
- Template-related tasks from `Taskfile.yml`
- `task configure` becomes unnecessary (or reduced to any remaining non-secret residual work)

### B.5 Update Taskfile

`task configure` either:

- Gets removed entirely (git push is the deployment mechanism)
- Gets reduced to a minimal task that does not manage encrypted secrets

---

## Resource Footprint

| Component                          | CPU Request                 | Memory Request           | Storage          |
| ---------------------------------- | --------------------------- | ------------------------ | ---------------- |
| Infisical Server (1 replica)       | 100m                        | 256Mi                    | None (stateless) |
| Infisical Operator                 | 50m                         | 64Mi                     | None             |
| Infisical LXC (PostgreSQL + Redis) | 2 cores                     | 1GB                      | 20G              |
| **Total new**                      | ~150m (K8s) + 2 cores (LXC) | ~320Mi (K8s) + 1GB (LXC) | 20G              |

Removed: Sealed Secrets controller (~50m CPU, 64Mi RAM)

---

## Risks & Mitigations

| Risk                                               | Impact   | Mitigation                                                                                                                                       |
| -------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Bitwarden cloud is unavailable during DR           | Medium   | Keep the Layer 0 secret set minimal, document the exact bootstrap set, and verify periodic recovery from a clean workstation.                    |
| Infisical LXC down = no new deployments            | High     | K8s Secrets persist after sync; running pods unaffected. Only new deployments/Ansible/Terraform fail. TrueNAS backups enable restore.            |
| Database corruption/loss                           | Critical | Regular PostgreSQL backups to TrueNAS and a documented rebuild procedure from Bitwarden bootstrap secrets.                                       |
| Infisical project abandoned                        | Medium   | MIT licensed, can fork. InfisicalSecret CRDs create standard K8s Secrets — easy to migrate to another tool.                                      |
| Migration window (both systems running)            | Low      | Phased migration, no big-bang cutover.                                                                                                           |
| Ansible/Terraform need network access to Infisical | Medium   | Infisical is on the local network; Bitwarden handles only the minimal bootstrap set.                                                             |
| Free tier feature limits                           | Low      | Secret rotation, dynamic secrets, PKI are enterprise. Static secret management covers current use case.                                          |
| ArgoCD prunes operator-managed Secrets             | Medium   | Label-based resource exclusion (`app.kubernetes.io/managed-by: infisical-operator`) configured in A.6. All InfisicalSecret CRDs must carry this label. |
| DeepTutor latest release changes runtime contract  | Medium   | Keep DeepTutor out of the initial critical path, then revisit it later once Infisical patterns are established and the app can be redesigned deliberately. |
| One or two SOPS edge cases survive unnoticed       | Medium   | Explicitly track the bootstrap password path and the Cloudflare tunnel JSON until they have a final replacement.                                 |
| Phase B scope creep (template elimination)         | Medium   | Treat Phase B as scheduled follow-through, not optional cleanup, because the main maintenance win comes from removing makejinja and config.yaml. |

---

## Disaster Recovery Runbook

Before Phase A is considered complete, write and maintain a DR runbook that can be executed from a clean workstation.

Minimum checklist:

1. Unlock Bitwarden CLI.
2. Export or inject the Layer 0 bootstrap secrets and workstation machine identity credentials.
3. Run the Infisical bootstrap playbook.
4. Restore PostgreSQL from the latest TrueNAS backup or snapshot.
5. Verify Infisical server health.
6. Verify the canary `InfisicalSecret` reconciles successfully.
7. Confirm Ansible and Terraform workstation lookups can authenticate with their stored machine identities.

This runbook does not need to be fully rehearsal-tested before the migration starts, but it must exist before Phase A is declared complete.

---

## Implementation Order

1. **Phase 0.1:** Retire ARC (controller + runners), including GitHub-side ARC cleanup and live finalizer cleanup if the namespaces stick in `Terminating`
2. **Phase 0.2:** Leave deeptutor in place and explicitly defer its upgrade/evaluation so it does not block the rest of the plan
3. **A.1:** Define the Layer 0 Bitwarden bootstrap contract (includes Helm chart research for bootstrap Secret schema)
4. **A.2-A.3:** Provision the dedicated Infisical data host (10.0.10.85) and build the one-command Ansible bootstrap flow with Bitwarden wrapper script
5. **A.4:** Deploy Infisical server on K8s
6. **A.5:** Populate secrets in Infisical UI/API using the secret inventory checklist
7. **A.6-A.8:** Deploy Infisical Operator with label-based ArgoCD exclusion, create all three machine identities (K8s Auth + 2x Universal Auth), store workstation credentials in Bitwarden, and validate the permanent canary
8. **A.9:** Migrate K8s secrets via InfisicalSecret CRDs: cert-manager → glitchtip (ArgoCD secrets handled separately in A.10)
9. **A.10:** Migrate Ansible secrets (includes ArgoCD bootstrap-path secret migration via Infisical lookups)
10. **A.11:** Migrate Terraform secrets (ephemeral resources, Terraform 1.10+)
11. **A.12.1:** ArgoCD helm-secrets teardown (env vars, init container, Age key volume, wrapper script)
12. **A.12.2:** Sealed Secrets removal (controller, CRD whitelist, sourceRepos, cert, plugin function)
13. **A.12.3:** SOPS/Age removal (root .sops.yaml, SecretTasks, encrypt task, Age variables)
14. **A.12.4:** Final cleanup sweep
15. **DR runbook:** Write the documented recovery checklist before calling Phase A complete
16. **Deferred follow-up:** Revisit deeptutor with the new secret-management patterns in hand; upgrade/evaluate it and migrate its secrets only when it is worth the effort
17. **B.1-B.3:** Convert all remaining templates to static files
18. **B.4-B.5:** Remove makejinja, config.yaml, and template infrastructure (includes deleting templates/.sops.yaml and tmpl/.sops.yaml)

Each phase is independently valuable, but Phase A is not complete until SOPS and Age are gone from this repo.

---

## Verification

**After Phase 0:**

- ArgoCD shows ARC removed / not found, and deeptutor remains synced and healthy on its current deployment
- `task configure` still runs clean
- `arc-controller`, `arc-system`, and `arc-runners` namespaces are gone from the cluster, not merely `Terminating`
- the `deeptutor` namespace is healthy and not stuck in `Terminating`
- repo searches show no live ARC manifest, workflow, config, or tracked-doc references outside intended historical documentation, and deeptutor references match the retained deployment
- no GitHub-side ARC registrations or scale sets remain
- no ARC custom resources, ARC finalizers, or orphaned ArgoCD repository registrations remain
- deeptutor is explicitly deferred and does not block the rest of the plan

**After bootstrap implementation:**

- a clean workstation can unlock Bitwarden CLI and run the bootstrap Ansible command
- the command is idempotent
- the `infisical` namespace and `infisical-bootstrap` Secret exist before the Infisical server pods start

**After operator deployment:**

- the canary `InfisicalSecret` reconciles successfully
- the corresponding Kubernetes Secret is created and refreshed as expected
- the ArgoCD exclusion is narrow enough that ArgoCD-managed Secrets such as its own credentials are still reconciled normally

**After each K8s app migration:**

- `kubectl get secret <name> -n <namespace>` confirms operator synced the secret
- Pod logs show successful startup with correct config
- ArgoCD sync succeeds, app is healthy, ingress responds

**After Ansible migration:**

- current playbooks that used `community.sops.load_vars` succeed in check mode
- at least one real execution path succeeds with the new lookup model

**After Terraform migration:**

- `terraform plan` resolves secrets from Infisical provider
- old repo-managed Terraform secret artifacts are removed

**Phase A complete:**

- All `*.secret.yaml` (SealedSecrets) removed from repo
- `seal_secret()` function removed from makejinja plugin
- No secrets remain in `config.yaml`
- No SOPS or Age configuration remains in the repo
- No `helm-secrets` integration remains in ArgoCD
- No encrypted secret artifacts remain in the repo
- Bootstrap depends on Bitwarden cloud plus the repo, not on Git-stored encrypted files
- A DR runbook exists for recovery from a clean workstation using Bitwarden and TrueNAS backups

**Phase B complete:**

- `templates/` directory deleted
- `makejinja/` directory deleted
- `config.yaml` deleted
- `task configure` removed or reduced to non-secret residual work only
- All manifests are static files edited directly
