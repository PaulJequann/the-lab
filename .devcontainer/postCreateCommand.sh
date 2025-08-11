#!/bin/bash
set -euo pipefail  # Enable stricter error handling

echo "Running post-create commands..."

# =====================
# Configuration Variables
# =====================
SOPS_AGE_DIR="${HOME}/.config/sops/age"
ANSIBLE_VENV_DIR="/usr/local/py-utils/venvs/ansible-core"
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

# Use $(whoami) for reliable user identification
CURRENT_USER=$(whoami)
sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "${ANSIBLE_VENV_DIR}"

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
pipx install --force makejinja
pipx inject --force makejinja bcrypt
pipx inject --force makejinja attrs
# =====================
# Cloudflared Installation
# =====================
echo "Installing cloudflared..."

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

echo "Post-create commands completed successfully!"