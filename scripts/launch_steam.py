#!/usr/bin/env python3
"""Steam Launch Controller & Process Lifecycle Manager for suckless-odin.

Features:
- Dynamically resolves 64-bit Non-Steam AppID from packaged binary.
- Detects Steam installation type (Flatpak / Native / Snap).
- Verifies Steam client process status before dispatching URI command.
- If Steam is not running, starts it cleanly and waits for readiness.
- Dispatches 'steam://rungameid/<id>' with error handling.
- Polls and verifies game process startup under Proton with PID & metrics.
- Provides actionable diagnostic advice on timeout or misconfiguration.
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
import zlib
from pathlib import Path


def find_target_executable(custom_path: str | None = None) -> Path:
    """Finds suckless-odin.exe Windows binary."""
    if custom_path:
        p = Path(custom_path).resolve()
        if p.exists() and p.is_file():
            return p
        sys.exit(f"❌ Error: Specified executable not found: {custom_path}")

    # Standard locations
    candidates = [
        Path("build-release/suckless-odin-windows-v0.1.0/suckless-odin.exe"),
        Path("build/release-win/suckless-odin.exe"),
    ]
    for c in candidates:
        if c.exists():
            return c.resolve()

    glob_matches = list(Path("build-release").glob("suckless-odin-windows-*/suckless-odin.exe"))
    if glob_matches:
        return glob_matches[0].resolve()

    sys.exit(
        "❌ Error: suckless-odin.exe not found.\n"
        "👉 Run 'task package-win' or 'task steam-update' first to build and package."
    )


def compute_app_ids(exe_path: Path, app_name: str = "suckless-odin") -> tuple[int, int]:
    """Computes 32-bit CRC32 AppID and 64-bit Steam shortcut rungameid."""
    key = f'"{exe_path}"{app_name}'.encode()
    crc = zlib.crc32(key)
    u32_id = crc | 0x80000000
    u64_id = ((u32_id | 0x80000000) << 32) | 0x02000000
    return u32_id, u64_id


def detect_steam_launcher() -> tuple[str, list[str]]:
    """Detects available Steam launcher command (Flatpak / Native / Snap)."""
    if shutil.which("flatpak"):
        res = subprocess.run(
            ["flatpak", "info", "com.valvesoftware.Steam"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if res.returncode == 0:
            return "flatpak", ["flatpak", "run", "com.valvesoftware.Steam"]

    if shutil.which("steam"):
        return "native", ["steam"]

    if shutil.which("snap"):
        res = subprocess.run(
            ["snap", "list", "steam"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if res.returncode == 0:
            return "snap", ["snap", "run", "steam"]

    return "unknown", ["xdg-open"]


def is_steam_running() -> tuple[bool, list[int]]:
    """Checks if Steam client processes are currently active."""
    try:
        res = subprocess.run(
            ["pgrep", "-f", "com.valvesoftware.Steam|ubuntu12_32/steam|steamwebhelper|/usr/lib/steam/steam"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        pids = [int(p) for p in res.stdout.strip().splitlines() if p.isdigit()]
        # Filter out current python script PID
        my_pid = os.getpid()
        pids = [p for p in pids if p != my_pid]
        return len(pids) > 0, pids
    except Exception:
        return False, []


def is_game_running() -> tuple[bool, int | None]:
    """Checks if suckless-odin process is currently running."""
    try:
        res = subprocess.run(
            ["pgrep", "-f", "suckless-odin"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        my_pid = os.getpid()
        for line in res.stdout.strip().splitlines():
            if line.isdigit():
                pid = int(line)
                if pid != my_pid:
                    return True, pid
        return False, None
    except Exception:
        return False, None


def wait_for_steam_ready(launcher_type: str, launcher_cmd: list[str], timeout_secs: int = 30) -> bool:
    """Launches Steam client and waits until it becomes responsive."""
    print("  🚀 Starting Steam client in background...")
    subprocess.Popen(
        launcher_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    print(f"  ⏳ Waiting for Steam client to initialize (up to {timeout_secs}s)...", end="", flush=True)
    start_time = time.time()
    while time.time() - start_time < timeout_secs:
        time.sleep(1)
        print(".", end="", flush=True)

        running, _ = is_steam_running()
        if running:
            # Check window presence via xdotool if available
            if shutil.which("xdotool"):
                win_check = subprocess.run(
                    ["xdotool", "search", "--name", "Steam"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                if win_check.returncode == 0 and win_check.stdout.strip():
                    print(" ✓ Steam UI window ready!")
                    time.sleep(2)  # Allow IPC server to settle
                    return True
            else:
                # Give a 4-second grace period for IPC sockets to open
                time.sleep(4)
                print(" ✓ Steam process active!")
                return True

    print(" ⚠️ Timeout reached waiting for Steam UI.")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Launch suckless-odin through official Steam client with full lifecycle verification."
    )
    parser.add_argument(
        "--exe",
        type=str,
        default=None,
        help="Path to suckless-odin.exe (default: auto-detect from build-release)",
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Send launch signal and exit immediately without polling game process",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=25,
        help="Maximum seconds to wait for game process to start under Proton (default: 25s)",
    )
    parser.add_argument(
        "--no-start-steam",
        action="store_true",
        help="Do not automatically start Steam client if not running",
    )
    args = parser.parse_args()

    print("=" * 70)
    print("🎮 STEAM APPLICATION LAUNCHER & PROCESS MONITOR")
    print("=" * 70)

    # 1. Resolve binary and AppID
    target_exe = find_target_executable(args.exe)
    u32_id, u64_id = compute_app_ids(target_exe)
    steam_uri = f"steam://rungameid/{u64_id}"

    print(f"📦 Executable : {target_exe}")
    print(f"🆔 AppID (u32): {u32_id} (0x{u32_id:08X})")
    print(f"🆔 AppID (u64): {u64_id}")
    print(f"🔗 Steam URI  : {steam_uri}")

    # 2. Detect Steam Environment
    launcher_type, launcher_cmd = detect_steam_launcher()
    print(f"🌐 Environment: Steam {launcher_type.capitalize()} ({' '.join(launcher_cmd)})")

    # 3. Verify Steam Process Status
    running, pids = is_steam_running()
    if running:
        print(f"✓ Steam client is running (detected {len(pids)} active process(es)).")
    else:
        print("⚠️ Steam client is NOT running.")
        if not args.no_start_steam:
            ready = wait_for_steam_ready(launcher_type, launcher_cmd)
            if not ready:
                print("⚠️ Warning: Proceeding with launch attempt anyway...")
        else:
            sys.exit("❌ Error: Steam is not running and --no-start-steam was requested.")

    # 4. Check if game is already running
    game_running, existing_pid = is_game_running()
    if game_running:
        print(f"ℹ️ Note: suckless-odin is already running (PID: {existing_pid}).")
        return 0

    # 5. Dispatch Launch Command
    print(f"\n==> Dispatching launch command to Steam ({steam_uri})...")
    dispatch_cmd = list(launcher_cmd)
    if launcher_type == "unknown":
        dispatch_cmd = ["xdg-open", steam_uri]
    else:
        dispatch_cmd.append(steam_uri)

    try:
        res = subprocess.run(
            dispatch_cmd,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode != 0:
            print(f"❌ Steam dispatch command returned exit code {res.returncode}:")
            if res.stderr:
                print(f"   {res.stderr.strip()}")
        else:
            print("✓ Launch command successfully delivered to Steam client.")
    except subprocess.TimeoutExpired:
        print("✓ Launch command sent (process backgrounded).")
    except Exception as e:
        sys.exit(f"❌ Failed to dispatch Steam command: {e}")

    if args.no_wait:
        print("👉 Running in non-blocking mode (--no-wait). Exiting.")
        return 0

    # 6. Monitor & Confirm Game Process Startup under Proton
    print(f"\n==> Monitoring game process startup under Proton (timeout: {args.timeout}s)...")
    start_time = time.time()
    game_pid = None

    while time.time() - start_time < args.timeout:
        time.sleep(1)
        running, pid = is_game_running()
        if running:
            game_pid = pid
            break
        elapsed = int(time.time() - start_time)
        if elapsed % 5 == 0:
            print(f"    ... waiting for Proton runtime & game launch ({elapsed}s/{args.timeout}s)")

    if game_pid:
        print("\n" + "=" * 70)
        print(f"✅ SUCCESS: suckless-odin is RUNNING under Steam / Proton (PID: {game_pid})!")
        print("=" * 70)

        # Query process info
        try:
            pinfo = subprocess.run(
                ["ps", "-p", str(game_pid), "-o", "pid,user,%cpu,%mem,vsz,rss,stat,etime,command"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            if pinfo.returncode == 0:
                print(pinfo.stdout.strip())
        except Exception:
            pass
        return 0
    else:
        print("\n" + "=" * 70)
        print(f"⚠️ TIMEOUT ({args.timeout}s): suckless-odin process was not detected.")
        print("=" * 70)
        print("💡 Diagnostic checklist:")
        print("  1. Is suckless-odin added in your Steam library?")
        print("     👉 Run 'task steam-update' to re-inject shortcuts.vdf and artworks.")
        print("  2. If shortcuts were just injected, Steam needs a restart to load shortcuts.vdf.")
        print("     👉 Run 'task steam-update' (which terminates Steam, updates VDF, and prepares launch).")
        print("  3. Check Steam Client UI -> Library -> suckless-odin -> Properties -> Compatibility -> Proton.")
        print("=" * 70)
        return 1


if __name__ == "__main__":
    sys.exit(main())
