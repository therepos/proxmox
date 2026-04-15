#!/usr/bin/env python3
"""
zip_to_7z.py
------------
Compresses one or more files/folders into a password-protected 7z archive.
Auto-installs 7-Zip if not present (Windows / macOS / Linux).

Output filename : log-YYYYMMDD-HHMM   (no extension, placed next to script)
Password        : 123
Usage           : python zip_to_7z.py <file_or_folder> [file_or_folder ...]
           or   : python zip_to_7z.py        (prompts for paths interactively)
"""

import sys
import os
import subprocess
import shutil
import platform
from datetime import datetime
from pathlib import Path


PASSWORD = "123"
PREFIX   = "log"

# Standard install locations 7-Zip uses on Windows
WIN_PATHS = [
    r"C:\Program Files\7-Zip\7z.exe",
    r"C:\Program Files (x86)\7-Zip\7z.exe",
]


# ──────────────────────────────────────────────
# 1.  FIND 7-ZIP
# ──────────────────────────────────────────────

def find_7z() -> str | None:
    """Return path to 7z executable, or None if not found."""
    for candidate in ("7z", "7za", "7zz"):
        found = shutil.which(candidate)
        if found:
            return found
    for p in WIN_PATHS:
        if os.path.isfile(p):
            return p
    return None


# ──────────────────────────────────────────────
# 2.  AUTO-INSTALL HELPERS
# ──────────────────────────────────────────────

def _install_windows() -> str:
    """Install via winget (Win 10/11). Falls back to direct MSI download."""
    if shutil.which("winget"):
        print("[*] Installing 7-Zip via winget ...")
        result = subprocess.run(
            ["winget", "install", "-e", "--id", "7zip.7zip",
             "--accept-package-agreements", "--accept-source-agreements"],
            capture_output=False,
            text=True,
        )
        if result.returncode == 0:
            os.environ["PATH"] += r";C:\Program Files\7-Zip"
            found = find_7z()
            if found:
                return found

    # Fallback: download MSI directly
    import urllib.request, tempfile
    print("[*] winget unavailable - downloading 7-Zip MSI installer ...")
    url = "https://www.7-zip.org/a/7z2409-x64.msi"
    tmp = os.path.join(tempfile.gettempdir(), "7zip_installer.msi")
    urllib.request.urlretrieve(url, tmp)
    print("[*] Running silent install ...")
    subprocess.run(["msiexec", "/i", tmp, "/quiet", "/norestart"], check=True)
    os.environ["PATH"] += r";C:\Program Files\7-Zip"
    found = find_7z()
    if found:
        return found
    raise RuntimeError("7-Zip installation finished but executable still not found.")


def _install_macos() -> str:
    """Install via Homebrew."""
    if not shutil.which("brew"):
        raise RuntimeError(
            "Homebrew is not installed. Install it from https://brew.sh then re-run."
        )
    print("[*] Installing p7zip via Homebrew ...")
    subprocess.run(["brew", "install", "p7zip"], check=True, capture_output=False)
    found = find_7z()
    if found:
        return found
    raise RuntimeError("p7zip installed but executable not found.")


def _install_linux() -> str:
    """Try apt, dnf, pacman, zypper in order."""
    managers = [
        (["apt-get", "install", "-y", "p7zip-full"],             "apt-get"),
        (["dnf",     "install", "-y", "p7zip", "p7zip-plugins"], "dnf"),
        (["pacman",  "-S", "--noconfirm", "p7zip"],              "pacman"),
        (["zypper",  "install", "-y", "p7zip"],                  "zypper"),
    ]
    for cmd, name in managers:
        if shutil.which(cmd[0]):
            print(f"[*] Installing p7zip via {name} ...")
            subprocess.run(["sudo"] + cmd, check=True, capture_output=False)
            found = find_7z()
            if found:
                return found
            raise RuntimeError(f"{name} finished but executable not found.")
    raise RuntimeError(
        "No supported package manager found (apt, dnf, pacman, zypper). "
        "Please install p7zip manually and re-run."
    )


def ensure_7z() -> str:
    """Return path to 7z, auto-installing if necessary."""
    found = find_7z()
    if found:
        return found

    system = platform.system()
    print(f"[!] 7-Zip not found. Auto-installing for {system} ...\n")

    if system == "Windows":
        return _install_windows()
    elif system == "Darwin":
        return _install_macos()
    elif system == "Linux":
        return _install_linux()
    else:
        raise RuntimeError(
            f"Unsupported OS '{system}'. Install 7-Zip manually and re-run."
        )


