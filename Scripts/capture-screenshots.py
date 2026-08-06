#!/usr/bin/env python3
"""
Capture the ScoreSort window for the welcome tour and the README.

The fiddly parts are automated — capturing without the drop shadow, checking the size
matches the existing images, writing each shot to every place it belongs, and creating
an imageset for a new tour page. Setting each view up (loading your demo documents,
choosing a tab) stays manual, because that's the part only you can judge.

Usage
-----
    python3 Scripts/capture-screenshots.py            # every target, in order
    python3 Scripts/capture-screenshots.py stamp      # just one
    python3 Scripts/capture-screenshots.py --list

Before you start
----------------
1. Run ScoreSort and load your demo documents. Tabs keep their state, so you can set
   them all up once and then walk through the captures.
2. Resize the window to 1280 x 800 — the existing tour images are 2560 x 1600, that
   size on a Retina display. The script checks each shot and tells you if it differs.
3. Terminal needs Screen Recording permission (System Settings > Privacy & Security >
   Screen Recording); macOS prompts the first time.

Each capture puts the cursor into window-picking mode: click the ScoreSort window.
No dependencies beyond what ships with macOS.
"""

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
EXPECTED_PIXELS = (2560, 1600)   # 1280 x 800 points on a Retina display

# name -> (what to show, [destination paths])
TARGETS = {
    "combiner": (
        "Combine tab (⌘1) with your demo files listed, ideally a collate group visible",
        ["ScoreSort/Assets.xcassets/tour-combiner.imageset/tour-combiner.png",
         "screenshots/combiner.png"],
    ),
    "renamer": (
        "Rename tab (⌘2) with a demo folder scanned and instruments detected",
        ["ScoreSort/Assets.xcassets/tour-renamer.imageset/tour-renamer.png",
         "screenshots/renamer.png"],
    ),
    "score-order": (
        "Rename tab (⌘2) showing the Score Order Sorter",
        ["ScoreSort/Assets.xcassets/tour-score-order.imageset/tour-score-order.png"],
    ),
    "splitter": (
        "Split tab (⌘3) Step 1 with a demo PDF and some split markers set",
        ["ScoreSort/Assets.xcassets/tour-splitter.imageset/tour-splitter.png",
         "screenshots/splitter.png"],
    ),
    "rotator": (
        "Rotate tab (⌘4) with a demo PDF loaded",
        ["ScoreSort/Assets.xcassets/tour-rotator.imageset/tour-rotator.png",
         "screenshots/rotator.png"],
    ),
    "stamp": (
        "Stamp tab (⌘5) with a stamp designed and a part in the preview",
        ["ScoreSort/Assets.xcassets/tour-stamp.imageset/tour-stamp.png",
         "screenshots/stamp.png"],
    ),
}


def pixel_size(path: Path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True).stdout
    values = [int(line.split(":")[1]) for line in out.splitlines() if ":" in line and
              line.strip().startswith(("pixelWidth", "pixelHeight"))]
    return tuple(values) if len(values) == 2 else None


def ensure_imageset(png_path: Path):
    """An .imageset needs a Contents.json naming its file, or Xcode ignores it.

    Written only once the PNG exists — a Contents.json pointing at a missing file is
    what left the app icon set broken for months.
    """
    contents = png_path.parent / "Contents.json"
    if contents.exists() or png_path.parent.suffix != ".imageset":
        return
    contents.write_text(json.dumps({
        "images": [{"filename": png_path.name, "idiom": "universal", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    print(f"   ✓ created {contents.relative_to(REPO)}")


def capture(destinations):
    first = REPO / destinations[0]
    first.parent.mkdir(parents=True, exist_ok=True)

    print("   … click the ScoreSort window (Esc cancels)")
    # -o drops the shadow, -w picks a window by click.
    result = subprocess.run(["screencapture", "-o", "-w", str(first)],
                            capture_output=True, text=True)
    if result.returncode != 0 or not first.exists():
        print(f"   ✗ nothing captured{': ' + result.stderr.strip() if result.stderr.strip() else ''}")
        return False

    size = pixel_size(first)
    if size == EXPECTED_PIXELS:
        print(f"   ✓ {destinations[0]}  ({size[0]} x {size[1]})")
    else:
        print(f"   ⚠️  {destinations[0]}  ({size[0]} x {size[1]}) — the other tour images "
              f"are {EXPECTED_PIXELS[0]} x {EXPECTED_PIXELS[1]}.")
        print("      Resize the window to 1280 x 800 points and recapture if you want "
              "them to match.")

    ensure_imageset(first)

    for extra in destinations[1:]:
        path = REPO / extra
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(first.read_bytes())
        print(f"   ✓ {extra}")
    return True


def main():
    if "--list" in sys.argv:
        for name, (what, _) in TARGETS.items():
            print(f"{name:12} {what}")
        return

    names = [a for a in sys.argv[1:] if not a.startswith("-")] or list(TARGETS)
    unknown = [n for n in names if n not in TARGETS]
    if unknown:
        print(f"Unknown target(s): {', '.join(unknown)}. Try --list.")
        sys.exit(1)

    print("Set the ScoreSort window to 1280 x 800 before you start.\n")
    for name in names:
        what, destinations = TARGETS[name]
        print(f"▸ {name}: {what}")
        answer = input("  Ready? Return to capture, s to skip, q to quit: ").strip().lower()
        if answer == "q":
            break
        if answer == "s":
            print("   skipped\n")
            continue
        capture(destinations)
        print()

    print("Done — check the images, then commit them.")
    print("If you captured 'stamp' for the first time, set imageName: \"tour-stamp\" is "
          "already in place on the tour page, so it will just appear.")


if __name__ == "__main__":
    main()
