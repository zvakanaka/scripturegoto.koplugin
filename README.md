# koreader-scripture-goto

A KOReader plugin (`scripturegoto.koplugin`) that adds scripture-reference
buttons to two different menus - the link-tap menu (alongside Copy/QR
code/Open in browser) for supported scripture links tapped inside *any*
open book, and the text-selection/highlight menu (alongside Copy/Highlight/
Dictionary) when the selected text itself looks like a plain-text scripture
reference (e.g. selecting "Alma 40:11-14" in a footnote):

- **Go to scripture** jumps straight to the matching chapter/verse in a
  locally configured scripture EPUB (e.g. a Bible epub).
- **Preview scripture** shows the verse text (or verse range/list, or -
  for a reference with no verse at all, whether a chapter-only *link* with
  no `id=`/verse in the URL or a chapter-only plain-text reference - a
  whole chapter or chapter range, e.g. "Ecclesiastes 3-4") in a floating
  window instead, using text downloaded on first use from
  [bcbooks/scriptures-json](https://github.com/bcbooks/scriptures-json) -
  no EPUB needs to be configured for this one.

Supported link providers (`scripturegoto.koplugin/providers/`):

- **ChurchofJesusChrist.org** —
  `https://www.churchofjesuschrist.org/study/scriptures/nt/matt/7?lang=eng&id=p7#p7`
  → opens the configured "nt" EPUB and jumps to Matthew 7:7. Multi-verse
  links (`id=p5-p7` or `id=p5,p7`) resolve their full verse range/list too
  (`providers/verse_list.lua`, shared with `reference_text.lua` below), and
  a multi-*chapter* link (a chapter range right in the URL path, e.g.
  `.../ot/eccl/1-2` for a footnote citing "Ecclesiastes 1-2") resolves its
  full chapter range for "Preview scripture" the same way a chapter-range
  plain-text reference does - the EPUB jump itself always targets just the
  first verse/chapter.
- **Bible Gateway** —
  `https://www.biblegateway.com/passage/?search=John+3%3A16&version=NIV`
  → Matthew/John/etc. all resolve to the same "ot"/"nt" EPUBs as above.
- **YouVersion / Bible.com** —
  `https://www.bible.com/bible/111/jhn.3.16.NIV`

Each provider only needs to recognize its own URL shape and resolve it to a
book name; which EPUB it opens is still driven by the shared per-volume
settings (`ot`, `nt`, `bofm`, `dc-testament`, `pgp`), so Bible Gateway and
YouVersion links share whatever EPUB you've already set for `ot`/`nt`.
Adding another site is a matter of dropping a new module in `providers/`
(see the existing ones for the small interface it needs) and listing it in
`PROVIDERS` in `main.lua`.

A separate, non-URL "provider" (`providers/reference_text.lua`) powers the
highlight-menu button: it looks for a run of words immediately before a
chapter number (optionally `:verse`) that matches a known book name or
common abbreviation (e.g. "Isa.", "D&C", "1 Ne.", "JST M"), trying the
longest matching run of words first (so "Song of Solomon" wins over
"Solomon" alone). It's necessarily heuristic - free text has no
scheme/host to anchor on - so it only recognizes references it can
confidently resolve and otherwise just doesn't show the button. Its
`ALIASES` table's coverage (including the LDS-specific abbreviations like
"D&C"/"JST M"/em-dash book names) is based on a reference regex/lookup
implementation the user supplied; see `ALIASES` in that file to extend
book-name coverage further.

