-- Dev-only hook loaded by scripturegoto.koplugin/main.lua when
-- SCRIPTUREGOTO_DEMO_HOOK points at this file (see tools/demo-gifs/README.md).
-- Drives the plugin through a scripted sequence for GIF recording, using
-- the real production code paths (the same button callbacks and menu
-- selection handlers a genuine tap/gesture would trigger) rather than
-- faking input events - and locates every on-screen tap target by
-- inspecting the actual widget tree (button/menu-item `.dimen`, and
-- document text via findText + getScreenBoxesFromPositions) instead of
-- hardcoding pixel coordinates, so this keeps working regardless of the
-- window size the emulator happens to get.
--
-- Reads SCRIPTUREGOTO_DEMO (a mode name from modes.json), SCRIPTUREGOTO_DEMO_PLAN
-- (the path to modes.json) and SCRIPTUREGOTO_DEMO_DIR (a directory for
-- sentinel/coordinate files) from the environment. A mode is a list of
-- steps (see STEPS below). Protocol: after setting up, the hook calls
-- ready(0); then for each step N (1-based) it waits for "<dir>/goN",
-- performs step N, and calls ready(N). ready(N) first works out where the
-- *next* step will tap (saved to "<dir>/coords.json" as "t<N+1>"), then
-- saves a screenshot "<dir>/shotN.png" and touches "<dir>/readyN". The
-- recording script (record.py) drives the go/ready handshake; this file
-- only touches the koreader/plugin side.
local self = ...

local demo = os.getenv("SCRIPTUREGOTO_DEMO")
if not demo then return end

local dir = os.getenv("SCRIPTUREGOTO_DEMO_DIR")
if not dir then return end

-- Document switches (the "go to scripture" jump) tear down this ReaderUI
-- and create a new one, re-running init() (and thus this hook) - keep a
-- global pointer to whichever ui is current, since steps that fire after
-- the switch need the new document's ui, not this run's (torn-down) one.
_G.__scripturegoto_demo_ui = self.ui
if _G.__scripturegoto_demo_fired then return end
_G.__scripturegoto_demo_fired = true

local UIManager = require("ui/uimanager")
local Device = require("device")
local json = require("json")

local function currentUi() return _G.__scripturegoto_demo_ui end

-- Every coordinate this hook reads from koreader (widget `.dimen`,
-- document-text boxes) is in koreader's own internal screen space
-- (Device.screen:getWidth() x :getHeight()), which the emulator's window
-- manager here does not reliably size to any particular value. record.py
-- scales each screenshot to a fixed width (SCRIPTUREGOTO_DEMO_CONTENT_W,
-- set by record.py to match), so every coordinate has to be scaled the
-- same way to land correctly on it.
local CONTENT_W = tonumber(os.getenv("SCRIPTUREGOTO_DEMO_CONTENT_W")) or 720
local SCALE = CONTENT_W / Device.screen:getWidth()

