#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/portainer-setup.sh?$(date +%s))"
# Purpose: Installs portainer docker (PVE9)
# =============================================================================
# Usage:
#   portainer-setup                      Interactive menu
#   portainer-setup install              Install and start Portainer
#   portainer-setup update               Pull latest image, recreate container
#   portainer-setup backup               Snapshot portainer_data to BACKUP_DIR
#   portainer-setup restore              Restore from newest snapshot
#   portainer-setup uninstall            Remove container, volume and images
#
# Non-interactive (for Webmin custom commands):
#   bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/portainer-setup.sh?$(date +%s))" -- update
#
# Note: keep the `--` placeholder — bash assigns the first word after the
#       script body to $0, not $1, so without it the action is lost.
# =============================================================================

set -euo pipefail

# --- Settings ----------------------------------------------------------------
IMAGE="portainer/portainer-ce:lts"
NAME="portainer"
PORT_HTTPS="9443"
HOST_BIND="/mnt/sec/apps"   # optional; leave empty to disable
BACKUP_DIR="/mnt/sec/backup/portainer"
HELPER_IMAGE="alpine:3"     # small image used for volume tar/untar

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
# True only if a controlling terminal can actually be opened. Testing -r alone
# is not enough: /dev/tty exists and looks readable even with no controlling
# terminal, and the open then fails at runtime.
have_tty(){ [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

asknum(){ # asknum "prompt" "min" "max" "default"
  local p="$1" min="$2" max="$3" def="$4" in
  while true; do
    # Read from /dev/tty if available (interactive) otherwise read from stdin
    if have_tty; then
      read -rp "$p [$min-$max, 0 to exit] (default: $def): " in </dev/tty || in="$def"
    else
      read -rp "$p [$min-$max, 0 to exit] (default: $def): " in || in="$def"
    fi
    in="${in:-$def}"
    [[ "$in" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( in==0 || (in>=min && in<=max) )) && { echo "$in"; return; }
  done
}

# --- Prechecks ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
command -v docker >/dev/null || fail "Docker not found"
[[ -S /var/run/docker.sock ]] || fail "Docker socket missing: /var/run/docker.sock"
[[ -n "${HOST_BIND}" ]] && mkdir -p "${HOST_BIND}"

exists_container(){ docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; }

start_portainer(){
  local sock_gid; sock_gid="$(stat -c '%g' /var/run/docker.sock)"
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${NAME}" \
    --pull=always --restart=always \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    -p ${PORT_HTTPS}:${PORT_HTTPS} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    $( [[ -n "${HOST_BIND}" ]] && echo "-v ${HOST_BIND}:/mnt/sec/apps" ) \
    --group-add "${sock_gid}" \
    "${IMAGE}" \
    -H unix:///var/run/docker.sock >/dev/null

  for _ in {1..30}; do
    docker ps --format '{{.Names}}' | grep -qx "${NAME}" && break
    sleep 1
  done
  if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
    local ip; ip=$(hostname -I | awk '{print $1}')
    ok "Portainer is up at https://${ip}:${PORT_HTTPS}"
  else
    fail "Container failed to start"
  fi
}

update_portainer(){
  info "Pulling ${IMAGE}…"
  docker pull "${IMAGE}" >/dev/null
  info "Restarting ${NAME}…"
  start_portainer
}

uninstall_portainer(){ # auto-clean everything
  info "Stopping/removing container…"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  info "Removing volume 'portainer_data'…"
  docker volume rm portainer_data >/dev/null 2>&1 || true
  info "Removing Portainer images…"
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -i '^portainer/portainer-ce:' \
    | xargs -r docker rmi -f >/dev/null 2>&1 || true
  ok "Uninstalled Portainer (container, volume, images)."
}

backup_portainer(){ # snapshot the portainer_data volume to BACKUP_DIR
  local stamp out was_running=0

  docker volume inspect portainer_data >/dev/null 2>&1 \
    || fail "No 'portainer_data' volume to back up"
  mkdir -p "${BACKUP_DIR}" || fail "Cannot create ${BACKUP_DIR}"

  stamp="$(date +%Y%m%d-%H%M%S)"
  out="${BACKUP_DIR}/portainer-${stamp}.tar.gz"

  # Portainer holds its database open, so stop it for a consistent snapshot.
  if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
    was_running=1
    info "Stopping ${NAME} for a consistent snapshot…"
    docker stop "${NAME}" >/dev/null
  fi

  info "Archiving 'portainer_data' → ${out}"
  if docker run --rm \
       -v portainer_data:/data:ro \
       -v "${BACKUP_DIR}:/backup" \
       "${HELPER_IMAGE}" \
       tar czf "/backup/portainer-${stamp}.tar.gz" -C /data . ; then
    if (( was_running )); then
      info "Restarting ${NAME}…"
      docker start "${NAME}" >/dev/null
    fi
    ok "Backup written: ${out}"
  else
    if (( was_running )); then docker start "${NAME}" >/dev/null 2>&1 || true; fi
    rm -f "${out}"
    fail "Backup failed"
  fi
}

restore_portainer(){
  local latest tarflag f
  local -a archives=()

  [[ -d "${BACKUP_DIR}" ]] || fail "Backup directory not found: ${BACKUP_DIR}"

  # Collect via globs rather than parsing ls: an unmatched glob makes ls exit
  # non-zero, which pipefail turns into a silent death before the check below.
  # .tar.gz is what backup writes; .tar is accepted so older snapshots restore.
  shopt -s nullglob
  archives=( "${BACKUP_DIR}"/portainer-*.tar.gz "${BACKUP_DIR}"/portainer-*.tar )
  shopt -u nullglob
  (( ${#archives[@]} )) || fail "No portainer-*.tar.gz backup found in ${BACKUP_DIR}"

  latest="${archives[0]}"
  for f in "${archives[@]}"; do
    if [[ "$f" -nt "$latest" ]]; then latest="$f"; fi
  done

  info "Using latest backup: ${latest}"
  info "Stopping ${NAME} (if running)…"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true

  docker volume inspect portainer_data >/dev/null 2>&1 \
    || docker volume create portainer_data >/dev/null

  tarflag="xzf"
  [[ "${latest}" == *.tar ]] && tarflag="xf"

  # Clear the volume first so files deleted since the backup do not survive it.
  info "Restoring into 'portainer_data'…"
  docker run --rm \
    -v portainer_data:/data \
    -v "${latest}:/backup.tar:ro" \
    "${HELPER_IMAGE}" \
    sh -c "rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null; tar ${tarflag} /backup.tar -C /data" \
    || fail "Restore failed — 'portainer_data' may be incomplete"

  ok "Restore complete. Starting Portainer…"
  start_portainer
}

usage(){
  cat <<'EOF'
Usage:
  portainer-setup.sh                   # interactive menu (CLI)
  portainer-setup.sh install           # non-interactive
  portainer-setup.sh update
  portainer-setup.sh backup
  portainer-setup.sh restore
  portainer-setup.sh uninstall
  portainer-setup.sh 1|2|3|4           # also accepted (context-sensitive)

Piped from wget (Webmin custom command) — keep the '--' placeholder:
  bash -c "$(wget -qLO- .../portainer-setup.sh?$(date +%s))" -- update
EOF
}

# Named actions work regardless of install state, so a Webmin button never has
# to care whether the container exists yet. Numeric args stay context-sensitive
# to match the menu.
run_action(){
  case "$1" in
    install)        start_portainer ;;
    update)         update_portainer ;;
    backup)         backup_portainer ;;
    restore)        restore_portainer ;;
    uninstall)      uninstall_portainer ;;
    help|-h|--help) usage ;;
    1) if exists_container; then update_portainer; else start_portainer; fi ;;
    2) exists_container || fail "Portainer is not installed (try: install)"
       backup_portainer ;;
    3) exists_container || fail "Portainer is not installed (try: install)"
       restore_portainer ;;
    4) exists_container || fail "Portainer is not installed (try: install)"
       uninstall_portainer ;;
    *) usage >&2
       fail "Unknown action '$1' (try: install|update|backup|restore|uninstall)" ;;
  esac
}

