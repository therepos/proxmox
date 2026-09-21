# Purpose: archives, OCR and office-to-PDF conversion for mcpshared
# =============================================================================
# Loaded by server.py:
#
#     from host_tools import register as register_host
#     register_host(mcp, _resolve, rel=_rel, guard=tool, read_only=READ_ONLY, link=download_link_for)
#
#   list_archive(path)                  members of a zip / tar archive (stdlib)
#   extract_archive(path, members, to)  unpack selected members into the share (stdlib)
#   ocr_text(path, pages, lang)         text from scanned PDFs and images (tesseract)
#   convert_to_pdf(path, destination)   docx / xlsx / pptx / odt ... -> PDF (LibreOffice)
#
# ocr_text and convert_to_pdf shell out to host programs that the installer
# offers as optional apt packages (tesseract-ocr, libreoffice-*). When the
# program is missing the tool says so; nothing else is affected.
#
# Environment:
#   MCP_EXTRACT_MAX_BYTES   cap on bytes unpacked per extract_archive call (default 4 GiB)
#   MCP_OCR_LANG            default tesseract language (default "eng")
# =============================================================================

from __future__ import annotations

import fnmatch
import io
import os
import posixpath
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Callable

from mcp.types import ToolAnnotations

MAX_CHARS = 100_000
MAX_MEMBERS_LISTED = 2000
MAX_OCR_PAGES = 20
ARCHIVE_EXT = (".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")
CONVERTIBLE = {
    ".docx", ".doc", ".odt", ".rtf", ".txt", ".html", ".htm",
    ".xlsx", ".xls", ".ods", ".csv",
    ".pptx", ".ppt", ".odp",
}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp"}

RO = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
RW = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        return int(raw) if raw else default
    except ValueError:
        return default


def _human(n: int) -> str:
    f = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or unit == "TB":
            return f"{f:.0f} {unit}" if unit == "B" else f"{f:.1f} {unit}"
        f /= 1024
    return f"{n} B"


def _cap(text: str, limit: int, hint: str = "") -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n\n[output truncated at {limit:,} characters] {hint}".rstrip()


def _need_prog(name: str, package: str):  # type: ignore[no-untyped-def]
    exe = shutil.which(name)
    if not exe:
        raise RuntimeError(
            f"{name} is not installed on the host. Re-run the installer (Update server) and accept the "
            f"optional '{package}' package."
        )
    return exe


def _safe_member(name: str) -> str | None:
    """Archive member name -> safe relative path, or None if it must be skipped (zip-slip)."""
    n = name.replace("\\", "/").lstrip("/")
    if not n or n.endswith("/"):
        return None
    parts = [p for p in posixpath.normpath(n).split("/") if p not in ("", ".")]
    if not parts or ".." in parts:
        return None
    return "/".join(parts)


def _is_tar(p: Path) -> bool:
    return p.name.lower().endswith(ARCHIVE_EXT[1:])


def _parse_pages(spec: str | None, total: int) -> list[int]:
    if not spec or not spec.strip():
        return list(range(1, total + 1))
    out: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, _, b = part.partition("-")
            lo, hi = (int(a) if a.strip() else 1), (int(b) if b.strip() else total)
        else:
            lo = hi = int(part)
        if lo < 1 or hi < lo:
            raise ValueError(f"Bad page range: {part!r}")
        out.extend(range(lo, min(hi, total) + 1))
    seen: set[int] = set()
    return [p for p in out if not (p in seen or seen.add(p))]  # type: ignore[func-returns-value]


