#!/usr/bin/env python3
# Purpose: MCP server that exposes one shared folder to Claude
# =============================================================================
# Installed by apps/installers/mcp-setup.sh (server id: mcpshared).
# HTTP endpoints, token gate and health check come from ../common.py.
# Document extraction (xlsx / pdf / docx -> text) lives in extraction_tools.py,
# file transfer (signed download / upload links, fetch_url) in transfer.py and
# office file creation (xlsx / docx / pptx / pdf from text) in build_tools.py.
#
# Every path argument is relative to MCP_ROOT and is jailed there: symlinks
# that resolve outside the share are rejected, as are ".." escapes.
#
# Environment (in addition to MCP_TOKEN / MCP_PORT / MCP_HOST, see common.py):
#   MCP_ROOT        directory to expose (required)
#   MCP_READ_ONLY   1 = do not register write tools  (default 0)
#   MCP_NAME        server name shown to Claude      (default "mcpshared")
#   MCP_PUBLIC_URL  https://<host> used in download / upload links (optional)
# =============================================================================

from __future__ import annotations

import base64
import fnmatch
import functools
import os
import shutil
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ImageContent, TextContent, ToolAnnotations

# common.py sits next to server.py once installed (/opt/mcp/<id>/), one level up in the repo.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_HERE, os.path.dirname(_HERE)]
from common import env, env_bool, serve  # noqa: E402
from extraction_tools import register as register_extraction  # noqa: E402
from transfer import register as register_transfer  # noqa: E402
from build_tools import register as register_build  # noqa: E402

# --- Config ------------------------------------------------------------------
READ_ONLY = env_bool("MCP_READ_ONLY", False)
NAME = env("MCP_NAME", "mcpshared")
PUBLIC_URL = env("MCP_PUBLIC_URL", "")
ROOT = Path(os.path.realpath(env("MCP_ROOT", required=True)))
if not ROOT.is_dir():
    sys.exit(f"MCP_ROOT is not a directory: {ROOT}")

MAX_TEXT_CHARS = 200_000          # hard cap on characters returned by read_file
MAX_IMAGE_BYTES = 8 * 1024 * 1024  # view_image cap
MAX_GREP_FILE_BYTES = 5 * 1024 * 1024
MAX_RESULTS = 500
IMAGE_MIME = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp",
}

# --- Path jail ---------------------------------------------------------------
def _resolve(rel: str, *, must_exist: bool = True) -> Path:
    """Map a user-supplied path onto the share and refuse anything outside it."""
    rel = (rel or ".").strip()
    if rel.startswith(str(ROOT)):          # absolute path inside the share is fine
        rel = os.path.relpath(rel, ROOT)
    if os.path.isabs(rel):
        raise ValueError(f"Absolute paths are not allowed. Paths are relative to the share root.")
    candidate = ROOT / rel
    # realpath follows symlinks, so a link pointing outside the share is caught here
    real = Path(os.path.realpath(candidate))
    if real != ROOT and ROOT not in real.parents:
        raise ValueError(f"Path escapes the share: {rel}")
    if must_exist and not real.exists():
        raise FileNotFoundError(f"Not found: {rel}")
    return real


def _rel(p: Path) -> str:
    r = os.path.relpath(p, ROOT)
    return "." if r == "." else r.replace(os.sep, "/")