It's also tolerant of common touchscreen highlight-selection mishaps:
trailing punctuation right after a verse number ("Job 38:7." or "Job
38:7,") is naturally ignored since the verse-list capture just stops at
the first non-digit/comma/hyphen character. A **dangling colon** - the
drag stopping right at or just past the colon before reaching the verse
digits, e.g. "Job 38:" or "Job 38: and" - is trickier: naively, that looks
like an incomplete verse reference, but since the colon has no verse
digits after it, the chapter:verse pass above never had anything to match
there in the first place, so the chapter-only pass treats it the same as
a plain "Job 38" and previews/jumps to the whole chapter instead of
showing nothing. Only a colon actually followed by a digit is treated as
"a real (if unresolved) verse reference" and left alone.

## Dev environment

`./vendor/` holds a self-contained KOReader desktop build (the official
Linux x86_64 AppImage, extracted) plus an isolated settings/home dir, so
you can iterate on the plugin without touching your real KOReader install.

- `vendor/squashfs-root/` — extracted AppImage (gitignored, redownload with
  the curl command below if it goes missing)
- `vendor/koreader-home/` — isolated `KO_HOME` for this dev instance,
  created fresh by `run-test.sh` on first run (gitignored entirely - it's
  regenerated local state: absolute paths under your home dir, a random
  device id, reading history, etc., none of it meant to be shared). After
  a fresh checkout, configure each scripture volume's EPUB path once via
  the plugin's own **More tools → Scripture Goto** menu (or by editing
  `vendor/koreader-home/settings.reader.lua`'s `scripturegoto_volume_epubs`
  table directly, same format as the plugin's own settings)
- `scripturegoto.koplugin/` — the plugin source, symlinked into
  `vendor/squashfs-root/usr/lib/koreader/plugins/`, so edits are live
- `test-books/` — EPUBs for manual testing:
  - `test-bible.epub` — fake "Bible" with Genesis 1, Matthew 6-8, and John
    3, each verse a numbered paragraph, hand-built
  - `source-book.epub` — a book with a grab-bag of scripture links across
    all supported providers plus edge cases, hand-built
  - real public-domain Gutenberg EPUBs, useful for testing against actual
    edition quirks (verse markup, TOC granularity) that hand-built fixtures
    don't reproduce - not committed to the repo, download your own copy if
    missing:
    - the Book of Mormon (ebook 17) - per-chapter TOC (e.g. "Alma Chapter
      32"), verses marked "chapter:verse"
    - the King James Bible (ebook 10, saved as `kjv-gutenberg.epub`) - TOC
      has only *one entry per book* (e.g. "The Proverbs"), no chapter-level
      heading at all; verses are also marked "chapter:verse" - this is what
      `findBookTocEntry` / `findChapterStartXPointer` in `main.lua` handle
    - a different King James Bible edition (ebook 10900, saved as
      `kjv-10900.epub`) - each book's TOC entry has a *nested child* entry
      whose title is actually a chapter-number picker widget's text (e.g.
      "2 3 4 5 ... 31", not a real heading); naively using that as the
      "next entry" boundary would wrongly restrict the whole-book search to
      just chapter 1, since that entry sits right after the book heading,
      before any verse text at all - `findBookTocEntry` skips past any
      such entry (`looksLikeChapterNumberList`) when picking the boundary

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

This sets `KO_HOME` to `vendor/koreader-home` (fully isolated from your
real KOReader config) and launches the emulator. Plugin edits under
`scripturegoto.koplugin/` take effect on the next launch — no rebuild step,
it's just Lua.

## Manual test

1. `./run-test.sh` — opens the source book.
2. Tap the "Matthew 7:7" link, then tap **Go to scripture** in the menu that
   appears (Copy/QR code/Open in browser are still there too).
3. It should switch documents into `test-bible.epub` and land on chapter 7,
   verse 7 ("This is Matthew chapter 7, verse 7...").
4. Long-press (or select) some plain text that looks like a scripture
   reference, e.g. type/select "Matthew 7:7" as regular prose anywhere -
   the highlight/selection menu that appears should also offer **Go to
   scripture**, distinct from the link-tap menu in step 2.
5. Either menu also offers **Preview scripture**. The first time you use
   it for a given volume it'll ask to download that volume's text (a few
   MB, cached under `scripturegoto/` in KOReader's data dir - `KO_HOME` in
   this dev setup); after that it opens instantly in a movable floating
   window, no EPUB required. From a text selection it pops up right next
   to the selected text (smaller, not centered); from a link tap it's
   centered and larger, KOReader's usual default sizing.
6. From the main menu → More tools → **Scripture Goto** you can also:
   - Set the EPUB path used for each scripture volume (`ot`, `nt`, `bofm`,
     `dc-testament`, `pgp`)
   - Open a test link via a paste-a-URL dialog, useful for testing
     chapter/verse resolution without needing a source book at all
   - View **About Scripture Goto…**, which credits bcbooks/scriptures-json
     as the source of the "Preview scripture" text

## How it works (plugins/scripturegoto.koplugin/main.lua)

- Registers a button (via `ReaderLink:addToExternalLinkDialog`, the same
  extension point the stock Copy/QR code/Open in browser buttons use) that
  only shows up in the link-tap dialog when the tapped URL matches a
  supported scripture provider, and otherwise leaves that dialog untouched.
- Tries each provider in `providers/` in turn; the first one whose URL
  pattern matches resolves the link to `{volume, book, chapter, verse}`.
  `book_data.lua` holds both the LDS slug→name tables and a derived
  `BOOK_VOLUME_BY_NAME` lookup that the non-LDS providers use to map a
  plain English book name back to an `ot`/`nt` volume.
- Opens (or switches to) the EPUB configured for that volume
  (`G_reader_settings` key `scripturegoto_volume_epubs`).
- Finds the chapter via the target EPUB's table of contents (fuzzy title
  match on book name + chapter number), jumps to it, then does a
  best-effort forward text search for the verse number to refine further.

