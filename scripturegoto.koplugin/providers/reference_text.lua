-- Detects a plain-text scripture reference inside arbitrary selected/
-- highlighted text (as opposed to a tappable hyperlink) - e.g. "Alma
-- 40:11-14" or "Isa. 24:21, 22" - and resolves it to {volume, book,
-- chapter, verse, verses, chapters}. `verse` is just the *first* verse (a
-- plain number), since that's all ScriptureGoto's chapter+verse jump
-- needs; `verses` is the full expanded, deduplicated, sorted list of
-- individual verse numbers covering every range and list item in the
-- reference (e.g. "12-14,16-17" -> {12,13,14,16,17}), for the
-- verse-preview feature to show all of them, not just the first. For a
-- reference with no verse at all - just a chapter, or a chapter range
-- like "Ecclesiastes 3-4" - `verse`/`verses` are nil and `chapters` holds
-- every chapter number covered instead (e.g. {3,4}), for the preview
-- feature to show those whole chapters.
--
-- This is necessarily heuristic: free text has no scheme/host to anchor
-- on, so a reference is only recognized when a run of words immediately
-- before a chapter number matches a known book name or abbreviation.
local BOOK_DATA = require("book_data")
local VerseList = require("providers.verse_list")

-- Aliases (lowercased, periods stripped, whitespace-collapsed) for names
-- that don't already match a canonical name in book_data.lua's ot/nt/
-- bofm/dc-testament/pgp tables. Not exhaustive - add more as needed.
local ALIASES = {
    -- Old Testament
    gen = "Genesis", exod = "Exodus", ex = "Exodus", lev = "Leviticus", num = "Numbers",
    deut = "Deuteronomy", josh = "Joshua", judg = "Judges",
    ["1 sam"] = "1 Samuel", ["2 sam"] = "2 Samuel",
    ["1 kgs"] = "1 Kings", ["2 kgs"] = "2 Kings", ["1 kings"] = "1 Kings", ["2 kings"] = "2 Kings",
    ["1 chr"] = "1 Chronicles", ["2 chr"] = "2 Chronicles",
    neh = "Nehemiah", esth = "Esther",
    ps = "Psalms", psalm = "Psalms", psalms = "Psalms",
    prov = "Proverbs", eccl = "Ecclesiastes", song = "Song of Solomon",
    isa = "Isaiah", jer = "Jeremiah", lam = "Lamentations", ezek = "Ezekiel",
    dan = "Daniel", obad = "Obadiah", hab = "Habakkuk", zeph = "Zephaniah",
    hag = "Haggai", zech = "Zechariah", mal = "Malachi",
    -- New Testament
    matt = "Matthew", rom = "Romans",
    ["1 cor"] = "1 Corinthians", ["2 cor"] = "2 Corinthians",
    gal = "Galatians", eph = "Ephesians", phil = "Philippians", philip = "Philippians",
    col = "Colossians",
    ["1 thes"] = "1 Thessalonians", ["2 thes"] = "2 Thessalonians",
    ["1 thess"] = "1 Thessalonians", ["2 thess"] = "2 Thessalonians",
    ["1 tim"] = "1 Timothy", ["2 tim"] = "2 Timothy",
    philem = "Philemon", heb = "Hebrews",
    ["1 pet"] = "1 Peter", ["2 pet"] = "2 Peter",
    ["1 jn"] = "1 John", ["2 jn"] = "2 John", ["3 jn"] = "3 John",
    rev = "Revelation", revelations = "Revelation",
    -- Book of Mormon
    ["1 ne"] = "1 Nephi", ["2 ne"] = "2 Nephi",
    ["w of m"] = "Words of Mormon", ["of m"] = "Words of Mormon",
    hel = "Helaman", ["3 ne"] = "3 Nephi", ["4 ne"] = "4 Nephi",
    morm = "Mormon", moro = "Moroni",
    -- Doctrine and Covenants
    ["d&c"] = "Doctrine and Covenants", ["d & c"] = "Doctrine and Covenants",
    ["doctrine and covenants"] = "Doctrine and Covenants",
    od = "Official Declaration",
    -- Pearl of Great Price
    ["joseph smith-matthew"] = "Joseph Smith-Matthew", ["joseph smith—matthew"] = "Joseph Smith-Matthew",
    ["js-m"] = "Joseph Smith-Matthew", jsm = "Joseph Smith-Matthew", ["jst m"] = "Joseph Smith-Matthew",
    ["joseph smith-history"] = "Joseph Smith-History", ["joseph smith—history"] = "Joseph Smith-History",
    ["js-h"] = "Joseph Smith-History", jsh = "Joseph Smith-History",
    ["a of f"] = "Articles of Faith", aof = "Articles of Faith",
}

