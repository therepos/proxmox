#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-kasm.sh?$(date +%s))"
# Purpose: Install Kasm Workspaces (Ubuntu), with a watchdog that re-registers gateways whose token expired
# =============================================================================
# Usage:
#   setup-kasm                     Interactive menu
#   setup-kasm install|upgrade     Install, or update to KASM_VERSION
#   setup-kasm uninstall           Remove Kasm and the watchdog
#   setup-kasm guide               Login, getting started, persistent profiles
#   setup-kasm watchdog            Check the gateways once (what the watchdog timer runs)
#
# Stored on this machine (root only, mode 600):
#   /etc/setup-kasm/watchdog.env   Component Registration Token for the watchdog
#   /etc/homelab/mail.env          Alert email settings (shared with setup-backup.sh)
#
# Defaults:
#   Password                                                    (default: password)
#   KASM_VERSION             Target version, or "latest"        (default: latest)
#   KASM_SWAP_GB             Swap size in GB                    (default: 4)
#   KASM_PORT                Web UI port                        (default: 443)
#   SKIP_QEMU_AGENT          Set "true" to skip                 (default: false)
#   SKIP_PERSISTENT          Set "true" to skip dirs            (default: false)
#   KASM_REGISTRATION_TOKEN  Turn the watchdog on with it       (default: unset)
#
# Uninstall flags (opt-in; also prompted interactively):
#   REMOVE_DATA              Delete /data/kasm-profiles + -shared  (default: false)
#   REMOVE_SWAP              Remove the install swap file          (default: false)
#   FORCE                    Skip the uninstall confirmation       (default: false)
# =============================================================================

