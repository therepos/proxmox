#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/termux/sync.sh?$(date +%s))"

# === Check for required packages ===
if ! command -v git &>/dev/null; then
  echo -e "\e[33mℹ 'git' not found. Installing...\e[0m"
  pkg install -y git || {
    echo -e "\e[31m✘ Failed to install 'git'. Exiting.\e[0m"
    exit 1
  }
fi

# === Load GitHub token if available ===
[ -f "$HOME/.github.env" ] && source "$HOME/.github.env"
[ -n "$GITHUB_TOKEN" ] && git config --global credential.helper "!f() { echo username=x; echo password=$GITHUB_TOKEN; }; f"

# === Check for .git ===
if [ ! -d .git ]; then
  echo -e "\e[31m✘ This folder is not a Git repo. Run pull.sh first.\e[0m"
  exit 1
fi

# === Pull latest changes ===
echo -e "\n🔄 Pulling latest from origin..."
git pull origin main || {
  echo -e "\e[31m✘ Pull failed. Resolve conflicts manually.\e[0m"
  exit 1
}

# === Show changes ===
echo -e "\n📦 Current status:"
git status

# === Stage and commit .md files only ===
echo -e "\n➕ Staging .md changes..."
git add *.md */*.md */*/*.md 2>/dev/null

if git diff --cached --quiet; then
  echo -e "\e[34mℹ No changes to commit.\e[0m"
else
  read -p "📝 Commit message: " COMMIT_MSG
  git commit -m "${COMMIT_MSG:-Update notes}"
  git push origin main
  echo -e "\n\e[32m✔ Synced changes to GitHub.\e[0m"
fi
