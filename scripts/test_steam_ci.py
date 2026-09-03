#!/usr/bin/env python3
"""Steam Deployment & Headless Runtime CI/CD Integration Test.

Validates:
1. Steam Grid Assets generation (ImageMagick).
2. Non-Steam Shortcut injection into binary shortcuts.vdf.
3. Compatibility tool mapping (Proton Experimental) in config.vdf.
4. Correct deployment of Grid artworks in userdata/<id>/config/grid/.
5. Headless Wine execution of suckless-odin.exe in benchmark mode under Xvfb.
6. Generation and validity of benchmark render frame.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from inject_steam_art import parse_vdf_dict


def run_cmd(
    cmd: list[str] | str,
    check: bool = True,
    shell: bool = False,
    cwd: Path | str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Helper to run a shell command."""
    if shell:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
    else:
        res = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if check and res.returncode != 0:
        print(f"❌ Command failed (code {res.returncode}): {cmd}")
        print("STDOUT:", res.stdout)
        print("STDERR:", res.stderr)
        sys.exit(res.returncode)
    return res


def test_steam_assets_and_vdf_injection(mock_root: Path, target_exe: Path) -> int:
    """Tests asset generation and VDF injection against a mock Steam directory."""
    print("==> 1. Testing Steam Grid assets generation...")
    run_cmd(["bash", "scripts/generate_steam_assets.sh"])

    grid_assets = [
        Path("assets/steam_grid/cover.png"),
        Path("assets/steam_grid/hero.png"),
        Path("assets/steam_grid/banner.png"),
        Path("assets/steam_grid/logo.png"),
        Path("assets/steam_grid/icon.ico"),
    ]
    for asset in grid_assets:
        assert asset.exists(), f"Missing expected asset: {asset}"
        assert asset.stat().st_size > 100, f"Asset too small: {asset}"
    print("    ✓ All 5 Steam Grid assets exist and are valid.")

    print("==> 2. Setting up mock Steam directory structure...")
    user_id = "12345678"
    userdata_dir = mock_root / "userdata" / user_id
    config_dir = userdata_dir / "config"
    grid_dir = config_dir / "grid"
    config_dir.mkdir(parents=True, exist_ok=True)
    grid_dir.mkdir(parents=True, exist_ok=True)

    steam_config_dir = mock_root / "config"
    steam_config_dir.mkdir(parents=True, exist_ok=True)
    mock_config_vdf = steam_config_dir / "config.vdf"
    mock_config_vdf.write_text(
        '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n',
        encoding="utf-8",
    )

    print("==> 3. Running inject_steam_art.py against mock Steam...")
    run_cmd(
        [
            sys.executable,
            "scripts/inject_steam_art.py",
            "--target",
            "suckless-odin",
            "--exe",
            str(target_exe.resolve()),
            "--paths",
            str(mock_root),
        ]
    )

    print("==> 4. Verifying binary shortcuts.vdf...")
    shortcuts_file = config_dir / "shortcuts.vdf"
    assert shortcuts_file.exists(), f"shortcuts.vdf not created at {shortcuts_file}"
    parsed_vdf, _ = parse_vdf_dict(shortcuts_file.read_bytes())
    assert "shortcuts" in parsed_vdf, "shortcuts key missing in parsed VDF"
    shortcuts = parsed_vdf["shortcuts"]
    assert len(shortcuts) >= 1, "No shortcut entries found"

    matched = False
    expected_appid = 0
    for _, sc in shortcuts.items():
        if sc.get("AppName") == "suckless-odin":
            matched = True
            expected_appid = sc.get("appid", 0)
            assert str(target_exe.resolve()) in sc.get("Exe", ""), f"Mismatch Exe in shortcut: {sc.get('Exe')}"
            start_dir = str(target_exe.parent.resolve())
            assert start_dir in sc.get("StartDir", ""), f"Mismatch StartDir: {sc.get('StartDir')}"
            assert "MESA_LOADER_DRIVER_OVERRIDE=iris" in str(sc.get("LaunchOptions", "")), (
                "MESA_LOADER_DRIVER_OVERRIDE=iris missing in LaunchOptions"
            )
            assert sc.get("AllowOverlay") == 0, (
                f"AllowOverlay must be 0 to avoid swapchain blockage, got: {sc.get('AllowOverlay')}"
            )
            break
    assert matched, "suckless-odin shortcut not found in shortcuts.vdf"
    print(f"    ✓ shortcuts.vdf parsed and verified (AppID: {expected_appid}, AllowOverlay=0, LaunchOptions verified).")

    print("==> 5. Verifying config.vdf CompatToolMapping...")
    config_text = mock_config_vdf.read_text(encoding="utf-8")
    assert str(expected_appid) in config_text, f"AppID {expected_appid} not found in config.vdf"
    assert "proton_experimental" in config_text, "proton_experimental not found in config.vdf"
    print("    ✓ config.vdf CompatToolMapping successfully injected with proton_experimental.")

    print("==> 6. Verifying deployed grid artworks...")
    grid_files = list(grid_dir.glob("*"))
    assert len(grid_files) >= 5, f"Expected at least 5 grid files, found {len(grid_files)}"
    print(f"    ✓ {len(grid_files)} grid artwork files deployed successfully in {grid_dir}.")

    return expected_appid


