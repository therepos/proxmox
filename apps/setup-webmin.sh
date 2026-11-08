#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-webmin.sh?$(date +%s))"
# Purpose: Install webmin on PVE9
# =============================================================================
# Note:
#   Temp files go to /var/tmp/.webmin (PVE 9 /tmp is a small RAM disk)
#   Behind a domain: referer=<domain> in /etc/webmin/config
#   Terminal behind a proxy: redirect_host=<domain> and redirect_port=443 in /etc/webmin/miniserv.conf, then systemctl restart webmin
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
# <<< admonition

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

echo ""
echo "Webmin - Automated Install"
echo "================================================="
echo ""

info "Updating package index..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
ok "Package index updated."

info "Setting up Webmin repository..."
bash <(curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh) || fail "Failed to add Webmin repo."
ok "Webmin repository added."

info "Installing Webmin..."
apt-get install -y -qq webmin --install-recommends > /dev/null 2>&1 || fail "Webmin install failed."
ok "Webmin installed."

info "Moving Webmin temp files to disk..."
WEBMIN_TMP=/var/tmp/.webmin
mkdir -p "$WEBMIN_TMP" && chmod 700 "$WEBMIN_TMP"
if grep -q '^tempdir=' /etc/webmin/config; then
    sed -i "s|^tempdir=.*|tempdir=${WEBMIN_TMP}|" /etc/webmin/config
else
    echo "tempdir=${WEBMIN_TMP}" >> /etc/webmin/config
fi
systemctl restart webmin
ok "Webmin temp files: ${WEBMIN_TMP}"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "Install Complete"
echo "================================================="
echo ""
echo "  Web UI        https://${SERVER_IP}:10000"
echo "  Login         Use your system root credentials."
echo ""
echo "  A self-signed certificate warning is expected."
echo ""
