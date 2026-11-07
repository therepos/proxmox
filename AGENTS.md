# Agent instructions

Personal Proxmox homelab repo: one-click installers and host tools.
Browser tools live in `therepos/extensions`, Windows scripts in `therepos/windows`,
MCP servers in `therepos/mcp` (Docker images, deployed via `therepos/docker`).
Scripts are fetched raw from GitHub `main` and run on the PVE host, so `main` must always work.

## Layout

- `apps/installers/<name>-setup.sh`  menu-driven installers, run as root on the PVE host
  (docker-related ones such as `portainer-setup.sh` run on the Docker VM)
- Docker compose files live in the private repo `therepos/docker` as `<name>-compose.yml`;
  deploy them with `apps/installers/portainer-setup.sh` (variables use `# hint:` comments)
- `apps/tools/`  one-off host scripts
- `scripts/`  repo helpers (docs generator, shared-block sync, lint). Header like the installers but
  without the one-liner: line 2 `# Purpose:`, a `# ===` fence, a terse `# Usage:` block, a closing fence.
- The script page (therepos.github.io/proxmox) is built by CI from each script's lines 2-3 with
  `scripts/docgen-pages.py` and deployed to GitHub Pages; nothing is committed.

## Installers

Each script is standalone: it runs via `bash -c "$(wget ...)"` and sources nothing.

- Name: `<name>-setup.sh`, lowercase, hyphenated. `vm-setup.sh` calls steps by that name.
- Header: line 2 the wget one-liner (ending `?$(date +%s)`), line 3 `# Purpose: <one line>`
  (the docs generator reads it), then a `# ===` fence. Optional terse `# Usage:` / `# Note:` lines below.
- Then `set -euo pipefail`, the shared blocks, and `[[ $EUID -eq 0 ]] || fail "Run as root."`.
- Shared blocks: regions between `# >>> <name>` and `# <<< <name>` are copies of the blocks in
  `scripts/sync-blocks.sh` (`admonition` = ok/info/warn/fail, `menu` = the menu helper). Never edit them
  in place; edit them there and run `scripts/lint.sh --fix`. Per-script code goes outside the markers.
  Shared look and behaviour belongs in a block, so changing it never touches a script's features.
- Output only through `ok`, `info`, `warn`, `fail` (`fail` exits). Continuation lines indent 7 spaces.
- Menus use the helper: `menu "Install" "Status|what it shows" "Back"`, then
  `case "$CHOICE" in Install) ...;; Status) ...;; Back) ...;; esac`, matching on names, never numbers.
  It numbers the options, adds `0) Exit` (0 only ever exits) and the prompt. In submenus put `Back` last.
  New menus must use it; convert hand-written menus when you next edit that script. Confirm destructive actions.
- Read input with `</dev/tty`; with no tty, take the safe default.
- Idempotent: detect existing state and skip; "nothing to do" exits 0.
- Section dividers: `# --- Title ---` padded to 79 columns.
- Secrets go to files with mode 600 under `/root` or `/etc/<app>`; never echo them to logs.

Scripts run by `vm-setup.sh` (disk, docker, gpu, kasm, virtiofs, webmin) also:
- run unattended with `-y`/`--yes` or env vars;
- exit 0 on success, 10 when a reboot is needed (never reboot themselves), anything else on failure.

Scripts that act differently on host vs VM detect with
`[[ -f /etc/pve/.version ]] || command -v pveversion` and expose a subcommand per side.

Orchestrators that log their run: `[[ -t 1 ]] && export FORCE_COLOR=1`, then tee to the log
through `sed 's/\x1b\[[0-9;]*m//g'`; keep logs outside dirs cleaned at the end.

## Before pushing

- `scripts/lint.sh --fix --changed origin/main` must pass. It fixes line 2, the shared blocks and `q) Quit`
  menus itself; fix the rest by hand. Without `--changed` it checks every script.
  CI checks changed scripts on every PR and push (every script when `sync-blocks.sh`, `lint.sh` or the
  workflow changes, weekly, or on a manual run) and pushes safe fixes back to the PR branch (never to `main`).
- Work on a branch and open a PR; merge only when lint is green.
- Never commit tokens, LAN IPs, serial numbers or MAC addresses. Use `<host-ip>` in docs.
- Do not put model names in commits, comments or docs.
