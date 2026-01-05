# The Lab - Project Context

This file contains important architectural decisions, patterns, and workflows for the-lab project. Claude Code references this file to understand project conventions and avoid re-learning established patterns.

## Project Overview

This is a GitOps-based Kubernetes infrastructure repository using:
- **K3s** on Proxmox VMs
- **ArgoCD** for GitOps continuous deployment
- **Cilium** for CNI and networking
- **SOPS** with Age encryption for secrets management
- **Sealed Secrets** for Kubernetes secret encryption
- **Cert-Manager** with Cloudflare DNS01 for TLS certificates

## Directory Structure

```
.
├── ansible/              # Ansible roles and playbooks for K3s cluster setup
├── kubernetes/           # Kubernetes manifests organized by category
│   ├── bootstrap/        # ApplicationSets and root app definitions
│   ├── core/             # Core infrastructure (sync-wave: -5)
│   ├── infrastructure/   # Infrastructure services (sync-wave: -3)
│   ├── apps/             # Applications (sync-wave: -1)
│   └── monitoring/       # Monitoring stack (sync-wave: 0)
├── templates/            # Jinja2 templates (.j2) for all configs
├── terraform/            # Terraform configs (Cloudflare, etc.)
├── makejinja/            # makejinja binary for template rendering
└── Taskfile.yml          # Task automation (replaces Makefile)
```

## Template and Configuration Workflow

### How it Works
1. **Source files**: All configuration lives in `templates/` as Jinja2 templates (`.j2` files)
2. **Variables**: Defined in `config.yaml` at repository root
3. **Rendering**: `task configure` runs `makejinja` which:
   - Reads all `.j2` files from `templates/`
   - Renders them with variables from `config.yaml`
   - Outputs to corresponding paths (e.g., `templates/kubernetes/core/app.yaml.j2` → `kubernetes/core/app.yaml`)
   - **Important**: makejinja regenerates ALL templates when ANY source changes (task-level granularity, not file-level)
4. **Encryption**: SOPS encrypts files matching `*.sops.*` pattern using Age encryption
   - Uses checksum-based change detection to avoid re-encrypting unchanged files
   - Stores plaintext SHA256 checksums and encrypted backups
   - Only re-encrypts when plaintext content actually changes

### Template Patterns
- Use `{% raw %}` blocks to escape Go templating in ArgoCD ApplicationSets:
  ```yaml
  name: {% raw %}'{{.path.basename}}'{% endraw %}
  ```
- SOPS-encrypted files use `.sops.` in filename: `secrets.sops.yaml`
- Sealed Secrets use `.secret.yaml` extension

### Running the Workflow
```bash
task configure    # Decrypt → Render templates → Encrypt → Cleanup
```

## ArgoCD Application Deployment Pattern

### Architecture
ArgoCD uses a hierarchical structure:
1. **Root Application**: `kubernetes/bootstrap/root-app.yaml`
   - Deployed manually via `kubectl apply`
   - Manages ApplicationSets
2. **ApplicationSets**: `kubernetes/bootstrap/applicationsets/`
   - `cluster-apps.yaml`: Auto-discovers and deploys all apps from directory structure
3. **Applications**: Automatically created from directory discovery

### Directory-Based Auto-Discovery
The `cluster-apps` ApplicationSet automatically creates ArgoCD Applications for any directory matching:
- `kubernetes/core/*`
- `kubernetes/infrastructure/*`
- `kubernetes/apps/*`
- `kubernetes/monitoring/*`

**Application naming**: Directory basename becomes app name (e.g., `kubernetes/core/cert-manager/` → app named `cert-manager`)

### Sync Waves (Deployment Order)
Applications deploy in this order based on directory:
1. **-10**: Special apps (Cilium CNI) - defined in individual `app.yaml`
2. **-5**: Core infrastructure (ArgoCD, Sealed Secrets, Cert-Manager)
3. **-3**: Infrastructure services
4. **-1**: Regular applications
5. **0**: Monitoring stack

### Adding a New Application

