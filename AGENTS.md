# Agent instructions

Personal Proxmox homelab repo: one-click installers and host tools.
Browser tools live in `therepos/extensions`, Windows scripts in `therepos/windows`,
MCP servers in `therepos/mcp` (Docker images, deployed via `therepos/docker`).
Scripts are fetched raw from GitHub `main` and run on the PVE host, so `main` must always work.

## Layout

- Root: docs only (`AGENTS.md`, `CLAUDE.md`, `README.md`), plus `apps/`, `scripts/`, `.github/`.
- `apps/<action>-<subject>.sh`, flat. Action: `setup` (menu-driven installer, run as root on the PVE host;
  docker-related ones such as `setup-portainer.sh` run on the Docker VM), `report`, `backup`, `create`
  (one-off tools). Subject: one lowercase word.
- Docker compose files live in the private repo `therepos/docker` as `<name>-compose.yml`;
  deploy them with `apps/setup-portainer.sh` (variables use `# hint:` comments)
- `scripts/`  repo helpers, never run by users (docs generator, shared-block sync, lint). Header like the installers but
  without the bootstrap: line 2 `# Purpose:`, a `# ===` fence, a terse `# Usage:` block, a closing fence.
- The script page (therepos.github.io/proxmox) is built by CI from each script's lines 2-3 with
  `scripts/docgen-pages.py` and deployed to GitHub Pages; nothing is committed.
- Script page: title `Proxmox Scripts`, one row per script (name, purpose, button), repo link in the footer.
  Each subject and action needs a display name in `NAMES` in `docgen-pages.py` (lint checks): Title Case
  words, acronyms and product names as spelled (`LM Sensors`, `GitLab`); tools read `VM Create`.

## Installers

Each script is standalone: it runs via `bash -c "$(wget ...)"` and sources nothing.

- Name: `setup-<subject>.sh`. `setup-vm.sh` calls steps by that name (`docker` -> `setup-docker.sh`).
- Header: line 2 the bootstrap, `# bash -c "$(wget -qLO- <raw URL of this file>?$(date +%s))"`, line 3 `# Purpose: <one line>`
  (the docs generator reads it), then a `# ===` fence. Optional terse `# Usage:` / `# Note:` lines below.
- Then `set -euo pipefail`, the shared blocks, and `[[ $EUID -eq 0 ]] || fail "Run as root."`.
- Shared blocks: the regions between `# >>> <name>` and `# <<< <name>` are copies of the blocks in
  `scripts/sync-blocks.sh` (`admonition` = ok/info/warn/fail and banner, `menu` = the menu helper, `shortcut` = below). Never edit inside the
  markers; edit the block in `sync-blocks.sh`, then run it or `scripts/lint.sh --fix`. Per-script code goes outside.
  Shared look and behaviour belongs in a block, so changing it never touches a script's features.
- Output only through `ok`, `info`, `warn`, `fail` (`fail` exits). Continuation lines indent 7 spaces.
- Screen titles use `banner "Title"` (admonition block): a `====` line, the title, a `====` line. A menu screen is
  `banner`, one status line (`ok`/`info`), then `menu`.
- Menus use the helper: `menu "Install" "Status|what it shows" "Back"`, then
  `case "$CHOICE" in Install) ...;; Status) ...;; Back) ...;; esac`, matching on names, never numbers.
  It numbers the options, adds `0) Exit` (0 only ever exits) and the prompt. In submenus put `Back` last.
  New menus must use it; convert hand-written menus when you next edit that script. Confirm destructive actions.
- Read input with `</dev/tty`; with no tty, take the safe default.
- Users are non-technical: ask only what has no safe default. Show the recommended settings with one
  `Use these? [Y/n]`; only on `n` prompt per field, Enter keeping the default. Do recommended steps without asking.
