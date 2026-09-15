#!/usr/bin/env python3
"""
check_logs.py — Regression guard for application logging.

Verifies:
1. All log tags used in src/ match the canonical whitelist of 27 active (+1 reserved) tags.
2. No rogue fmt.print* or fmt.eprint* calls exist in src/ outside authorized CLI files.

Scope note:
Scanned directories: src/ only.
tests/, tools/, benchmarks/, scripts/ do not emit log.* calls (verified by codebase scan).
"""

import os
import re
import sys
from pathlib import Path

# Canonical whitelist of authorized logging tags: 27 active + 1 reserved
CANONICAL_TAGS = {
    "app",
    "app.window",
    "app.input",
    "app.gamepad",
    "app.telemetry",  # Reserved (no current emitter)
    "scene",
    "scene.async",
    "scene.env",
    "render.shader",
    "render.texture",
    "render.material",
    "render.skybox",
    "render.ibl",
    "render.shadow",
    "render.volumetric",
    "render.overlay",
    "render.instanced",
    "render.billboard",
    "render.postfx",
    "render.postfx.cache",
    "render.postfx.io",
    "render.postfx.lut",
    "render.postfx.ubo",
    "core.perf",
    "core.settings",
    "core.session",
    "core.renderdoc",
    "core.itt",
}

# Authorized files for raw fmt.print / fmt.eprint (CLI entrypoint & CLI benchmark reporting)
FMT_PRINT_WHITELIST = {
    "src/cli.odin",
    "src/app/benchmark.odin",
}

SRC_DIR = Path("src")

LOG_FN_PATTERN = re.compile(r"\blog\.log_(?:debug|info|warning|error|critical)\s*\(\s*\"([^\"]+)\"")
LOG_MSG_PATTERN = re.compile(r"\blog\.log_message\s*\(\s*[^,]+,\s*\"([^\"]+)\"")

# Pattern for raw fmt print calls (excluding tprintf)
FMT_PATTERN = re.compile(r"\bfmt\.(?:println|printf|print|eprintln|eprintf|eprint)\s*\(")


def main() -> int:
    errors = []
    total_log_calls = 0
    tags_found = set()

    for root, _, files in os.walk(SRC_DIR):
        for f in sorted(files):
            if not f.endswith(".odin"):
                continue
            path = Path(root) / f
            rel_path = path.as_posix()

            # Skip core/log/ implementation files
            if "core/log" in rel_path:
                continue

            with open(path, encoding="utf-8") as fp:
                content = fp.read()

            # 1. Check all log tags (multiline-safe)
            for pattern in (LOG_FN_PATTERN, LOG_MSG_PATTERN):
                for m in pattern.finditer(content):
                    tag = m.group(1)
                    line_idx = content[: m.start()].count("\n") + 1
                    total_log_calls += 1
                    tags_found.add(tag)
                    if tag not in CANONICAL_TAGS:
                        errors.append(f"[INVALID TAG] {rel_path}:{line_idx} -> Unknown tag '{tag}'")

            # 2. Check forbidden fmt prints outside whitelist
            if rel_path not in FMT_PRINT_WHITELIST:
                lines = content.split("\n")
                for line_idx, line in enumerate(lines, 1):
                    stripped = line.strip()
                    if stripped.startswith("//") or stripped.startswith("/*"):
                        continue
                    if FMT_PATTERN.search(line):
                        errors.append(
                            f"[FORBIDDEN FMT] {rel_path}:{line_idx} -> "
                            f"Direct fmt print forbidden in engine code: {stripped}"
                        )

    print("=== CHECK LOGS AUDIT ===")
    print("Scanned files in src/ (excluding core/log/)")
    print(f"Total log calls detected : {total_log_calls}")
    print(f"Unique tags detected     : {len(tags_found)}")

    if errors:
        print(f"\n❌ FAIL: {len(errors)} violation(s) detected:")
        for err in errors:
            print(f"  {err}")
        return 1

    print("\n✅ PASS: All log tags match canonical whitelist and zero rogue fmt prints found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
