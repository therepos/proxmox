#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/termux/pull.sh?$(date +%s))"

echo "🔧 Script is running..."

# === Check required packages ===
for pkg in git jq; do
  if ! command -v "$pkg" &>/dev/null; then
    echo -e "\e[33mℹ '$pkg' not found. Installing...\e[0m"
    pkg install -y "$pkg" || {
      echo -e "\e[31m✘ Failed to install '$pkg'. Exiting.\e[0m"
      exit 1
    }
  fi
done

# === Load GitHub token if present ===
[ -f "$HOME/.github.env" ] && source "$HOME/.github.env"
AUTH_HEADER=""
[ -n "$GITHUB_TOKEN" ] && AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

# === Auto-detect repo ===
LOCAL_DIR=$(pwd)
REPO_NAME=$(basename "$LOCAL_DIR")
REPO_SLUG="therepos/$REPO_NAME"
API_URL="https://api.github.com/repos/$REPO_SLUG/git/trees/main?recursive=1"
git config --global --add safe.directory "$LOCAL_DIR" 2>/dev/null

# === Debug output ===
echo "🔎 LOCAL_DIR: $LOCAL_DIR"
echo "🔎 REPO_NAME: $REPO_NAME"
echo "🔎 REPO_SLUG: $REPO_SLUG"

# === Verify repo exists ===
if [ -n "$AUTH_HEADER" ]; then
  REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH_HEADER" \
    "https://api.github.com/repos/$REPO_SLUG")
else
  REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://api.github.com/repos/$REPO_SLUG")
fi

if [ "$REPO_CHECK" != "200" ]; then
  echo -e "\e[31m✘ Repo not found: $REPO_SLUG\e[0m"
  exit 1
fi

# === Init Git repo if needed ===
mkdir -p "$LOCAL_DIR"
cd "$LOCAL_DIR" || exit 1

if [ ! -d .git ]; then
  git init
  git config core.sparseCheckout true
  git sparse-checkout init             # non-cone mode
  git config pull.rebase false
fi

# === Ensure remote is set ===
if ! git remote get-url origin &>/dev/null; then
  git remote add origin "https://github.com/$REPO_SLUG.git"
fi

# === Ensure sparse-checkout active ===
[ ! -f .git/info/sparse-checkout ] && git sparse-checkout init

# === Fetch list of .md files ===
echo -e "\n🔍 Fetching .md files from $REPO_SLUG..."
if [ -n "$AUTH_HEADER" ]; then
  FILES_JSON=$(curl -s -H "$AUTH_HEADER" "$API_URL")
else
  FILES_JSON=$(curl -s "$API_URL")
fi

mapfile -t FILE_LIST < <(echo "$FILES_JSON" |
  jq -r '.tree[] | select(.path | endswith(".md")) | .path')

if [ ${#FILE_LIST[@]} -eq 0 ]; then
  echo -e "\e[31m✘ No .md files found or API rate limit reached.\e[0m"
  exit 1
fi

# === Show selection menu ===
echo -e "\n📄 Select one or more Markdown files to pull:"
for i in "${!FILE_LIST[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${FILE_LIST[$i]}"
done

echo
read -p "#? " -a SELECTED

# === Build list of valid file paths ===
SELECTED_PATHS=()
for idx in "${SELECTED[@]}"; do
  if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#FILE_LIST[@]}" ]; then
    SELECTED_PATHS+=("${FILE_LIST[$((idx-1))]}")
  fi
done

if [ ${#SELECTED_PATHS[@]} -eq 0 ]; then
  echo -e "\e[33m↪ No valid selections made. Exiting.\e[0m"
  exit 0
fi

# === Enable sparse-checkout for selected files only (non-cone) ===
echo -e "\n⬇ Pulling selected files..."
git sparse-checkout set --no-cone "${SELECTED_PATHS[@]}"
git pull origin main

# === Show pulled result ===
echo -e "\n\e[32m✔ Pulled:\e[0m"
for f in "${SELECTED_PATHS[@]}"; do
  echo "  - $f"
done
