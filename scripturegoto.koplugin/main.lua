--[[--
Scripture Goto

Adds a "Go to scripture" button to the stock external-link dialog (the one
that also offers Copy/QR code/Open in browser) whenever a tapped link -
from *any* open book - matches a supported scripture site (see providers/),
and a second "Go to scripture" button to the text-selection/highlight menu
when the selected text itself looks like a plain-text scripture reference
(e.g. "Alma 40:11-14"), jumping either way to the matching chapter/verse in
a locally configured EPUB for that volume of scripture.

Also adds a "Preview scripture" button next to each of those, which shows
the verse text (downloaded on first use from bcbooks/scriptures-json, see
scripture_data.lua) in a floating window instead of jumping to it - no
EPUB needs to be configured for that to work.

@module koplugin.ScriptureGoto
]]--

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local Size = require("ui/size")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local Screen = Device.screen

-- Downloads/caches the bcbooks/scriptures-json flat text files and looks
-- up verse text from them for the "Preview scripture" floating window -
-- independent of the per-volume EPUBs the "Go to scripture" jump uses.
local ScriptureData = require("scripture_data")

-- Each provider recognizes one site's scripture-link URL format and, if it
-- matches, resolves it to a {volume, book, chapter, verse} table. `volume`
-- is just a key into the per-volume EPUB settings (see get/setVolumeEpubSetting
-- below) - providers that don't distinguish LDS-style volumes (Bible Gateway,
-- YouVersion) still resolve to "ot"/"nt" so they share EPUBs configured for
-- those volumes. Add a new site by dropping a module in providers/ and
-- listing it here.
local PROVIDERS = {
    require("providers.lds"),
    require("providers.biblegateway"),
    require("providers.youversion"),
}

-- Recognizes a plain-text scripture reference (not a hyperlink) inside
-- selected/highlighted text, e.g. "Alma 40:11-14" or "Isa. 24:21, 22".
local ReferenceText = require("providers.reference_text")

-- Try each provider in turn and return the first match, tagged with which
-- provider recognized it.
local function parseScriptureUrl(url)
    for _, provider in ipairs(PROVIDERS) do
        local parsed = provider.parse(url)
        if parsed then
            parsed.provider = provider.id
            return parsed
        end
    end
    return nil
end

-- True if `parsed` (from either a URL provider or reference_text) resolves
-- to something "Preview scripture" can show: a specific verse or verse
-- range/list, or (with no verse at all) a whole chapter or chapter range.
-- Every provider always resolves at least a chapter, so this is really
-- just "parsed ~= nil" - spelled out for clarity/documentation.
local function canPreview(parsed)
    return parsed ~= nil and parsed.chapter ~= nil
end

local ScriptureGoto = WidgetContainer:extend{
    name = "scripturegoto",
    is_doc_only = false,
}

function ScriptureGoto:onDispatcherRegisterActions()
    Dispatcher:registerAction("scripturegoto_test_link", {
        category = "none", event = "ScriptureGotoTestLink", title = _("Scripture Goto: open test link"), general = true,
    })
end

function ScriptureGoto:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:addExternalLinkDialogButton()
    self:addHighlightDialogButton()
    self:addExternalLinkPreviewButton()
    self:addHighlightPreviewButton()

    -- Dev-only hook for tools/demo-gifs (see its README): completely inert
    -- unless SCRIPTUREGOTO_DEMO_HOOK is set (by that tool) to a Lua file
    -- path, which is then run with this plugin instance as an argument.
    -- Never set by the plugin itself, so this is a no-op for real users.
    local demo_hook_path = os.getenv("SCRIPTUREGOTO_DEMO_HOOK")
    if demo_hook_path then
        local chunk, load_err = loadfile(demo_hook_path)
        if chunk then
            local ok, err = pcall(chunk, self)
            if not ok then
                logger.warn("ScriptureGoto: demo hook errored:", err)
            end
        else
            logger.warn("ScriptureGoto: demo hook failed to load:", load_err)
        end
    end
end

-- Add a "Go to scripture" button to ReaderLink's external-link dialog (the
-- one that also offers Copy/QR code/Open in browser/etc.), shown only when
-- the tapped link matches a supported scripture site. This leaves those
-- other options available instead of us fully taking over the link.
function ScriptureGoto:addExternalLinkDialogButton()
    self.ui.link:addToExternalLinkDialog("15_scripturegoto", function(this, link_url)
        return {
            text = _("Go to scripture"),
            callback = function()
                UIManager:close(this.external_link_dialog)
                local parsed = parseScriptureUrl(link_url)
                if parsed then
                    ScriptureGoto:handleScriptureLink(this.ui, parsed)
                end
            end,
            show_in_dialog_func = function()
                return parseScriptureUrl(link_url) ~= nil
            end,
        }
    end)
