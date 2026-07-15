#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/docker/brave-profile.sh?$(date +%s))"
# Purpose: Backup / restore the Brave (Kasm) profile for a standalone container.
# =============================================================================
# Why this exists:
#   The kasmweb/brave standalone container launches Brave MAXIMIZED only when it
#   uses its own in-container profile. Bind-mounting a host profile over
#   ~/.config/BraveSoftware/Brave-Browser breaks the xfce4 session ("failsafe
#   session" error) and/or restores a tiny, unmovable window. So instead of
#   persisting via a volume, we run the container with NO profile mount and
#   back up / restore the profile manually with this script.
#
#   RESTORE strips Brave's saved window geometry so it re-opens maximized.
#
# Usage:
#   brave-profile.sh            # interactive menu
#   brave-profile.sh backup     # non-interactive backup
#   brave-profile.sh restore    # non-interactive restore
#   brave-profile.sh status     # show backup + container state
# =============================================================================

set -euo pipefail

# --- Config (override via env) ----------------------------------------------
CONTAINER="${CONTAINER:-brave}"                                   # docker container name
PROFILE_PATH="${PROFILE_PATH:-/home/kasm-user/.config/BraveSoftware/Brave-Browser}"  # profile dir inside container
BACKUP_DIR="${BACKUP_DIR:-/mnt/sec/apps/brave/backup}"            # where the backup lives on the host
KASM_UID="${KASM_UID:-1000}"                                      # in-container owner UID
KASM_GID="${KASM_GID:-1000}"                                      # in-container owner GID

# --- Helpers ----------------------------------------------------------------
GREEN="\e[32m✔\e[0m"; RED="\e[31m✘\e[0m"; BLUE="\e[34mℹ\e[0m"; YEL="\e[33m!\e[0m"
ok(){   echo -e "${GREEN} $*"; }
info(){ echo -e "${BLUE} $*"; }
warn(){ echo -e "${YEL} $*"; }
fail(){ echo -e "${RED} $*"; exit 1; }

