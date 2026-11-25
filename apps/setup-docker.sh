#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-docker.sh?$(date +%s))"
# Purpose: Installs docker engine and docker compose (Ubuntu/PVE9), with a restart-loop alert
# =============================================================================
# Usage:
#   setup-docker                   Install Docker (skipped when present) and the restart watchdog
#   setup-docker watchdog          Check containers once (what the watchdog timer runs)
#   setup-docker watchdog-off      Turn the restart watchdog off
# =============================================================================

set -euo pipefail

ACTION="${1:-install}"; [[ "$ACTION" == -y || "$ACTION" == --yes ]] && ACTION=install
SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/setup-docker.sh"
MAIL_CONF="${MAIL_CONF:-/etc/homelab/mail.env}"
WD_STATE_DIR="${WD_STATE_DIR:-/var/lib/setup-docker}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
WD_UNIT="setup-docker-watchdog"

if [[ "$ACTION" == install ]]; then
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/dockerhost-install-$(date +%F).log"
mkdir -p "$LOG_DIR"; : >"$LOG_FILE"; chmod 0644 "$LOG_FILE"
[[ -t 1 ]] && export FORCE_COLOR=1
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
trap 'err "Error on line $LINENO"' ERR
fi

# --- Helpers -----------------------------------------------------------------
# >>> admonition
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
banner() { local l='================================================='; printf '\n%s\n  %s\n%s\n' "$l" "$*" "$l"; }
# Status line: value red when missing/failed, yellow while starting, green when OK.
row() {
  local c=''
  case "${2,,}" in
    not|*"not "*|*not-*|*missing*|*fail*|*error*|*inactive*|*disconnected*) c="$_CE" ;;
    *activating*|*reconnecting*|*starting*) c="$_CW" ;;
    *installed*|*active*|*connected*|*"logged in"*|*running*|*enabled*|*mounted*|*loaded*) c="$_CK" ;;
  esac
  printf '  %-16s%s%s%s\n' "$1" "$c" "$2" "${c:+$_C0}"
}
# <<< admonition

# Back-compat aliases used within this script:
log() { ok "$@"; }
err() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; }   # print-only (no exit)

# --- Prerequisites -----------------------------------------------------------
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

# --- Install -----------------------------------------------------------------
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

# --- Restart watchdog --------------------------------------------------------
# Emails when a container crash-loops (10+ restarts in an hour), e.g. a database that cannot start.
# shellcheck disable=SC1090  # env file path is a runtime argument
load_env(){ [[ -f "$1" ]] && { set -a; . "$1"; set +a; }; return 0; }
mail_ready(){ [[ -n "${SMTP_HOST:-}" && -n "${SMTP_PASSWORD:-}" && -n "${ALERT_TO:-}" ]]; }
send_mail(){ # send_mail subject body; returns 1 when email is not set up or sending fails
  mail_ready || return 1
  SUBJECT="$1" BODY="$2" python3 - <<'PY'
import os, smtplib
from email.message import EmailMessage
E = os.environ
m = EmailMessage(); m["Subject"] = E["SUBJECT"]; m["From"] = E.get("SMTP_FROM") or E["SMTP_USERNAME"]; m["To"] = E["ALERT_TO"]
m.set_content(E["BODY"])
port = int(E.get("SMTP_PORT") or 587); sec = E.get("SMTP_SECURITY") or "starttls"
if sec == "force_tls" or port == 465:
    s = smtplib.SMTP_SSL(E["SMTP_HOST"], port, timeout=30)
else:
    s = smtplib.SMTP(E["SMTP_HOST"], port, timeout=30)
    if sec != "off": s.starttls()
with s:
    s.login(E["SMTP_USERNAME"], E["SMTP_PASSWORD"]); s.send_message(m)
PY
}
st_get(){ cat "$WD_STATE_DIR/$1" 2>/dev/null || true; }
st_set(){ mkdir -p "$WD_STATE_DIR"; printf '%s' "$2" >"$WD_STATE_DIR/$1"; }

