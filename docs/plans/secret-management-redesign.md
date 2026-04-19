# Secret Management Redesign

## Context

The current secrets management in the-lab uses a multi-stage encryption pipeline (`config.yaml` -> `makejinja` templates -> SOPS + kubeseal) with three different secret types (SOPS-encrypted YAML, Sealed Secrets, env vars) and five different tools (age, sops, kubeseal, makejinja plugin, envsubst). This has become messy and hard to maintain.

The goal is:

1. **Replace the entire secret pipeline** with self-hosted Infisical as a single source of truth for secrets consumed by Kubernetes apps, Ansible roles, and Terraform configs
2. **Keep** `task configure` + Jinja templates for deterministic, non-secret rendering of shared configuration across Kubernetes, Ansible, and Terraform
3. **Remove the nondeterministic secret-generation path** so rerunning `task configure` does not create Git noise when values have not changed

Infisical is not just for this repo — it will be core network infrastructure used by all apps and services on the homelab network.

## Key Decisions

| #   | Decision             | Resolution                                                                        |
| --- | -------------------- | --------------------------------------------------------------------------------- |
| 1   | DR strategy          | TrueNAS PostgreSQL backups on a dedicated Infisical host                          |
| 2   | Shared fate          | Dedicated Infisical LXC — isolated from GlitchTip and all app databases           |
| 3   | Bootstrap trust root | Bitwarden cloud stores the minimal external secret set: initial bootstrap secrets plus post-bootstrap workstation credentials                   |
| 4   | Vaultwarden role     | Vaultwarden is a normal homelab app, not a bootstrap dependency                   |
| 5   | Bootstrap UX         | One idempotent Ansible command; no required manual kubectl secret creation        |
| 6   | Why Infisical        | UX + simplicity wins for single-operator homelab over Vault/OpenBao               |
| 7   | Migration order      | Retire ARC first; keep deeptutor in place, migrate its current three runtime secrets during Phase A so Sealed Secrets can be removed globally, and defer only the larger deeptutor redesign/upgrade follow-up |
| 8   | Project organization | Single Infisical project with path-based organization, split later if needed      |
| 9   | config.yaml fate     | Keep `config.yaml` as the non-secret render source and service catalog            |
| 10  | Template pipeline    | Keep `task configure` + Jinja; remove only secret-related nondeterministic paths  |
| 11  | ArgoCD ownership     | Exclude operator-managed K8s Secrets from ArgoCD sync                             |
| 12  | SOPS/Age fate        | Remove SOPS and Age from this repo completely during Phase A                      |
| 13  | Redis auth           | Infisical LXC Redis uses `requirepass`; `infisical_redis_password` is an initial bootstrap secret stored in Bitwarden cloud     |
| 14  | Network encryption   | Plaintext PostgreSQL/Redis on private network (same pattern as glitchtip_data)    |
| 15  | Auth identities      | 3 separate: K8s Auth (operator), Universal Auth (Ansible), Universal Auth (Terraform) — each path-scoped |
| 16  | Identity IDs         | Hardcoded in static InfisicalSecret YAML manifests (not templated)                |
| 17  | ArgoCD exclusion     | Label-based via `app.kubernetes.io/managed-by: infisical-operator` propagated from CRD |
| 18  | Bitwarden CLI tool   | Use `rbw` (agent-based Bitwarden CLI) with a dedicated `bootstrap` profile pointing at Bitwarden cloud; playbook never touches rbw directly |
| 19  | ArgoCD secrets       | Bootstrap-only via Ansible Infisical lookup, NOT operator-managed InfisicalSecrets |
| 20  | Rollback strategy    | Accept K8s Secret persistence; no warm standby. Restore from backup if needed     |
| 21  | Monitoring           | Permanent canary InfisicalSecret + ArgoCD health; no additional monitoring infra  |
| 22  | Infisical LXC IP     | 10.0.10.85 (sequential with glitchtip .83, honcho .84)                            |
| 23  | ArgoCD admin hash    | Store a precomputed bcrypt hash in Infisical (`admin_password_hash`); do not generate hashes during template rendering or Ansible apply |

## Architecture

### Trust Layers

The bootstrap chain has to terminate outside the homelab. Self-hosted systems such as Vaultwarden and self-hosted Infisical cannot serve as the trust root for rebuilding the lab after a full outage.

Layer 0 is Bitwarden cloud.

- Holds only the minimal external secret set.
- Before first bootstrap, this means the initial bootstrap secrets needed to stand up Infisical.
- After Infisical is running, it also holds workstation-run credentials that cannot be stored only inside Infisical itself, such as post-bootstrap machine identity credentials for Ansible and Terraform.
- Lives outside the homelab and survives total homelab loss.
- Is accessed from the workstation through `rbw` (agent-based Bitwarden CLI) using a dedicated `bootstrap` profile during bootstrap runs and later workstation-driven automation.

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

The only secrets that exist outside Infisical are the minimal external secrets stored in Bitwarden cloud. These fall into two stages:

1. **Initial bootstrap secrets** — must exist before Infisical is first brought up.
2. **Post-bootstrap workstation credentials** — created later inside Infisical, then copied into Bitwarden because workstation-run Ansible and Terraform cannot fetch their own login credentials from Infisical without creating a circular dependency.

