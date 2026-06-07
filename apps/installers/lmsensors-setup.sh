#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/lmsensors-setup.sh?$(date +%s))"
# Purpose: Install/uninstall lm-sensors temperature monitoring on PVE9
# =============================================================================
# Usage:
#   1) Install / Update
#   2) Uninstall
#   3) Exit
#
# Webmin:
#   Tools > System and Server Status > LM Sensor Status > Add monitor of type
#   Sensor to check: Package id 0
#   Failures before reporting: 80
#
# Note: skips I2C/SMBus probe (flagged risky)
# =============================================================================

set -euo pipefail

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

# Detect the CPU temperature driver for this host
detect_module() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then
        echo "coretemp"
    elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
        echo "k10temp"
    else
        echo ""
    fi
}

do_install() {
    echo ""
    echo "Install / Update"
    echo "================================================="
    echo ""

    info "Updating package index and upgrading system..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y -qq dist-upgrade > /dev/null 2>&1 || fail "System upgrade failed."
    ok "System updated."

    info "Installing lm-sensors..."
    apt-get install -y -qq lm-sensors > /dev/null 2>&1 || fail "lm-sensors install failed."
    ok "lm-sensors installed."

    local mod
    mod="$(detect_module)"
    if [[ -n "$mod" ]]; then
        info "Loading CPU temperature driver ($mod)..."
        modprobe "$mod" || fail "Failed to load module: $mod"
        touch /etc/modules
        grep -qxF "$mod" /etc/modules || echo "$mod" >> /etc/modules
        ok "$mod loaded and set to load on boot."
    else
        info "Unknown CPU vendor - skipping CPU driver (NVMe temps will still work)."
    fi

    echo ""
    echo "Detected sensors"
    echo "================================================="
    sensors || fail "'sensors' command failed."

    echo ""
    echo "Done. CPU temp = 'Package id 0' above."
    echo "Webmin: Tools > System and Server Status > add 'LM Sensor Status'."
    echo "If a new kernel was installed during upgrade, reboot."
    echo ""
}

do_uninstall() {
    echo ""
    echo "Uninstall"
    echo "================================================="
    echo ""

    local mod
    mod="$(detect_module)"
    if [[ -n "$mod" ]]; then
        info "Unloading $mod (skipped if in use)..."
        modprobe -r "$mod" 2>/dev/null || true
        [[ -f /etc/modules ]] && sed -i "/^${mod}$/d" /etc/modules
        ok "$mod removed from boot config."
    fi

    info "Removing lm-sensors..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq lm-sensors > /dev/null 2>&1 || fail "lm-sensors removal failed."
    apt-get autoremove -y -qq > /dev/null 2>&1 || true
    ok "lm-sensors removed."

    echo ""
    echo "Done. Temperature monitoring uninstalled."
    echo "Remove the Webmin monitor manually under System and Server Status."
    echo ""
}

# --- Menu --------------------------------------------------------------------
echo ""
echo "lm-sensors - Temperature Setup for PVE9"
echo "================================================="
echo ""
echo "  1) Install / Update"
echo "  2) Uninstall"
echo "  3) Exit"
echo ""

read -rp "Select an option [1-3]: " choice
case "$choice" in
    1) do_install ;;
    2) do_uninstall ;;
    3) echo "Bye."; exit 0 ;;
    *) fail "Invalid option: $choice" ;;
esac