# Parse optional CLI arg (works in Webmin).
# Under `bash -c "$(wget …)" update` the word lands in $0 rather than $1, so
# accept it from there too — but only when it names a known action, so a real
# $0 (a path, or the '--' placeholder) is never mistaken for one.
arg="${1:-}"
if [[ -z "$arg" && $# -eq 0 ]]; then
  case "$0" in
    install|update|backup|restore|uninstall|help|-h|--help|1|2|3|4) arg="$0" ;;
  esac
fi

if [[ -n "$arg" ]]; then
  run_action "$arg"
  exit 0
fi

# No action given: the menu needs a terminal. Fail loudly rather than hang or
# silently pick a default when run headless (Webmin, cron, orchestrator).
if ! have_tty; then
  usage >&2
  fail "No terminal for the interactive menu — pass an action (e.g. update)."
fi

# Interactive menu (CLI)
if exists_container; then
  echo "Portainer is already installed. What would you like to do?"
  echo "1) Update"
  echo "2) Backup"
  echo "3) Restore"
  echo "4) Uninstall"
  echo "0) Exit"
  choice="$(asknum 'Enter choice' 1 4 1)"
  case "$choice" in
    0) ok "Bye."; exit 0 ;;
    1) update_portainer ;;
    2) backup_portainer ;;
    3) restore_portainer ;;
    4) uninstall_portainer ;;
  esac
else
  echo "Portainer is not installed. What would you like to do?"
  echo "1) Install"
  echo "0) Exit"
  choice="$(asknum 'Enter choice' 1 1 1)"
  case "$choice" in
    0) ok "Bye."; exit 0 ;;
    1) start_portainer ;;
  esac
fi
