#!/usr/bin/env python3
"""zipper - password-protected 7z transfer archives: zip, unzip, split, join.

Commands
  unzip <file> [<file> ...] [--out DIR] [--password PW] [--no-copy]
        any part of a split set (.001, .002, ...) is fine; 7z or zip; no extension needed
  zip   <path> [<path> ...] [--out DIR] [--password PW] [--split-mb N]
        -> YYYYMMDD-HHMMSS (no extension), or .001/.002/... when over the split size
  password set [PW]      save the password (reads it from stdin when PW is omitted)
  password forget        remove the saved password
  password status        say whether a password is available (never prints it)
  config [--out DIR] [--split-mb N]   show or change saved defaults (--out "" resets)

Password lookup: --password, then $ZIPPER_PASSWORD, then the saved config
(~/.config/zipper/config.json, mode 600, or $ZIPPER_CONFIG). Only `password set`
saves: a --password for someone else's archive (e.g. a client's) is used once.
Exit codes: 0 ok, 1 failed, 3 password needed -> ask the user, then `password set`.
Uses a 7z binary when present, otherwise py7zr (installed on demand). Stdlib otherwise.
Also imported as a module by the mcpshared server (apps/mcp/mcpshared/zip_tools.py).
"""
import argparse
import bisect
import functools
import getpass
import io
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime
from pathlib import Path

DEFAULT_SPLIT_MB = 500
EXIT_NEED_PASSWORD = 3
OFFICE_EXT = (".xlsx", ".xlsm", ".docx", ".pptx")
OUTPUTS = Path("/mnt/user-data/outputs")        # claude.ai: files here can be handed to the user
PART_RE = re.compile(r"^(.*)\.(\d{3})$")
ASK_USER = "Ask the user for the zip password, then run: zipper.py password set"


class NeedPassword(Exception):
    pass


# ---------------------------------------------------------------- settings
def config_path() -> Path:
    return Path(os.environ.get("ZIPPER_CONFIG") or Path.home() / ".config" / "zipper" / "config.json")


def load_config() -> dict:
    try:
        return json.loads(config_path().read_text())
    except (OSError, ValueError):
        return {}


def save_config(cfg: dict) -> None:
    p = config_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
    try:
        os.chmod(p, 0o600)          # O_CREAT mode only applies to new files
    except OSError:
        pass


def known_password(cli: str | None = None) -> str | None:
    return cli or os.environ.get("ZIPPER_PASSWORD") or load_config().get("password") or None


def password_state() -> str:
    if os.environ.get("ZIPPER_PASSWORD"):
        return "from ZIPPER_PASSWORD"
    return "saved" if load_config().get("password") else "not saved"


def set_password(pw: str | None) -> None:
    """Save pw, or remove the saved password when pw is empty/None."""
    cfg = load_config()
    if pw:
        cfg["password"] = pw
    else:
        cfg.pop("password", None)
    save_config(cfg)


def saved_split_mb() -> int:
    return max(0, int(load_config().get("split_mb", DEFAULT_SPLIT_MB)))


# ---------------------------------------------------------------- backends
@functools.lru_cache(maxsize=1)
def find_7z() -> str | None:
    for name in ("7z", "7zz", "7za"):
        if shutil.which(name):
            return shutil.which(name)
    for p in (r"C:\Program Files\7-Zip\7z.exe", r"C:\Program Files (x86)\7-Zip\7z.exe"):
        if os.path.isfile(p):
            return p
    return None


def need_module(name: str):
    """Import a pip package, installing it on first use (claude.ai sandboxes, Claude Code)."""
    try:
        return __import__(name)
    except ImportError:
        pass
    for extra in (["--user"], ["--break-system-packages"], []):
        r = subprocess.run([sys.executable, "-m", "pip", "install", "-q", name, *extra],
                           capture_output=True, text=True)
        if r.returncode == 0:
            break
    import importlib
    import site
    importlib.invalidate_caches()
    if site.getusersitepackages() not in sys.path:
        sys.path.append(site.getusersitepackages())
    try:
        return __import__(name)
    except ImportError:
        raise RuntimeError(f"could not install {name}; install 7-Zip (p7zip-full) or {name}") from None


def run_7z(args: list[str]) -> tuple[int, str]:
    """Run 7z non-interactively; return (exit code, its most useful error line)."""
    r = subprocess.run([find_7z(), *args], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, errors="replace")
    lines = [l.strip() for l in (r.stderr + "\n" + r.stdout).splitlines() if l.strip()]
    err = next((l for l in lines if "password" in l.lower()), None) \
        or next((l for l in lines if re.search(r"missing volume|unexpected end|cannot|can not|^error", l, re.I)), None) \
        or (lines[-1] if lines else "")
    return r.returncode, err


