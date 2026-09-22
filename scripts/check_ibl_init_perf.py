#!/usr/bin/env python3
"""
check_ibl_init_perf.py — Regression guard for IBL environment loading latency.

Baselines (master commit dca186c):
  Linux Native : 1302.90 ms (Threshold +20%: 1563.48 ms)
  Windows Wine : 1424.17 ms (Threshold +20%: 1709.00 ms)

Runs suckless-odin in benchmark mode (--benchmark --benchmark-frames=300),
extracts 'IBL environment ready in X.XX ms', and fails if latency exceeds
baseline + 20% margin.
"""

import argparse
import os
import re
import subprocess
import sys

LINUX_BASELINE_MS = 1302.90
LINUX_THRESHOLD_MS = LINUX_BASELINE_MS * 1.20  # ~1563.48 ms

WIN_BASELINE_MS = 1424.17
WIN_THRESHOLD_MS = WIN_BASELINE_MS * 1.20  # ~1709.00 ms

PATTERN = re.compile(r"IBL environment ready in\s+([0-9.]+)\s+ms")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check IBL initialization latency against regression threshold")
    parser.add_argument("--win", action="store_true", help="Run / check Windows executable under Wine")
    parser.add_argument("--log", type=str, default="", help="Path to existing log file to parse instead of executing")
    parser.add_argument("--baseline", type=float, default=0.0, help="Override baseline in ms")
    parser.add_argument("--threshold", type=float, default=0.0, help="Override threshold in ms")
    parser.add_argument("--frames", type=int, default=300, help="Number of benchmark frames to run")
    parser.add_argument("--profile", type=str, default="quality", help="Optimization profile")
    args = parser.parse_args()

    is_win = args.win
    platform_name = "Windows (Wine)" if is_win else "Linux (Native)"

    env_baseline = os.environ.get("IBL_BASELINE_MS")
    env_threshold = os.environ.get("IBL_THRESHOLD_MS")

    if args.baseline > 0.0:
        baseline = args.baseline
    elif env_baseline:
        baseline = float(env_baseline)
    else:
        baseline = WIN_BASELINE_MS if is_win else LINUX_BASELINE_MS

    if args.threshold > 0.0:
        threshold = args.threshold
    elif env_threshold:
        threshold = float(env_threshold)
    else:
        threshold = baseline * 1.20

    log_output = ""
    if args.log:
        if not os.path.isfile(args.log):
            print(f"❌ ERROR: Specified log file '{args.log}' does not exist.")
            return 1
        with open(args.log, encoding="utf-8", errors="replace") as f:
            log_output = f.read()
    else:
        root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if is_win:
            exe_path = os.path.join(root_dir, "build", "release-win", "suckless-odin.exe")
            if not os.path.isfile(exe_path):
                print(f"❌ ERROR: Windows binary not found: {exe_path}. Build it first (task build-win-release).")
                return 1
            cmd = [
                "wine",
                exe_path,
                "--benchmark",
                f"--benchmark-frames={args.frames}",
                f"--opt-profile={args.profile}",
            ]
            env = os.environ.copy()
            env["WINEDEBUG"] = "-all"
            env["vblank_mode"] = "0"
            env["__GL_SYNC_TO_VBLANK"] = "0"
        else:
            exe_path = os.path.join(root_dir, "build", "release", "suckless-odin")
            if not os.path.isfile(exe_path):
                print(f"❌ ERROR: Linux binary not found: {exe_path}. Build it first (task build-release).")
                return 1
            cmd = [exe_path, "--benchmark", f"--benchmark-frames={args.frames}", f"--opt-profile={args.profile}"]
            env = os.environ.copy()
            env["mesa_glthread"] = "true"
            env["MESA_NO_ERROR"] = "1"
            env["vblank_mode"] = "0"
            env["__GL_SYNC_TO_VBLANK"] = "0"

        print(f"==> Measuring IBL initialization latency on {platform_name}...")
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        log_output = proc.stdout

    match = PATTERN.search(log_output)
    if not match:
        print("❌ ERROR: 'IBL environment ready in ... ms' log not found in execution output!")
        print("Tail of output:")
        print("\n".join(log_output.splitlines()[-30:]))
        return 1

    measured_ms = float(match.group(1))
    delta_vs_baseline = measured_ms - baseline
    delta_pct = (delta_vs_baseline / baseline) * 100.0

    print("==========================================================================")
    print(f"IBL INITIALIZATION LATENCY AUDIT — {platform_name}")
    print(f"  Baseline Reference  : {baseline:8.2f} ms")
    print(f"  Max Allowed (+20%)  : {threshold:8.2f} ms")
    print(f"  Measured Latency    : {measured_ms:8.2f} ms ({delta_pct:+.1f} % vs baseline)")
    print("--------------------------------------------------------------------------")

    if measured_ms > threshold:
        diff_ms = measured_ms - threshold
        print(f"❌ REGRESSION DETECTED: {measured_ms:.2f} ms exceeds threshold {threshold:.2f} ms (+{diff_ms:.2f} ms)!")
        print("==========================================================================")
        return 1
    else:
        margin_ms = threshold - measured_ms
        print(f"✅ PASS: Latency {measured_ms:.2f} ms within budget (headroom: {margin_ms:.2f} ms).")
        print("==========================================================================")
        return 0


if __name__ == "__main__":
    sys.exit(main())
