#!/usr/bin/env python3
"""check_gl_symbols.py — Regression guard for OpenGL symbols vs pinned version.

Verifies:
1. Pinned GL version in src/app/window.odin (GL_MAJOR, GL_MINOR).
2. Symbols table generated dynamically from vendor:OpenGL (or fallback cache scripts/.gl_symbols_cache.json).
3. All version-gated gl.* symbols in src/ are <= pinned version (FAIL if > pinned).
4. Guard anti-inconnu: Any gl.* symbol in src/ not recognized in vendor:OpenGL triggers a visible WARNING.

Regeneration command:
  task regen-gl-symbols  (or: python3 scripts/check_gl_symbols.py --regen)

Fallback cache behavior:
  When vendor:OpenGL sources are unavailable (e.g. CI runners, cross-compilation environments,
  or containers without ODIN_ROOT), the script automatically falls back to the committed cache
  scripts/.gl_symbols_cache.json with an explicit warning, ensuring the guard is never blind.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SRC_DIR = Path("src")
WINDOW_ODIN = SRC_DIR / "app" / "window.odin"
CACHE_FILE = Path("scripts/.gl_symbols_cache.json")


def find_vendor_gl_dir() -> Path | None:
    """Locate the vendor:OpenGL directory from ODIN_ROOT or 'odin root'."""
    odin_root = os.environ.get("ODIN_ROOT")
    if odin_root:
        p = Path(odin_root) / "vendor" / "OpenGL"
        if (p / "impl.odin").is_file():
            return p

    odin_bin = shutil.which("odin")
    if odin_bin:
        try:
            res = subprocess.run([odin_bin, "root"], capture_output=True, text=True, check=False)
            if res.returncode == 0:
                root = Path(res.stdout.strip())
                p = root / "vendor" / "OpenGL"
                if (p / "impl.odin").is_file():
                    return p
        except Exception:
            pass

    # Common system locations
    candidates = [
        Path("/usr/lib/odin/vendor/OpenGL"),
        Path("/usr/local/share/odin/vendor/OpenGL"),
        Path.home() / ".local/share/odin/vendor/OpenGL",
    ]
    for c in candidates:
        if (c / "impl.odin").is_file():
            return c

    return None


def extract_from_vendor(vendor_dir: Path) -> tuple[dict[str, list[str]], set[str]]:
    """Parse vendor:OpenGL sources to extract versioned symbols and all known identifiers."""
    decl_re = re.compile(r"^([A-Za-z0-9_]+)\s*::", re.MULTILINE)
    proc_re = re.compile(r"load_(\d+)_(\d+)\s*::\s*proc\s*\([^)]*\)\s*\{([^}]+)\}", re.DOTALL)
    sym_re = re.compile(r"set_proc_address\s*\(\s*&impl_([A-Za-z0-9_]+)\s*,")

    version_symbols: dict[str, list[str]] = {}
    all_known: set[str] = set()

    impl_text = (vendor_dir / "impl.odin").read_text(encoding="utf-8")
    for m in proc_re.finditer(impl_text):
        ver = f"{m.group(1)}.{m.group(2)}"
        syms = sorted(set(sym_re.findall(m.group(3))))
        version_symbols[ver] = syms
        all_known.update(syms)

    for fname in ["constants.odin", "enums.odin", "helpers.odin", "impl.odin"]:
        p = vendor_dir / fname
        if p.is_file():
            all_known.update(decl_re.findall(p.read_text(encoding="utf-8")))

    # Built-in vendor extras
    all_known.update({"load_up_to", "get_proc_address", "Set_Proc_Address_Type", "DEBUGPROC"})

    return version_symbols, all_known


def save_cache(version_symbols: dict[str, list[str]], all_known: set[str]) -> None:
    """Save extracted symbols to JSON cache with deterministic sorted keys."""
    total_versioned = sum(len(v) for v in version_symbols.values())
    payload = {
        "_meta": {
            "source": "vendor:OpenGL",
            "total_known_identifiers": len(all_known),
            "total_versioned_symbols": total_versioned,
        },
        "all_known": sorted(all_known),
        "version_symbols": {k: sorted(v) for k, v in sorted(version_symbols.items())},
    }
    CACHE_FILE.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[check_gl_symbols] Cache written to {CACHE_FILE} ({total_versioned} procs, {len(all_known)} identifiers)")


def load_cache() -> tuple[dict[str, list[str]], set[str]] | None:
    """Load symbols from JSON cache if available."""
    if not CACHE_FILE.is_file():
        return None
    try:
        data = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
        version_symbols = data.get("version_symbols", {})
        all_known = set(data.get("all_known", []))
        return version_symbols, all_known
    except Exception as e:
        print(f"WARNING: Failed to parse {CACHE_FILE}: {e}", file=sys.stderr)
        return None


def get_symbols_data(force_regen: bool = False) -> tuple[dict[str, list[str]], set[str]]:
    """Retrieve symbol tables either by parsing vendor:OpenGL or reading cache."""
    vendor_dir = find_vendor_gl_dir()

    if vendor_dir is not None:
        if force_regen or not CACHE_FILE.is_file():
            print(f"[check_gl_symbols] Regenerating symbol tables from {vendor_dir}...")
            version_symbols, all_known = extract_from_vendor(vendor_dir)
            save_cache(version_symbols, all_known)
            return version_symbols, all_known
        else:
            # Vendor found and cache exists: load cache
            cached = load_cache()
            if cached is not None:
                return cached
            version_symbols, all_known = extract_from_vendor(vendor_dir)
            save_cache(version_symbols, all_known)
            return version_symbols, all_known

    # Vendor not found: fallback to cache
    print("⚠️  WARNING: vendor:OpenGL not found at $ODIN_ROOT or 'odin root'.", file=sys.stderr)
    print(f"⚠️  Falling back to committed cache {CACHE_FILE}...", file=sys.stderr)
    cached = load_cache()
    if cached is not None:
        return cached

    print(f"❌ ERROR: vendor:OpenGL not found and cache {CACHE_FILE} missing!", file=sys.stderr)
    sys.exit(1)


def get_pinned_gl_version() -> tuple[int, int]:
    """Parse GL_MAJOR and GL_MINOR from window.odin."""
    if not WINDOW_ODIN.is_file():
        print(f"ERROR: {WINDOW_ODIN} not found!", file=sys.stderr)
        sys.exit(1)

    content = WINDOW_ODIN.read_text(encoding="utf-8")
    major_match = re.search(r"\bGL_MAJOR\s*::\s*(\d+)", content)
    minor_match = re.search(r"\bGL_MINOR\s*::\s*(\d+)", content)

    if not major_match or not minor_match:
        print(f"ERROR: Could not parse GL_MAJOR / GL_MINOR from {WINDOW_ODIN}", file=sys.stderr)
        sys.exit(1)

    return int(major_match.group(1)), int(minor_match.group(1))


def main() -> int:
    force_regen = "--regen" in sys.argv
    version_symbols, all_known = get_symbols_data(force_regen=force_regen)

    if force_regen:
        print("✅ Symbol tables successfully regenerated and verified.")
        return 0

    # Build symbol -> (major, minor) map
    symbol_version_map: dict[str, tuple[int, int]] = {}
    for ver_str, syms in version_symbols.items():
        parts = ver_str.split(".")
        ver_tuple = (int(parts[0]), int(parts[1]))
        for sym in syms:
            symbol_version_map[sym] = ver_tuple

    pinned_version = get_pinned_gl_version()
    pinned_str = f"{pinned_version[0]}.{pinned_version[1]}"
    print(f"=== CHECK OPENGL SYMBOLS AUDIT (Pinned GL Version: {pinned_str}) ===")

    gl_call_re = re.compile(r"\bgl\.([A-Za-z0-9_]+)\b")

    version_violations = []
    unknown_symbols = []
    scanned_files = 0
    symbols_inspected = 0

    for root, _, files in os.walk(SRC_DIR):
        for fname in sorted(files):
            if not fname.endswith(".odin"):
                continue
            fpath = Path(root) / fname
            scanned_files += 1

            try:
                lines = fpath.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue

            for line_idx, line in enumerate(lines, start=1):
                # Ignore comments
                stripped = line.strip()
                if stripped.startswith("//"):
                    continue

                for match in gl_call_re.finditer(line):
                    sym = match.group(1)
                    symbols_inspected += 1

                    # 1. Version gate check
                    if sym in symbol_version_map:
                        req_ver = symbol_version_map[sym]
                        if req_ver > pinned_version:
                            req_str = f"{req_ver[0]}.{req_ver[1]}"
                            version_violations.append((fpath, line_idx, sym, req_str))

                    # 2. Anti-unknown guard check
                    if sym not in all_known:
                        unknown_symbols.append((fpath, line_idx, sym))

    print(f"Scanned {scanned_files} files across {SRC_DIR}/.")
    print(f"Total gl.* identifier references inspected: {symbols_inspected}")

    # Report unknown symbols (warnings, not failure)
    if unknown_symbols:
        print(
            f"\n⚠️  WARNING: Found {len(unknown_symbols)} unknown gl.* symbol reference(s) not in vendor:OpenGL:",
            file=sys.stderr,
        )
        for fpath, line_no, sym in unknown_symbols:
            print(f"  {fpath}:{line_no}: gl.{sym} (unknown identifier)", file=sys.stderr)
    else:
        print("  Unknown gl.* references : 0 (100% matched in vendor:OpenGL)")

    # Report version violations (failure)
    if version_violations:
        print(
            f"\n❌ FAIL: Found {len(version_violations)} GL symbol call(s) exceeding pinned GL {pinned_str}:",
            file=sys.stderr,
        )
        for fpath, line_no, sym, req_str in version_violations:
            print(f"  {fpath}:{line_no}: gl.{sym} requires OpenGL {req_str} (pinned: {pinned_str})", file=sys.stderr)
        return 1

    print(f"✅ PASS: All versioned GL symbols in {SRC_DIR}/ are <= pinned OpenGL {pinned_str}.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
