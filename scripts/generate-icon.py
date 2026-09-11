#!/usr/bin/env python3
"""Package the approved icon artwork; do not redraw the brand asset."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
SOURCE = RESOURCES / "AppIcon-source.png"
ICONSET = RESOURCES / "AppIcon.iconset"


def resize(source, destination, pixels):
    subprocess.run(["sips", "-z", str(pixels), str(pixels), str(source), "--out", str(destination)], check=True, stdout=subprocess.DEVNULL)


def main():
    if not SOURCE.is_file():
        raise SystemExit("Missing Resources/AppIcon-source.png; see README.md")
    ICONSET.mkdir(parents=True, exist_ok=True)
    resize(SOURCE, RESOURCES / "AppIcon.png", 1024)
    for size in (16, 32, 128, 256, 512):
        resize(SOURCE, ICONSET / f"icon_{size}x{size}.png", size)
        resize(SOURCE, ICONSET / f"icon_{size}x{size}@2x.png", size * 2)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(RESOURCES / "AppIcon.icns")], check=True)
    print(RESOURCES / "AppIcon.icns")


if __name__ == "__main__":
    main()
