#!/usr/bin/env python3
"""Steam Artwork & Grid Assets Injector for suckless-odin.

Discovers Steam installations (Native / Flatpak / Snap), parses shortcuts.vdf,
resolves target non-Steam App IDs dynamically, and installs cover, hero, banner,
logo, and icon assets into the appropriate userdata/<user_id>/config/grid/ directory.
"""

import argparse
import shutil
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class SteamShortcut:
    """Represents a Steam Non-Steam shortcut parsed from shortcuts.vdf."""

    app_name: str
    app_id: int
    exe: str
    icon: str
    index: str


def parse_vdf_dict(data: bytes, pos: int = 0) -> tuple[dict[str, Any], int]:
    """Recursively parses Valve's binary KeyValues / VDF format."""

    def read_string(offset: int) -> tuple[str, int]:
        end = data.find(b"\x00", offset)
        if end == -1:
            raise ValueError("Unterminated string in binary VDF")
        return data[offset:end].decode("utf-8", errors="replace"), end + 1

    res: dict[str, Any] = {}
    while pos < len(data):
        type_byte = data[pos : pos + 1]
        pos += 1
        if type_byte == b"\x08" or not type_byte:
            break
        key, pos = read_string(pos)
        if type_byte == b"\x00":  # Nested dict
            sub_dict, pos = parse_vdf_dict(data, pos)
            res[key] = sub_dict
        elif type_byte == b"\x01":  # String
            val_str, pos = read_string(pos)
            res[key] = val_str
        elif type_byte == b"\x02":  # Int32
            val_int = struct.unpack("<I", data[pos : pos + 4])[0]
            pos += 4
            res[key] = val_int
    return res, pos


def find_steam_userdata_dirs(custom_paths: list[Path] | None = None) -> list[Path]:
    """Finds all existing userdata directories across Steam installation types."""
    candidates = [
        Path.home() / ".var/app/com.valvesoftware.Steam/.local/share/Steam",
        Path.home() / ".var/app/com.valvesoftware.Steam/data/Steam",
        Path.home() / ".local/share/Steam",
        Path.home() / ".steam/steam",
        Path.home() / ".steam/root",
        Path.home() / ".steam/debian-installation",
    ]
    if custom_paths:
        candidates = custom_paths + candidates

    found_roots: list[Path] = []
    seen = set()
    for c in candidates:
        try:
            resolved = c.resolve()
            if resolved.exists() and (resolved / "userdata").is_dir():
                if resolved not in seen:
                    seen.add(resolved)
                    found_roots.append(resolved / "userdata")
        except Exception:
            continue
    return found_roots


def calculate_shortcut_appid(exe: str, app_name: str) -> int:
    """Calculates the standard Steam 32-bit shortcut AppID from Exe and AppName."""
    key = f"{exe}{app_name}".encode()
    return zlib.crc32(key) | 0x80000000