def _fmt_time(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def _human(n: int) -> str:
    f = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or unit == "TB":
            return f"{f:.0f} {unit}" if unit == "B" else f"{f:.1f} {unit}"
        f /= 1024
    return f"{n} B"


def _entry(p: Path) -> dict[str, Any]:
    st = p.lstat()
    kind = "dir" if stat.S_ISDIR(st.st_mode) else "link" if stat.S_ISLNK(st.st_mode) else "file"
    return {
        "path": _rel(p),
        "name": p.name,
        "type": kind,
        "size": st.st_size if kind == "file" else None,
        "size_human": _human(st.st_size) if kind == "file" else None,
        "modified": _fmt_time(st.st_mtime),
    }


def _is_binary(sample: bytes) -> bool:
    return b"\x00" in sample


def _require_write() -> None:
    if READ_ONLY:
        raise PermissionError("This share is exposed read-only.")


# --- Server ------------------------------------------------------------------
mcp = MCPServer(
    NAME,
    instructions=(
        f"Filesystem access to the shared folder '{ROOT.name}'"
        f"{' (read-only)' if READ_ONLY else ' (read/write)'}. "
        "All paths are relative to the share root ('.'). Start with list_directory "
        "or search_files to find things; use read_file for text and view_image for pictures. "
        "Office files are unpacked on the server: list_sheets / read_sheet / extract_sheet_images "
        "for xlsx, extract_pdf_text for pdf, extract_docx_text for docx. Never read those with "
        "read_file_base64; view_pdf_page shows a page as a picture. To hand the user an actual "
        "file use download_link; to let them add files use upload_link; fetch_url pulls a public "
        "URL into the share. To deliver a document, build_docx / build_xlsx / build_pptx / "
        "build_pdf create the real file and return its download link."
    ),
)

def tool(annotations: ToolAnnotations):
    """Register a tool and surface exceptions to Claude as readable messages (not a generic error)."""
    def deco(fn):
        @functools.wraps(fn)
        def guarded(*a, **kw):
            try:
                return fn(*a, **kw)
            except ToolError:
                raise
            except Exception as e:  # noqa: BLE001
                # never leak the host path in error text
                raise ToolError(f"{type(e).__name__}: {str(e).replace(str(ROOT), '<share>')}") from e
        return mcp.tool(annotations=annotations)(guarded)
    return deco


RO = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
RW = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
DESTRUCTIVE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False)