class Joined(io.RawIOBase):
    """Read-only, seekable view of split parts as one file (no temporary copy)."""

    def __init__(self, paths: list[Path]):
        self.files = [open(p, "rb") for p in paths]
        self.starts, self.size, self.pos = [], 0, 0
        for p in paths:
            self.starts.append(self.size)
            self.size += p.stat().st_size

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=0):
        self.pos = max(0, {0: 0, 1: self.pos, 2: self.size}[whence] + offset)
        return self.pos

    def readinto(self, buf):
        if self.pos >= self.size:
            return 0
        i = bisect.bisect_right(self.starts, self.pos) - 1
        f = self.files[i]
        f.seek(self.pos - self.starts[i])
        data = f.read(len(buf))
        buf[:len(data)] = data
        self.pos += len(data)
        return len(data)

    def close(self):
        for f in self.files:
            f.close()
        super().close()


def _open_parts(parts: list[Path]):
    return io.BufferedReader(Joined(parts), 1 << 20) if len(parts) > 1 else open(parts[0], "rb")


# ---------------------------------------------------------------- archive sets
def resolve_set(raw: str) -> tuple[str, list[Path]]:
    """Dropped item -> (display name, ordered parts). Raises ValueError if missing or a part is absent."""
    p = Path(raw).expanduser()
    for c in (p, Path(f"{p}.7z"), Path(f"{p}.001")):
        if c.is_file():
            p = c.resolve()
            break
    else:
        raise ValueError(f"not found: {raw}")
    m = PART_RE.match(p.name)
    if not m:
        return re.sub(r"\.(7z|zip)$", "", p.name, flags=re.I), [p]
    base = m.group(1)
    nums = sorted(int(mm.group(2)) for f in p.parent.iterdir()
                  if (mm := PART_RE.match(f.name)) and mm.group(1) == base and f.is_file())
    missing = [f"{n:03d}" for n in range(1, nums[-1] + 1) if n not in nums]
    if missing:
        raise ValueError(f"{base}: part(s) {', '.join(missing)} missing (found up to {nums[-1]:03d})")
    return re.sub(r"\.(7z|zip)$", "", base, flags=re.I), [p.parent / f"{base}.{n:03d}" for n in nums]


def kind(path: Path) -> str:
    with open(path, "rb") as f:
        sig = f.read(6)
    if sig.startswith(b"7z\xbc\xaf\x27\x1c"):
        return "7z"
    return "zip" if sig.startswith(b"PK") else "unknown"


def tree_size(targets: list[Path]) -> int:
    return sum(f.stat().st_size for t in targets for f in ([t] if t.is_file() else t.rglob("*")) if f.is_file())


# ---------------------------------------------------------------- extract
def _py7z_encrypted(parts: list[Path]) -> bool:
    """True when a 7z needs a password (encrypted names or encrypted content)."""
    py7zr = need_module("py7zr")
    try:
        with _open_parts(parts) as f, py7zr.SevenZipFile(f, mode="r") as z:
            return bool(z.needs_password())
    except py7zr.exceptions.PasswordRequired:
        return True
    except Exception:  # noqa: BLE001
        return False


def _extract_once(parts: list[Path], dst: Path, pw: str) -> str | None:
    """Try one password ('' = none). Returns None on success, 'password', or an error text."""
    dst.mkdir(parents=True, exist_ok=True)
    if find_7z():
        rc, err = run_7z(["x", f"-p{pw or '-'}", "-y", f"-o{dst}", str(parts[0])])
        if rc == 0:
            return None
        return "password" if "password" in err.lower() else (err or f"7z exit {rc}")

    k = kind(parts[0])
    pwd = pw.encode() if pw else None
    try:
        with _open_parts(parts) as f:
            if k == "zip":
                try:
                    with zipfile.ZipFile(f) as z:
                        z.extractall(dst, pwd=pwd)
                except NotImplementedError:          # AES zip
                    f.seek(0)
                    with need_module("pyzipper").AESZipFile(f) as z:
                        z.extractall(dst, pwd=pwd)
            else:
                with need_module("py7zr").SevenZipFile(f, mode="r", password=pw or None) as z:
                    z.extractall(path=dst)
        return None
    except Exception as e:  # noqa: BLE001 - a wrong password surfaces as many exception types
        text = f"{type(e).__name__}: {e}"
        if "password" in text.lower() or (k != "zip" and _py7z_encrypted(parts)):
            return "password"
        return text


def extract(parts: list[Path], dst: Path, pw: str | None) -> str:
    """Extract with the known password, then with none. Returns the password that worked."""
    existed = dst.exists()                       # never delete a folder we did not create
    for candidate in ([pw] if pw else []) + [""]:
        res = _extract_once(parts, dst, candidate)
        if res is None:
            return candidate
        if not existed:
            shutil.rmtree(dst, ignore_errors=True)
        if res != "password":
            raise RuntimeError(res)
    raise NeedPassword()


