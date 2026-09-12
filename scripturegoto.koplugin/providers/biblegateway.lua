-- Provider for biblegateway.com passage links, of the form
-- https://www.biblegateway.com/passage/?search=John+3%3A16&version=NIV
local BOOK_DATA = require("book_data")

local function urlDecode(s)
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    return s
end

-- Normalizes spelled-out/roman-numeral book ordinals ("First John", "I John",
-- "1st John") down to the leading-digit form ("1 John") our book tables use.
local ORDINAL_ALIASES = {
    first = "1", i = "1", ["1st"] = "1",
    second = "2", ii = "2", ["2nd"] = "2",
    third = "3", iii = "3", ["3rd"] = "3",
}

local function normalizeBookName(name)
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local ordinal, rest = name:match("^(%a+)%s+(.+)$")
    if ordinal and ORDINAL_ALIASES[ordinal:lower()] then
        name = ORDINAL_ALIASES[ordinal:lower()] .. " " .. rest
    end
    return name:lower()
end

return {
    id = "biblegateway",
    name = "Bible Gateway",

    parse = function(url)
        if not url:find("biblegateway%.com") then return nil end
        local ref = url:match("[?&]search=([^&]+)")
        if not ref then return nil end
        ref = urlDecode(ref)

        -- e.g. "John 3:16", "1 Corinthians 13", "Song of Solomon 2:1-4"
        local book_part, chapter, verse = ref:match("^(.-)%s+(%d+)%s*:?%s*(%d*)")
        if not book_part or chapter == "" then return nil end

        local resolved = BOOK_DATA.BOOK_VOLUME_BY_NAME[normalizeBookName(book_part)]
        if not resolved then return nil end

        return {
            volume = resolved.volume,
            book = resolved.name,
            chapter = tonumber(chapter),
            verse = verse ~= "" and tonumber(verse) or nil,
        }
    end,
}
