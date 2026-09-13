# Purpose: file transfer for mcpshared: signed download / upload links and server-side fetch
# =============================================================================
# Loaded by server.py:
#
#     from transfer import register as register_transfer
#     register_transfer(mcp, _resolve, rel=_rel, guard=tool, read_only=READ_ONLY,
#                       token=TOKEN, public_url=PUBLIC_URL)
#
# MCP has no way to move a file between the user's device and the server: tool
# results go through the model's context. What connectors do instead is hand out
# links, and that is what this module does.
#
#   download_link(path)      -> signed URL; a browser on any device gets the file
#                               (folders arrive as a streamed zip)
#   upload_link(folder)      -> signed URL; opens a drop-zone page that PUTs files
#                               into that folder (curl -T works too)
#   fetch_url(url, dest)     -> server pulls a public URL straight into the share
#
# Routes (opened in the token gate by server.py via open_prefixes=("/files/",)):
#
#   GET /files/d/<exp>/<sig>/<path>          download
#   GET /files/u/<exp>/<sig>/<dir>           upload page
#   PUT /files/u/<exp>/<sig>/<dir>/<name>    store one file
#
# <sig> is an HMAC over (mode, expiry, share-relative path) keyed from MCP_TOKEN,
# so the token itself never appears in a link and rotating it voids every link.
#
# Environment:
#   MCP_PUBLIC_URL        https://<host> used in links (falls back to the LAN address)
#   MCP_LINK_MINUTES      default link lifetime (60)
#   MCP_UPLOAD_MAX_BYTES  per-file upload cap (default 4 GiB)
#   MCP_FETCH_MAX_BYTES   fetch_url cap (default 4 GiB)
# =============================================================================

from __future__ import annotations

import base64
import hashlib
import hmac
import html
import ipaddress
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from mcp.types import ToolAnnotations
from starlette.requests import Request
from starlette.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, StreamingResponse

PREFIX = "/files"
CHUNK = 1 << 20

RO = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
RW = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
NET = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=True)


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        return int(raw) if raw else default
    except ValueError:
        return default


