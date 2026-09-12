-- Downloads and caches the flat scripture-text JSON files from
-- https://github.com/bcbooks/scriptures-json (one per volume: OT, NT,
-- Book of Mormon, D&C, Pearl of Great Price), and looks up verse text
-- from them for the "preview scripture" floating-window feature. This is
-- independent of the per-volume EPUBs used by the "Go to scripture" jump
-- feature - no EPUB needs to be configured for a volume to preview text
-- from it.
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socketutil = require("socketutil")

local CACHE_DIR = DataStorage:getDataDir() .. "/scripturegoto"

-- Each volume's flat-JSON filename on GitHub, and (where it differs from
-- our own book_data.lua canonical names) a mapping from our canonical book
-- name to the book-name prefix this dataset's "reference" strings use.
local VOLUME_INFO = {
    ot = {
        file = "old-testament-flat.json",
        book_name_overrides = { ["Song of Solomon"] = "Solomon's Song" },
    },
    nt = {
        file = "new-testament-flat.json",
    },
    bofm = {
        file = "book-of-mormon-flat.json",
    },
    ["dc-testament"] = {
        file = "doctrine-and-covenants-flat.json",
        book_name_overrides = { ["Doctrine and Covenants"] = "D&C" },
        -- This dataset only covers D&C sections, not Official Declarations.
    },
    pgp = {
        file = "pearl-of-great-price-flat.json",
        book_name_overrides = {
            ["Joseph Smith-Matthew"] = "Joseph Smith\226\128\148Matthew", -- em dash
            ["Joseph Smith-History"] = "Joseph Smith\226\128\148History", -- em dash
        },
    },
}

local BASE_URL = "https://raw.githubusercontent.com/bcbooks/scriptures-json/master/flat/"

-- In-memory verse index, built lazily per volume on first lookup:
-- loaded_indexes[volume] = { ["book|chapter|verse"] = "verse text", ... }
local loaded_indexes = {}

-- Companion index, built alongside loaded_indexes, listing each chapter's
-- verse numbers in the order they appear in the source data:
-- loaded_chapter_verses[volume] = { ["book|chapter"] = {1, 2, 3, ...}, ... }
local loaded_chapter_verses = {}

local ScriptureData = {}

function ScriptureData:getCachePath(volume)
    local info = VOLUME_INFO[volume]
    if not info then return nil end
    return CACHE_DIR .. "/" .. info.file
end

function ScriptureData:isCached(volume)
    local path = self:getCachePath(volume)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

-- Downloads the given volume's flat JSON file (requires network access,
-- prompting for Wi-Fi if needed) and calls on_done(ok, err_message).
function ScriptureData:download(volume, on_done)
    local info = VOLUME_INFO[volume]
    if not info then
        on_done(false, "Unknown volume: " .. tostring(volume))
        return
    end

    NetworkMgr:runWhenOnline(function()
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local socket = require("socket")

        local ok_mkdir = lfs.attributes(CACHE_DIR, "mode") == "directory" or lfs.mkdir(CACHE_DIR)
        if not ok_mkdir then
            on_done(false, "Could not create cache directory")
            return
        end

        local path = self:getCachePath(volume)
        local tmp_path = path .. ".tmp"
        local out_file, open_err = io.open(tmp_path, "wb")
        if not out_file then
            on_done(false, "Could not write cache file: " .. tostring(open_err))
            return
        end

        socketutil:set_timeout(15, 120)
        local code, _, status = socket.skip(1, http.request{
            url = BASE_URL .. info.file,
            method = "GET",
            sink = ltn12.sink.file(out_file),
        })
        socketutil:reset_timeout()

        if code == 200 then
            local ok_rename = os.rename(tmp_path, path)
            if ok_rename then
                on_done(true)
            else
                on_done(false, "Downloaded but could not save cache file")
            end
        else
            os.remove(tmp_path)
            logger.warn("ScriptureData: download failed for", volume, "code", code, "status", status)
            on_done(false, tostring(status or code or "request failed"))
        end
    end)
