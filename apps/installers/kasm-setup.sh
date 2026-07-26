#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/kasm-setup.sh?$(date +%s))"
# Purpose: Install Kasm Workspaces (Ubuntu)
# =============================================================================
# Usage:
#   No args (interactive):
#     - No existing install     -> fresh install
#     - Existing install found  -> menu: upgrade / uninstall / exit
#   CLI arg (non-interactive):  install | upgrade | uninstall
#
# Defaults:
#   Password                                            (default: password)
#   KASM_VERSION        Target version, or "latest"     (default: latest)
#   KASM_SWAP_GB        Swap size in GB                 (default: 4)
#   KASM_PORT           Web UI port                     (default: 443)
#   SKIP_QEMU_AGENT     Set "true" to skip              (default: false)
#   SKIP_PERSISTENT     Set "true" to skip dirs         (default: false)
#
# Uninstall flags (opt-in; also prompted interactively):
#   REMOVE_DATA         Delete /data/kasm-profiles + -shared  (default: false)
#   REMOVE_SWAP         Remove the install swap file          (default: false)
#   REMOVE_DOCKER       Purge the Docker engine               (default: false)
#   FORCE               Skip the uninstall confirmation       (default: false)
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
# "latest" resolves the newest stable release at runtime; pin an explicit
# version (e.g. KASM_VERSION=1.18.1) to override.
KASM_VERSION="${KASM_VERSION:-latest}"
KASM_FALLBACK_VERSION="1.18.1"   # used if the latest cannot be resolved online
KASM_BASE_URL="https://kasm-static-content.s3.amazonaws.com"
KASM_TARBALL=""                  # set by resolve_target()
KASM_URL=""                      # set by resolve_target()
KASM_SWAP_GB="${KASM_SWAP_GB:-4}"
KASM_PORT="${KASM_PORT:-443}"
SKIP_QEMU_AGENT="${SKIP_QEMU_AGENT:-false}"
SKIP_PERSISTENT="${SKIP_PERSISTENT:-false}"
FORCE="${FORCE:-false}"
DEFAULT_PASS="password"

