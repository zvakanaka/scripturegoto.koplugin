#!/usr/bin/env python3
"""Builds the final GIFs from recorded frames (build/{mode}_f{N}.png) and
their tap-indicator coordinates (build/{mode}_coords.json, written by
demo_hook.lua via record.py) - crops each frame, overlays a translucent red
"tap here" circle wherever the next stage's target was, and hands the
sequence to ffmpeg. Run via run.sh after record.py has produced frames for
all four modes.
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

# Crop height (of the 720-wide capture): tall enough to keep each mode's
# dialog/popup fully visible without carrying along excess blank space
# below it. The link/jump dialog tops out shorter than the highlight
# dialog (it has fewer buttons) and the preview popup, hence two heights.
CROP_H = {"jump": 830, "preview": 830, "hjump": 860, "hpreview": 860}

# Each mode's frame sequence: (frame_index, hold_seconds) for a plain
# frame; ("touch", frame_index, coord_key, hold_seconds) to overlay a
# static tap indicator at coords[coord_key] on top of that frame; or
# ("swipe", frame_index, start_key, end_key, total_seconds, n_steps) to
# overlay the indicator sliding from coords[start_key] to coords[end_key]
# across n_steps frames (for a highlight/select drag, rather than a tap).
SEQUENCES = {
    "jump": [
        (0, 1.0),
        ("touch", 0, "link", 0.45),
        (1, 1.0),
        ("touch", 1, "dialog_button", 0.45),
        (2, 1.6),
        ("touch", 2, "menu_icon", 0.45),
        (3, 1.2),
        ("touch", 3, "menu_item", 0.45),
        (4, 1.8),
    ],
    "preview": [
        (0, 1.0),
        ("touch", 0, "link", 0.45),
        (1, 1.0),
        ("touch", 1, "dialog_button", 0.45),
        (2, 2.0),
    ],
    "hjump": [
        (0, 1.0),
        ("swipe", 0, "phrase_left", "phrase_right", 0.7, 7),
        (1, 1.0),
        ("touch", 1, "dialog_button", 0.45),
        (2, 2.0),
    ],
    "hpreview": [
        (0, 1.0),
        ("swipe", 0, "phrase_left", "phrase_right", 0.7, 7),
        (1, 1.0),
        ("touch", 1, "dialog_button", 0.45),
        (2, 2.0),
    ],
}

OUTPUT_NAME = {
    "jump": "demo-jump.gif",
    "preview": "demo-preview.gif",
    "hjump": "demo-highlight-jump.gif",
    "hpreview": "demo-highlight-preview.gif",
}


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


def _expand(mode, spec, coords, load):
    """Expands one SEQUENCES entry into a list of (image, duration)."""
    kind = spec[0]
    if kind == "touch":
        _, idx, key, dur = spec
        xy = coords.get(key)
        img = load(idx)
        if xy:
            img = add_touch(img, (xy["x"], xy["y"]))
        else:
            _missing(mode, key)
        return [(img, dur)]
    if kind == "swipe":
        _, idx, start_key, end_key, dur, steps = spec
        p0, p1 = coords.get(start_key), coords.get(end_key)
        base = load(idx)
        if not (p0 and p1):
            _missing(mode, f"{start_key}/{end_key}")
            return [(base, dur)]
        step_dur = dur / steps
        frames = []
        for i in range(steps):
            t = i / (steps - 1) if steps > 1 else 1.0
            x = p0["x"] + (p1["x"] - p0["x"]) * t
            y = p0["y"] + (p1["y"] - p0["y"]) * t
            frames.append((add_touch(base, (x, y)), step_dur))
        return frames
    idx, dur = spec
    return [(load(idx), dur)]


def build(mode, build_dir, out_dir):
    with open(os.path.join(build_dir, f"{mode}_coords.json")) as f:
        coords = json.load(f)

    frames_raw = {}

    def load(i):
        if i not in frames_raw:
            frames_raw[i] = Image.open(os.path.join(build_dir, f"{mode}_f{i}.png"))
        return frames_raw[i]

    h = CROP_H[mode]
    seq_dir = os.path.join(build_dir, f"{mode}_seq")
    if os.path.isdir(seq_dir):
        shutil.rmtree(seq_dir)
    os.makedirs(seq_dir)

    flat = []
    for spec in SEQUENCES[mode]:
        flat.extend(_expand(mode, spec, coords, load))

    inputs = []
    for n, (img, dur) in enumerate(flat):
        img = crop(img, h)
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
    modes = sys.argv[1:] or ["jump", "preview", "hjump", "hpreview"]
    for mode in modes:
        build(mode, build_dir, out_dir)
