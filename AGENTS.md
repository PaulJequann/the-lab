# The Lab - Agent Guidelines

This repository manages a GitOps-based Kubernetes infrastructure using K3s, ArgoCD, Cilium, SOPS, and more. All configurations are template-driven.

## 1. Build, Lint, and Configuration Commands

This project uses `task` (via Taskfile.yml) instead of `make` or `npm`. There is no `package.json`.

### Core Workflows
- **Configure (Render & Encrypt):** `task configure`
  - Renders Jinja2 templates from `templates/` to destination directories (`kubernetes/`, `ansible/`, etc.).
  - Encrypts secrets using SOPS.
  - **CRITICAL:** Do NOT manually edit generated files (YAMLs in `kubernetes/` without `.j2`). Always edit the source templates in `templates/`.

### Validation & Setup
- **Verify Environment:** `task verify`
- **Install Dependencies:** `task init` (installs helm, kubectl, sops, etc.)
- **Linting:**
  - `yamllint .` (General YAML check)
  - `ansible-lint` (Ansible roles)
  - `tflint` (Terraform)

### Testing
- This is an infrastructure repo; "tests" are primarily validation checks and dry-runs.
- **Kubernetes Validation:**
  - `kubectl apply --dry-run=client -f <manifest>`
  - `kubectl create secret generic <name> --dry-run=client -o yaml` (for secrets)

## 2. Code Style & Conventions

### Directory Structure & Templates
- **Source of Truth:** `templates/` contains all `.j2` source templates.
- **Variables:** Defined in `config.yaml` at the root.
- **Destinations:** `kubernetes/`, `ansible/`, `terraform/` are generated targets.
- **Workflow:** Edit `templates/.../*.j2` -> Run `task configure` -> Commit generated files.

### Kubernetes & ArgoCD
- **Application Structure:**
  - `kubernetes/core/`: Infrastructure (Cilium, Cert-Manager).
  - `kubernetes/apps/`: User applications.
  - **Auto-Discovery:** Apps are auto-discovered by ArgoCD from directory structure.
  - **Namespace:** Usually matches the app name (e.g., `kubernetes/apps/sonarr` -> namespace `sonarr`).
- **Sync Waves:**
  - `-5`: Core Infra
  - `-3`: Infra Services
  - `-1`: Apps
  - `0`: Monitoring
- **Internal Communication:** Use internal DNS (`http://service.namespace:port`) for app-to-app talk, not external Ingress domains.

### Secrets Management (Strict!)
- **SOPS (`.sops.yaml`):** Used for config values (Ansible vars, Terraform vars).
- **Sealed Secrets (`.secret.yaml`):** Used for Kubernetes Secret objects.
- **Workflow:**
  - Never commit plaintext secrets.
  - Use `sops filename.sops.yaml` to edit encrypted files.
  - Files matching `*.sops.*` are automatically encrypted by `task configure`.

### Naming & Formatting
- **Files:** Kebab-case (`my-app.yaml`, `cluster-issuer.yaml`).
- **Templates:** Must end in `.j2` (e.g., `app.yaml.j2`).
- **Indent:** 2 spaces for YAML/JSON.
- **Comments:** Explain *why*, not *what*.

### Error Handling
- **Missing Variables:** Ensure `config.yaml` has all necessary keys referenced in templates.
- **Deployment Failures:** Check `kubectl events` and `kubectl logs`. Common issues:
  - NFS mount failures (missing `nfs-utils` on nodes).
  - Certificate "Issuing" stuck (check ClusterIssuer name matches `config.yaml`).
  - Immutable selector errors (requires deleting the Deployment resource).

### Tools
- **Task:** Automation runner.
- **Makejinja:** Template renderer.
- **SOPS/Age:** Encryption.
- **Renovate:** Dependency updates (keep configuration clean).

## 3. Cursor / Copilot Rules
- **No `package.json`:** Do not assume Node.js/NPM workflows.
- **No Manual Edits:** If you see a file in `kubernetes/` or `ansible/`, check if a corresponding file exists in `templates/`. If so, edit the template.
- **Run Configure:** Always suggest running `task configure` after editing templates.
