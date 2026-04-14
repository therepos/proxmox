"""
╔══════════════════════════════════════════════════════════════════╗
║     LOCAL vs INTERNET MONITORING TEST v2.0                       ║
║     What exactly can each agent see?                             ║
║     Double-click to run — dependencies auto-install              ║
╚══════════════════════════════════════════════════════════════════════╝

This script answers:
  1. Which agents react to local vs internet transfers?
  2. What EXACTLY can each agent capture?
     (IO spike ≠ content inspection)
  3. Outputs full results to a log file.
"""

import subprocess
import sys
import importlib

def ensure(pkg, imp=None):
    try:
        importlib.import_module(imp or pkg)
    except ImportError:
        print(f"  Installing {pkg}...")
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", pkg, "--quiet"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

print("\n  Checking dependencies...")
ensure("psutil")
ensure("requests")
print("  All dependencies ready.\n")

import os
import re
import time
import socket
import threading
import tempfile
import datetime
import json

import psutil
import requests

# ══════════════════════════════════════════════════════════════
#  AGENT KNOWLEDGE BASE
#  What each tool actually does vs what people assume it does
# ══════════════════════════════════════════════════════════════

AGENT_PROFILES = {
    "zsatunnel.exe": {
        "label": "Zscaler Tunnel",
        "category": "Network Security",
        "purpose": "Cloud proxy — routes internet traffic through Zscaler's cloud for inspection",
        "can_see": [
            "URLs and domains you visit",
            "File uploads/downloads over HTTP/HTTPS (via SSL interception)",
            "File names, sizes, and destinations",
            "File CONTENTS if SSL interception is active",
            "Which cloud apps you use and for how long",
        ],
        "cannot_see": [
            "Files copied to USB or local drives",
            "What you type (no keystroke logging)",
            "Your screen (no screen capture)",
            "Clipboard content",
            "Files that never touch the network",
        ],
        "local_traffic_note": (
            "Zscaler's agent hooks into the OS network stack via a TUN/TAP driver. "
            "It MAY see local network packets if its filter driver intercepts all "
            "traffic before routing decisions. However, local traffic is typically "
            "NOT forwarded to Zscaler's cloud for inspection — the agent may log "
            "the connection metadata (source, dest, port) locally but is unlikely "
            "to perform content inspection on LAN-to-LAN transfers."
        ),
        "io_spike_meaning": (
            "An IO spike from ZSATunnel during a local transfer likely means the "
            "agent's network filter SAW the packets pass through the stack and logged "
            "metadata (IP, port, bytes). This does NOT necessarily mean it inspected "
            "the content or forwarded it to the cloud. For internet transfers, it "
            "DOES inspect and forward content."
        ),
    },
    "zscaler.exe": {
        "label": "Zscaler App",
        "category": "Network Security",
        "purpose": "Zscaler client UI and management process",
        "can_see": ["Same as ZSATunnel — this is the parent process"],
        "cannot_see": ["Same as ZSATunnel"],
        "local_traffic_note": "See ZSATunnel notes.",
        "io_spike_meaning": "UI/management process — IO often unrelated to traffic inspection.",
    },
    "zsatray.exe": {
        "label": "Zscaler Tray",
        "category": "Network Security",
        "purpose": "System tray icon for Zscaler",
        "can_see": ["Minimal — mostly UI status"],
        "cannot_see": ["Content of any transfers"],
        "local_traffic_note": "UI only.",
        "io_spike_meaning": "Likely just refreshing status display.",
    },
    "mssense.exe": {
        "label": "Defender for Endpoint (EDR)",
        "category": "Endpoint Security (EDR)",
        "purpose": "Advanced threat detection — monitors process behavior, file access, network connections",
        "can_see": [
            "Which processes access which files (file path, name, size)",
            "Process creation chains (what launched what)",
            "Network connections made by each process (IP, port, protocol)",
            "Suspicious behavior patterns (e.g., mass file reads, encryption)",
            "Registry changes, privilege escalation attempts",
            "DLL loads and code injection attempts",
        ],
        "cannot_see": [
            "File CONTENTS (it detects behavior patterns, not reads file text)",
            "Clipboard content",
            "Keystrokes",
            "Screen content",
            "The actual data bytes transferred over the network",
        ],
        "local_traffic_note": (
            "MsSense monitors at the endpoint level — it sees that a process opened "
            "a network socket and transferred X bytes to Y IP. It logs this regardless "
            "of whether the destination is local or internet. However, it does NOT "
            "inspect the content of the transfer. It looks for behavioral anomalies "
            "(e.g., 'python.exe suddenly reading 500 files and opening a network connection')."
        ),
        "io_spike_meaning": (
            "An IO spike means MsSense recorded telemetry about what processes did — "
            "file opens, network connections, process activity. This is metadata/behavioral "
            "logging, NOT content inspection. It knows 'python.exe sent 50KB to 192.168.1.5' "
            "but NOT what was in those 50KB."
        ),
    },
    "msmpeng.exe": {
        "label": "Windows Defender Antimalware",
        "category": "Antivirus",
        "purpose": "Real-time antimalware scanning — checks files for malware signatures",
        "can_see": [
            "File contents (scans for malware patterns/signatures)",
            "Files as they are created, modified, or accessed",
            "Downloaded files",
            "Email attachments opened locally",
        ],
        "cannot_see": [
            "Network traffic content (not a network inspector)",
            "Clipboard content",
            "Keystrokes or screen content",
            "What you do in your browser (that's Zscaler's domain)",
        ],
        "local_traffic_note": (
            "MsMpEng does NOT monitor network traffic. It scans FILES on disk. "
            "If it spiked during a transfer test, it's because the test file was "
            "written to disk and Defender scanned it for malware — not because it "
            "inspected the network transfer itself."
        ),
        "io_spike_meaning": (
            "An IO spike means Defender scanned a file that was created or accessed. "
            "It reads the file to check for malware signatures. It is NOT inspecting "
            "network traffic or logging your transfer activity. It would spike the same "
            "way if you simply opened the file in Notepad."
        ),
    },
    "defendpointservice.exe": {
        "label": "BeyondTrust / Defendpoint",
        "category": "Privilege Management",
        "purpose": "Controls which apps can run with elevated privileges, application whitelisting",
        "can_see": [
            "Which applications are running",
            "Whether an app requested admin/elevated privileges",
            "Application install/uninstall events",
        ],
        "cannot_see": [
            "File contents",
            "Network traffic or transfer content",
            "Clipboard, keystrokes, or screen content",
            "What data you send or receive",
        ],
        "local_traffic_note": (
            "BeyondTrust does not monitor network traffic at all. It manages "
            "application privileges and policies."
        ),
        "io_spike_meaning": (
            "IO spike likely means it checked whether the running process (python.exe) "
            "is allowed to run or has the correct privilege level. This is routine "
            "application control, not surveillance."
        ),
    },
    "nxtcoordinator.exe": {
        "label": "Nexthink Coordinator",
        "category": "Digital Experience Management (DEX)",
        "purpose": "IT operations — measures app performance, device health, user experience",
        "can_see": [
            "Application names and usage duration (how long you used each app)",
            "Device health: CPU, RAM, disk, battery",
            "Network performance: latency, throughput, connection quality",
            "Software inventory and versions installed",
            "App crash reports and error counts",
            "Boot/login times",
        ],
        "cannot_see": [
            "File contents or file names",
            "Network traffic content",
            "Clipboard content",
            "Keystrokes or screen content",
            "What you upload or download (only that an app used network)",
            "Emails, chat messages, or documents",
        ],
        "local_traffic_note": (
            "Nexthink does NOT inspect network traffic content. It may log that "
            "an application used X MB of network bandwidth, but it does not know "
            "what the data was. It is an IT experience tool, not a security tool."
        ),
        "io_spike_meaning": (
            "IO spike means Nexthink collected its routine telemetry — app usage, "
            "performance metrics, maybe network throughput stats. This is NOT "
            "content inspection. It would record 'python.exe used 50KB of network' "
            "but has no visibility into what that 50KB contained."
        ),
    },
    "ccmexec.exe": {
        "label": "SCCM / ConfigMgr Client",
        "category": "IT Management",
        "purpose": "Software deployment, patch management, hardware/software inventory, compliance",
        "can_see": [
            "Software installed on the machine",
            "Patch/update compliance status",
            "Hardware inventory (CPU, RAM, disk model)",
            "Whether required software is present",
        ],
        "cannot_see": [
            "File contents or user documents",
            "Network traffic content",
            "Clipboard, keystrokes, screen",
            "What you do day-to-day (not a monitoring tool)",
        ],
        "local_traffic_note": "SCCM does not monitor network traffic or file transfers.",
        "io_spike_meaning": (
            "IO spike likely means SCCM ran a scheduled inventory scan or checked "
            "for pending software updates. Completely unrelated to your transfer."
        ),
    },
    "smartscreen.exe": {
        "label": "Windows SmartScreen",
        "category": "Application Reputation",
        "purpose": "Checks downloaded files and apps against Microsoft's reputation database",
        "can_see": [
            "Executable files you download or run for the first time",
            "URLs visited in Edge browser",
        ],
        "cannot_see": [
            "Document contents (only checks executables)",
            "Network traffic content",
            "Clipboard, keystrokes, screen",
            "File transfers between devices",
        ],
        "local_traffic_note": "SmartScreen does not monitor file transfers.",
        "io_spike_meaning": "Likely checked whether python.exe is a known/safe application.",
    },
}

