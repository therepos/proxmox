#!/usr/bin/env python3
"""
zip_to_7z.py
------------
Compresses a file OR folder into a password-protected 7z archive.
Auto-installs 7-Zip if not present (Windows / macOS / Linux).

Output filename : log-YYYYMMDD-HHMM   (no extension, placed next to input)
Password        : 123
Usage           : python zip_to_7z.py <file_or_folder_path>
           or   : python zip_to_7z.py        (prompts for path)
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
# 3.  COMPRESS
# ──────────────────────────────────────────────

def make_archive(target: Path, seven_z: str) -> Path:
    timestamp   = datetime.now().strftime("%Y%m%d-%H%M")
    output_name = f"{PREFIX}-{timestamp}"      # no extension
    script_dir  = Path(__file__).resolve().parent
    output_path = script_dir / output_name     # sits next to the script

    cmd = [
        seven_z,
        "a",               # add / create archive
        "-t7z",            # 7z format
        f"-p{PASSWORD}",   # password
        "-mhe=on",         # encrypt file headers too
        "-mx=5",           # compression level 0-9
        str(output_path),  # destination (no .7z suffix -- intentional)
        str(target),       # source: file or folder
    ]

    kind = "Folder" if target.is_dir() else "File"
    print(f"[*] {kind:<8}     : {target}")
    print(f"[*] Output       : {output_path}")
    print(f"[*] Password     : {PASSWORD}")
    print()

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
# 4.  ENTRY POINT
# ──────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Drag-and-drop a file or folder onto this script, or enter the path below.")
        raw = input("  Path: ").strip().strip('"').strip("'")
    else:
        raw = sys.argv[1].strip().strip('"').strip("'")

    target = Path(raw).expanduser().resolve()

    if not target.exists():
        print(f"[!] Path does not exist: {target}")
        sys.exit(1)
    if not target.is_file() and not target.is_dir():
        print(f"[!] Not a file or folder: {target}")
        sys.exit(1)

    try:
        seven_z = ensure_7z()
    except RuntimeError as e:
        print(f"\n[!] Could not obtain 7-Zip: {e}")
        sys.exit(1)

    try:
        out = make_archive(target, seven_z)
        print(f"\n[✓] Done -> {out}")
    except RuntimeError as e:
        print(f"\n[!] Compression failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
