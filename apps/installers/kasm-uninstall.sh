#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/kasm-uninstall.sh?$(date +%s))"
# Purpose: Cleanly uninstall Kasm Workspaces (reverses kasm-setup.sh)
# =============================================================================
# Removes:
#   - All Kasm containers, images, networks and volumes
#   - The /opt/kasm install tree (configs, certs, database, backups)
#
# Optional (off by default to protect data / shared services):
#   REMOVE_DATA     "true" to delete /data/kasm-profiles + /data/kasm-shared
#   REMOVE_SWAP     "true" to remove the swap file created at install
#   REMOVE_DOCKER   "true" to purge the Docker engine entirely
#
# Other:
#   KASM_SWAP_GB    Swap size used at install, for the file name (default: 4)
#   FORCE           "true" to skip the confirmation prompt
# =============================================================================

set -euo pipefail

# --- Helpers -----------------------------------------------------------------
# >>> ui-block (managed by scripts/sync-ui.sh — do not edit here) >>>
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
# <<< ui-block <<<

# --- Root check --------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# --- Configuration -----------------------------------------------------------
REMOVE_DATA="${REMOVE_DATA:-false}"
REMOVE_SWAP="${REMOVE_SWAP:-false}"
REMOVE_DOCKER="${REMOVE_DOCKER:-false}"
KASM_SWAP_GB="${KASM_SWAP_GB:-4}"
FORCE="${FORCE:-false}"

HAVE_DOCKER=false
command -v docker >/dev/null 2>&1 && HAVE_DOCKER=true