def _lan_ip() -> str:
    """Best-effort primary LAN address (no packets are sent)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def _fmt_ts(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")


def _human(n: int) -> str:
    f = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or unit == "TB":
            return f"{f:.0f} {unit}" if unit == "B" else f"{f:.1f} {unit}"
        f /= 1024
    return f"{n} B"


def _unique(dest: Path) -> Path:
    """report.pdf -> report (1).pdf ... until free."""
    if not dest.exists():
        return dest
    stem, suffix = dest.stem, dest.suffix
    for i in range(1, 1000):
        cand = dest.with_name(f"{stem} ({i}){suffix}")
        if not cand.exists():
            return cand
    raise FileExistsError(f"Too many copies of {dest.name}")


def _clean_filename(name: str) -> str:
    name = urllib.parse.unquote(name).replace("\\", "/").split("/")[-1].strip()
    name = re.sub(r"[\x00-\x1f]", "", name)
    if not name or name in (".", "..") or name.startswith("."):
        raise ValueError("Bad file name.")
    return name[:200]


class _ZipSink:
    """Write-only buffer so zipfile can stream to an HTTP response."""

    def __init__(self) -> None:
        self.buf = bytearray()
        self.pos = 0

    def write(self, b: bytes) -> int:  # noqa: D401
        self.buf += b
        self.pos += len(b)
        return len(b)

    def tell(self) -> int:
        return self.pos

    def flush(self) -> None:
        pass

    def seekable(self) -> bool:
        return False

    def drain(self) -> bytes:
        out = bytes(self.buf)
        self.buf.clear()
        return out


def _zip_folder(root: Path):
    """Generator yielding a zip of root/ (deflated, streamed, zip64 as needed)."""
    sink = _ZipSink()
    with zipfile.ZipFile(sink, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for name in sorted(filenames):
                p = Path(dirpath) / name
                if p.is_symlink() or not p.is_file():
                    continue
                arc = os.path.join(root.name, os.path.relpath(p, root))
                with zf.open(zipfile.ZipInfo.from_file(p, arc), "w", force_zip64=True) as dst, open(p, "rb") as src:
                    while chunk := src.read(CHUNK):
                        dst.write(chunk)
                        if len(sink.buf) >= CHUNK:
                            yield sink.drain()
        if not zf.namelist():
            zf.writestr(f"{root.name}/", "")
    yield sink.drain()


def _host_is_public(host: str) -> None:
    """Refuse fetches that would reach this LAN, loopback or link-local (SSRF guard)."""
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as e:
        raise ValueError(f"Cannot resolve host: {host}") from e
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global:
            raise ValueError(f"Refusing to fetch from a private or local address ({host}).")


UPLOAD_PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Upload to __DIR__</title>
<style>
body{font:15px/1.4 system-ui,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem;color:#222;background:#fafafa}
h1{font-size:1.2rem;margin:0 0 .3rem}p{margin:.3rem 0 1rem;color:#555}
#drop{border:2px dashed #999;border-radius:12px;padding:2.5rem 1rem;text-align:center;background:#fff;cursor:pointer}
#drop.over{border-color:#06c;background:#eef5ff}
input[type=file]{display:none}
ul{list-style:none;padding:0}li{padding:.5rem 0;border-bottom:1px solid #eee;display:flex;justify-content:space-between;gap:1rem}
li span:last-child{white-space:nowrap;color:#555}.ok{color:#080}.err{color:#b00}
progress{width:100%;height:6px;display:block;margin-top:.3rem}
small{color:#777}
</style>
<h1>Upload to <code>__DIR__</code></h1>
<p>Files are stored on the shared drive. Link expires __EXP__.</p>
<div id=drop>Tap to choose files, or drop them here<input id=f type=file multiple></div>
<ul id=list></ul>
<small>Existing names are kept: a new copy gets a number appended. Large files: use the LAN link.</small>
<script>
const drop=document.getElementById('drop'),inp=document.getElementById('f'),list=document.getElementById('list');
drop.onclick=()=>inp.click();
['dragenter','dragover'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('over')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('over')}));
drop.addEventListener('drop',ev=>send(ev.dataTransfer.files));
inp.onchange=()=>send(inp.files);
function send(files){for(const file of files){
  const li=document.createElement('li');const name=document.createElement('span');name.textContent=file.name;
  const st=document.createElement('span');st.textContent='0%';const pr=document.createElement('progress');pr.max=100;pr.value=0;
  li.append(name,st);list.prepend(li);li.after(pr);
  const xhr=new XMLHttpRequest();
  xhr.open('PUT',location.pathname.replace(/\\/$/,'')+'/'+encodeURIComponent(file.name));
  xhr.upload.onprogress=e=>{if(e.lengthComputable){const p=Math.round(e.loaded/e.total*100);pr.value=p;st.textContent=p+'%'}};
  xhr.onload=()=>{pr.remove();try{const r=JSON.parse(xhr.responseText);
    if(xhr.status<300){st.textContent='saved as '+r.saved.split('/').pop();st.className='ok'}else{st.textContent=r.error||xhr.statusText;st.className='err'}}
    catch(e){st.textContent=xhr.status<300?'saved':'failed ('+xhr.status+')';st.className=xhr.status<300?'ok':'err'}};
  xhr.onerror=()=>{pr.remove();st.textContent='network error';st.className='err'};
  xhr.send(file);
}}
</script>
"""


