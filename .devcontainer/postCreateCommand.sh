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
pipx inject --force makejinja attrs
pipx inject --force ansible-core passlib

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

echo "Post-create commands completed successfully!"