def _drop_symlinks(folder: Path) -> None:
    """Archives may carry symlinks pointing outside the destination."""
    for p in folder.rglob("*"):
        if p.is_symlink():
            p.unlink()


def extract_all(parts: list[Path], dst: Path, pw: str | None) -> tuple[str, list[str]]:
    """Extract, drop symlinks, then unpack one level of nested archives.
    Returns (password that worked, warnings). Raises NeedPassword or RuntimeError."""
    used = extract(parts, dst, pw)
    _drop_symlinks(dst)
    warnings = []
    for f in [f for f in dst.rglob("*") if f.is_file()]:
        if f.name.lower().endswith(OFFICE_EXT) or kind(f) not in ("7z", "zip"):
            continue
        sub = f.with_name(f.stem + "_extracted")
        try:
            extract([f], sub, used or pw)
            _drop_symlinks(sub)
        except NeedPassword:
            warnings.append(f"nested archive {f.relative_to(dst)}: needs a different password")
        except RuntimeError as e:
            warnings.append(f"nested archive {f.relative_to(dst)}: {e}")
    return used, warnings


# ---------------------------------------------------------------- compress
def _split_file(path: Path, part_bytes: int) -> list[Path]:
    """Cut path into path.001, .002, ... of part_bytes (7z volumes are plain byte splits)."""
    parts = []
    with open(path, "rb") as src:
        while chunk := src.read(min(part_bytes, 64 << 20)):
            part = path.with_name(f"{path.name}.{len(parts) + 1:03d}")
            with open(part, "wb") as out:
                out.write(chunk)
                left = part_bytes - len(chunk)
                while left and (chunk := src.read(min(left, 64 << 20))):
                    out.write(chunk)
                    left -= len(chunk)
            parts.append(part)
    path.unlink()
    return parts


def create_archive(targets: list[Path], out_dir: Path, pw: str | None, split_mb: int | None = None) -> list[Path]:
    """Encrypted 7z (names hidden) of targets in out_dir: YYYYMMDD-HHMMSS, or .001/.002/...
    parts over split_mb (None = saved setting, 0 = never). Raises NeedPassword without a password."""
    if not pw:
        raise NeedPassword()
    split_mb = saved_split_mb() if split_mb is None else max(0, split_mb)
    limit = split_mb * 1024 * 1024
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base, i = out_dir / stamp, 2
    while any(out_dir.glob(base.name + "*")):          # never append to an existing archive
        base, i = out_dir / f"{stamp}-{i}", i + 1
    tmp = base.with_name(base.name + ".7z")

    if find_7z():
        args = ["a", "-t7z", f"-p{pw}", "-mhe=on", "-mx=5"]
        if limit and tree_size(targets) > limit:
            args.append(f"-v{split_mb}m")
        rc, err = run_7z(args + [str(tmp)] + [str(t) for t in targets])
        if rc != 0:
            for f in out_dir.glob(tmp.name + "*"):
                f.unlink()
            raise RuntimeError(err or f"7z exit {rc}")
        made = sorted(out_dir.glob(tmp.name + ".[0-9][0-9][0-9]")) or [tmp]
    else:
        try:
            with need_module("py7zr").SevenZipFile(tmp, "w", password=pw, header_encryption=True) as z:
                for t in targets:
                    z.writeall(t, arcname=t.name) if t.is_dir() else z.write(t, arcname=t.name)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
        made = _split_file(tmp, limit) if limit and tmp.stat().st_size > limit else [tmp]

    if len(made) == 1:                      # one file -> no extension
        made[0].rename(base)
        return [base]
    result = [base.with_name(f"{base.name}.{f.name[-3:]}") for f in made]   # name.001, name.002, ...
    for f, dest in zip(made, result):
        f.rename(dest)
    return result


# ---------------------------------------------------------------- CLI
def default_extract_root(no_copy: bool) -> Path:
    cfg_out = load_config().get("out")
    if os.environ.get("EXTRACT_DIR"):
        return Path(os.environ["EXTRACT_DIR"])
    if cfg_out:
        return Path(cfg_out)
    if OUTPUTS.is_dir() and not no_copy:
        return OUTPUTS
    return Path("/home/claude/extracted") if os.path.isdir("/home/claude") else Path("/tmp/extracted")


def default_zip_dir() -> Path:
    cfg_out = load_config().get("out")
    if cfg_out:
        return Path(cfg_out)
    for d in (OUTPUTS, Path.home() / "Downloads"):
        if d.is_dir():
            return d
    return Path.cwd()


