# Demo GIFs

Regenerates the `docs/demo-*.gif` files used in the main README, by
driving a real (emulated) KOReader through each usage flow and recording
it:

- `demo-jump.gif` / `demo-preview.gif` - tapping a scripture link
- `demo-highlight-jump.gif` / `demo-highlight-preview.gif` - highlighting a
  plain-text reference ("Alma 7:24")
- `demo-search-shortcut.gif` / `demo-search-range.gif` /
  `demo-search-words.gif` - the "Search scriptures" dialog: a shortcut
  ("ne37"), a reference with a verse range ("alma 32:21-22"), and a word
  query ("ask seek knock"), each ending on the tinted verse(s)

## Running it

```
./tools/demo-gifs/run.sh
```

Prerequisites: the dev environment set up per
[`test-books/README.md`](../../test-books/README.md) (needs
`vendor/squashfs-root` and the `nt`/`ot`/`bofm` volume EPUBs configured in
`vendor/koreader-home/settings.reader.lua`), network access for the
one-time scripture-text cache download (all five volumes; the word-search
demo builds its index from them, once), `ffmpeg` on `PATH`, and a display
for the emulator window (`DISPLAY` set). Takes a few minutes; output lands
in `docs/`.

## How it works

Each demo is a list of steps in `modes.json` ("tap the link", "tap the
Search button", "open the menu", "tap Open previous document", ...), and
the GIF has one frame per step, with a tap indicator on the target of the
next one. The demos walk the whole path - through the reader menu to the
Search tab where that is the feature - and finish back in the
original book (via the menu's "Open previous document" after a jump, or by
closing the preview). Add or reorder steps there to change a demo.

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

At each stage the hook also saves a screenshot of koreader's own
framebuffer (`Screen:shot`) - not an X11 grab of the window, which can
return a stale picture after the document switches. `record.py` waits for
the stage, scales that screenshot to a fixed width (`capture.py`) and saves
the frames plus the recorded `coords.json` under `build/`.

`assemble.py` crops each frame, overlays a translucent red circle at the
recorded tap coordinate for the relevant transition, and hands the
sequence to `ffmpeg` to build the final GIF.

## Fixtures

`fixtures/notes/` is the source for the "Gospel Study Guide" notes EPUB
used as the on-screen document in every recording (a John 3:16 link and a
plain-text "Alma 7:24" mention; the search demos start from it too). `build_demo_epub.py` zips it into
`build/demo.epub`. Edit the fixture and rerun `run.sh` to change what the
demo book shows.
