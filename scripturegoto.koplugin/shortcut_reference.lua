-- Gospel Library-style abbreviated reference shortcuts for the search
-- dialog: "ne37" offers 1 Nephi 3:7, 2 Nephi 3:7, 3 Nephi 3:7, 4 Nephi
-- 1:37 and Nehemiah 3:7; "1ne37" only 1 Nephi 3:7; "jn316" John 3:16;
-- "dc76" D&C 7:6 and D&C 76. Also takes explicit separators ("alma 32:21",
-- "ne 3 7", "gen 1:1-3") and a bare numbered book ("3 nephi").
--
-- The letters are matched against every book's abbreviations (the
-- churchofjesuschrist.org slugs from book_data.lua plus reference_text.lua's
-- aliases) and full name, ignoring any leading book number, which then
-- narrows the match if given. A digit run without a separator is split
-- every way that names a real chapter and verse (per the bundled
-- chapter_verses.lua) - so "37" is 3:7 in 1 Nephi but 1:37 in single-
-- chapter 4 Nephi - and is also tried as a whole chapter.
local BOOK_DATA = require("book_data")
local CHAPTER_VERSES = require("chapter_verses")
local ReferenceText = require("providers.reference_text")

local VOLUME_TITLES = {
    ot = "Old Testament",
    nt = "New Testament",
    bofm = "Book of Mormon",
    ["dc-testament"] = "Doctrine and Covenants",
    pgp = "Pearl of Great Price",
}

local MAX_RESULTS = 30

-- Lowercase and drop everything but letters and "&" ("D&C"), so "W of M",
-- "w-of-m" and "wofm" all compare equal.
local function squash(s)
    return (s:lower():gsub("[^%a&]", ""))
end

-- Splits a leading book number off a name, slug or alias: "1 Nephi" ->
-- "1", "Nephi"; "1-ne" -> "1", "ne"; "Alma" -> nil, "Alma".
local function splitBookNumber(s)
    local num, base = s:match("^(%d)[%s%-]+(.+)$")
    if num then return num, base end
    return nil, s
end

-- Built on first use: one entry per book, in canonical order, with the
-- squashed keys its letters can match against.
local books

local function getBooks()
    if books then return books end
    books = {}
    for i, entry in ipairs(CHAPTER_VERSES) do
        local num, base = splitBookNumber(entry.book)
        local exact = { [squash(base)] = true }
        for slug, name in pairs(BOOK_DATA[entry.volume] or {}) do
            if name == entry.book then
                local _, slug_base = splitBookNumber(slug)
                exact[squash(slug_base)] = true
            end
        end
        for alias, name in pairs(ReferenceText.ALIASES) do
            if name == entry.book then
                local _, alias_base = splitBookNumber(alias)
                exact[squash(alias_base)] = true
            end
        end
        local later_words = {}
        local first = true
        for word in base:gmatch("[^%s%-]+") do
            if not first then table.insert(later_words, squash(word)) end
            first = false
        end
        table.insert(books, {
            order = i,
            volume = entry.volume,
            name = entry.book,
            number = num,
            exact = exact,
            later_words = later_words,
            verses = entry.verses,
        })
    end
    return books
end