set -euo pipefail

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
# >>> menu
menu() {
  local o name desc i=1 w=0 pick
  { true </dev/tty; } 2>/dev/null || { warn "No terminal for the menu."; exit 0; }
  for o in "$@"; do name="${o%%|*}"; (( ${#name} > w )) && w=${#name}; done
  echo ""
  for o in "$@"; do
    name="${o%%|*}"; desc=""; [[ "$o" == *"|"* ]] && desc="${o#*|}"
    if [[ -n "$desc" ]]; then printf '  %d) %-*s  %s\n' "$i" "$w" "$name" "$desc"
    else printf '  %d) %s\n' "$i" "$name"; fi
    i=$((i + 1))
  done
  echo "  0) Exit"
  echo ""
  while true; do
    read -rp "  Choose [0-$#]: " pick </dev/tty || exit 0
    [[ "$pick" == "0" ]] && exit 0
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= $# )); then
      CHOICE="${!pick}"; CHOICE="${CHOICE%%|*}"; return 0
    fi
    warn "Choose a number from 0 to $#."
  done
}
# <<< menu

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
SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/setup-kasm.sh"
KASM_APP_DIR="${KASM_APP_DIR:-/opt/kasm/current/conf/app}"
WD_CONF_DIR="${WD_CONF_DIR:-/etc/setup-kasm}"
WD_CONF="$WD_CONF_DIR/watchdog.env"
WD_STATE_DIR="${WD_STATE_DIR:-/var/lib/setup-kasm}"
MAIL_CONF="${MAIL_CONF:-/etc/homelab/mail.env}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
WD_UNIT="setup-kasm-watchdog"
# <config folder under $KASM_APP_DIR>:<container> for each component the watchdog re-registers
WD_COMPONENTS=(rdp_gateway:kasm_rdp_gateway rdp_https_gateway:kasm_rdp_https_gateway)

# --- Input helpers -----------------------------------------------------------
have_tty(){ [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }
askv(){ # askv "  LABEL" [default] [e.g.] -> prompts "  LABEL (default: x) = "
  local l="$1" def="${2:-}" eg="${3:-}" in="" h=""
  have_tty || fail "No terminal to ask: $l"
  [[ -n "$eg" ]] && h="e.g. $eg"
  [[ -n "$def" ]] && h="${h:+$h, }default: $def"
  read -rp "$l${h:+ ($h)} = " in </dev/tty
  printf '%s' "${in:-$def}"
}
ask_secret(){ local in=""; have_tty || fail "No terminal to ask: $1"
  read -rsp "$1: " in </dev/tty; echo >/dev/tty; printf '%s' "$in"; }
write_env(){ # write_env file KEY=VALUE ...  (mode 600, values single-quoted)
  local f="$1" kv; shift
  mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")"
  ( umask 077; : >"$f.tmp"
    for kv in "$@"; do printf "%s='%s'\n" "${kv%%=*}" "$(printf '%s' "${kv#*=}" | sed "s/'/'\\\\''/g")" >>"$f.tmp"; done )
  mv "$f.tmp" "$f"; chmod 600 "$f"
}
# shellcheck disable=SC1090  # env file path is a runtime argument
load_env(){ [[ -f "$1" ]] && { set -a; . "$1"; set +a; }; return 0; }

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

# --- Alert email -------------------------------------------------------------
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
setup_mail(){
  local pw
  echo "Alert email (Enter = default):"
  SMTP_HOST="$(askv '  SMTP_HOST' "${SMTP_HOST:-smtp.zoho.com}")"
  SMTP_PORT="$(askv '  SMTP_PORT' "${SMTP_PORT:-587}")"
  SMTP_SECURITY="${SMTP_SECURITY:-starttls}"
  SMTP_USERNAME="$(askv '  SMTP_USERNAME' "${SMTP_USERNAME:-}" admin@example.com)"
  read -rsp "  SMTP_PASSWORD = " pw </dev/tty; echo >/dev/tty
  SMTP_PASSWORD="${pw:-${SMTP_PASSWORD:-}}"
  ALERT_TO="$(askv '  ALERT_TO' "${ALERT_TO:-$SMTP_USERNAME}")"
  export SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USERNAME SMTP_PASSWORD ALERT_TO
  write_env "$MAIL_CONF" "SMTP_HOST=$SMTP_HOST" "SMTP_PORT=$SMTP_PORT" "SMTP_SECURITY=$SMTP_SECURITY" \
    "SMTP_USERNAME=$SMTP_USERNAME" "SMTP_PASSWORD=$SMTP_PASSWORD" "ALERT_TO=$ALERT_TO"
  mail_test
}
mail_test(){
  if send_mail "[$(hostname)] Test alert" "Alert email from setup-kasm is working."; then ok "Test email sent to ${ALERT_TO}."
  else warn "Test email failed. Fix it with Token watchdog > Change alert email."; fi
}

# --- Token watchdog ----------------------------------------------------------
# Kasm components renew their own token; when that fails they loop on "JWT token has expired".
# Kasm reads registration_token.txt from the component's config folder, re-registers and deletes it.
wd_on(){ [[ -f "$UNIT_DIR/$WD_UNIT.timer" ]] && systemctl is-enabled "$WD_UNIT.timer" >/dev/null 2>&1; }
wd_state(){ if wd_on; then printf on; else printf off; fi; }
st_get(){ cat "$WD_STATE_DIR/$1" 2>/dev/null || true; }
st_set(){ mkdir -p "$WD_STATE_DIR"; printf '%s' "$2" >"$WD_STATE_DIR/$1"; }
st_del(){ rm -f "$WD_STATE_DIR/$1"; }

wd_alert(){ # wd_alert <container> <problem> <fix>; logs every time, emails at most once a day per container
  local now last
  warn "$1: $2"
  now="$(date +%s)"; last="$(st_get "mailed_$1")"
  [[ -n "$last" ]] && (( now - last < 86400 )) && return 0
  if send_mail "[$(hostname)] Kasm: $1 needs attention" "$2

Fix: $3
"; then st_set "mailed_$1" "$now"; else warn "Alert email not sent (not set up, or sending failed)."; fi
}

wd_check(){
  load_env "$WD_CONF"; load_env "$MAIL_CONF"
  [[ -n "${KASM_REGISTRATION_TOKEN:-}" ]] || fail "No token saved. Run setup-kasm and choose Token watchdog."
  command -v docker >/dev/null 2>&1 || fail "Docker not found."
  local now c dir ctr f placed since logs n base at fix
  now="$(date +%s)"
  fix="Copy the Component Registration Token from Kasm Admin > Settings > Global, run setup-kasm, choose Token watchdog > Change token."
  for c in "${WD_COMPONENTS[@]}"; do
    dir="$KASM_APP_DIR/${c%%:*}"; ctr="${c#*:}"; f="$dir/registration_token.txt"
    docker inspect "$ctr" >/dev/null 2>&1 || continue
    placed="$(st_get "placed_$ctr")"
    since=$(( now - 900 )); [[ -n "$placed" ]] && (( placed + 5 > since )) && since=$(( placed + 5 ))
    logs="$(docker logs --since "$since" "$ctr" 2>&1 | grep -iE 'registration|register_component|JWT' || true)"
    if grep -q 'registration successful' <<<"$logs"; then
      [[ -n "$placed" ]] && ok "$ctr re-registered."
      st_del "placed_$ctr"; st_del "mailed_$ctr"
    elif grep -qiE 'JWT token has expired|Expired JWT' <<<"$logs"; then
      [[ -f "$f" ]] && continue                      # placed, not read yet
      if [[ -n "$placed" ]] && (( now - placed < 3600 )); then
        wd_alert "$ctr" "Its token expired and re-registering with the saved token did not fix it." "$fix"
      elif [[ -d "$dir" ]]; then
        ( umask 077; printf '%s\n' "$KASM_REGISTRATION_TOKEN" >"$f" )
        chown --reference="$dir" "$f" 2>/dev/null || true
        st_set "placed_$ctr" "$now"
        ok "$ctr: token expired, gave it the saved registration token."
      else
        wd_alert "$ctr" "Its token expired and its config folder $dir is missing." "Reinstall or update Kasm with setup-kasm."
      fi
    elif grep -q 'Access Denied' <<<"$logs"; then
      wd_alert "$ctr" "Kasm rejected the saved registration token." "$fix"
    fi
  done
  # Any Kasm container restarting 10+ times in an hour is looping, whatever the cause
  while IFS= read -r ctr; do
    [[ -n "$ctr" ]] || continue
    n="$(docker inspect -f '{{.RestartCount}}' "$ctr" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || continue
    base="$(st_get "restarts_$ctr")"; at="$(st_get "restarts_at_$ctr")"
    if [[ -z "$base" || -z "$at" ]] || (( n < base )); then
      st_set "restarts_$ctr" "$n"; st_set "restarts_at_$ctr" "$now"
    elif (( now - at >= 3600 )); then
      (( n - base >= 10 )) && wd_alert "$ctr" "It restarted $(( n - base )) times in the last hour." \
        "See why with: docker logs --tail 50 $ctr"
      st_set "restarts_$ctr" "$n"; st_set "restarts_at_$ctr" "$now"
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^kasm_' || true)
  return 0
}

wd_save_token(){ # wd_save_token [token]; asks when not given; 1 when nothing was entered
  local tok="${1:-}"
  if [[ -z "$tok" ]]; then
    info "Kasm Admin > Settings > Global, under Authentication: Component Registration Token (unmask to copy)."
    tok="$(ask_secret 'Paste the Component Registration Token')"
  fi
  tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
  [[ -n "$tok" ]] || { warn "No token entered. Nothing changed."; return 1; }
  write_env "$WD_CONF" "KASM_REGISTRATION_TOKEN=$tok"
  ok "Token saved to $WD_CONF (root only)."
}

wd_enable(){
  cat >"$UNIT_DIR/$WD_UNIT.service" <<EOF
[Unit]
Description=Kasm token watchdog (setup-kasm)
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'src=\$\$(wget -qLO- "$SCRIPT_URL?\$\$(date +%%s)") || { echo "could not download setup-kasm.sh from GitHub"; exit 1; }; exec bash -c "\$\$src" setup-kasm watchdog'
EOF
  cat >"$UNIT_DIR/$WD_UNIT.timer" <<EOF
[Unit]
Description=Kasm token watchdog every 10 minutes
[Timer]
OnActiveSec=1min
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$WD_UNIT.timer" >/dev/null 2>&1
  ok "Watchdog on: checks every 10 minutes and fixes an expired gateway token by itself."
}
wd_disable(){
  systemctl disable --now "$WD_UNIT.timer" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$WD_UNIT.service" "$UNIT_DIR/$WD_UNIT.timer"
  systemctl daemon-reload 2>/dev/null || true
  ok "Watchdog off."
}

wd_turn_on(){
  wd_save_token || return 0
  load_env "$MAIL_CONF"
  if mail_ready; then ok "Alerts go to ${ALERT_TO} (settings shared with setup-backup)."
  else
    info "The watchdog emails you only when it cannot fix something itself."
    if askyn "Set up alert email now? (recommended)"; then setup_mail
    else info "No email: problems are only logged (journalctl -u $WD_UNIT)."; fi
  fi
  wd_enable
}

wd_menu(){ # returns 1 on Back
  banner "Token Watchdog"
  load_env "$MAIL_CONF"
  if wd_on; then
    ok "On: checks every 10 minutes, alerts $(mail_ready && printf 'to %s' "$ALERT_TO" || printf 'not emailed')"
    menu "Check now" "Change token|after you regenerate it in Kasm" "Change alert email" "Test email" "Turn off" "Back"
    case "$CHOICE" in
      "Check now")          wd_check ;;
      "Change token")       wd_save_token || true ;;
      "Change alert email") setup_mail ;;
      "Test email")         if mail_ready; then mail_test; else setup_mail; fi ;;
      "Turn off")           wd_disable ;;
      "Back")               return 1 ;;
    esac
  else
    info "Off"
    menu "Turn on|re-register the RDP gateways when their token expires" "Back"
    case "$CHOICE" in
      "Turn on") wd_turn_on ;;
      "Back")    return 1 ;;
    esac
  fi
}