-- Lowercase, strip periods, collapse whitespace, trim.
local function normalize(text)
    text = text:gsub("%.", ""):gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:lower()
end

local function resolveBookName(normalized)
    local alias = ALIASES[normalized]
    if alias then
        return BOOK_DATA.BOOK_VOLUME_BY_NAME[alias:lower()]
    end
    return BOOK_DATA.BOOK_VOLUME_BY_NAME[normalized]
end

-- Given the text immediately before a chapter number, find which trailing
-- run of words is the book name, preferring the longest recognized match
-- (so "Song of Solomon" wins over "Solomon" alone). Only looks within the
-- current clause (stops at a comma/semicolon/newline) so unrelated
-- preceding prose ("...see also Isaiah 25:4") isn't swept in.
local function findBookBeforeChapter(prefix_text)
    local tail = prefix_text:match("[^,;\n]*$") or prefix_text
    local words = {}
    for w in tail:gmatch("%S+") do
        table.insert(words, w)
    end
    for take = math.min(4, #words), 1, -1 do
        local candidate = table.concat(words, " ", #words - take + 1, #words)
        local resolved = resolveBookName(normalize(candidate))
        if resolved then
            return resolved
        end
    end
    return nil
end

local function parseReference(text)
    if not text then return nil end

    -- Normalize en/em dashes to a plain hyphen so range detection below
    -- doesn't need to special-case them.
    text = text:gsub("\226\128\147", "-"):gsub("\226\128\148", "-")

    -- "book chapter:verse[-verse][,verse[-verse]...]" form, e.g.
    -- "40:11-14", "24:21, 22", "6:12-14,16-17".
    local search_start = 1
    while true do
        local num_start, num_end, chapter_str, verse_list_str =
            text:find("(%d+)%s*:%s*(%d+[%d%s,%-]*)", search_start)
        if not num_start then break end
        local resolved = findBookBeforeChapter(text:sub(1, num_start - 1))
        if resolved then
            local verses = VerseList.expand(verse_list_str)
            return {
                volume = resolved.volume,
                book = resolved.name,
                chapter = tonumber(chapter_str),
                verse = verses[1],
                verses = verses,
            }
        end
        search_start = num_end + 1
    end

    -- "book chapter[-chapter]" form with no verse at all, e.g.
    -- "Zechariah 14" or "Ecclesiastes 3-4" (a whole-chapter range). Also
    -- covers a *dangling* colon with no verse digits after it at all, e.g.
    -- "Job 38:" or "Job 38: " - a common highlight-selection mishap where
    -- the drag stops right at the colon - since if the colon really did
    -- have verse digits after it, the loop above would already have
    -- claimed this position (matched or not); only skip a colon that's
    -- actually followed by a digit, to avoid re-treating a real (if
    -- unresolved) chapter:verse reference as chapter-only.
    search_start = 1
    while true do
        local num_start, num_end, chapter_str = text:find("(%d+)", search_start)
        if not num_start then break end
        local after = text:sub(num_end + 1)
        if not after:match("^%s*:%s*%d") then
            local resolved = findBookBeforeChapter(text:sub(1, num_start - 1))
            if resolved then
                local chapter = tonumber(chapter_str)
                local end_chapter = tonumber(after:match("^%s*%-%s*(%d+)")) or chapter
                local chapters = {}
                for c = chapter, end_chapter do table.insert(chapters, c) end
                return {
                    volume = resolved.volume,
                    book = resolved.name,
                    chapter = chapter,
                    verse = nil,
                    chapters = chapters,
                }
            end
        end
        search_start = num_end + 1
    end

    return nil
end

return {
    id = "reference_text",
    parse = parseReference,
}
