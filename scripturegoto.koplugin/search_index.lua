-- Full-text word search across all five volumes, ported from the
-- "Scripture Search" CodePen (https://codepen.io/zvakanaka/pen/OJvZrXp):
-- an inverted index of every word to the verses containing it, where a
-- multi-word query matches verses containing *all* of its words.
--
-- The index is built once, from the same bcbooks/scriptures-json files
-- scripture_data.lua downloads for "Preview scripture" (all five volumes
-- must be cached first), and saved next to them, so later searches - even
-- across restarts - only have to read it back. It's rebuilt automatically
-- if those source files change or INDEX_VERSION is bumped.
--
-- On-disk format, both plain text so they can be searched without parsing
-- everything into Lua tables first:
--   search-verses.txt  one verse per line, in canonical order (line number
--                      = verse id): volume \t book \t chapter \t verse \t text
--   search-words.idx   "\n" word \t ids, sorted by word, where ids are the
--                      comma-separated, delta-encoded ids of every verse
--                      containing that word
--   search-meta.txt    INDEX_VERSION and the source files' sizes, to tell
--                      whether the index is current
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local ScriptureData = require("scripture_data")

local INDEX_VERSION = "1"

local SearchIndex = {}

-- Loaded on first search, kept for the session.
local words_blob -- the whole search-words.idx file
local verse_lines -- search-verses.txt, one string per verse id

local function path(name)
    return ScriptureData:getCacheDir() .. "/" .. name
end

-- Lowercased words of `text`, apostrophes dropped ("Lord's" -> "lords")
-- and any other non-letter splitting words ("came-to" -> "came", "to").
local function tokenize(text)
    local words = {}
    text = text:lower():gsub("'", ""):gsub("\226\128\153", "")
    for word in text:gmatch("%a+") do
        table.insert(words, word)
    end
    return words
end
SearchIndex.tokenize = tokenize

local function expectedMeta()
    local parts = { INDEX_VERSION }
    for _, volume in ipairs(ScriptureData.VOLUMES) do
        table.insert(parts, volume .. "=" .. tostring(lfs.attributes(ScriptureData:getCachePath(volume), "size")))
    end
    return table.concat(parts, "\n")
end

-- Volumes whose text isn't downloaded yet (needed before building).
function SearchIndex:missingVolumes()
    local missing = {}
    for _, volume in ipairs(ScriptureData.VOLUMES) do
        if not ScriptureData:isCached(volume) then
            table.insert(missing, volume)
        end
    end
    return missing
end

function SearchIndex:isBuilt()
    local f = io.open(path("search-meta.txt"), "rb")
    if not f then return false end
    local meta = f:read("*a")
    f:close()
    return meta == expectedMeta()
        and lfs.attributes(path("search-words.idx"), "mode") == "file"
        and lfs.attributes(path("search-verses.txt"), "mode") == "file"
end

local function writeFile(name, content)
    local tmp = path(name) .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    f:write(content)
    f:close()
    return os.rename(tmp, path(name))
end

-- Builds and saves the index from the downloaded volumes. Self-contained
-- (no UI), so it can run in a Trapper subprocess. Returns true, or nil
-- and an error message.
function SearchIndex:build()
    local verse_out = {}
    local postings = {} -- word -> { id, id, ... } ascending, no duplicates
    local id = 0
    for _, volume in ipairs(ScriptureData.VOLUMES) do
        local f = io.open(ScriptureData:getCachePath(volume), "rb")
        if not f then return nil, "missing text for " .. volume end
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(json.decode, content)
        if not ok or not data or not data.verses then
            return nil, "couldn't parse text for " .. volume
        end
        for _, entry in ipairs(data.verses) do
            local book, chapter, verse = entry.reference:match("^(.-)%s+(%d+):(%d+)$")
            if book then
                id = id + 1
                local text = entry.text:gsub("[\t\n]", " ")
                table.insert(verse_out, table.concat({
                    volume, ScriptureData:canonicalBookName(volume, book), chapter, verse, text,
                }, "\t"))
                for _, word in ipairs(tokenize(text)) do
                    local ids = postings[word]
                    if not ids then
                        postings[word] = { id }
                    elseif ids[#ids] ~= id then
                        table.insert(ids, id)
                    end
                end
            end
        end
    end

    local sorted_words = {}
    for word in pairs(postings) do table.insert(sorted_words, word) end
    table.sort(sorted_words)
    local idx_out = { "" } -- so the file starts with "\n" like every entry
    for _, word in ipairs(sorted_words) do
        local ids, deltas, prev = postings[word], {}, 0
        for i, v in ipairs(ids) do
            deltas[i] = v - prev
            prev = v
        end
        table.insert(idx_out, word .. "\t" .. table.concat(deltas, ","))
    end

    local ok, err = writeFile("search-verses.txt", table.concat(verse_out, "\n") .. "\n")
    if not ok then return nil, err end
    ok, err = writeFile("search-words.idx", table.concat(idx_out, "\n") .. "\n")
    if not ok then return nil, err end
    -- written last: its presence marks the index complete
    ok, err = writeFile("search-meta.txt", expectedMeta())
    if not ok then return nil, err end
    words_blob, verse_lines = nil, nil
    return true
end

local function load()
    if words_blob then return true end
    local f = io.open(path("search-words.idx"), "rb")
    if not f then return false end
    words_blob = f:read("*a")
    f:close()
    verse_lines = {}
    for line in io.lines(path("search-verses.txt")) do
        table.insert(verse_lines, line)
    end
    return true
end

-- Ascending verse ids containing `word`, or nil if none.
local function lookup(word)
    local s, e = words_blob:find("\n" .. word .. "\t", 1, true)
    if not s then return nil end
    local line_end = words_blob:find("\n", e + 1, true) or (#words_blob + 1)
    local ids, prev = {}, 0
    for delta in words_blob:sub(e + 1, line_end - 1):gmatch("%d+") do
        prev = prev + tonumber(delta)
        table.insert(ids, prev)
    end
    return ids
end

-- Ids present in both ascending lists.
local function intersect(a, b)
    local out, i, j = {}, 1, 1
    while i <= #a and j <= #b do
        if a[i] == b[j] then
            table.insert(out, a[i]); i = i + 1; j = j + 1
        elseif a[i] < b[j] then
            i = i + 1
        else
            j = j + 1
        end
    end
    return out
end

local function verseById(id)
    local volume, book, chapter, verse, text = verse_lines[id]:match("^(.-)\t(.-)\t(%d+)\t(%d+)\t(.*)$")
    return {
        volume = volume,
        book = book,
        chapter = tonumber(chapter),
        verse = tonumber(verse),
        verses = { tonumber(verse) },
        text = text,
    }
end

-- Returns { total = N, words = {query words}, results = {first
-- max_results verses, canonical order} }, or nil and an error if the
-- index isn't built.
function SearchIndex:search(query, max_results)
    if not load() then return nil, "not_built" end
    local words = tokenize(query)
    local ids
    for _, word in ipairs(words) do
        local word_ids = lookup(word)
        if not word_ids then
            ids = {}
            break
        end
        ids = ids and intersect(ids, word_ids) or word_ids
    end
    ids = ids or {}

    local results = {}
    for i = 1, math.min(#ids, max_results or #ids) do
        table.insert(results, verseById(ids[i]))
    end
    return { total = #ids, words = words, results = results }
end

return SearchIndex
