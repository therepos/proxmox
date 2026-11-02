# Purpose: password-protected 7z transfer archives for mcpshared (zip, unzip, split sets)
# =============================================================================
# Loaded by server.py (write mode only):
#
#     from zip_tools import register as register_zip
#     register_zip(mcp, _resolve, rel=_rel, guard=tool, link=download_link_for)
#
#   unzip_transfer(path, destination, password) 7z or zip, no extension needed, any part of a .001 set
#   zip_transfer(paths, destination, split_mb)  encrypted 7z (names hidden), split over split_mb
#   zip_password(action, password)              set / forget / status of the saved password
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

from pathlib import Path
from typing import Any, Callable, Literal

from mcp.types import ToolAnnotations

import zipper

RW = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
MAX_LISTED = 200
NEED_PASSWORD = {
    "need_password": True,
    "next": "Use the zip password from the user's preferences if given, otherwise ask the user; "
            "save it with zip_password(action='set', password=...), then retry.",
}


def register(
    mcp,  # type: ignore[no-untyped-def]
    resolve: Callable[..., Path],
    *,
    rel: Callable[[Path], str],
    guard: Callable[[ToolAnnotations], Callable],
    link: Callable[[Path], dict[str, Any]],
) -> None:

    @guard(RW)
    def unzip_transfer(path: str, destination: str | None = None, password: str | None = None) -> dict[str, Any]:
        """Extract one of the user's transfer archives: a 7z or zip, usually with no extension
        (e.g. 20261102-143015), or a split set (20261102-143015.001, .002, ...). Pass any part of
        a split set; the other parts must be in the same folder. One level of nested archives is
        extracted too. If the result says need_password, get the password, save it with
        zip_password and call again.

        Args:
            path: archive (or any part of a split set) relative to the share root.
            destination: target folder relative to the share root. Default: "<name>-extracted" next to it.
            password: only when the user just gave one; saved for next time if none is saved.
        """
        name, parts = zipper.resolve_set(str(resolve(path, must_exist=False)))   # ValueError -> readable error
        parts = [resolve(rel(x)) for x in parts]                                   # every part inside the share
        dest = resolve(destination or rel(parts[0].parent / f"{name}-extracted"), must_exist=False)
        try:
            used, warnings = zipper.extract_all(parts, dest, zipper.known_password(password))
        except zipper.NeedPassword:
            return {"archive": rel(parts[0]), **NEED_PASSWORD}
        if password:
            zipper.remember_password(used)
        files = sorted(rel(f) for f in dest.rglob("*") if f.is_file())
        out: dict[str, Any] = {
            "archive": rel(parts[0]), "parts": len(parts), "destination": rel(dest),
            "count": len(files), "files": files[:MAX_LISTED],
        }
        if warnings:
            out["warnings"] = warnings
        if len(files) > MAX_LISTED:
            out["note"] = f"{len(files) - MAX_LISTED} more files; use list_directory."
        return out

    @guard(RW)
    def zip_transfer(paths: list[str], destination: str | None = None, split_mb: int | None = None) -> dict[str, Any]:
        """Pack files/folders into the user's transfer format: a password-protected 7z with file
        names hidden, named YYYYMMDD-HHMMSS (no extension), split into .001, .002, ... parts when
        larger than split_mb. Returns download links. If the result says need_password, get the
        password, save it with zip_password and call again.

        Args:
            paths: files or folders relative to the share root.
            destination: folder for the archive. Default: the folder of the first path.
            split_mb: part size in MB (0 = never split). Default: saved setting, else 500.
        """
        targets = list(dict.fromkeys(resolve(p) for p in paths))
        if not targets:
            raise ValueError("Pass at least one path.")
        out_dir = resolve(destination, must_exist=False) if destination else targets[0].parent
        try:
            made = zipper.create_archive(targets, out_dir, zipper.known_password(), split_mb)
        except zipper.NeedPassword:
            return dict(NEED_PASSWORD)
        out: dict[str, Any] = {"files": [rel(f) for f in made], "links": [link(f) for f in made]}
        if len(made) > 1:
            out["note"] = "Keep all parts together to unzip."
        return out

    @guard(RW)
    def zip_password(action: Literal["set", "forget", "status"], password: str | None = None) -> dict[str, Any]:
        """Manage the saved password used by zip_transfer / unzip_transfer. The password is never
        returned. Use 'set' when the user gives or changes their zip password, 'forget' to remove it,
        'status' to check whether one is saved."""
        if action == "set":
            if not password:
                raise ValueError("password is required for action='set'.")
            zipper.set_password(password)
        elif action == "forget":
            zipper.set_password(None)
        return {"password": zipper.password_state()}
