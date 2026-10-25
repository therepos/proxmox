#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/claude-setup.sh?$(date +%s))"
# Purpose: Installs Claude Code with Remote Control as a boot service, plus optional Claude Desktop in the browser via KasmVNC (Ubuntu VM)
# =============================================================================
# Usage:
#   Run inside the Ubuntu VM (not the PVE host), as root or via sudo, from a
#   console where you can type (Proxmox console or SSH). Menu:
#     1) Install      Claude Code + tmux + one-time login + boot service
#     2) Status       service, version, working folder
#     3) Update       update Claude Code and restart the service
#     4) Static IP    pin the VM's LAN address (netplan, auto-reverts if broken)
#     5) Desktop      Claude Desktop on XFCE, streamed to any browser by KasmVNC,
#                     so the app's Chat can use folders on this VM from anywhere
#     6) Uninstall    remove the service, the desktop (optionally Claude Code)
#   Args skip the menu: install | status | update | ip | desktop | uninstall
#
#   After install: Claude app -> Code tab -> tap this VM under Devices.
#   Watch the live session:   tmux attach -t claude   (detach: Ctrl+B then D)
#   After Desktop: open https://<host-ip>:8444, sign in to the app, then
#   project -> Add folder -> the working folder. claude-rc keeps running alongside.
#
# Config (env): CLAUDE_USER, CLAUDE_WORKDIR, CLAUDE_RC_NAME, CLAUDE_DESKTOP_PORT
# =============================================================================

set -euo pipefail

# --- Variables ---------------------------------------------------------------
SERVICE_NAME="claude-rc"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONF_FILE="/etc/claude-rc.conf"
TMUX_SESSION="claude"
DEFAULT_WORKDIR="/mnt/sec/media/shared"
INSTALL_URL="https://claude.ai/install.sh"
# Desktop bridge (Claude Desktop for Linux, Anthropic apt repo)
DESKTOP_KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
DESKTOP_KEY_FILE="/usr/share/keyrings/claude-desktop-archive-keyring.asc"
DESKTOP_KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
DESKTOP_REPO_FILE="/etc/apt/sources.list.d/claude-desktop.list"
DESKTOP_REPO_LINE="deb [arch=amd64,arm64 signed-by=${DESKTOP_KEY_FILE}] https://downloads.claude.ai/claude-desktop/apt/stable stable main"
DESKTOP_SERVICE="claude-desktop"
DESKTOP_SERVICE_FILE="/etc/systemd/system/${DESKTOP_SERVICE}.service"
DESKTOP_DISPLAY=":1"
DESKTOP_PORT="${CLAUDE_DESKTOP_PORT:-8444}"
AUTOLOGIN_FILE="/etc/lightdm/lightdm.conf.d/50-autologin.conf"   # older versions only
SLEEP_TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"
DESKTOP_PKGS="xfce4 xfce4-terminal dbus-x11 gnome-keyring ssl-cert"

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

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
[[ -d /etc/pve ]] && fail "This is the Proxmox host. Run this inside the Ubuntu VM instead."
[[ -r /dev/tty ]] || fail "No terminal available. Run from the VM console or SSH."

# ask "Prompt" "default" -> echoes the answer (default when empty)
ask() {
    local p="$1" def="${2:-}" in
    if [[ -n "$def" ]]; then
        read -rp "  $p [$def]: " in </dev/tty || in=""
    else
        read -rp "  $p: " in </dev/tty || in=""
    fi
    echo "${in:-$def}"
}

# confirm "Question" "Y|N" -> 0 for yes
confirm() {
    local q="$1" def="${2:-N}" in hint="[y/N]"
    [[ "$def" == "Y" ]] && hint="[Y/n]"
    read -rp "  $q $hint: " in </dev/tty || in=""
    in="${in:-$def}"
    [[ "$in" =~ ^[Yy]$ ]]
}