end

-- Add a "Go to scripture" button to ReaderHighlight's selection/highlight
-- dialog (the one that also offers Copy/Highlight/Dictionary/etc.), shown
-- only when the selected text itself looks like a plain-text scripture
-- reference rather than a tappable link.
function ScriptureGoto:addHighlightDialogButton()
    self.ui.highlight:addToHighlightDialog("13_scripturegoto", function(this)
        return {
            text = _("Go to scripture"),
            callback = function()
                local parsed = ReferenceText.parse(this.selected_text.text)
                this:onClose()
                if parsed then
                    ScriptureGoto:handleScriptureLink(this.ui, parsed)
                end
            end,
            show_in_highlight_dialog_func = function()
                return this.selected_text and this.selected_text.text
                    and ReferenceText.parse(this.selected_text.text) ~= nil
            end,
        }
    end)
end

-- Add a "Preview scripture" button to ReaderLink's external-link dialog,
-- shown under the same condition as "Go to scripture", that shows the
-- verse text in a floating window instead of jumping to it in an EPUB -
-- no EPUB needs to be configured for the volume for this to work.
function ScriptureGoto:addExternalLinkPreviewButton()
    self.ui.link:addToExternalLinkDialog("16_scripturegoto_preview", function(this, link_url)
        return {
            text = _("Preview scripture"),
            callback = function()
                UIManager:close(this.external_link_dialog)
                local parsed = parseScriptureUrl(link_url)
                if parsed then
                    ScriptureGoto:showScripturePreview(parsed)
                end
            end,
            show_in_dialog_func = function()
                local parsed = parseScriptureUrl(link_url)
                return canPreview(parsed)
            end,
        }
    end)
end

-- Same as above, but for ReaderHighlight's selection/highlight dialog.
function ScriptureGoto:addHighlightPreviewButton()
    self.ui.highlight:addToHighlightDialog("14_scripturegoto_preview", function(this)
        return {
            text = _("Preview scripture"),
            callback = function()
                local parsed = ReferenceText.parse(this.selected_text.text)
                -- Keep the highlight (and this.selected_text, needed for
                -- anchor positioning) instead of clearing it, same as the
                -- stock Dictionary/Translate buttons do.
                this:onClose(true)
                if parsed then
                    ScriptureGoto:showScripturePreview(parsed, this)
                end
            end,
            show_in_highlight_dialog_func = function()
                local parsed = this.selected_text and this.selected_text.text
                    and ReferenceText.parse(this.selected_text.text)
                return canPreview(parsed)
            end,
        }
    end)
end

-- Collapses a sorted list of numbers (verses or chapters) into range/list
-- notation, e.g. {11,12,13,14} -> "11-14", {12,13,14,16,17} -> "12-14,16-17".
local function formatRangeLabel(numbers)
    local parts = {}
    local i = 1
    while i <= #numbers do
        local run_start, run_end = numbers[i], numbers[i]
        while numbers[i + 1] == run_end + 1 do
            i = i + 1
            run_end = numbers[i]
        end
        table.insert(parts, run_end > run_start and (run_start .. "-" .. run_end) or tostring(run_start))
        i = i + 1
    end
    return table.concat(parts, ",")
end

