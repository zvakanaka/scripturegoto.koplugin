"""X11 helpers for finding the koreader emulator window and screenshotting
it. Only used by record.py; not needed to run the plugin itself.
"""
from Xlib import display
from Xlib import X

d = display.Display(':0')


def _find_all_windows(root=None, matches=None):
    # Killing a previous run's koreader process (SIGKILL, since it doesn't
    # exit on its own from a scripted demo) has been observed to leave its
    # X11 window behind: unmapped from any live process, but still present
    # in the window tree and still answering get_image() with its last
    # rendered content. Collecting every match and picking the
    # highest-numbered window id (X assigns ids in increasing order, so
    # this is always the most recently created one) avoids grabbing one of
    # these ghosts instead of the live window from *this* run.
    root = root or d.screen().root
    if matches is None:
        matches = []
    for child in root.query_tree().children:
        try:
            name = child.get_wm_name()
        except Exception:
            name = None
        if name and 'KOReader' in str(name):
            matches.append(child)
        _find_all_windows(child, matches)
    return matches


def destroy_stale_windows():
    """Destroys every existing KOReader-named X11 window. Call this before
    launching a new koreader process, so a leftover ghost from a prior run
    can never be mistaken for the new one."""
    for w in _find_all_windows():
        try:
            w.destroy()
        except Exception:
            pass
    d.sync()


def find_window():
    matches = _find_all_windows()
    if not matches:
        return None
    return max(matches, key=lambda w: w.id)


def capture(path, content_w, content_h):
    """Screenshots the koreader window and saves it to `path`, scaled to
    (content_w, content_h). koreader/SDL does not honor the requested
    window size in every sandbox (it reports back whatever size the window
    manager actually assigned), so rather than crop to a fixed box (which
    can clip wide dialogs), the whole captured window is scaled to the
    target width, preserving aspect ratio, then cropped/padded to the
    target height, anchored at the top."""
    from PIL import Image

    win = find_window()
    if not win:
        raise RuntimeError('KOReader window not found')
    geom = win.get_geometry()
    raw = win.get_image(0, 0, geom.width, geom.height, X.ZPixmap, 0xffffffff)
    img = Image.frombytes('RGB', (geom.width, geom.height), raw.data, 'raw', 'BGRX')
    scale = content_w / geom.width
    new_h = round(geom.height * scale)
    img = img.resize((content_w, new_h), Image.LANCZOS)
    if new_h >= content_h:
        img = img.crop((0, 0, content_w, content_h))
    else:
        canvas = Image.new('RGB', (content_w, content_h), 'white')
        canvas.paste(img, (0, 0))
        img = canvas
    img.save(path)
    return img
