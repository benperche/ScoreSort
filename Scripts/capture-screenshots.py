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
2. Size the window to 1280 x 800 — in a Debug build, View > Set Window to 1280 x 800.
   That gives 2560 x 1600 on a Retina display, matching the existing tour images.
3. Terminal needs Screen Recording permission (System Settings > Privacy & Security >
   Screen Recording); macOS prompts the first time.

Works with nothing but macOS, in which case each capture asks you to click the window.
With pyobjc it finds the window itself — no clicking, and it warns *before* a shot if
the window is the wrong size. This repo has a .venv with it already installed:

    .venv/bin/python Scripts/capture-screenshots.py

To recreate that venv (it isn't committed):

    python3 -m venv .venv && .venv/bin/pip install pyobjc-framework-Quartz

A venv rather than a plain `pip install` because Homebrew's Python — the `python3` on
PATH here — refuses installs under PEP 668, and its `--break-system-packages` escape
hatch is exactly as advertised.
"""

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP_NAME = "ScoreSort"
EXPECTED_POINTS = (1280, 800)    # View ▸ Set Window to 1280 × 800 (Debug builds)
EXPECTED_PIXELS = (2560, 1600)   # …which is this many pixels on a Retina display

# Optional: with pyobjc installed the script finds the window itself, so there's no
# clicking and it can check the size *before* each shot rather than after.
#     python3 -m pip install --user pyobjc-framework-Quartz
try:
    import Quartz
    HAVE_QUARTZ = True
except ImportError:
    HAVE_QUARTZ = False

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


def find_window():
    """(id, width, height) in points for the app's main window, or None. Needs pyobjc."""
    if not HAVE_QUARTZ:
        return None
    options = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    for win in Quartz.CGWindowListCopyWindowInfo(options, Quartz.kCGNullWindowID):
        if win.get("kCGWindowOwnerName") != APP_NAME:
            continue
        bounds = win["kCGWindowBounds"]
        # Skip panels, popovers and the like.
        if bounds["Width"] < 400 or bounds["Height"] < 300:
            continue
        return win["kCGWindowNumber"], int(bounds["Width"]), int(bounds["Height"])
    return None


def check_window_size():
    """Warn before capturing if the window isn't the size the tour images expect."""
    window = find_window()
    if window is None:
        return
    _, width, height = window
    if (width, height) != EXPECTED_POINTS:
        print(f"   ⚠️  window is {width} × {height} pt, not "
              f"{EXPECTED_POINTS[0]} × {EXPECTED_POINTS[1]}")
        print("      In a Debug build: View ▸ Set Window to 1280 × 800 (screenshots)")


def capture(destinations):
    first = REPO / destinations[0]
    first.parent.mkdir(parents=True, exist_ok=True)

    window = find_window()
    if window is not None:
        # -l captures that window directly: no clicking, and no chance of grabbing
        # the wrong one.
        args = ["screencapture", "-o", "-x", "-l", str(window[0]), str(first)]
    else:
        print("   … click the ScoreSort window (Esc cancels)")
        # -w picks a window by click — the fallback when pyobjc isn't installed.
        args = ["screencapture", "-o", "-w", str(first)]

    result = subprocess.run(args, capture_output=True, text=True)
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

    if HAVE_QUARTZ:
        window = find_window()
        if window is None:
            print(f"No {APP_NAME} window found — start the app, then run this again.")
            sys.exit(1)
        print(f"Found {APP_NAME}: window {window[0]}, {window[1]} × {window[2]} pt.")
    else:
        print("pyobjc isn't installed, so each capture asks you to click the window.")
        print("For hands-off captures:  python3 -m pip install --user pyobjc-framework-Quartz")
    print("Set the window to 1280 × 800 first — in a Debug build, "
          "View ▸ Set Window to 1280 × 800.\n")

    for name in names:
        what, destinations = TARGETS[name]
        print(f"▸ {name}: {what}")
        check_window_size()
        answer = input("  Ready? Return to capture, s to skip, q to quit: ").strip().lower()
        if answer == "q":
            break
        if answer == "s":
            print("   skipped\n")
            continue
        capture(destinations)
        print()

    print("Done — check the images, then commit them.")
    print("The tour page already names tour-stamp, so a first capture of 'stamp' "
          "appears in the tour with no further changes.")


if __name__ == "__main__":
    main()
