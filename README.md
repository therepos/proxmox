## Usage

Pick a script from [docs/templates.md](docs/templates.md) and run the wget one-liner on line 2 of the script, as root.

Related repos: [docker](https://github.com/therepos/docker) (compose files, private), [backups](https://github.com/therepos/backups) (private),
[mcp](https://github.com/therepos/mcp) (MCP servers), [extensions](https://github.com/therepos/extensions) (browser tools),
[windows](https://github.com/therepos/windows) (Windows scripts), [skills](https://github.com/therepos/skills) (Claude skills).

## Structure

```
proxmox
├── AGENTS.md                   # rules for AI agents
├── CLAUDE.md                   # @AGENTS.md
├── .claude
│   └── skills                  # copies of Claude skills from therepos/skills.
├── .github
│   └── workflows        
├── apps
│   ├── installers              # bash installers
│   └── tools                   # host and guest scripts.
├── docs
│   └── templates.md            # site index (auto-generated)
└── scripts
    ├── admonition.sh           # ok/info/warn/fail
    ├── sync-admonition.sh      # copies it into every script (--check to verify).
    └── docgen-templates.py     # builds docs/templates.md.
```

## Notes

- db-travel-food
- db-audit
- [Phr00t/Qwen-Image-Edit-Rapid-AIO](https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/blob/main/v23/Qwen-Rapid-AIO-NSFW-v23.safetensors)

## Resources

- [Proxmox community scripts](https://community-scripts.github.io/ProxmoxVE/)
- [Proxmox helper scripts](https://github.com/tteck/Proxmox)
