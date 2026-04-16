#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ANSIBLE_VENV="${HOME}/.venvs/the-lab"
ANSIBLE_BIN_DIR="${ANSIBLE_VENV}/bin"
HELM_DIFF_REPO="https://github.com/databus23/helm-diff"
PACKAGES=(
  age
  argocd
  cloudflared
  fluxcd
  git
  go-task
  go-yq
  helm
  jq
  kubectl
  kubeseal
  kustomize
  openssh
  pre-commit
  prettier
  rbw
  sops
  stern
  terraform
  tflint
  uv
  yamllint
)

require_cachyos_or_arch() {
  if ! command -v pacman >/dev/null 2>&1; then
    echo "This script expects an Arch-based host with pacman."
    exit 1
  fi
}

install_system_packages() {
  echo "Installing host packages with pacman..."
  sudo pacman -S --needed "${PACKAGES[@]}"
}

install_makejinja_tool() {
  echo "Installing makejinja with uv..."
  uv tool install --force --with bcrypt --with attrs --with pyyaml makejinja
  uv tool update-shell || true
}

create_ansible_venv() {
  echo "Creating the-lab Ansible venv..."
  uv venv "${ANSIBLE_VENV}"

  echo "Installing Ansible Python dependencies..."
  uv pip install \
    --python "${ANSIBLE_BIN_DIR}/python3" \
    ansible-core==2.20.4 \
    -r "${REPO_ROOT}/ansible/requirements.txt"
}

install_ansible_galaxy_content() {
  echo "Installing Ansible Galaxy content..."
  "${ANSIBLE_BIN_DIR}/ansible-galaxy" role install \
    -r "${REPO_ROOT}/ansible/requirements.yml" \
    --roles-path "${HOME}/.ansible/roles" \
    --force

  "${ANSIBLE_BIN_DIR}/ansible-galaxy" collection install \
    -r "${REPO_ROOT}/ansible/requirements.yml" \
    --collections-path "${HOME}/.ansible/collections" \
    --force
}

install_helm_diff_plugin() {
  echo "Ensuring Helm diff plugin is installed..."
  if helm plugin list 2>/dev/null | awk '{print $1}' | grep -qx diff; then
    echo "Helm diff plugin already installed."
    return
  fi

  helm plugin install "${HELM_DIFF_REPO}"
}

report_local_state() {
  echo
  echo "Checking expected local workstation state..."

  local path
  for path in \
    "${HOME}/.config/sops/age/keys.txt" \
    "${HOME}/.ssh" \
    "${HOME}/.kube" \
    "${HOME}/.terraform.d/credentials.tfrc.json" \
    "${HOME}/.config/rbw-bootstrap" \
    "${HOME}/.local/share/rbw-bootstrap" \
    "${HOME}/.cache/rbw-bootstrap"
  do
    if [[ -e "${path}" ]]; then
      echo "  present ${path}"
    else
      echo "  missing ${path}"
    fi
  done
}

print_next_steps() {
  cat <<EOF

Host bootstrap complete.

Next steps:
  1. Restart your shell, or run: rehash && hash -r
  2. Activate the Ansible venv:
       source "${ANSIBLE_VENV}/bin/activate"
  3. Unlock Bitwarden before bootstrap workflows:
       RBW_PROFILE=bootstrap rbw unlock
  4. Verify the toolchain:
       which yq
       yq --version
       which makejinja
       which ansible
       ansible --version
       helm plugin list

Expected:
  - yq --version reports Mike Farah yq v4
  - ansible resolves to ${ANSIBLE_VENV}/bin/ansible
  - makejinja resolves from uv's tool directory
EOF
}

main() {
  require_cachyos_or_arch
  install_system_packages
  install_makejinja_tool
  create_ansible_venv
  install_ansible_galaxy_content
  install_helm_diff_plugin
  report_local_state
  print_next_steps
}

main "$@"