local function readJson(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("a")
    f:close()
    local ok, decoded = pcall(json.decode, content)
    return ok and decoded or nil
end

local plan = readJson(os.getenv("SCRIPTUREGOTO_DEMO_PLAN") or "")
local mode = plan and plan[demo]
if not mode then return end
local steps = mode.steps

-- The letter hints (Q W E R ...) on a results list are for keyboard
-- navigation; they have no place in a demo of a touch device.
require("ui/widget/menu").is_enable_shortcut = false

local function touch(path)
    local f = io.open(path, "w")
    if f then f:close() end
end

local function waitForFile(path, callback)
    local function check()
        local f = io.open(path, "r")
        if f then
            f:close()
            callback()
        else
            UIManager:scheduleIn(0.1, check)
        end
    end
    check()
end

-- Merges `coords` (a table of name -> {x=, y=}) into "<dir>/coords.json".
local function saveCoords(coords)
    local existing = readJson(dir .. "/coords.json") or {}
    for k, v in pairs(coords) do existing[k] = v end
    local f = io.open(dir .. "/coords.json", "w")
    f:write(json.encode(existing))
    f:close()
end

local function dimenCenter(dimen)
    if not dimen then return nil end
    return { x = (dimen.x + dimen.w / 2) * SCALE, y = (dimen.y + dimen.h / 2) * SCALE }
end

-- Finds a screen-space box for a run of visible text, by searching for it
-- and asking crengine for the screen boxes of the match - this is exactly
-- how a real search-result highlight is positioned (see readersearch.lua's
-- use of getTextFromXPointers(start, "end", true)), just without actually
-- drawing a selection.
local function findTextBox(ui, text)
    local results = ui.document:findText(text, 0, 0, false, ui.view.state.page, false, 5, 0)
    local hit = results and results[1]
    if not hit then return nil end
    local boxes = ui.document:getScreenBoxesFromPositions(hit.start, hit["end"], true)
    if not boxes or #boxes == 0 then return nil end
    local box = boxes[1]
    return {
        left = { x = box.x * SCALE, y = (box.y + box.h / 2) * SCALE },
        right = { x = (box.x + box.w) * SCALE, y = (box.y + box.h / 2) * SCALE },
        center = { x = (box.x + box.w / 2) * SCALE, y = (box.y + box.h / 2) * SCALE },
    }, hit
end

-- The topmost shown widget: whichever dialog, popup or results list is up.
local function topWidget()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget
end

-- Finds a dialog's button widget by its exact label, by walking the button
-- grid built by ui/widget/buttontable.lua (buttons_layout is a [row][col]
-- array of the actual Button widgets). ButtonDialog calls its table
-- `buttontable`, InputDialog and TextViewer `button_table`.
local function findDialogButton(dialog, label)
    local table_ = dialog and (dialog.buttontable or dialog.button_table)
    local layout = table_ and table_.buttons_layout
    if not layout then return nil end
    for _, row in ipairs(layout) do
        for _, button in ipairs(row) do
            if button.text == label then return button end
        end
    end
    return nil
end

local function itemLabel(item)
    return item.text_func and item.text_func() or item.text
end

-- The reader's TouchMenu while it is open.
local function touchMenu()
    local ui = currentUi()
    return ui.menu and ui.menu.menu_container and ui.menu.menu_container[1]
end

-- Finds a TouchMenu row by its label on the page showing now, by walking
-- item_group (see ui/widget/touchmenu.lua: item_group holds the menu's icon
-- bar followed by one TouchMenuItem per visible entry).
local function findMenuRow(menu, label)
    for _, widget in ipairs(menu.item_group) do
        if widget.item and itemLabel(widget.item) == label then return widget end
    end
    return nil
end

-- The index of the TouchMenu tab holding an item labelled `label`.
local function findTab(menu, label)
    for i, tab in ipairs(menu.tab_item_table) do
        for _, item in ipairs(tab) do
            if itemLabel(item) == label then return i end
        end
    end
end

-- A results list row, by the item's text (plain-text rows) or parsed label
-- (rows whose text carries bold markup).
local function findResultRow(menu, label)
    for _, row in ipairs(menu.item_group) do
        local entry = row.entry
        if entry and (entry.text == label or (entry.parsed and entry.parsed.label == label)) then
            return row
        end
    end
end

local function selectPhrase(ui, phrase)
    -- Select the phrase the same way a real search result gets selected
    -- (see readersearch.lua's use of getTextFromXPointers(start, "end",
    -- true) to highlight a found range) - this avoids needing a real
    -- hold+pan+release gesture at physical screen coordinates.
    local h = ui.highlight
    local _, hit = findTextBox(ui, phrase)
    if hit then
        ui.document:getTextFromXPointers(hit.start, hit["end"], true)
        h.selected_text = {
            text = phrase,
            pos0 = hit.start,
            pos1 = hit["end"],
            sboxes = ui.document:getScreenBoxesFromPositions(hit.start, hit["end"], true),
        }
        h:onShowHighlightMenu()
    end
end

local LINK_URL = "https://www.churchofjesuschrist.org/study/scriptures/nt/john/3?lang=eng&id=p16#p16"
local LINK_TEXT = "John 3:16"
local PHRASE = "Alma 7:24"

-- Seconds a step needs to finish (document switches, downloads) before
-- the screenshot.
local BUTTON_WAIT = { ["Go to scripture"] = 3.0, ["Preview scripture"] = 1.5, ["Close"] = 1.0 }

-- Each step: where the tap lands (target: returns {x,y}, or {from=, to=}
-- for a drag), and what the tap does (act), run through the same code a
-- real tap runs. `wait` is how long to let it finish.
local STEPS = {}

function STEPS.link()
    return {
        target = function()
            local box = findTextBox(currentUi(), LINK_TEXT)
            return box and box.center
        end,
        act = function() currentUi().link:onGoToExternalLink(LINK_URL) end,
        wait = 0.5,
    }
end

function STEPS.select()
    return {
        target = function()
            local box = findTextBox(currentUi(), PHRASE)
            -- Left to right edge, so the GIF can animate the indicator
            -- sliding across the phrase like the drag of a real
            -- select-and-hold gesture.
            return box and { from = box.left, to = box.right }
        end,
        act = function() selectPhrase(currentUi(), PHRASE) end,
        wait = 0.5,
    }
end

function STEPS.button(label)
    return {
        target = function()
            local button = findDialogButton(topWidget(), label)
            return dimenCenter(button and button.dimen)
        end,
        act = function()
            local button = findDialogButton(topWidget(), label)
            if button and button.callback then button.callback() end
        end,
        wait = BUTTON_WAIT[label] or 1.0,
    }