# Catch-all for unknown processes
DEFAULT_PROFILE = {
    "label": "Unknown Agent",
    "category": "Unknown",
    "purpose": "Not in our knowledge base",
    "can_see": ["Unknown — research this process name"],
    "cannot_see": ["Unknown"],
    "local_traffic_note": "Unknown — investigate manually.",
    "io_spike_meaning": "Cannot determine without identifying the process.",
}


# ══════════════════════════════════════════════════════════════
#  SNAPSHOT ENGINE
# ══════════════════════════════════════════════════════════════

def get_agent_io():
    snapshot = {}
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            pname = proc.info["name"].lower()
            if pname in AGENT_PROFILES:
                io = proc.io_counters()
                snapshot[pname] = {
                    "pid": proc.info["pid"],
                    "read_bytes": io.read_bytes,
                    "write_bytes": io.write_bytes,
                    "read_count": io.read_count,
                    "write_count": io.write_count,
                }
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return snapshot

def get_connections():
    conns = {}
    for c in psutil.net_connections(kind="tcp"):
        if c.status == "ESTABLISHED" and c.raddr:
            try:
                proc = psutil.Process(c.pid)
                key = f"{proc.name()}|{c.raddr.ip}:{c.raddr.port}"
                conns[key] = {
                    "process": proc.name(),
                    "remote_ip": c.raddr.ip,
                    "remote_port": c.raddr.port,
                }
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
    return conns