# Load settings so status/update/uninstall reuse them. Order: the saved config
# (written by Install), else values read back from an existing service file
# (a setup done by hand), else nothing. SETTINGS_SRC records which one won.
load_conf() {
    SETTINGS_SRC="none"
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
        SETTINGS_SRC="$CONF_FILE"
    elif [[ -f "$SERVICE_FILE" ]]; then
        CLAUDE_USER="$(awk -F= '/^User=/{print $2; exit}' "$SERVICE_FILE")"
        CLAUDE_WORKDIR="$(awk -F= '/^WorkingDirectory=/{print $2; exit}' "$SERVICE_FILE")"
        CLAUDE_RC_NAME="$(grep -o -- '--name [^ '\'']*' "$SERVICE_FILE" | head -1 | cut -d' ' -f2)"
        SETTINGS_SRC="existing service (no ${CONF_FILE})"
    fi
    return 0
}

# Remote Control state, read from the live tmux screen of the service.
# Echoes: connected | not-connected | not-running
rc_state() {
    local u="$1" pane last
    as_user "$u" tmux has-session -t "$TMUX_SESSION" 2>/dev/null || { echo "not-running"; return; }
    pane="$(as_user "$u" tmux capture-pane -p -t "$TMUX_SESSION" -S -300 2>/dev/null || true)"
    last="$(grep -iE 'connected|reconnecting|failed|error|log ?in' <<<"$pane" | tail -1)"
    if grep -qiE '(^|[^a-z])connected' <<<"$last" && ! grep -qiE 'not connected|disconnected|failed' <<<"$last"; then
        echo "connected"
    else
        echo "not-connected"
    fi
}

user_home()  { getent passwd "$1" | cut -d: -f6; }
claude_bin() { echo "$(user_home "$1")/.local/bin/claude"; }