# --- Registration ------------------------------------------------------------
def register(
    mcp,  # type: ignore[no-untyped-def]
    resolve: Callable[..., Path],
    *,
    rel: Callable[[Path], str],
    guard: Callable[[ToolAnnotations], Callable],
    read_only: bool,
    link: Callable[[Path], dict[str, Any]],
) -> None:
    extract_max = _int_env("MCP_EXTRACT_MAX_BYTES", 4 << 30)
    ocr_lang_default = os.environ.get("MCP_OCR_LANG", "").strip() or "eng"

    def _archive(path: str) -> Path:
        p = resolve(path)
        if not p.is_file():
            raise IsADirectoryError(f"Not a file: {path}")
        if not p.name.lower().endswith(ARCHIVE_EXT):
            raise ValueError(f"Not a supported archive (zip, tar, tar.gz, tar.bz2, tar.xz): {path}")
        return p

    # --- archives ------------------------------------------------------------------
    @guard(RO)
    def list_archive(path: str, pattern: str = "*", limit: int = 500) -> dict[str, Any]:
        """List the members of a zip or tar archive without unpacking it: name, size, modified.
        Works on multi-GB archives because only the index is read.

        Args:
            path: archive relative to the share root.
            pattern: case-insensitive glob on the member path, e.g. "*.pdf" or "2025/*".
            limit: maximum members to return.
        """
        p = _archive(path)
        pat = pattern.lower()
        members: list[dict[str, Any]] = []
        total = matched = 0
        total_bytes = 0
        if _is_tar(p):
            with tarfile.open(p, "r:*") as tf:
                for m in tf:
                    if not m.isfile():
                        continue
                    total += 1
                    total_bytes += m.size
                    if fnmatch.fnmatch(m.name.lower(), pat):
                        matched += 1
                        if len(members) < limit:
                            members.append({"name": m.name, "size": m.size, "size_human": _human(m.size)})
                    if total > MAX_MEMBERS_LISTED * 50:
                        break
        else:
            with zipfile.ZipFile(p) as zf:
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    total += 1
                    total_bytes += info.file_size
                    if fnmatch.fnmatch(info.filename.lower(), pat):
                        matched += 1
                        if len(members) < limit:
                            d = info.date_time
                            members.append({
                                "name": info.filename, "size": info.file_size, "size_human": _human(info.file_size),
                                "modified": f"{d[0]:04d}-{d[1]:02d}-{d[2]:02d} {d[3]:02d}:{d[4]:02d}",
                            })
        return {
            "path": rel(p), "archive_bytes": p.stat().st_size, "files": total, "uncompressed": _human(total_bytes),
            "matched": matched, "returned": len(members), "truncated": matched > len(members), "members": members,
            "next": "extract_archive(path, members=[...], destination=...) unpacks what you need.",
        }

    if not read_only:

        @guard(RW)
        def extract_archive(
            path: str,
            members: list[str] | None = None,
            destination: str | None = None,
            overwrite: bool = False,
        ) -> dict[str, Any]:
            """Unpack members of a zip or tar archive into a folder on the share. Pass exact member
            names or globs (e.g. ["reports/*.pdf"]); omit members to unpack everything. Paths that
            try to escape the destination are skipped.

            Args:
                path: archive relative to the share root.
                members: member names or globs. Default: all.
                destination: target folder relative to the share root. Default: "<archive folder>/<archive name>/".
                overwrite: replace files that already exist.
            """
            p = _archive(path)
            stem = p.name
            for ext in sorted(ARCHIVE_EXT, key=len, reverse=True):
                if stem.lower().endswith(ext):
                    stem = stem[: -len(ext)]
                    break
            dest = resolve(destination, must_exist=False) if destination else resolve(rel(p.parent / stem), must_exist=False)
            if dest.exists() and not dest.is_dir():
                raise NotADirectoryError(f"Destination is not a folder: {rel(dest)}")
            dest.mkdir(parents=True, exist_ok=True)
            pats = [m.lower() for m in (members or ["*"])]

            def wanted(name: str) -> bool:
                n = name.lower()
                return any(n == m or fnmatch.fnmatch(n, m) for m in pats)

            written: list[str] = []
            skipped: list[str] = []
            total = 0

            def store(name: str, size: int, opener: Callable[[], Any]) -> None:
                nonlocal total
                safe = _safe_member(name)
                if safe is None:
                    skipped.append(f"{name}: unsafe path")
                    return
                target = dest / safe
                if target.exists() and not overwrite:
                    skipped.append(f"{safe}: exists")
                    return
                total += size
                if total > extract_max:
                    raise ValueError(f"Extraction exceeds the {_human(extract_max)} cap; pick fewer members.")
                target.parent.mkdir(parents=True, exist_ok=True)
                src = opener()
                if src is None:
                    skipped.append(f"{safe}: unreadable")
                    return
                with src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
                written.append(rel(target))

            if _is_tar(p):
                with tarfile.open(p, "r:*") as tf:
                    for m in tf:
                        if m.isfile() and wanted(m.name):
                            store(m.name, m.size, lambda m=m: tf.extractfile(m))
            else:
                with zipfile.ZipFile(p) as zf:
                    for info in zf.infolist():
                        if not info.is_dir() and wanted(info.filename):
                            store(info.filename, info.file_size, lambda info=info: zf.open(info))
            out: dict[str, Any] = {
                "archive": rel(p), "destination": rel(dest), "written": len(written), "bytes": total,
                "files": written[:200], "skipped": skipped[:50],
            }
            if len(written) > 200:
                out["note"] = f"{len(written) - 200} more files written; use list_directory."
            if not written and not skipped:
                out["note"] = "No member matched."
            return out

    # --- OCR -----------------------------------------------------------------------
    @guard(RO)
    def ocr_text(path: str, pages: str | None = None, lang: str = ocr_lang_default, dpi: int = 200) -> str:
        """Read text out of a scanned PDF or an image (png, jpg, tif...) with OCR. Use when
        extract_pdf_text reports scanned pages, or to read a screenshot. Up to 20 pages per call.

        Args:
            path: PDF or image relative to the share root.
            pages: PDF pages, 1-based, e.g. "1-3,7". Default: first 20.
            lang: tesseract language code(s), e.g. "eng" or "eng+chi_sim" (extra languages need their apt package).
            dpi: render resolution for PDFs (150-300).
        """
        tesseract = _need_prog("tesseract", "tesseract-ocr")
        p = resolve(path)
        if not p.is_file():
            raise IsADirectoryError(f"Not a file: {path}")
        if not lang.replace("+", "").replace("_", "").isalnum():
            raise ValueError("Bad language code.")

        def run(png: bytes) -> str:
            r = subprocess.run([tesseract, "-", "-", "-l", lang, "--psm", "3"], input=png, capture_output=True, timeout=120)
            if r.returncode != 0:
                err = r.stderr.decode("utf-8", "replace").strip().splitlines()
                raise RuntimeError("tesseract failed: " + (err[-1] if err else "unknown error"))
            return r.stdout.decode("utf-8", "replace").strip()

        ext = p.suffix.lower()
        if ext in IMAGE_EXT:
            from PIL import Image  # bundled with pdfplumber
            img = Image.open(p)
            img.load()
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            buf = io.BytesIO()
            img.save(buf, "PNG")
            text = run(buf.getvalue())
            return _cap(text or "[no text recognised]", MAX_CHARS) + f"\n\n[ocr {lang}, {img.width}x{img.height}px]"
        if ext != ".pdf":
            raise ValueError("ocr_text handles PDFs and images (png, jpg, tif, bmp, gif, webp).")
        try:
            import pdfplumber
        except ImportError as e:
            raise RuntimeError("pdfplumber is not installed; re-run the installer (Update server).") from e
        dpi = max(150, min(int(dpi), 300))
        chunks: list[str] = []
        used = 0
        with pdfplumber.open(p) as pdf:
            total = len(pdf.pages)
            wanted = _parse_pages(pages, total)
            if len(wanted) > MAX_OCR_PAGES:
                wanted = wanted[:MAX_OCR_PAGES]
            for n in wanted:
                img = pdf.pages[n - 1].to_image(resolution=dpi).original.convert("L")
                buf = io.BytesIO()
                img.save(buf, "PNG")
                text = run(buf.getvalue()) or "[no text recognised]"
                block = f"--- page {n} of {total} ---\n{text}"
                chunks.append(block)
                used += len(block)
                if used > MAX_CHARS:
                    break
        body = _cap("\n\n".join(chunks), MAX_CHARS, 'Request fewer pages with pages="a-b".')
        tail = f"[ocr {lang}, {len(chunks)} of {total} pages"
        if len(wanted) < total and not pages:
            tail += f"; continue with pages=\"{wanted[-1] + 1}-\""
        return body + "\n\n" + tail + "]"

    # --- office -> PDF ---------------------------------------------------------------
    if not read_only:

        @guard(RW)
        def convert_to_pdf(path: str, destination: str | None = None, overwrite: bool = False) -> dict[str, Any]:
            """Convert a Word, Excel, PowerPoint or OpenDocument file to PDF with LibreOffice and return
            a download link. Layout matches what the office application would print.

            Args:
                path: source file relative to the share root (docx, doc, xlsx, xls, pptx, ppt, odt, ods, odp, rtf, csv, txt, html).
                destination: target .pdf path or folder relative to the share root. Default: next to the source.
                overwrite: replace an existing PDF.
            """
            soffice = shutil.which("soffice") or shutil.which("libreoffice")
            if not soffice:
                raise RuntimeError(
                    "LibreOffice is not installed on the host. Re-run the installer (Update server) and accept the "
                    "optional LibreOffice package, or use build_pdf for markdown content."
                )
            src = resolve(path)
            if not src.is_file():
                raise IsADirectoryError(f"Not a file: {path}")
            if src.suffix.lower() not in CONVERTIBLE:
                raise ValueError(f"Cannot convert {src.suffix or 'this file'} to PDF.")
            if destination:
                dest = resolve(destination, must_exist=False)
                if dest.is_dir() or destination.endswith("/"):
                    dest = dest / (src.stem + ".pdf")
                elif dest.suffix.lower() != ".pdf":
                    dest = dest.with_name(dest.name + ".pdf")
            else:
                dest = src.with_suffix(".pdf")
            if dest.exists() and not overwrite:
                raise FileExistsError(f"Destination exists: {rel(dest)} (pass overwrite=true)")
            dest.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="lo-") as tmp:
                env = dict(os.environ, HOME=tmp)
                cmd = [
                    soffice, "--headless", "--norestore", "--nologo",
                    f"-env:UserInstallation=file://{tmp}/profile",
                    "--convert-to", "pdf", "--outdir", tmp, str(src),
                ]
                try:
                    r = subprocess.run(cmd, capture_output=True, timeout=300, env=env)
                except subprocess.TimeoutExpired as e:
                    raise RuntimeError("LibreOffice timed out after 300 s.") from e
                produced = Path(tmp) / (src.stem + ".pdf")
                if r.returncode != 0 or not produced.is_file():
                    err = (r.stderr or r.stdout).decode("utf-8", "replace").strip().splitlines()
                    raise RuntimeError("LibreOffice conversion failed: " + (err[-1] if err else "no output"))
                shutil.move(str(produced), dest)
            out = {"source": rel(src), "saved": rel(dest), "bytes": dest.stat().st_size, "download": link(dest)}
            return out
