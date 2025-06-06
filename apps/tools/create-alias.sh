#!/usr/bin/env bash
# Create or remove aliases in Termux/Proxmox
# Usage: bash -c "$(wget -qLO- https://github.com/.../create-alias.sh)"

# ====== USER CONFIGURATION ======
MODE="live"  # "live" = fetch fresh each time, "local" = download scripts

ALIASES=(
  "pull|https://github.com/therepos/proxmox/raw/main/apps/termux/pull.sh"
  "sync|https://github.com/therepos/proxmox/raw/main/apps/termux/sync.sh"
)
# =================================

# Symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
BLUE="\e[34mℹ\e[0m"

status_message() {
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

ALIASES_FILE="$HOME/.aliases"
SHELL_RC="$HOME/.bashrc"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
touch "$ALIASES_FILE"

echo -e "\n \e[1mAlias Manager [$MODE mode]\e[0m"
echo "1) Install aliases"
echo "2) Uninstall aliases"
read -p "Select an option (1 or 2): " choice
echo ""

if [[ "$choice" == "1" ]]; then
  for entry in "${ALIASES[@]}"; do
    IFS='|' read -r name url <<< "$entry"
    sed -i "/alias $name=/d" "$ALIASES_FILE"

    if [[ "$MODE" == "live" ]]; then
      echo "alias $name='bash -c \"\$(wget -qLO- ${url}?$(date +%s})\"'" >> "$ALIASES_FILE"
      status_message success "Alias '$name' set to fetch live"
    else
      script_path="$BIN_DIR/$name.sh"
      wget -qO "$script_path" "${url}?$(date +%s)"
      chmod +x "$script_path"
      echo "alias $name=\"$script_path\"" >> "$ALIASES_FILE"
      status_message success "Alias '$name' installed locally"
    fi
  done

  grep -q "source ~/.aliases" "$SHELL_RC" || echo '[ -f ~/.aliases ] && source ~/.aliases' >> "$SHELL_RC"
  source "$ALIASES_FILE"

  echo ""
  status_message info "Aliases ready. Try:"
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
      IFS='|' read -r name _ <<< "$entry"
      sed -i "/alias $name=/d" "$ALIASES_FILE"
      rm -f "$BIN_DIR/$name.sh"
      status_message success "Removed alias and script: $name"
    done

    if [ ! -s "$ALIASES_FILE" ]; then
      rm -f "$ALIASES_FILE"
      sed -i '/source ~/.aliases/d' "$SHELL_RC"
      status_message info "Cleaned up ~/.aliases"
    fi

    status_message success "Uninstall complete."
  else
    status_message error "Cancelled."
  fi

else
  status_message error "Invalid selection. Exiting."
  exit 1
fi