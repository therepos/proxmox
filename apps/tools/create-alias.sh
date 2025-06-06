#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/create-alias.sh?$(date +%s))"
# purpose: create alias for command-line in proxmox or termux

# ====== USER CONFIGURATION =======
ALIASES=(
  "pull|https://github.com/therepos/proxmox/raw/main/apps/termux/pull.sh?$(date +%s)"
  "sync|https://github.com/therepos/proxmox/raw/main/apps/termux/sync.sh?$(date +%s)"
  "reset|https://github.com/therepos/proxmox/raw/main/apps/termux/reset.sh?$(date +%s)"
  "purgedockerct|https://github.com/therepos/proxmox/raw/main/apps/tools/purge-dockerct.sh?$(date +%s)"
)
# =================================

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
BLUE="\e[34mℹ\e[0m"

function status_message() {
  local status=$1
  local message=$2
  if [[ "$status" == "success" ]]; then
    echo -e "${GREEN} ${message}"
  elif [[ "$status" == "info" ]]; then
    echo -e "${BLUE} ${message}"
  else
    echo -e "${RED} ${message}"
  fi
}

# Paths
ALIASES_FILE="$HOME/.aliases"
SHELL_RC="$HOME/.bashrc"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
touch "$ALIASES_FILE"

# Menu
echo -e "\n \e[1mAlias Manager\e[0m"
echo "1) Install aliases"
echo "2) Uninstall aliases"
read -p "Select an option (1 or 2): " choice
echo ""

if [[ "$choice" == "1" ]]; then
  for entry in "${ALIASES[@]}"; do
    IFS='|' read -r name url <<< "$entry"

    # Strip ?timestamp and get clean filename
    script_filename=$(basename "${url%%\?*}")
    script_path="$BIN_DIR/$script_filename"

    # Remove old alias and fetch fresh script
    sed -i "/alias $name=/d" "$ALIASES_FILE"
    wget -qO "$script_path" "$url"
    chmod +x "$script_path"
    echo "alias $name=\"$script_path\"" >> "$ALIASES_FILE"
    status_message success "Installed alias: $name"
  done

  grep -q "source ~/.aliases" "$SHELL_RC" || echo '[ -f ~/.aliases ] && source ~/.aliases' >> "$SHELL_RC"
  source "$ALIASES_FILE"

  echo ""
  status_message info "All aliases ready. Try:"
  for entry in "${ALIASES[@]}"; do
    IFS='|' read -r name _ <<< "$entry"
    echo "  → $name"
  done

elif [[ "$choice" == "2" ]]; then
  status_message info "This will remove the following aliases:"
  for entry in "${ALIASES[@]}"; do
    IFS='|' read -r name _ <<< "$entry"
    echo "  - $name"
  done
  echo ""
  read -p "Proceed? (y/n): " confirm
  echo ""

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    for entry in "${ALIASES[@]}"; do
      IFS='|' read -r name url <<< "$entry"
      script_filename=$(basename "${url%%\?*}")
      sed -i "/alias $name=/d" "$ALIASES_FILE"
      rm -f "$BIN_DIR/$script_filename"
      status_message success "Removed alias and script: $name"
    done

    if [ ! -s "$ALIASES_FILE" ]; then
      rm -f "$ALIASES_FILE"
      sed -i '/source ~/.aliases/d' "$SHELL_RC"
      status_message info "Cleaned up empty ~/.aliases and removed sourcing."
    fi

    status_message success "Uninstall complete."
  else
    status_message error "Cancelled. No changes made."
  fi

else
  status_message error "Invalid selection. Exiting."
  exit 1
fi