# --- Uninstall ---------------------------------------------------------------
uninstall_kasm(){
  local HAVE_DOCKER=false
  command -v docker >/dev/null 2>&1 && HAVE_DOCKER=true

  # Optional removals: an explicit env flag wins; otherwise ask when interactive.
  local remove_data="${REMOVE_DATA:-false}"
  local remove_swap="${REMOVE_SWAP:-false}"

  if [[ "$FORCE" != "true" && -r /dev/tty ]]; then
    askyn "Uninstall Kasm? Removes all containers, images and /opt/kasm" \
      || { warn "Aborted. Nothing was changed."; return 0; }
    if [[ "$remove_data" != "true" ]] && { [[ -d /data/kasm-profiles ]] || [[ -d /data/kasm-shared ]]; }; then
      askyn "Also delete user data in /data/kasm-profiles and /data/kasm-shared?" && remove_data=true
    fi
    if [[ "$remove_swap" != "true" && -f "/mnt/${KASM_SWAP_GB}GiB.swap" ]]; then
      askyn "Also remove the swap file /mnt/${KASM_SWAP_GB}GiB.swap?" && remove_swap=true
    fi
  fi

  echo ""

  if [[ -f "$UNIT_DIR/$WD_UNIT.timer" || -d "$WD_CONF_DIR" ]]; then
    wd_disable
    rm -rf "$WD_CONF_DIR" "$WD_STATE_DIR"
    ok "Token watchdog removed (alert email settings kept: $MAIL_CONF)."
  fi

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

  banner "Uninstall Complete"
  echo ""
  echo "  Kasm Workspaces has been removed."
  [[ "$remove_data" != "true" && ( -d /data/kasm-profiles || -d /data/kasm-shared ) ]] && \
    echo "  User data was preserved under /data (see above)."
  if [[ "$HAVE_DOCKER" == "true" ]]; then
    echo "  Docker was left installed. To remove it too (only if nothing"
    echo "  else uses it): apt-get purge docker-ce docker-ce-cli containerd.io"
  fi
  echo ""
}