local function startsWith(s, prefix)
    return s:sub(1, #prefix) == prefix
end

-- 0 = an abbreviation or the name itself, 1 = the start of one, 2 = the
-- start of a later word of the name ("mormon" -> Words of Mormon), nil =
-- no match.
local function matchRank(book, letters)
    if book.exact[letters] then return 0 end
    for key in pairs(book.exact) do
        if startsWith(key, letters) then return 1 end
    end
    for _, word in ipairs(book.later_words) do
        if startsWith(word, letters) then return 2 end
    end
    return nil
end

-- Every {chapter, first_verse, last_verse} (verses nil for a whole
-- chapter, or chapters for a chapter range) the digits can mean in `book`.
local function candidatesFor(book, digits)
    local counts = book.verses
    local function valid(chapter, verse)
        return chapter and counts[chapter] ~= nil
            and (verse == nil or (verse >= 1 and verse <= counts[chapter]))
    end

    local out = {}
    if digits.kind == "book" then
        table.insert(out, { chapter = 1, whole_book = true })
    elseif digits.kind == "explicit" then
        local last = digits.last_verse or digits.verse
        if valid(digits.chapter, digits.verse) and valid(digits.chapter, last) and last >= digits.verse then
            table.insert(out, { chapter = digits.chapter, verse = digits.verse, last_verse = last })
        end
    elseif digits.kind == "chapters" then
        if #counts == 1 then
            -- "4 ne 3-7": a single-chapter book only has a verse range
            if valid(1, digits.first) and valid(1, digits.last) and digits.last >= digits.first then
                table.insert(out, { chapter = 1, verse = digits.first, last_verse = digits.last })
            end
        elseif valid(digits.first) and valid(digits.last) and digits.last >= digits.first then
            table.insert(out, { chapter = digits.first, last_chapter = digits.last })
        end
    else -- "run": an unseparated run of digits like "37" or "3221"
        local run = digits.run
        for k = 1, #run - 1 do
            local c, v = run:sub(1, k), run:sub(k + 1)
            if not c:match("^0") and not v:match("^0") then
                local chapter, verse = tonumber(c), tonumber(v)
                if valid(chapter, verse) then
                    table.insert(out, { chapter = chapter, verse = verse })
                end
            end
        end
        local n = tonumber(run)
        if #counts == 1 then
            -- the whole run as a verse: "37" -> 4 Nephi 1:37
            if valid(1, n) then
                table.insert(out, { chapter = 1, verse = n })
            end
        elseif valid(n) and not run:match("^0") then
            table.insert(out, { chapter = n })
        end
    end
    return out
end

-- Splits the query into a book number, the letters of a book name/
-- abbreviation, and a description of its digits. Returns nil if it
-- doesn't look like a shortcut at all.
local function parseQuery(query)
    local q = query:lower():gsub("\226\128[\147\148]", "-"):gsub("%.", " ")
    q = q:gsub("^%s+", ""):gsub("%s+$", "")

    local num, letters, rest = q:match("^(%d?)%s*([%a&][%a&%s%-]-)%s*(%d[%d%s:%-]*)$")
    if not num then
        num, letters = q:match("^(%d)%s*([%a&][%a&%s%-]*)$")
        if not num then return nil end
        rest = ""
    end
    letters = squash(letters)
    if letters == "" then return nil end
    if num == "" then num = nil end

    local digits
    local c, v, v2 = rest:match("^(%d+)%s*[:%s]%s*(%d+)%s*%-%s*(%d+)$")
    if c then
        digits = { kind = "explicit", chapter = tonumber(c), verse = tonumber(v), last_verse = tonumber(v2) }
    else
        c, v = rest:match("^(%d+)%s*[:%s]%s*(%d+)$")
        if c then
            digits = { kind = "explicit", chapter = tonumber(c), verse = tonumber(v) }
        else
            local a, b = rest:match("^(%d+)%s*%-%s*(%d+)$")
            if a then
                digits = { kind = "chapters", first = tonumber(a), last = tonumber(b) }
            elseif rest:match("^%d+$") then
                digits = { kind = "run", run = rest }
            elseif rest == "" then
                digits = { kind = "book" }
            else
                return nil
            end
        end
    end
    return num, letters, digits
end

-- Turns a book + candidate into the same {volume, book, chapter, verse,
-- verses, chapters} shape the link providers and reference_text.lua
-- resolve to, plus a display `label` and the volume's `volume_title`.
local function toParsed(book, cand)
    local parsed = {
        volume = book.volume,
        book = book.name,
        chapter = cand.chapter,
        volume_title = VOLUME_TITLES[book.volume],
    }
    if cand.verse then
        local verses = {}
        for v = cand.verse, cand.last_verse or cand.verse do table.insert(verses, v) end
        parsed.verse = cand.verse
        parsed.verses = verses
        parsed.label = book.name .. " " .. cand.chapter .. ":" .. cand.verse
            .. (#verses > 1 and ("-" .. verses[#verses]) or "")
    elseif cand.whole_book then
        parsed.chapters = { 1 }
        parsed.label = book.name
    else
        local chapters = {}
        for ch = cand.chapter, cand.last_chapter or cand.chapter do table.insert(chapters, ch) end
        parsed.chapters = chapters
        parsed.label = book.name .. " " .. cand.chapter
            .. (#chapters > 1 and ("-" .. chapters[#chapters]) or "")
    end
    return parsed
end

-- Returns a list (possibly empty) of parsed references the query could
-- be shorthand for, best matches first, or nil if the query isn't
-- shaped like a shortcut at all.
local function search(query)
    local num, letters, digits = parseQuery(query)
    if not num and not letters then return nil end
    -- A bare book with no chapter is only a shortcut when it's numbered
    -- ("3 nephi"); plain words are left to full-text search.
    if digits.kind == "book" and not num then return nil end

    local matches = {}
    for _, book in ipairs(getBooks()) do
        if not num or book.number == num then
            local rank = matchRank(book, letters)
            if rank then
                for i, cand in ipairs(candidatesFor(book, digits)) do
                    table.insert(matches, { rank = rank, order = book.order, i = i, parsed = toParsed(book, cand) })
                end
            end
        end
    end
    table.sort(matches, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.order ~= b.order then return a.order < b.order end
        return a.i < b.i
    end)

    local results = {}
    for i = 1, math.min(#matches, MAX_RESULTS) do
        table.insert(results, matches[i].parsed)
    end
    return results
end

return {
    search = search,
    VOLUME_TITLES = VOLUME_TITLES,
}