#### Option 1: Auto-discovered via ApplicationSet (Recommended)
1. Create directory: `kubernetes/<category>/<app-name>/`
2. Add Kubernetes manifests (can be plain YAML, Kustomize, or Helm)
3. Commit and push - ApplicationSet will auto-create the Application
4. Category determines sync wave automatically

#### Option 2: Explicit Application Definition
For apps needing custom config (different sync wave, Helm charts, etc.):
1. Create `kubernetes/<category>/<app-name>/app.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: my-app
     namespace: argocd
     annotations:
       argocd.argoproj.io/sync-wave: "-10"  # Custom sync wave
   spec:
     project: default
     source:
       repoURL: https://charts.example.com
       chart: my-chart
       targetRevision: 1.2.3
     destination:
       server: https://kubernetes.default.svc
       namespace: my-app
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

### Helm Chart Applications
See examples in:
- [kubernetes/core/cilium/app.yaml](kubernetes/core/cilium/app.yaml)
- [kubernetes/core/sealed-secrets/app.yaml](kubernetes/core/sealed-secrets/app.yaml)

Pattern:
```yaml
source:
  repoURL: https://helm.cilium.io/
  chart: cilium
  targetRevision: 1.16.5
  helm:
    releaseName: cilium
    valuesObject:
      # Helm values here
```

### Important Conventions
- **Namespace**: Usually matches app name (auto-created via `CreateNamespace=true`)
- **Automated sync**: All apps use `automated: {prune: true, selfHeal: true}`
- **ServerSideApply**: Enabled via `syncOptions` to avoid conflicts
- **Project**: Core apps use project matching category (e.g., `core`, `infrastructure`)

## SOPS Encryption Workflow

### Encryption Pattern
- Files matching `*.sops.*` are automatically encrypted by `task configure`
- Age encryption using key from `config.yaml` (`sops_age_key_file`)
- Configuration in `.sops.yaml` at repository root

### Change Detection
To prevent git noise from re-encrypting unchanged files:
1. Before encryption: compute SHA256 checksum of plaintext
2. Compare with stored checksum from `.checksum` file
3. If unchanged: restore from `.encrypted.bak` (skip re-encryption)
4. If changed: encrypt and update backup + checksum
5. Backup/checksum files are gitignored

### Dynamic Content
Some templates have legitimately changing content:
- `bcrypt_password` filter generates new hash with random salt each time
- These files will be re-encrypted on every `task configure` (expected behavior)

## Secrets Management

### Two Secret Types

1. **SOPS-encrypted YAML** (`.sops.yaml`)
   - For Ansible variables, Terraform vars, non-Kubernetes secrets
   - Encrypted at rest in Git
   - Decrypted during `task configure` for rendering
   - Example: `ansible/roles/argocd/defaults/main.sops.yaml`

2. **Sealed Secrets** (`.secret.yaml`)
   - For Kubernetes Secret objects
   - Encrypted with cluster-specific key (not SOPS)
   - Created via `kubeseal` command
   - Example: `kubernetes/core/cert-manager/secrets/cloudflare-api.secret.yaml`

### When to Use Which
- **SOPS**: Configuration values, template variables, Terraform vars
- **Sealed Secrets**: Kubernetes Secret objects deployed to cluster

## Common Operations

### Initial Cluster Setup
```bash
task configure          # Render all configs
task ansible:setup      # Deploy K3s cluster
task bootstrap          # Deploy ArgoCD root app
```

### Adding New Application
```bash
# 1. Create app directory and manifests
mkdir -p kubernetes/apps/myapp
# 2. Add manifests
# 3. Commit and push - ArgoCD auto-deploys

# OR for Helm chart:
# 1. Create from template
# 2. Modify app.yaml
# 3. task configure && commit
```

### Managing Secrets
```bash
# Edit SOPS file (auto-decrypts)
sops ansible/roles/argocd/defaults/main.sops.yaml

# Create Sealed Secret
kubectl create secret generic my-secret --dry-run=client -o yaml | \
  kubeseal -o yaml > kubernetes/apps/myapp/my-secret.secret.yaml
