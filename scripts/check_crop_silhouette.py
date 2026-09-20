#!/usr/bin/env python3
"""
check_crop_silhouette.py - Validates that silhouette crop images are not monochrome/uniform.
Rejects images where luminance standard deviation < 5.0 (e.g. blown-out window/bulb halos).
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

MIN_STD_DEV = 5.0


def check_crop(path_str: str) -> bool:
    path = Path(path_str)
    if not path.is_file():
        print(f"❌ FAIL: File not found: {path}")
        return False

    img = Image.open(path).convert("RGBA")
    arr = np.array(img, dtype=np.float64)

    # Rec. 601 Luminance
    lum = 0.299 * arr[:, :, 0] + 0.587 * arr[:, :, 1] + 0.114 * arr[:, :, 2]
    mean_lum = float(np.mean(lum))
    std_lum = float(np.std(lum))
    min_lum = float(np.min(lum))
    max_lum = float(np.max(lum))

    print(
        f"[{path.name}] Dim: {img.size[0]}x{img.size[1]} | "
        f"Mean: {mean_lum:.2f} | Std: {std_lum:.2f} | Min: {min_lum:.1f} | Max: {max_lum:.1f}"
    )

    if std_lum < MIN_STD_DEV:
        print(f"❌ REJECTED: Luminance std {std_lum:.2f} < threshold {MIN_STD_DEV:.2f} (monochrome / blown-out halo)")
        return False

    print(f"✅ PASS: Silhouette edge verified (std {std_lum:.2f} >= {MIN_STD_DEV:.2f})")
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 check_crop_silhouette.py <image1.png> [image2.png ...]")
        sys.exit(1)

    all_pass = True
    for p in sys.argv[1:]:
        if not check_crop(p):
            all_pass = False

    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
