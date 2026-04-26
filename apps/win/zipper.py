#!/usr/bin/env python3
"""
zipper.py
---------
Compress files/folders into a password-protected 7z archive,
or extract a password-protected 7z archive.
Auto-installs 7-Zip if not present (Windows / macOS / Linux).

ZIP MODE
  Output filename : log-YYYYMMDD-HHMM   (no extension, placed next to script)
  Password        : prompts (press Enter to use the default '123')

UNZIP MODE
  Input           : a 7z archive (with or without .7z extension)
  Password        : prompts (press Enter to use the default '123';
                    will re-prompt if wrong)
  Output          : a folder next to the archive (or a path you choose)

Usage
  python zipper.py                              (interactive — asks zip or unzip)
  python zipper.py --zip   <file_or_folder> ...
  python zipper.py --unzip <archive> [output_dir]
  python zipper.py --password <pw> --zip <file_or_folder> ...
  python zipper.py <file_or_folder> ...         (legacy: defaults to zip)

Flags
  --zip / -z              compress mode
  --unzip / -u / -x       extract mode
  --password <pw> / -p    skip the password prompt and use this value
"""

import sys
import os
import subprocess
import shutil
import platform
from datetime import datetime
from pathlib import Path


DEFAULT_PASSWORD = "123"
PREFIX           = "log"

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
# 3.  COLLECT & VALIDATE TARGETS  (for ZIP mode)
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
# 3b. PASSWORD PROMPT
# ──────────────────────────────────────────────

def prompt_password(action: str, *, confirm: bool = False) -> str:
    """
    Ask the user for a password, hiding input where possible.
    Press Enter on an empty line to accept DEFAULT_PASSWORD.

    `action` is just a label used in the prompt (e.g. "encrypt", "extract").
    `confirm` re-prompts and verifies the entry matches (used for zipping).
    """
    # Use getpass so the password isn't echoed to the terminal. If stdin
    # isn't a real TTY (e.g. piped input), getpass falls back to plain input.
    import getpass

    prompt = (
        f"  Password for {action} "
        f"(press Enter for default '{DEFAULT_PASSWORD}'): "
    )

    try:
        pw = getpass.getpass(prompt)
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)

    if not pw:
        print(f"  [-] Using default password.")
        return DEFAULT_PASSWORD

    if confirm:
        try:
            pw2 = getpass.getpass("  Confirm password: ")
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)
        if pw != pw2:
            print("  [!] Passwords do not match. Try again.\n")
            return prompt_password(action, confirm=True)

    return pw


# ──────────────────────────────────────────────
# 4.  COMPRESS
# ──────────────────────────────────────────────