```

## Key Files

- **config.yaml**: All template variables and configuration
- **.sops.yaml**: SOPS encryption rules and Age key configuration
- **Taskfile.yml**: Task automation definitions
- **makejinja.toml**: Template rendering configuration
- **kubernetes/bootstrap/root-app.yaml**: ArgoCD root Application
- **kubernetes/bootstrap/applicationsets/cluster-apps.yaml**: Main ApplicationSet for auto-discovery

## Anti-Patterns to Avoid

1. **Don't** manually edit generated files (files without `.j2` extension in template paths)
2. **Don't** create apps outside the category directories (core/infrastructure/apps/monitoring)
3. **Don't** use different namespace than app name without good reason
4. **Don't** disable automated sync unless absolutely necessary
5. **Don't** create documentation files proactively (only when explicitly requested)
6. **Don't** commit plaintext secrets to Git
7. **Don't** add "Generated with Claude Code" attribution to commits unless explicitly requested

## Tools and Dependencies

- **sops**: Secret encryption/decryption
- **age**: Encryption backend for SOPS
- **kubeseal**: Sealed Secrets CLI
- **kubectl**: Kubernetes CLI
- **task**: Task runner (replaces make)
- **makejinja**: Jinja2 template renderer
- **jq**: JSON processor (used in task scripts)
- **ansible**: Cluster provisioning
- **terraform**: Cloud resource management (Cloudflare)

## Git Workflow

- **Main branch**: `main`
- **Current work branch**: `the-lab-v2`
- **Commit pattern**: Descriptive messages with context
- **Staging**: Use `git add -A` to catch all changes from template rendering

## NFS Storage Configuration

### NFS Client Requirements
All Kubernetes nodes must have NFS client utilities installed to mount NFS volumes. Without these packages, pods will fail to mount NFS shares with error: `bad option; for several filesystems (e.g. nfs, cifs) you might need a /sbin/mount.<type> helper program`

**Rocky Linux**: The `nfs-utils` package is required and is installed via the Ansible `pre` role in [ansible/roles/pre/tasks/main.yaml:50](ansible/roles/pre/tasks/main.yaml#L50)

### NFS Mount Types

There are two patterns for mounting NFS storage in pods:

#### 1. CSI Driver with PersistentVolumeClaims (Recommended for Config Data)
Best for: Application configuration, databases, small frequently-accessed data

**Pattern**:
```yaml
persistence:
  config:
    enabled: true
    type: persistentVolumeClaim
    storageClass: nfs-csi
    accessMode: ReadWriteOnce
    size: 10Gi
```

**Configuration**: NFS CSI driver storage class in [templates/kubernetes/infrastructure/storage/csi-driver-nfs/app.yaml.j2](templates/kubernetes/infrastructure/storage/csi-driver-nfs/app.yaml.j2)

**Mount options**: Uses NFSv3 with `nolock` for TrueNAS compatibility

#### 2. Direct NFS Volume Mounts (Required for Hard-linking)
Best for: Bulk media storage where hard-linking is needed (Sonarr, Radarr, etc.)

**Pattern**:
```yaml
persistence:
  media:
    enabled: true
    type: nfs
    server: 10.0.10.106  # NFS server IP
    path: /mnt/media/hoodflix  # Export path
    globalMounts:
      - path: /data
