## Usage

Open [therepos.github.io/proxmox](https://therepos.github.io/proxmox/), click Copy command, paste into the Proxmox shell and press Enter.

## Structure

```
proxmox
├── AGENTS.md                   # rules for AI agents
├── CLAUDE.md                   # @AGENTS.md
├── .github
│   └── workflows        
├── apps
│   ├── installers              # bash installers
│   └── tools                   # host and guest scripts
├── docs
│   ├── index.html              # script page, therepos.github.io/proxmox (auto-generated)
│   └── templates.md            # script list (auto-generated)
└── scripts
    ├── sync-admonition.sh      # ok/info/warn/fail, synced into every script
    ├── lint.sh                 # checks every script against AGENTS.md
    └── docgen-templates.py     # builds docs/index.html and docs/templates.md
```

## Notes

- db-travel-food
- db-audit
- [Phr00t/Qwen-Image-Edit-Rapid-AIO](https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/blob/main/v23/Qwen-Rapid-AIO-NSFW-v23.safetensors)

## Resources

- [Proxmox community scripts](https://community-scripts.github.io/ProxmoxVE/)
- [Proxmox helper scripts](https://github.com/tteck/Proxmox)
