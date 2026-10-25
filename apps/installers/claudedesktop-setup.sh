#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/claudedesktop-setup.sh?$(date +%s))"
# Purpose: Installs Claude Desktop with a lean auto-login desktop as an always-on Chat bridge (Ubuntu VM)
# =============================================================================
# Usage:
#   Run inside the Ubuntu VM (not the PVE host), as root or via sudo. Menu:
#     1) Install      XFCE + LightDM auto-login + Claude Desktop + autostart
#     2) Status       desktop, auto-login, app version, autostart, running, sleep
#     3) Update       apt upgrade claude-desktop
#     4) Uninstall    remove the app and autostart (optionally the desktop)
#   Args skip the menu: install | status | update | uninstall
#
#   After install (once, from the Proxmox noVNC console):
#     sign in to Claude, then open the project -> Add folder -> the shared folder.
#   Then use claude.ai Chat from any browser; this VM keeps the folder reachable.
#   Coexists with claude-rc (claudeubuntu-setup.sh), which stays the headless fallback.
#
# Config (env): CLAUDE_USER, CLAUDE_WORKDIR
# =============================================================================

set -euo pipefail

# --- Variables ---------------------------------------------------------------
CONF_FILE="/etc/claude-desktop.conf"
DEFAULT_WORKDIR="/mnt/sec/media/shared"
KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
KEY_FILE="/usr/share/keyrings/claude-desktop-archive-keyring.asc"
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
REPO_FILE="/etc/apt/sources.list.d/claude-desktop.list"
REPO_LINE="deb [arch=amd64,arm64 signed-by=${KEY_FILE}] https://downloads.claude.ai/claude-desktop/apt/stable stable main"
AUTOLOGIN_FILE="/etc/lightdm/lightdm.conf.d/50-autologin.conf"
SLEEP_TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"
DESKTOP_PKGS="xfce4 xfce4-terminal lightdm lightdm-gtk-greeter dbus-x11 xserver-xorg gnome-keyring libpam-gnome-keyring"

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

load_conf() {
    # shellcheck disable=SC1090
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
    return 0
}

user_home() { getent passwd "$1" | cut -d: -f6; }
autostart_file() { echo "$(user_home "$1")/.config/autostart/claude-desktop.desktop"; }
nosleep_file()   { echo "$(user_home "$1")/.config/autostart/no-blank.desktop"; }
pkg_ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# --- Settings ----------------------------------------------------------------
pick_settings() {
    load_conf
    local def_user="${CLAUDE_USER:-${SUDO_USER:-}}"
    [[ -z "$def_user" || "$def_user" == "root" ]] && \
        def_user="$(getent passwd 1000 | cut -d: -f1)"

    echo ""
    info "The desktop logs in automatically as this user and starts Claude Desktop."
    CLAUDE_USER="$(ask "Auto-login user" "$def_user")"
    id "$CLAUDE_USER" &>/dev/null || fail "User '$CLAUDE_USER' does not exist."
    [[ "$CLAUDE_USER" != "root" ]] || fail "Pick a normal user, not root (the app refuses to run as root)."

    CLAUDE_WORKDIR="$(ask "Folder to add in the app" "${CLAUDE_WORKDIR:-$DEFAULT_WORKDIR}")"
    [[ -d "$CLAUDE_WORKDIR" ]] || warn "Folder '$CLAUDE_WORKDIR' not found. Mount the share first (virtiofs-setup.sh)."

    cat > "$CONF_FILE" <<EOF
CLAUDE_USER="${CLAUDE_USER}"
CLAUDE_WORKDIR="${CLAUDE_WORKDIR}"
EOF
    chmod 644 "$CONF_FILE"
    ok "Settings saved to ${CONF_FILE}."
}

# --- Install -----------------------------------------------------------------
install_desktop() {
    info "Installing a minimal XFCE desktop with LightDM (several minutes)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $DESKTOP_PKGS >/dev/null \
        || fail "Desktop package install failed."
    ok "Desktop installed."
}