def test_interactive_window_presentation(target_exe: Path) -> None:
    """Verifies that suckless-odin.exe presents real non-black pixels to the display backbuffer."""
    print("==> 7. Testing interactive window rendering & backbuffer presentation (non-black pixel assertion)...")
    capture_png = Path("/tmp/ci_interactive_window.png")
    if capture_png.exists():
        capture_png.unlink()

    env_prefix = (
        "WINEDEBUG=-all "
        "LIBGL_ALWAYS_SOFTWARE=1 "
        "GALLIUM_DRIVER=llvmpipe "
        "MESA_GL_VERSION_OVERRIDE=4.5 "
        "MESA_GLSL_VERSION_OVERRIDE=450"
    )
    wine_cmd = shutil.which("wine") or shutil.which("wine64") or "wine"
    magick_cmd = "magick" if shutil.which("magick") else "convert"

    # Launch under Xvfb in background and capture screen frame using $DISPLAY
    run_cmd_str = (
        f'{env_prefix} xvfb-run -a -s "-screen 0 1024x768x24" '
        f'bash -c \'{wine_cmd} "{target_exe.resolve()}" & WINE_PID=$!; sleep 4; '
        f'import -window root "{capture_png}" 2>/dev/null '
        f'|| ffmpeg -y -f x11grab -video_size 1024x768 -i "$DISPLAY" -vframes 1 "{capture_png}" 2>/dev/null '
        f'|| (xwd -root -silent | {magick_cmd} xwd:- "{capture_png}" 2>/dev/null); '
        f"kill -9 $WINE_PID 2>/dev/null || true; wait $WINE_PID 2>/dev/null || true'"
    )
    print(f"    Running: {run_cmd_str}")
    subprocess.run(run_cmd_str, shell=True, cwd=target_exe.parent, capture_output=True, text=True)

    assert capture_png.exists(), f"Failed to capture interactive window frame at {capture_png}"
    assert capture_png.stat().st_size > 500, f"Captured screen image too small ({capture_png.stat().st_size} bytes)"

    # Validate image luminance (ensure backbuffer is not black / not blank)
    lum_res = subprocess.run(
        f'{magick_cmd} "{capture_png}" -format "%[mean]" info:',
        shell=True,
        capture_output=True,
        text=True,
    )
    mean_lum = 0.0
    if lum_res.returncode == 0 and lum_res.stdout.strip():
        try:
            mean_lum = float(lum_res.stdout.strip())
        except ValueError:
            pass

    print(f"    ✓ Interactive window captured: {capture_png} (mean luminosity: {mean_lum:.2f})")
    assert mean_lum > 200.0, (
        f"REGRESSION DETECTED: Window backbuffer is black/blank! Mean luminosity: {mean_lum:.2f} <= 200.0"
    )