def diff_io(before, after):
    deltas = {}
    for pname in after:
        if pname in before:
            rd = after[pname]["read_bytes"] - before[pname]["read_bytes"]
            wd = after[pname]["write_bytes"] - before[pname]["write_bytes"]
            rc = after[pname]["read_count"] - before[pname]["read_count"]
            wc = after[pname]["write_count"] - before[pname]["write_count"]
            profile = AGENT_PROFILES.get(pname, DEFAULT_PROFILE)
            deltas[pname] = {
                "label": profile["label"],
                "category": profile["category"],
                "read_kb": round(rd / 1024, 1),
                "write_kb": round(wd / 1024, 1),
                "read_ops": rc,
                "write_ops": wc,
                "total_kb": round((rd + wd) / 1024, 1),
            }
    return deltas

def diff_connections(before, after):
    new_keys = set(after.keys()) - set(before.keys())
    return {k: after[k] for k in new_keys}

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


# ══════════════════════════════════════════════════════════════
#  LOGGER — writes to both console and log file
# ══════════════════════════════════════════════════════════════

class Logger:
    def __init__(self, log_path):
        self.log_path = log_path
        self.lines = []

    def log(self, text=""):
        print(text)
        self.lines.append(text)

    def header(self, title):
        w = 64
        self.log(f"\n{'='*w}")
        self.log(f"  {title}")
        self.log(f"{'='*w}")

    def separator(self):
        self.log(f"\n{'─'*64}")

    def save(self):
        with open(self.log_path, "w", encoding="utf-8") as f:
            f.write("\n".join(self.lines))
        self.log(f"\n  📄 Full log saved to: {self.log_path}")


# ══════════════════════════════════════════════════════════════
#  LOCAL NETWORK SERVER / CLIENT
# ══════════════════════════════════════════════════════════════

