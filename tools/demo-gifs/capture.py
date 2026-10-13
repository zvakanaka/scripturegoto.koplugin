"""Helper for record.py: turns a screenshot saved by demo_hook.lua
(koreader's own framebuffer, at its internal resolution) into a frame of the
fixed size the GIF assembly expects.
"""
from PIL import Image


def load_shot(src, dst, content_w, content_h):
    """Scales the screenshot at `src` to `content_w` wide (keeping the aspect
    ratio), then crops or pads (white) to `content_h` tall, anchored at the
    top, and saves it to `dst`. koreader's emulator window is not reliably
    any particular size, so the width is normalised here and the hook scales
    its tap coordinates by the same factor."""
    img = Image.open(src).convert("RGB")
    new_h = round(img.height * content_w / img.width)
    img = img.resize((content_w, new_h), Image.LANCZOS)
    if new_h >= content_h:
        img = img.crop((0, 0, content_w, content_h))
    else:
        canvas = Image.new("RGB", (content_w, content_h), "white")
        canvas.paste(img, (0, 0))
        img = canvas
    img.save(dst)
    return img
