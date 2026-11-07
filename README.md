## Usage

Pick a script from [docs/templates.md](docs/templates.md) and run the wget one-liner on line 2 of the script, as root.

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
│   └── templates.md            # site index (auto-generated)
└── scripts
    ├── sync-admonition.sh      # ok/info/warn/fail, synced into every script
    ├── lint.sh                 # checks every script against AGENTS.md
    └── docgen-templates.py     # builds docs/templates.md
```

## Notes

- db-travel-food
- db-audit
- [Phr00t/Qwen-Image-Edit-Rapid-AIO](https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/blob/main/v23/Qwen-Rapid-AIO-NSFW-v23.safetensors)

## Resources

- [Proxmox community scripts](https://community-scripts.github.io/ProxmoxVE/)
- [Proxmox helper scripts](https://github.com/tteck/Proxmox)