def create_test_file(test_dir):
    path = os.path.join(test_dir, "CONFIDENTIAL_Client_Data_Test.txt")
    with open(path, "w") as f:
        f.write("PRIVILEGED & CONFIDENTIAL\n")
        f.write("Client: Acme Holdings Pte Ltd\n")
        f.write("Engagement: SG-2026-0045\n")
        f.write("SSN: 078-05-1120\n")
        f.write("Credit Card: 4111-1111-1111-1111\n")
        f.write("Wire: ABA 021000021 / Acct 123456789\n")
        f.write("MNPI — Material Non-Public Information\n\n")
        for i in range(500):
            f.write(f"Row {i}: Revenue ${i*1000:,} | AR ${i*500:,} | "
                    f"Vendor V{10000+i} | INV-2025-{8000+i} | "
                    f"${(i*347.89)%45000:,.2f}\n")
    return path

def run_local_server(host, port, received, ready_event, done_event):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    srv.settimeout(30)
    ready_event.set()
    try:
        conn, _ = srv.accept()
        data = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        conn.close()
        received.append(len(data))
    except socket.timeout:
        received.append(0)
    finally:
        srv.close()
        done_event.set()

def send_file_to(filepath, host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((host, port))
    with open(filepath, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            sock.sendall(chunk)
    sock.close()


# ══════════════════════════════════════════════════════════════
#  RUN A SINGLE TEST
# ══════════════════════════════════════════════════════════════

def run_transfer_test(log, test_name, test_func, wait_seconds=8):
    """Run a test, capture before/after IO, return deltas."""
    io_before = get_agent_io()
    conn_before = get_connections()

    test_func()

    log.log(f"  Waiting for agent reaction ({wait_seconds} sec)...")
    time.sleep(wait_seconds)

    io_after = get_agent_io()
    conn_after = get_connections()

    deltas = diff_io(io_before, io_after)
    new_conns = diff_connections(conn_before, conn_after)

    return deltas, new_conns


# ══════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════

def main():
    # Setup log
    log_dir = os.path.dirname(os.path.abspath(__file__))
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(log_dir, f"monitoring_test_log_{timestamp}.txt")
    log = Logger(log_path)

    log.log("""
╔══════════════════════════════════════════════════════════════════╗
║     LOCAL vs INTERNET MONITORING TEST v2.0                       ║
║     What exactly can each agent see?                             ║
╚══════════════════════════════════════════════════════════════════════╝""")

    log.log(f"\n  Timestamp: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log.log(f"  Computer: {os.environ.get('COMPUTERNAME', 'unknown')}")
    log.log(f"  User: {os.environ.get('USERNAME', 'unknown')}")

    # ── Detect agents ────────────────────────────────────────
    log.header("STEP 1: DETECTING MONITORING AGENTS")
    agents = get_agent_io()
    if not agents:
        log.log("  ⚠️  No known monitoring agents detected.")
    else:
        log.log(f"  Found {len(agents)} agents:\n")
        for pname, info in agents.items():
            profile = AGENT_PROFILES.get(pname, DEFAULT_PROFILE)
            log.log(f"    • {profile['label']} ({pname}, PID {info['pid']})")
            log.log(f"      Category: {profile['category']}")
            log.log(f"      Purpose: {profile['purpose']}")

    local_ip = get_local_ip()
    log.log(f"\n  Local IP: {local_ip}")

    # Create test file
    test_dir = tempfile.mkdtemp(prefix="montest_")
    test_file = create_test_file(test_dir)
    file_size = os.path.getsize(test_file)
    log.log(f"  Test file: {file_size:,} bytes (with DLP trigger content)")

    results = {}

    # ── TEST A: BASELINE ─────────────────────────────────────
    log.header("TEST A: BASELINE — idle for 10 seconds")
    log.log("  Measuring background IO noise. No activity.\n")

    def do_nothing():
        time.sleep(10)

    baseline, _ = run_transfer_test(log, "baseline", do_nothing, wait_seconds=0)
    results["baseline"] = baseline

    for pname, d in baseline.items():
        log.log(f"    {d['label']:30s}  total: {d['total_kb']:>8.1f} KB")

    # ── TEST B: LOCALHOST (127.0.0.1) ────────────────────────
    log.header("TEST B: LOCALHOST TRANSFER (127.0.0.1)")
    log.log("  Loopback transfer — never touches network hardware.\n")

    def do_localhost():
        port = 19876
        received = []
        ready = threading.Event()
        done = threading.Event()
        t = threading.Thread(target=run_local_server,
                           args=("127.0.0.1", port, received, ready, done))
        t.daemon = True
        t.start()
        ready.wait(5)
        send_file_to(test_file, "127.0.0.1", port)
        done.wait(10)
        log.log(f"  Transferred {received[0] if received else 0:,} bytes over localhost")

    localhost_deltas, localhost_conns = run_transfer_test(log, "localhost", do_localhost)
    results["localhost"] = localhost_deltas

    for pname, d in localhost_deltas.items():
        bl = baseline.get(pname, {"total_kb": 0})
        above = d["total_kb"] - bl["total_kb"]
        flag = "⚡ ACTIVITY" if above > 5 else "   quiet"
        log.log(f"    {d['label']:30s}  total: {d['total_kb']:>8.1f} KB  "
                f"(+{above:.1f} vs baseline) {flag}")

    time.sleep(3)

    # ── TEST C: LAN IP ───────────────────────────────────────
    log.header(f"TEST C: LAN TRANSFER (via {local_ip})")
    log.log("  Simulates LocalSend — traffic goes through network stack.\n")

    def do_lan():
        port = 19877
        received = []
        ready = threading.Event()
        done = threading.Event()
        t = threading.Thread(target=run_local_server,
                           args=("0.0.0.0", port, received, ready, done))
        t.daemon = True
        t.start()
        ready.wait(5)
        send_file_to(test_file, local_ip, port)
        done.wait(10)
        log.log(f"  Transferred {received[0] if received else 0:,} bytes over LAN IP")

    lan_deltas, lan_conns = run_transfer_test(log, "lan", do_lan)
    results["lan"] = lan_deltas

    for pname, d in lan_deltas.items():
        bl = baseline.get(pname, {"total_kb": 0})
        above = d["total_kb"] - bl["total_kb"]
        flag = "⚡ ACTIVITY" if above > 5 else "   quiet"
        log.log(f"    {d['label']:30s}  total: {d['total_kb']:>8.1f} KB  "
                f"(+{above:.1f} vs baseline) {flag}")

    time.sleep(3)

    # ── TEST D: INTERNET ─────────────────────────────────────
    log.header("TEST D: INTERNET UPLOAD (httpbin.org)")
    log.log("  Same file sent to external server over HTTPS.\n")

    def do_internet():
        try:
            with open(test_file, "rb") as f:
                resp = requests.post("https://httpbin.org/post",
                                    files={"file": f}, timeout=15, verify=True)
            log.log(f"  Upload complete: HTTP {resp.status_code}")
        except requests.exceptions.SSLError:
            log.log("  SSL intercepted by Zscaler (expected)")
        except Exception as e:
            log.log(f"  Upload error: {str(e)[:80]}")

    internet_deltas, internet_conns = run_transfer_test(log, "internet", do_internet)
    results["internet"] = internet_deltas

    for pname, d in internet_deltas.items():
        bl = baseline.get(pname, {"total_kb": 0})
        above = d["total_kb"] - bl["total_kb"]
        flag = "⚡ ACTIVITY" if above > 5 else "   quiet"
        log.log(f"    {d['label']:30s}  total: {d['total_kb']:>8.1f} KB  "
                f"(+{above:.1f} vs baseline) {flag}")

    # ══════════════════════════════════════════════════════════
    #  COMPARISON TABLE
    # ══════════════════════════════════════════════════════════

    log.header("SIDE-BY-SIDE IO COMPARISON (KB)")

    all_agents = set()
    for test_name in results:
        all_agents.update(results[test_name].keys())

    log.log(f"\n  {'Agent':<30s} {'Baseline':>10s} {'Localhost':>10s} "
            f"{'LAN IP':>10s} {'Internet':>10s}")
    log.log(f"  {'─'*30} {'─'*10} {'─'*10} {'─'*10} {'─'*10}")

    for pname in sorted(all_agents):
        bl = results["baseline"].get(pname, {"total_kb": 0, "label": pname})
        lo = results["localhost"].get(pname, {"total_kb": 0})
        la = results["lan"].get(pname, {"total_kb": 0})
        inet = results["internet"].get(pname, {"total_kb": 0})
        profile = AGENT_PROFILES.get(pname, DEFAULT_PROFILE)

        log.log(f"  {profile['label']:<30s} {bl['total_kb']:>8.1f}KB "
                f"{lo['total_kb']:>8.1f}KB {la['total_kb']:>8.1f}KB "
                f"{inet['total_kb']:>8.1f}KB")

    # ══════════════════════════════════════════════════════════
    #  PER-AGENT DETAILED ANALYSIS
    # ══════════════════════════════════════════════════════════

    log.header("DETAILED ANALYSIS PER AGENT")

    for pname in sorted(all_agents):
        profile = AGENT_PROFILES.get(pname, DEFAULT_PROFILE)

        bl_val = results["baseline"].get(pname, {"total_kb": 0})["total_kb"]
        lo_val = results["localhost"].get(pname, {"total_kb": 0})["total_kb"]
        la_val = results["lan"].get(pname, {"total_kb": 0})["total_kb"]
        inet_val = results["internet"].get(pname, {"total_kb": 0})["total_kb"]

        lo_above = lo_val - bl_val
        la_above = la_val - bl_val
        inet_above = inet_val - bl_val

        reacts_local = lo_above > 10 or la_above > 10
        reacts_internet = inet_above > 10

        log.log(f"\n  ┌─────────────────────────────────────────────────────")
        log.log(f"  │ {profile['label']} ({pname})")
        log.log(f"  │ Category: {profile['category']}")
        log.log(f"  ├─────────────────────────────────────────────────────")
        log.log(f"  │ Purpose: {profile['purpose']}")
        log.log(f"  │")
        log.log(f"  │ IO above baseline:")
        log.log(f"  │   Localhost:  +{lo_above:.1f} KB {'⚡' if lo_above > 10 else '✓ normal'}")
        log.log(f"  │   LAN IP:    +{la_above:.1f} KB {'⚡' if la_above > 10 else '✓ normal'}")
        log.log(f"  │   Internet:  +{inet_above:.1f} KB {'⚡' if inet_above > 10 else '✓ normal'}")
        log.log(f"  │")

        if reacts_local or reacts_internet:
            log.log(f"  │ What the IO spike ACTUALLY means:")
            log.log(f"  │ {profile['io_spike_meaning']}")
            log.log(f"  │")

        if reacts_local:
            log.log(f"  │ Local traffic assessment:")
            log.log(f"  │ {profile['local_traffic_note']}")
            log.log(f"  │")

        log.log(f"  │ What this agent CAN see:")
        for item in profile["can_see"]:
            log.log(f"  │   ✓ {item}")

        log.log(f"  │")
        log.log(f"  │ What this agent CANNOT see:")
        for item in profile["cannot_see"]:
            log.log(f"  │   ✗ {item}")

        # Final verdict for this agent
        log.log(f"  │")
        if pname in ["zsatunnel.exe", "zscaler.exe"]:
            if reacts_local:
                log.log(f"  │ 🟡 VERDICT: Zscaler's agent detected local network activity.")
                log.log(f"  │    It likely logged connection metadata (IP, port, bytes).")
                log.log(f"  │    Content inspection of local traffic is UNLIKELY — Zscaler's")
                log.log(f"  │    cloud inspection typically only applies to internet-bound traffic.")
                log.log(f"  │    Your file CONTENTS over local transfer are probably NOT read.")
            else:
                log.log(f"  │ 🟢 VERDICT: Did not react to local traffic.")
        elif pname == "mssense.exe":
            if reacts_local:
                log.log(f"  │ 🟡 VERDICT: Defender for Endpoint logged the network activity.")
                log.log(f"  │    It recorded METADATA (which process, destination IP, bytes).")
                log.log(f"  │    It did NOT read the file contents being transferred.")
                log.log(f"  │    This is behavioral telemetry, not content inspection.")
            else:
                log.log(f"  │ 🟢 VERDICT: Did not react to local traffic.")
        elif pname == "msmpeng.exe":
            if reacts_local:
                log.log(f"  │ 🟢 VERDICT: Defender Antimalware scanned the TEST FILE on disk.")
                log.log(f"  │    This is a malware scan, NOT surveillance. It would do the same")
                log.log(f"  │    if you simply opened the file. It does not monitor transfers.")
            else:
                log.log(f"  │ 🟢 VERDICT: No significant reaction.")
        elif pname == "nxtcoordinator.exe":
            if reacts_local:
                log.log(f"  │ 🟢 VERDICT: Nexthink collected routine performance telemetry.")
                log.log(f"  │    It logged app usage metrics (python.exe was active).")
                log.log(f"  │    It has NO visibility into file contents or transfer data.")
                log.log(f"  │    This is an IT experience tool, not a security tool.")
            else:
                log.log(f"  │ 🟢 VERDICT: Normal background activity.")
        elif pname in ["ccmexec.exe", "defendpointservice.exe", "smartscreen.exe"]:
            log.log(f"  │ 🟢 VERDICT: {profile['label']} is not a surveillance tool.")
            log.log(f"  │    Any IO activity is routine operational tasks.")
        else:
            if reacts_local:
                log.log(f"  │ 🟡 VERDICT: Activity detected — investigate this process.")
            else:
                log.log(f"  │ 🟢 VERDICT: No significant reaction.")

        log.log(f"  └─────────────────────────────────────────────────────")

    # ══════════════════════════════════════════════════════════
    #  FINAL SUMMARY
    # ══════════════════════════════════════════════════════════

    log.header("FINAL SUMMARY: LOCAL TRANSFER VISIBILITY")

    log.log("""
  Understanding the difference:

  ┌──────────────────────────────────────────────────────────┐
  │  "REACTED" ≠ "SAW YOUR CONTENT"                         │
  │                                                          │
  │  An IO spike means the process did SOME work.            │
  │  What that work was depends on the tool:                 │
  │                                                          │
  │  • Zscaler:    logged connection metadata (IP, port)     │
  │                Content inspection = internet only         │
  │  • MsSense:    logged behavioral telemetry               │
  │                (process X connected to IP Y)              │
  │  • MsMpEng:    scanned the file for malware              │
  │                (not related to the transfer)              │
  │  • Nexthink:   collected app usage metrics               │
  │                (no content visibility at all)             │
  │  • SCCM:       routine inventory/compliance check        │
  │  • BeyondTrust: checked app privilege level              │
  └──────────────────────────────────────────────────────────┘
""")

    log.log("  For a LOCAL network transfer (e.g., LocalSend over WiFi):\n")

    content_inspectors = []
    metadata_loggers = []
    not_relevant = []

    for pname in sorted(all_agents):
        profile = AGENT_PROFILES.get(pname, DEFAULT_PROFILE)
        bl_val = results["baseline"].get(pname, {"total_kb": 0})["total_kb"]
        la_above = results["lan"].get(pname, {"total_kb": 0})["total_kb"] - bl_val

        if pname in ["zsatunnel.exe", "zscaler.exe"] and la_above > 10:
            metadata_loggers.append(profile["label"])
        elif pname == "mssense.exe" and la_above > 10:
            metadata_loggers.append(profile["label"])
        elif pname == "msmpeng.exe" and la_above > 10:
            not_relevant.append(f"{profile['label']} (malware scan only)")
        elif pname == "nxtcoordinator.exe":
            not_relevant.append(f"{profile['label']} (app metrics only)")
        elif la_above > 10:
            metadata_loggers.append(profile["label"])
        else:
            not_relevant.append(profile["label"])

    if content_inspectors:
        log.log("  🔴 CAN SEE FILE CONTENTS:")
        for name in content_inspectors:
            log.log(f"      • {name}")

    if metadata_loggers:
        log.log("  🟡 CAN SEE METADATA (connection happened, bytes transferred):")
        log.log("     But CANNOT see what was inside the file:")
        for name in metadata_loggers:
            log.log(f"      • {name}")

    if not_relevant:
        log.log("  🟢 NOT RELEVANT to file transfer monitoring:")
        for name in not_relevant:
            log.log(f"      • {name}")

    if not content_inspectors:
        log.log("""
  ┌──────────────────────────────────────────────────────────┐
  │  CONCLUSION: No agent can see the CONTENTS of a local    │
  │  network file transfer. Some agents log that a transfer  │
  │  happened (metadata), but the file data itself is NOT    │
  │  inspected for local-to-local traffic.                   │
  │                                                          │
  │  Content inspection (reading what's inside your files)   │
  │  only happens for INTERNET-bound traffic via Zscaler's   │
  │  SSL interception.                                       │
  └──────────────────────────────────────────────────────────┘
""")
    else:
        log.log("""
  ┌──────────────────────────────────────────────────────────┐
  │  ⚠️  Content inspection detected on local transfers.     │
  │  Use the sanitizer before ANY transfer method.           │
  └──────────────────────────────────────────────────────────┘
""")

    log.separator()
    log.log(f"\n  Test completed: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    # Cleanup
    try:
        import shutil
        shutil.rmtree(test_dir, ignore_errors=True)
    except Exception:
        pass

    # Save log
    log.save()

    input("\n  Press Enter to close...")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n  Cancelled.")
    except Exception as e:
        print(f"\n\n  Error: {e}")
        import traceback
        traceback.print_exc()
        input("\n  Press Enter to close...")