```
Bitwarden cloud (Layer 0)
    ├── Initial bootstrap secrets
    │   ├── proxmox_api_token
    │   ├── infisical_db_password
    │   ├── infisical_redis_password
    │   ├── infisical_encryption_key
    │   ├── infisical_auth_secret
    │   └── any remaining bootstrap-only external credential
    ├── Post-bootstrap workstation credentials
    │   ├── ansible_machine_identity_client_id/client_secret
    │   └── terraform_machine_identity_client_id/client_secret
      │
      ▼
Workstation unlocks rbw agent (RBW_PROFILE=bootstrap)
      │
      ▼
Ansible injects env vars into bootstrap run
      │
      ├── Provisions Infisical data host
      ├── Creates infisical namespace
      ├── Creates infisical-secrets Secret
      ├── Creates infisical-postgres-connection Secret
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

### Template Pipeline Constraints

The current Git noise problem is caused by nondeterministic secret-generation behavior, not by `makejinja` itself.

- `makejinja.toml` sets `force = true`, so files are rewritten on every render
- Git only becomes dirty when the rendered bytes actually change
- Deterministic non-secret templates are acceptable and remain in scope
- The secret-path pieces that must be removed from active rendering are:
  - `encrypt-secrets` in `Taskfile.yml`
  - `bcrypt_password()` in `makejinja/plugin.py`
  - `seal_secret()` in `makejinja/plugin.py`

After those secret-path pieces are removed and replaced, `task configure` can keep rendering files while `git status` stays clean unless a real config/template value changed.

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

Single project, path-based. Final structure (post-audit, post-migration):

```
Project: the-lab
├── Environment: prod
│   ├── /kubernetes
│   │   ├── /cert-manager     (cloudflare_api_token)
│   │   ├── /argocd           (admin_password_hash — pre-hashed bcrypt from Bitwarden)
│   │   ├── /glitchtip        (raw components: POSTGRES_*, REDIS_*, DB_HOST, SECRET_KEY,
│   │   │                      EMAIL_URL, ADMIN_*, BOOTSTRAP_MCP_TOKEN; CRD composes URLs)
│   │   └── /deeptutor        (LLM_BINDING_API_KEY, EMBEDDING_BINDING_API_KEY, PERPLEXITY_API_KEY)
│   ├── /ansible
│   │   ├── /cloudflare       (tunnel_json, email — email has no current consumer, future-use)
│   │   ├── /proxmox          (cipassword, api_token_id, api_token_secret — Terraform cross-scope)
│   │   └── /services         (honcho_* service-level secrets only; nullable keys skipped)
│   └── /terraform
│       └── /unifi            (username, password, iot_wlan_passphrase)
```

Machine identities scoped to paths with **targeted cross-scope reads** on specific shared keys:

- K8s Operator identity: reads `/kubernetes/*`
- Ansible identity: reads `/ansible/*` plus targeted reads on `/kubernetes/argocd/admin_password_hash` and `/kubernetes/glitchtip/{POSTGRES_PASSWORD,REDIS_PASSWORD}`
- Terraform identity: reads `/terraform/*` plus targeted reads on `/ansible/proxmox/{cipassword,api_token_id,api_token_secret}`

Dropped paths (from earlier drafts): `/ansible/cert-manager/*`, `/terraform/cloudflare/*`, `/terraform/proxmox/*`, `/kubernetes/argocd/{repo_credentials,ghcr_*}` — see A.5 "Explicitly NOT migrated" section.

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

### 0.2 Keep deeptutor in place and defer redesign/upgrade work ✅

Keep deeptutor in the homelab for now, but do not let deeptutor upgrade/evaluation block the rest of the secret-management redesign. Deeptutor's current runtime secret wiring is simple enough that its existing three API-key secrets should still be migrated during Phase A. What stays deferred is the broader deeptutor redesign/upgrade follow-up.

Keep:

- `kubernetes/apps/deeptutor/`
- `templates/kubernetes/apps/deeptutor/`
- deeptutor entries in the ArgoCD apps project
- `deeptutor_*` variables in `config.yaml` until the app's post-upgrade configuration contract is confirmed

Do now:

- Keep the current deeptutor deployment healthy while the broader plan moves forward.
- Preserve the existing deeptutor manifests, workflow, and namespace while the broader plan moves forward.
- Treat deeptutor redesign/upgrade as out of the critical path for Phase 0 and the initial Infisical rollout.
- Migrate deeptutor's current three runtime API-key secrets during Phase A so Sealed Secrets can be removed cluster-wide.

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
- Because `v1.x` may change the application's broader runtime contract, defer DeepTutor's redesign/upgrade work until there is time to evaluate it deliberately.
- The current three-key secret migration is intentionally smaller in scope than a full app redesign and should happen during Phase A.
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

### A.1 Define the Bootstrap Contract ✅

**Status:** A.1 is complete. All 5 initial bootstrap secrets are created in Bitwarden cloud. The Helm chart contract (OCI standalone chart v1.8.0, two K8s Secrets with specific keys) has been verified.

The bootstrap contract is the minimum external secret set needed to build Layer 1.

Stored in Bitwarden cloud **before the first Infisical bootstrap run**:

- `proxmox_api_token`
- `infisical_db_password`
- `infisical_redis_password`
- `infisical_encryption_key`
- `infisical_auth_secret`
- `infisical_admin_email`
- `infisical_admin_password`
- any remaining bootstrap-only secret still required by the initial provisioning flow

**Current Bitwarden item names (created):**

- [x] `proxmox_api_token` → `homelab/bootstrap/proxmox-api-token`
- [x] `infisical_db_password` → `homelab/bootstrap/infisical-db-password`
- [x] `infisical_redis_password` → `homelab/bootstrap/infisical-redis-password`
- [x] `infisical_encryption_key` → `homelab/bootstrap/infisical-encryption-key`
- [x] `infisical_auth_secret` → `homelab/bootstrap/infisical-auth-secret`
- [x] `infisical_admin_email` → `homelab/bootstrap/infisical-admin-email`
- [x] `infisical_admin_password` → `homelab/bootstrap/infisical-admin-password`

The admin email/password pair is the credential used by `infisical bootstrap` (see A.4.5) to create the first admin user + organization on a freshly-deployed Infisical server. It is Layer 0 / bootstrap-tier by definition: without it, a DR rebuild cannot re-establish the admin identity after the PostgreSQL backup is restored into a new server.

**Additional Bitwarden items required for Terraform bootstrap (to create):**

- [x] `proxmox_api_token_id` → `homelab/bootstrap/proxmox-api-token-id`
- [x] `proxmox_cipassword` → `homelab/bootstrap/proxmox-cipassword`
- [x] `unifi_username` → `homelab/bootstrap/unifi-username`
- [x] `unifi_password` → `homelab/bootstrap/unifi-password`

These items are needed by the bootstrap Terraform root (`terraform/infisical-data/`) and are currently hardcoded in `.auto.tfvars` files. They must be added to Bitwarden before the wrapper script can fully replace tfvars-based secret injection.

**Non-secret bootstrap configuration (not stored in Bitwarden):**

- `INFISICAL_API_URL=https://infisical.local.bysliek.com` — exported by the loader script so every subsequent Infisical CLI call resolves against the self-hosted instance instead of the default US cloud. Per the [Infisical CLI docs](https://infisical.com/docs/cli/usage), setting `INFISICAL_API_URL` "applies the domain setting globally to all commands" for `login`, `secrets`, `run`, and `export`. The `infisical bootstrap` subcommand is an exception — it uses its own `--domain` flag and does not honor `INFISICAL_API_URL`, so A.4.5 passes the domain explicitly.

All Bitwarden item names above are the canonical references for the bootstrap wrapper script and any related operator runbooks.

Not part of the initial bootstrap set:

- `ansible_machine_identity_client_id` / `ansible_machine_identity_client_secret`
- `terraform_machine_identity_client_id` / `terraform_machine_identity_client_secret`

Those machine identity credentials do ultimately live in Bitwarden cloud as post-bootstrap external workstation credentials, but they are created later in A.7 after Infisical is running and the identities exist.

Bootstrap rules:

- Bitwarden cloud is the only external secret dependency.
- No encrypted secret files live in this repo.
- No bootstrap secrets are committed to Git.
- The bootstrap flow must be executable from a clean workstation with `rbw` installed and the `bootstrap` profile configured.

**Chart contract verified for implementation:**

Use the upstream OCI chart `oci://helm.oci.cloudsmith.io/infisical/helm-charts/infisical-standalone` (verified at version `1.8.0`), not the older Mongo-based HTTP chart.

The chart consumes bootstrap configuration in two paths:

1. **Main backend env secret** via `infisical.kubeSecretRef` → mounted into the Infisical pod through `envFrom.secretRef`
2. **PostgreSQL connection string secret** via `postgresql.useExistingPostgresSecret.*` → mounted as `DB_CONNECTION_URI`

**Concrete bootstrap contract:**

| K8s Secret | Key | Source | Injection mechanism |
|---|---|---|---|
| `infisical-secrets` | `ENCRYPTION_KEY` | Bitwarden `infisical_encryption_key` | `infisical.kubeSecretRef` → `envFrom.secretRef` |
| `infisical-secrets` | `AUTH_SECRET` | Bitwarden `infisical_auth_secret` | `infisical.kubeSecretRef` → `envFrom.secretRef` |
| `infisical-secrets` | `REDIS_URL` | composed from Bitwarden `infisical_redis_password` and the dedicated LXC address | `infisical.kubeSecretRef` → `envFrom.secretRef` |
| `infisical-secrets` | `SITE_URL` | static repo-managed value (`https://infisical.local.bysliek.com`) | `infisical.kubeSecretRef` → `envFrom.secretRef` |
| `infisical-postgres-connection` | `connectionString` | composed PostgreSQL URI for the dedicated Infisical data host | `postgresql.useExistingPostgresSecret.existingConnectionStringSecret` → `DB_CONNECTION_URI` |

Notes:

- `AUTH_SECRET` and `ENCRYPTION_KEY` are the required bootstrap secrets for the current Postgres-based self-hosted Infisical runtime.
- The older Mongo-based chart contract (`MONGO_URL`, JWT secret set) is intentionally out of scope for this plan.
- Do not enable the chart's `autoBootstrap` job for initial server startup; it is a post-install root-identity helper, not the server's first-boot secret contract.

### A.2 Provision Dedicated Infisical LXC ✅

**Status:** A.2 is complete. The Terraform root provisioned the LXC (10.0.10.85, running and SSH-reachable). The Ansible role, playbook, inventory, Taskfile entries, and template sources are all implemented and verified via `task render-templates` in the devcontainer and Ansible dry runs.

Use the same split of responsibilities already present elsewhere in this repo for service hosts such as `glitchtip-data` and `honcho`:

- **Terraform** creates the Proxmox LXC and any closely related infrastructure objects.
- **Ansible** bootstraps the guest OS and configures PostgreSQL, Redis, backups, and service-level settings.

This keeps infrastructure creation aligned with the repo's existing Proxmox IaC pattern while preserving the simple one-command bootstrap experience in A.3.

**New Terraform root:** `terraform/infisical-data/`

Terraform responsibilities:

- Provisions the Proxmox LXC
- Sets hostname, CPU, memory, disk, network, on-boot behavior, and SSH public key injection
- Optionally manages any closely coupled network identity object if needed (for example, a `unifi_user`, following the existing `glitchtip-data` / `honcho` pattern)
- Exposes stable outputs needed by the wrapper script or later automation, such as the LXC IP address

#### Terraform structure for service LXCs

The Terraform refactor for service hosts should preserve the repo's current `templates -> task configure -> terraform/` workflow while removing repeated LXC boilerplate.

- Add a shared template-backed Terraform module at `templates/terraform/modules/proxmox-lxc-service/`
- Render that module to `terraform/modules/proxmox-lxc-service/`
- Keep thin per-service Terraform roots for `glitchtip-data`, `honcho`, and `infisical-data`
- Do **not** collapse all service LXCs into one mega-root or shared state file

The shared module owns the common `proxmox_lxc` + optional `unifi_user` pattern. Each thin root keeps:

- providers
- root variables
- one module call
- root outputs

This keeps separate Terraform state per service while making the resource logic DRY.

#### Existing root migration (`glitchtip-data`, `honcho`)

`glitchtip-data` and `honcho` already exist as live Terraform-managed resources, so the refactor must be a state-address migration rather than a destroy/recreate migration.

- Keep `terraform/glitchtip-data/` and `terraform/honcho/` as the long-lived thin roots
- Replace their duplicated resource blocks with a shared module call
- Use Terraform `moved` blocks to migrate existing resource addresses into the module
- Refactor one root at a time and require a no-create / no-destroy plan before apply

Example migration shape:

```hcl
moved {
  from = proxmox_lxc.glitchtip_data
  to   = module.service_host.proxmox_lxc.this
}

moved {
  from = unifi_user.glitchtip_data
  to   = module.service_host.unifi_user.this
}
```

Use the same pattern for `honcho`. The `moved` blocks are temporary migration scaffolding: keep them through the migration window, then remove them after the relevant state has been successfully applied through the refactored root and no untouched older state snapshots still depend on the mapping.

#### Service-host config model (implemented)

`config.yaml` uses a DRY service-host map. The `terraform_service_lxcs` entry for `infisical-data` was extended with nested service config — no flat `infisical_data_*` top-level vars were created. Ansible templates reference the map directly via `{% set infisical = terraform_service_lxcs['infisical-data'] %}`.

```yaml
terraform_service_lxcs:
  glitchtip-data:
    target_node: mia
    hostname: glitchtip-data
    ip: 10.0.10.83
    # ... (existing flat vars remain for glitchtip-data and honcho until migration)
  honcho:
    target_node: mia
    hostname: honcho
    ip: 10.0.10.84
    # ...
  infisical-data:
    target_node: mia
    hostname: infisical-data
    ip: 10.0.10.85
    gateway: 10.0.10.1
    storage: local-lvm
    disk_size: 20G
    cores: 2
    memory_mb: 1024
    swap_mb: 0
    nameserver: 1.1.1.1
    postgres:
      db: infisical
      user: infisical
      port: 5432
    redis:
      port: 6379
    backup:
      enabled: true
      nfs_server: "truenas.local.bysliek.com"
      nfs_path: "/mnt/k8s-ssd-pool/infisical-postgres-backups"
      retention_days: 14
```

The existing glitchtip-data and honcho flat vars remain until those roles are migrated. The nested keys (`postgres`, `redis`, `backup`) are consumed only by Ansible templates — Terraform templates ignore them.

**Ansible role and playbook (implemented):**

- `ansible/playbooks/infisical-data.yml` — SOPS-free playbook using `lookup('env', ...)` for secrets
- `ansible/roles/infisical_data/` — PostgreSQL + Redis configuration role following the `glitchtip_data` pattern, simplified (single database, no `additional_databases` machinery)

Key design departure: the playbook does NOT use `community.sops.load_vars`. Secrets come from environment variables (`INFISICAL_DB_PASSWORD`, `INFISICAL_REDIS_PASSWORD`) set by the bootstrap secret loader script. The playbook validates these are present via an `assert` task before proceeding.

Template sources live under `templates/ansible/roles/infisical_data/` and are rendered via `task configure` (makejinja). Role tasks, handlers, and backup templates use `{% raw %}` wrapping (pass through verbatim); only `defaults/main.yaml.j2` is truly templated for IP interpolation.

`community.postgresql` (v4.2.0) was added to `ansible/requirements.yml` as an explicit dependency — it was already used by `glitchtip_data` and `honcho` roles but never declared.

**Bootstrap-domain guardrail:**

- `terraform/infisical-data/` is a bootstrap Terraform root.
- It must remain completely independent from self-hosted Infisical.
- It uses only Bitwarden-fed bootstrap inputs plus the Proxmox provider and any other already-external provider required for host creation.
- Do **not** add the Infisical Terraform provider to this root.

**Host specs:**

- IP: 10.0.10.85
- Cores: 2
- Memory: 1GB
- Disk: 20G on local-lvm

**Backup configuration:**

- Mechanism: `pg_dump` via systemd timer (same pattern as `glitchtip_data` role)
- Schedule: daily at 03:45 (offset from glitchtip's 03:15 to avoid NFS contention)
- Retention: 14 days to TrueNAS NFS mount
- Backup script, systemd service, and timer managed by Ansible

**Taskfile entries (implemented):**

- `terraform:init-infisical-data`, `terraform:plan-infisical-data`, `terraform:apply-infisical-data`
- `ansible:bootstrap-infisical-data`, `ansible:update-infisical-data`, `ansible:configure-infisical-data`
- `apply-infisical-bootstrap-secrets` — private helper that creates/reconciles the K8s namespace and bootstrap Secrets
- `deploy-infisical-data` — first-time provisioning path
- `update-infisical-data` — package updates and host/app reconfiguration for an already-running server
- `redeploy-infisical-secrets` — secrets-only reconciliation path

### A.3 Build a One-Command Bootstrap Flow ✅

**Status:** A.3 is complete and A.4 is unblocked. The bootstrap flow is split into three task paths plus a secret loader script: first-time deploy, update-existing-host, and secrets-only reconciliation. The `rbw` bootstrap profile is configured and verified, `task deploy-infisical-data` now completes successfully end to end, and the Infisical data host at `10.0.10.85` is up with PostgreSQL and Redis configured and reachable. Backups are intentionally deferred for now, so the host bootstrap is considered complete with backup wiring disabled until the later storage pass.

**Design: SRP split instead of monolithic wrapper script**

The original plan proposed a single wrapper script that both loaded secrets and orchestrated the deploy. The implemented design separates these concerns:

1. **`scripts/load-bootstrap-secrets.sh`** — Single responsibility: load Bitwarden secrets into the current shell. Sourceable script that sets `RBW_PROFILE=bootstrap`, ensures the agent is unlocked, and exports all 9 secrets as env vars. Does not orchestrate, does not call tasks.

2. **`task deploy-infisical-data`** — Single responsibility: orchestrate the first-time deploy. Chains configure → terraform → ansible bootstrap → ansible configure → secrets reconciliation.
3. **`task update-infisical-data`** — Single responsibility: update an already-running host and reapply the Infisical service config.
4. **`task redeploy-infisical-secrets`** — Single responsibility: reconcile the bootstrap Kubernetes Secrets after a secret rotation or leak.

**Usage:**

```bash
source scripts/load-bootstrap-secrets.sh    # defaults to all bootstrap secret groups
task deploy-infisical-data                   # deploy data host + bootstrap Secrets
task update-infisical-data                   # update running host + reapply service config
task redeploy-infisical-secrets              # reconcile bootstrap Secrets only
```

Or run individual steps:

```bash
source scripts/load-bootstrap-secrets.sh
task ansible:configure-infisical-data        # just reconfigure PostgreSQL/Redis
task apply-infisical-bootstrap-secrets       # internal helper used by redeploy-infisical-secrets
task ansible:update-infisical-data           # update base host packages/config on an existing server
```

**Bitwarden CLI tooling (`rbw`):**

The bootstrap flow uses `rbw` — an agent-based, unofficial Bitwarden CLI available in the Arch extra repo (`pacman -S rbw`). Unlike the official `bw` CLI, `rbw` maintains a background agent process (similar to `ssh-agent`) that holds decryption keys in memory, eliminating manual session token management (`BW_SESSION` export, session expiry, npm global install).

A dedicated `RBW_PROFILE=bootstrap` profile is configured to point at Bitwarden cloud (the Layer 0 trust root). Each rbw profile uses its own separate configuration, local vault, and agent instance, so the bootstrap profile is fully isolated from any personal or Vaultwarden-pointing profile the operator may also use.

**One-time setup (per workstation):**

1. `pacman -S rbw`
2. `RBW_PROFILE=bootstrap rbw config set email <bootstrap-account-email>` (base_url defaults to Bitwarden cloud)
3. `RBW_PROFILE=bootstrap rbw register` (required for official Bitwarden server bot-detection)
4. `RBW_PROFILE=bootstrap rbw login`
5. `RBW_PROFILE=bootstrap rbw unlock`
6. `RBW_PROFILE=bootstrap rbw sync`

After this, `RBW_PROFILE=bootstrap rbw get <item>` works without session tokens.

**Secret loader script (`scripts/load-bootstrap-secrets.sh`):**

```bash
source scripts/load-bootstrap-secrets.sh
```

Exports:

```bash
# Terraform secrets (TF_VAR_ prefix → auto-consumed by Terraform)
TF_VAR_pm_api_token_id        # from homelab/bootstrap/proxmox-api-token-id
TF_VAR_pm_api_token_secret    # from homelab/bootstrap/proxmox-api-token
TF_VAR_cipassword             # from homelab/bootstrap/proxmox-cipassword
TF_VAR_unifi_username         # from homelab/bootstrap/unifi-username
TF_VAR_unifi_password         # from homelab/bootstrap/unifi-password

# Infisical application secrets (consumed by Ansible and kubectl)
INFISICAL_DB_PASSWORD          # from homelab/bootstrap/infisical-db-password
INFISICAL_ENCRYPTION_KEY       # from homelab/bootstrap/infisical-encryption-key
INFISICAL_AUTH_SECRET          # from homelab/bootstrap/infisical-auth-secret
INFISICAL_REDIS_PASSWORD       # from homelab/bootstrap/infisical-redis-password

# Infisical admin identity bootstrap (consumed by `infisical bootstrap` in A.4.5)
INFISICAL_ADMIN_EMAIL          # from homelab/bootstrap/infisical-admin-email
INFISICAL_ADMIN_PASSWORD       # from homelab/bootstrap/infisical-admin-password

# Infisical CLI global configuration (static, not from Bitwarden)
INFISICAL_API_URL=https://infisical.local.bysliek.com
```

The `TF_VAR_` prefix is a Terraform convention: any env var matching `TF_VAR_<variable_name>` automatically populates the corresponding `variable "<variable_name>"` block. This eliminates `.auto.tfvars` files for secrets entirely — no secret touches disk and nothing gets committed.

Non-secret infrastructure shape variables (`pm_api_url`, `ssh_key_file`, `template_name`, `unifi_api_url`) are safe to keep in a committed `.auto.tfvars` file or pass via `-var-file`. Only values sourced from Bitwarden flow through `TF_VAR_` env vars.

Later, after A.7 creates the Ansible and Terraform machine identities inside Infisical, Bitwarden also becomes the storage location for those post-bootstrap workstation credentials.

**Orchestration via Taskfile (`task deploy-infisical-data`):**

The deploy and maintenance tasks split the host lifecycle into separate paths:

1. `task configure` — render templates
2. `task terraform:init-infisical-data` — init Terraform
3. `task terraform:apply-infisical-data` — provision/reconcile LXC
4. `task ansible:bootstrap-infisical-data` — create ansible user, deploy SSH key
5. `task ansible:configure-infisical-data` — configure PostgreSQL, Redis, backups
6. `task redeploy-infisical-secrets` — create/reconcile namespace and bootstrap Secrets

For repeat operations:

- `task update-infisical-data` — run the package update and host/app reconfiguration path
- `task redeploy-infisical-secrets` — reconcile only the Kubernetes bootstrap Secrets after a leak or rotation

The loader defaults to `all` when called with no arguments and now fails immediately if any `rbw get` call returns an error or an empty secret. The `deploy-infisical-data` task also performs workstation and cluster preflight checks before provisioning begins.

**Completion evidence:**

- [x] Bitwarden bootstrap items are readable through the `bootstrap` `rbw` profile
- [x] `task deploy-infisical-data` completes successfully after the Proxmox API token pair was corrected
- [x] Terraform reconciles the `infisical-data` LXC successfully
- [x] Ansible bootstrap and configuration complete successfully for the data host
- [x] PostgreSQL is running on `10.0.10.85:5432`
- [x] Redis is running on `10.0.10.85:6379`
- [x] The `infisical` PostgreSQL role and database exist and accept authenticated connections
- [x] Bootstrap K8s Secrets are created in the `infisical` namespace
- [x] Backup setup is explicitly deferred and disabled for now so it does not block bootstrap

This closes Phase A.3. The remaining backup/NFS design work is not a prerequisite for bringing up the Infisical server and should be handled later as follow-up infrastructure work, not as a blocker for A.4.

**K8s bootstrap Secrets created by `apply-infisical-bootstrap-secrets`:**

| K8s Secret | Key | Source |
|---|---|---|
| `infisical-secrets` | `ENCRYPTION_KEY` | `$INFISICAL_ENCRYPTION_KEY` |
| `infisical-secrets` | `AUTH_SECRET` | `$INFISICAL_AUTH_SECRET` |
| `infisical-secrets` | `REDIS_URL` | composed: `redis://:${INFISICAL_REDIS_PASSWORD}@10.0.10.85:6379` |
| `infisical-secrets` | `SITE_URL` | static: `https://infisical.local.bysliek.com` |
| `infisical-postgres-connection` | `connectionString` | composed: `postgresql://infisical:${INFISICAL_DB_PASSWORD}@10.0.10.85:5432/infisical?sslmode=disable` |

Both secrets use `kubectl create --dry-run=client -o yaml | kubectl apply -f -` for idempotency.

### A.4 Deploy Infisical Server on K8s

Create `kubernetes/infrastructure/infisical/` with a Helm-based ArgoCD Application.

**Helm chart:** `oci://helm.oci.cloudsmith.io/infisical/helm-charts/infisical-standalone`

**Pinned chart version:** `1.8.0`

**Helm values:**

```yaml
infisical:
  replicaCount: 1
  kubeSecretRef: infisical-secrets
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

postgresql:
  enabled: false # external, on dedicated LXC
  useExistingPostgresSecret:
    enabled: true
    existingConnectionStringSecret:
      name: infisical-postgres-connection
      key: connectionString

redis:
  enabled: false # external, on dedicated LXC
```

The `infisical-secrets` Secret provides `ENCRYPTION_KEY`, `AUTH_SECRET`, `REDIS_URL`, and `SITE_URL` through `envFrom`. The `infisical-postgres-connection` Secret provides `DB_CONNECTION_URI` through the chart's `useExistingPostgresSecret` hook.

**Bootstrap ordering:** Both bootstrap Secrets (`infisical-secrets` and `infisical-postgres-connection`) must be created by the Ansible bootstrap flow before the ArgoCD application syncs, otherwise the server pods will start without the required connection settings.

**ArgoCD project config:**

- Add the Infisical OCI chart registry/repo used for `oci://helm.oci.cloudsmith.io/infisical/helm-charts/infisical-standalone` to `spec.sourceRepos` in the infrastructure project
- Add `infisical` namespace to `spec.destinations`

**Ingress:**

- Host: `infisical.local.bysliek.com`
- TLS via cert-manager with existing ClusterIssuer
- IngressClassName: cilium

### A.4.5 Bootstrap Admin Identity

**Status:** Already complete in the current environment. The admin user and `the-lab` organization exist and are reachable at `https://infisical.local.bysliek.com`. This section is documented for DR/rebuild reproducibility — not a gating step for A.5 in the current pass.

After A.4 deploys the Infisical server pod, the instance has zero users, zero organizations, and zero machine identities. The chart's `autoBootstrap` job is intentionally disabled (see A.1) — `infisical bootstrap` is the explicit, scripted path to create the first admin user + organization and drop a machine-identity token into the cluster for downstream automation to consume.

**Command contract:**

```bash
infisical bootstrap \
  --domain "$INFISICAL_API_URL" \
  --email "$INFISICAL_ADMIN_EMAIL" \
  --password "$INFISICAL_ADMIN_PASSWORD" \
  --organization the-lab \
  --output k8-secret \
  --k8-secret-namespace infisical \
  --k8-secret-name infisical-admin-identity \
  --ignore-if-bootstrapped
```

**CLI configuration quirk — important:**

Per the [Infisical CLI usage docs](https://infisical.com/docs/cli/usage), `INFISICAL_API_URL` applies globally to `login`, `secrets`, `run`, and `export`. The `infisical bootstrap` subcommand is an exception — it has its own `--domain` flag and does **not** honor `INFISICAL_API_URL`. Pass the domain explicitly as shown above. The loader script still exports `INFISICAL_API_URL` for every other subcommand; this step simply forwards that value as `--domain` for bootstrap.

**Outputs:**

- A K8s Secret `infisical-admin-identity` in the `infisical` namespace containing `token` (a machine-identity access token).
- The admin user is created with the email/password from Bitwarden (`homelab/bootstrap/infisical-admin-email` / `homelab/bootstrap/infisical-admin-password`).
- The `the-lab` organization exists.

**Idempotency:**

`--ignore-if-bootstrapped` makes this command safe to re-run. It does nothing on an already-bootstrapped instance.

**Orchestration:**

Wire this as an Ansible task at the tail of the Infisical deploy flow (or a `task` entry chained after the Helm release reports Ready). The task:

1. Waits for the Infisical Service to accept TCP connections on port 8080.
2. Executes the `infisical bootstrap` command above with `INFISICAL_ADMIN_EMAIL` / `INFISICAL_ADMIN_PASSWORD` in the process environment (already exported by the loader).
3. Verifies the K8s Secret `infisical-admin-identity` exists in the `infisical` namespace.

**Downstream consumers of the admin identity Secret:**

- **A.5** (`scripts/populate-infisical.sh`) — reads the token out of the K8s Secret to authenticate `infisical secrets set` calls during one-shot migration.
- **A.7** — same token is used to create the three scoped machine identities (K8s Auth operator identity, Ansible Universal Auth identity, Terraform Universal Auth identity). After A.7 the admin identity becomes a break-glass credential, not a steady-state automation credential.

### A.4.7 Secret/Config Classification Audit

**Status:** ✅ Audit complete (2026-04-17) and operator decisions resolved below. The A.5 inventory table reflects the approved mapping.

Before the scripted population in A.5 writes anything to Infisical, every candidate key across the repo is classified into one of three buckets:

| Bucket | Fate |
|---|---|
| **SECRET** | Migrate to Infisical, remove from repo. |
| **CONFIG** | Stays in `config.yaml` / plaintext source. Never touches Infisical. |
| **GRAY** | Requires operator judgment. Audit defaults to SECRET for blast-radius reduction; operator can override. |

The audit was performed under strict no-leak rules: **zero plaintext values entered any tool output or documentation during discovery**. Classification used key names + file context only, via `yq 'keys'`, LHS-only grep on tfvars, and SOPS files where values are self-redacting `ENC[...]` blobs.

**Scope covered:**

1. `config.yaml` (plaintext — highest risk surface, currently holds ~25 real secrets in plaintext under a comment block acknowledging the fact)
2. All 8 active SOPS-encrypted YAML/JSON files in `ansible/` and `kubernetes/`
3. All 4 active `.tfvars` files in `terraform/`
4. All 3 active `.secret.yaml.j2` SealedSecret templates
5. 1 env template (`ansible/roles/honcho/templates/honcho.env`)
6. Rendered `kubernetes/core/argo-cd/secrets/ghcr-registry.secret.yaml`

**Why this step exists:**

Without an explicit classification pass, two classes of error are likely:

- **False positives in Infisical** — migrating non-secret config keys (domains, namespaces, display names, chart versions) into Infisical bloats the secret store with values that should live in plaintext, widening the ArgoCD-operator resource-exclusion blast radius and complicating DR.
- **False negatives in `config.yaml`** — real secrets left behind in the plaintext config file after the migration. The audit flags 25+ keys currently in `config.yaml` under a "replace before production" comment that must be cleared out once Infisical holds the authoritative value.

**Resolved operator decisions (locked into A.5 inventory below):**

1. **GRAY items** — all 6 retained as SECRET per audit default (cloudflare_email, proxmox_api_token_id, unifi_username, glitchtip_admin_username, glitchtip_admin_email, glitchtip_email_url).
2. **Glitchtip bootstrap scope** — Job trimmed to admin + MCP token only. The 7 `GLITCHTIP_BOOTSTRAP_ORGANIZATION_*` / `_PROJECT_*` / `_PROJECT_KEY_*` variables are deleted entirely, along with the `glitchtip-bootstrap-artifacts` Secret write. Org/project/DSN setup moves to manual UI configuration (no repo consumer for the artifacts).
3. **Glitchtip URL composition** — raw components live at `/kubernetes/glitchtip/`; InfisicalSecret CRD uses `spec.template.data` (Go templates) to compose DATABASE_URL/MAINTENANCE_DATABASE_URL/REDIS_URL at operator reconcile time. No migration-time composition, no cron, no repo-side URL templating.
4. **ACME contact split** — new `acme_contact_email` CONFIG variable decouples the ClusterIssuer's Let's Encrypt notification address from `cloudflare_email`. Eliminates a bootstrap cycle and keeps `task configure` Infisical-free.
5. **Orphaned artifacts** — `kubernetes/core/argo-cd/secrets/ghcr-registry.secret.yaml`, `terraform/cloudflare/secret.sops.yaml`, and `terraform/kubernetes-nodes/terraform.tfvars` are confirmed dead and deleted (not migrated). Cleanup lives in A.12.
6. **Shared-value scope model** — one canonical path per secret with targeted cross-scope reads (A.7 grants specific read permissions where needed). Rejected: multi-path mirroring.
7. **Bitwarden↔Infisical dual-storage** — Bitwarden holds only the minimum bootstrap set; Infisical is authoritative for steady-state including mirrored copies of proxmox/unifi/cipassword for future automation devices without Bitwarden access.
8. **ArgoCD bcrypt** — operator pre-hashes the admin password locally (e.g., `htpasswd -bnBC 10 "" <password>`), stores the hash in Bitwarden as `homelab/bootstrap/argocd-admin-password-hash`, and the migration script writes the hash straight into `/kubernetes/argocd/admin_password_hash`. No plaintext password ever touches the script, Infisical, or a committed file.

### A.5 Populate Secrets in Infisical

**Status:** ✅ Complete — executed 2026-04-18 against project `the-lab` (env `prod`). Live run result: 35 written, 3 nullable honcho keys skipped, 0 failed. Matches A.5 inventory 1:1.

One-time scripted migration: read secret values from their current repo-managed sources (`config.yaml`, SOPS-encrypted YAML/JSON, rendered `.secret.yaml` artifacts, Terraform `.tfvars`) and write them into Infisical at the path structure defined in the inventory below.

This is a one-time data migration, not a long-term workflow. After A.5 completes successfully, the migration script is archival — subsequent secret changes happen directly in Infisical (UI, CLI, or API) and DR replays from PostgreSQL backups, not by re-running the migration.

**Inventory rule for implementation:** treat the current source as the actual live artifact or role input that exists in this repo today, not just the historical variable origin. For ArgoCD in particular, the migration checklist must reference the rendered Kubernetes secret artifacts that are currently applied as well as any backing Ansible role inputs.

**Migration tooling: `scripts/populate-infisical.sh`**

A committed shell script that drives the one-shot migration end-to-end. Design constraints:

- **Authentication.** Reads the admin-identity token from the K8s Secret `infisical/infisical-admin-identity` created by A.4.5 (`kubectl -n infisical get secret infisical-admin-identity -o jsonpath='{.data.token}' | base64 -d`), exports it as `INFISICAL_TOKEN` for the script's lifetime, and relies on the loader-script-exported `INFISICAL_API_URL` for domain resolution. No hardcoded credentials, no secrets on disk.
- **Plaintext handling.** SOPS-encrypted sources are decrypted in-memory only via `sops -d` into shell variables or process substitution — **never** to disk. Terraform `.tfvars` and `config.yaml` are read directly. Bitwarden-sourced values (ArgoCD admin password hash, proxmox/unifi mirrors) are read via `rbw get` in the script's shell. The script fails fast on any empty value rather than writing an empty secret.
- **Bcrypt handling.** The ArgoCD admin password is pre-hashed once by the operator (`htpasswd -bnBC 10 "" <password> | tr -d ':\n' | sed 's/$2y/$2a/'`) and stored in Bitwarden as `homelab/bootstrap/argocd-admin-password-hash`. The script reads the hash verbatim and writes it to `/kubernetes/argocd/admin_password_hash`. No plaintext password enters the migration script, Infisical, or any committed file.
- **Null handling.** For the three nullable honcho keys (`honcho_llm_openai_compatible_api_key`, `honcho_llm_vllm_api_key`, `honcho_vector_store_turbopuffer_api_key`), the script checks for null/empty and **skips** those entries instead of writing empty strings. Ansible consumers use `| default(omit)` for these keys to handle the "not set" case gracefully.
- **Idempotency.** `infisical secrets set` upserts, so re-running the script overwrites Infisical with whatever the repo currently has. This is intentional — it means the script can be used to re-baseline after correcting a bad source value. It is **not** a two-way sync.
- **Dry-run mode.** Supports `--dry-run` that prints every `infisical secrets set` call the script would make without executing it. Required for reviewing the full migration before flipping the switch.
- **Per-path isolation.** Loops the inventory table in deterministic order, calling `infisical secrets set --path <p> --env prod KEY=VALUE` for each entry. Failure in one path does not silently skip subsequent entries — the script aborts and reports which entry failed.
- **Audit trail.** Prints each key (not value) as it is set, and exits with a count of secrets written, path-by-path.

**Script invocation:**

```bash
source scripts/load-bootstrap-secrets.sh   # exports INFISICAL_API_URL + rbw-backed values
scripts/populate-infisical.sh --dry-run     # review
scripts/populate-infisical.sh               # execute
```

**Archival after use:**

Once A.5 is verified complete (all inventory rows populate successfully, canary InfisicalSecret from A.8 reconciles), the script stays in the repo as DR scaffolding but is not part of steady-state workflows. DR recovers Infisical state from the PostgreSQL backup, not by re-running the migration.

**Secret inventory (final, post-audit):**

Six Infisical paths, ~25 active secret keys. Mapping locked per the resolved audit decisions (§A.4.7 above).

| Infisical Path | Key | Current Source | Consumer |
|---|---|---|---|
| `/kubernetes/cert-manager` | `cloudflare_api_token` | `config.yaml` | A.9 — cert-manager InfisicalSecret CRD |
| `/kubernetes/argocd` | `admin_password_hash` | Bitwarden `homelab/bootstrap/argocd-admin-password-hash` (pre-hashed by operator) | A.10 — Ansible ArgoCD role |
| `/kubernetes/glitchtip` | `SECRET_KEY` | `config.yaml` (`glitchtip_secret_key`) | A.9 |
| `/kubernetes/glitchtip` | `POSTGRES_USER` | `config.yaml` | A.9 (template compose input) |
| `/kubernetes/glitchtip` | `POSTGRES_PASSWORD` | `config.yaml` (`glitchtip_postgres_password`) | A.9 (compose input); Ansible glitchtip_data role (cross-scope read) |
| `/kubernetes/glitchtip` | `POSTGRES_DB` | `config.yaml` | A.9 (compose input) |
| `/kubernetes/glitchtip` | `DB_HOST` | `config.yaml` (`glitchtip_data_ip`) | A.9 (compose input) |
| `/kubernetes/glitchtip` | `DB_PORT` | `config.yaml` (`glitchtip_postgres_port`) | A.9 (compose input) |
| `/kubernetes/glitchtip` | `REDIS_PASSWORD` | `config.yaml` (`glitchtip_redis_password`) | A.9 (compose input); Ansible glitchtip_data role (cross-scope read) |
| `/kubernetes/glitchtip` | `REDIS_PORT` | `config.yaml` | A.9 (compose input) |
| `/kubernetes/glitchtip` | `EMAIL_URL` | `config.yaml` (`glitchtip_email_url`) | A.9 |
| `/kubernetes/glitchtip` | `ADMIN_USERNAME` | `config.yaml` (`glitchtip_admin_username`) | A.9 (trimmed bootstrap Job) |
| `/kubernetes/glitchtip` | `ADMIN_EMAIL` | `config.yaml` (`glitchtip_admin_email`) | A.9 (trimmed bootstrap Job) |
| `/kubernetes/glitchtip` | `ADMIN_PASSWORD` | `config.yaml` (`glitchtip_admin_password`) | A.9 (trimmed bootstrap Job) |
| `/kubernetes/glitchtip` | `BOOTSTRAP_MCP_TOKEN` | `config.yaml` (`glitchtip_bootstrap_mcp_token`) | A.9 (trimmed bootstrap Job) |
| `/kubernetes/deeptutor` | `LLM_BINDING_API_KEY` | `config.yaml` (`deeptutor_llm_api_key`) | A.9 |
| `/kubernetes/deeptutor` | `EMBEDDING_BINDING_API_KEY` | `config.yaml` (`deeptutor_embedding_api_key`) | A.9 |
| `/kubernetes/deeptutor` | `PERPLEXITY_API_KEY` | `config.yaml` (`deeptutor_perplexity_api_key`) | A.9 |
| `/ansible/cloudflare` | `tunnel_json` | `ansible/roles/cloudflare/files/cloudflare-tunnel.sops.json` (full JSON blob) | A.10 — cloudflare role writes cloudflared credentials file |
| `/ansible/cloudflare` | `email` | `config.yaml` (`cloudflare_email`) | *No current consumer; retained per operator direction for future Cloudflare-account-email uses* |
| `/ansible/proxmox` | `cipassword` | Bitwarden `homelab/bootstrap/proxmox-cipassword` (Infisical is the steady-state mirror) | A.10 (chpasswd); A.11 Terraform (cross-scope read) |
| `/ansible/proxmox` | `api_token_id` | Bitwarden `homelab/bootstrap/proxmox-api-token-id` (mirror) | A.11 Terraform (cross-scope read) |
| `/ansible/proxmox` | `api_token_secret` | Bitwarden `homelab/bootstrap/proxmox-api-token` (mirror) | A.11 Terraform (cross-scope read) |
| `/ansible/services` | `honcho_postgres_password` | `ansible/group_vars/services.sops.yaml` | A.10 — honcho role |
| `/ansible/services` | `honcho_redis_password` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_auth_jwt_secret` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_webhook_secret` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_llm_anthropic_api_key` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_llm_openai_api_key` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_llm_gemini_api_key` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_llm_groq_api_key` | `services.sops.yaml` | A.10 |
| `/ansible/services` | `honcho_sentry_dsn` | `services.sops.yaml` | A.10 |
| `/terraform/unifi` | `username` | Bitwarden `homelab/bootstrap/unifi-username` (mirror) | A.11 |
| `/terraform/unifi` | `password` | Bitwarden `homelab/bootstrap/unifi-password` (mirror) | A.11 |
| `/terraform/unifi` | `iot_wlan_passphrase` | `terraform/unifi/terraform.tfvars` | A.11 |

**Nullable honcho keys** (`honcho_llm_openai_compatible_api_key`, `honcho_llm_vllm_api_key`, `honcho_vector_store_turbopuffer_api_key`) are **skipped at migration** when null. Ansible consumers use `| default(omit)` fallback. Operator adds them later if/when those integrations are enabled.

**URL composition (glitchtip):** Raw components live at `/kubernetes/glitchtip/`. The InfisicalSecret CRD uses `spec.template.data` (Go templates, `{{ .KEY }}` syntax — confirmed supported in operator v0.7+ per [Infisical PR #3326](https://github.com/Infisical/infisical/pull/3326)) to compose URLs at reconcile time:

```yaml
spec:
  template:
    data:
      DATABASE_URL: "postgresql://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASSWORD }}@{{ .DB_HOST }}:{{ .DB_PORT }}/{{ .POSTGRES_DB }}"
      MAINTENANCE_DATABASE_URL: "postgresql://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASSWORD }}@{{ .DB_HOST }}:{{ .DB_PORT }}/{{ .POSTGRES_DB }}"
      REDIS_URL: "redis://:{{ .REDIS_PASSWORD }}@{{ .DB_HOST }}:{{ .REDIS_PORT }}/0"
```

Rotating `POSTGRES_PASSWORD` in Infisical → operator re-renders the managed Secret on next reconcile → pod restart picks up new `DATABASE_URL`. No duplicate Infisical writes, no cron, no repo-side composition.

**Shared-value scope model:** One canonical path per secret. When a second identity needs the value (e.g., Terraform reading `cipassword` from `/ansible/proxmox/`, or Ansible glitchtip_data role reading `POSTGRES_PASSWORD`/`REDIS_PASSWORD` from `/kubernetes/glitchtip/`), A.7 provisions a **targeted cross-scope read permission** on that specific key. No mirrored paths, no duplicate writes on rotation.

**Bitwarden↔Infisical dual-storage model:** Bitwarden holds the minimum bootstrap-only set needed to rebuild Infisical from zero (infisical core secrets, proxmox + unifi bootstrap creds, cipassword, Ansible/Terraform machine-identity client credentials, ArgoCD admin password hash). Infisical is the authoritative source for steady-state — including mirrored copies of proxmox/unifi/cipassword so future automation servers without Bitwarden access can read them via machine identity. A rotation helper script writes both stores for the overlapping set; Infisical is the primary write target.

**ACME contact split:** A new CONFIG variable `acme_contact_email` is added to `config.yaml` for the cert-manager ClusterIssuer's `acme.email` field. Previously the template inlined `cloudflare_email` (SECRET) which would have forced `task configure` to reach Infisical for non-secret rendering and created a DR bootstrap cycle (Infisical ingress needs cert → cert needs ClusterIssuer → ClusterIssuer needs Infisical). The Let's Encrypt contact address is semantically independent from the Cloudflare account email and is genuinely CONFIG.

**Explicitly NOT migrated (deletions, not Infisical entries):**

- `/kubernetes/argocd/repo_credentials` — phantom; no such key exists in `secrets.sops.yaml.j2`. Dropped from inventory.
- `/kubernetes/argocd/ghcr_*` — `kubernetes/core/argo-cd/secrets/ghcr-registry.secret.yaml` is orphaned (zero `imagePullSecrets` references; all in-cluster `ghcr.io` pulls use public images). Deleted entirely in A.12.2.
- `/ansible/cert-manager/*` — three of four keys in `cert-manager/defaults/main.sops.yaml` are CONFIG dupes; the one secret (`cloudflare_api_token`) already lives at `/kubernetes/cert-manager/`. Path dropped.
- `/ansible/cloudflare/api_token` — dead variable; the ansible cloudflare role references only `AccountTag`/`TunnelID`/`TunnelSecret`/`Endpoint` (from tunnel_json blob) plus `cloudflare_tunnel_name`/`cloudflare_domain`. Never touches `cloudflare_api_token`.
- `/terraform/cloudflare/*` — `terraform/cloudflare/` contains only `secret.sops.yaml` with no `.tf` files or `var.cloudflare_apikey` references anywhere in the repo. Orphaned config. Deleted in A.12.3.
- `/terraform/proxmox/*` — proxmox values live under `/ansible/proxmox/` with Terraform cross-scope reads. One canonical path per value.
- 7 glitchtip BOOTSTRAP variables (`BOOTSTRAP_ORGANIZATION_NAME`, `_ORGANIZATION_SLUG`, `_PROJECT_NAME`, `_PROJECT_SLUG`, `_PROJECT_PLATFORM`, `_PROJECT_KEY_NAME`, `_PROJECT_KEY_PUBLIC_KEY`) + the `glitchtip-bootstrap-artifacts` Secret write — glitchtip-bootstrap-admin Job is trimmed in A.9 to admin + MCP token creation only; org/project/DSN setup moves to manual UI configuration (no other app in this repo consumes the bootstrap artifacts).
- `terraform/kubernetes-nodes/terraform.tfvars` — byte-identical duplicate of `terraform/unifi/terraform.tfvars`; the dir has an empty `main.tf` and only runs `unifi_users.tf`. Delete the duplicate file (keep `unifi/terraform.tfvars` as the canonical source) during A.11 cleanup.

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

**ArgoCD project policy updates required before app migration:**

- Add `secrets.infisical.com` / `InfisicalSecret` to any AppProject that will own these CRDs during Phase A.
- At minimum, update the `apps` AppProject before migrating GlitchTip.
- Keep app-specific `InfisicalSecret` manifests next to the app that consumes them; do not introduce a second Argo application topology just for secret sync.

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

Create three separate machine identities in Infisical, each scoped to the minimum paths it needs.

This step is where the workstation credentials that were intentionally omitted from A.1 are first created. After each identity is created, copy its non-bootstrap client credentials into Bitwarden cloud so future workstation runs still have an external trust root.

**1. Kubernetes Operator Identity (K8s Auth)**

- Auth method: Kubernetes Auth (service account tokens)
- Scoped to: `/kubernetes/*` paths in `the-lab` project
- Used by: Infisical Operator running in-cluster
- Identity ID is hardcoded into each InfisicalSecret CRD manifest

**2. Ansible Identity (Universal Auth)**

- Auth method: Universal Auth (client_id + client_secret)
- Scoped to: `/ansible/*` and `/kubernetes/argocd/*` paths in `the-lab` project
- Used by: Ansible playbooks running on workstation
- `client_id` and `client_secret` are created here, then stored in Bitwarden cloud as post-bootstrap external workstation credentials
- Injected as `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` env vars by the bootstrap wrapper script for steady-state Ansible runs

**3. Terraform Identity (Universal Auth)**

- Auth method: Universal Auth (client_id + client_secret)
- Scoped to: `/terraform/*` paths in `the-lab` project
- Used by: Terraform runs on workstation
- `client_id` and `client_secret` are created here, then stored in Bitwarden cloud as post-bootstrap external workstation credentials
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

**Secret-readiness rule for all Phase A app migrations:**

Do not rely on ArgoCD sync waves alone to prove that an operator-managed Secret is ready. `InfisicalSecret` reconciliation is asynchronous. For any app or hook job that must consume the resulting Kubernetes Secret during sync, use a standard readiness gate:

1. Apply the `InfisicalSecret` manifest first.
2. Add a reusable `PreSync` wait Job convention that blocks until the expected native Kubernetes Secret exists (and, if needed, contains the expected keys).
3. Only then allow the consuming workload, Helm release, or bootstrap job to proceed.

This keeps the current app auto-discovery model intact and avoids introducing a separate Argo application topology just to sequence secret sync.

### A.9 Migrate Kubernetes Secrets (Per-App)

DeepTutor is part of the retained app set. Its broader redesign/upgrade remains deferred, but its current three runtime API-key secrets should still migrate during Phase A so the Sealed Secrets controller can be removed globally.

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
  # Raw components live at /kubernetes/glitchtip/; operator composes URLs at reconcile time.
  # Any SECRET key present in the source path is also exposed verbatim in the managed Secret.
  template:
    data:
      DATABASE_URL: "postgresql://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASSWORD }}@{{ .DB_HOST }}:{{ .DB_PORT }}/{{ .POSTGRES_DB }}"
      MAINTENANCE_DATABASE_URL: "postgresql://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASSWORD }}@{{ .DB_HOST }}:{{ .DB_PORT }}/{{ .POSTGRES_DB }}"
      REDIS_URL: "redis://:{{ .REDIS_PASSWORD }}@{{ .DB_HOST }}:{{ .REDIS_PORT }}/0"
  secretsScope:
    projectSlug: the-lab
    envSlug: prod
    secretsPath: /kubernetes/glitchtip
```

The `identityId` is the K8s Operator machine identity created in A.7. It is a public identifier (not a secret) and is hardcoded in each InfisicalSecret manifest.

**Glitchtip bootstrap Job trimmed (A.9 scope change):**

The current `glitchtip-bootstrap-admin` PostSync Job does five things: (1) creates the admin superuser, (2) creates an Organization, (3) creates a Project with a deterministic DSN, (4) creates an MCP API token, (5) writes a `glitchtip-bootstrap-artifacts` Secret with the DSN and token. Research against the Glitchtip 6.0.10 image confirmed that Glitchtip does **not** auto-create a superuser from `envFrom`-supplied environment variables, so a Job is required for step 1. However, grep across the repo shows **zero consumers** of the `glitchtip-bootstrap-artifacts` Secret, the auto-created DSN, or the MCP token — steps 2–5 are pre-configuring UI state that the operator has decided to manage manually via the Glitchtip UI after deploy.

Trim the Job during A.9 to:

- Create (or idempotently update) the admin superuser from `GLITCHTIP_ADMIN_USERNAME` / `GLITCHTIP_ADMIN_EMAIL` / `GLITCHTIP_ADMIN_PASSWORD`.
- Create (or idempotently update) the MCP API token from `GLITCHTIP_BOOTSTRAP_MCP_TOKEN` (label comes from `config.yaml` via a static `env:` entry on the Job; no Infisical key for the label).
- Delete the org/project/project-key creation logic, the `glitchtip-bootstrap-artifacts` Secret write, and the Kubernetes API client code that supports it.

Drop from `config.yaml` and from the InfisicalSecret source path:

- `glitchtip_bootstrap_organization_name`
- `glitchtip_bootstrap_organization_slug`
- `glitchtip_bootstrap_project_name`
- `glitchtip_bootstrap_project_slug`
- `glitchtip_bootstrap_project_platform`
- `glitchtip_bootstrap_project_key_name`
- `glitchtip_bootstrap_project_key_public_key`

The `glitchtip_bootstrap_mcp_token_label` variable is a non-secret display label; keep it in `config.yaml` as CONFIG and render it as a static `env:` entry on the Job (same pattern as `GLITCHTIP_DOMAIN` / `GLITCHTIP_NAMESPACE` today). Also render `DEFAULT_FROM_EMAIL` (CONFIG per audit §1b) as a static `env:` entry on the Deployment rather than an Infisical-managed Secret key.

**Placement and sequencing rules:**

- Keep each `InfisicalSecret` manifest in the same app directory as the workload that consumes it.
- Update the owning AppProject to allow `secrets.infisical.com` resources before applying the CRD.
- For apps that currently assume a secret exists during sync (for example, cert-manager and GlitchTip), pair the `InfisicalSecret` with the standard `PreSync` wait Job convention from A.8 rather than relying on sync waves alone.

**Hard gate before A.12.2 (Sealed Secrets removal):**

Do **not** remove the Sealed Secrets controller until every app that currently depends on a SealedSecret has a verified replacement native Kubernetes Secret already present via the new mechanism. At minimum, Phase A must verify replacement Secrets for:

- cert-manager
- glitchtip
- deeptutor

Use `kubectl get secret -A` and the app-specific readiness checks to confirm the replacement Secrets exist before touching A.12.2.

**Apps to migrate via InfisicalSecret CRDs (in order):**

1. **cert-manager** — 1 secret (`cloudflare_api_token`). `cloudflare_email` is no longer inlined in the ClusterIssuer — the template is updated to reference the new `acme_contact_email` CONFIG variable instead. Low secret count, existing certs buffer any issues during migration.
2. **glitchtip** — 13 raw components under `/kubernetes/glitchtip/`; operator composes `DATABASE_URL`/`MAINTENANCE_DATABASE_URL`/`REDIS_URL` via `spec.template.data`. Bootstrap Job trimmed (see above).
3. **deeptutor** — 3 API-key secrets only. Migrate the current secret contract without redesigning or upgrading the app in this plan.

**Not migrated via InfisicalSecret CRDs:**

- **argo-cd** — ArgoCD secrets are created by the Ansible bootstrap flow (A.10), not by the Infisical Operator. ArgoCD needs its secrets before the operator exists, and having the operator manage Secrets in the argocd namespace risks ownership conflicts with ArgoCD's own secret management. Values are stored in Infisical at `/kubernetes/argocd` for Ansible to look up, but no InfisicalSecret CRD is created in the argocd namespace.

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
- The Infisical value for the admin credential is a **precomputed bcrypt hash** stored as `admin_password_hash`, not a plaintext password.
- The Ansible role should pass that stored hash straight through to ArgoCD rather than generating a fresh hash during rendering or apply time.

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

**Roles and live secret inputs to migrate:**

- `ansible/roles/argocd/defaults/main.sops.yaml` — admin password hash replaced by `/kubernetes/argocd/admin_password_hash` lookup; other keys are CONFIG dupes (already in `config.yaml`).
- `ansible/roles/cloudflare/defaults/main.sops.yaml` — contains `cloudflare_email` and `cloudflare_api_token` as unused dead variables; the cloudflare role's tasks reference neither. Only the tunnel JSON blob migrates.
- `ansible/roles/cloudflare/files/cloudflare-tunnel.sops.json` → `/ansible/cloudflare/tunnel_json` (single blob; Ansible materializes the JSON file on the tunnel host at runtime).
- `ansible/roles/cert-manager/defaults/main.sops.yaml` — **all four keys are CONFIG dupes or already migrated elsewhere**; no `/ansible/cert-manager/` Infisical path is created. `cert_manager_namespace`, `cert_manager_cloudflare_api_secret_name`, `cert_manager_cloudflare_api_secret_key` remain in `config.yaml`. `cloudflare_api_token` already lives at `/kubernetes/cert-manager/` for the InfisicalSecret CRD.
- `ansible/group_vars/services.sops.yaml` — all honcho_* keys migrate to `/ansible/services/` (9 non-null + 3 nullable that are skipped at migration).
- `ansible/inventory/group_vars/all.sops.yaml` — `cipassword` (single key) migrates to `/ansible/proxmox/cipassword`. This is an Infisical mirror of the Bitwarden bootstrap value; steady-state Ansible reads from Infisical.

**ClusterIssuer template update (no bootstrap cycle):**

The cert-manager ClusterIssuer template at `templates/kubernetes/core/cert-manager/templates/cluster-issuer.yaml.j2` currently inlines `{{ cloudflare_email }}`. Update it to inline `{{ acme_contact_email }}` (new CONFIG variable in `config.yaml`) instead. The ACME contact is the Let's Encrypt cert-expiry notification address — genuinely public — and is semantically independent from the Cloudflare account email. This keeps `task configure` Infisical-free and avoids a DR bootstrap cycle (Infisical ingress needs a TLS cert → cert needs ClusterIssuer → ClusterIssuer would otherwise need Infisical). `cloudflare_email` itself stays SECRET at `/ansible/cloudflare/email` with no current consumer, retained for future Cloudflare-account-email use cases.

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

#### Terraform bootstrap/state boundary

The shared service-host Terraform module is for infrastructure shape only. Do not push application/bootstrap secrets down into it.

- The bootstrap root `terraform/infisical-data/` remains completely independent from self-hosted Infisical
- Do **not** add the Infisical provider to `terraform/infisical-data/`
- Do **not** put secrets in `infisical-data.auto.tfvars` — all secret variables (`pm_api_token_id`, `pm_api_token_secret`, `cipassword`, `unifi_username`, `unifi_password`) must flow exclusively through `TF_VAR_` env vars exported by the wrapper script
- A committed `.auto.tfvars` file may contain **only** non-secret infrastructure shape variables: `pm_api_url`, `ssh_key_file`, `template_name`, `unifi_api_url`
- The `.auto.tfvars.j2` template must be updated (or replaced with a non-secret-only version) to reflect this split
- Mark secret variables in `variables.tf` with `sensitive = true` so Terraform redacts them from plan/apply output
- Avoid passing DB password, Redis password, `AUTH_SECRET`, or `ENCRYPTION_KEY` through Terraform resources or outputs unless strictly required

Use the Infisical Terraform provider and ephemeral secret resources only for steady-state Terraform paths after self-hosted Infisical is healthy. The shared module and the bootstrap root must stay usable without Infisical.

**Configs to migrate:**

Phase A covers every repo-managed Terraform input currently known to contain a secret. Do not leave plaintext `tfvars` / `auto.tfvars` behind accidentally. If any path is intentionally deferred, name it explicitly in this section before implementation starts.

Current known Terraform secret-bearing inputs:

- `terraform/cloudflare/secret.sops.yaml` — **orphaned**. The directory contains only this SOPS file; no `.tf`, no `.tfvars`, and zero `var.cloudflare_apikey` / `var.cloudflare_email` references anywhere in the repo. **Deleted entirely** in A.12.3, not migrated.
- `terraform/unifi/terraform.tfvars` — only `iot_wlan_passphrase` is a non-bootstrap secret that lives in Infisical; `username`/`password` are Infisical mirrors of Bitwarden bootstrap values.
- `terraform/kubernetes-nodes/terraform.tfvars` — **byte-identical duplicate** of `terraform/unifi/terraform.tfvars` (same md5). The dir has an empty `main.tf` and only runs `unifi_users.tf` (which reuses unifi provider creds). Delete the duplicate file during A.11 cleanup; point `terraform/kubernetes-nodes/` at the canonical unifi tfvars via `-var-file` if still needed.
- `terraform/glitchtip-data/glitchtip-data.auto.tfvars` — secret values (pm_api_token_*, cipassword, unifi_*) come from loader-exported `TF_VAR_*` env vars; the `.auto.tfvars` file itself retains only non-secret shape (pm_api_url, ssh_key_file, template_name, unifi_api_url).
- `terraform/honcho/honcho.auto.tfvars` — same pattern as glitchtip-data.
- `terraform/proxmox-nodes/` variable injection path for Proxmox credentials — reads from `/ansible/proxmox/` via ephemeral Infisical resources with cross-scope read granted to the Terraform identity.

**Dual-storage model (Bitwarden mirror):** Terraform secrets that also need to exist in Bitwarden (to survive a full DR rebuild where Infisical doesn't exist yet) are `proxmox_api_token_id`, `proxmox_api_token_secret`, `cipassword`, `unifi_username`, `unifi_password`. Bitwarden is the bootstrap source; Infisical is the steady-state authoritative source. A rotation helper script writes both. Other Terraform secrets (`iot_wlan_passphrase`, anything added later) live in Infisical only.

**Cleanup:**

- Delete `terraform/cloudflare/secret.sops.yaml` and the `terraform/cloudflare/` directory (orphaned — confirmed no consumers).
- Delete `terraform/kubernetes-nodes/terraform.tfvars` (byte-identical duplicate of `terraform/unifi/terraform.tfvars`).
- Remove SOPS provider configuration from every `providers.tf`.
- Remove any temporary `*.auto.tfvars` secret inputs that have been replaced by Infisical lookups or ephemeral resources.

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

**Rewrite `templates/kubernetes/core/argo-cd/app.yaml.j2`:**

- Remove the `helm.valueFiles` entry that calls `build_helm_secrets_path(...)`
- Stop referencing `secrets.sops.yaml` as a remote helm-secrets value file
- Ensure the ArgoCD application definition no longer depends on helm-secrets, SOPS, Age, or the helper function in `makejinja/plugin.py`

**Remove from `ansible/roles/argocd/defaults/main.sops.yaml` (file deleted entirely in A.10):**

- `helm_secrets_age_key_secret_name`
- `helm_secrets_age_key_secret_namespace`

**Remove from `config.yaml`:**

- `helm_secrets_age_key_secret_name`
- `helm_secrets_age_key_name`

**Remove from `ansible/roles/k3s/tasks/main.yaml`:**

- The Helm Secrets plugin installation task

**Verify after teardown:**

- ArgoCD starts without the init container or volume mounts
- All existing ArgoCD Applications still sync successfully
- No `helm-secrets-private-keys` Secret remains in the argocd namespace

#### A.12.2 Sealed Secrets Removal

**Hard gate before teardown:**

- Do **not** begin A.12.2 until every current SealedSecret consumer has a verified replacement native Kubernetes Secret already present
- Verify this explicitly for `cert-manager`, `glitchtip`, and `deeptutor`
- Remove old SealedSecret artifacts only after the replacement Secrets are present and the consuming apps remain healthy

- Delete `kubernetes/core/sealed-secrets/` (entire directory)
- Delete `templates/kubernetes/core/sealed-secrets/` if it exists
- Delete `kubernetes/core/argo-cd/secrets/ghcr-registry.secret.yaml` (orphaned — zero `imagePullSecrets` references in the repo; artifact from prior ARC-runner cleanup). Delete the parent `kubernetes/core/argo-cd/secrets/` directory if it becomes empty.
- Remove `SealedSecret` from the apps ArgoCD project whitelist (`kubernetes/bootstrap/projects/apps.yaml`)
- Remove the SealedSecret-specific `ignoreDifferences` rule from `kubernetes/bootstrap/applicationsets/cluster-apps.yaml` after Sealed Secrets are gone
- Remove `bitnami-labs/sealed-secrets` chart repo from both the core and infrastructure ArgoCD projects' `spec.sourceRepos`
- Delete `.sealed-secrets-public-cert.pem` only after all `seal_secret()`-backed templates are gone from the active render path
- Remove `seal_secret()` function from `makejinja/plugin.py`
- Remove `kubeseal_version` and `sealed_secrets_chart_version` from `config.yaml`

#### A.12.3 SOPS/Age Removal + Deterministic Template Rendering

- Delete root `.sops.yaml`
- Delete obsolete `templates/.sops.yaml` and `tmpl/.sops.yaml`
- Delete `.taskfiles/SecretTasks.yaml`
- Remove `encrypt-secrets` task from `Taskfile.yml`
- Rewrite `task configure` so that Phase A keeps it for non-secret work only (`render-templates` + `download-cert-manager-crds`) and no longer invokes any SOPS/Age encryption flow
- Keep `task configure` rendering the non-secret Kubernetes, Ansible, and Terraform layers, including the shared `proxmox-lxc-service` module and the thin service roots
- Remove `sops_age_key_file` and any Age-related variables from `config.yaml`
- Remove all secret values from `config.yaml` (non-secret variables remain, including the service-host catalog used by Terraform/Ansible rendering)
- Remove `bcrypt_password()` from `makejinja/plugin.py`
- Remove `seal_secret()` from `makejinja/plugin.py`
- Verify no active template render path remains nondeterministic

#### A.12.4 Remaining Cleanup

- Remove `build_helm_secrets_path()` function from `makejinja/plugin.py` only after `templates/kubernetes/core/argo-cd/app.yaml.j2` no longer calls it
- Add the required `InfisicalSecret` allowlists to the owning AppProjects and remove obsolete SealedSecret policy rules
- Remove any `community.sops` references from Ansible requirements or configuration
- Verify no `.sops.yaml`, `.secret.yaml`, `kubeseal`, `bcrypt_password`, or Age key references remain in tracked files

#### A.12.5 Replace `sops-pre-commit` with `infisical scan`

Once SOPS is removed from the repo (A.12.3), the existing `onedr0p/sops-pre-commit` `forbid-secrets` hook in `.pre-commit-config.yaml` becomes stale — it is a SOPS-specific check that assumes encrypted files are the norm. With no SOPS in the pipeline, the repo needs a replacement guardrail against accidentally committing plaintext secrets.

**Action:**

- Remove the `onedr0p/sops-pre-commit` block from `.pre-commit-config.yaml`.
- Add an `infisical scan git-changes` hook to the same file. The CLI exposes a pre-commit-friendly `scan git-changes` subcommand that inspects uncommitted changes for leaked secrets; `infisical scan install pre-commit` wires it in automatically, or it can be added manually as a `local` hook invoking the CLI directly.
- Document the installed hook in the repo README or AGENTS.md (optional — the hook is self-documenting in `.pre-commit-config.yaml`).
- Verify: stage a deliberately leaky blob (e.g., a dummy AWS access key pattern) and confirm `pre-commit run --all-files` blocks it.

**Why this belongs in Phase A cleanup:** the migration from SOPS to Infisical removes encryption-at-rest as a safety net. Without a replacement guardrail, a stray paste of a plaintext secret into a template or tfvars file commits clean — the pre-commit hook is the only thing catching it before it hits Git history.

#### A.12.6 Evaluate makejinja Replacement (Deferred)

After the secret-path plugin functions are removed, the remaining rendering surface is straightforward Jinja2 + YAML. `makejinja` is a niche Python tool with a small user base that requires `pipx`, Python, and injected dependencies (`bcrypt`, `attrs`, `pyyaml`). This creates operational friction — `task configure` cannot run on the host workstation without the devcontainer or a manual `pipx install` chain.

Evaluate replacing `makejinja` with a more portable alternative:

- A minimal Python script (the actual rendering logic is ~50 lines)
- A standalone CLI like `j2cli` or `jinja2-cli`
- A vendored Go binary for zero-dependency rendering

The goal is to preserve the `config.yaml` + `task configure` pattern (centralized non-secret config rendered across Kubernetes, Ansible, and Terraform) while removing the niche tooling dependency. The pattern is valuable; the tool is the liability.

**What survives Phase A:**

- `config.yaml` (non-secret variables only)
- `makejinja` (renders non-secret templates, minus `bcrypt_password`, `seal_secret`, and `build_helm_secrets_path`) — candidate for replacement in A.12.5
- `task configure` (non-secret rendering only)

Nothing from the old SOPS or Age toolchain is functional after Phase A.

### A.13 Trust Chain Heartbeat

The DR runbook written at the end of Phase A is a static document. It proves nothing until someone executes it — and by that time you're in a disaster. The canary InfisicalSecret from A.8 validates one leg of the trust chain (Infisical Operator → K8s Secret) but leaves the rest unmonitored. A.13 closes this gap with a scheduled validation that continuously proves the full Bitwarden → Infisical → K8s/Ansible/Terraform trust chain is live and recoverable.

This is what converts the DR runbook from a hope-based recovery strategy into an evidence-based one.

#### What it validates

The heartbeat checks each trust layer independently. A failure in any leg is actionable on its own.

**Leg 1 — Layer 0 (Bitwarden cloud):**

- All 5 initial bootstrap items from A.1 exist and are readable (`homelab/bootstrap/infisical-*`, `homelab/bootstrap/proxmox-api-token`)
- All 4 post-bootstrap workstation credentials from A.7 exist and are readable (Ansible + Terraform machine identity `client_id` / `client_secret`)
- Validates: the external trust root has not silently degraded (accidental deletion, Bitwarden org policy changes, item corruption)

**Leg 2 — Layer 1 health (Infisical):**

- Infisical API returns healthy (`GET /api/status` or equivalent health endpoint)
- Infisical PostgreSQL accepts connections from the LXC (basic `pg_isready` or equivalent)
- Canary secret round-trip: write a timestamped nonce to a dedicated `/heartbeat` path in Infisical, read it back, verify match, delete it
- Validates: the secret management server itself is operational, not just reachable

**Leg 3 — Layer 1 → Layer 2 (Kubernetes):**

- K8s Operator machine identity can authenticate to Infisical
- The permanent canary InfisicalSecret from A.8 has reconciled within the expected window (check `secrets.infisical.com/version` annotation timestamp)
- Validates: the operator path that all K8s apps depend on is functional end-to-end

**Leg 4 — Layer 1 → Layer 2 (Ansible):**

- Ansible machine identity (`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` from Bitwarden) can authenticate to Infisical
- A read from `/ansible/cloudflare` (or any known populated path) returns a non-empty result
- Validates: workstation-driven Ansible runs will not fail at secret lookup time

**Leg 5 — Layer 1 → Layer 2 (Terraform):**

- Terraform machine identity can authenticate to Infisical
- A read from `/terraform/cloudflare` (or any known populated path) returns a non-empty result
- Validates: workstation-driven Terraform runs will not fail at secret lookup time

**Implementation note for Legs 4 and 5:**

Use the Infisical CLI for the auth + read round-trip rather than hand-rolled `curl` against the REST API. The failure modes are clearer and the CLI handles token exchange natively:

```bash
export INFISICAL_API_URL="https://infisical.local.bysliek.com"
export INFISICAL_TOKEN=$(infisical login \
  --method=universal-auth \
  --client-id="$ANSIBLE_CLIENT_ID" \
  --client-secret="$ANSIBLE_CLIENT_SECRET" \
  --silent --plain)
infisical secrets get --path /ansible/cloudflare --env prod email --silent
```

A non-zero exit code from either `infisical login` or `infisical secrets get` is an actionable failure for the corresponding leg. Repeat with the Terraform machine identity for Leg 5.

**Leg 6 — Backup chain:**

- TrueNAS NFS mount is accessible from the Infisical LXC
- Most recent `pg_dump` file exists and is less than 26 hours old (allows for daily schedule + margin)
- Backup file is non-empty and passes basic integrity check (`pg_restore --list` against the dump)
- Validates: if Legs 1-5 all fail simultaneously, the recovery path still works

#### Implementation

The heartbeat is a single script (~80-120 lines of bash) that runs each leg sequentially and reports per-leg pass/fail. No new infrastructure — it uses tools already present in the stack.

**Runtime environment:** K8s CronJob in a utility namespace (e.g., `infisical` or a dedicated `heartbeat` namespace). The CronJob pod needs:

- `rbw` CLI (Bitwarden, `RBW_PROFILE=bootstrap`) — for Leg 1
- `curl` — for Leg 2 (Infisical API)
- `kubectl` access — for Leg 3 (canary check)
- Infisical SDK or `curl` with Universal Auth — for Legs 4-5
- SSH or NFS access to the Infisical LXC — for Leg 6 (backup check)

Alternative: run from the workstation as a systemd timer if the K8s CronJob approach creates too many access-boundary complications. The workstation already has `rbw`, `kubectl`, `ssh`, and network access to everything. A workstation timer is simpler to bootstrap and avoids putting Bitwarden credentials inside the cluster.

**Schedule:** Daily. The heartbeat does not need to run more frequently — its purpose is to detect silent rot over days/weeks, not minute-level outages. The canary InfisicalSecret already covers real-time operator health.

**Alerting:** On any leg failure, POST to GlitchTip (already deployed). The alert should identify which specific leg failed so the operator can triage without re-running the full check.

**Bootstrap dependency:** The heartbeat itself depends on Infisical being deployed and all machine identities existing. It cannot run until after A.8 (canary validated) and A.7 (identities created). It should be deployed as one of the last Phase A deliverables, after the migration is complete but before Phase A is declared done.

#### What this catches that the current plan does not

| Silent failure mode | Current detection | With heartbeat |
|---|---|---|
| Bitwarden item accidentally deleted | None — discovered during DR | Leg 1 fails next daily run |
| Machine identity token expired | None — discovered when Ansible/Terraform fails | Legs 4-5 fail next daily run |
| Infisical DB silently corrupted | None — discovered when operator can't reconcile | Leg 2 fails (round-trip check) |
| TrueNAS backup job silently stopped | None — discovered during DR restore | Leg 6 fails next daily run |
| Infisical LXC disk full (backups can't write) | None — discovered when backup restore fails | Leg 6 fails (backup age check) |
| Operator service account misconfigured after cluster change | Canary goes stale (A.8) | Leg 3 explicitly checks + Leg 3 gives richer diagnostics |
| Workstation credentials out of sync with Infisical | None — discovered when Ansible run fails | Legs 4-5 fail with auth error |

#### Operational rules

- The heartbeat script is committed to the repo (e.g., `scripts/trust-chain-heartbeat.sh`)
- The heartbeat is not a substitute for the DR runbook — the runbook documents the full recovery procedure; the heartbeat proves the chain is intact so the runbook will work when needed
- If a leg fails, fix the root cause. Do not suppress or skip legs.
- The heartbeat itself has no secrets hardcoded — it reads Bitwarden credentials at runtime via `rbw` with `RBW_PROFILE=bootstrap` (same pattern as the bootstrap wrapper) and uses in-cluster auth for K8s checks

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
| Bitwarden cloud is unavailable during DR           | Medium   | Keep the external Bitwarden-held secret set minimal, document the initial bootstrap secrets and post-bootstrap workstation credentials clearly, and verify periodic recovery from a clean workstation.                    |
| Infisical LXC down = no new deployments            | High     | K8s Secrets persist after sync; running pods unaffected. Only new deployments/Ansible/Terraform fail. TrueNAS backups enable restore.            |
| Database corruption/loss                           | Critical | Regular PostgreSQL backups to TrueNAS and a documented rebuild procedure from Bitwarden bootstrap secrets.                                       |
| Infisical project abandoned                        | Medium   | MIT licensed, can fork. InfisicalSecret CRDs create standard K8s Secrets — easy to migrate to another tool.                                      |
| Migration window (both systems running)            | Low      | Phased migration, no big-bang cutover.                                                                                                           |
| Ansible/Terraform need network access to Infisical | Medium   | Infisical is on the local network; Bitwarden holds only the initial bootstrap secrets plus the post-bootstrap workstation credentials.                                                             |
| Free tier feature limits                           | Low      | Secret rotation, dynamic secrets, PKI are enterprise. Static secret management covers current use case.                                          |
| ArgoCD prunes operator-managed Secrets             | Medium   | Label-based resource exclusion (`app.kubernetes.io/managed-by: infisical-operator`) configured in A.6. All InfisicalSecret CRDs must carry this label. |
| DeepTutor latest release changes runtime contract  | Medium   | Keep DeepTutor out of the initial critical path, then revisit it later once Infisical patterns are established and the app can be redesigned deliberately. |
| One or two SOPS edge cases survive unnoticed       | Medium   | Explicitly track the bootstrap password path and the Cloudflare tunnel JSON until they have a final replacement.                                 |
| A secret-path helper survives in active templates | Medium   | Explicitly remove `encrypt-secrets`, `seal_secret()`, and `bcrypt_password()` from the active render path and verify `task configure` no longer creates churn without real config changes. |
| Trust chain silently degrades between DR tests    | High     | Daily trust chain heartbeat (A.13) validates all 6 legs from Bitwarden through backups; GlitchTip alerts on any failure within one cycle. |

---

## Disaster Recovery Runbook

Before Phase A is considered complete, write and maintain a DR runbook that can be executed from a clean workstation.

Minimum checklist:

1. Unlock `rbw` agent with `RBW_PROFILE=bootstrap` (`rbw unlock`).
2. Export or inject the initial Bitwarden-held bootstrap secrets via `rbw get`. The loader script (`scripts/load-bootstrap-secrets.sh`) also exports `INFISICAL_API_URL=https://infisical.local.bysliek.com` so subsequent CLI commands resolve against the self-hosted instance.
3. Run the Infisical bootstrap wrapper, which re-applies `terraform/infisical-data/`, re-runs Ansible host configuration, recreates the Kubernetes bootstrap Secrets, and then syncs the Infisical application.
4. Restore PostgreSQL from the latest TrueNAS backup or snapshot.
5. Verify Infisical server health.
6. If the admin identity was lost with the database, re-run `infisical bootstrap --domain "$INFISICAL_API_URL" --email "$INFISICAL_ADMIN_EMAIL" --password "$INFISICAL_ADMIN_PASSWORD" --organization the-lab --output k8-secret --k8-secret-namespace infisical --k8-secret-name infisical-admin-identity --ignore-if-bootstrapped` (see A.4.5). Note the subcommand-specific `--domain` flag — `INFISICAL_API_URL` alone does **not** configure `infisical bootstrap`.
7. If needed, recreate the Ansible and Terraform machine identities in Infisical and store their client credentials back into Bitwarden.
8. Verify the canary `InfisicalSecret` reconciles successfully.
9. Confirm Ansible and Terraform workstation lookups can authenticate with their stored machine identities.

**CLI-driven verification during recovery (ad-hoc):**

- `infisical secrets list --path /kubernetes/glitchtip --env prod` — confirm a known populated path returned without errors after PostgreSQL restore.
- `infisical secrets get --path /ansible/cloudflare --env prod email --silent` — spot-check a specific Ansible-scope value after machine identities are recreated.
- `infisical secrets list --path /terraform/cloudflare --env prod` — same spot-check for the Terraform path.

These are not automated — they exist to give the operator fast, tactile verification during a live DR without clicking through the UI.

This runbook does not need to be fully rehearsal-tested before the migration starts, but it must exist before Phase A is declared complete.

---

## Implementation Order

1. **Phase 0.1:** Retire ARC (controller + runners), including GitHub-side ARC cleanup and live finalizer cleanup if the namespaces stick in `Terminating`
2. **Phase 0.2:** Leave deeptutor in place and explicitly defer its upgrade/evaluation so it does not block the rest of the plan
3. **A.1:** Define the Bitwarden-held initial bootstrap contract (includes Helm chart research for bootstrap Secret schema)
4. **A.2-A.3:** Refactor the service-host Terraform layer to use a shared rendered module with thin roots, migrate existing `glitchtip-data` / `honcho` state into that structure with `moved` blocks, provision the dedicated Infisical data host (10.0.10.85), and wrap the bootstrap flow in one Bitwarden-driven operator command
5. **A.4:** Deploy Infisical server on K8s
6. **A.4.5:** Bootstrap the admin identity via `infisical bootstrap --output k8-secret` (already complete in current env; documented for DR/rebuild reproducibility and required for scripted population in A.5)
7. **A.4.7:** ✅ Complete the Secret/Config Classification Audit; resolve all GRAY items and update A.5 inventory before the migration script is authored
8. **A.5:** ✅ Populate secrets in Infisical via `scripts/populate-infisical.sh` using the admin-identity token from A.4.5 and the audit-derived mapping (completed 2026-04-18: 35 written, 3 nullable skipped)
9. **A.6-A.8:** Deploy Infisical Operator with label-based ArgoCD exclusion, create all three machine identities (K8s Auth + 2x Universal Auth), add required `InfisicalSecret` AppProject allowlists, store workstation credentials in Bitwarden, and validate the permanent canary
10. **A.9:** Migrate K8s secrets via in-app `InfisicalSecret` CRDs using the standard secret-readiness gate (`PreSync` wait Job): cert-manager → glitchtip → deeptutor (ArgoCD secrets handled separately in A.10)
11. **A.10:** Migrate Ansible secrets (includes ArgoCD bootstrap-path secret migration via Infisical lookups)
12. **A.11:** Migrate Terraform secrets across all known repo-managed secret-bearing inputs (ephemeral resources where possible; explicitly defer any exceptions)
13. **A.12.1:** ArgoCD helm-secrets teardown (env vars, init container, Age key volume, wrapper script, and k3s Helm Secrets plugin install)
14. **A.12.2:** Sealed Secrets removal (controller, CRD whitelist, ApplicationSet ignore rule, sourceRepos, cert, plugin function)
15. **A.12.3:** SOPS/Age removal and `task configure` rewrite for non-secret-only Phase A behavior
16. **A.12.4:** Final cleanup sweep
17. **A.12.5:** Replace `sops-pre-commit` `forbid-secrets` hook with `infisical scan git-changes` in `.pre-commit-config.yaml`
18. **DR runbook:** Write the documented recovery checklist before calling Phase A complete
19. **A.13:** Deploy the trust chain heartbeat script and schedule (daily CronJob or workstation timer), verify all 6 legs pass green, configure GlitchTip alerting on failure
20. **Deferred follow-up (A.12.6):** Evaluate replacing `makejinja` with a more portable renderer after the secret-path plugin functions are removed
21. **Deferred follow-up:** Revisit deeptutor with the new secret-management patterns in hand and decide whether to redesign/upgrade it after the current secret migration has already removed its dependence on Sealed Secrets
Each phase is independently valuable, but Phase A is not complete until SOPS and Age are gone from this repo and the trust chain heartbeat is running green.

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
- deeptutor redesign/upgrade is explicitly deferred and does not block the rest of the plan

**After bootstrap implementation:**

- a clean workstation can unlock Bitwarden CLI and run the bootstrap Ansible command
- the command is idempotent
- the `infisical` namespace, `infisical-secrets` Secret, and `infisical-postgres-connection` Secret exist before the Infisical server pods start

**After operator deployment:**

- the canary `InfisicalSecret` reconciles successfully
- the corresponding Kubernetes Secret is created and refreshed as expected
- the ArgoCD exclusion is narrow enough that ArgoCD-managed Secrets such as its own credentials are still reconciled normally

**After each K8s app migration:**

- `kubectl get secret <name> -n <namespace>` confirms operator synced the secret
- the secret-readiness gate succeeds before dependent workloads or hook jobs run
- Pod logs show successful startup with correct config
- ArgoCD sync succeeds, app is healthy, ingress responds
- for deeptutor specifically, the existing deployment remains healthy after `deeptutor-secrets` is replaced by the operator-managed Secret without requiring a broader app redesign

**After Ansible migration:**

- current playbooks that used `community.sops.load_vars` succeed in check mode
- at least one real execution path succeeds with the new lookup model
- the ArgoCD bootstrap path reads `admin_password_hash` from Infisical and passes it through without generating a fresh bcrypt hash during rendering or apply

**After Terraform migration:**

- `terraform plan` resolves secrets from Infisical provider
- old repo-managed Terraform secret artifacts are removed, including committed `tfvars` / `auto.tfvars` inputs that previously held secrets
- rerunning `task configure` without config changes does not dirty the worktree

**After trust chain heartbeat deployment:**

- All 6 heartbeat legs pass on first manual run
- The scheduled job (CronJob or systemd timer) fires on the expected daily cadence
- A simulated failure (e.g., temporarily invalid Bitwarden item name) triggers a GlitchTip alert within one cycle
- The heartbeat script is committed to the repo and does not contain hardcoded secrets

**Phase A complete:**

- All `*.secret.yaml` (SealedSecrets) removed from repo
- `seal_secret()` function removed from `makejinja/plugin.py`
- `bcrypt_password()` removed from `makejinja/plugin.py`
- `encrypt-secrets` removed from `Taskfile.yml`
- ArgoCD reads a precomputed bcrypt hash from Infisical (`admin_password_hash`) instead of generating one during rendering
- No secrets remain in `config.yaml`
- No SOPS or Age configuration remains in the repo
- No `helm-secrets` integration remains in ArgoCD or cluster bootstrap roles
- No encrypted secret artifacts remain in the repo
- Bootstrap depends on Bitwarden cloud plus the repo, not on Git-stored encrypted files
- `task configure` still exists during Phase A but performs non-secret work only
- `task configure` can be rerun without creating Git noise when inputs are unchanged
- A DR runbook exists for recovery from a clean workstation using Bitwarden and TrueNAS backups
- The trust chain heartbeat runs daily, all 6 legs pass green, and GlitchTip alerting is configured for failures