# Run a command as the target user with their HOME and PATH.
as_user() {
    local u="$1"; shift
    sudo -H -u "$u" env PATH="$(user_home "$u")/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

# --- Settings ----------------------------------------------------------------
pick_settings() {
    load_conf
    local def_user="${CLAUDE_USER:-${SUDO_USER:-}}"
    [[ -z "$def_user" || "$def_user" == "root" ]] && \
        def_user="$(getent passwd 1000 | cut -d: -f1)"

    echo ""
    info "Claude runs as a normal user (not root). It works inside one folder."
    CLAUDE_USER="$(ask "Run as user" "$def_user")"
    id "$CLAUDE_USER" &>/dev/null || fail "User '$CLAUDE_USER' does not exist."
    [[ "$CLAUDE_USER" != "root" ]] || fail "Pick a normal user, not root."

    CLAUDE_WORKDIR="$(ask "Working folder" "${CLAUDE_WORKDIR:-$DEFAULT_WORKDIR}")"
    [[ -d "$CLAUDE_WORKDIR" ]] || fail "Folder '$CLAUDE_WORKDIR' not found. Mount the share first (virtiofs-setup.sh)."
    as_user "$CLAUDE_USER" test -w "$CLAUDE_WORKDIR" || \
        warn "User '$CLAUDE_USER' cannot write to $CLAUDE_WORKDIR. Claude will be read-only there."

    CLAUDE_RC_NAME="$(ask "Session name shown in the Claude app" "${CLAUDE_RC_NAME:-Server}")"
    [[ "$CLAUDE_RC_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Use letters, digits, dot, dash or underscore only."

    cat > "$CONF_FILE" <<EOF
CLAUDE_USER="${CLAUDE_USER}"
CLAUDE_WORKDIR="${CLAUDE_WORKDIR}"
CLAUDE_RC_NAME="${CLAUDE_RC_NAME}"
EOF
    chmod 644 "$CONF_FILE"
    ok "Settings saved to ${CONF_FILE}."
}

# --- Install -----------------------------------------------------------------
install_packages() {
    info "Installing tmux and curl..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq tmux curl >/dev/null
    ok "tmux and curl installed."
}

install_claude() {
    local bin; bin="$(claude_bin "$CLAUDE_USER")"
    if [[ -x "$bin" ]]; then
        ok "Claude Code already installed ($(as_user "$CLAUDE_USER" "$bin" --version 2>/dev/null | head -1))."
        return 0
    fi
    info "Installing Claude Code for '${CLAUDE_USER}' (no progress shown, please wait)..."
    as_user "$CLAUDE_USER" bash -c "curl -fsSL ${INSTALL_URL} | bash" >/dev/null 2>&1 \
        || fail "Claude Code install failed. Check internet access from the VM."
    [[ -x "$bin" ]] || fail "Install finished but $bin is missing."
    ok "Claude Code installed ($(as_user "$CLAUDE_USER" "$bin" --version 2>/dev/null | head -1))."
}

# Login and the two one-time questions (trust folder, enable Remote Control)
# need a human, so this step runs Remote Control once in the foreground.
first_run() {
    local bin home; bin="$(claude_bin "$CLAUDE_USER")"; home="$(user_home "$CLAUDE_USER")"

    if [[ -f "${home}/.claude/.credentials.json" ]] && \
       ! confirm "Already logged in. Log in again?" "N"; then
        ok "Using the existing login."
    else
        echo ""
        info "Log in with your Claude account (Pro/Max). Choose the claude.ai option."
        info "The VM has no browser: open the link it shows on your phone or laptop,"
        info "sign in, then paste the code back here."
        echo ""
        as_user "$CLAUDE_USER" "$bin" auth login </dev/tty || fail "Login failed. Re-run Install to try again."
        ok "Logged in."
    fi

    echo ""
    info "One-time check: Remote Control starts in the foreground now."
    info "  - If asked 'Trust ${CLAUDE_WORKDIR}?' answer y"
    info "  - If asked 'Enable Remote Control?' answer y"
    info "  - When it shows 'Connected', press Ctrl+C. Setup then continues."
    echo ""
    confirm "Ready?" "Y" || fail "Cancelled."

    # Let Ctrl+C stop only the child, not this script.
    trap ':' INT
    (cd "$CLAUDE_WORKDIR" && as_user "$CLAUDE_USER" "$bin" remote-control --name "$CLAUDE_RC_NAME" </dev/tty) || true
    trap - INT
    echo ""
    ok "One-time check done."
}

write_service() {
    local home tmux_bin; home="$(user_home "$CLAUDE_USER")"
    tmux_bin="$(command -v tmux)" || fail "tmux not found."

    # Wait for the shared folder only if it lives on a separate mount.
    local mount_dep=""
    local mnt; mnt="$(findmnt -n -o TARGET --target "$CLAUDE_WORKDIR" 2>/dev/null || true)"
    [[ -n "$mnt" && "$mnt" != "/" ]] && mount_dep="RequiresMountsFor=${mnt}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Claude Code Remote Control
After=network-online.target
Wants=network-online.target
${mount_dep}

[Service]
Type=forking
User=${CLAUDE_USER}
Environment=HOME=${home}
Environment=PATH=${home}/.local/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=${CLAUDE_WORKDIR}
ExecStart=${tmux_bin} new-session -d -s ${TMUX_SESSION} -c ${CLAUDE_WORKDIR} 'claude remote-control --name ${CLAUDE_RC_NAME}'
ExecStop=${tmux_bin} kill-session -t ${TMUX_SESSION}
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    # A leftover manual session would block the service from starting.
    as_user "$CLAUDE_USER" "$tmux_bin" kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 5
    systemctl is-active --quiet "$SERVICE_NAME" \
        || fail "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 50"
    ok "Boot service '${SERVICE_NAME}' enabled and running."
}

do_install() {
    echo ""
    echo "Claude Code - Install"
    echo "================================================="
    pick_settings
    install_packages
    install_claude
    first_run
    write_service
    print_done
}

print_done() {
    echo ""
    echo "Install Complete"
    echo "================================================="
    echo ""
    echo "  Use it        Claude app -> Code tab -> tap '$(hostname)' under Devices"
    echo "                or https://claude.ai/code in any browser"
    echo "  Folder        ${CLAUDE_WORKDIR}"
    echo "  Live view     sudo -u ${CLAUDE_USER} tmux attach -t ${TMUX_SESSION}"
    echo "                (detach with Ctrl+B then D, never Ctrl+C)"
    echo "  Restart       sudo systemctl restart ${SERVICE_NAME}"
    echo ""
    echo "  Starts automatically on every boot."
    echo ""
}

# --- Status ------------------------------------------------------------------
do_status() {
    load_conf
    # No saved settings and no service: still check the usual user for an install.
    local u="${CLAUDE_USER:-}"
    if [[ -z "$u" ]]; then
        u="${SUDO_USER:-}"
        [[ -z "$u" || "$u" == "root" ]] && u="$(getent passwd 1000 | cut -d: -f1)"
    fi

    local bin="" ver="not installed" login="-" svc rc rc_txt tmux_txt
    if [[ -n "$u" ]]; then
        bin="$(claude_bin "$u")"
        if [[ -x "$bin" ]]; then
            ver="installed ($(as_user "$u" "$bin" --version 2>/dev/null | awk '{print $1; exit}'))  ${bin}"
            [[ -f "$(user_home "$u")/.claude/.credentials.json" ]] && login="logged in" || login="NOT logged in"
        fi
    fi
    tmux_txt="$(command -v tmux >/dev/null && echo installed || echo 'not installed')"

    if [[ -f "$SERVICE_FILE" ]]; then
        local act ena
        act="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
        ena="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
        svc="${SERVICE_NAME}  ${act:-unknown} / ${ena:-unknown}"
        [[ "$ena" == "enabled" ]] && svc+=" (starts on boot)"
    else
        svc="not set up"
    fi

    rc="$( [[ -n "$u" ]] && command -v tmux >/dev/null && rc_state "$u" || echo not-running )"
    case "$rc" in
        connected)     rc_txt="Connected  (name: ${CLAUDE_RC_NAME:-?})" ;;
        not-connected) rc_txt="Running, NOT connected  -> attach to see why, or re-run Install to log in" ;;
        *)             rc_txt="Not running" ;;
    esac

    echo ""
    echo "================================================="
    echo "  Status"
    echo "================================================="
    echo "  Claude Code     ${ver}"
    echo "  Login           ${login}"
    echo "  tmux            ${tmux_txt}"
    echo "  Service         ${svc}"
    echo "  Remote Control  ${rc_txt}"
    echo "  Desktop         $(desktop_state "$u")"
    echo "  User            ${u:--}"
    echo "  Folder          ${CLAUDE_WORKDIR:--}"
    echo "  LAN IP          $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "  Settings        ${SETTINGS_SRC}"
    echo "================================================="
    echo ""
}