The verse-level jump is **heuristic** — it depends on how your actual
Bible EPUB marks verses (leading number, pilcrow, etc). The regex used to
find the verse marker is `[^0-9]%d+[^0-9]` by default and can be overridden
via `G_reader_settings:saveSetting("scripturegoto_verse_pattern", "...")`
if your EPUB needs something else. A `"<chapter>:<verse>"` prefix (e.g.
`32:21 Yea, ...`, as used by the Project Gutenberg Book of Mormon edition)
is always tried as a built-in fallback alongside that pattern, so editions
using either style work without extra configuration
(`getVersePatternCandidates` in `main.lua`). Chapter-level jump via TOC
matching is solid regardless.

Two non-obvious crengine quirks this relies on, found by instrumenting a
real search against the Project Gutenberg Book of Mormon EPUB (see
`CreDocument:findText` and `koreader-base/cre.cpp` upstream):
- `findText`'s direction argument is **0 for forward, 1 for backward**
  (opposite of what you'd guess) — passing 1 silently searches backward
  from the chapter start and never finds anything forward of it.
- Its regex engine does **not** anchor `^` to each paragraph/line, only to
  the very start of the whole search buffer, and paragraphs are
  concatenated with no separator in that buffer. So `^%d+[^0-9]` never
  matches past the very first paragraph. The pattern is bracketed by
  `[^0-9]` on *both* sides instead (no `^`), and since that alone can still
  match a verse/chapter number merely mentioned in another verse's prose
  (e.g. "...as told in chapter 7, verse 1..."), every candidate hit is
  re-validated in Lua against its own paragraph's full text
  (`getTextFromXPointer`) before being accepted, picking the first hit that
  is both in-chapter and genuinely starts with that marker.

**Preview scripture** (`scripture_data.lua`) is independent of all of the
above - it doesn't need a chapter TOC or an EPUB at all. On first use for
a volume it downloads that volume's flat verse-text JSON from
[bcbooks/scriptures-json](https://github.com/bcbooks/scriptures-json)
(`flat/*.json`, each just `{ verses: [{reference: "1 Nephi 1:1", text:
"..."}, ...] }`) into `scripturegoto/` under KOReader's data dir, then
parses it into an in-memory `"book|chapter|verse" → text` index, plus a
companion `"book|chapter" → {verse numbers, in order}` index, both rebuilt
once per session, per volume, on first lookup. A small
`book_name_overrides` table in `scripture_data.lua` maps our canonical
book names to the few cases where this dataset's own naming differs
("Doctrine and Covenants" → "D&C", "Song of Solomon" → "Solomon's Song",
and em-dash forms for the two Joseph Smith Pearl of Great Price books).
This dataset doesn't include the Official Declarations, so those won't
preview even though a churchofjesuschrist.org link to one still resolves
fine. A verse range or list (e.g. "Alma 40:11-14" or "Isa. 24:21, 22")
shows *every* verse in it, each line prefixed with its full "Book
Chapter:Verse" reference (`ScriptureData:getVerseText`); a reference with
no verse at all - just a chapter, or a chapter range like "Ecclesiastes
3-4" - shows every verse of every chapter in it instead
(`ScriptureData:getChapterText`, `providers/reference_text.lua`'s
`chapters` field). Either way the floating window's title shows the
range/list collapsed (`formatRangeLabel` in `main.lua`, e.g.
"12-14,16-17" for verses, "3-4" for chapters). The bcbooks/scriptures-json
data source is credited (with a link) in the plugin's own **About
Scripture Goto…** menu entry (More
tools → Scripture Goto), so anyone using the feature can find where the
text came from.

When opened from a text selection, the preview window is sized down
(~90% width, ~40% height) and pops up right next to the selected text
instead of centered/near-fullscreen - see `getSelectionAnchor` in
`main.lua`. This intentionally does *not* reuse ReaderHighlight's own
`highlight_dialog_position` setting/logic (which governs a different
dialog, its own action menu, and is usually left at "center"); it's a
self-contained reimplementation of the same "pop up above/below the
selection, whichever has room" math so our preview always anchors
regardless of that setting. Opened from a link tap (no text selection to
anchor to), it falls back to TextViewer's own default, larger, centered
sizing.

## Known gaps / next steps

- `findChapterStartXPointer` (the book-level-TOC-fallback chapter finder)
  bounds its search by the *next* TOC entry, to avoid landing in some
  other book's same-numbered chapter. An earlier version fell back to an
  *unbounded* retry when the bounded search came up empty, on the theory
  that the bound itself might be stale/wrong - but that was reverted after
  it was confirmed (while investigating a real report of a "couldn't find
  chapter N" failure) to itself risk silently landing in a same-numbered
  chapter of the *wrong book*, which is worse than a clear error since a
  reader might not immediately notice.
  The underlying report turned out to be a real, reproducible edition
  difference (ebook 10900, a different King James Bible edition than
  ebook 10 - see "Dev environment" above): its TOC nests a *chapter-number
  picker widget* right after each book's own heading, which `toc[i+1]`
  would naively treat as "the next book", making the search boundary
  effectively "end of chapter 1" - too tight for any later chapter (or
  even, in this specific edition, chapter 1's own verse search, since that
  boundary landed *before* the verse text even starts). Fixed by having
  `findBookTocEntry` skip past any entry that looks like such a widget
  (`looksLikeChapterNumberList`) when picking the boundary.
- Verse-search pattern (for the EPUB jump) will need tuning for editions
  that mark verses differently than a bare leading number or a
  `chapter:verse` prefix (verse markup varies a lot between editions).
- No handling yet for multi-column/red-letter/footnote edge cases in the
  EPUB jump's verse search.
- The plain-text reference detector (`providers/reference_text.lua`) is
  necessarily best-effort - free text has no scheme/host to anchor on -
  and its `ALIASES` book-name/abbreviation table, while reasonably
  thorough, isn't exhaustive; extend it as more abbreviations/edge cases
  come up.
- "Preview scripture" can't show the Official Declarations (D&C OD 1/2) -
  the bcbooks/scriptures-json dataset it uses doesn't include them - even
  though a churchofjesuschrist.org link to one still resolves fine for the
  EPUB jump.