# --- Menu helpers ------------------------------------------------------------
asknum(){ # asknum "prompt" "min" "max" "default"
  local p="$1" min="$2" max="$3" def="$4" in
  while true; do
    if [[ -r /dev/tty ]]; then
      read -rp "$p [$min-$max, 0 to exit] (default: $def): " in </dev/tty || in="$def"
    else
      read -rp "$p [$min-$max, 0 to exit] (default: $def): " in || in="$def"
    fi
    in="${in:-$def}"
    [[ "$in" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( in==0 || (in>=min && in<=max) )) && { echo "$in"; return; }
  done
}

askyn(){ # askyn "prompt"  -> exit 0 if yes
  local p="$1" in=""
  if [[ -r /dev/tty ]]; then
    read -rp "$p [y/N]: " in </dev/tty || in=""
  else
    read -rp "$p [y/N]: " in || in=""
  fi
  [[ "$in" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- Version resolution ------------------------------------------------------
# List available "kasm_release_<version>[.<hash>].tar.gz" artifact names, one
# per line. Tries the S3 bucket listing first (authoritative), then falls back
# to scraping the public downloads page. Empty output / non-zero => unknown.
list_release_tarballs(){
  local xml html page
  xml="$(curl -fsSL --max-time 15 \
    "${KASM_BASE_URL}/?list-type=2&prefix=kasm_release_&max-keys=2000" 2>/dev/null || true)"
  if [[ -n "$xml" ]]; then
    printf '%s' "$xml" \
      | grep -oE 'kasm_release_[0-9]+\.[0-9]+\.[0-9]+(\.[0-9a-f]+)?\.tar\.gz' \
      | grep -viE 'rc|beta|alpha|develop' | sort -u && return 0
  fi
  for page in "https://www.kasmweb.com/downloads" "https://kasm.com/downloads"; do
    html="$(curl -fsSL --max-time 15 "$page" 2>/dev/null || true)"
    [[ -n "$html" ]] || continue
    printf '%s' "$html" \
      | grep -oE 'kasm_release_[0-9]+\.[0-9]+\.[0-9]+(\.[0-9a-f]+)?\.tar\.gz' \
      | grep -viE 'rc|beta|alpha|develop' | sort -u && return 0
  done
  return 1
}

# Given a set of tarball names on stdin, print the one for the highest version.
highest_tarball(){
  local names ver
  names="$(cat)"
  [[ -n "$names" ]] || return 1
  ver="$(printf '%s\n' "$names" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1)"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$names" | grep -F "kasm_release_${ver}" | head -n1
}

# Populate KASM_VERSION / KASM_TARBALL / KASM_URL for the install/upgrade.
resolve_target(){
  local names tarball
  if [[ "$KASM_VERSION" == "latest" ]]; then
    info "Resolving the latest Kasm version..."
    names="$(list_release_tarballs || true)"
    tarball="$(printf '%s' "$names" | highest_tarball 2>/dev/null || true)"
    if [[ -z "$tarball" ]]; then
      warn "Could not determine the latest version online - falling back to ${KASM_FALLBACK_VERSION}."
      KASM_VERSION="$KASM_FALLBACK_VERSION"
      tarball="kasm_release_${KASM_VERSION}.tar.gz"
    else
      KASM_VERSION="$(printf '%s' "$tarball" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
      ok "Latest stable is Kasm ${KASM_VERSION}."
    fi
  else
    # Explicit pin: resolve the exact artifact (handles hashed names) if we can,
    # otherwise assume the plain naming.
    names="$(list_release_tarballs || true)"
    tarball="$(printf '%s\n' "$names" | grep -F "kasm_release_${KASM_VERSION}" | head -n1 || true)"
    [[ -n "$tarball" ]] || tarball="kasm_release_${KASM_VERSION}.tar.gz"
  fi
  KASM_TARBALL="$tarball"
  KASM_URL="${KASM_BASE_URL}/${KASM_TARBALL}"
}

# --- Uninstall ---------------------------------------------------------------
uninstall_kasm(){
  local HAVE_DOCKER=false
  command -v docker >/dev/null 2>&1 && HAVE_DOCKER=true

  # Optional removals: an explicit env flag wins; otherwise ask when interactive.
  local remove_data="${REMOVE_DATA:-false}"
  local remove_swap="${REMOVE_SWAP:-false}"
  local remove_docker="${REMOVE_DOCKER:-false}"

  if [[ "$FORCE" != "true" && -r /dev/tty ]]; then
    askyn "Uninstall Kasm? Removes all containers, images and /opt/kasm" \
      || { warn "Aborted. Nothing was changed."; return 0; }
    if [[ "$remove_data" != "true" ]] && { [[ -d /data/kasm-profiles ]] || [[ -d /data/kasm-shared ]]; }; then
      askyn "Also delete user data in /data/kasm-profiles and /data/kasm-shared?" && remove_data=true
    fi
    if [[ "$remove_swap" != "true" && -f "/mnt/${KASM_SWAP_GB}GiB.swap" ]]; then
      askyn "Also remove the swap file /mnt/${KASM_SWAP_GB}GiB.swap?" && remove_swap=true
    fi
    if [[ "$remove_docker" != "true" && "$HAVE_DOCKER" == "true" ]]; then
      askyn "Also purge the Docker engine? (other containers will be lost)" && remove_docker=true
    fi
  fi

  echo ""

  # Stop services
  if [[ -x /opt/kasm/current/bin/stop ]]; then
    info "Stopping Kasm services..."
    bash /opt/kasm/current/bin/stop >/dev/null 2>&1 || warn "Stop script returned an error - continuing."
    ok "Kasm services stopped."
  fi

  if [[ "$HAVE_DOCKER" == "true" ]]; then
    info "Removing Kasm containers..."
    mapfile -t _containers < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^kasm_' || true)
    if [[ ${#_containers[@]} -gt 0 ]]; then
      docker rm -f "${_containers[@]}" >/dev/null 2>&1 || true
      ok "Removed ${#_containers[@]} container(s)."
    else
      ok "No Kasm containers found."
    fi

    info "Removing Kasm images..."
    mapfile -t _images < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i '^kasmweb/' || true)
    if [[ ${#_images[@]} -gt 0 ]]; then
      docker rmi -f "${_images[@]}" >/dev/null 2>&1 || true
      ok "Removed ${#_images[@]} image(s)."
    else
      ok "No Kasm images found."
    fi

    info "Removing Kasm networks..."
    mapfile -t _networks < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -i 'kasm' || true)
    if [[ ${#_networks[@]} -gt 0 ]]; then
      docker network rm "${_networks[@]}" >/dev/null 2>&1 || true
      ok "Removed ${#_networks[@]} network(s)."
    else
      ok "No Kasm networks found."
    fi

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

  if [[ -d /opt/kasm ]]; then
    info "Removing /opt/kasm..."
    rm -rf /opt/kasm
    ok "Removed /opt/kasm."
  fi

  if [[ "$remove_swap" == "true" ]]; then
    local swap_file="/mnt/${KASM_SWAP_GB}GiB.swap"
    if [[ -f "$swap_file" ]]; then
      info "Removing swap file ${swap_file}..."
      swapoff "$swap_file" 2>/dev/null || true
      sed -i "\#^${swap_file} #d" /etc/fstab 2>/dev/null || true
      rm -f "$swap_file"
      ok "Swap file removed and fstab entry cleaned."
    else
      warn "Swap file ${swap_file} not found - skipping."
    fi
  fi

  if [[ "$remove_data" == "true" ]]; then
    local d
    for d in /data/kasm-profiles /data/kasm-shared; do
      if [[ -d "$d" ]]; then
        info "Removing ${d}..."
        rm -rf "$d"
        ok "Removed ${d}."
      fi
    done
  elif [[ -d /data/kasm-profiles || -d /data/kasm-shared ]]; then
    info "Keeping user data (set REMOVE_DATA=true to delete):"
    [[ -d /data/kasm-profiles ]] && echo "    /data/kasm-profiles"
    [[ -d /data/kasm-shared ]]   && echo "    /data/kasm-shared"
  fi

  if [[ "$remove_docker" == "true" && "$HAVE_DOCKER" == "true" ]]; then
    info "Purging Docker engine..."
    export DEBIAN_FRONTEND=noninteractive
    systemctl disable --now docker 2>/dev/null || true
    systemctl disable --now containerd 2>/dev/null || true
    apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    rm -rf /var/lib/docker /var/lib/containerd
    ok "Docker engine purged."
  fi

  echo ""
  echo "Uninstall Complete"
  echo "================================================="
  echo ""
  echo "  Kasm Workspaces has been removed."
  [[ "$remove_data" != "true" && ( -d /data/kasm-profiles || -d /data/kasm-shared ) ]] && \
    echo "  User data was preserved under /data (see above)."
  [[ "$remove_docker" != "true" && "$HAVE_DOCKER" == "true" ]] && \
    echo "  Docker was left installed (other containers may depend on it)."
  echo ""
}

# --- Determine action --------------------------------------------------------
ACTION="${1:-}"

MODE="install"
EXISTING_VERSION=""
if [[ -d /opt/kasm/current ]]; then
    EXISTING_VERSION=$(readlink -f /opt/kasm/current | grep -oP '\d+\.\d+\.\d+' || true)
    MODE="upgrade"
fi

# Uninstall never needs to resolve a version / touch the network.
case "$ACTION" in
    uninstall)      uninstall_kasm; exit 0 ;;
    help|-h|--help) echo "Usage: kasm-setup.sh [install|upgrade|uninstall]"; exit 0 ;;
    install)        MODE="install" ;;
    upgrade)        MODE="upgrade" ;;
    "")             : ;;  # interactive / automated default handled below
    *)              fail "Unknown action '$ACTION' (try: install|upgrade|uninstall)" ;;
esac

# Interactive menu for an existing install invoked with no argument.
if [[ -z "$ACTION" && -d /opt/kasm/current && -r /dev/tty ]]; then
    echo ""
    echo "Kasm ${EXISTING_VERSION:-unknown} is installed."
    echo "  1) Update to the latest version"
    echo "  2) Uninstall"
    echo "  0) Exit"
    case "$(asknum 'Enter choice' 1 2 1)" in
        0) ok "Nothing to do."; exit 0 ;;
        1) MODE="upgrade" ;;
        2) uninstall_kasm; exit 0 ;;
    esac
fi

# We are installing or upgrading -> resolve the target version now.
resolve_target

# Existing install already on the target version -> nothing to do.
if [[ -d /opt/kasm/current && "$EXISTING_VERSION" == "$KASM_VERSION" ]]; then
    ok "Kasm ${KASM_VERSION} is already installed (latest). Nothing to do."
    exit 0
fi

echo ""
if [[ "$MODE" == "upgrade" ]]; then
    echo "Kasm Workspaces - Upgrade ${EXISTING_VERSION} -> ${KASM_VERSION}"
else
    echo "Kasm Workspaces ${KASM_VERSION} - Fresh Install"
fi
echo "================================================="
echo ""

# --- System update -----------------------------------------------------------
info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "System packages updated."

# --- Prerequisites -----------------------------------------------------------
info "Installing prerequisites..."
apt-get install -y -qq curl wget apt-transport-https ca-certificates > /dev/null 2>&1
ok "Prerequisites installed."

# QEMU Guest Agent (install only)
if [[ "$MODE" == "install" && "${SKIP_QEMU_AGENT}" != "true" ]]; then
    info "Installing QEMU guest agent..."
    apt-get install -y -qq qemu-guest-agent > /dev/null 2>&1
    systemctl enable --now qemu-guest-agent 2>/dev/null || true
    ok "QEMU guest agent active."
elif [[ "${SKIP_QEMU_AGENT}" == "true" ]]; then
    warn "Skipping QEMU guest agent."
fi

# Swap (install only)
if [[ "$MODE" == "install" ]]; then
    SWAP_FILE="/mnt/${KASM_SWAP_GB}GiB.swap"
    if [[ ! -f "${SWAP_FILE}" ]]; then
        info "Creating ${KASM_SWAP_GB} GB swap file..."
        fallocate -l "${KASM_SWAP_GB}g" "${SWAP_FILE}"
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}"
        swapon "${SWAP_FILE}"
        grep -q "${SWAP_FILE}" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        ok "Swap configured (${KASM_SWAP_GB} GB, persistent)."
    else
        warn "Swap file already exists at ${SWAP_FILE} - skipping."
    fi
fi

# --- Download ----------------------------------------------------------------
info "Downloading Kasm Workspaces v${KASM_VERSION}..."
cd /tmp
if [[ -f "${KASM_TARBALL}" ]]; then
    warn "Tarball already present in /tmp - reusing."
else
    curl -fSL -O "${KASM_URL}" || fail "Download failed. Check KASM_VERSION or network connectivity."
fi
ok "Download complete."

# --- Extract -----------------------------------------------------------------
info "Extracting..."
tar -xf "${KASM_TARBALL}"
ok "Extracted."

# --- Install or Upgrade ------------------------------------------------------
if [[ "$MODE" == "upgrade" ]]; then

    info "Backing up database before upgrade..."
    mkdir -p /opt/kasm/backups
    chown -R 70:70 /opt/kasm/backups

    BACKUP_FILE="/opt/kasm/backups/kasm_db_backup_pre_${KASM_VERSION}.tar"
    bash /opt/kasm/current/bin/utils/db_backup -f "${BACKUP_FILE}" -p /opt/kasm/current/ \
        && ok "Database backed up to ${BACKUP_FILE}." \
        || warn "Database backup failed. Consider a VM snapshot as fallback."

    info "Running upgrade (this may take several minutes)..."
    echo ""
    bash kasm_release/upgrade.sh -L "${KASM_PORT}" || fail "Upgrade failed. Check /tmp for kasm_upgrade_*.log."
    echo ""
    ok "Upgraded from ${EXISTING_VERSION} to ${KASM_VERSION}."

else

    info "Running installer (this may take several minutes)..."
    echo ""
    bash kasm_release/install.sh \
        -L "${KASM_PORT}" \
        -e \
        --admin-password "${DEFAULT_PASS}" \
        --user-password "${DEFAULT_PASS}" \
        || fail "Installer failed."
    echo ""
    ok "Kasm Workspaces ${KASM_VERSION} installed."
fi

# --- Docker group ------------------------------------------------------------
# Kasm's installer sets up Docker. Add the invoking user to the docker group
# so they can run docker commands without sudo.
if [[ "$MODE" == "install" ]]; then
    REAL_USER="${SUDO_USER:-root}"
    if getent group docker > /dev/null 2>&1; then
        usermod -aG docker "${REAL_USER}" 2>/dev/null || true
        ok "User '${REAL_USER}' added to docker group (log out and back in to take effect)."
    fi
fi

# --- Persistent storage ------------------------------------------------------
if [[ "${SKIP_PERSISTENT}" != "true" ]]; then
    info "Ensuring persistent storage directories exist..."
    mkdir -p /data/kasm-profiles
    chown -R 1000:1000 /data/kasm-profiles
    mkdir -p /data/kasm-shared
    chown -R 1000:1000 /data/kasm-shared
    ok "Persistent storage ready."
fi

# --- Cleanup -----------------------------------------------------------------
info "Cleaning up /tmp..."
rm -rf /tmp/kasm_release /tmp/"${KASM_TARBALL}"
ok "Cleanup done."

# --- Summary -----------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
if [[ "$MODE" == "upgrade" ]]; then
    echo "Upgrade Complete"
    echo "================================================="
    echo ""
    echo "  ${EXISTING_VERSION} -> ${KASM_VERSION}"
    echo "  Web UI        https://${SERVER_IP}:${KASM_PORT}"
    echo "  Backup        ${BACKUP_FILE}"
    echo ""
    echo "  Log in with your existing credentials."
    echo "  Check the Workspace Registry for updated images."
else
    echo "Install Complete"
    echo "================================================="
    echo ""
    echo "  Web UI        https://${SERVER_IP}:${KASM_PORT}"
    echo ""
    echo "  Admin login   admin@kasm.local"
    echo "  User login    user@kasm.local"
    echo "  Password      ${DEFAULT_PASS}"
fi

echo ""
echo "  A self-signed certificate warning is expected."
echo ""
echo ""
echo "Getting Started"
echo "================================================="
echo ""
echo "  1. Open https://${SERVER_IP}:${KASM_PORT} in your browser."
echo "     Accept the self-signed certificate warning."
echo ""
echo "  2. Log in as admin@kasm.local with password: ${DEFAULT_PASS}"
echo ""
echo "  3. CHANGE BOTH PASSWORDS IMMEDIATELY."
echo "     Admin > Users > select user > edit > update password."
echo ""
echo ""
echo "Persistent Profiles Setup Guide"
echo "================================================="
echo ""
echo "  Kasm does not persist user data between sessions by default."
echo "  To enable it, configure each workspace in the Admin UI:"
echo ""
echo "    1. Go to Admin > Workspaces > edit the workspace image."
echo "    2. Under 'Persistent Profile Path', enter:"
echo "       /data/kasm-profiles/<workspace-name>/{user_id}"
echo ""
echo "       Examples:"
echo "       /data/kasm-profiles/brave/{user_id}"
echo "       /data/kasm-profiles/desktop/{user_id}"
echo ""
echo "       Use any name that identifies the workspace. Kasm creates"
echo "       the subdirectories automatically on first session launch."
echo ""
echo "    3. Under 'Docker Run Config Override', add a shared volume:"
echo '       {'
echo '         "/data/kasm-shared": {'
echo '           "bind": "/home/kasm-user/shared",'
echo '           "mode": "rw",'
echo '           "uid": 1000,'
echo '           "gid": 1000'
echo '         }'
echo '       }'
echo ""
echo "       This mounts /data/kasm-shared on the host to"
echo "       /home/kasm-user/shared inside every workspace,"
echo "       giving users a common folder to share files across"
echo "       different workspace types."
echo ""
echo "  Storage locations:"
echo "    Profiles    /data/kasm-profiles/"
echo "    Shared      /data/kasm-shared/"
echo ""
