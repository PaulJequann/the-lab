#!/bin/bash
set -euo pipefail  # Enable stricter error handling

echo "Running post-create commands..."

# =====================
# Configuration Variables
# =====================
SOPS_AGE_DIR="${HOME}/.config/sops/age"
TEMP_DIR="/tmp"
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-"
# Determine repo root for accessing config.yaml reliably
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${REPO_ROOT}/config.yaml"

# =====================
# Directory Setup
# =====================
echo "Configuring directories..."
mkdir -p "${SOPS_AGE_DIR}"
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

# Install beads CLI (AI-friendly task tracker)
# Note: Installation only adds the CLI. Run 'bd init' manually when ready to use beads.
if ! command -v bd &> /dev/null; then
    echo "Installing beads..."
    curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
    echo "beads installed. Run 'bd init' to initialize task tracking."
else
    echo "beads already installed: $(bd --version 2>/dev/null || echo 'unknown version')"
fi

# =====================
# Python Package Management
# =====================
echo "Installing Python packages..."

# Verify pipx is installed
if ! command -v pipx &> /dev/null; then
    echo "Error: pipx not found. Please install pipx first."
    exit 1
fi

# Install packages with idempotency checks
if ! pipx list | grep -q "package makejinja"; then
    echo "Installing makejinja..."
    pipx install makejinja
    pipx inject makejinja bcrypt attrs pyyaml
else
    echo "makejinja already installed"
fi

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
# kubeseal Installation (Debian devcontainer, linux-amd64)
# =====================
echo "Installing kubeseal..."
KUBESEAL_VERSION=""
if [[ -f "${CONFIG_PATH}" ]]; then
  # Extract value from config.yaml (expects kubeseal_version: "0.30.0")
  KUBESEAL_VERSION=$(grep -E '^[[:space:]]*kubeseal_version:' "${CONFIG_PATH}" | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

TARGET_VER=""
TAG=""
if [[ -n "${KUBESEAL_VERSION}" ]]; then
  TARGET_VER="${KUBESEAL_VERSION#v}"
  TAG="v${TARGET_VER}"
else
  echo "kubeseal_version not set in ${CONFIG_PATH}; resolving latest..."
  latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/bitnami-labs/sealed-secrets/releases/latest || true)"
  if [[ "${latest_url}" =~ /tag/v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    TARGET_VER="${BASH_REMATCH[1]}"
    TAG="v${TARGET_VER}"
  else
    echo "Could not resolve latest tag; will use latest download endpoint"
    TARGET_VER=""
    TAG="latest"
  fi
fi

CUR_VER=""
if command -v kubeseal &>/dev/null; then
  CUR_VER_RAW="$(kubeseal --version 2>&1 || true)"
  CUR_VER="$(echo "$CUR_VER_RAW" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
fi

if [[ -n "${TARGET_VER}" && "${CUR_VER#v}" == "${TARGET_VER}" ]]; then
  echo "kubeseal ${CUR_VER} already installed. Skipping."
else
  TMP_DIR="$(mktemp -d)"
  echo "Preparing to install kubeseal to /usr/local/bin..."
  if [[ -n "${TARGET_VER}" ]]; then
    ASSET_BASE="https://github.com/bitnami-labs/sealed-secrets/releases/download/${TAG}"
    TARBALL_URL="${ASSET_BASE}/kubeseal-${TARGET_VER}-linux-amd64.tar.gz"
    echo "Downloading kubeseal ${TAG} tarball (linux-amd64)..."
    if ! curl -fL "${TARBALL_URL}" -o "${TMP_DIR}/kubeseal.tgz"; then
      echo "Versioned tarball not found, trying latest tarball..."
      curl -fL "https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-amd64.tar.gz" -o "${TMP_DIR}/kubeseal.tgz"
    fi
  else
    echo "Downloading kubeseal latest tarball (linux-amd64)..."
    curl -fL "https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-amd64.tar.gz" -o "${TMP_DIR}/kubeseal.tgz"
  fi
  tar -xzf "${TMP_DIR}/kubeseal.tgz" -C "${TMP_DIR}"
  sudo install -m 0755 -o root -g root "${TMP_DIR}/kubeseal" /usr/local/bin/kubeseal
  rm -rf "${TMP_DIR}"
  echo "kubeseal installed: $(kubeseal --version || true)"
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
echo "  AI:         claude, bd (beads)"
echo "  K8s:        kubectl, helm, kubeseal, argocd, stern, kustomize"
echo "  Infra:      terraform, ansible, sops, age"
echo "  Utilities:  cloudflared, prettier, yamllint, pre-commit"
echo ""
echo "Run 'claude' to start AI assistant."
echo "========================================"