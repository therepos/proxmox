# Templates

## Installers
- [Claudeubuntu Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/claudeubuntu-setup.sh) – Installs Claude Code with Remote Control as a boot service, plus optional Claude Desktop in the browser via KasmVNC (Ubuntu VM).  
- [Cloudflared Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/cloudflared-setup.sh) – Install / Update / Uninstall Cloudflared tunnel LXC on Proxmox.  
- [Disk Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/disk-setup.sh) – Check VM disk capacity and expand it end-to-end (host & VM aware).  
- [Docker Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/docker-setup.sh) – Installs docker engine and docker compose (Ubuntu/PVE9).  
- [Drivemount Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/drivemount-setup.sh) – Mount a drive and optionally register as Proxmox storage.  
- [Filebrowser Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/filebrowser-setup.sh) – Installs FileBrowser via official binary (Ubuntu/PVE9).  
- [Gitlab Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/gitlab-setup.sh) – Deploys and manages GitLab CE with Runner, Container Registry and Pages (Ubuntu/PVE9).  
- [Gpu Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/gpu-setup.sh) – GPU passthrough (host) + NVIDIA driver install (VM) — combined.  
- [Hermes Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/hermes-setup.sh) – Install / Update / Uninstall Hermes Agent LXC (Docker) on Proxmox.  
- [Kasm Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/kasm-setup.sh) – Install Kasm Workspaces (Ubuntu).  
- [Lmsensors Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/lmsensors-setup.sh) – Install/uninstall lm-sensors temperature monitoring on PVE9.  
- [Mcp Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/mcp-setup.sh) – Install / Update / Uninstall MCP servers (apps/mcp) that connect Claude to this host.  
- [Portainer Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/portainer-setup.sh) – Installs Portainer, deploys stacks from the docker repo, and backs Portainer up to GitHub nightly.  
- [Pvenosub Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/pvenosub-setup.sh) – Apply Proxmox VE post-install homelab defaults + remove the sub nag.  
- [Smb Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/smb-setup.sh) – Samba server on Proxmox host / SMB client mounts in VM (Debian/Ubuntu).  
- [Tailscale Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/tailscale-setup.sh) – Install / Update / Uninstall Tailscale subnet router LXC on Proxmox.  
- [Virtiofs Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/virtiofs-setup.sh) – VirtIO-FS share — Proxmox host setup + Ubuntu VM mount (auto-detects).  
- [vm-create.sh](https://github.com/therepos/proxmox/blob/main/apps/installers/vm-create.sh) – Create an Ubuntu VM on the Proxmox host (q35/OVMF + GPU passthrough).  
- [Vm Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/vm-setup.sh) – Orchestrate Ubuntu VM setup (delegates to standalone installers).  
- [Webmin Installer](https://github.com/therepos/proxmox/blob/main/apps/installers/webmin-setup.sh) – Install webmin on PVE9.  

## Tools
- [hermes-backup.sh](https://github.com/therepos/proxmox/blob/main/apps/tools/hermes-backup.sh) – Nightly backup of Hermes skills, scripts, jobs, config and memories to a private GitHub repo (run inside the Hermes LXC).  
- [llmfit.sh](https://github.com/therepos/proxmox/blob/main/apps/tools/llmfit.sh) – Recommend local LLMs that fit this machine's GPU/RAM via llmfit (VM/LXC, no sudo).  
- [pve-report.sh](https://github.com/therepos/proxmox/blob/main/apps/tools/pve-report.sh) – Dump a full Proxmox VE configuration/health report to a text file (PVE host).  
- [vm-report.sh](https://github.com/therepos/proxmox/blob/main/apps/tools/vm-report.sh) – Dump a full guest (VM or LXC) configuration/health report to a text file (Debian/Ubuntu).  