-- Computes an anchor rect near the current text selection's on-screen
-- position, so the preview window can pop up right next to it instead of
-- centered - independent of the user's own "highlight_dialog_position"
-- setting, which governs a *different* dialog (ReaderHighlight's own
-- action menu) and is usually left at "center". Returns nil (falls back
-- to centered) if there's no usable selection box, e.g. when called from
-- the link-tap dialog rather than a text selection.
local function getSelectionAnchor(highlight, dialog)
    local selected_text = highlight and highlight.selected_text
    local boxes = selected_text and (selected_text.sboxes or selected_text.pboxes)
    if not boxes or #boxes == 0 then return nil end

    local box0, box1 = boxes[1], boxes[#boxes]
    if box0.y > box1.y then box0, box1 = box1, box0 end
    if highlight.ui.paging then
        local page = selected_text.pos0 and selected_text.pos0.page
        box0 = highlight.view:pageToScreenTransform(page, box0)
        box1 = highlight.view:pageToScreenTransform(page, box1)
        if not (box0 and box1) then return nil end
    end

    local padding = Size.padding.small
    local y0, y1 = box0.y, box1.y + box1.h
    local content_h = dialog:getContentSize().h + 2 * padding
    local screen_h = Screen:getHeight()
    if y1 + content_h <= screen_h then
        return { y = y1 + padding }, true -- pop down
    elseif content_h <= y0 then
        return { y = y0 - padding } -- pop up
    end
    return nil
end

-- Shows the resolved reference's text - every verse in its range or list,
-- or (for a reference with no verse at all) every verse of every chapter
-- in its chapter range - in a scrollable floating window (TextViewer,
-- movable/draggable), downloading and caching that volume's text data
-- first if needed. When called from a text selection (`highlight` is the
-- ReaderHighlight instance), the window is sized down and popped up right
-- next to the selection instead of centered/near-fullscreen.
function ScriptureGoto:showScripturePreview(parsed, highlight)
    -- `verses` covers a full range/list (from reference_text.lua); URL
    -- providers only ever resolve a single verse. With no verse at all,
    -- `chapters` (also only ever set by reference_text.lua; URL providers
    -- always resolve a single chapter) covers a whole chapter or chapter
    -- range instead - URL providers still get a single-chapter preview via
    -- the {parsed.chapter} fallback.
    local verses = parsed.verses or (parsed.verse and { parsed.verse } or nil)
    local chapters = not verses and (parsed.chapters or { parsed.chapter }) or nil

    local function displayText()
        local text, err, label
        if verses then
            text, err = ScriptureData:getVerseText(parsed.volume, parsed.book, parsed.chapter, verses)
            label = parsed.chapter .. ":" .. formatRangeLabel(verses)
        else
            text, err = ScriptureData:getChapterText(parsed.volume, parsed.book, chapters)
            label = formatRangeLabel(chapters)
        end
        if not text then
            UIManager:show(InfoMessage:new{
                text = T(_("Couldn't find %1 %2 in the downloaded scripture text (%3)."),
                    parsed.book, label, tostring(err)),
            })
            return
        end

        local textviewer
        textviewer = TextViewer:new{
            title = T("%1 %2", parsed.book, label),
            text = text,
            width = highlight and math.floor(Screen:getWidth() * 0.9) or nil,
            height = highlight and math.floor(Screen:getHeight() * 0.4) or nil,
            anchor = highlight and function() return getSelectionAnchor(highlight, textviewer) end or nil,
        }
        UIManager:show(textviewer)
    end

    if ScriptureData:isCached(parsed.volume) then
        displayText()
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Scripture text for \"%1\" hasn't been downloaded yet. Download it now? (one-time download, a few MB)"), parsed.volume),
        ok_text = _("Download"),
        ok_callback = function()
            local msg = InfoMessage:new{ text = _("Downloading scripture text…") }
            UIManager:show(msg)
            UIManager:scheduleIn(0.1, function()
                ScriptureData:download(parsed.volume, function(ok, err)
                    UIManager:close(msg)
                    if ok then
                        displayText()
                    else
                        UIManager:show(InfoMessage:new{
                            text = T(_("Download failed: %1"), tostring(err)),
                        })
                    end
                end)
            end)
        end,
    })
end

function ScriptureGoto:getVolumeEpubSetting(volume)
    local settings = G_reader_settings:readSetting("scripturegoto_volume_epubs") or {}
    return settings[volume]
end

function ScriptureGoto:setVolumeEpubSetting(volume, path)
    local settings = G_reader_settings:readSetting("scripturegoto_volume_epubs") or {}
    settings[volume] = path
    G_reader_settings:saveSetting("scripturegoto_volume_epubs", settings)
end

-- Best-effort regex (crengine/srell flavour) used to *locate candidate*
-- verse markers once we've landed on the chapter: matches the verse number
-- bracketed by non-digits on both sides, so "7" doesn't also match "17",
-- "27", etc. NOTE: crengine's regex search does *not* anchor "^" to each
-- paragraph/line - only to the very start of the whole search buffer, and
-- paragraphs are concatenated with no separator in its search text - so a
-- search alone can't tell "7 So it was..." (an actual verse 7) apart from
-- "...as told in chapter 7, verse 1..." (verse 1 merely mentioning chapter
-- 7). Each candidate hit is therefore re-checked in Lua against its own
-- paragraph's full text (see the `validate` field below and its use in
-- jumpToChapterVerse) before being accepted. Tune this per-EPUB if your
-- Bible marks verses differently (e.g. with a leading pilcrow or
-- superscript).
-- Leading boundary uses a zero-width lookbehind rather than a consuming
-- "[^0-9]" character class: crengine's regex engine has been observed to
-- never match when a consuming character class is the very first token in
-- the pattern (empirically confirmed - even a literal leading space before
-- a known-present "16" failed to match), while the same class works fine
-- as a trailing token, and a leading lookbehind assertion works fine too.
local DEFAULT_VERSE_PATTERN = "(?<![0-9])%d+[^0-9]"