# --- Detect ------------------------------------------------------------------
INSTALLED=false
[[ -d /opt/kasm ]] && INSTALLED=true
if [[ "$HAVE_DOCKER" == "true" ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^kasm_'; then
    INSTALLED=true
fi

if [[ "$INSTALLED" != "true" ]]; then
    ok "No Kasm installation detected. Nothing to do."
    exit 0
fi

echo ""
echo "Kasm Workspaces - Uninstall"
echo "================================================="
echo ""
echo "  This will remove all Kasm containers, images, networks,"
echo "  volumes and the /opt/kasm install tree."
echo ""
echo "  User data   /data/kasm-profiles, /data/kasm-shared   $([[ "$REMOVE_DATA" == "true" ]] && echo 'WILL be removed' || echo 'will be KEPT')"
echo "  Swap file   /mnt/${KASM_SWAP_GB}GiB.swap             $([[ "$REMOVE_SWAP" == "true" ]] && echo 'WILL be removed' || echo 'will be KEPT')"
echo "  Docker      engine                                  $([[ "$REMOVE_DOCKER" == "true" ]] && echo 'WILL be purged' || echo 'will be KEPT')"
echo ""

# --- Confirmation ------------------------------------------------------------
if [[ "$FORCE" != "true" ]]; then
    reply=""
    if [[ -r /dev/tty ]]; then
        read -rp "Type 'yes' to proceed: " reply </dev/tty || reply=""
    else
        read -rp "Type 'yes' to proceed: " reply || reply=""
    fi
    [[ "$reply" == "yes" ]] || { warn "Aborted. Nothing was changed."; exit 0; }
fi

echo ""

# --- Stop services -----------------------------------------------------------
if [[ -x /opt/kasm/current/bin/stop ]]; then
    info "Stopping Kasm services..."
    bash /opt/kasm/current/bin/stop >/dev/null 2>&1 || warn "Stop script returned an error - continuing."
    ok "Kasm services stopped."
fi

# --- Containers --------------------------------------------------------------
if [[ "$HAVE_DOCKER" == "true" ]]; then
    info "Removing Kasm containers..."
    mapfile -t _containers < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^kasm_' || true)
    if [[ ${#_containers[@]} -gt 0 ]]; then
        docker rm -f "${_containers[@]}" >/dev/null 2>&1 || true
        ok "Removed ${#_containers[@]} container(s)."
    else
        ok "No Kasm containers found."
    fi

    # --- Images --------------------------------------------------------------
    info "Removing Kasm images..."
    mapfile -t _images < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i '^kasmweb/' || true)
    if [[ ${#_images[@]} -gt 0 ]]; then
        docker rmi -f "${_images[@]}" >/dev/null 2>&1 || true
        ok "Removed ${#_images[@]} image(s)."
    else
        ok "No Kasm images found."
    fi

    # --- Networks ------------------------------------------------------------
    info "Removing Kasm networks..."
    mapfile -t _networks < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -i 'kasm' || true)
    if [[ ${#_networks[@]} -gt 0 ]]; then
        docker network rm "${_networks[@]}" >/dev/null 2>&1 || true
        ok "Removed ${#_networks[@]} network(s)."
    else
        ok "No Kasm networks found."
    fi

    # --- Volumes -------------------------------------------------------------
    info "Removing Kasm volumes..."
    mapfile -t _volumes < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -i 'kasm' || true)
    if [[ ${#_volumes[@]} -gt 0 ]]; then
        docker volume rm "${_volumes[@]}" >/dev/null 2>&1 || true
        ok "Removed ${#_volumes[@]} volume(s)."
    else
        ok "No Kasm volumes found."
    fi
else
    warn "Docker not found - skipping container/image cleanup."
fi

# --- Install tree ------------------------------------------------------------
if [[ -d /opt/kasm ]]; then
    info "Removing /opt/kasm..."
    rm -rf /opt/kasm
    ok "Removed /opt/kasm."
fi

# --- Swap (optional) ---------------------------------------------------------
if [[ "$REMOVE_SWAP" == "true" ]]; then
    SWAP_FILE="/mnt/${KASM_SWAP_GB}GiB.swap"
    if [[ -f "$SWAP_FILE" ]]; then
        info "Removing swap file ${SWAP_FILE}..."
        swapoff "$SWAP_FILE" 2>/dev/null || true
        sed -i "\#^${SWAP_FILE} #d" /etc/fstab 2>/dev/null || true
        rm -f "$SWAP_FILE"
        ok "Swap file removed and fstab entry cleaned."
    else
        warn "Swap file ${SWAP_FILE} not found - skipping."
    fi
fi

# --- Persistent data (optional) ----------------------------------------------
if [[ "$REMOVE_DATA" == "true" ]]; then
    for d in /data/kasm-profiles /data/kasm-shared; do
        if [[ -d "$d" ]]; then
            info "Removing ${d}..."
            rm -rf "$d"
            ok "Removed ${d}."
        fi
    done
else
    if [[ -d /data/kasm-profiles || -d /data/kasm-shared ]]; then
        info "Keeping user data (set REMOVE_DATA=true to delete):"
        [[ -d /data/kasm-profiles ]] && echo "    /data/kasm-profiles"
        [[ -d /data/kasm-shared ]]   && echo "    /data/kasm-shared"
    fi
fi

# --- Docker (optional) -------------------------------------------------------
if [[ "$REMOVE_DOCKER" == "true" && "$HAVE_DOCKER" == "true" ]]; then
    info "Purging Docker engine..."
    export DEBIAN_FRONTEND=noninteractive
    systemctl disable --now docker 2>/dev/null || true
    systemctl disable --now containerd 2>/dev/null || true
    apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    rm -rf /var/lib/docker /var/lib/containerd
    ok "Docker engine purged."
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "Uninstall Complete"
echo "================================================="
echo ""
echo "  Kasm Workspaces has been removed."
[[ "$REMOVE_DATA" != "true" && ( -d /data/kasm-profiles || -d /data/kasm-shared ) ]] && \
    echo "  User data was preserved under /data (see above)."
[[ "$REMOVE_DOCKER" != "true" && "$HAVE_DOCKER" == "true" ]] && \
    echo "  Docker was left installed (other containers may depend on it)."
echo ""
