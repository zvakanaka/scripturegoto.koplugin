# Demo GIFs

Regenerates the four `docs/demo-*.gif` files used in the main README, by
driving a real (emulated) KOReader through each usage flow and recording
it:

- `demo-jump.gif` / `demo-preview.gif` - tapping a scripture link
- `demo-highlight-jump.gif` / `demo-highlight-preview.gif` - highlighting a
  plain-text reference ("Alma 7:24")

## Running it

```
./tools/demo-gifs/run.sh
```

Prerequisites: the dev environment set up per
[`test-books/README.md`](../../test-books/README.md) (needs
`vendor/squashfs-root` and the `nt`/`ot`/`bofm` volume EPUBs configured in
`vendor/koreader-home/settings.reader.lua`), network access for the
one-time scripture-text cache download, and `ffmpeg` on `PATH`. Takes
around a minute; output lands in `docs/`.

## How it works

`scripturegoto.koplugin/main.lua` has a small permanent hook: if
`SCRIPTUREGOTO_DEMO_HOOK` is set to a Lua file path, that file is loaded
and run (with the plugin instance as its argument) at the end of `init()`.
It's a no-op for real users - nothing in the plugin ever sets that
variable itself. `demo_hook.lua` here is what actually gets loaded.

`record.py` launches koreader with `SCRIPTUREGOTO_DEMO` set to one of
`jump`/`preview`/`hjump`/`hpreview`, `SCRIPTUREGOTO_DEMO_HOOK` pointed at
`demo_hook.lua`, and `SCRIPTUREGOTO_DEMO_DIR` pointed at a fresh temp
directory. The hook and `record.py` hand-shake through sentinel files in
that directory (`goN` from the script means "advance to stage N"; `readyN`
from the hook means "stage N is done, safe to screenshot") - needed
because there's no way to script real touch/gesture input against this
emulator (X11 XTest fake input was tried and does not reach koreader's
SDL window here); every action is instead performed by calling the same
production code a real tap would run: `ReaderLink:onGoToExternalLink`,
button/menu-item `callback`s found via widget introspection (see below),
`ReaderHighlight:onShowHighlightMenu`, etc.

For each `goN`, `demo_hook.lua` also computes where a tap indicator should
go for the *next* stage's target, and writes it to `coords.json` in that
same directory:

- **Document text** ("John 3:16", "Alma 7:24"): found via
  `document:findText()` and converted to an on-screen box via
  `document:getScreenBoxesFromPositions()` - the same mechanism a real
  search-result highlight uses (see `readersearch.lua`).
- **Dialog buttons** ("Go to scripture", "Preview scripture"): found by
  walking the shown `ButtonDialog`'s `button_table.buttons_layout` grid
  for a `Button` widget with a matching `.text`, then reading its `.dimen`
  (populated with real screen coordinates once painted).
- **The menu icon and "Open previous document"**: found the same way, by
  walking the opened `TouchMenu`'s `bar.icon_widgets` / `item_group`.

None of this hardcodes pixel positions, so it isn't sensitive to whatever
window size the emulator's window manager happens to assign on a given
run (observed to vary between runs in this sandbox).

`record.py` screenshots each stage (via `capture.py`, which also works
around another sandbox quirk: a killed koreader process's X11 window can
linger and answer screenshot requests with its last frame, so `capture.py`
destroys every existing KOReader-named window before each launch and
always picks the highest window id - the most recently created - as the
live one) and saves the frames plus the recorded `coords.json` under
`build/`.

`assemble.py` crops each frame, overlays a translucent red circle at the
recorded tap coordinate for the relevant transition, and hands the
sequence to `ffmpeg` to build the final GIF.

## Fixtures

`fixtures/notes/` is the source for the "Gospel Study Guide" notes EPUB
used as the on-screen document in every recording (a John 3:16 link and a
plain-text "Alma 7:24" mention). `build_demo_epub.py` zips it into
`build/demo.epub`. Edit the fixture and rerun `run.sh` to change what the
demo book shows.
