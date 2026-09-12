-- Provider for bible.com / YouVersion passage links, of the form
-- https://www.bible.com/bible/111/jhn.3.16
local BOOK_DATA = require("book_data")
local USFM_BOOKS = require("providers.usfm_book_data")

return {
    id = "youversion",
    name = "YouVersion / Bible.com",

    parse = function(url)
        if not url:find("bible%.com") then return nil end
        local usfm, chapter, verse = url:match("/bible/%d+/(%w%w%w)%.(%d+)%.?(%d*)")
        if not usfm then return nil end

        local book_name = USFM_BOOKS[usfm:lower()]
        if not book_name then return nil end
        local resolved = BOOK_DATA.BOOK_VOLUME_BY_NAME[book_name:lower()]
        if not resolved then return nil end

        return {
            volume = resolved.volume,
            book = resolved.name,
            chapter = tonumber(chapter),
            verse = verse ~= "" and tonumber(verse) or nil,
        }
    end,
}