# --- Post-install guide ------------------------------------------------------
# Login credentials, getting-started steps and the persistent-profiles guide.
# Shown after a fresh install and on demand via the menu / `guide` argument.
show_guide(){
  local ip port
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; [[ -n "$ip" ]] || ip="<this-vm-ip>"
  port="$(docker port kasm_proxy 2>/dev/null | awk -F: 'NR==1{print $2}' || true)"
  [[ -n "$port" ]] || port="${KASM_PORT}"

  banner "Kasm UI Login Credentials"
  echo ""
  echo "  Web UI        https://${ip}:${port}"
  echo ""
  echo "  Admin login   admin@kasm.local"
  echo "  User login    user@kasm.local"
  echo "  Password      ${DEFAULT_PASS}   (default; change it if you haven't)"
  echo ""
  echo "  A self-signed certificate warning is expected."
  echo ""
  banner "Getting Started"
  echo ""
  echo "  1. Open https://${ip}:${port} in your browser."
  echo "     Accept the self-signed certificate warning."
  echo ""
  echo "  2. Log in as admin@kasm.local with password: ${DEFAULT_PASS}"
  echo ""
  echo "  3. CHANGE BOTH PASSWORDS IMMEDIATELY."
  echo "     Admin > Users > select user > edit > update password."
  echo ""
  banner "Persistent Profiles Setup Guide"
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
  banner "Token Watchdog"
  echo ""
  echo "  Kasm's RDP gateways renew their own login token. If that fails,"
  echo "  they restart every few minutes and RDP stops working."
  echo "  The watchdog (now: $(wd_state)) re-registers them with your saved"
  echo "  Component Registration Token and emails you if that does not work."
  echo ""
  echo "  Turn on    run this again and choose Token watchdog > Turn on"
  echo "  Token      Admin > Settings > Global, under Authentication"
  echo "  Test       Token watchdog > Check now"
  echo "  Log        journalctl -u ${WD_UNIT}"
  echo "  Undo       Token watchdog > Turn off"
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

# These actions never resolve a version / touch the network.
case "$ACTION" in
    uninstall)      uninstall_kasm; exit 0 ;;
    guide)          show_guide; exit 0 ;;
    watchdog)       wd_check; exit 0 ;;
    help|-h|--help) echo "Usage: setup-kasm.sh [install|upgrade|uninstall|guide|watchdog]"; exit 0 ;;
    install)        MODE="install" ;;
    upgrade)        MODE="upgrade" ;;
    "")             : ;;  # interactive / automated default handled below
    *)              fail "Unknown action '$ACTION' (try: install|upgrade|uninstall|guide|watchdog)" ;;