- No setting whose only effect is to break another feature: fix the safe behaviour and move old installs to it on the next Install.
- Installers whose result the user works with offer `Guide`: key addresses, how to log in, how to test it, how to undo.
- Under `set -euo pipefail`, `v=$(cmd | grep ...)` with no match exits silently: add `|| true` inside `$( )` and check `v`.
  Run fetched scripts as `src=$(wget ...) || fail ...; bash -c "$src"`: `bash -c "$(wget ...)"` succeeds on a failed download.
- Scripts run again later (like `setup-gpu.sh`) offer Settings > Shortcut via the `shortcut` block: a `.bashrc`
  command named after the script that runs the latest version from GitHub (set `SCRIPT_URL` above the block).
  Never save a local copy of a script; remove an old one on the next run. Next-step hints name the menu option
  ("run this again and choose Bind"), not a command that may not exist.
- Idempotent: detect existing state and skip; "nothing to do" exits 0. Restart a service only when its config changed.
- Prechecks: on the wrong machine say where to run it; offer to install a missing prerequisite with its
  `setup-<subject>.sh` instead of only failing. Pass third-party installers their yes/force flag.
- Section dividers: `# --- Title ---` padded to 79 columns.
- Secrets go to files with mode 600 under `/root` or `/etc/<app>`; never echo them to logs.
- Containers are created with `--timezone host` so their clock (and cron) matches the PVE host.

Scripts run by `setup-vm.sh` (disk, docker, gpu, kasm, virtiofs, webmin) also:
- run unattended with `-y`/`--yes` or env vars;
- exit 0 on success, 10 when a reboot is needed (never reboot themselves), anything else on failure.

Scripts that act differently on host vs VM detect with
`[[ -f /etc/pve/.version ]] || command -v pveversion` and expose a subcommand per side.

Orchestrators that log their run: `[[ -t 1 ]] && export FORCE_COLOR=1`, then tee to the log
through `sed 's/\x1b\[[0-9;]*m//g'`; keep logs outside dirs cleaned at the end.

Backups go to the private repo `therepos/backups`, one folder per app, overwritten each run (git keeps history).
A restore confirms first, stops the app, restores, always starts it again, and says what is not restored (secrets).
App data (`/mnt/sec/apps`) belongs to `setup-backup.sh` (in development): `setup-backup.sh restore <app>` exits 0
when restored, 3 when it has no backup for that app, anything else on failure.

## Documentation

- Script header: shebang; bootstrap (installers and tools); `# Purpose:` in one line; a fence. Optional
  sections follow (`# Usage:`, `# Markers:`, `# Note:`), closed by a fence.
- `# Usage:` lists commands only: one per line, descriptions aligned in one column, never wrapped.
- Explanations (how, why, what CI does) live in AGENTS.md, not in script headers.
- Concise, standard terms (bootstrap, shared block, lint, fence); no filler words.
- Code comments only where the reason is not obvious, one line each.
- Refinement: when the owner corrects a name, wording or format, apply it everywhere it occurs in the same
  PR, record the rule here, and add a lint check when it can be checked mechanically.

## Before pushing

- `scripts/lint.sh --fix --changed origin/main` must pass. `--fix` repairs the bootstrap, the shared blocks and
  old `q) Quit` menus; fix the rest by hand. Options combine. `--changed` checks every script when
  `sync-blocks.sh`, `lint.sh` or `ci-lint.yml` changed.
- CI checks changed scripts on every PR and push (every script weekly, on a manual run, or when those files
  change) and pushes safe fixes to the PR branch, never to `main`.
- Work on a branch and open a PR (`gh api repos/<owner>/<repo>/pulls`, body via `-F body=@file`; GraphQL `gh pr` commands
  are blocked here); merge it yourself, without asking, as soon as lint is green. Dry-run host-changing flows with stub `qm`/`pct`/`ssh` first on `PATH`
  against a copy whose `/etc/pve` paths point to a temp dir. Run negative tests on a temp copy, never via `git checkout` (it drops uncommitted edits), and check each edit landed
  (`git diff`) before reporting it.
- Never commit tokens, LAN IPs, serial numbers or MAC addresses. Use `<host-ip>` in docs.
- Do not put model names in commits, comments or docs.
