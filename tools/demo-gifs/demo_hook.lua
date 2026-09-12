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
-- Reads SCRIPTUREGOTO_DEMO (one of "jump", "preview", "hjump", "hpreview")
-- and SCRIPTUREGOTO_DEMO_DIR (a directory for sentinel/coordinate files)
-- from the environment. Protocol per stage N: this hook waits for
-- "<dir>/goN" to appear, performs stage N, writes any tap-indicator
-- coordinate for the *next* stage's target to "<dir>/coords.json" (merging
-- with what's already there), then touches "<dir>/readyN". The recording
-- script (record.py) drives the go/ready handshake and takes the
-- screenshots; this file only touches the koreader/plugin side.
local self = ...

local demo = os.getenv("SCRIPTUREGOTO_DEMO")
if not demo then return end

local dir = os.getenv("SCRIPTUREGOTO_DEMO_DIR")
if not dir then return end

-- Document switches (the "go to scripture" jump) tear down this ReaderUI
-- and create a new one, re-running init() (and thus this hook) - keep a
-- global pointer to whichever ui is current, since stages that fire after
-- the switch need the new document's ui, not this run's (torn-down) one.
_G.__scripturegoto_demo_ui = self.ui
if _G.__scripturegoto_demo_fired then return end
_G.__scripturegoto_demo_fired = true

local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local json = require("json")

-- Every coordinate this hook reads from koreader (widget `.dimen`,
-- document-text boxes) is in koreader's own internal screen space
-- (Device.screen:getWidth() x :getHeight()), which the emulator's window
-- manager here does not reliably size to any particular value. record.py's
-- capture() always scales its screenshot to a fixed width instead (see
-- SCRIPTUREGOTO_DEMO_CONTENT_W, set by record.py to match), so every
-- coordinate has to be scaled the same way to land correctly on that
-- screenshot - confirmed empirically: without this, a button's own
-- `.dimen` (which *is* real and correctly the button's position, just in
-- the wrong space) landed a full two rows off on a run where koreader's
-- internal width (624) diverged from the capture width (720).
local CONTENT_W = tonumber(os.getenv("SCRIPTUREGOTO_DEMO_CONTENT_W")) or 720
local SCALE = CONTENT_W / Device.screen:getWidth()

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
    local path = dir .. "/coords.json"
    local existing = {}
    local f = io.open(path, "r")
    if f then
        local content = f:read("a")
        f:close()
        local ok, decoded = pcall(json.decode, content)
        if ok and decoded then existing = decoded end
    end
    for k, v in pairs(coords) do existing[k] = v end
    f = io.open(path, "w")
    f:write(json.encode(existing))
    f:close()
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

local function findTextCenter(ui, text)
    local box, hit = findTextBox(ui, text)
    return box and box.center, hit
end

-- Finds a ButtonDialog's button widget by its exact label, by walking the
-- button grid built by ui/widget/buttontable.lua (buttontable.buttons_layout
-- is a [row][col] array of the actual Button widgets).
local function findDialogButton(dialog, label)
    local layout = dialog.buttontable and dialog.buttontable.buttons_layout
    if not layout then return nil end
    for _, row in ipairs(layout) do
        for _, button in ipairs(row) do
            if button.text == label then return button end
        end
    end
    return nil
end

-- Finds a TouchMenu's item widget by its rendered label, by walking
-- item_group (see ui/widget/touchmenu.lua: item_group holds the menu's
-- icon bar followed by one TouchMenuItem per visible entry).
local function findMenuItem(menu, label)
    for _, widget in ipairs(menu.item_group) do
        if widget.item then
            local item = widget.item
            local text = item.text_func and item.text_func() or item.text
            if text == label then return widget end
        end
    end
    return nil
end

local function dimenCenter(dimen)
    if not dimen then return nil end
    return { x = (dimen.x + dimen.w / 2) * SCALE, y = (dimen.y + dimen.h / 2) * SCALE }
end

