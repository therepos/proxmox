#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-gpudriver.sh?$(date +%s))"
# Purpose: Installs the recommended NVIDIA headless driver in Ubuntu
# Version: Ubuntu
# =============================================================================
# Usage:
#   Installs the recommended NVIDIA headless driver
#   If Docker is present, installs NVIDIA Container Toolkit + NVIDIA runtime
#   If Kasm agent is running, restarts it to pick up the GPU
# =============================================================================

set -euo pipefail

# Helpers
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

# Root check
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# Proxmox check
if [[ -f /etc/pve/.version ]] || command -v pveversion &> /dev/null; then
    echo ""
    echo "Proxmox VE detected. This script cannot run here."
    echo "================================================="
    echo ""
    echo "  This script installs NVIDIA drivers inside a guest VM"
    echo "  so the VM can use a GPU that has been passed through."
    echo ""
    echo "  Installing NVIDIA drivers on the Proxmox host would"
    echo "  conflict with GPU passthrough (VFIO) and break your"
    echo "  passthrough setup."
    echo ""
    echo "  Instead:"
    echo "    Proxmox host  -> use install-passthrough.sh"
    echo "    Ubuntu VM      -> use install-gpudriver.sh (this script)"
    echo ""
    exit 1
fi

echo ""
echo "NVIDIA GPU Driver - Install"
echo "================================================="
echo ""

# Check for NVIDIA GPU
info "Checking for NVIDIA GPU..."
if ! lspci | grep -qi nvidia; then
    fail "No NVIDIA GPU detected. Is GPU passthrough configured?"
fi
GPU_MODEL=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
ok "Found: ${GPU_MODEL}"

# Install prerequisites
info "Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ubuntu-drivers-common curl gnupg2 ca-certificates > /dev/null 2>&1
ok "Prerequisites installed."

# Install NVIDIA driver
NEEDS_REBOOT=false
CURRENT_DRIVER=""

if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    ok "NVIDIA driver already installed (version: ${CURRENT_DRIVER}). Skipping driver install."
else
    info "Installing NVIDIA driver..."

    add-apt-repository -y ppa:graphics-drivers/ppa > /dev/null 2>&1
    apt-get update -qq

    if [[ -n "${NVIDIA_DRIVER_VERSION:-}" ]]; then
        DRIVER_PKG="nvidia-headless-${NVIDIA_DRIVER_VERSION}"
        UTILS_PKG="nvidia-utils-${NVIDIA_DRIVER_VERSION}"
        info "Using specified driver branch: ${NVIDIA_DRIVER_VERSION}"
    else
        info "Detecting recommended driver..."
        DRIVER_LIST=$(ubuntu-drivers list 2>/dev/null || true)

        DRIVER_BRANCH=$(echo "$DRIVER_LIST" \
            | grep -oP 'nvidia-driver-\K[0-9]+(?=-server)' \
            | sort -n | tail -1)

        if [[ -z "$DRIVER_BRANCH" ]]; then
            DRIVER_BRANCH=$(echo "$DRIVER_LIST" \
                | grep -oP 'nvidia-driver-\K[0-9]+' \
                | sort -n | tail -1)
        fi

        [[ -n "$DRIVER_BRANCH" ]] || fail "Could not detect a suitable NVIDIA driver. Try setting NVIDIA_DRIVER_VERSION manually."

        DRIVER_PKG="nvidia-headless-${DRIVER_BRANCH}"
        UTILS_PKG="nvidia-utils-${DRIVER_BRANCH}"
        info "Recommended driver branch: ${DRIVER_BRANCH}"
    fi

    apt-get install -y -qq "${DRIVER_PKG}" "${UTILS_PKG}" > /dev/null 2>&1 \
        || fail "Failed to install ${DRIVER_PKG}. Try a different NVIDIA_DRIVER_VERSION."

    ok "NVIDIA driver installed (${DRIVER_PKG})."
    NEEDS_REBOOT=true
fi

# Docker integration (optional)
HAS_DOCKER=false
HAS_CONTAINER_TK=false

if command -v docker &> /dev/null; then
    HAS_DOCKER=true
    info "Docker detected. Installing NVIDIA Container Toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit > /dev/null 2>&1
    ok "NVIDIA Container Toolkit installed."

    info "Configuring Docker to use NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=docker > /dev/null 2>&1
    ok "Docker NVIDIA runtime configured."

    info "Restarting Docker..."
    systemctl restart docker
    ok "Docker restarted."
    HAS_CONTAINER_TK=true

    # Restart Kasm agent if it happens to be running
    if docker ps --format '{{.Names}}' | grep -q kasm_agent; then
        info "Kasm agent detected. Restarting..."
        docker restart kasm_agent > /dev/null 2>&1
        ok "Kasm agent restarted."
    fi
else
    info "Docker not found. Skipping container toolkit setup."
    info "If you install Docker later, re-run this script to add GPU support."
fi

# Summary
echo ""
echo "Install Complete"
echo "================================================="
echo ""
echo "  GPU             ${GPU_MODEL}"
if [[ "${NEEDS_REBOOT}" == "true" ]]; then
    echo "  Driver          ${DRIVER_PKG} (REBOOT REQUIRED)"
else
    echo "  Driver          ${CURRENT_DRIVER:-installed}"
fi
if [[ "${HAS_CONTAINER_TK}" == "true" ]]; then
    echo "  Container TK    installed"
    echo "  Docker runtime  nvidia"
else
    echo "  Container TK    skipped (no Docker)"
fi

if [[ "${NEEDS_REBOOT}" == "true" ]]; then
    echo ""
    echo "  REBOOT REQUIRED to load the NVIDIA kernel module."
    echo "  After reboot, verify with: nvidia-smi"
else
    echo ""
    echo "  Verify with: nvidia-smi"
    if [[ "${HAS_DOCKER}" == "true" ]]; then
        echo "  Test Docker GPU access with:"
        echo "    docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi"
    fi
fi
echo ""