def cmd_unzip(a) -> int:
    pw = known_password(a.password)
    root = Path(a.out).expanduser().resolve() if a.out else default_extract_root(a.no_copy)
    seen, present, failed, need_pw = set(), [], 0, False
    for raw in a.files:
        try:
            name, parts = resolve_set(raw)
        except ValueError as e:
            print(f"MISSING_PARTS: {e}" if "missing" in str(e) else str(e))
            failed += 1
            continue
        if parts[0] in seen:
            continue
        seen.add(parts[0])
        dst = root / name
        print(f"{name}: {kind(parts[0])}" + (f", split set of {len(parts)} parts" if len(parts) > 1 else ""))
        try:
            _, warnings = extract_all(parts, dst, pw)
        except NeedPassword:
            print(f"NEED_PASSWORD: {name} needs a password zipper does not know.")
            need_pw, failed = True, failed + 1
            continue
        except RuntimeError as e:
            print(f"FAILED: {name}: {e}")
            failed += 1
            continue
        for w in warnings:
            print(f"  {w}")
        files = sorted(f for f in dst.rglob("*") if f.is_file())
        print(f"{len(files)} files extracted to {dst}:")
        for f in files:
            print(f"  {f.stat().st_size / 1e6:8.2f} MB  {f.relative_to(dst)}")
        present += map(str, files)
    if present:
        print("PRESENT:", " ".join(present))
    if need_pw:
        print(ASK_USER)
        return EXIT_NEED_PASSWORD
    return 1 if failed else 0


def cmd_zip(a) -> int:
    targets = []
    for raw in a.paths:
        p = Path(raw).expanduser().resolve()
        if not p.exists():
            print(f"not found: {raw}")
            return 1
        if p not in targets:
            targets.append(p)
    out_dir = Path(a.out).expanduser().resolve() if a.out else default_zip_dir()
    print(f"{len(targets)} item(s), {tree_size(targets) / 1e6:.1f} MB before compression")
    try:
        result = create_archive(targets, out_dir, known_password(a.password), a.split_mb)
    except NeedPassword:
        print("NEED_PASSWORD: no zip password saved.")
        print(ASK_USER)
        return EXIT_NEED_PASSWORD
    except Exception as e:  # noqa: BLE001
        print(f"FAILED: {e}")
        return 1
    for f in result:
        print(f"  {f.stat().st_size / 1e6:8.1f} MB  {f}")
    if len(result) > 1:
        print("Keep all parts together in one folder to unzip.")
    print("PRESENT:", " ".join(map(str, result)))
    return 0


def cmd_password(a) -> int:
    if a.action == "status":
        print(f"password: {password_state()}")
        return 0
    if a.action == "forget":
        set_password(None)
        print("password removed")
        return 0
    pw = a.value
    if pw is None:
        pw = getpass.getpass("Zip password: ") if sys.stdin.isatty() else sys.stdin.readline().rstrip("\r\n")
    if not pw:
        print("empty password, nothing saved")
        return 1
    set_password(pw)
    print("password saved")
    return 0


def cmd_config(a) -> int:
    if a.out is not None or a.split_mb is not None:
        cfg = load_config()
        if a.out:
            cfg["out"] = str(Path(a.out).expanduser().resolve())
        elif a.out is not None:
            cfg.pop("out", None)
        if a.split_mb is not None:
            cfg["split_mb"] = max(0, a.split_mb)
        save_config(cfg)
    split = saved_split_mb()
    print(f"password:  {password_state()}")
    print(f"out:       {load_config().get('out') or 'default (outputs / Downloads / /tmp/extracted)'}")
    print(f"split_mb:  {split or 'never split'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Password-protected 7z transfer archives.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    u = sub.add_parser("unzip", help="extract archives or split sets")
    u.add_argument("files", nargs="+")
    u.add_argument("--out")
    u.add_argument("--password")
    u.add_argument("--no-copy", action="store_true", help="claude.ai: do not extract into the outputs folder")
    u.set_defaults(fn=cmd_unzip)

    z = sub.add_parser("zip", help="create a password-protected 7z")
    z.add_argument("paths", nargs="+")
    z.add_argument("--out")
    z.add_argument("--password")
    z.add_argument("--split-mb", type=int)
    z.set_defaults(fn=cmd_zip)

    p = sub.add_parser("password", help="set, forget or check the saved password")
    p.add_argument("action", choices=["set", "forget", "status"])
    p.add_argument("value", nargs="?")
    p.set_defaults(fn=cmd_password)

    c = sub.add_parser("config", help="show or change saved defaults")
    c.add_argument("--out")
    c.add_argument("--split-mb", type=int)
    c.set_defaults(fn=cmd_config)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