# --- Update ------------------------------------------------------------------
do_update() {
    load_conf
    [[ -n "${CLAUDE_USER:-}" ]] || fail "Not installed. Run Install first."
    local bin; bin="$(claude_bin "$CLAUDE_USER")"
    [[ -x "$bin" ]] || fail "Claude Code not found at $bin."
    info "Updating Claude Code..."
    as_user "$CLAUDE_USER" "$bin" update || warn "Update command reported an error."
    systemctl restart "$SERVICE_NAME"
    ok "Updated to $(as_user "$CLAUDE_USER" "$bin" --version 2>/dev/null | head -1). Service restarted."
    if [[ -n "$(pkg_ver claude-desktop)" ]]; then
        info "Updating Claude Desktop..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade claude-desktop >/dev/null \
            || warn "Claude Desktop update failed."
        ok "Claude Desktop $(pkg_ver claude-desktop). Restart the app (or reboot) to use it."
    fi
}

# --- Static IP ---------------------------------------------------------------
# Pins the VM's LAN address so tunnel routes survive reboots. Uses 'netplan try',
# which reverts automatically if you do not confirm within 120 seconds.
do_static_ip() {
    command -v netplan >/dev/null || fail "netplan not found (not Ubuntu?)."
    local iface cur_cidr cur_ip prefix gw mac new_ip dns
    iface="$(ip route show default | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || fail "No default route found."
    cur_cidr="$(ip -4 -o addr show dev "$iface" | awk '{print $4; exit}')"
    cur_ip="${cur_cidr%/*}"; prefix="${cur_cidr#*/}"
    gw="$(ip route show default | awk '{print $3; exit}')"
    mac="$(cat "/sys/class/net/${iface}/address")"

    echo ""
    echo "Static IP"
    echo "================================================="
    warn "Run this from the Proxmox console, not SSH/Webmin: the connection drops when the IP changes."
    echo "  Interface  ${iface}"
    echo "  Current    ${cur_cidr}  (gateway ${gw})"
    echo ""
    info "Pick a high address (e.g. .200-.250) the router is unlikely to hand out."
    new_ip="$(ask "Static IP" "$cur_ip")"
    [[ "$new_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Invalid IP address."
    prefix="$(ask "Prefix length" "$prefix")"
    gw="$(ask "Gateway" "$gw")"
    dns="$(ask "DNS servers (comma separated)" "${gw}, 1.1.1.1")"

    if [[ "$new_ip" != "$cur_ip" ]] && ping -c 2 -W 1 "$new_ip" >/dev/null 2>&1; then
        fail "${new_ip} already answers ping. Another device is using it; pick another."
    fi

    confirm "Apply ${new_ip}/${prefix} via ${gw} on ${iface}?" "N" || { info "Cancelled."; return 0; }

    local bak
    bak="/root/netplan-backup-$(date +%F-%H%M%S)"
    mkdir -p "$bak"
    cp -a /etc/netplan/. "$bak/"
    ok "Backed up /etc/netplan to ${bak}."

    # Stop cloud-init from regenerating network config on boot.
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi

    find /etc/netplan -maxdepth 1 -name '*.yaml' -delete
    cat > /etc/netplan/01-static.yaml <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      match:
        macaddress: ${mac}
      set-name: ${iface}
      dhcp4: false
      dhcp6: true
      addresses: [${new_ip}/${prefix}]
      routes:
        - to: default
          via: ${gw}
      nameservers:
        addresses: [${dns}]
EOF
    chmod 600 /etc/netplan/01-static.yaml

    echo ""
    info "From another device run:  ping ${new_ip}"
    info "If it replies, press ENTER below to keep it. Otherwise wait and it reverts."
    echo ""
    netplan try --timeout 120 </dev/tty || true

    if ip -4 -o addr show dev "$iface" | grep -q " ${new_ip}/"; then
        ok "Static IP ${new_ip} active and saved."
        info "Update any Cloudflare tunnel routes that used the old IP (refresh the page between edits)."
    else
        warn "New IP not active; restoring previous netplan files."
        find /etc/netplan -maxdepth 1 -name '*.yaml' -delete
        cp -a "$bak/." /etc/netplan/
        netplan apply || true
        fail "Reverted. Nothing changed."
    fi
}

# --- Desktop (Claude Desktop in the browser) ---------------------------------
# Claude Desktop is a GUI app. KasmVNC runs a lean XFCE desktop as a boot
# service and streams it to any browser (same tech as the kasmweb/brave
# container), so the app's Chat, with folders on this VM, is reachable remotely.
pkg_ver()        { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
autostart_file() { echo "$(user_home "$1")/.config/autostart/claude-desktop.desktop"; }
noblank_file()   { echo "$(user_home "$1")/.config/autostart/no-blank.desktop"; }

# One-line summary for Status.
desktop_state() {
    local u="$1" ver svc masked=0 t
    ver="$(pkg_ver claude-desktop)"
    [[ -n "$ver" ]] || { echo "not installed"; return; }
    svc="$(systemctl is-active "$DESKTOP_SERVICE" 2>/dev/null || true)"
    for t in $SLEEP_TARGETS; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null || true)" == "masked" ]] && masked=$((masked + 1))
    done
    echo "app ${ver}, ${DESKTOP_SERVICE} ${svc:-inactive}, https://$(hostname -I 2>/dev/null | awk '{print $1}'):${DESKTOP_PORT}, sleep ${masked}/4 masked"
}

# Earlier versions used LightDM auto-login on the console. KasmVNC replaces it;
# two sessions would start two copies of the app.
remove_autologin() {
    [[ -f "$AUTOLOGIN_FILE" ]] || systemctl is-enabled --quiet lightdm 2>/dev/null || return 0
    info "Switching off the console auto-login (KasmVNC replaces it)..."
    rm -f "$AUTOLOGIN_FILE"
    systemctl disable --now lightdm >/dev/null 2>&1 || true
    systemctl set-default multi-user.target >/dev/null
    ok "Console auto-login removed."
}

install_kasmvnc() {
    if [[ -n "$(pkg_ver kasmvncserver)" ]]; then
        ok "KasmVNC already installed ($(pkg_ver kasmvncserver))."
        return 0
    fi
    local codename arch url tmp
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    arch="$(dpkg --print-architecture)"
    info "Finding the KasmVNC package for ${codename} (${arch})..."
    local assets
    assets="$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*\.deb"' | cut -d'"' -f4)" \
        || fail "Cannot reach GitHub to find KasmVNC."
    url="$(grep "/kasmvncserver_[a-z]*_${codename}_[^/]*_${arch}\.deb$" <<<"$assets" | head -1 || true)"
    if [[ -z "$url" ]]; then
        url="$(grep "/kasmvncserver_ubuntu_noble_[^/]*_${arch}\.deb$" <<<"$assets" | head -1 || true)"
        [[ -n "$url" ]] || fail "No KasmVNC package for ${codename}/${arch}."
        warn "No KasmVNC build for ${codename}; using the Ubuntu 24.04 (noble) one."
    fi
    tmp="$(mktemp -d)"
    curl -fsSLo "${tmp}/${url##*/}" "$url" || fail "KasmVNC download failed."
    apt-get install -y -qq "${tmp}/${url##*/}" >/dev/null || fail "KasmVNC install failed."
    rm -rf "$tmp"
    ok "KasmVNC $(pkg_ver kasmvncserver) installed."
}

# Browser login for KasmVNC: username = the Linux user, password asked here.
set_kasm_password() {
    local home pw pw2; home="$(user_home "$CLAUDE_USER")"
    if [[ -f "${home}/.kasmpasswd" ]] && ! confirm "Browser login already set. Change the password?" "N"; then
        return 0
    fi
    while true; do
        read -rsp "  Browser login password for '${CLAUDE_USER}' (min 6 chars): " pw </dev/tty; echo ""
        read -rsp "  Repeat: " pw2 </dev/tty; echo ""
        [[ "$pw" == "$pw2" && ${#pw} -ge 6 ]] && break
        warn "Passwords differ or are too short. Try again."
    done
    printf '%s\n%s\n' "$pw" "$pw" | as_user "$CLAUDE_USER" kasmvncpasswd -u "$CLAUDE_USER" -wo "${home}/.kasmpasswd" >/dev/null \
        || fail "Could not set the browser login."
    chmod 600 "${home}/.kasmpasswd"
    ok "Browser login set (user '${CLAUDE_USER}')."
}

write_kasm_config() {
    local home; home="$(user_home "$CLAUDE_USER")"
    mkdir -p "${home}/.vnc"
    cat > "${home}/.vnc/kasmvnc.yaml" <<EOF
network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: ${DESKTOP_PORT}
  ssl:
    require_ssl: true
desktop:
  resolution:
    width: 1920
    height: 1080
  allow_resize: true
encoding:
  max_frame_rate: 60
  rect_encoding_mode:
    min_quality: 5
    max_quality: 6
  video_encoding_mode:
    enter_video_encoding_mode:
      area_threshold: 100%
  scrolling:
    detect_vertical_scrolling: true
EOF
    cat > "${home}/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
EOF
    chmod 755 "${home}/.vnc/xstartup"
    touch "${home}/.vnc/.de-was-selected"
    chown -R "$CLAUDE_USER:" "${home}/.vnc"

    local mount_dep="" mnt
    mnt="$(findmnt -n -o TARGET --target "$CLAUDE_WORKDIR" 2>/dev/null || true)"
    [[ -n "$mnt" && "$mnt" != "/" ]] && mount_dep="RequiresMountsFor=${mnt}"

    cat > "$DESKTOP_SERVICE_FILE" <<EOF
[Unit]
Description=Claude Desktop in the browser (KasmVNC)
After=network-online.target
Wants=network-online.target
${mount_dep}

[Service]
Type=forking
User=${CLAUDE_USER}
SupplementaryGroups=ssl-cert
Environment=HOME=${home}
WorkingDirectory=${home}
ExecStartPre=-/usr/bin/vncserver -kill ${DESKTOP_DISPLAY}
ExecStart=/usr/bin/vncserver ${DESKTOP_DISPLAY}
ExecStop=/usr/bin/vncserver -kill ${DESKTOP_DISPLAY}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$DESKTOP_SERVICE" >/dev/null 2>&1
    systemctl restart "$DESKTOP_SERVICE"
    sleep 5
    systemctl is-active --quiet "$DESKTOP_SERVICE" \
        || fail "KasmVNC failed to start. Check: journalctl -u ${DESKTOP_SERVICE} -n 50"
    ok "Boot service '${DESKTOP_SERVICE}' enabled and running."
}

do_desktop() {
    echo ""
    echo "Claude Desktop in the browser - Install"
    echo "================================================="
    load_conf
    [[ -n "${CLAUDE_USER:-}" ]] || pick_settings
    local home; home="$(user_home "$CLAUDE_USER")"
    info "XFCE + Claude Desktop run as '${CLAUDE_USER}', streamed by KasmVNC on port ${DESKTOP_PORT}."
    confirm "Continue?" "Y" || { info "Cancelled."; return 0; }

    export DEBIAN_FRONTEND=noninteractive
    info "Installing a minimal XFCE desktop (several minutes)..."
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $DESKTOP_PKGS >/dev/null \
        || fail "Desktop package install failed."
    ok "Desktop installed."

    remove_autologin

    # shellcheck disable=SC2086
    systemctl mask $SLEEP_TARGETS >/dev/null 2>&1
    mkdir -p "${home}/.config/autostart"
    cat > "$(noblank_file "$CLAUDE_USER")" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable screen blanking and compositing
Exec=sh -c "xset s off -dpms s noblank; xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false; xfconf-query -c xfce4-screensaver -p /saver/enabled -n -t bool -s false; xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false"
EOF
    ok "Sleep/suspend masked, screen blanking off."

    if [[ -z "$(pkg_ver claude-desktop)" ]]; then
        info "Adding Anthropic's apt repository..."
        curl -fsSLo "$DESKTOP_KEY_FILE" "$DESKTOP_KEY_URL" || fail "Key download failed. Check access to downloads.claude.ai."
        gpg --show-keys --with-colons "$DESKTOP_KEY_FILE" 2>/dev/null | grep -q "^fpr:::::::::${DESKTOP_KEY_FPR}:" \
            || { rm -f "$DESKTOP_KEY_FILE"; fail "Signing key fingerprint mismatch. Not installing."; }
        echo "$DESKTOP_REPO_LINE" > "$DESKTOP_REPO_FILE"
        apt-get update -qq
        info "Installing claude-desktop..."
        apt-get install -y -qq claude-desktop >/dev/null || fail "claude-desktop install failed."
    fi
    ok "Claude Desktop $(pkg_ver claude-desktop) installed."

    cat > "$(autostart_file "$CLAUDE_USER")" <<'EOF'
[Desktop Entry]
Type=Application
Name=Claude
Exec=claude-desktop
EOF
    chown -R "$CLAUDE_USER:" "${home}/.config"
    ok "Claude Desktop starts with the desktop."

    install_kasmvnc
    usermod -aG ssl-cert "$CLAUDE_USER"
    set_kasm_password
    write_kasm_config

    echo ""
    echo "Desktop ready"
    echo "================================================="
    echo ""
    echo "  Open          https://$(hostname -I 2>/dev/null | awk '{print $1}'):${DESKTOP_PORT}"
    echo "                (self-signed certificate: accept the browser warning)"
    echo "  Login         ${CLAUDE_USER} + the password you just set"
    echo "  Remote        Cloudflare tunnel -> https://<host-ip>:${DESKTOP_PORT} with No TLS Verify,"
    echo "                behind Cloudflare Access"
    echo "  Keyring       if asked for a new keyring password, leave it BLANK"
    echo "  Restart       sudo systemctl restart ${DESKTOP_SERVICE}"
    echo ""
}

desktop_remove() {
    systemctl disable --now "$DESKTOP_SERVICE" >/dev/null 2>&1 || true
    rm -f "$DESKTOP_SERVICE_FILE"
    systemctl daemon-reload
    apt-get remove -y -qq claude-desktop >/dev/null 2>&1 || true
    rm -f "$DESKTOP_REPO_FILE"
    [[ -n "${CLAUDE_USER:-}" ]] && rm -f "$(autostart_file "$CLAUDE_USER")"
    ok "Claude Desktop and its service removed."

    if confirm "Also remove KasmVNC, the sleep mask and the XFCE desktop?" "N"; then
        remove_autologin
        if [[ -n "${CLAUDE_USER:-}" ]]; then
            local home; home="$(user_home "$CLAUDE_USER")"
            rm -rf "$(noblank_file "$CLAUDE_USER")" "${home}/.vnc" "${home}/.kasmpasswd"
        fi
        # shellcheck disable=SC2086
        systemctl unmask $SLEEP_TARGETS >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        apt-get remove -y -qq kasmvncserver $DESKTOP_PKGS lightdm lightdm-gtk-greeter >/dev/null 2>&1 || true
        apt-get autoremove -y -qq >/dev/null 2>&1 || true
        ok "KasmVNC and the desktop removed."
    fi
}

# --- Uninstall ---------------------------------------------------------------
do_uninstall() {
    load_conf
    if [[ -n "$(pkg_ver claude-desktop)" ]] && confirm "Remove Claude Desktop and its browser desktop?" "N"; then
        desktop_remove
    fi
    confirm "Remove the '${SERVICE_NAME}' boot service?" "N" || { info "Cancelled."; return 0; }
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    [[ -n "${CLAUDE_USER:-}" ]] && as_user "$CLAUDE_USER" tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    ok "Service removed."

    if [[ -n "${CLAUDE_USER:-}" ]] && confirm "Also remove Claude Code and its login for '${CLAUDE_USER}'?" "N"; then
        local home; home="$(user_home "$CLAUDE_USER")"
        rm -rf "${home}/.local/bin/claude" "${home}/.local/share/claude" "${home}/.claude" "${home}/.claude.json"
        ok "Claude Code removed. Your files in ${CLAUDE_WORKDIR:-the working folder} are untouched."
    fi
    rm -f "$CONF_FILE"
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-}" in
    install)   do_install;    exit 0 ;;
    status)    do_status;     exit 0 ;;
    update)    do_update;     exit 0 ;;
    ip)        do_static_ip;  exit 0 ;;
    desktop)   do_desktop;    exit 0 ;;
    uninstall) do_uninstall;  exit 0 ;;
    "")        ;;
    *)         fail "Unknown option '$1'. Use: install | status | update | ip | desktop | uninstall" ;;
esac

while true; do
    echo ""
    echo "================================================="
    echo "  Claude Code on Ubuntu VM"
    echo "================================================="
    echo "  1) Install"
    echo "  2) Status"
    echo "  3) Update"
    echo "  4) Static IP"
    echo "  5) Desktop (browser)"
    echo "  6) Uninstall"
    echo "  0) Exit"
    echo ""
    read -rp "  Choose [0-6]: " choice </dev/tty || choice=0
    case "$choice" in
        1) do_install ;;
        2) do_status ;;
        3) do_update ;;
        4) do_static_ip ;;
        5) do_desktop ;;
        6) do_uninstall ;;
        0) exit 0 ;;
        *) warn "Invalid choice." ;;
    esac
done
