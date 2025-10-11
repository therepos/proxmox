#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-dockerhost2.sh?$(date +%s))"
# purpose: installs docker engine, docker compose, and optional nvidia container toolkit

set -euo pipefail

# --- logging ---
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/dockerhost-install-$(date +%F).log"
mkdir -p "$LOG_DIR"; : >"$LOG_FILE"; chmod 0644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'printf "\033[1;31m✘ Error on line %s\033[0m\n" "$LINENO"' ERR
log()  { printf "\033[1;32m✔ %s\033[0m\n" "$1"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$1"; }
err()  { printf "\033[1;31m✘ %s\033[0m\n" "$1" >&2; }

require_root() { [[ $EUID -eq 0 ]] || { err "Run as root (no sudo on Proxmox)."; exit 1; }; }

detect_os() {
  [[ -r /etc/os-release ]] || { err "/etc/os-release not found"; exit 1; }
  . /etc/os-release
  OS_ID="${ID:-debian}"               # debian | ubuntu
  OS_CODENAME="${VERSION_CODENAME:-}" # trixie/bookworm/bullseye/jammy/focal...
  ARCH="$(dpkg --print-architecture)"
  if [[ -z "${OS_CODENAME}" ]]; then
    case "${OS_ID}:${VERSION_ID:-}" in
      debian:12) OS_CODENAME="bookworm" ;;
      debian:11) OS_CODENAME="bullseye" ;;
      ubuntu:22.04) OS_CODENAME="jammy" ;;
      ubuntu:20.04) OS_CODENAME="focal" ;;
      *) err "Cannot determine VERSION_CODENAME"; exit 1 ;;
    esac
  fi
  log "Detected: ${PRETTY_NAME:-$OS_ID} (${OS_CODENAME}) [${ARCH}]"
}

repo_exists() { curl -fsSI "https://download.docker.com/linux/${OS_ID}/dists/${1}/Release" >/dev/null 2>&1; }

pick_supported_codename() {
  local c="${OS_CODENAME}"
  if repo_exists "$c"; then echo "$c"; return; fi
  if [[ "$OS_ID" == "debian" ]]; then
    for alt in bookworm bullseye; do
      if repo_exists "$alt"; then
        warn "Docker repo not available for '${c}'; falling back to '${alt}'."
        echo "$alt"; return
      fi
    done
  elif [[ "$OS_ID" == "ubuntu" ]]; then
    for alt in jammy focal; do
      if repo_exists "$alt"; then
        warn "Docker repo not available for '${c}'; falling back to '${alt}'."
        echo "$alt"; return
      fi
    done
  fi
  err "No supported Docker repo for ${OS_ID}/${c}."
  exit 1
}

apt_prep() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg apt-transport-https software-properties-common || true
  log "Prerequisites installed"
}

install_repo() {
  # remove any malformed docker entries first (surgical cleanup)
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    mv /etc/apt/sources.list.d/docker.list "/etc/apt/sources.list.d/docker.list.$(date +%s).bak"
  fi
  sed -i 's|^\(.*download\.docker\.com.*\)$|# \1|' /etc/apt/sources.list || true

  install -m 0755 -d /etc/apt/keyrings
  KEYRING="/etc/apt/keyrings/docker.gpg"
  if [[ ! -f "$KEYRING" ]]; then
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o "$KEYRING"
  else
    warn "Keyring exists: $KEYRING (keeping)"
  fi
  chmod a+r "$KEYRING"

  SUPPORTED_CODENAME="$(pick_supported_codename)"
  LIST="/etc/apt/sources.list.d/docker.list"
  echo "deb [arch=${ARCH} signed-by=${KEYRING}] https://download.docker.com/linux/${OS_ID} ${SUPPORTED_CODENAME} stable" > "$LIST"
  log "Docker repo configured: ${SUPPORTED_CODENAME}"
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  apt-get update -y
}

install_docker() {
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  log "Docker installed and started"
}

verify() {
  docker --version
  docker compose version
  log "Validation OK"
}

main() {
  require_root
  detect_os
  apt_prep
  install_repo
  install_docker
  verify
  echo "Log saved to: $LOG_FILE"
  log "All done 🎉"
}

main "$@"
