#!/usr/bin/env python3
"""Builds the final GIFs from recorded frames (build/{mode}_f{N}.png) and
their tap-indicator coordinates (build/{mode}_coords.json, written by
demo_hook.lua via record.py) - crops each frame, overlays a translucent red
"tap here" circle wherever the next stage's target was, and hands the
sequence to ffmpeg. Run via run.sh after record.py has produced frames for
every mode.
"""
import json
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

RADIUS = 34

# Crop height (of the 720-wide capture): the menus and results lists use
# most of the screen, so keep it all but the blank strip at the very bottom.
CROP_H = 900

# Seconds each frame is held before the tap indicator shows on it, and for
# the tap itself. Frames that show a result (a landing, a preview) are held
# longer, and the last one longest.
HOLD = 1.0
HOLD_RESULT = 2.0
HOLD_LAST = 2.8
TAP = 0.45
SWIPE = (0.7, 7)  # seconds, steps

# Steps whose resulting frame is the payoff the viewer should read.
RESULT_STEPS = {"result", "button:Go to scripture", "button:Preview scripture"}

OUTPUT_NAME = {
    "jump": "demo-jump.gif",
    "preview": "demo-preview.gif",
    "hjump": "demo-highlight-jump.gif",
    "hpreview": "demo-highlight-preview.gif",
    "shortcut": "demo-search-shortcut.gif",
    "range": "demo-search-range.gif",
    "words": "demo-search-words.gif",
}

with open(os.path.join(HERE, "modes.json")) as _f:
    MODES = json.load(_f)


def sequence(mode):
    """One entry per recorded frame: (frame_index, hold_seconds, key), where
    key is the "t<N>" coordinate of the tap that leaves that frame (none on
    the last)."""
    steps = MODES[mode]["steps"]
    seq = []
    for i in range(len(steps) + 1):
        last = i == len(steps)
        if last:
            hold = HOLD_LAST
        elif i > 0 and steps[i - 1] in RESULT_STEPS:
            hold = HOLD_RESULT
        else:
            hold = HOLD
        seq.append((i, hold, None if last else f"t{i + 1}"))
    return seq


def add_touch(img, xy):
    img = img.convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    x, y = xy
    draw.ellipse(
        (x - RADIUS, y - RADIUS, x + RADIUS, y + RADIUS),
        fill=(220, 30, 30, 90),
        outline=(200, 20, 20, 200),
        width=3,
    )
    return Image.alpha_composite(img, overlay).convert("RGB")


def crop(img, h):
    w, _ = img.size
    return img.crop((0, 0, w, h))


def _missing(mode, key):
    print(f"warning: no recorded coordinate for {mode!r} stage {key!r}; "
          f"showing the frame without a tap indicator", file=sys.stderr)


def _expand(mode, idx, hold, key, coords, load):
    """The frames (image, duration) for one recorded frame: the plain frame
    held for `hold`, then the tap indicator (or a sliding drag) on it."""
    base = load(idx)
    out = [(base, hold)]
    target = coords.get(key) if key else None
    if key and not target:
        _missing(mode, key)
    if not target:
        return out
    if "from" in target:
        p0, p1 = target["from"], target["to"]
        dur, steps = SWIPE
        for i in range(steps):
            t = i / (steps - 1) if steps > 1 else 1.0
            xy = (p0["x"] + (p1["x"] - p0["x"]) * t, p0["y"] + (p1["y"] - p0["y"]) * t)
            out.append((add_touch(base, xy), dur / steps))
    else:
        out.append((add_touch(base, (target["x"], target["y"])), TAP))
    return out


def build(mode, build_dir, out_dir):
    with open(os.path.join(build_dir, f"{mode}_coords.json")) as f:
        coords = json.load(f)

    frames_raw = {}

    def load(i):
        if i not in frames_raw:
            frames_raw[i] = Image.open(os.path.join(build_dir, f"{mode}_f{i}.png"))
        return frames_raw[i]

    seq_dir = os.path.join(build_dir, f"{mode}_seq")
    if os.path.isdir(seq_dir):
        shutil.rmtree(seq_dir)
    os.makedirs(seq_dir)

    flat = []
    for idx, hold, key in sequence(mode):
        flat.extend(_expand(mode, idx, hold, key, coords, load))

    inputs = []
    for n, (img, dur) in enumerate(flat):
        img = crop(img, CROP_H)
        path = os.path.join(seq_dir, f"{n}.png")
        img.save(path)
        inputs += ["-loop", "1", "-t", str(dur), "-i", path]

    n = len(flat)
    filter_complex = (
        "".join(f"[{i}:v]" for i in range(n))
        + f"concat=n={n}:v=1:a=0,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer"
    )

    out_path = os.path.join(out_dir, OUTPUT_NAME[mode])
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *inputs,
         "-filter_complex", filter_complex, "-r", "8", out_path],
        check=True,
    )
    print("built", out_path)


if __name__ == "__main__":
    build_dir = os.path.join(HERE, "build")
    out_dir = os.path.join(REPO, "docs")
    os.makedirs(out_dir, exist_ok=True)
    modes = sys.argv[1:] or list(MODES)
    for mode in modes:
        build(mode, build_dir, out_dir)
