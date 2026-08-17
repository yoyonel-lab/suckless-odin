#!/usr/bin/env python3
import csv
import os
import sys


def analyze(csv_file="profiling/tracy_frames.csv"):
    if not os.path.exists(csv_file):
        # Fallback to searching common trace locations
        candidates = ["/tmp/trace_unwrapped.csv", "/tmp/tracy_frames.csv", "profiling/tracy_frames.csv"]
        for c in candidates:
            if os.path.exists(c):
                csv_file = c
                break

    if not os.path.exists(csv_file):
        print(f"Error: Trace CSV file '{csv_file}' not found.", file=sys.stderr)
        sys.exit(1)

    frame_times_ms = []
    try:
        with open(csv_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                if "exec_time_ns" in row:
                    ns = int(row["exec_time_ns"])
                    # Filter Frame zones or raw frames
                    if "name" not in row or row["name"] == "Frame":
                        frame_times_ms.append(ns / 1e6)
                elif "duration_ms" in row:
                    frame_times_ms.append(float(row["duration_ms"]))
    except Exception as e:
        print(f"Error reading CSV: {e}", file=sys.stderr)
        sys.exit(1)

    if not frame_times_ms:
        print("No frame data found in trace.", file=sys.stderr)
        sys.exit(1)

    frame_times_ms.sort(reverse=True)  # Worst frame first
    fps = [1000.0 / t for t in frame_times_ms if t > 0]
    fps.sort()  # Lowest FPS first

    total_frames = len(fps)
    avg_fps = sum(fps) / total_frames
    min_fps = fps[0]
    max_fps = fps[-1]

    print("==========================================================================")
    print("                    FPS & FRAME TIME ANALYSIS                             ")
    print("==========================================================================")
    print(f"Total Frames Analyzed : {total_frames}")
    print(f"Average FPS           : {avg_fps:.2f} (Avg Frame Time: {1000.0 / avg_fps:.2f} ms)")
    print(f"Min FPS (Worst Spike) : {min_fps:.2f} ({1000.0 / min_fps:.2f} ms)")
    print(f"Max FPS (Peak)        : {max_fps:.2f} ({1000.0 / max_fps:.2f} ms)")
    print("--------------------------------------------------------------------------")
    print("Percentiles:")

    def percentile(data, p):
        k = (len(data) - 1) * (p / 100.0)
        f = int(k)
        c = f + 1 if f + 1 < len(data) else f
        d = k - f
        return data[f] + d * (data[c] - data[f])

    percentiles = [1, 5, 10, 25, 50, 75, 90, 95, 99]
    for p in percentiles:
        val = percentile(fps, p)
        print(f"  {p:>2}th Percentile (worst {p:>2}%) : {val:>7.2f} FPS ({1000.0 / val:>6.2f} ms)")

    # Transition spikes (< 30 FPS)
    low_fps_frames = [(i, f) for i, f in enumerate(fps) if f < 30.0]
    if low_fps_frames:
        print("--------------------------------------------------------------------------")
        print(f"⚠️  Found {len(low_fps_frames)} frames below 30 FPS (Spikes during HDR cycle)")
        print("Worst frames:")
        for idx, f in low_fps_frames[:10]:
            print(f"  - Frame #{idx + 1}: {f:.2f} FPS ({1000.0 / f:.2f} ms)")
    print("==========================================================================")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "profiling/tracy_frames.csv"
    analyze(path)