end

function STEPS.type()
    return {
        target = function()
            local dialog = topWidget()
            local input = dialog and dialog._input_widget
            return dimenCenter(input and input.dimen)
        end,
        act = function() topWidget():setInputText(mode.query) end,
        wait = 0.3,
    }
end

-- A tap near the top of the screen opens the reader menu. ":main" opens it
-- on the last tab (history, "Open previous document", ...), otherwise on
-- the first tab (the menu would otherwise reopen on whichever tab was left
-- open last, which is saved per book and so differs between runs).
function STEPS.menu_top(which)
    return {
        target = function() return { x = CONTENT_W / 2, y = 30 } end,
        act = function()
            -- 7 = the main (hamburger) tab of the reader menu.
            currentUi().menu:onShowMenu(which == "main" and 7 or 1)
        end,
        wait = 0.5,
    }
end

function STEPS.tab(label)
    -- `label` names a tab by an item only it holds: "tools" has "More
    -- tools", "search" has "Search scriptures…".
    local marker = ({ tools = "More tools", search = "Search scriptures…" })[label]
    return {
        target = function()
            local menu = touchMenu()
            local i = menu and findTab(menu, marker)
            return dimenCenter(i and menu.bar.icon_widgets[i].dimen)
        end,
        act = function()
            -- Through the tab bar, as a tap on its icon runs it: that also
            -- moves the bar's highlight (switchMenuTab alone leaves the
            -- old tab highlighted over the new tab's items).
            local menu = touchMenu()
            menu.bar:switchToTab(findTab(menu, marker))
        end,
        wait = 0.4,
    }
end

function STEPS.page_next()
    return {
        target = function()
            local menu = touchMenu()
            return dimenCenter(menu and menu.page_info_right_chev.dimen)
        end,
        act = function() touchMenu():onNextPage() end,
        wait = 0.4,
    }
end

function STEPS.item(label)
    local function row()
        local menu = touchMenu()
        return menu and findMenuRow(menu, label)
    end
    return {
        target = function()
            local r = row()
            return dimenCenter(r and (r.item_frame and r.item_frame.dimen or r.dimen))
        end,
        act = function(done)
            local r = row()
            if not r then return end
            if label == "Open previous document" then
                -- TouchMenu:onMenuSelect() would normally run the item's
                -- callback (real production code - same as tapping it) and
                -- then close the menu, in that order; here that leaves the
                -- menu visibly open even though the document underneath
                -- has switched, since the callback itself tears down and
                -- replaces this whole ReaderUI (and thus this menu
                -- instance) before the close half gets to run. Close first,
                -- with a tick to let that render, then run the real
                -- callback.
                currentUi().menu:onCloseReaderMenu()
                UIManager:scheduleIn(0.5, function() r.item.callback() end)
            else
                touchMenu():onMenuSelect(r.item)
            end
        end,
        wait = label == "Open previous document" and 3.5 or 0.6,
    }
end

-- Taps a row of the search results list.
function STEPS.result()
    local function row()
        local menu = topWidget()
        return menu and menu.item_group and findResultRow(menu, mode.pick)
    end
    return {
        target = function()
            local r = row()
            return dimenCenter(r and r.dimen)
        end,
        act = function()
            local r = row()
            if r then topWidget():onMenuChoice(r.entry) end
        end,
        wait = 3.0,
    }
end

local actions = {}
for i, spec in ipairs(steps) do
    local name, arg = spec:match("^([^:]+):?(.*)$")
    actions[i] = STEPS[name](arg ~= "" and arg or nil)
end

-- Works out the next step's tap target, then screenshots koreader's own
-- framebuffer (Screen:shot), not the X11 window: under XWayland an X11
-- grab of the window can return a stale picture after the document
-- switches. The brief delay lets whatever the step just did finish
-- painting. record.py waits for "<dir>/readyN" and then picks up
-- "<dir>/shotN.png".
local function ready(n)
    UIManager:scheduleIn(0.8, function()
        local nxt = actions[n + 1]
        if nxt then
            local ok, target = pcall(nxt.target)
            saveCoords({ ["t" .. (n + 1)] = ok and target or nil })
        end
        Device.screen:shot(dir .. "/shot" .. n .. ".png")
        touch(dir .. "/ready" .. n)
    end)
end

if mode.build_index then
    -- Build the word index up front so the recording shows the instant
    -- search a user gets after the one-time build.
    local SearchIndex = require("search_index")
    if not SearchIndex:isBuilt() then SearchIndex:build() end
end

self.last_search_query = nil
ready(0)

for i, action in ipairs(actions) do
    waitForFile(dir .. "/go" .. i, function()
        action.act()
        UIManager:scheduleIn(action.wait, function() ready(i) end)
    end)
end
