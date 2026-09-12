"""Launches koreader with the SCRIPTUREGOTO_DEMO_HOOK dev hook active,
drives it through one demo mode's stages via a sentinel-file handshake, and
screenshots each stage. Returns the frame paths and any tap-indicator
coordinates the hook recorded (see demo_hook.lua) - assemble.py turns those
into the final GIFs.

Modes: "jump", "preview" (5 stages: notes page, dialog, landed/previewed,
menu, back at notes - jump only has the extra menu/back stages) and
"hjump", "hpreview" (3 stages: notes page, highlight menu, landed/previewed).
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from capture import find_window, capture, destroy_stale_windows

CONTENT_W, CONTENT_H = 720, 972

STAGE_COUNT = {"jump": 5, "preview": 3, "hjump": 3, "hpreview": 3}


def _wait_for(path, timeout=20):
    start = time.time()
    while time.time() - start < timeout:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {path}")


def _wait_for_window(timeout=10):
    start = time.time()
    while time.time() - start < timeout:
        try:
            w = find_window()
            if w:
                return w
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("window not found in time")


def _kill_group(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass


def record(mode, out_dir, book, settle=2.5):
    """Runs one demo mode. Returns (frame_paths, coords) where coords is the
    dict written by demo_hook.lua (tap-indicator target -> {"x":, "y":})."""
    n_stages = STAGE_COUNT[mode]
    demo_dir = tempfile.mkdtemp(prefix="scripturegoto-demo-")
    log_path = os.path.join(out_dir, f"record_{mode}.log")

    destroy_stale_windows()

    env = os.environ.copy()
    env["SCRIPTUREGOTO_DEMO"] = mode
    env["SCRIPTUREGOTO_DEMO_DIR"] = demo_dir
    env["SCRIPTUREGOTO_DEMO_HOOK"] = os.path.join(HERE, "demo_hook.lua")
    env["SCRIPTUREGOTO_DEMO_CONTENT_W"] = str(CONTENT_W)
    env["KO_HOME"] = os.path.join(REPO, "vendor", "koreader-home")

    proc = subprocess.Popen(
        ["./vendor/squashfs-root/usr/lib/koreader/koreader.sh", book],
        cwd=REPO, env=env,
        stdout=open(log_path, "w"), stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        _wait_for_window()

        frames = []
        _wait_for(os.path.join(demo_dir, "ready0"))
        time.sleep(settle)
        f0 = os.path.join(out_dir, f"{mode}_f0.png")
        capture(f0, CONTENT_W, CONTENT_H)
        frames.append(f0)

        for i in range(1, n_stages):
            open(os.path.join(demo_dir, f"go{i}"), "w").close()
            _wait_for(os.path.join(demo_dir, f"ready{i}"))
            time.sleep(settle)
            fi = os.path.join(out_dir, f"{mode}_f{i}.png")
            capture(fi, CONTENT_W, CONTENT_H)
            frames.append(fi)

        coords = {}
        coords_path = os.path.join(demo_dir, "coords.json")
        if os.path.exists(coords_path):
            with open(coords_path) as f:
                coords = json.load(f)
        with open(os.path.join(out_dir, f"{mode}_coords.json"), "w") as f:
            json.dump(coords, f)

        return frames, coords
    finally:
        time.sleep(0.2)
        _kill_group(proc)


if __name__ == "__main__":
    mode = sys.argv[1]
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(HERE, "build")
    book = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else os.path.join(HERE, "build", "demo.epub")
    os.makedirs(out_dir, exist_ok=True)
    frames, coords = record(mode, out_dir, book)
    print("frames:", frames)
    print("coords:", coords)
