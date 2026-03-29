#!/usr/bin/env bash
# =============================================================================
# NVIDIA Driver + Container Toolkit - Automated Install Script
# Target: Ubuntu 22.04 / 24.04 (amd64) - VM with GPU passthrough
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/<YOU>/<REPO>/main/install-gpudriver.sh | sudo bash
#
# Run this AFTER install-kasm.sh (Docker must already be installed).
#
# What this does:
#   1. Detects NVIDIA GPU via lspci
#   2. Installs the recommended NVIDIA headless driver
#   3. Installs NVIDIA Container Toolkit
#   4. Configures Docker to use the NVIDIA runtime
#   5. Restarts Docker and Kasm agent
#
# A reboot is required after first install to load the kernel module.
#
# Optional environment variables:
#   NVIDIA_DRIVER_VERSION   Override driver branch (default: auto-detect recommended)
# =============================================================================

set -euo pipefail

# -- Helpers ------------------------------------------------------------------
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

# -- Root check ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

echo ""
echo "NVIDIA Driver + Container Toolkit - Install"
echo "================================================="
echo ""

# -- 1. Check for NVIDIA GPU --------------------------------------------------
info "Checking for NVIDIA GPU..."
if ! lspci | grep -qi nvidia; then
    fail "No NVIDIA GPU detected. Is GPU passthrough configured?"
fi
GPU_MODEL=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
ok "Found: ${GPU_MODEL}"

# -- 2. Check Docker is installed ---------------------------------------------
info "Checking for Docker..."
if ! command -v docker &> /dev/null; then
    fail "Docker is not installed. Run install-kasm.sh first."
fi
ok "Docker is available."

# -- 3. Install prerequisites -------------------------------------------------
info "Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ubuntu-drivers-common curl gnupg2 ca-certificates > /dev/null 2>&1
ok "Prerequisites installed."

# -- 4. Install NVIDIA driver -------------------------------------------------
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    ok "NVIDIA driver already installed (version: ${CURRENT_DRIVER}). Skipping driver install."
else
    info "Installing NVIDIA driver..."

    # Add PPA for latest drivers
    add-apt-repository -y ppa:graphics-drivers/ppa > /dev/null 2>&1
    apt-get update -qq

    if [[ -n "${NVIDIA_DRIVER_VERSION:-}" ]]; then
        # User specified a driver branch
        DRIVER_PKG="nvidia-headless-${NVIDIA_DRIVER_VERSION}"
        UTILS_PKG="nvidia-utils-${NVIDIA_DRIVER_VERSION}"
        info "Using specified driver branch: ${NVIDIA_DRIVER_VERSION}"
    else
        # Auto-detect the recommended server driver
        info "Detecting recommended driver..."
        DRIVER_LIST=$(ubuntu-drivers list 2>/dev/null || true)

        # Prefer server drivers, fall back to regular
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

# -- 5. Install NVIDIA Container Toolkit --------------------------------------
info "Installing NVIDIA Container Toolkit..."

# Add NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit > /dev/null 2>&1
ok "NVIDIA Container Toolkit installed."

# -- 6. Configure Docker runtime -----------------------------------------------
info "Configuring Docker to use NVIDIA runtime..."
nvidia-ctk runtime configure --runtime=docker > /dev/null 2>&1
ok "Docker NVIDIA runtime configured."

# -- 7. Restart services -------------------------------------------------------
info "Restarting Docker..."
systemctl restart docker
ok "Docker restarted."

if docker ps --format '{{.Names}}' | grep -q kasm_agent; then
    info "Restarting Kasm agent..."
    docker restart kasm_agent > /dev/null 2>&1
    ok "Kasm agent restarted."
fi

# -- Summary -------------------------------------------------------------------
echo ""
echo "Install Complete"
echo "================================================="
echo ""
echo "  GPU             ${GPU_MODEL}"
if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
    echo "  Driver          ${DRIVER_PKG} (REBOOT REQUIRED)"
else
    echo "  Driver          ${CURRENT_DRIVER:-installed}"
fi
echo "  Container TK    installed"
echo "  Docker runtime  nvidia"

if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
    echo ""
    echo "  REBOOT REQUIRED to load the NVIDIA kernel module."
    echo "  After reboot, verify with: nvidia-smi"
else
    echo ""
    echo "  Verify with: nvidia-smi"
    echo "  Test Docker GPU access with:"
    echo "    docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi"
fi

echo ""
echo ""
echo "Kasm GPU Setup Guide"
echo "================================================="
echo ""
echo "  After reboot (if needed) and verifying nvidia-smi works:"
echo ""
echo "    1. Log into Kasm Admin UI."
echo "    2. Go to Admin > Infrastructure > Docker Agents."
echo "       Confirm the agent shows 1 or more GPUs."
echo ""
echo "    3. Go to Admin > Workspaces > edit the workspace."
echo "       Set 'GPU Count' to 1."
echo ""
echo "    4. For workspaces outside the Kasm AI Registry,"
echo "       also add this to 'Docker Run Config Override':"
echo '       {'
echo '         "environment": {'
echo '           "NVIDIA_DRIVER_CAPABILITIES": "all"'
echo '         }'
echo '       }'
echo ""