end

-- Lazily parses a cached volume's JSON into an in-memory verse index.
-- Returns true on success, false (and logs) if the cache file is missing
-- or malformed.
function ScriptureData:ensureIndex(volume)
    if loaded_indexes[volume] then return true end

    local path = self:getCachePath(volume)
    if not path or lfs.attributes(path, "mode") ~= "file" then
        return false
    end

    local f = io.open(path, "rb")
    if not f then return false end
    local content = f:read("*a")
    f:close()

    local ok, data = pcall(json.decode, content)
    if not ok or not data or not data.verses then
        logger.warn("ScriptureData: failed to parse cached JSON for", volume)
        return false
    end

    local index = {}
    local chapter_verses = {}
    for _, entry in ipairs(data.verses) do
        -- reference looks like "1 Nephi 1:1" or "D&C 88:103"
        local book, chapter, verse = entry.reference:match("^(.-)%s+(%d+):(%d+)$")
        if book then
            index[book .. "|" .. chapter .. "|" .. verse] = entry.text
            local chapter_key = book .. "|" .. chapter
            local verses = chapter_verses[chapter_key]
            if not verses then
                verses = {}
                chapter_verses[chapter_key] = verses
            end
            table.insert(verses, tonumber(verse))
        end
    end
    loaded_indexes[volume] = index
    loaded_chapter_verses[volume] = chapter_verses
    return true
end

-- Returns (text, nil) for the given book/chapter and every verse number in
-- `verses` (a plain array, e.g. {11,12,13,14} for a range or {21,22} for a
-- list - order and gaps are respected as given), each line prefixed with
-- its full "Book Chapter:Verse" reference, or (nil, err) if the volume
-- isn't cached yet or none of the requested verses are found in this
-- dataset.
function ScriptureData:getVerseText(volume, book, chapter, verses)
    if not self:isCached(volume) then
        return nil, "not_cached"
    end
    if not self:ensureIndex(volume) then
        return nil, "parse_failed"
    end

    local info = VOLUME_INFO[volume] or {}
    local lookup_book = (info.book_name_overrides and info.book_name_overrides[book]) or book
    local index = loaded_indexes[volume]

    local parts = {}
    for _, v in ipairs(verses) do
        local text = index[lookup_book .. "|" .. chapter .. "|" .. v]
        if text then
            table.insert(parts, book .. " " .. chapter .. ":" .. v .. " " .. text)
        end
    end

    if #parts == 0 then
        return nil, "verse_not_found"
    end
    return table.concat(parts, "\n\n")
end

-- Returns (text, nil) for every verse of every chapter number in `chapters`
-- (a plain array, e.g. {3} or {3,4} for a chapter range), each line
-- prefixed with its full "Book Chapter:Verse" reference, or (nil, err) as
-- with getVerseText.
function ScriptureData:getChapterText(volume, book, chapters)
    if not self:isCached(volume) then
        return nil, "not_cached"
    end
    if not self:ensureIndex(volume) then
        return nil, "parse_failed"
    end

    local info = VOLUME_INFO[volume] or {}
    local lookup_book = (info.book_name_overrides and info.book_name_overrides[book]) or book
    local index = loaded_indexes[volume]
    local chapter_verses = loaded_chapter_verses[volume]

    local parts = {}
    for _, chapter in ipairs(chapters) do
        local verses = chapter_verses[lookup_book .. "|" .. chapter]
        if verses then
            for _, v in ipairs(verses) do
                local text = index[lookup_book .. "|" .. chapter .. "|" .. v]
                if text then
                    table.insert(parts, book .. " " .. chapter .. ":" .. v .. " " .. text)
                end
            end
        end
    end

    if #parts == 0 then
        return nil, "chapter_not_found"
    end
    return table.concat(parts, "\n\n")
end

return ScriptureData
