# Purpose: password-protected 7z transfer archives for mcpshared (zip, unzip, split sets)
# =============================================================================
# Loaded by server.py (write mode only):
#
#     from zip_tools import register as register_zip
#     register_zip(mcp, _resolve, rel=_rel, guard=tool, link=download_link_for)
#
#   unzip_transfer(path, destination)          7z or zip, no extension needed, any part of a .001 set
#   zip_transfer(paths, destination, split_mb) encrypted 7z (names hidden), split over split_mb
#   zip_password(action, password)             set / forget / status of the saved password
#
# The engine is zipper.py, a copy of therepos/skills zipper/scripts/zipper.py
# (edit it there, then re-copy). It uses a 7z binary when the host has one
# (optional APT p7zip-full) and py7zr otherwise (PIP_mcpshared, imported lazily).
#
# Environment:
#   ZIPPER_PASSWORD   password to use (optional; normally saved via zip_password)
#   ZIPPER_CONFIG     settings file; the installer points it at /var/lib/mcp/mcpshared/
# =============================================================================

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Callable, Literal

from mcp.types import ToolAnnotations

import zipper

RW = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
MAX_LISTED = 200
NEED_PASSWORD = {
    "need_password": True,
    "next": "Ask the user for their zip password, call zip_password(action='set', password=...), then retry.",
}


def register(
    mcp,  # type: ignore[no-untyped-def]
    resolve: Callable[..., Path],
    *,
    rel: Callable[[Path], str],
    guard: Callable[[ToolAnnotations], Callable],
    link: Callable[[Path], dict[str, Any]],
) -> None:

    def _drop_symlinks(folder: Path) -> None:
        # an archive may carry symlinks that point outside the share
        for p in sorted(folder.rglob("*"), reverse=True):
            if p.is_symlink():
                p.unlink()

    @guard(RW)
    def unzip_transfer(path: str, destination: str | None = None, password: str | None = None) -> dict[str, Any]:
        """Extract one of the user's transfer archives: a 7z or zip, usually with no extension
        (e.g. 20261102-143015), or a split set (20261102-143015.001, .002, ...). Pass any part of
        a split set; the other parts must be in the same folder. One level of nested archives is
        extracted too. If the result says need_password, ask the user, save it with zip_password
        and call again.

        Args:
            path: archive (or any part of a split set) relative to the share root.
            destination: target folder relative to the share root. Default: "<name>-extracted" next to it.
            password: only when the user just gave one; it is saved for next time if none is saved.
        """
        p = resolve(path, must_exist=False)
        try:
            name, parts = zipper.resolve_set(str(p))
        except ValueError as e:
            raise FileNotFoundError(str(e).replace(str(p.parent), "")) from None
        parts = [resolve(rel(x)) for x in parts]                     # keep every part inside the share
        dest = resolve(destination, must_exist=False) if destination else resolve(rel(parts[0].parent / f"{name}-extracted"), must_exist=False)
        try:
            used = zipper.extract(parts, dest, zipper.known_password(password))
        except zipper.NeedPassword:
            return {"archive": rel(parts[0]), **NEED_PASSWORD}
        if password and used:
            zipper.remember_password(used)
        _drop_symlinks(dest)
        for f in list(dest.rglob("*")):                               # one level of nested archives
            if f.is_file() and not f.name.lower().endswith(zipper.OFFICE_EXT) and zipper.kind([f]) in ("7z", "zip"):
                try:
                    sub = f.with_name(f.stem + "_extracted")
                    zipper.extract([f], sub, used or zipper.known_password(None))
                    _drop_symlinks(sub)
                except (zipper.NeedPassword, RuntimeError):
                    pass
        files = sorted(rel(f) for f in dest.rglob("*") if f.is_file())
        out: dict[str, Any] = {
            "archive": rel(parts[0]), "parts": len(parts), "destination": rel(dest),
            "count": len(files), "files": files[:MAX_LISTED],
        }
        if len(files) > MAX_LISTED:
            out["note"] = f"{len(files) - MAX_LISTED} more files; use list_directory."
        return out

    @guard(RW)
    def zip_transfer(paths: list[str], destination: str | None = None, split_mb: int | None = None) -> dict[str, Any]:
        """Pack files/folders into the user's transfer format: a password-protected 7z with file
        names hidden, named YYYYMMDD-HHMMSS (no extension), split into .001, .002, ... parts when
        larger than split_mb. Returns download links. If the result says need_password, ask the
        user, save it with zip_password and call again.

        Args:
            paths: files or folders relative to the share root.
            destination: folder for the archive. Default: the folder of the first path.
            split_mb: part size in MB (0 = never split). Default: saved setting, else 500.
        """
        pw = zipper.known_password(None)
        if not pw:
            return dict(NEED_PASSWORD)
        targets = []
        for raw in paths:
            t = resolve(raw)
            if t not in targets:
                targets.append(t)
        if not targets:
            raise ValueError("Pass at least one path.")
        out_dir = resolve(destination, must_exist=False) if destination else targets[0].parent
        size = split_mb if split_mb is not None else int(zipper.load_config().get("split_mb", zipper.DEFAULT_SPLIT_MB))
        made = zipper.create_archive(targets, out_dir, pw, max(0, size))
        return {
            "files": [rel(f) for f in made],
            "links": [link(f) for f in made],
            "note": "Keep all parts together to unzip." if len(made) > 1 else "",
        }

    @guard(RW)
    def zip_password(action: Literal["set", "forget", "status"], password: str | None = None) -> dict[str, Any]:
        """Manage the saved password used by zip_transfer / unzip_transfer. The password is never
        returned. Use 'set' when the user gives or changes their zip password, 'forget' to remove it,
        'status' to check whether one is saved."""
        cfg = zipper.load_config()
        if action == "set":
            if not password:
                raise ValueError("password is required for action='set'.")
            cfg["password"] = password
            zipper.save_config(cfg)
            return {"password": "saved"}
        if action == "forget":
            cfg.pop("password", None)
            zipper.save_config(cfg)
            return {"password": "removed"}
        return {"password": "saved" if cfg.get("password") or os.environ.get("ZIPPER_PASSWORD") else "not saved"}
