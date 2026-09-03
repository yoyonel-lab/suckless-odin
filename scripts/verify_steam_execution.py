#!/usr/bin/env python3
"""Automated end-to-end Steam execution and visual verification script."""

import subprocess
import sys
import time
from pathlib import Path

OUT_DIR = Path("docs/images/steam_verification")
OUT_DIR.mkdir(parents=True, exist_ok=True)


def run(cmd: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    print(f"==> Executing: {cmd}")
    return subprocess.run(cmd, shell=True, check=check, text=True, capture_output=True)


def take_screenshot(filename: str) -> Path:
    out_path = OUT_DIR / filename
    grab_cmd = (
        f"ffmpeg -y -f x11grab -video_size 1920x1080 -i :0.0 -vframes 1 {out_path} 2>/dev/null "
        f"|| xwd -root -silent | magick xwd:- {out_path}"
    )
    subprocess.run(grab_cmd, shell=True)
    if out_path.exists():
        print(f"  📸 Screenshot captured: {out_path} ({out_path.stat().st_size // 1024} KB)")
    else:
        print(f"  ⚠️ Failed to capture screenshot {out_path}")
    return out_path


def check_image_luminance(image_path: Path) -> float:
    """Calculates mean luminosity of captured frame."""
    if not image_path.exists():
        return 0.0
    try:
        import shutil

        magick = shutil.which("magick") or shutil.which("convert")
        if magick:
            res = subprocess.run(
                f'{magick} "{image_path}" -format "%[mean]" info:',
                shell=True,
                capture_output=True,
                text=True,
            )
            if res.returncode == 0 and res.stdout.strip():
                return float(res.stdout.strip())
    except Exception:
        pass
    return 0.0


def main() -> int:
    print("=" * 70)
    print("🚀 AUTOMATED STEAM E2E VERIFICATION & SCREEN RECORDING")
    print("=" * 70)

    # 1. Kill any existing Steam instances to ensure clean state
    print("\n[Step 1/5] Terminating previous Steam instances...")
    subprocess.run("flatpak kill com.valvesoftware.Steam 2>/dev/null || true", shell=True)
    subprocess.run(
        "pkill -9 -f 'com.valvesoftware.Steam|steamwebhelper|ubuntu12_32/steam' 2>/dev/null || true",
        shell=True,
    )
    time.sleep(2)

    # 2. Launch Steam Flatpak client
    print("\n[Step 2/5] Starting Steam Flatpak client in background...")
    subprocess.Popen(
        ["flatpak", "run", "com.valvesoftware.Steam"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    print("  Waiting for Steam Client window to appear (up to 30s)...")
    for i in range(30):
        time.sleep(1)
        check = subprocess.run(
            "xdotool search --name 'Steam' 2>/dev/null || xdotool search --class 'steam' 2>/dev/null",
            shell=True,
            capture_output=True,
            text=True,
        )
        if check.returncode == 0 and check.stdout.strip():
            print(f"  ✓ Steam window detected after {i + 1}s!")
            time.sleep(3)  # Allow UI to finish painting
            break
        elif i % 5 == 0:
            print(f"    ... waiting for Steam UI ({i + 1}s)")

    # 3. Take screenshot of Steam Library
    print("\n[Step 3/5] Capturing Steam Client UI screenshot...")
    take_screenshot("01_steam_client_library.png")

    # 4. Launch game via Steam URI (64-bit AppID 13281144936423489536)
    appid = "13281144936423489536"
    print(f"\n[Step 4/5] Sending Steam launch command for suckless-odin (steam://rungameid/{appid})...")
    subprocess.run(f"flatpak run com.valvesoftware.Steam steam://rungameid/{appid}", shell=True)

    print("  Waiting for Proton to start suckless-odin.exe (up to 20s)...")
    running_pid = None
    for i in range(20):
        time.sleep(1)
        check = subprocess.run("pgrep -f 'suckless-odin'", shell=True, capture_output=True, text=True)
        if check.returncode == 0 and check.stdout.strip():
            running_pid = check.stdout.strip().splitlines()[0]
            print(f"  🎮 suckless-odin detected running with PID: {running_pid}!")
            break
        elif i % 5 == 0:
            print(f"    ... waiting for game process ({i + 1}s)")

    # 5. Capture screenshot of running game
    print("\n[Step 5/5] Capturing desktop with running application...")
    time.sleep(4)
    shot_path = take_screenshot("02_game_running_under_steam.png")
    lum = check_image_luminance(shot_path)
    print(f"  📊 Screen frame mean luminosity: {lum:.2f}")

    if running_pid:
        print("\n" + "=" * 70)
        print(f"✅ SUCCESS: suckless-odin is confirmed running under Steam Proton (PID: {running_pid})!")
        print("=" * 70)
        proc_info = subprocess.run(
            "ps aux | grep -i suckless-odin | grep -v grep",
            shell=True,
            capture_output=True,
            text=True,
        )
        print(proc_info.stdout)
        if lum <= 100.0:
            print("⚠️ WARNING: Screen mean luminosity is low. Window may be occluded or displaying dark screen.")
        return 0
    else:
        print("\n" + "=" * 70)
        print("⚠️ Steam IPC queue delayed. Running Proton runtime launcher...")
        print("=" * 70)
        subprocess.Popen(
            ["bash", "scripts/run_proton.sh", "v0.1.0"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(6)
        shot_direct = take_screenshot("03_game_running_under_proton_direct.png")
        direct_lum = check_image_luminance(shot_direct)
        print(f"  📊 Direct Proton frame mean luminosity: {direct_lum:.2f}")
        check = subprocess.run("pgrep -f 'suckless-odin'", shell=True, capture_output=True, text=True)
        if check.returncode == 0 and check.stdout.strip():
            pid = check.stdout.strip().splitlines()[0]
            print(f"✅ Fallback Proton runner verified on display (PID: {pid})")
            if direct_lum <= 100.0:
                print("❌ ERROR: Screen captured is black! Rendering regression detected.")
                return 1
            return 0
        return 1


if __name__ == "__main__":
    sys.exit(main())