def test_headless_execution(target_exe: Path) -> None:
    """Tests headless execution of Windows binary under Wine/Xvfb in benchmark mode."""
    print("==> 8. Testing headless benchmark execution & FBO frame dumping...")
    ppm_out = Path("/tmp/benchmark_frame.ppm")
    png_out = Path("/tmp/benchmark_frame.png")
    if ppm_out.exists():
        ppm_out.unlink()
    if png_out.exists():
        png_out.unlink()

    # Configure headless environment & Xvfb 24-bit screen
    env_prefix = (
        "WINEDEBUG=-all "
        "LIBGL_ALWAYS_SOFTWARE=1 "
        "GALLIUM_DRIVER=llvmpipe "
        "MESA_GL_VERSION_OVERRIDE=4.5 "
        "MESA_GLSL_VERSION_OVERRIDE=450"
    )
    wine_cmd = shutil.which("wine") or shutil.which("wine64") or "wine"
    bench_cmd = (
        f'{env_prefix} xvfb-run -a -s "-screen 0 1024x768x24" '
        f'{wine_cmd} "{target_exe.resolve()}" --benchmark --benchmark-frames=30'
    )
    print(f"    Running: {bench_cmd}")
    res = run_cmd(bench_cmd, check=True, shell=True, cwd=target_exe.parent)
    assert "BENCHMARK RESULTS" in res.stdout, "Benchmark results not found in stdout"
    assert ppm_out.exists(), f"Benchmark frame was not written to {ppm_out}"

    # Convert PPM to PNG with ImageMagick
    magick_cmd = "magick" if shutil.which("magick") else "convert"
    run_cmd(f'{magick_cmd} "{ppm_out}" "{png_out}"', shell=True)
    assert png_out.exists(), f"Failed to convert {ppm_out} to {png_out}"
    assert png_out.stat().st_size > 1000, f"Rendered frame PNG too small ({png_out.stat().st_size} bytes)"
    print(f"    ✓ Headless benchmark execution succeeded ({png_out.stat().st_size} bytes PNG generated).")


def main() -> None:
    print("=" * 70)
    print("🎮 STEAM DEPLOYMENT & HEADLESS CI/CD VALIDATION SUITE")
    print("=" * 70)

    # Locate executable
    candidates = sorted(Path("build-release").glob("suckless-odin-windows-*/suckless-odin.exe")) + [
        Path("build/release-win/suckless-odin.exe"),
    ]
    target_exe = None
    for c in candidates:
        if c.exists():
            target_exe = c
            break

    if target_exe is None:
        print("==> suckless-odin.exe not found in build-release/. Checking build/release-win/...")
        if shutil.which("odin"):
            run_cmd(["task", "build-win-release"])
            target_exe = Path("build/release-win/suckless-odin.exe")
        else:
            raise FileNotFoundError("suckless-odin.exe not found in build-release/ packages.")

    mock_steam_root = Path("/tmp/mock_steam_ci")
    if mock_steam_root.exists():
        shutil.rmtree(mock_steam_root)
    mock_steam_root.mkdir(parents=True, exist_ok=True)

    try:
        test_steam_assets_and_vdf_injection(mock_steam_root, target_exe)
        test_interactive_window_presentation(target_exe)
        test_headless_execution(target_exe)
        print("=" * 70)
        print("✅ ALL STEAM CI/CD VALIDATION TESTS PASSED SUCCESSFULLY!")
        print("=" * 70)
    finally:
        if mock_steam_root.exists():
            shutil.rmtree(mock_steam_root, ignore_errors=True)


if __name__ == "__main__":
    main()