setup_autologin() {
    mkdir -p "$(dirname "$AUTOLOGIN_FILE")"
    cat > "$AUTOLOGIN_FILE" <<EOF
[Seat:*]
autologin-user=${CLAUDE_USER}
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
EOF
    # LightDM only auto-logs in members of the autologin group on Ubuntu.
    groupadd -f autologin
    usermod -aG autologin "$CLAUDE_USER"
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
    systemctl enable lightdm >/dev/null 2>&1 || true
    systemctl set-default graphical.target >/dev/null
    ok "Auto-login set for '${CLAUDE_USER}' (XFCE)."
}

disable_sleep() {
    # shellcheck disable=SC2086
    systemctl mask $SLEEP_TARGETS >/dev/null 2>&1
    local f; f="$(nosleep_file "$CLAUDE_USER")"
    mkdir -p "$(dirname "$f")"
    cat > "$f" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable screen blanking
Exec=sh -c "xset s off -dpms s noblank; xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false; xfconf-query -c xfce4-screensaver -p /saver/enabled -n -t bool -s false"
X-GNOME-Autostart-enabled=true
EOF
    chown -R "$CLAUDE_USER:" "$(user_home "$CLAUDE_USER")/.config"
    ok "Sleep/suspend masked, screen blanking off at login."
}

install_app() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq curl gnupg >/dev/null
    info "Adding Anthropic's apt repository..."
    curl -fsSLo "$KEY_FILE" "$KEY_URL" || fail "Key download failed. Check access to downloads.claude.ai."
    gpg --show-keys --with-colons "$KEY_FILE" 2>/dev/null | grep -q "^fpr:::::::::${KEY_FPR}:" \
        || { rm -f "$KEY_FILE"; fail "Signing key fingerprint mismatch. Not installing."; }
    echo "$REPO_LINE" > "$REPO_FILE"
    apt-get update -qq
    info "Installing claude-desktop..."
    apt-get install -y -qq claude-desktop >/dev/null || fail "claude-desktop install failed."
    ok "Claude Desktop $(pkg_ver claude-desktop) installed."
}

setup_autostart() {
    local f; f="$(autostart_file "$CLAUDE_USER")"
    mkdir -p "$(dirname "$f")"
    cat > "$f" <<'EOF'
[Desktop Entry]
Type=Application
Name=Claude
Exec=claude-desktop
X-GNOME-Autostart-enabled=true
EOF
    chown -R "$CLAUDE_USER:" "$(user_home "$CLAUDE_USER")/.config"
    ok "Claude Desktop starts at login."
}

do_install() {
    echo ""
    echo "Claude Desktop - Install"
    echo "================================================="
    pick_settings
    install_desktop
    setup_autologin
    disable_sleep
    install_app
    setup_autostart
    print_done
    if confirm "Start the desktop now (switches the console to the GUI)?" "Y"; then
        systemctl restart lightdm || systemctl isolate graphical.target
    fi
}

print_done() {
    echo ""
    echo "Install Complete"
    echo "================================================="
    echo ""
    echo "  One-time, in the Proxmox noVNC console:"
    echo "    1. If asked to create a keyring password, leave it BLANK"
    echo "       (auto-login cannot unlock a passworded keyring; the sign-in would be lost)."
    echo "    2. Sign in to Claude in the app."
    echo "    3. Open your project -> Add folder -> ${CLAUDE_WORKDIR}"
    echo ""
    echo "  Then use claude.ai Chat from any browser. Reboot once to test it comes back."
    echo "  Status        bash $0 status"
    echo ""
}

