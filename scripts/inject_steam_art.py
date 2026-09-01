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


def serialize_vdf_dict(d: dict[str, Any]) -> bytes:
    """Recursively serializes a dict into Valve's binary KeyValues / VDF format."""
    out = bytearray()
    for k, v in d.items():
        if isinstance(v, dict):
            out.append(0x00)
            out.extend(str(k).encode("utf-8") + b"\x00")
            out.extend(serialize_vdf_dict(v))
        elif isinstance(v, str):
            out.append(0x01)
            out.extend(str(k).encode("utf-8") + b"\x00")
            out.extend(v.encode("utf-8") + b"\x00")
        elif isinstance(v, int):
            out.append(0x02)
            out.extend(str(k).encode("utf-8") + b"\x00")
            out.extend(struct.pack("<I", v & 0xFFFFFFFF))
    out.append(0x08)
    return bytes(out)


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


def configure_steam_proton_mapping(steam_root: Path, appid: int) -> None:
    """Ensures Proton Experimental is configured for this shortcut in config.vdf."""
    candidate_configs = [
        steam_root / "config" / "config.vdf",
        steam_root.parent / "config" / "config.vdf",
        Path.home() / ".var/app/com.valvesoftware.Steam/.local/share/Steam/config/config.vdf",
        Path.home() / ".local/share/Steam/config/config.vdf",
        Path.home() / ".steam/steam/config/config.vdf",
    ]
    config_file = None
    for c in candidate_configs:
        if c.exists():
            config_file = c
            break

    if not config_file or not config_file.exists():
        return
    try:
        content = config_file.read_text(encoding="utf-8", errors="replace")
        u32_str = str(appid)
        if f'"{u32_str}"' in content:
            return
        import re

        m = re.search(r'("CompatToolMapping"\s*\{)', content)
        if m:
            entry = (
                f'\n\t\t\t\t\t"{u32_str}"\n\t\t\t\t\t{{\n\t\t\t\t\t\t"name"\t\t"proton_experimental"'
                '\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}}'
            )
            new_content = content[: m.end()] + entry + content[m.end() :]
            config_file.write_text(new_content, encoding="utf-8")
            print(f"    ✓ Configured Proton Experimental compatibility tool in {config_file} for AppID {u32_str}")
    except Exception as e:
        print(f"    ⚠️ Could not update {config_file}: {e}")


def process_user_shortcuts(
    shortcuts_file: Path,
    target_name: str,
    assets_dir: Path,
    icon_source: Path,
    exe_path: Path | None = None,
    auto_add: bool = True,
) -> bool:
    """Processes a single shortcuts.vdf, creates shortcut if missing, and deploys assets to config/grid/."""
    try:
        raw_data = shortcuts_file.read_bytes() if shortcuts_file.exists() else b"\x00shortcuts\x00\x08\x08"
        parsed_vdf, _ = parse_vdf_dict(raw_data)
    except Exception as e:
        print(f"  ⚠️ Could not parse {shortcuts_file}: {e}")
        parsed_vdf = {"shortcuts": {}}

    shortcuts_dict = parsed_vdf.get("shortcuts", {})
    if not isinstance(shortcuts_dict, dict):
        shortcuts_dict = {}

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

    # If not found and auto_add is enabled, create shortcut entry
    if not matched_shortcuts and auto_add:
        target_exe = None
        if exe_path and exe_path.exists():
            target_exe = exe_path.resolve()
        else:
            candidates = [
                Path("build-release/suckless-odin-windows-v0.1.0/suckless-odin.exe").resolve(),
                Path("build/release-win/suckless-odin.exe").resolve(),
            ]
            for c in candidates:
                if c.exists():
                    target_exe = c
                    break

        if target_exe:
            print(f"  [+] Automatically adding non-Steam shortcut for '{target_name}' -> {target_exe}")
            formatted_exe = f'"{target_exe}"'
            formatted_start_dir = f'"{target_exe.parent}"'
            appid = calculate_shortcut_appid(formatted_exe, target_name)
            icon_dest = shortcuts_file.parent / "grid" / "icon.ico"
            icon_path_str = str(icon_dest.resolve()) if icon_dest.exists() else str(icon_source.resolve())

            # Find next free numerical index
            existing_indices = [int(k) for k in shortcuts_dict.keys() if str(k).isdigit()]
            next_idx = str(max(existing_indices, default=-1) + 1)

            new_sc_dict = {
                "AppName": target_name,
                "Exe": formatted_exe,
                "StartDir": formatted_start_dir,
                "icon": icon_path_str,
                "ShortcutPath": "",
                "LaunchOptions": "",
                "IsHidden": 0,
                "AllowDesktopConfig": 1,
                "AllowOverlay": 1,
                "OpenVR": 0,
                "Devkit": 0,
                "DevkitGameID": "",
                "DevkitOverrideAppID": 0,
                "FlatpakAppID": "",
                "tags": {},
                "appid": appid,
            }

            shortcuts_dict[next_idx] = new_sc_dict
            parsed_vdf["shortcuts"] = shortcuts_dict
            try:
                # Backup existing shortcuts file
                if shortcuts_file.exists():
                    shutil.copy2(shortcuts_file, shortcuts_file.with_suffix(".vdf.bak"))
                shortcuts_file.write_bytes(serialize_vdf_dict(parsed_vdf))
                print(f"    ✓ Successfully registered shortcut in {shortcuts_file}")
            except Exception as e:
                print(f"    ❌ Failed to write {shortcuts_file}: {e}")

            matched_shortcuts.append(
                SteamShortcut(
                    app_name=target_name,
                    app_id=appid,
                    exe=formatted_exe,
                    icon=icon_path_str,
                    index=next_idx,
                )
            )

            # Configure Proton tool in Steam config.vdf
            steam_root = shortcuts_file.parent.parent.parent
            configure_steam_proton_mapping(steam_root, appid)

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
        "--exe",
        type=Path,
        default=None,
        help="Path to the target Windows .exe executable.",
    )
    parser.add_argument(
        "--no-auto-add",
        action="store_true",
        help="Disable automatic creation of shortcut if missing.",
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
        for profile_dir in u_dir.iterdir():
            if not profile_dir.is_dir() or profile_dir.name in ["anonymous", "0"]:
                continue
            config_dir = profile_dir / "config"
            config_dir.mkdir(parents=True, exist_ok=True)
            shortcut_file = config_dir / "shortcuts.vdf"
            if process_user_shortcuts(
                shortcut_file,
                args.target,
                args.assets_dir,
                args.icon,
                exe_path=args.exe,
                auto_add=not args.no_auto_add,
            ):
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