def process_user_shortcuts(
    shortcuts_file: Path,
    target_name: str,
    assets_dir: Path,
    icon_source: Path,
) -> bool:
    """Processes a single shortcuts.vdf and deploys assets to config/grid/."""
    try:
        raw_data = shortcuts_file.read_bytes()
        parsed_vdf, _ = parse_vdf_dict(raw_data)
    except Exception as e:
        print(f"  ⚠️ Could not parse {shortcuts_file}: {e}")
        return False

    shortcuts_dict = parsed_vdf.get("shortcuts", {})
    if not isinstance(shortcuts_dict, dict):
        return False

    matched_shortcuts: list[SteamShortcut] = []
    for idx, sc_data in shortcuts_dict.items():
        if not isinstance(sc_data, dict):
            continue
        sc_appname = str(sc_data.get("AppName", ""))
        sc_exe = str(sc_data.get("Exe", ""))
        if (
            target_name.lower() in sc_appname.lower()
            or target_name.lower() in sc_exe.lower()
            or sc_appname.lower() in target_name.lower()
        ):
            appid = sc_data.get("appid")
            if not isinstance(appid, int):
                appid = calculate_shortcut_appid(sc_exe, sc_appname)
            matched_shortcuts.append(
                SteamShortcut(
                    app_name=sc_appname,
                    app_id=appid,
                    exe=sc_exe,
                    icon=str(sc_data.get("icon", "")),
                    index=str(idx),
                )
            )

    if not matched_shortcuts:
        return False

    grid_dir = shortcuts_file.parent / "grid"
    grid_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n[+] Processing Steam Profile: {shortcuts_file.parent.parent.name}")
    print(f"    Grid Directory : {grid_dir}")

    for sc in matched_shortcuts:
        u32_id = str(sc.app_id)
        s32_id = str(struct.unpack("<i", struct.pack("<I", sc.app_id))[0])
        u64_id = str(((sc.app_id | 0x80000000) << 32) | 0x02000000)

        print(f"  🎮 Matched Shortcut: '{sc.app_name}' (AppID: {u32_id} / 64-bit: {u64_id})")

        # Define destination mapping for all representations
        id_aliases = [u32_id, s32_id, u64_id, sc.app_name]

        asset_map = {
            "banner.png": ["{id}.png"],
            "cover.png": ["{id}p.png"],
            "hero.png": ["{id}_hero.png"],
            "logo.png": ["{id}_logo.png"],
            "icon.png": ["{id}_icon.png"],
            "icon.ico": ["{id}_icon.ico"],
        }

        for src_file, patterns in asset_map.items():
            src_path = assets_dir / src_file
            if not src_path.exists():
                continue
            for pattern in patterns:
                for id_alias in id_aliases:
                    dst_file = pattern.format(id=id_alias)
                    dst_path = grid_dir / dst_file
                    shutil.copy2(src_path, dst_path)
            print(f"    ✓ Deployed {src_file} ({len(id_aliases)} ID aliases)")

    return True


def main() -> None:
    """Main injection workflow."""
    parser = argparse.ArgumentParser(description="Inject artwork and icons into Steam for suckless-odin.")
    parser.add_argument(
        "--target",
        default="suckless-odin",
        help="The application name or substring as it appears in Steam library.",
    )
    parser.add_argument(
        "--assets-dir",
        type=Path,
        default=Path("assets/steam_grid"),
        help="Directory containing generated Steam Grid images.",
    )
    parser.add_argument(
        "--icon",
        type=Path,
        default=Path("assets/steam_grid/icon.ico"),
        help="Path to the .ico application icon.",
    )
    parser.add_argument(
        "--paths",
        nargs="*",
        type=Path,
        default=None,
        help="Custom search paths for Steam installation root.",
    )

    args = parser.parse_args()

    if not args.assets_dir.is_dir():
        print(f"❌ Assets directory '{args.assets_dir}' not found. Run 'task steam-gen-assets' first.")
        sys.exit(1)

    userdata_dirs = find_steam_userdata_dirs(args.paths)
    if not userdata_dirs:
        print("❌ No Steam userdata directory found.")
        sys.exit(1)

    matched_any = False
    for u_dir in userdata_dirs:
        for shortcut_file in u_dir.glob("*/config/shortcuts.vdf"):
            if process_user_shortcuts(shortcut_file, args.target, args.assets_dir, args.icon):
                matched_any = True

    if matched_any:
        print("\n" + "=" * 70)
        print("✅ Steam Grid Artworks & Icon injected successfully!")
        print("=" * 70)
        print("💡 NOTE IMPORTANTE :")
        print("   Si Steam est actuellement ouvert, redémarrez Steam complètement")
        print("   (Menu Steam -> Quitter / Exit Steam) pour forcer le rechargement")
        print("   du cache graphique (Hero, Logo, Cover, Banner et Icône).")
        print("=" * 70)
    else:
        print(f"\n⚠️ No shortcut matching '{args.target}' found in any shortcuts.vdf.")
        print("   Assurez-vous d'avoir ajouté l'exécutable comme 'Jeu non-Steam' dans Steam.")


if __name__ == "__main__":
    main()