# --- Status ------------------------------------------------------------------
do_status() {
    load_conf
    local u="${CLAUDE_USER:-}" dm al app auto run masked=0 t
    dm="$(systemctl is-active display-manager 2>/dev/null || true)"
    al="$(awk -F= '/^autologin-user=/{print $2; exit}' "$AUTOLOGIN_FILE" 2>/dev/null || true)"
    app="$(pkg_ver claude-desktop)"
    auto="-"; [[ -n "$u" ]] && { [[ -f "$(autostart_file "$u")" ]] && auto="present" || auto="missing"; }
    pgrep -f claude-desktop >/dev/null && run="running" || run="NOT running"
    for t in $SLEEP_TARGETS; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null || true)" == "masked" ]] && masked=$((masked + 1))
    done

    echo ""
    echo "================================================="
    echo "  Status"
    echo "================================================="
    echo "  Desktop         $( [[ -n "$(pkg_ver xfce4)" ]] && echo "XFCE installed" || echo "not installed")"
    echo "  Display manager ${dm:-inactive}  (default: $(systemctl get-default))"
    echo "  Auto-login      ${al:-not set}"
    echo "  Claude Desktop  ${app:-not installed}"
    echo "  Autostart       ${auto}"
    echo "  App process     ${run}"
    echo "  Sleep targets   ${masked}/4 masked"
    echo "  Folder          ${CLAUDE_WORKDIR:--}"
    echo "  claude-rc       $( [[ -f /etc/systemd/system/claude-rc.service ]] && systemctl is-active claude-rc 2>/dev/null || echo 'not set up')"
    echo "================================================="
    echo ""
}

# --- Update ------------------------------------------------------------------
do_update() {
    [[ -n "$(pkg_ver claude-desktop)" ]] || fail "Not installed. Run Install first."
    info "Updating claude-desktop..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --only-upgrade claude-desktop >/dev/null || fail "Update failed."
    ok "Claude Desktop $(pkg_ver claude-desktop). Restart the app (or reboot) to use it."
}

# --- Uninstall ---------------------------------------------------------------
do_uninstall() {
    load_conf
    confirm "Remove Claude Desktop and its autostart?" "N" || { info "Cancelled."; return 0; }
    pkill -f claude-desktop 2>/dev/null || true
    apt-get remove -y -qq claude-desktop >/dev/null 2>&1 || true
    rm -f "$REPO_FILE"
    [[ -n "${CLAUDE_USER:-}" ]] && rm -f "$(autostart_file "$CLAUDE_USER")"
    ok "Claude Desktop removed. Files in ${CLAUDE_WORKDIR:-the shared folder} are untouched."

    if confirm "Also remove auto-login, the sleep mask and the desktop (back to text console)?" "N"; then
        rm -f "$AUTOLOGIN_FILE"
        [[ -n "${CLAUDE_USER:-}" ]] && rm -f "$(nosleep_file "$CLAUDE_USER")"
        # shellcheck disable=SC2086
        systemctl unmask $SLEEP_TARGETS >/dev/null 2>&1 || true
        systemctl set-default multi-user.target >/dev/null
        systemctl disable lightdm >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        apt-get remove -y -qq $DESKTOP_PKGS >/dev/null 2>&1 || true
        apt-get autoremove -y -qq >/dev/null 2>&1 || true
        ok "Desktop removed. Reboot to return to the text console."
    fi
    rm -f "$CONF_FILE"
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-}" in
    install)   do_install;   exit 0 ;;
    status)    do_status;    exit 0 ;;
    update)    do_update;    exit 0 ;;
    uninstall) do_uninstall; exit 0 ;;
    "")        ;;
    *)         fail "Unknown option '$1'. Use: install | status | update | uninstall" ;;
esac

while true; do
    echo ""
    echo "================================================="
    echo "  Claude Desktop on Ubuntu VM"
    echo "================================================="
    echo "  1) Install"
    echo "  2) Status"
    echo "  3) Update"
    echo "  4) Uninstall"
    echo "  0) Exit"
    echo ""
    read -rp "  Choose [0-4]: " choice </dev/tty || choice=0
    case "$choice" in
        1) do_install ;;
        2) do_status ;;
        3) do_update ;;
        4) do_uninstall ;;
        0) exit 0 ;;
        *) warn "Invalid choice." ;;
    esac
done
