-- Provider for churchofjesuschrist.org scripture study links, of the form
-- https://www.churchofjesuschrist.org/study/scriptures/<volume>/<book>/<chapter>?id=p<verse>
-- The chapter path segment can also carry a chapter range for a
-- multi-chapter citation, e.g. ".../ot/eccl/1-2"; the "id=" param can
-- similarly carry a verse range or list for a multi-verse selection, e.g.
-- "id=p5-p7" or "id=p5,p7".
local BOOK_DATA = require("book_data")
local VerseList = require("providers.verse_list")

return {
    id = "lds",
    name = "ChurchofJesusChrist.org",

    parse = function(url)
        if not url:find("churchofjesuschrist%.org") then return nil end
        local volume, book_slug, chapter, end_chapter =
            url:match("/study/scriptures/([%w%-]+)/([%w%-]+)/(%d+)%-(%d+)")
        if not volume then
            volume, book_slug, chapter = url:match("/study/scriptures/([%w%-]+)/([%w%-]+)/(%d+)")
        end
        if not volume then return nil end

        local verses
        local id_spec = url:match("[?&]id=([%w%-,]+)")
        if id_spec then
            verses = VerseList.expand((id_spec:gsub("p", "")))
        else
            local frag_verse = url:match("#p(%d+)")
            if frag_verse then verses = { tonumber(frag_verse) } end
        end

        local chapters
        if end_chapter and not verses then
            chapters = {}
            for c = tonumber(chapter), tonumber(end_chapter) do table.insert(chapters, c) end
        end

        return {
            volume = volume,
            book = (BOOK_DATA[volume] or {})[book_slug] or book_slug,
            chapter = tonumber(chapter),
            verse = verses and verses[1] or nil,
            verses = verses,
            chapters = chapters,
        }
    end,
}
