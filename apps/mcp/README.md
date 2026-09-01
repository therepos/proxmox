# MCP servers

Remote [MCP](https://modelcontextprotocol.io) servers that connect Claude (claude.ai, Desktop,
Claude Code) to things on this Proxmox host. One folder per server, one shared plumbing file,
one installer.

```
apps/mcp/
├── README.md            # this file
├── common.py            # token gate, /healthz, serve() - shared by every server
└── shared-drive/        # server id = folder name
    ├── server.py
    └── README.md
```

| Server | Port | What it does |
|---|---|---|
| [shared-drive](shared-drive/) | 8765 | Browse, search, read and optionally write one folder on the host |

## Install

On the Proxmox host, then pick a server from the list:

```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/mcp-setup.sh?$(date +%s))"
```

Each server gets its own sandboxed systemd unit, token and port:

| Path | Purpose |
|---|---|
| `/opt/mcp/<id>/` | `server.py`, `common.py`, Python venv (`mcp>=2,<3`, `uvicorn`) |
| `/etc/mcp/<id>.env` | settings and token, mode 600 |
| `/etc/systemd/system/mcp-<id>.service` | unit; host is read-only except the paths the server declares |

## Contract (common.py)

Every server exposes the same endpoints, so the installer and Cloudflare setup are identical:

| Endpoint | Auth |
|---|---|
| `GET /healthz` | none |
| `POST /<TOKEN>/mcp` | token in the path (what claude.ai uses) |
| `POST /mcp` | `Authorization: Bearer <TOKEN>` |
| anything else | plain 404 |

## Connect

1. **Cloudflare**: Zero Trust → Networks → Tunnels → your tunnel → Public Hostname → Add.
   One hostname per server, type HTTP, URL `<host-ip>:<port>`.
2. **claude.ai / Claude Desktop**: Settings → Connectors → Add custom connector.
   URL `https://<hostname>/<TOKEN>/mcp`, OAuth fields empty.
3. **Claude Code**: `claude mcp add --transport http <name> https://<hostname>/<TOKEN>/mcp`

## Adding a server

1. Create `apps/mcp/<id>/server.py`:
   ```python
   from mcp.server.mcpserver import MCPServer
   import os, sys
   _HERE = os.path.dirname(os.path.abspath(__file__))
   sys.path[:0] = [_HERE, os.path.dirname(_HERE)]
   from common import env, serve

   mcp = MCPServer("<id>", instructions="what this server is for")

   @mcp.tool()
   def hello(name: str) -> str:
       """Say hello."""
       return f"hello {name}"

   if __name__ == "__main__":
       serve(mcp)
   ```
2. Add a line to `SERVERS=(...)` in `apps/installers/mcp-setup.sh`: `"<id>|<port>|<description>"`.
3. If it needs its own prompts or writable paths, add `configure_<id>()` next to
   `configure_shared_drive()`. It fills `EXTRA_ENV`, `RW_PATHS`, `RO_PATHS`, `SUMMARY`.
4. Add a `README.md` in the folder and a row in the table above.

## Security

- The token is the only credential. Anyone with the URL has the server's access level. Rotate from the installer (option 5).
- Wrong or missing token returns 404, so nothing is discoverable by scanning. Optionally add a Cloudflare WAF rule allowing only paths starting with `/<TOKEN>/`.
- Cloudflare Access cannot sit in front of it: claude.ai cannot log in through it.