@tool(RO)
def list_directory(path: str = ".", show_hidden: bool = False, limit: int = MAX_RESULTS) -> dict[str, Any]:
    """List files and folders directly inside a directory (non-recursive).

    Args:
        path: directory relative to the share root. "." is the root.
        show_hidden: include dot-files.
        limit: maximum entries to return.
    """
    d = _resolve(path)
    if not d.is_dir():
        raise NotADirectoryError(f"Not a directory: {path}")
    items = sorted(d.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
    if not show_hidden:
        items = [p for p in items if not p.name.startswith(".")]
    total = len(items)
    entries = [_entry(p) for p in items[: max(1, limit)]]
    return {"path": _rel(d), "total": total, "returned": len(entries), "entries": entries}


@tool(RO)
def directory_tree(path: str = ".", max_depth: int = 2, show_hidden: bool = False) -> str:
    """Show a compact tree of a directory down to max_depth levels (dirs only beyond depth 1 are still shown)."""
    root = _resolve(path)
    if not root.is_dir():
        raise NotADirectoryError(f"Not a directory: {path}")
    lines = [_rel(root) + "/"]
    count = 0

    def walk(d: Path, depth: int, prefix: str) -> None:
        nonlocal count
        if depth > max_depth or count > MAX_RESULTS:
            return
        try:
            kids = sorted(d.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except PermissionError:
            lines.append(prefix + "[permission denied]")
            return
        if not show_hidden:
            kids = [k for k in kids if not k.name.startswith(".")]
        for i, k in enumerate(kids):
            count += 1
            if count > MAX_RESULTS:
                lines.append(prefix + "... (truncated)")
                return
            last = i == len(kids) - 1
            branch = "└── " if last else "├── "
            if k.is_dir() and not k.is_symlink():
                lines.append(f"{prefix}{branch}{k.name}/")
                walk(k, depth + 1, prefix + ("    " if last else "│   "))
            else:
                size = f"  ({_human(k.stat().st_size)})" if k.is_file() else ""
                lines.append(f"{prefix}{branch}{k.name}{size}")

    walk(root, 1, "")
    return "\n".join(lines)


@tool(RO)
def search_files(pattern: str, path: str = ".", limit: int = 200) -> dict[str, Any]:
    """Find files and folders whose name matches a glob pattern, searching recursively.

    Args:
        pattern: case-insensitive glob, e.g. "*.pdf", "invoice*", "*2024*".
        path: directory to start from (relative to share root).
        limit: maximum matches to return.
    """
    start = _resolve(path)
    pat = pattern.lower()
    hits: list[dict[str, Any]] = []
    for dirpath, dirnames, filenames in os.walk(start):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in dirnames + filenames:
            if fnmatch.fnmatch(name.lower(), pat):
                hits.append(_entry(Path(dirpath) / name))
                if len(hits) >= limit:
                    return {"pattern": pattern, "truncated": True, "matches": hits}
    return {"pattern": pattern, "truncated": False, "matches": hits}


@tool(RO)
def search_content(query: str, path: str = ".", file_glob: str = "*", case_sensitive: bool = False, limit: int = 100) -> dict[str, Any]:
    """Search inside text files for a substring and return matching lines with file and line number.

    Args:
        query: text to look for (plain substring, not regex).
        path: directory to search recursively (relative to share root).
        file_glob: only search files whose name matches, e.g. "*.md" or "*.txt".
        case_sensitive: match case exactly.
        limit: maximum matching lines to return.
    """
    start = _resolve(path)
    needle = query if case_sensitive else query.lower()
    hits: list[dict[str, Any]] = []
    scanned = 0
    for dirpath, dirnames, filenames in os.walk(start):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if not fnmatch.fnmatch(name.lower(), file_glob.lower()):
                continue
            p = Path(dirpath) / name
            try:
                if p.stat().st_size > MAX_GREP_FILE_BYTES:
                    continue
                with open(p, "rb") as fh:
                    head = fh.read(4096)
                    if _is_binary(head):
                        continue
                    data = head + fh.read()
            except OSError:
                continue
            scanned += 1
            for no, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
                hay = line if case_sensitive else line.lower()
                if needle in hay:
                    hits.append({"file": _rel(p), "line": no, "text": line.strip()[:300]})
                    if len(hits) >= limit:
                        return {"query": query, "files_scanned": scanned, "truncated": True, "matches": hits}
    return {"query": query, "files_scanned": scanned, "truncated": False, "matches": hits}


@tool(RO)
def get_file_info(path: str) -> dict[str, Any]:
    """Return size, timestamps, type and permissions for a file or directory."""
    p = _resolve(path)
    st = p.stat()
    info = _entry(p)
    info.update({
        "created": _fmt_time(st.st_ctime),
        "accessed": _fmt_time(st.st_atime),
        "permissions": oct(st.st_mode & 0o777),
        "owner_uid": st.st_uid,
        "is_symlink": p.is_symlink(),
    })
    if p.is_dir():
        kids = list(p.iterdir())
        info["children"] = len(kids)
    return info


@tool(RO)
def read_file(path: str, start_line: int = 1, max_lines: int = 500) -> str:
    """Read a text file. Large files are paged: pass start_line to continue.

    Args:
        path: file relative to the share root.
        start_line: first line to return (1-based).
        max_lines: how many lines to return.
    """
    p = _resolve(path)
    if not p.is_file():
        raise IsADirectoryError(f"Not a file: {path}")
    with open(p, "rb") as fh:
        head = fh.read(4096)
        if _is_binary(head):
            size = _human(p.stat().st_size)
            hint = "Use view_image for pictures." if p.suffix.lower() in IMAGE_MIME else "Use read_file_base64 if you need the raw bytes."
            return f"[binary file, {size}] {hint}"
        data = head + fh.read()
    lines = data.decode("utf-8", errors="replace").splitlines()
    total = len(lines)
    start = max(1, start_line)
    chunk = lines[start - 1 : start - 1 + max(1, max_lines)]
    text = "\n".join(chunk)
    truncated = False
    if len(text) > MAX_TEXT_CHARS:
        text = text[:MAX_TEXT_CHARS]
        truncated = True
    end = start + len(chunk) - 1
    footer = f"\n\n[lines {start}-{end} of {total}]"
    if end < total:
        footer += f" (continue with start_line={end + 1})"
    if truncated:
        footer += " [output truncated at character cap]"
    return text + footer


@tool(RO)
def read_file_base64(path: str, max_bytes: int = 2_000_000) -> dict[str, Any]:
    """Return the raw bytes of a small binary file as base64 (capped by max_bytes)."""
    p = _resolve(path)
    if not p.is_file():
        raise IsADirectoryError(f"Not a file: {path}")
    size = p.stat().st_size
    if size > max_bytes:
        raise ValueError(f"File is {_human(size)}, above the {_human(max_bytes)} cap.")
    return {"path": _rel(p), "size": size, "base64": base64.b64encode(p.read_bytes()).decode()}


@tool(RO)
def view_image(path: str) -> list[ImageContent | TextContent]:
    """Return an image file (png, jpg, gif, webp) so Claude can look at it. Capped at 8 MB."""
    p = _resolve(path)
    mime = IMAGE_MIME.get(p.suffix.lower())
    if not p.is_file() or not mime:
        raise ValueError("Not a supported image (png, jpg, jpeg, gif, webp).")
    size = p.stat().st_size
    if size > MAX_IMAGE_BYTES:
        raise ValueError(f"Image is {_human(size)}, above the {_human(MAX_IMAGE_BYTES)} cap.")
    return [
        TextContent(type="text", text=f"{_rel(p)} ({_human(size)})"),
        ImageContent(type="image", data=base64.b64encode(p.read_bytes()).decode(), mimeType=mime),
    ]


@tool(RO)
def disk_usage() -> dict[str, Any]:
    """Free and used space on the drive that holds the share."""
    u = shutil.disk_usage(ROOT)
    return {
        "share": str(ROOT),
        "total": _human(u.total),
        "used": _human(u.used),
        "free": _human(u.free),
        "used_percent": round(u.used / u.total * 100, 1) if u.total else None,
        "read_only": READ_ONLY,
    }


# --- Write tools (only when not read-only) -----------------------------------
if not READ_ONLY:

    @tool(RW)
    def write_file(path: str, content: str, append: bool = False) -> dict[str, Any]:
        """Create or overwrite a text file (UTF-8). Set append=true to add to the end instead.
        Parent folders are created as needed."""
        _require_write()
        p = _resolve(path, must_exist=False)
        if p.is_dir():
            raise IsADirectoryError(f"Is a directory: {path}")
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a" if append else "w", encoding="utf-8") as fh:
            fh.write(content)
        return {"written": _rel(p), "bytes": p.stat().st_size, "append": append}

    @tool(RW)
    def create_directory(path: str) -> dict[str, Any]:
        """Create a folder (and any missing parents)."""
        _require_write()
        p = _resolve(path, must_exist=False)
        p.mkdir(parents=True, exist_ok=True)
        return {"created": _rel(p)}

    @tool(RW)
    def move_path(source: str, destination: str, overwrite: bool = False) -> dict[str, Any]:
        """Move or rename a file or folder inside the share."""
        _require_write()
        src = _resolve(source)
        dst = _resolve(destination, must_exist=False)
        if dst.is_dir():
            dst = dst / src.name
        if dst.exists() and not overwrite:
            raise FileExistsError(f"Destination exists: {_rel(dst)} (pass overwrite=true)")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        return {"moved": _rel(src), "to": _rel(dst)}

    @tool(RW)
    def copy_path(source: str, destination: str, overwrite: bool = False) -> dict[str, Any]:
        """Copy a file or folder to another location inside the share."""
        _require_write()
        src = _resolve(source)
        dst = _resolve(destination, must_exist=False)
        if dst.is_dir() and not (src.is_dir() and dst == src):
            dst = dst / src.name
        if dst.exists() and not overwrite:
            raise FileExistsError(f"Destination exists: {_rel(dst)} (pass overwrite=true)")
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=overwrite)
        else:
            shutil.copy2(src, dst)
        return {"copied": _rel(src), "to": _rel(dst)}

    @tool(DESTRUCTIVE)
    def delete_path(path: str, recursive: bool = False) -> dict[str, Any]:
        """Delete a file or an empty folder. Set recursive=true to delete a folder with contents.
        The share root itself can never be deleted."""
        _require_write()
        p = _resolve(path)
        if p == ROOT:
            raise PermissionError("Refusing to delete the share root.")
        if p.is_dir() and not p.is_symlink():
            if recursive:
                shutil.rmtree(p)
            else:
                p.rmdir()  # raises if not empty
        else:
            p.unlink()
        return {"deleted": _rel(p), "recursive": recursive}


# --- Document extraction (xlsx / pdf / docx -> text) ---------------------------
register_extraction(mcp, _resolve, rel=_rel, guard=tool, read_only=READ_ONLY)

# --- File transfer (signed links, fetch_url) ----------------------------------
download_link_for = register_transfer(
    mcp, _resolve, rel=_rel, guard=tool, read_only=READ_ONLY,
    token=env("MCP_TOKEN", required=True), public_url=PUBLIC_URL, port=int(env("MCP_PORT", "8765")),
)

# --- Build office files from text (write mode only) ----------------------------
if not READ_ONLY:
    register_build(mcp, _resolve, rel=_rel, guard=tool, link=download_link_for)


# --- Run ---------------------------------------------------------------------
if __name__ == "__main__":
    print(f"[mcp] {NAME}: serving {ROOT} {'read-only' if READ_ONLY else 'read/write'}", flush=True)
    serve(mcp, extra_health={"read_only": READ_ONLY}, open_prefixes=("/files/",))
