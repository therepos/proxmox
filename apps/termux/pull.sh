#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/termux/pull.sh?$(date +%s))"

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

echo "🔧 Script is running..."

# === Load GitHub token from ~/.github.env ===
[ -f "$HOME/.github.env" ] && source "$HOME/.github.env"
AUTH_HEADER=""
[ -n "$GITHUB_TOKEN" ] && AUTH_HEADER="-H Authorization: token $GITHUB_TOKEN"

# === Auto-detect repo from current folder ===
LOCAL_DIR=$(pwd)
REPO_NAME=$(basename "$LOCAL_DIR")
REPO_SLUG="therepos/$REPO_NAME"

echo "🔎 LOCAL_DIR: $LOCAL_DIR"
echo "🔎 REPO_NAME: $REPO_NAME"
echo "🔎 REPO_SLUG: $REPO_SLUG"

# === Check if repo exists and get default branch ===
REPO_INFO=$(curl -s ${AUTH_HEADER:+$AUTH_HEADER} "https://api.github.com/repos/$REPO_SLUG")
REPO_CHECK=$(echo "$REPO_INFO" | jq -r .message)

if [ "$REPO_CHECK" = "Not Found" ]; then
  echo -e "\e[31m✘ Repo not found: $REPO_SLUG\e[0m"
  exit 1
fi

DEFAULT_BRANCH=$(echo "$REPO_INFO" | jq -r .default_branch)
API_URL="https://api.github.com/repos/$REPO_SLUG/git/trees/$DEFAULT_BRANCH?recursive=1"

# === Initialize Git repo if needed ===
mkdir -p "$LOCAL_DIR"
cd "$LOCAL_DIR" || exit 1

if [ ! -d .git ]; then
  git init
  git remote add origin "https://github.com/$REPO_SLUG.git"
  git sparse-checkout init --cone
  git config pull.rebase false
fi

# === Fetch list of .md files ===
echo -e "\n🔍 Fetching .md files from $REPO_SLUG..."
mapfile -t FILE_LIST < <(curl -s $AUTH_HEADER "$API_URL" |
  jq -r '.tree[] | select(.path | endswith(".md")) | .path')

if [ ${#FILE_LIST[@]} -eq 0 ]; then
  echo -e "\e[31m✘ No .md files found or API rate limit reached.\e[0m"
  exit 1
fi

# === Show numbered menu ===
echo -e "\n📄 Select one or more Markdown files to pull:"
for i in "${!FILE_LIST[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${FILE_LIST[$i]}"
done

echo
read -p "#? " -a SELECTED

# === Validate + build sparse-checkout set ===
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

# === Sparse-checkout selected files ===
echo -e "\n⬇ Pulling selected files..."
git sparse-checkout set "${SELECTED_PATHS[@]}"
git pull origin "$DEFAULT_BRANCH"

# === Final result ===
echo -e "\n\e[32m✔ Pulled:\e[0m"
for f in "${SELECTED_PATHS[@]}"; do
  echo "  - $f"
done