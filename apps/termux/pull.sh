#!/usr/bin/env bash

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
REPO_API="https://api.github.com/repos/$REPO_SLUG"
git config --global --add safe.directory "$LOCAL_DIR" 2>/dev/null

# === Check if repo exists ===
REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$REPO_API")
if [ "$REPO_CHECK" != "200" ]; then
  echo -e "\e[31m✘ Repo not found: $REPO_SLUG\e[0m"
  exit 1
fi

# === Get default branch from GitHub ===
DEFAULT_BRANCH=$(curl -s ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$REPO_API" | jq -r '.default_branch')
API_URL="$REPO_API/git/trees/$DEFAULT_BRANCH?recursive=1"

# === Init Git if needed ===
mkdir -p "$LOCAL_DIR"
cd "$LOCAL_DIR" || exit 1

if [ ! -d .git ]; then
  git init
  git config core.sparseCheckout true
  git sparse-checkout init        # non-cone mode
  git config pull.rebase false
fi

# === Ensure remote ===
if ! git remote get-url origin &>/dev/null; then
  git remote add origin "https://github.com/$REPO_SLUG.git"
fi

[ ! -f .git/info/sparse-checkout ] && git sparse-checkout init

# === Fetch list of .md files ===
echo -e "\n🔍 Fetching .md files from $REPO_SLUG ($DEFAULT_BRANCH)..."
FILES_JSON=$(curl -s ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$API_URL")
mapfile -t FILE_LIST < <(echo "$FILES_JSON" |
  jq -r '.tree[] | select(.path | endswith(".md")) | .path')

if [ ${#FILE_LIST[@]} -eq 0 ]; then
  echo -e "\e[31m✘ No .md files found.\e[0m"
  exit 1
fi

# === Show selection menu ===
echo -e "\n📄 Select one or more Markdown files to pull:"
for i in "${!FILE_LIST[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${FILE_LIST[$i]}"
done

echo
read -p "#? " -a SELECTED

# === Validate input ===
SELECTED_PATHS=()
for idx in "${SELECTED[@]}"; do
  if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#FILE_LIST[@]}" ]; then
    SELECTED_PATHS+=("${FILE_LIST[$((idx-1))]}")
  fi
done

if [ ${#SELECTED_PATHS[@]} -eq 0 ]; then
  echo -e "\e[33m↪ No valid selections. Exiting.\e[0m"
  exit 0
fi

# === Pull selected files ===
echo -e "\n⬇ Pulling selected files..."
git sparse-checkout set --no-cone "${SELECTED_PATHS[@]}"
git pull origin "$DEFAULT_BRANCH"
git sparse-checkout reapply

# === Done ===
echo -e "\n\e[32m✔ Pulled:\e[0m"
for f in "${SELECTED_PATHS[@]}"; do
  echo "  - $f"
done