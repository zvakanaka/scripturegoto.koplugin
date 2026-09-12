# Dev environment & testing

`../vendor/` holds a self-contained KOReader desktop build (the official
Linux x86_64 AppImage, extracted) plus an isolated settings/home dir, so
you can iterate on the plugin without touching your real KOReader install.

- `vendor/squashfs-root/` — extracted AppImage (gitignored; redownload
  with the command below if it goes missing)
- `vendor/koreader-home/` — isolated `KO_HOME` for this dev instance,
  created fresh by `run-test.sh` on first run (gitignored entirely - it's
  regenerated local state, none of it meant to be shared)
- `scripturegoto.koplugin/` — the plugin source, symlinked into
  `vendor/squashfs-root/usr/lib/koreader/plugins/`, so edits are live

Redownload the AppImage if `vendor/squashfs-root` is missing or you want
to update KOReader:

```sh
curl -sL -o vendor/koreader-x86_64.AppImage \
  https://github.com/koreader/koreader/releases/latest/download/koreader-x86_64.AppImage
chmod +x vendor/koreader-x86_64.AppImage
(cd vendor && ./koreader-x86_64.AppImage --appimage-extract)
ln -sf ../../../../../../scripturegoto.koplugin \
  vendor/squashfs-root/usr/lib/koreader/plugins/scripturegoto.koplugin
```

## Running it

```sh
./run-test.sh                      # opens test-books/source-book.epub
./run-test.sh /path/to/other.epub  # open something else
```

Sets `KO_HOME` to `vendor/koreader-home` (fully isolated from your real
KOReader config) and launches the emulator. Plugin edits under
`scripturegoto.koplugin/` take effect on the next launch - no rebuild
step, it's just Lua.

After a fresh checkout, set each scripture volume's EPUB path once via
More tools → **Scripture Goto** in the app, or by editing
`vendor/koreader-home/settings.reader.lua`'s `scripturegoto_volume_epubs`
table directly.

## Test fixtures

- `test-bible.epub` — fake "Bible" with Genesis 1, Matthew 6-8, and John
  3, each verse a numbered paragraph, hand-built
- `source-book.epub` — a book with a grab-bag of scripture links across
  all supported providers plus edge cases, hand-built
- Real public-domain Gutenberg EPUBs, useful for edition quirks hand-built
  fixtures don't reproduce - not committed to the repo, download your own
  copy if missing:
  - Book of Mormon (ebook 17, `Smith, Joseph, Jr. - The Book of Mormon...epub`)
    — per-chapter TOC (e.g. "Alma Chapter 32"); verses marked "chapter:verse"
  - King James Bible (ebook 10, `kjv-gutenberg.epub`) — TOC has only *one
    entry per book* (e.g. "The Proverbs"), no chapter-level heading at
    all; verses also marked "chapter:verse". Handled by
    `findBookTocEntry`/`findChapterStartXPointer` in `main.lua`.
  - A different King James Bible edition (ebook 10900, `kjv-10900.epub`)
    — each book's TOC entry has a *nested child* entry whose title is
    actually a chapter-number picker widget's text (e.g. "2 3 4 5 ... 31"),
    not a real heading. Handled by `looksLikeChapterNumberList` in
    `findBookTocEntry`, which skips such entries when picking the "next
    entry" boundary.

## Manual test walkthrough

1. `./run-test.sh` — opens the source book.
2. Tap the "Matthew 7:7" link, then tap **Go to scripture**. It should
   switch into `test-bible.epub` and land on Matthew 7:7.
3. Highlight some plain text that looks like a scripture reference (e.g.
   type/select "Matthew 7:7") - the selection menu should also offer
   **Go to scripture**.
4. Either menu also offers **Preview scripture** - first use for a volume
   asks to download its text (cached under `scripturegoto/` in
   `KO_HOME`), then opens a floating window. From a selection it pops up
   next to the selected text (smaller); from a link tap it's centered and
   larger.
5. More tools → **Scripture Goto** also lets you set each volume's EPUB,
   open a test link via a paste-a-URL dialog, and view **About Scripture
   Goto…** (credits the text data source).
