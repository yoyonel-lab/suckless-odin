#!/usr/bin/env python3
import csv
import os
import sys


def analyze(csv_path, unwrapped_path=None):
    if not os.path.exists(csv_path):
        print(f"Error: {csv_path} not found.")
        sys.exit(1)

    print("================================================================================")
    print("                      TRACY PROFILE PERFORMANCE ANALYSIS                        ")
    print("================================================================================")
    print(f"{'Zone Name':<32} | {'Count':<6} | {'Min (ms)':<9} | {'Max (ms)':<9} | {'Mean (ms)':<9}")
    print("--------------------------------------------------------------------------------")

    targets = [
        "IBL: Upload_HDR_Texture",
        "IBL: Upload_HDR_Texture_Slice",
        "IBL: Specular_Mip_Slice",
        "IBL: Irradiance_Slice",
        "Skybox: Start Cubemap Gen",
        "Cubemap_Gen_Init",
        "Cubemap_Gen_Face",
        "Cubemap_Gen_Downsample",
        "PostFX_Final_Composite",
        "HDR_Load_Decode",
        "Frame",
        "Swap_Buffers",
    ]

    found = {}
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.get("name")
            if name in targets:
                count = int(row.get("counts", 0))
                min_ms = float(row.get("min_ns", 0)) / 1e6
                max_ms = float(row.get("max_ns", 0)) / 1e6
                mean_ms = float(row.get("mean_ns", 0)) / 1e6
                found[name] = (count, min_ms, max_ms, mean_ms)

    for target in targets:
        if target in found:
            count, min_ms, max_ms, mean_ms = found[target]
            print(f"{target:<32} | {count:<6} | {min_ms:<9.3f} | {max_ms:<9.3f} | {mean_ms:<9.3f}")
        else:
            print(f"{target:<32} | {'N/A':<6} | {'N/A':<9} | {'N/A':<9} | {'N/A':<9}")
    print("================================================================================")

    # Top 5 longest frames analysis
    if unwrapped_path and os.path.exists(unwrapped_path):
        print("\n================================================================================")
        print("                           TOP 5 LONGEST FRAMES DETAIL                          ")
        print("================================================================================")

        frames = []
        all_zones = []

        with open(unwrapped_path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                name = row.get("name")
                ns_start = int(row.get("ns_since_start", 0))
                exec_ns = int(row.get("exec_time_ns", 0))
                thread = row.get("thread", "")

                zone_data = {
                    "name": name,
                    "start": ns_start,
                    "duration": exec_ns / 1e6,  # in ms
                    "end": ns_start + exec_ns,
                    "thread": thread,
                }

                if name == "Frame":
                    frames.append(zone_data)
                else:
                    all_zones.append(zone_data)

        if not frames:
            print("No 'Frame' zones found in unwrapped trace.")
            return

        # Sort frames by duration descending
        frames.sort(key=lambda x: x["duration"], reverse=True)
        top_5 = frames[:5]

        for i, frame in enumerate(top_5):
            print(f"Rank {i + 1}: Frame duration = {frame['duration']:.3f} ms (started at {frame['start'] / 1e9:.3f}s)")

            # Find sub-zones that started within this frame's duration
            sub_zones = []
            for zone in all_zones:
                if zone["start"] >= frame["start"] and zone["start"] < frame["end"]:
                    sub_zones.append(zone)

            # Sort sub-zones by duration descending
            sub_zones.sort(key=lambda x: x["duration"], reverse=True)

            if sub_zones:
                print("   Contributing zones in this frame:")
                # Show top 8 sub-zones to keep it readable
                for sz in sub_zones[:8]:
                    print(f"     - {sz['name']:<35} : {sz['duration']:7.3f} ms (Thread {sz['thread']})")
            else:
                print("   (No significant contributing sub-zones found)")
            print("-" * 80)
        print("================================================================================")

    # Startup and first 5 frames telemetry analysis
    telemetry_path = "/tmp/startup_telemetry.csv"
    if os.path.exists(telemetry_path):
        print("\n================================================================================")
        print("                      STARTUP & FIRST 5 FRAMES TELEMETRY                        ")
        print("================================================================================")
        print(f"{'Metric':<32} | {'Duration (ms)':<15}")
        print("--------------------------------------------------------------------------------")
        nice_names = {
            "init_time_ms": "Initialization (Until Frame 1)",
            "frame_1_total_ms": "Frame 1 - Total",
            "frame_1_poll_ms": "  - PollEvents",
            "frame_1_update_ms": "  - scene_update",
            "frame_1_render_ms": "  - scene_render (inc. GUI)",
            "frame_1_swap_ms": "  - SwapBuffers",
            "frame_2_total_ms": "Frame 2 - Total",
            "frame_2_poll_ms": "  - PollEvents",
            "frame_2_update_ms": "  - scene_update",
            "frame_2_render_ms": "  - scene_render (inc. GUI)",
            "frame_2_swap_ms": "  - SwapBuffers",
            "frame_3_total_ms": "Frame 3 - Total",
            "frame_3_poll_ms": "  - PollEvents",
            "frame_3_update_ms": "  - scene_update",
            "frame_3_render_ms": "  - scene_render (inc. GUI)",
            "frame_3_swap_ms": "  - SwapBuffers",
            "frame_4_total_ms": "Frame 4 - Total",
            "frame_4_poll_ms": "  - PollEvents",
            "frame_4_update_ms": "  - scene_update",
            "frame_4_render_ms": "  - scene_render (inc. GUI)",
            "frame_4_swap_ms": "  - SwapBuffers",
            "frame_5_total_ms": "Frame 5 - Total",
            "frame_5_poll_ms": "  - PollEvents",
            "frame_5_update_ms": "  - scene_update",
            "frame_5_render_ms": "  - scene_render (inc. GUI)",
            "frame_5_swap_ms": "  - SwapBuffers",
        }
        try:
            with open(telemetry_path) as f:
                telemetry_reader = csv.DictReader(f)
                for row in telemetry_reader:
                    metric = row.get("metric")
                    value = float(row.get("value", 0))
                    label = nice_names.get(metric, metric)
                    print(f"{label:<32} | {value:<15.3f} ms")
        except Exception as e:
            print(f"Error parsing startup telemetry: {e}")
        print("================================================================================")


if __name__ == "__main__":
    csv_path = "/tmp/trace.csv"
    unwrapped_path = "/tmp/trace_unwrapped.csv"

    if len(sys.argv) > 1:
        csv_path = sys.argv[1]
    if len(sys.argv) > 2:
        unwrapped_path = sys.argv[2]

    analyze(csv_path, unwrapped_path)