wd_check(){
  command -v docker >/dev/null 2>&1 || fail "Docker not found."
  load_env "$MAIL_CONF"
  local now ctr n base at last logs
  now="$(date +%s)"
  while IFS= read -r ctr; do
    [[ -n "$ctr" ]] || continue
    n="$(docker inspect -f '{{.RestartCount}}' "$ctr" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || continue
    base="$(st_get "restarts_$ctr")"; at="$(st_get "restarts_at_$ctr")"
    if [[ -z "$base" || -z "$at" ]] || (( n < base )); then
      st_set "restarts_$ctr" "$n"; st_set "restarts_at_$ctr" "$now"; continue
    fi
    (( now - at >= 3600 )) || continue
    st_set "restarts_$ctr" "$n"; st_set "restarts_at_$ctr" "$now"
    (( n - base >= 10 )) || continue
    warn "$ctr restarted $(( n - base )) times in the last hour."
    last="$(st_get "mailed_$ctr")"
    [[ -n "$last" ]] && (( now - last < 86400 )) && continue
    logs="$(docker logs --tail 15 "$ctr" 2>&1 | cut -c1-200 || true)"
    if send_mail "[$(hostname)] $ctr keeps restarting" "$ctr restarted $(( n - base )) times in the last hour, so it is crash-looping and keeps the server busy.

Last log lines:
$logs

See more: docker logs --tail 50 $ctr
This email repeats at most once a day per container."; then st_set "mailed_$ctr" "$now"
    else warn "Alert email not sent (set up in setup-backup or setup-kasm, or sending failed)."; fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
  return 0
}

wd_on(){ [[ -f "$UNIT_DIR/$WD_UNIT.timer" ]] && systemctl is-enabled "$WD_UNIT.timer" >/dev/null 2>&1; }
wd_enable(){
  if wd_on; then ok "Restart watchdog already on."; return 0; fi
  cat >"$UNIT_DIR/$WD_UNIT.service" <<EOF
[Unit]
Description=Container restart-loop alert (setup-docker)
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'src=\$\$(wget -qLO- "$SCRIPT_URL?\$\$(date +%%s)") || { echo "could not download setup-docker.sh from GitHub"; exit 1; }; exec bash -c "\$\$src" setup-docker watchdog'
EOF
  cat >"$UNIT_DIR/$WD_UNIT.timer" <<EOF
[Unit]
Description=Container restart-loop alert every 10 minutes
[Timer]
OnActiveSec=1min
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$WD_UNIT.timer" >/dev/null 2>&1
  ok "Restart watchdog on: emails when a container restarts 10+ times in an hour."
  load_env "$MAIL_CONF"
  mail_ready || info "No alert email set up yet: alerts only go to journalctl -u $WD_UNIT (email is set up in setup-backup or setup-kasm)."
}
wd_disable(){
  systemctl disable --now "$WD_UNIT.timer" >/dev/null 2>&1 || true
  rm -f "${UNIT_DIR:?}/${WD_UNIT:?}.service" "${UNIT_DIR:?}/${WD_UNIT:?}.timer"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "${WD_STATE_DIR:?}"
  ok "Restart watchdog off."
}

main() {
  require_root
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version | cut -d, -f1)"
  else
    detect_os
    apt_prep
    install_repo
    install_docker
    verify
  fi
  wd_enable
  echo "Log saved to: $LOG_FILE"
  log "All done"
}

case "$ACTION" in
  install)      main ;;
  watchdog)     [[ $EUID -eq 0 ]] || fail "Run as root."; wd_check ;;
  watchdog-off) [[ $EUID -eq 0 ]] || fail "Run as root."; wd_disable ;;
  *)            fail "Unknown action '$ACTION' (try: install|watchdog|watchdog-off)" ;;
esac