# --- Registration ------------------------------------------------------------
def register(
    mcp,  # type: ignore[no-untyped-def]
    resolve: Callable[..., Path],
    *,
    rel: Callable[[Path], str],
    guard: Callable[[ToolAnnotations], Callable],
    read_only: bool,
    token: str,
    public_url: str = "",
    port: int = 8765,
) -> Callable[[Path], dict[str, Any]]:
    """Registers routes and tools; returns download_link_for(Path) for other modules."""
    key = hmac.new(token.encode(), b"mcpshared-files", hashlib.sha256).digest()
    default_minutes = _int_env("MCP_LINK_MINUTES", 60)
    upload_max = _int_env("MCP_UPLOAD_MAX_BYTES", 4 << 30)
    fetch_max = _int_env("MCP_FETCH_MAX_BYTES", 4 << 30)
    public = public_url.rstrip("/")
    lan = f"http://{_lan_ip()}:{port}"

    def sign(mode: str, exp: int, relpath: str) -> str:
        mac = hmac.new(key, f"{mode}|{exp}|{relpath}".encode(), hashlib.sha256).digest()
        return base64.urlsafe_b64encode(mac[:24]).decode().rstrip("=")

    def link(mode: str, relpath: str, minutes: int) -> dict[str, Any]:
        minutes = max(1, min(int(minutes), 7 * 24 * 60))
        exp = int(time.time()) + minutes * 60
        path = f"{PREFIX}/{mode}/{exp}/{sign(mode, exp, relpath)}/{urllib.parse.quote(relpath, safe='/')}"
        out: dict[str, Any] = {"url": (public or lan) + path, "lan_url": lan + path, "expires": _fmt_ts(exp)}
        if not public:
            out["note"] = "No public URL configured (installer option 4); this link only works on the LAN."
        return out

    def check(mode: str, exp_s: str, sig: str, relpath: str) -> Path | None:
        """Verify a link; returns the resolved path or None."""
        try:
            exp = int(exp_s)
        except ValueError:
            return None
        if exp < time.time():
            return None
        if not hmac.compare_digest(sign(mode, exp, relpath), sig):
            return None
        try:
            return resolve(relpath)
        except Exception:  # noqa: BLE001
            return None

    # --- Routes (self-authenticated by signature; the token gate lets /files/ through) ----
    @mcp.custom_route(PREFIX + "/d/{exp}/{sig}/{rest:path}", methods=["GET"], include_in_schema=False)
    async def download(request: Request):  # type: ignore[no-untyped-def]
        pp = request.path_params
        p = check("d", pp["exp"], pp["sig"], pp["rest"].strip("/") or ".")
        if p is None:
            return PlainTextResponse("not found", status_code=404)
        if p.is_dir():
            name = (p.name or "share") + ".zip"
            headers = {"Content-Disposition": f"attachment; filename*=UTF-8''{urllib.parse.quote(name)}"}
            return StreamingResponse(_zip_folder(p), media_type="application/zip", headers=headers)
        if not p.is_file():
            return PlainTextResponse("not found", status_code=404)
        return FileResponse(p, filename=p.name, content_disposition_type="attachment")

    @mcp.custom_route(PREFIX + "/u/{exp}/{sig}/{rest:path}", methods=["GET", "PUT"], include_in_schema=False)
    async def upload(request: Request):  # type: ignore[no-untyped-def]
        pp = request.path_params
        rest = pp["rest"].strip("/")
        if request.method == "GET":
            d = check("u", pp["exp"], pp["sig"], rest or ".")
            if d is None or not d.is_dir():
                return PlainTextResponse("not found", status_code=404)
            page = UPLOAD_PAGE.replace("__DIR__", html.escape(rel(d))).replace("__EXP__", html.escape(_fmt_ts(int(pp["exp"]))))
            return HTMLResponse(page)
        # PUT: last path segment is the file name, the signature covers the folder
        if read_only:
            return PlainTextResponse("not found", status_code=404)
        folder, _, raw_name = rest.rpartition("/")
        d = check("u", pp["exp"], pp["sig"], folder or ".")
        if d is None or not d.is_dir():
            return PlainTextResponse("not found", status_code=404)
        try:
            name = _clean_filename(raw_name)
        except ValueError as e:
            return JSONResponse({"error": str(e)}, status_code=400)
        dest = _unique(d / name)
        tmp = d / f".{name}.part"
        size = 0
        try:
            with open(tmp, "wb") as fh:
                async for chunk in request.stream():
                    size += len(chunk)
                    if size > upload_max:
                        raise ValueError(f"File exceeds the {_human(upload_max)} upload cap.")
                    fh.write(chunk)
            os.replace(tmp, dest)
        except ValueError as e:
            tmp.unlink(missing_ok=True)
            return JSONResponse({"error": str(e)}, status_code=413)
        except Exception:  # noqa: BLE001
            tmp.unlink(missing_ok=True)
            return JSONResponse({"error": "upload failed"}, status_code=500)
        return JSONResponse({"saved": rel(dest), "bytes": size}, status_code=201)

    # --- Tools ---------------------------------------------------------------------------
    @guard(RO)
    def download_link(path: str, expires_minutes: int = default_minutes) -> dict[str, Any]:
        """Create a temporary link the user can open in a browser on any device to download a file
        from the share. A folder is delivered as a zip. Give the URL to the user verbatim; it needs
        no login and stops working after expires_minutes (max 7 days). Use this instead of
        read_file_base64 whenever the user wants the actual file.

        Args:
            path: file or folder relative to the share root.
            expires_minutes: how long the link stays valid.
        """
        p = resolve(path)
        out = link("d", rel(p), expires_minutes)
        out["path"] = rel(p)
        if p.is_dir():
            out["delivered_as"] = "zip"
        else:
            out["bytes"] = p.stat().st_size
            out["size"] = _human(p.stat().st_size)
        return out

    def download_link_for(p: Path) -> dict[str, Any]:
        return link("d", rel(p), default_minutes)

    if read_only:
        return download_link_for

    @guard(RW)
    def upload_link(directory: str = ".", expires_minutes: int = default_minutes) -> dict[str, Any]:
        """Create a temporary link that opens an upload page: the user picks or drops files on their
        phone or computer and they land in this folder on the share. Also accepts
        `curl -T <file> "<url>/"`. Give the URL to the user verbatim. Existing names are never
        overwritten; a numbered copy is created instead. Call list_directory afterwards to see
        what arrived.

        Args:
            directory: target folder relative to the share root (created if missing).
            expires_minutes: how long the link stays valid (max 7 days).
        """
        d = resolve(directory, must_exist=False)
        d.mkdir(parents=True, exist_ok=True)
        if not d.is_dir():
            raise NotADirectoryError(f"Not a directory: {directory}")
        out = link("u", rel(d), expires_minutes)
        out["directory"] = rel(d)
        out["max_file_size"] = _human(upload_max)
        out["hint"] = "Behind Cloudflare, uploads above 100 MB need the lan_url."
        return out

    @guard(NET)
    def fetch_url(url: str, destination: str = ".", overwrite: bool = False) -> dict[str, Any]:
        """Download a file from a public http(s) URL straight into the share, without passing the
        bytes through the conversation. Works for direct links and public share links from
        Google Drive (use https://drive.google.com/uc?export=download&id=<id>), Dropbox (?dl=1),
        GitHub releases and similar.

        Args:
            url: http or https URL.
            destination: folder (name taken from the response or URL) or full file path, relative to the share root.
            overwrite: replace an existing file instead of failing.
        """
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError("Only http:// and https:// URLs are supported.")
        _host_is_public(parts.hostname)

        class _Redirects(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
                nu = urllib.parse.urlsplit(newurl)
                if nu.scheme not in ("http", "https") or not nu.hostname:
                    raise urllib.error.URLError("redirect to unsupported scheme")
                _host_is_public(nu.hostname)
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        opener = urllib.request.build_opener(_Redirects())
        req = urllib.request.Request(url, headers={"User-Agent": "mcpshared/1.0"})
        try:
            resp = opener.open(req, timeout=30)
        except urllib.error.HTTPError as e:
            raise ValueError(f"HTTP {e.code} from {parts.hostname}") from e
        except urllib.error.URLError as e:
            raise ValueError(f"Could not fetch: {e.reason}") from e
        with resp:
            dest = resolve(destination, must_exist=False)
            if dest.is_dir() or destination.endswith("/"):
                name = ""
                cd = resp.headers.get("Content-Disposition", "")
                m = re.search(r"filename\*=UTF-8''([^;]+)", cd) or re.search(r'filename="?([^";]+)"?', cd)
                if m:
                    name = m.group(1)
                if not name:
                    name = urllib.parse.urlsplit(resp.geturl()).path.rsplit("/", 1)[-1]
                try:
                    name = _clean_filename(name)
                except ValueError:
                    name = "download"
                dest = dest / name
            if dest.exists() and not overwrite:
                raise FileExistsError(f"Destination exists: {rel(dest)} (pass overwrite=true)")
            dest.parent.mkdir(parents=True, exist_ok=True)
            declared = resp.headers.get("Content-Length")
            if declared and declared.isdigit() and int(declared) > fetch_max:
                raise ValueError(f"Remote file is {_human(int(declared))}, above the {_human(fetch_max)} cap.")
            tmp = dest.with_name(f".{dest.name}.part")
            size = 0
            try:
                with open(tmp, "wb") as fh:
                    while chunk := resp.read(CHUNK):
                        size += len(chunk)
                        if size > fetch_max:
                            raise ValueError(f"Download exceeded the {_human(fetch_max)} cap.")
                        fh.write(chunk)
                os.replace(tmp, dest)
            except BaseException:
                tmp.unlink(missing_ok=True)
                raise
            ctype = resp.headers.get("Content-Type", "")
        result = {"saved": rel(dest), "bytes": size, "size": _human(size), "content_type": ctype.split(";")[0], "final_url": resp.geturl()}
        if ctype.startswith("text/html") and not dest.suffix.lower() in (".html", ".htm"):
            result["warning"] = "The server returned an HTML page, not a file. For Google Drive this usually means the file is not shared publicly or needs the large-file confirmation."
        return result

    return download_link_for