```

**Why**: Hard-linking requires the source and destination to be on the same filesystem. Using direct NFS mounts ensures downloads and library folders share the same mount point, enabling atomic moves instead of copies.

**TrueNAS Configuration**:
- NFS export must allow writes (maproot=root)
- Dataset permissions must allow Group/Other write access
- Export path should be the actual dataset path (e.g., `/mnt/media/hoodflix`, not just `/media`)

### Storage Architecture

**SSD Storage** (`nfs_server: truenas.local.bysliek.com`, `nfs_export_path: /mnt/k8s-ssd-pool/k8s-nfs-share`):
- Application configs
- Databases
- Fast-access data
- Mounted via NFS CSI driver with PVCs

**HDD Storage** (`10.0.10.106:/mnt/media/hoodflix`):
- Media files (movies, TV shows)
- Downloads
- Bulk storage
- Mounted directly as NFS volumes for hard-linking support

## Cert-Manager Configuration

### ClusterIssuer Naming Convention
The ClusterIssuer template appends nothing to the variable - it uses it directly.

**Critical**: The `cert_manager_issuer_name` variable MUST contain the **full ClusterIssuer name** (not a prefix).

**Current configuration**:
```yaml
cert_manager_issuer_name: "cloudflare-cluster-issuer"
```

**Template usage**:
```jinja
# ClusterIssuer manifest
name: "{{ cert_manager_issuer_name }}"  # Uses variable directly

# Ingress annotations (in app templates)
cert-manager.io/cluster-issuer: {{ cert_manager_issuer_name }}  # Also uses directly
```

**Common error**: If the template appends a suffix (e.g., `-cluster-issuer`) when the variable already contains it, you'll get redundant naming like `cloudflare-cluster-issuer-cluster-issuer`.

**Verification**:
```bash
kubectl get clusterissuer
# Should show: cloudflare-cluster-issuer (not cloudflare-cluster-issuer-cluster-issuer)
```

**Debugging certificate issues**:
```bash
# Check certificate status
kubectl get certificate -n <namespace>

# Check certificate request details
kubectl get certificaterequest -n <namespace>
kubectl describe certificaterequest <name> -n <namespace>

# Common error: "Referenced 'ClusterIssuer' not found"
# Fix: Verify issuer name in ingress annotation matches actual ClusterIssuer name
```

### Ingress TLS Pattern
All ingresses with TLS should reference the ClusterIssuer via annotation:
```yaml
annotations:
  cert-manager.io/cluster-issuer: cloudflare-cluster-issuer
tls:
  - secretName: app-tls
    hosts:
      - app.local.bysliek.com
```

## Media Application Deployment Pattern

### Namespace Strategy
Media applications (Sonarr, Radarr, Prowlarr, Overseerr, etc.) share a common `media` namespace to:
- Simplify resource management
- Enable shared network policies
- Group related services together

### Application Port Configuration
**Critical**: Each media app uses a specific port - configure correctly in templates

| Application | Port | Purpose |
|------------|------|---------|
| Sonarr | 8989 | TV show management |
| Radarr | 7878 | Movie management |
| Overseerr | 5055 | Media request management |
| Prowlarr | 9696 | Indexer management |

**Template configuration**:
```yaml
service:
  app:
    controller: <app-name>
    ports:
      http:
        port: <correct-port>  # Use table above
```

**Common error**: Using wrong port (e.g., 7878 for Overseerr instead of 5055) will cause connection refused errors. Verify by checking pod logs for "Server ready on port XXXX".

### Internal Service Communication
**Critical**: Apps in the same namespace should communicate using internal Kubernetes service DNS, not external ingress domains.

**Correct pattern (same namespace):**
```
Overseerr → Radarr: http://radarr:7878
Overseerr → Sonarr: http://sonarr:8989
```

**Correct pattern (fully qualified):**
```
http://<service-name>.<namespace>.svc.cluster.local:<port>
http://radarr.media.svc.cluster.local:7878
```

**Wrong pattern (causes issues):**
```
https://radarr.local.bysliek.com:7878  ❌
https://sonarr.local.bysliek.com:8989  ❌
```

**Why use internal DNS:**
- Direct pod-to-pod communication (no ingress hop)
- Lower latency
- No TLS complexity for internal traffic
- Avoids routing through external network
- Works even if ingress is down

**Example configurations:**
- **Overseerr** connecting to Radarr: `http://radarr:7878`
- **Overseerr** connecting to Sonarr: `http://sonarr:8989`
- **Sonarr/Radarr** connecting to Prowlarr: `http://prowlarr:9696`

