#!/usr/bin/env python3
"""Wrapper around odin-imgui/build.py that parallelizes C++ compilation.

The upstream build.py compiles all .cpp files in a single sequential clang
invocation. This wrapper monkey-patches subprocess.check_output to split
multi-file clang -c calls into parallel per-file compilations.
"""

import concurrent.futures
import multiprocessing
import os
import subprocess

_orig_check_output = subprocess.check_output
_jobs = max(1, multiprocessing.cpu_count() - 2)


def _parallel_check_output(cmd, *args, **kwargs):
    """Intercept clang -c with multiple sources and compile in parallel."""
    if isinstance(cmd, list) and len(cmd) > 2 and "-c" in cmd:
        # Check if first element is clang (or a path ending with clang)
        if "clang" in os.path.basename(cmd[0]):
            c_idx = cmd.index("-c")
            sources = cmd[c_idx + 1 :]
            if len(sources) > 1:
                flags = cmd[:c_idx] + ["-c"]
                print(f"  [parallel] Compiling {len(sources)} files with {_jobs} jobs...")

                def compile_one(src):
                    _orig_check_output(flags + [src], *args, **kwargs)
                    print(f"    Compiled {src}")

                with concurrent.futures.ThreadPoolExecutor(max_workers=_jobs) as pool:
                    futures = [pool.submit(compile_one, src) for src in sources]
                    for future in concurrent.futures.as_completed(futures):
                        future.result()  # Raise if any compilation failed
                return b""
    return _orig_check_output(cmd, *args, **kwargs)


if __name__ == "__main__":
    # Change to odin-imgui directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    imgui_dir = os.path.join(script_dir, "..", "deps", "odin-imgui")
    os.chdir(imgui_dir)

    # Apply monkey-patch
    subprocess.check_output = _parallel_check_output

    # Execute original build.py
    with open("build.py") as f:
        exec(compile(f.read(), "build.py", "exec"))  # noqa: S102
