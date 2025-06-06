#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/termux/reset.sh?$(date +%s))"

BASE_DIR=$(pwd)

echo "📁 Current folder: $BASE_DIR"
echo "🔍 Scanning for subfolders..."

mapfile -t FOLDERS < <(find . -maxdepth 1 -mindepth 1 -type d | sed 's|^\./||')

if [ ${#FOLDERS[@]} -eq 0 ]; then
  echo "⚠ No subfolders found. Exiting."
  exit 1
fi

echo -e "\n📂 Select folder(s) to delete & reset:"
for i in "${!FOLDERS[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${FOLDERS[$i]}"
done

echo
read -p "#? " -a SELECTED

RESET_LIST=()
for idx in "${SELECTED[@]}"; do
  if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#FOLDERS[@]}" ]; then
    RESET_LIST+=("${FOLDERS[$((idx-1))]}")
  fi
done

if [ ${#RESET_LIST[@]} -eq 0 ]; then
  echo "↪ No valid selections. Exiting."
  exit 0
fi

echo -e "\n⚠ The following folders will be deleted and recreated:"
for folder in "${RESET_LIST[@]}"; do
  echo "  - $folder"
done

read -p "Proceed? (y/n): " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && echo "❌ Cancelled." && exit 0

for folder in "${RESET_LIST[@]}"; do
  rm -rf "$folder"
  mkdir -p "$folder"
  echo "✔ Reset: $folder"
done

echo -e "\nℹ Done. You can now run 'pull' inside each folder."