def make_archive(targets: list[Path], seven_z: str,
                 password: str = DEFAULT_PASSWORD) -> Path:
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
    print(f"[*] Password         : {'*' * len(password)} ({len(password)} chars)")
    print()

    cmd = [
        seven_z,
        "a",               # add / create archive
        "-t7z",            # 7z format
        f"-p{password}",   # password
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
# 5.  EXTRACT
# ──────────────────────────────────────────────

def resolve_archive(raw: str) -> Path:
    """
    Resolve the input archive path. Accepts the bare name (no extension),
    a name with .7z, or any path. Exits if it can't be found.
    """
    p = Path(raw.strip().strip('"').strip("'")).expanduser().resolve()

    candidates = [p, Path(str(p) + ".7z")]
    for c in candidates:
        if c.is_file():
            return c

    print(f"[!] Archive not found: {p}")
    sys.exit(1)


def prompt_extract_inputs() -> tuple[Path, Path]:
    """
    Interactive mode for extraction.
    Returns (archive_path, output_dir).
    """
    print("Enter the path to the archive to extract.")
    try:
        raw = input("  Archive: ").strip()
    except EOFError:
        raw = ""
    if not raw:
        print("[!] No archive provided. Exiting.")
        sys.exit(0)

    archive = resolve_archive(raw)

    print("\nEnter the output folder (press Enter to use a folder next to the archive).")
    try:
        raw_out = input("  Output : ").strip()
    except EOFError:
        raw_out = ""

    if raw_out:
        out_dir = Path(raw_out.strip('"').strip("'")).expanduser().resolve()
    else:
        out_dir = archive.parent / f"{archive.stem}-extracted"

    return archive, out_dir


def extract_archive(archive: Path, out_dir: Path, seven_z: str,
                    password: str = DEFAULT_PASSWORD) -> Path:
    """
    Extract `archive` into `out_dir`. If the password fails,
    prompt the user for the correct one (up to 3 attempts).
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[*] Archive          : {archive}")
    print(f"[*] Output folder    : {out_dir}")
    print(f"[*] Password         : {'*' * len(password)} ({len(password)} chars)")
    print()

    def _run(pw: str) -> int:
        cmd = [
            seven_z,
            "x",                  # extract WITH full paths
            f"-p{pw}",
            "-y",                 # assume Yes on prompts (overwrite, etc.)
            f"-o{out_dir}",       # output dir (no space after -o)
            str(archive),
        ]
        return subprocess.run(cmd, capture_output=False, text=True).returncode

    rc = _run(password)

    # 7-Zip returns non-zero for fatal errors (wrong password is one of them).
    # Allow up to 3 retry attempts.
    import getpass
    attempts = 0
    while rc != 0 and attempts < 3:
        attempts += 1
        print(f"\n[!] Extraction failed (exit code {rc}). "
              "The password may be wrong.")
        try:
            new_pw = getpass.getpass(
                f"  Enter password (attempt {attempts}/3, blank to abort): "
            ).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            new_pw = ""
        if not new_pw:
            raise RuntimeError("Extraction aborted.")
        rc = _run(new_pw)

    if rc != 0:
        raise RuntimeError(f"7z exited with code {rc}")

    return out_dir


# ──────────────────────────────────────────────
# 6.  MODE SELECTION
# ──────────────────────────────────────────────

def prompt_mode() -> str:
    """Ask the user whether to zip or unzip."""
    print("What would you like to do?")
    print("  1) Zip   (compress files/folders into a password-protected archive)")
    print("  2) Unzip (extract a password-protected archive)")
    while True:
        try:
            choice = input("Choice [1/2]: ").strip().lower()
        except EOFError:
            choice = ""
        if choice in ("1", "z", "zip"):
            return "zip"
        if choice in ("2", "u", "unzip", "x", "extract"):
            return "unzip"
        print("  [!] Please enter 1 or 2.")


# ──────────────────────────────────────────────
# 7.  ENTRY POINT
# ──────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    mode: str | None = None
    cli_password: str | None = None

    # --- Extract --password / -p from anywhere in args ---
    cleaned: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--password", "-p"):
            if i + 1 >= len(args):
                print("[!] --password requires a value.")
                sys.exit(1)
            cli_password = args[i + 1]
            i += 2
            continue
        if a.startswith("--password="):
            cli_password = a.split("=", 1)[1]
            i += 1
            continue
        cleaned.append(a)
        i += 1
    args = cleaned

    # --- Parse mode flag if present ---
    if args and args[0] in ("--zip", "-z"):
        mode = "zip"
        args = args[1:]
    elif args and args[0] in ("--unzip", "-u", "--extract", "-x"):
        mode = "unzip"
        args = args[1:]
    elif args and args[0] in ("--help", "-h"):
        print(__doc__)
        sys.exit(0)

    # --- If no mode flag and args were given, default to zip (legacy behaviour) ---
    if mode is None and args:
        mode = "zip"

    # --- If still no mode, ask interactively ---
    if mode is None:
        mode = prompt_mode()
        print()

    # --- Ensure 7-Zip is available ---
    try:
        seven_z = ensure_7z()
    except RuntimeError as e:
        print(f"\n[!] Could not obtain 7-Zip: {e}")
        sys.exit(1)

    # --- Dispatch ---
    if mode == "zip":
        if args:
            targets = collect_targets(args)
        else:
            targets = prompt_targets()

        password = cli_password if cli_password is not None else \
            prompt_password("encrypt", confirm=True)

        try:
            out = make_archive(targets, seven_z, password=password)
            print(f"\n[✓] Done -> {out}")
        except RuntimeError as e:
            print(f"\n[!] Compression failed: {e}")
            sys.exit(1)

    elif mode == "unzip":
        if args:
            archive = resolve_archive(args[0])
            if len(args) >= 2:
                out_dir = Path(args[1]).expanduser().resolve()
            else:
                out_dir = archive.parent / f"{archive.stem}-extracted"
        else:
            archive, out_dir = prompt_extract_inputs()

        password = cli_password if cli_password is not None else \
            prompt_password("extract")

        try:
            out = extract_archive(archive, out_dir, seven_z, password=password)
            print(f"\n[✓] Done -> {out}")
        except RuntimeError as e:
            print(f"\n[!] Extraction failed: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
