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
