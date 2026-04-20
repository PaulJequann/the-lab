# Host Setup

This document describes the supported host-side setup for working in `the-lab` without the devcontainer on CachyOS or Arch Linux.

The current recommended split is:

- Install non-Python operator tooling with `pacman`
- Install `makejinja` as a `uv` tool
- Run Ansible from a dedicated `uv` virtualenv for this repo

## What This Setup Covers

After completing this setup, the host should be able to run:

- `task configure`
- `source scripts/load-bootstrap-secrets.sh ...`
- `ansible`, `ansible-playbook`, and `ansible-galaxy` from the repo venv
- Terraform, kubectl, Helm, and related operator workflows

## Required Local State

These files and directories must already exist on the workstation:

- `~/.ssh/`
- `~/.kube/`
- `~/.terraform.d/credentials.tfrc.json`
- `~/.config/rbw-bootstrap`
- `~/.local/share/rbw-bootstrap`
- `~/.cache/rbw-bootstrap`

`rbw` also needs a working `bootstrap` profile for workstation-driven bootstrap tasks.

## One-Shot Bootstrap

Run the included setup script from the repo root:

```bash
bash scripts/bootstrap-host-cachyos.sh
```

The script:

- installs required host packages with `pacman`
- installs `makejinja` with `uv tool install`
- creates `~/.venvs/the-lab`
- installs `ansible-core==2.20.4` plus `ansible/requirements.txt` into that venv
- installs Galaxy roles and collections into `~/.ansible`
- installs the Helm `diff` plugin

## Manual Setup

Install the host packages:

```bash
sudo pacman -S --needed \
  argocd cloudflared git go-task go-yq helm infisical-cli jq kubectl \
  kustomize openssh pre-commit prettier rbw stern \
  terraform tflint yamllint uv
```

Install `makejinja` with `uv`:

```bash
uv tool install --force --with bcrypt --with attrs --with pyyaml makejinja
uv tool update-shell
```

Create the Ansible venv and install Python-side dependencies:

```bash
uv venv ~/.venvs/the-lab
source ~/.venvs/the-lab/bin/activate
uv pip install ansible-core==2.20.4 -r ansible/requirements.txt
ansible-galaxy role install -r ansible/requirements.yml --roles-path ~/.ansible/roles --force
ansible-galaxy collection install -r ansible/requirements.yml --collections-path ~/.ansible/collections --force
```

Install the Helm diff plugin:

```bash
helm plugin install https://github.com/databus23/helm-diff
```

If the shell still resolves `ansible` or another executable to an older path after activation, clear zsh's command cache:

```bash
rehash
hash -r
```

## Day-To-Day Usage

Activate the Ansible venv before running Ansible commands:

```bash
source ~/.venvs/the-lab/bin/activate
```

Unlock Bitwarden before bootstrap or secret-loading workflows:

```bash
RBW_PROFILE=bootstrap rbw unlock
```

The host-side `makejinja` installation is managed separately from the Ansible venv. `makejinja` should come from `uv`'s tool directory, while `ansible` should come from `~/.venvs/the-lab/bin/ansible`.

## Verification

Run these checks after setup:

```bash
which task
which yq
yq --version
which makejinja
which ansible
ansible --version
ansible-galaxy collection list | rg 'kubernetes.core|community.postgresql|infisical.vault'
makejinja --version
helm plugin list
RBW_PROFILE=bootstrap rbw unlocked && echo unlocked || echo locked
```

Expected results:

- `task` resolves to the Go Task runner
- `yq --version` reports Mike Farah `yq` v4
- `makejinja` resolves from `uv`'s tool bin directory
- `ansible` resolves to `~/.venvs/the-lab/bin/ansible`
- Helm lists the `diff` plugin
- `rbw` reports either `unlocked` or `locked`, not a missing-profile error
