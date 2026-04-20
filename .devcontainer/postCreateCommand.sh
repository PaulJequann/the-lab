#!/bin/bash
set -euo pipefail  # Enable stricter error handling

echo "Running post-create commands..."

# =====================
# Configuration Variables
# =====================
TEMP_DIR="/tmp"
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-"
# Determine repo root for accessing config.yaml reliably
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${REPO_ROOT}/config.yaml"

# =====================
# Directory Setup
# =====================
echo "Configuring directories..."
mkdir -p "${HOME}/.copilot"
echo "Created user directories"

echo "Directory setup complete"

# =====================
# AI CLI Tools
# =====================
echo "Installing AI CLI tools..."

# Install Claude Code
if ! command -v claude &> /dev/null; then
    echo "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    echo "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
fi

# Install GitHub Copilot CLI
if ! command -v copilot &> /dev/null; then
  echo "Installing GitHub Copilot CLI..."
  npm install -g @github/copilot
else
  echo "GitHub Copilot CLI already installed: $(copilot --version 2>/dev/null || echo 'unknown version')"
fi

# =====================
# Python Package Management
# =====================
echo "Installing Python packages for scripts/render.py..."
pip install --quiet --upgrade jinja2 pyyaml

# =====================
# Ansible Collections
# =====================
echo "Installing Ansible collections..."
if ! ansible-galaxy collection list | grep -q "kubernetes.core"; then
    ansible-galaxy collection install kubernetes.core
    echo "Installed kubernetes.core version:"
    ansible-galaxy collection list kubernetes.core
else
    echo "kubernetes.core already installed:"
    ansible-galaxy collection list kubernetes.core
fi

# =====================
# Helm Installation & Plugins
# =====================
echo "Installing/updating Helm..."
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm already installed: $(helm version --short)"
fi

echo "Installing Helm diff plugin..."
if ! helm plugin list | grep -q diff; then
    helm plugin install https://github.com/databus23/helm-diff
else
    echo "Helm diff plugin already installed"
fi

# =====================
# Cloudflared Installation
# =====================
echo "Installing cloudflared..."

if command -v cloudflared &>/dev/null; then
    echo "cloudflared already installed: $(cloudflared --version 2>&1 | head -n1 || echo 'unknown version')"
else
    # Verify architecture compatibility
    ARCH=$(dpkg --print-architecture)
    VALID_ARCHS=("amd64" "arm64" "armhf")
    if [[ ! " ${VALID_ARCHS[*]} " =~ " ${ARCH} " ]]; then
        echo "Unsupported architecture: ${ARCH}"
        exit 1
    fi

    # Download with error handling
    CLOUDFLARED_DEB="${TEMP_DIR}/cloudflared.deb"
    trap 'rm -f "${CLOUDFLARED_DEB}"' EXIT  # Ensure cleanup on exit

    if ! curl -Lfs "${CLOUDFLARED_URL}${ARCH}.deb" -o "${CLOUDFLARED_DEB}"; then
        echo "Cloudflared download failed"
        exit 1
    fi

    # Install with verification
    sudo dpkg -i "${CLOUDFLARED_DEB}" || {
        echo "Cloudflared installation failed"
        exit 1
    }
    echo "cloudflared installed: $(cloudflared --version 2>&1 | head -n1 || echo 'unknown version')"
fi

# =====================
# rbw Installation (Bitwarden CLI for bootstrap secrets)
# =====================
echo "Installing rbw..."
RBW_TARGET_VER="1.15.0"
if command -v rbw &>/dev/null && [[ "$(rbw --version 2>/dev/null)" == "rbw ${RBW_TARGET_VER}" ]]; then
  echo "rbw ${RBW_TARGET_VER} already installed. Skipping."
else
  RBW_TMP="$(mktemp -d)"
  curl -fL "https://github.com/doy/rbw/releases/download/${RBW_TARGET_VER}/rbw_${RBW_TARGET_VER}_linux_amd64.tar.gz" -o "${RBW_TMP}/rbw.tar.gz"
  tar -xzf "${RBW_TMP}/rbw.tar.gz" -C "${RBW_TMP}"
  sudo install -m 0755 "${RBW_TMP}/rbw" /usr/local/bin/rbw
  sudo install -m 0755 "${RBW_TMP}/rbw-agent" /usr/local/bin/rbw-agent
  rm -rf "${RBW_TMP}"
  echo "rbw installed: $(rbw --version)"
fi

# =====================
# Summary
# =====================
echo ""
echo "========================================"
echo "Post-create commands completed!"
echo "========================================"
echo ""
echo "Available tools:"
echo "  AI:         claude, copilot"
echo "  K8s:        kubectl, helm, argocd, stern, kustomize"
echo "  Infra:      terraform, ansible, sops, age, rbw"
echo "  Utilities:  cloudflared, prettier, yamllint, pre-commit"
echo ""
echo "Run 'claude' or 'copilot' to start an AI assistant."
echo "========================================"