function ScriptureGoto:getVersePattern()
    return G_reader_settings:readSetting("scripturegoto_verse_pattern") or DEFAULT_VERSE_PATTERN
end

-- Candidate verse-marker searches to try in order, most specific first.
-- Each has a crengine search pattern used to gather candidate hit
-- positions, and (for the patterns we control the exact format of) a Lua
-- `validate(node_text)` function that checks the *candidate's own
-- paragraph text* genuinely starts with that marker, to reject hits that
-- are just a chapter/verse number mentioned in another verse's prose. A
-- user-overridden `scripturegoto_verse_pattern` is trusted as-is (no
-- validate), since we can't know its exact expected format.
--
-- The chapter:verse form (e.g. "32:21 Yea, for ...") is always tried as a
-- fallback alongside the bare-verse-number form, since some editions (e.g.
-- the Project Gutenberg Book of Mormon) mark verses that way.
function ScriptureGoto:getVersePatternCandidates(chapter, verse)
    local candidates = {}
    local custom_pattern = G_reader_settings:readSetting("scripturegoto_verse_pattern")
    if custom_pattern then
        table.insert(candidates, { search = custom_pattern:gsub("%%d%+", tostring(verse)) })
    else
        table.insert(candidates, {
            search = "(?<![0-9])" .. verse .. "[^0-9]",
            validate = function(node_text)
                return node_text:match("^%s*" .. verse .. "%f[%D]") ~= nil
            end,
        })
    end
    table.insert(candidates, {
        search = "(?<![0-9])" .. chapter .. ":" .. verse .. "[^0-9]",
        validate = function(node_text)
            return node_text:match("^%s*" .. chapter .. ":" .. verse .. "%f[%D]") ~= nil
        end,
    })
    return candidates
end

function ScriptureGoto:handleScriptureLink(ui, parsed)
    local epub_path = self:getVolumeEpubSetting(parsed.volume)
    if not epub_path or lfs.attributes(epub_path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = T(_("No EPUB configured for scripture volume \"%1\".\nSet one in the Scripture Goto menu (More tools)."), parsed.volume),
        })
        return true
    end

    local book_name = parsed.book

    local function navigate(target_ui)
        UIManager:scheduleIn(0.1, function()
            ScriptureGoto:jumpToChapterVerse(target_ui, book_name, parsed.chapter, parsed.verse)
        end)
    end

    if ui.document and ui.document.file == epub_path then
        navigate(ui)
    else
        ui.link:addCurrentLocationToStack()
        ui:switchDocument(epub_path, nil, navigate)
    end
    return true
end