esac

# Interactive menu (only when a real terminal is present). Never auto-installs:
# a fresh box asks first. Non-interactive runs fall through to the default MODE.
main_menu(){
    banner "Kasm Workspaces"
    if [[ -d /opt/kasm/current ]]; then
        ok "Kasm ${EXISTING_VERSION:-unknown} installed, token watchdog $(wd_state)"
        menu "Update|to the latest version" \
             "Token watchdog|re-registers the RDP gateways when their token expires" \
             "Guide|login, getting started, persistent profiles" "Uninstall"
        case "$CHOICE" in
            "Update")         MODE="upgrade" ;;
            "Token watchdog") if wd_menu; then exit 0; else main_menu; fi ;;
            "Guide")          show_guide; exit 0 ;;
            "Uninstall")      uninstall_kasm; exit 0 ;;
        esac
    else
        info "Not installed"
        menu "Install|the latest version" "Guide|login, getting started, persistent profiles"
        case "$CHOICE" in
            "Install") MODE="install" ;;
            "Guide")   show_guide; exit 0 ;;
        esac
    fi
}
if [[ -z "$ACTION" ]] && have_tty; then main_menu; fi

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

# --- Token watchdog ----------------------------------------------------------
if [[ -n "${KASM_REGISTRATION_TOKEN:-}" ]]; then
    wd_save_token "$KASM_REGISTRATION_TOKEN" && wd_enable
elif ! wd_on; then
    info "Tip: run this again and choose Token watchdog, so an expired gateway token fixes itself."
fi

# --- Summary -----------------------------------------------------------------
echo ""
if [[ "$MODE" == "upgrade" ]]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    banner "Upgrade Complete"
    echo ""
    echo "  ${EXISTING_VERSION} -> ${KASM_VERSION}"
    echo "  Web UI        https://${SERVER_IP}:${KASM_PORT}"
    echo "  Backup        ${BACKUP_FILE}"
    echo ""
    echo "  Log in with your existing credentials."
    echo "  Check the Workspace Registry for updated images."
    echo ""
    echo "  Tip: re-run this script and choose 'Guide' to see setup info."
    echo ""
else
    banner "Install Complete"
    show_guide
fi