if demo == "jump" or demo == "preview" then
    local url = "https://www.churchofjesuschrist.org/study/scriptures/nt/john/3?lang=eng&id=p16#p16"
    local button_label = demo == "jump" and "Go to scripture" or "Preview scripture"

    touch(dir .. "/ready0")

    waitForFile(dir .. "/go1", function()
        -- Stage 1: real production tap handler, same as a genuine tap on
        -- the link - this is what opens the dialog with our buttons in it.
        self.ui.link:onGoToExternalLink(url)
        UIManager:scheduleIn(0.2, function()
            local center = findTextCenter(self.ui, "John 3:16")
            local dialog = self.ui.link.external_link_dialog
            local button = dialog and findDialogButton(dialog, button_label)
            saveCoords({
                link = center,
                dialog_button = dimenCenter(button and button.dimen),
            })
            touch(dir .. "/ready1")
        end)
    end)

    waitForFile(dir .. "/go2", function()
        -- Stage 2: call the real button's own callback (the same closure
        -- addExternalLinkDialogButton/addExternalLinkPreviewButton
        -- registered) instead of re-deriving what it does - this is
        -- exactly what a real tap on that button runs.
        local dialog = self.ui.link.external_link_dialog
        local button = dialog and findDialogButton(dialog, button_label)
        if button and button.callback then button.callback() end
        UIManager:scheduleIn(3.0, function() touch(dir .. "/ready2") end)
    end)

    if demo == "jump" then
        waitForFile(dir .. "/go3", function()
            -- Stage 3: open the top-right "main" menu tab (history / open
            -- previous document / etc), same as tapping the hamburger icon
            -- there. Use the current (post-switch) ui - see note above.
            local ui = _G.__scripturegoto_demo_ui
            ui.menu:onShowMenu(7)
            UIManager:scheduleIn(0.3, function()
                local menu = ui.menu.menu_container[1]
                local icon = menu.bar.icon_widgets[7]
                local item = findMenuItem(menu, "Open previous document")
                saveCoords({
                    menu_icon = dimenCenter(icon and icon.dimen),
                    menu_item = dimenCenter(item and item.item_frame and item.item_frame.dimen),
                })
                touch(dir .. "/ready3")
            end)
        end)

        waitForFile(dir .. "/go4", function()
            local ui = _G.__scripturegoto_demo_ui
            local menu = ui.menu.menu_container[1]
            local item_widget = menu and findMenuItem(menu, "Open previous document")
            if item_widget then
                -- TouchMenu:onMenuSelect() would normally run the item's
                -- callback (real production code - same as tapping it) and
                -- then close the menu, in that order; here that leaves the
                -- menu visibly open even though the document underneath
                -- has switched, since the callback itself tears down and
                -- replaces this whole ReaderUI (and thus this menu
                -- instance) before the close half gets to run. Close first
                -- instead, with a tick to let that render, then run the
                -- real callback.
                ui.menu:onCloseReaderMenu()
                UIManager:scheduleIn(0.5, function()
                    item_widget.item.callback()
                end)
            end
            UIManager:scheduleIn(3.5, function() touch(dir .. "/ready4") end)
        end)
    end
elseif demo == "hjump" or demo == "hpreview" then
    local phrase = "Alma 7:24"
    local button_label = demo == "hjump" and "Go to scripture" or "Preview scripture"

    touch(dir .. "/ready0")

    waitForFile(dir .. "/go1", function()
        -- Stage 1: select the phrase the same way a real search result
        -- gets selected (see readersearch.lua's use of
        -- getTextFromXPointers(start, "end", true) to highlight a found
        -- range) - this avoids needing a real hold+pan+release gesture at
        -- physical screen coordinates, which would have to match whatever
        -- window size this particular run's window manager assigns.
        local h = self.ui.highlight
        local box, hit = findTextBox(self.ui, phrase)
        if hit then
            self.ui.document:getTextFromXPointers(hit.start, hit["end"], true)
            h.selected_text = {
                text = phrase,
                pos0 = hit.start,
                pos1 = hit["end"],
                sboxes = self.ui.document:getScreenBoxesFromPositions(hit.start, hit["end"], true),
            }
            h:onShowHighlightMenu()
        end
        UIManager:scheduleIn(0.3, function()
            local dialog = h.highlight_dialog
            local button = dialog and findDialogButton(dialog, button_label)
            saveCoords({
                -- Left/right edges (not just a center point) so the GIF can
                -- animate the tap indicator sliding across the phrase, like
                -- the drag of a real select-and-hold gesture.
                phrase_left = box and box.left,
                phrase_right = box and box.right,
                dialog_button = dimenCenter(button and button.dimen),
            })
            touch(dir .. "/ready1")
        end)
    end)

    waitForFile(dir .. "/go2", function()
        -- Stage 2: call the real button's own callback, same as stage 2
        -- of the link-based flow above.
        local h = self.ui.highlight
        local dialog = h.highlight_dialog
        local button = dialog and findDialogButton(dialog, button_label)
        if button and button.callback then button.callback() end
        UIManager:scheduleIn(3.0, function() touch(dir .. "/ready2") end)
    end)
end