# ──────────────────────────────────────────────
# 3.  COLLECT & VALIDATE TARGETS
# ──────────────────────────────────────────────

def collect_targets(raw_paths: list[str]) -> list[Path]:
    """
    Resolve and validate a list of raw path strings.
    Skips duplicates (by resolved path). Exits if any path is invalid.
    """
    seen:    set[Path]  = set()
    targets: list[Path] = []
    errors:  list[str]  = []

    for raw in raw_paths:
        p = Path(raw.strip().strip('"').strip("'")).expanduser().resolve()
        if not p.exists():
            errors.append(f"  [!] Not found     : {p}")
        elif not p.is_file() and not p.is_dir():
            errors.append(f"  [!] Not a file/dir: {p}")
        elif p in seen:
            print(f"  [-] Duplicate skip: {p}")
        else:
            seen.add(p)
            targets.append(p)

    if errors:
        print("\n[!] Some paths could not be resolved:")
        for e in errors:
            print(e)
        sys.exit(1)

    return targets


def prompt_targets() -> list[Path]:
    """
    Interactive mode: ask the user to enter paths one by one.
    An empty line (or 'done') finishes input.
    """
    print("Enter file/folder paths to archive (one per line).")
    print("Press Enter on an empty line when done.\n")

    raw_paths: list[str] = []
    while True:
        try:
            line = input(f"  Path {len(raw_paths) + 1}: ").strip()
        except EOFError:
            break
        if line.lower() in ("", "done", "q", "quit"):
            break
        raw_paths.append(line)

    if not raw_paths:
        print("[!] No paths provided. Exiting.")
        sys.exit(0)

    return collect_targets(raw_paths)


# ──────────────────────────────────────────────
# 4.  COMPRESS
# ──────────────────────────────────────────────

def make_archive(targets: list[Path], seven_z: str) -> Path:
    timestamp   = datetime.now().strftime("%Y%m%d-%H%M")
    output_name = f"{PREFIX}-{timestamp}"      # no extension
    script_dir  = Path(__file__).resolve().parent
    output_path = script_dir / output_name     # sits next to the script

    # Print a summary of what will be archived
    print(f"[*] Items to archive : {len(targets)}")
    for t in targets:
        kind = "Folder" if t.is_dir() else "File"
        print(f"    {kind:<8} : {t}")
    print(f"[*] Output           : {output_path}")
    print(f"[*] Password         : {PASSWORD}")
    print()

    cmd = [
        seven_z,
        "a",               # add / create archive
        "-t7z",            # 7z format
        f"-p{PASSWORD}",   # password
        "-mhe=on",         # encrypt file headers too
        "-mx=5",           # compression level 0-9
        str(output_path),  # destination (no .7z suffix -- intentional)
        *[str(t) for t in targets],   # ← all sources
    ]

    result = subprocess.run(cmd, capture_output=False, text=True)

    if result.returncode != 0:
        raise RuntimeError(f"7z exited with code {result.returncode}")

    # Some 7z builds silently append .7z -- strip it back off
    with_ext = Path(str(output_path) + ".7z")
    if with_ext.exists() and not output_path.exists():
        with_ext.rename(output_path)
        print(f"[*] Removed auto-added extension -> '{output_path.name}'")

    return output_path


# ──────────────────────────────────────────────
# 5.  ENTRY POINT
# ──────────────────────────────────────────────

def main():
    # --- Gather raw paths from argv or interactive prompt ---
    if len(sys.argv) >= 2:
        # All extra argv items are treated as paths (supports drag-and-drop of
        # multiple files onto the script icon on Windows/macOS)
        targets = collect_targets(sys.argv[1:])
    else:
        targets = prompt_targets()

    # --- Ensure 7-Zip is available ---
    try:
        seven_z = ensure_7z()
    except RuntimeError as e:
        print(f"\n[!] Could not obtain 7-Zip: {e}")
        sys.exit(1)

    # --- Compress ---
    try:
        out = make_archive(targets, seven_z)
        print(f"\n[✓] Done -> {out}")
    except RuntimeError as e:
        print(f"\n[!] Compression failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
