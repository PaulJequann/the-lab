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
| 7   | Migration order      | Remove arc-runners + deeptutor first, then cert-manager as first migration target |
| 8   | Project organization | Single Infisical project with path-based organization, split later if needed      |
| 9   | config.yaml fate     | Eliminate config.yaml + makejinja entirely (Phase B)                              |
| 10  | Phasing              | Two-phase: Phase A replaces secrets and removes SOPS; Phase B removes templates   |
| 11  | ArgoCD ownership     | Exclude operator-managed K8s Secrets from ArgoCD sync                             |
| 12  | SOPS/Age fate        | Remove SOPS and Age from this repo completely during Phase A                      |

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
Dedicated Infisical LXC (e.g., 10.0.10.85)
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

## Phase 0: Pre-Migration Cleanup

Remove apps that are being decommissioned before starting Infisical work. This reduces migration scope and eliminates dead work.

### 0.1 Retire ARC completely

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

### 0.2 Remove deeptutor

Delete:

- `kubernetes/apps/deeptutor/` (entire directory)
- `templates/kubernetes/apps/deeptutor/` (entire directory)
- deeptutor entries from ArgoCD project `spec.sourceRepos` and `spec.destinations`
- all `deeptutor_*` variables from `config.yaml`
- `.github/workflows/deeptutor-builder.yaml`
- tracked docs and operator guidance that still describe deeptutor as a live system

Notes:

- Treat deeptutor as fully retired; there is no requirement to preserve app data before removing the app and namespace.
- Delete repo-owned deeptutor GHCR artifacts as part of Phase 0, but do not attempt to remove third-party upstream images.

### 0.3 Verify

- ArgoCD shows ARC and deeptutor removed / not found
- `task configure` still runs clean
- `arc-runners` and `deeptutor` namespaces are gone from the cluster
- No orphaned references remain in templates, config, workflows, or tracked docs outside intended historical documentation
- No GitHub-side ARC registrations or scale sets remain
- No repo-owned deeptutor GHCR artifacts remain

---

## Phase A: Infisical Deployment + Secret Migration

### A.1 Define the Bootstrap Contract

The bootstrap contract is the minimum external secret set needed to build Layer 1.

Stored in Bitwarden cloud:

- `proxmox_api_token`
- `infisical_db_password`
- `infisical_encryption_key`
- `infisical_auth_secret`
- any remaining bootstrap-only secret still required by the initial provisioning flow
- any workstation-run machine identity credentials that cannot be stored inside Infisical itself

Bootstrap rules:

- Bitwarden cloud is the only external secret dependency.
- No encrypted secret files live in this repo.
- No bootstrap secrets are committed to Git.
- The bootstrap flow must be executable from a clean workstation with Bitwarden CLI access.

### A.2 Provision Dedicated Infisical LXC

Create the Infisical host via Ansible, using the Bitwarden-backed bootstrap contract for credentials.

**New Ansible role:** `ansible/roles/infisical_data/`

- Provisions Proxmox LXC (similar pattern to `glitchtip_data`)
- Installs PostgreSQL + Redis
- Creates the `infisical` database and user
- Configures backups to TrueNAS NFS (independent from GlitchTip backups)

**Host specs:**

- IP: TBD (e.g., 10.0.10.85)
- Cores: 2
- Memory: 1GB
- Disk: 20G on local-lvm
- PostgreSQL backup retention: 14 days to TrueNAS

### A.3 Build a One-Command Bootstrap Flow

Bootstrap should be performed through one idempotent Ansible entrypoint.

- Unlock Bitwarden CLI on the workstation.
- Inject the bootstrap values into the Ansible process as environment variables.
- Provision the Infisical data host if it does not already exist.
- Create the `infisical` namespace in Kubernetes.
- Create or reconcile the `infisical-bootstrap` Secret in Kubernetes.
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
  DB_CONNECTION_URI: postgresql://<user>:<pass>@<infisical-lxc-ip>:5432/infisical
  REDIS_URL: redis://<infisical-lxc-ip>:6379
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

Do not exclude all `Secret` resources cluster-wide. The exclusion must be scoped to the actual Infisical-managed Secrets, either by the namespaces being migrated or by the ownership labels the Infisical Operator applies.

Verify the operator's exact labels and ArgoCD exclusion capabilities against the Infisical Operator and ArgoCD docs before committing the final config.

```yaml
resource.exclusions: |
  - apiGroups: [""]
    kinds: ["Secret"]
    clusters: ["*"]
    namespaces:
      - cert-manager
      - glitchtip
      - argocd
```

