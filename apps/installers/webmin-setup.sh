#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-webmin.sh?$(date +%s))"
# Purpose: Install webmin on PVE9
# =============================================================================

set -euo pipefail

info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

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