asknum(){ # asknum "prompt" min max default
  local p="$1" min="$2" max="$3" def="$4" in
  while true; do
    if [[ -r /dev/tty ]]; then
      read -rp "$p [$min-$max] (default: $def): " in </dev/tty || in="$def"
    else
      read -rp "$p [$min-$max] (default: $def): " in || in="$def"
    fi
    in="${in:-$def}"
    [[ "$in" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( in>=min && in<=max )) && { echo "$in"; return; }
  done
}

# --- Prechecks --------------------------------------------------------------
command -v docker >/dev/null || fail "Docker not found."

container_exists(){ docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; }
container_running(){ docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; }

# --- Backup -----------------------------------------------------------------
do_backup(){
  container_exists || fail "Container '${CONTAINER}' does not exist."

  # Verify the profile path exists inside the container
  if ! docker exec "$CONTAINER" test -d "$PROFILE_PATH" 2>/dev/null; then
    fail "Profile path '${PROFILE_PATH}' not found inside '${CONTAINER}'."
  fi

  info "Backing up profile from ${CONTAINER}:${PROFILE_PATH}"
  mkdir -p "$BACKUP_DIR"

  # Single backup: clear the target as root (via docker) so leftover
  # root-owned files like BrowserMetrics-spare.pma can't block the copy.
  docker run --rm -v "${BACKUP_DIR:?}:/b" busybox \
    sh -c 'rm -rf /b/* /b/.[!.]* /b/..?* 2>/dev/null' || true

  # Copy profile CONTENTS into BACKUP_DIR (trailing /. copies contents)
  docker cp "${CONTAINER}:${PROFILE_PATH}/." "${BACKUP_DIR}/" \
    || fail "docker cp (backup) failed."

  ok "Backup complete -> ${BACKUP_DIR}"
  local sz; sz=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
  info "Backup size: ${sz:-unknown}"
}

# --- Strip saved window geometry (so Brave reopens maximized) ---------------
strip_window_geometry(){
  # Edits Preferences (per-profile) and Local State (browser-level) in the
  # backup copy BEFORE pushing into the container. Safe if files are absent.
  command -v python3 >/dev/null || { warn "python3 not found; skipping geometry strip."; return 0; }

  python3 - "$BACKUP_DIR" <<'PY'
import json, os, sys
base = sys.argv[1]

def fix(path, keys_to_force_maximized=False):
    if not os.path.isfile(path):
        return
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        return
    b = d.get("browser", {})
    # Drop any saved placement, then force maximized
    b.pop("window_placement", None)
    b["window_placement"] = {"maximized": True, "left": 0, "top": 0}
    d["browser"] = b
    try:
        with open(path, "w") as f:
            json.dump(d, f)
    except Exception:
        pass

# Per-profile window state
fix(os.path.join(base, "Default", "Preferences"))
# Browser-level window state
fix(os.path.join(base, "Local State"))
print("window geometry stripped (forced maximized)")
PY
  ok "Window geometry stripped — Brave will reopen maximized."
}

# --- Restore ----------------------------------------------------------------
do_restore(){
  container_exists || fail "Container '${CONTAINER}' does not exist. Deploy it first, then restore."
  [[ -d "$BACKUP_DIR" ]] || fail "Backup directory not found: ${BACKUP_DIR}"
  # Must have at least something to restore
  [[ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]] || fail "Backup directory is empty: ${BACKUP_DIR}"

  info "Preparing restore into ${CONTAINER}:${PROFILE_PATH}"

  # Strip window geometry from the backup before pushing it in.
  strip_window_geometry

  # Stop the container so Brave isn't writing during the copy.
  local was_running=0
  if container_running; then
    was_running=1
    info "Stopping ${CONTAINER}..."
    docker stop "$CONTAINER" >/dev/null || fail "Failed to stop ${CONTAINER}."
  fi

  # Ensure the destination dir exists inside the container, then copy in.
  docker cp "${BACKUP_DIR}/." "${CONTAINER}:${PROFILE_PATH}/" \
    || fail "docker cp (restore) failed."

  # Fix ownership inside the container (runs as root via -u 0).
  docker start "$CONTAINER" >/dev/null || fail "Failed to start ${CONTAINER}."
  # Give it a moment to be ready for exec
  sleep 2
  docker exec -u 0 "$CONTAINER" chown -R "${KASM_UID}:${KASM_GID}" "$PROFILE_PATH" 2>/dev/null \
    && ok "Ownership set to ${KASM_UID}:${KASM_GID} inside container." \
    || warn "Could not chown inside container (may still work)."

  ok "Restore complete. Reload the Kasm session (Brave should be maximized)."
  [[ "$was_running" == "0" ]] && info "Note: container was not running before; it is now started."
}

# --- Status -----------------------------------------------------------------
do_status(){
  echo ""
  echo "  Brave Profile — Status"
  echo "  ----------------------"
  echo "  Container:     ${CONTAINER}  ($(container_running && echo running || (container_exists && echo stopped || echo 'not created')))"
  echo "  Profile path:  ${PROFILE_PATH}"
  echo "  Backup dir:    ${BACKUP_DIR}"
  if [[ -d "$BACKUP_DIR" && -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    local sz when
    sz=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    when=$(stat -c '%y' "$BACKUP_DIR" 2>/dev/null | cut -d. -f1)
    echo "  Backup:        present (${sz}, updated ${when})"
  else
    echo "  Backup:        none"
  fi
  echo ""
}

# --- CLI arg (non-interactive) ----------------------------------------------
arg="${1:-}"
case "$arg" in
  backup)  do_backup;  exit 0 ;;
  restore) do_restore; exit 0 ;;
  status)  do_status;  exit 0 ;;
  "" ) : ;;  # fall through to menu
  *) fail "Unknown action '$arg' (use: backup | restore | status)" ;;
esac

# --- Interactive menu -------------------------------------------------------
echo "================================================="
echo "  Brave Profile Backup/Restore — ${CONTAINER}"
echo "================================================="
echo "  1) Backup    (container profile -> ${BACKUP_DIR})"
echo "  2) Restore   (backup -> container, maximized)"
echo "  3) Status"
echo "  0) Exit"
choice="$(asknum 'Choose' 0 3 1)"
case "$choice" in
  0) ok "Bye."; exit 0 ;;
  1) do_backup ;;
  2) do_restore ;;
  3) do_status ;;
esac