The namespace list is illustrative, not authoritative. Prefer a more specific selector if the operator and ArgoCD support it reliably.

### A.7 Create Machine Identity for K8s

In Infisical UI/API:

- Create a Machine Identity with Kubernetes Auth method
- Scope it to the `homelab` project
- The operator authenticates using K8s service account tokens

After creating workstation-run machine identities for Ansible and Terraform, store the resulting `client_id` and `client_secret` values in Bitwarden cloud. These credentials cannot live in Infisical without creating a circular dependency.

### A.8 Canary Health Check

Before migrating real applications, create a low-risk canary `InfisicalSecret` in a non-critical namespace.

Purpose:

- Verify the operator can authenticate
- Verify the operator can read from the expected Infisical path
- Verify the target Kubernetes Secret is created and refreshed correctly

Do not start real application migration until this canary path works end to end.

### A.9 Migrate Kubernetes Secrets (Per-App)

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
spec:
  hostAPI: http://infisical.infisical.svc.cluster.local:8080
  authentication:
    kubernetesAuth:
      identityId: <machine-identity-id>
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

**Apps to migrate (in order):**

1. **cert-manager** — 2 secrets (cloudflare_api_token, cloudflare_email). Low secret count, existing certs buffer any issues during migration.
2. **glitchtip** — 10+ secrets (DB, Redis, email, admin creds). Largest migration, most complex.
3. **argo-cd** — Admin password, repo credentials, GHCR registry creds. Most sensitive — do last among K8s apps.

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

- Use Bitwarden-fed environment variables only for the minimal bootstrap path.
- Do not introduce new repo-encrypted artifacts.

Steady-state:

- Use Infisical lookups for normal Ansible configuration after self-hosted Infisical is healthy.
- Replace `community.sops.load_vars` usage in the current playbooks and roles.
- Cover the current bootstrap password path and the Cloudflare tunnel JSON edge case explicitly so they do not become leftover SOPS holdouts.

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

Remove old secret infrastructure:

- Sealed Secrets controller (`kubernetes/core/sealed-secrets/` entire directory)
- `seal_secret()` function from `makejinja/plugin.py`
- SOPS-related ArgoCD config (HELM_SECRETS_BACKEND, sops init container)
- Encryption task from Taskfile.yml and `.taskfiles/SecretTasks.yaml`
- All secret values from `config.yaml`
- `.sealed-secrets-public-cert.pem`
- `.sops.yaml` rules for kubernetes/, ansible/, and terraform/ paths

**What survives Phase A:**

- `config.yaml` (non-secret variables only)
- `makejinja` (renders non-secret templates)

Nothing from the old SOPS or Age toolchain survives Phase A.

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
| ArgoCD prunes operator-managed Secrets             | Medium   | Resource exclusion configured in A.6 and verified against actual operator-managed Secret scope. Operator owns Secret lifecycle.                  |
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

1. **Phase 0:** Retire ARC (controller + runners) and deeptutor in one cleanup PR, including GitHub-side ARC cleanup and repo-owned deeptutor artifact cleanup
2. **A.1:** Define the Layer 0 Bitwarden bootstrap contract
3. **A.2-A.3:** Provision the dedicated Infisical data host and build the one-command Ansible bootstrap flow
4. **A.4:** Deploy Infisical server on K8s
5. **A.5:** Populate secrets in Infisical UI/API (manual one-time migration)
6. **A.6-A.8:** Deploy Infisical Operator, scope ArgoCD exclusions, create machine identities, store workstation credentials in Bitwarden, and validate the canary secret path
7. **A.9:** Migrate K8s secrets: cert-manager → glitchtip → argo-cd
8. **A.10:** Migrate Ansible secrets
9. **A.11:** Migrate Terraform secrets
10. **A.12:** Phase A cleanup (remove Sealed Secrets, SOPS, Age, and old secret templates)
11. **DR runbook:** Write the documented recovery checklist before calling Phase A complete
12. **B.1-B.3:** Convert all remaining templates to static files
13. **B.4-B.5:** Remove makejinja, config.yaml, and template infrastructure

Each phase is independently valuable, but Phase A is not complete until SOPS and Age are gone from this repo.

---

## Verification

**After Phase 0:**

- ArgoCD shows ARC and deeptutor removed / not found
- `task configure` still runs clean
- `arc-runners` and `deeptutor` namespaces are gone from the cluster
- repo searches show no live manifest, workflow, config, or tracked-doc references outside intended historical documentation
- no GitHub-side ARC registrations or scale sets remain
- no repo-owned deeptutor GHCR artifacts remain

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
