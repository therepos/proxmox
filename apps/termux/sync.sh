#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/termux/sync.sh?$(date +%s))"

echo "🧪 Running latest ** sync.sh at $(date)"
echo "🔧 Syncing..."

# === Check required packages ===
if ! command -v git &>/dev/null; then
  echo -e "\e[33mℹ 'git' not found. Installing...\e[0m"
  pkg install -y git || {
    echo -e "\e[31m✘ Failed to install 'git'. Exiting.\e[0m"
    exit 1
  }
fi

# === Load GitHub token if present ===
[ -f "$HOME/.github.env" ] && source "$HOME/.github.env"
if [ -n "$GITHUB_TOKEN" ]; then
  git config --global credential.helper "!f() { echo username=x; echo password=$GITHUB_TOKEN; }; f"
fi

# === Mark this dir as safe for Git ===
git config --global --add safe.directory "$(pwd)" 2>/dev/null

# === Ensure .git exists ===
if [ ! -d .git ]; then
  echo -e "\e[31m✘ This folder is not a Git repo. Run 'pull' first.\e[0m"
  exit 1
fi

# === Ensure remote is set ===
REPO_NAME=$(basename "$(pwd)")
REPO_SLUG="therepos/$REPO_NAME"
if ! git remote get-url origin &>/dev/null; then
  git remote add origin "https://github.com/$REPO_SLUG.git"
fi

# === Detect current branch or create main ===
CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)

if ! git show-ref --quiet --heads "$CURRENT_BRANCH"; then
  echo -e "📎 No local branch '$CURRENT_BRANCH' — creating it..."
  git checkout -b "$CURRENT_BRANCH"
fi

# === Try pulling from origin ===
echo -e "\n🔄 Pulling latest from origin/$CURRENT_BRANCH..."
if ! git pull origin "$CURRENT_BRANCH" 2>/dev/null; then
  echo -e "🔁 No remote branch yet. Pushing initial '$CURRENT_BRANCH' to GitHub..."
  git push -u origin "$CURRENT_BRANCH" || {
    echo -e "\e[31m✘ Push failed. Check remote access.\e[0m"
    exit 1
  }
fi

# === Git status ===
echo -e "\n📦 Git status:"
git status

# === Stage .md files ===
echo -e "\n➕ Staging .md files..."
git add *.md */*.md */*/*.md 2>/dev/null

# === Commit and push ===
if git diff --cached --quiet; then
  echo -e "\e[34mℹ No changes to commit.\e[0m"
else
  read -p "📝 Commit message: " COMMIT_MSG
  git commit -m "${COMMIT_MSG:-Update notes}"
  git push origin "$CURRENT_BRANCH" && echo -e "\n\e[32m✔ Synced changes to GitHub.\e[0m"
fi