**When to use ingress domains:**
- Browser access from outside the cluster
- External API calls from non-Kubernetes services

### Dual-Storage Configuration
Media apps typically need two storage mounts:

1. **Config storage** (PVC on SSD NFS):
   - Application settings
   - Databases
   - Small, frequently-accessed files

2. **Media storage** (Direct NFS mount on HDD):
   - Downloads directory
   - Library/media files
   - Large, infrequently-modified files
   - Enables hard-linking for atomic moves

### Example: Sonarr Configuration
See [templates/kubernetes/bootstrap/apps/sonarr.yaml.j2](templates/kubernetes/bootstrap/apps/sonarr.yaml.j2) for complete example showing:
- bjw-s app-template v4.5.0 Helm chart usage
- Dual NFS mount configuration (PVC + direct mount)
- Ingress with TLS
- Service configuration with correct port (8989)

## Troubleshooting Guide

### Pod Stuck in ContainerCreating (NFS Mount Issues)
**Symptoms**: Pod events show `MountVolume.SetUp failed` with NFS-related errors

**Check**:
1. Are NFS client utilities installed on the node?
   ```bash
   ansible all -i inventory/hosts.yaml -m shell -a "rpm -q nfs-utils"
   ```
2. Is the NFS export accessible?
   ```bash
   showmount -e <nfs-server-ip>
   ```
3. Are NFS export permissions correct? (maproot, dataset permissions)

**Fix**: Install nfs-utils via Ansible pre role and run playbook

### Certificate Stuck in Issuing State
**Symptoms**: Certificate remains in "Issuing" state, ingress shows ERR_CONNECTION_RESET

**Check**:
1. Verify ClusterIssuer exists and is ready:
   ```bash
   kubectl get clusterissuer
   kubectl describe clusterissuer cloudflare-cluster-issuer
   ```
2. Check certificate events:
   ```bash
   kubectl describe certificate <cert-name> -n <namespace>
   ```
3. Verify issuer name in ingress annotation matches actual ClusterIssuer name

**Fix**: Ensure `cert_manager_issuer_name` in config.yaml matches the ClusterIssuer resource name exactly

### ArgoCD Application Out of Sync
**Symptoms**: Application shows "OutOfSync" status in ArgoCD UI

**Check**:
1. Did you run `task configure` after editing templates?
2. Did you commit and push changes?
3. Are there RBAC/permission issues? (Check ArgoCD project permissions)

**Fix**: Ensure ApplicationSet recurse is enabled and project has proper permissions

### Deployment Selector Field is Immutable
**Symptoms**: ArgoCD sync fails with error: `Deployment.apps "name" is invalid: spec.selector: Invalid value: field is immutable`

**Cause**: Kubernetes Deployments have an immutable `spec.selector` field. Helm chart upgrades (especially major versions like app-template 3.x → 4.x) often change label selectors.

**Fix**:
1. Delete the Deployment: `kubectl delete deployment <name> -n <namespace>`
2. ArgoCD will recreate it with the new chart version and correct selectors
3. Alternative: Scale to 0 first if you need graceful shutdown

**Prevention**: When upgrading major helm chart versions, expect to recreate Deployments

### PVC Size Changes Not Supported
**Symptoms**: Want to reduce PVC size but change doesn't apply

**Cause**: Kubernetes only supports **expanding** PVCs, not shrinking them

**Solutions**:
1. **Keep current size** - Simplest, no data loss
2. **Backup and recreate** - Delete PVC, create new smaller one, restore data
3. **Direct NFS copy** - If using NFS CSI driver:
   - Old PVC path: `/mnt/k8s-ssd-pool/k8s-nfs-share/pvc-<old-uuid>`
   - New PVC path: `/mnt/k8s-ssd-pool/k8s-nfs-share/pvc-<new-uuid>`
   - Copy data on NFS server: `cp -av /old/path/* /new/path/`

**Important**: Chart upgrades may change PVC names (e.g., app-template 3.x uses `<app>-config`, 4.x uses `<app>`). Plan data migration accordingly.