-- Find the TOC entry whose title contains both the book name and the
-- chapter number as a standalone number (so chapter 7 doesn't match "17").
function ScriptureGoto:findChapterTocEntry(ui, book_name, chapter)
    ui.toc:fillToc()
    local toc = ui.toc.toc
    if not toc then return nil, nil end

    local book_pat = book_name:gsub("%W", function(c) return "%" .. c end)
    local chapter_pat = "%f[%d]" .. chapter .. "%f[%D]"
    for i, entry in ipairs(toc) do
        if entry.title and entry.title:find(book_pat) and entry.title:find(chapter_pat) then
            return entry, toc[i + 1]
        end
    end
    return nil, nil
end

-- Some editions' TOC nests a second entry under each book whose "title" is
-- actually a chapter-number picker widget's text, e.g. "2 3 4 5 ... 31"
-- (all remaining chapter numbers concatenated, one per link) - not a real
-- next-book heading. Using that as the "next entry" boundary would wrongly
-- restrict the whole-book search to just its first chapter or two, since
-- that entry sits right after the book's own heading, before any verse
-- text at all. Recognized by a title that's nothing but digits/whitespace.
local function looksLikeChapterNumberList(title)
    return title:match("^%s*%d+[%s%d]*$") ~= nil
end

-- Find the TOC entry whose title merely contains the book name, ignoring
-- chapter - for editions (e.g. some Gutenberg Bible EPUBs) whose TOC only
-- lists one entry per *book*, with no per-chapter heading at all; chapters
-- there are distinguishable only by a "chapter:verse" marker in the
-- running text. See findChapterStartXPointer below for how we locate a
-- chapter within such a book.
function ScriptureGoto:findBookTocEntry(ui, book_name)
    ui.toc:fillToc()
    local toc = ui.toc.toc
    if not toc then return nil, nil end

    local book_pat = book_name:gsub("%W", function(c) return "%" .. c end)
    for i, entry in ipairs(toc) do
        if entry.title and entry.title:find(book_pat) then
            local j = i + 1
            while toc[j] and toc[j].title and looksLikeChapterNumberList(toc[j].title) do
                j = j + 1
            end
            return entry, toc[j]
        end
    end
    return nil, nil
end

-- Locates a chapter's start, within a book that has no chapter-level TOC
-- entry, by searching forward (from wherever the document currently is -
-- the book's own TOC entry, in practice) for that chapter's "chapter:1"
-- marker, validated the same way verse candidates are (see
-- getVersePatternCandidates) to reject false positives such as a
-- cross-reference mentioning that chapter elsewhere. `upper_bound_entry`
-- (typically the *next book's* TOC entry) keeps the search from wandering
-- past the end of the book entirely; it does not need to be chapter-tight,
-- since the chapter number in the pattern itself already disambiguates.
-- NOTE: deliberately does NOT fall back to an unbounded search if the
-- bounded one finds nothing. An earlier version did, on the theory that a
-- stale/wrong upper_bound_entry might be the obstacle - but that risks
-- silently landing in a same-numbered chapter of a *different* book
-- (confirmed: reproduced this exact failure while testing), which is a
-- worse outcome than a clear "couldn't find" error, since a reader might
-- not immediately notice they're in the wrong book.
function ScriptureGoto:findChapterStartXPointer(ui, chapter, upper_bound_entry)
    local pattern = "(?<![0-9])" .. chapter .. ":1[^0-9]"
    local ok, results = pcall(function()
        return ui.document:findText(pattern, 0, 0, false, ui.view.state.page, true, 20, 0)
    end)
    if not ok or not results then return nil end

    for _, hit in ipairs(results) do
        if hit.start then
            if upper_bound_entry and ui.document:compareXPointers(hit.start, upper_bound_entry.xpointer) <= 0 then
                break
            end
            local ok2, node_text = pcall(function() return ui.document:getTextFromXPointer(hit.start) end)
            if ok2 and node_text and node_text:match("^%s*" .. chapter .. ":1%f[%D]") then
                return hit.start
            end
        end
    end
    return nil
end

-- Best-effort verse search: look for the verse marker forward from wherever
-- the document currently is (the chapter's start, in practice), but don't
-- wander past next_entry (the next chapter, or - when falling back to a
-- book-level TOC entry - the next book). Tries each candidate search in
-- turn, checking every candidate hit position (there can be several false
-- positives before the real one) until one both stays in range and
-- validates as a genuine verse start.
function ScriptureGoto:searchAndJumpToVerse(ui, chapter, verse, next_entry)
    for _, candidate in ipairs(self:getVersePatternCandidates(chapter, verse)) do
        local ok, results = pcall(function()
            -- direction 0 = forward, 1 = backward (see readersearch.lua) -
            -- do NOT pass 1 here expecting "forward", that searches
            -- backward from the chapter start and never finds anything.
            return ui.document:findText(candidate.search, 0, 0, false, ui.view.state.page, true, 20, 0)
        end)
        if ok and results then
            for _, hit in ipairs(results) do
                if hit.start then
                    if next_entry and ui.document:compareXPointers(hit.start, next_entry.xpointer) <= 0 then
                        -- landed past the next chapter/book start; hits are in
                        -- document order, so later ones are only further out
                        -- of range - stop trying this candidate
                        break
                    end
                    local valid = true
                    if candidate.validate then
                        local ok2, node_text = pcall(function()
                            return ui.document:getTextFromXPointer(hit.start)
                        end)
                        valid = ok2 and node_text and candidate.validate(node_text)
                    end
                    if valid then
                        ui.rolling:onGotoXPointer(hit.start, hit.start)
                        return
                    end
                end
            end
        end
        logger.dbg("ScriptureGoto: verse search found nothing for", candidate.search)
    end
end

function ScriptureGoto:jumpToChapterVerse(ui, book_name, chapter, verse)
    if not (ui.rolling and ui.toc) then
        UIManager:show(InfoMessage:new{ text = _("Scripture Goto: target document isn't a reflowable EPUB.") })
        return
    end

    local entry, next_entry = self:findChapterTocEntry(ui, book_name, chapter)
    if entry then
        ui:handleEvent(Event:new("GotoXPointer", entry.xpointer))
        if not verse then return end
        UIManager:scheduleIn(0.2, function()
            self:searchAndJumpToVerse(ui, chapter, verse, next_entry)
        end)
        return
    end

    -- No per-chapter TOC entry found; fall back to a book-level entry and
    -- locate the chapter within it via its "chapter:1" marker.
    local book_entry, book_next_entry = self:findBookTocEntry(ui, book_name)
    if not book_entry then
        UIManager:show(InfoMessage:new{
            text = T(_("Scripture Goto: couldn't find \"%1\" in this book's table of contents."), book_name),
        })
        return
    end

    ui:handleEvent(Event:new("GotoXPointer", book_entry.xpointer))

    if chapter == 1 then
        if not verse then return end
        UIManager:scheduleIn(0.2, function()
            self:searchAndJumpToVerse(ui, chapter, verse, book_next_entry)
        end)
        return
    end

    UIManager:scheduleIn(0.2, function()
        local chapter_xp = self:findChapterStartXPointer(ui, chapter, book_next_entry)
        if not chapter_xp then
            UIManager:show(InfoMessage:new{
                text = T(_("Scripture Goto: couldn't find chapter %1 of \"%2\" in the text."), chapter, book_name),
            })
            return
        end
        ui.rolling:onGotoXPointer(chapter_xp, chapter_xp)
        if not verse then return end
        UIManager:scheduleIn(0.2, function()
            self:searchAndJumpToVerse(ui, chapter, verse, book_next_entry)
        end)
    end)
end

function ScriptureGoto:onScriptureGotoTestLink()
    local dialog
    dialog = InputDialog:new{
        title = _("Open scripture link"),
        description = _("Paste a scripture URL (ChurchofJesusChrist.org, Bible Gateway, or YouVersion/Bible.com) to test navigation."),
        input = "https://www.churchofjesuschrist.org/study/scriptures/nt/matt/7?lang=eng&id=p7#p7",
        input_type = "text",
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Go"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText()
                    UIManager:close(dialog)
                    local parsed = parseScriptureUrl(url)
                    if not parsed then
                        UIManager:show(InfoMessage:new{ text = _("Not a recognized scripture URL.") })
                        return
                    end
                    self:handleScriptureLink(self.ui, parsed)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ScriptureGoto:onShowAbout()
    UIManager:show(TextViewer:new{
        title = _("About Scripture Goto"),
        text = _([[Scripture Goto adds "Go to scripture" and "Preview scripture" buttons to the link-tap and text-selection menus for supported scripture references.

"Go to scripture" jumps to the matching chapter/verse in a scripture EPUB you configure per volume.

"Preview scripture" shows the verse text in a floating window without needing an EPUB. That text comes from the bcbooks/scriptures-json project (LDS scriptures in JSON):

https://github.com/bcbooks/scriptures-json

downloaded on first use and cached locally. Many thanks to that project for making this text freely available.]]),
    })
end

function ScriptureGoto:addToMainMenu(menu_items)
    local sub_item_table = {}
    for _i, volume in ipairs{ "ot", "nt", "bofm", "dc-testament", "pgp" } do
        table.insert(sub_item_table, {
            text_func = function()
                local path = self:getVolumeEpubSetting(volume)
                return T(_("Set EPUB for \"%1\": %2"), volume, path and ffiUtil.basename(path) or _("(none)"))
            end,
            callback = function()
                UIManager:show(PathChooser:new{
                    select_directory = false,
                    select_file = true,
                    path = self:getVolumeEpubSetting(volume) or G_reader_settings:readSetting("home_dir"),
                    onConfirm = function(new_path)
                        self:setVolumeEpubSetting(volume, new_path)
                    end,
                })
            end,
        })
    end
    table.insert(sub_item_table, {
        text = _("Open test link…"),
        callback = function() self:onScriptureGotoTestLink() end,
    })
    table.insert(sub_item_table, {
        text = _("About Scripture Goto…"),
        callback = function() self:onShowAbout() end,
    })

    menu_items.scripturegoto = {
        text = _("Scripture Goto"),
        sorting_hint = "more_tools",
        sub_item_table = sub_item_table,
    }
end

return ScriptureGoto
