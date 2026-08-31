--[[
    The console window.

    Layout, top to bottom: a toolbar of icon buttons, a filter row, the canvas
    log view filling the rest, an optional detail pane, and a status line. All
    Align driven, never absolute, so the window resizes and the view is told to
    re-measure instead of being redrawn at a stale size.

    Refresh is throttled. The log calls back on every record, but the callback
    only sets a flag. A timer turns the newest flag into one repaint every
    RefreshInterval milliseconds. Pause stops the repaint, not the recording,
    so nothing is lost and resuming shows what arrived meanwhile.

    Closing hides the window. OnClose returns caHide, so the filter, the scroll
    position and the selection survive a close and reopen. The host frees the
    window explicitly when it is finished with it.

    Focus is tracked, not queried. KeyPreview is on so the view gets arrow keys
    and Ctrl+A, which would otherwise be swallowed. KeyPreview also takes every
    keystroke away from the search box, so the box reports its own focus
    through OnEnter and OnExit. Reading form.ActiveControl back and comparing
    it is not reliable, because two lookups of the same Cheat Engine object
    need not produce the same Lua value.
]]

local Core = require("Manifold-Logger-Core")
local Format = require("Manifold-Logger-Format")
local View = require("Manifold-Logger-View")
local Version = require("Manifold-Logger-Version")

local Console = {}
Console.__index = Console

Console.Defaults = {
    Width = 980,
    Height = 620,
    RefreshInterval = 120,   -- ms between repaints while records arrive
    DetailHeight = 170
}

--- The level thresholds offered in the filter. SUCCESS is absent because it
--- shares INFO's band, so "at least SUCCESS" would be a rank nobody means.
--- See Manifold-Logger-Core.Levels.
Console.LevelChoices = {
    { Caption = "All",      Rank = 0 },
    { Caption = "Trace",    Rank = Core.Levels.TRACE },
    { Caption = "Debug",    Rank = Core.Levels.DEBUG },
    { Caption = "Info",     Rank = Core.Levels.INFO },
    { Caption = "Warning",  Rank = Core.Levels.WARNING },
    { Caption = "Error",    Rank = Core.Levels.ERROR },
    { Caption = "Critical", Rank = Core.Levels.CRITICAL }
}

Console.ExportChoices = { "text", "jsonl", "csv", "markdown" }

--
--- ∑ Builds a console. Nothing is created until Open.
--- @param services table # { Log, Theme, Icons, Writer }
--- @return table
--
function Console:New(services)
    services = services or {}
    return setmetatable({
        Log     = services.Log,
        Theme   = services.Theme,
        Icons   = services.Icons,
        Writer  = services.Writer,

        Form    = nil,
        View    = nil,
        Memo    = nil,        -- fallback when no canvas surface exists
        Timer   = nil,
        Listener= nil,

        Paused  = false,
        PendingRefresh = true,   -- a record arrived, re-read the log
        PendingRedraw = false,   -- nothing arrived, but the picture changed
        NeedsFullRefresh = true, -- the shown list cannot be extended, only rebuilt
        SearchFocused = false,
        DetailVisible = false,
        ExportMode = "text",

        Filter  = { MinRank = Core.Levels.TRACE, Channel = nil, Search = nil },
        ThemeSource = false,      -- the design theme table the chrome was coloured from
        SearchLower = nil,        -- lowered once per change, not once per record
        Signature = nil,          -- the filter, as a string, to notice a change
        ChannelSignature = nil,   -- so the channel list is only rebuilt when it moved
        -- One array for the life of the window, mutated in place. The view
        -- uses that identity to append rows for the new records instead of
        -- rebuilding every row on every frame.
        Shown   = {},
        ShownSeq = 0,             -- highest Seq already considered
        Stats   = { Total = 0, Shown = 0, Hidden = 0, Suppressed = 0 }
    }, Console)
end

--------------------------------------------------------
--                      Helpers                       --
--------------------------------------------------------

local function safeSet(control, property, value)
    if not control then return false end
    return (pcall(function() control[property] = value end))
end

local function clipboard(text)
    local write = rawget(_G, "writeToClipboard")
    if type(write) ~= "function" then return false end
    return (pcall(write, tostring(text)))
end

local function shell(path)
    local execute = rawget(_G, "shellExecute")
    if type(execute) ~= "function" or not path then return false end
    return (pcall(execute, path))
end

--------------------------------------------------------
--                       Window                       --
--------------------------------------------------------

--
--- ∑ Shows the console, building it on first use.
--- @return userdata|nil
--
function Console:Open()
    if self.Form then
        local alive = pcall(function()
            self.Form.Visible = true
            self.Form.BringToFront()
        end)
        if alive then
            -- A theme may have been applied while the window was hidden.
            self:CheckTheme()
            self:Refresh(true)
            return self.Form
        end
        -- The form was destroyed outside our control. Fall through and
        -- rebuild instead of doing nothing.
        self:Release()
    end
    self:Build()
    self:Refresh(true)
    if self.View then self.View:ScrollToEnd() end
    safeSet(self.Form, "Visible", true)
    return self.Form
end

function Console:Close()
    if self.Form then pcall(function() self.Form.Visible = false end) end
end

function Console:Toggle()
    local visible = false
    if self.Form then pcall(function() visible = self.Form.Visible == true end) end
    if visible then self:Close() else self:Open() end
end

--
--- ∑ Whether the window is on screen. A form destroyed from outside makes the
---   property read raise. Let go of everything pointing at it then, or the
---   refresh timer keeps asking and the listener keeps setting a flag for a
---   window that no longer exists.
--- @return boolean
--
function Console:IsOpen()
    if not self.Form then return false end
    local ok, visible = pcall(function() return self.Form.Visible == true end)
    if not ok then
        self:Release(true)
        return false
    end
    return visible == true
end

--
--- ∑ Constructs the window and everything in it.
--- @return nil
--
function Console:Build()
    local theme = self.Theme
    -- Nothing from a previous window may be re-coloured through this one.
    theme:Forget()
    local form = theme:CreateWindow(
        string.format("%s - %s", Version.Full(), self.Log.Name or "Manifold"),
        Console.Defaults.Width, Console.Defaults.Height)
    self.Form = form

    -- Bottom up. alBottom stacks in creation order, so the status line ends up
    -- furthest down and the detail pane above it.
    self.StatusLabel, self.StatusBar, self.StatusDetail = theme:CreateStatusBar(form, "")
    self:BuildDetail(form)
    self:BuildToolBar(form)
    self:BuildFilterBar(form)
    self:BuildView(form)
    self:BuildMenu()
    self:BuildKeys(form)

    self.ThemeSource = theme:Source()

    -- Live updates. The listener only sets a flag, the timer decides when that
    -- becomes a repaint. A new record has to be filtered and appended, a dedup
    -- update only changes a counter the record already carries, and a clear
    -- invalidates the shown list outright.
    self.Listener = self.Log:AddListener(function(_, kind)
        if kind == "new" then
            self.PendingRefresh = true
        elseif kind == "clear" then
            self.NeedsFullRefresh = true
            self.PendingRefresh = true
        else
            self.PendingRedraw = true
        end
    end)
    self:StartTimer()

    form.OnClose = function()
        -- Hide, do not free. See the file header. caHide is ordinal 1 in
        -- TCloseAction, which is what the fallback stands for.
        self:Close()
        return rawget(_G, "caHide") or 1
    end
end

function Console:BuildToolBar(form)
    local theme = self.Theme
    local bar = theme:CreateToolBar(form, 40)
    self.ToolBar = bar

    local function button(options)
        options.Align = "alLeft"
        return theme:CreateToolButton(bar, options)
    end

    local _, _, setPaused = button({
        Caption = "Pause", Icon = "Pause", Width = 92, Toggle = true,
        Hint = "Stop repainting. Records keep arriving and appear on resume.",
        OnClick = function(pressed) self:SetPaused(pressed) end
    })
    self.SetPausedButton = setPaused

    local _, _, setFollow = button({
        Caption = "Follow", Icon = "Follow", Width = 96, Toggle = true, Pressed = true,
        Hint = "Keep the newest record in view (End).",
        OnClick = function(pressed) if self.View then self.View:SetFollow(pressed) end end
    })
    self.SetFollowButton = setFollow

    button({
        Caption = "Wrap", Icon = "WrapLongLines", Width = 88, Toggle = true,
        Hint = "Wrap long lines instead of cutting them.",
        OnClick = function(pressed) if self.View then self.View:SetWrap(pressed) end end
    })

    theme:CreateToolSeparator(bar)

    button({
        Caption = "Copy", Icon = "Copy", Width = 88,
        Hint = "Copy the selected records, or everything shown (Ctrl+C).",
        OnClick = function() self:CopySelection() end
    })
    button({
        Caption = "Export", Icon = "Export", Width = 96,
        Hint = "Write what is shown to a file, as text, JSON lines, CSV or Markdown.",
        OnClick = function() self:Export() end
    })
    button({
        Caption = "Clear", Icon = "Clear", Width = 88,
        Hint = "Empty the buffer. The counters and the log file are untouched.",
        OnClick = function() self:ClearBuffer() end
    })

    theme:CreateToolSeparator(bar)

    local _, _, setDetail = button({
        Caption = "Detail", Icon = "Detail", Width = 92, Toggle = true,
        Hint = "Show the full record, its fields and its traceback.",
        OnClick = function(pressed) self:SetDetailVisible(pressed) end
    })
    self.SetDetailButton = setDetail

    -- alRight so it sits at the far end, away from the verbs.
    self.MenuButton = theme:CreateButton(bar, {
        Caption = "Menu", Icon = "Settings", Align = "alRight", Width = 92, Height = 28,
        Hint = "Everything else. Also on right-click, anywhere in the log.",
        OnClick = function() self:ShowMenu() end
    })
end

function Console:BuildFilterBar(form)
    local theme = self.Theme
    local bar = theme:CreatePanel(form, {
        Align = "alTop", Height = 34, Spacing = { Left = 8, Right = 8, Top = 2 }
    })
    self.FilterBar = bar

    local captions = {}
    for index, choice in ipairs(Console.LevelChoices) do captions[index] = choice.Caption end

    local label = theme:CreateLabel(bar, "Level", "muted")
    safeSet(label, "Left", 4)
    safeSet(label, "Top", 8)

    self.LevelCombo = theme:CreateCombo(bar, {
        Items = captions, ItemIndex = 0, Left = 46, Top = 4, Width = 104,
        Hint = "Hide everything below this level. The records are kept either way.",
        OnChange = function()
            local index = (tonumber(self.LevelCombo.ItemIndex) or 0) + 1
            local choice = Console.LevelChoices[index]
            self.Filter.MinRank = choice and choice.Rank or 0
            self:Refresh(true)
        end
    })

    local channelLabel = theme:CreateLabel(bar, "Channel", "muted")
    safeSet(channelLabel, "Left", 164)
    safeSet(channelLabel, "Top", 8)

    self.ChannelCombo = theme:CreateCombo(bar, {
        Items = { "All channels" }, ItemIndex = 0, Left = 226, Top = 4, Width = 168,
        Hint = "Show one producer only. Sub-channels of the choice are included.",
        OnChange = function()
            local index = tonumber(self.ChannelCombo.ItemIndex) or 0
            self.Filter.Channel = index > 0 and self.ChannelList[index] or nil
            self:Refresh(true)
        end
    })
    self.ChannelList = {}

    local searchLabel = theme:CreateLabel(bar, "Search", "muted")
    safeSet(searchLabel, "Left", 408)
    safeSet(searchLabel, "Top", 8)

    self.SearchEdit = theme:CreateEdit(bar, {
        Left = 466, Top = 4, Width = 260, Anchors = "[akLeft,akTop,akRight]",
        Placeholder = "plain text, case-insensitive",
        Hint = "Filter and highlight. Ctrl+F focuses this box.",
        OnChange = function()
            local text = self.SearchEdit.Text
            self.Filter.Search = (text ~= "" and text) or nil
            self.SearchLower = self.Filter.Search and self.Filter.Search:lower() or nil
            if self.View then self.View:SetSearch(text) end
            -- Flag it and let the tick coalesce. A search change arrives per
            -- keystroke, and the 120 ms timer exists to stop each one
            -- re-filtering the whole buffer. Paused, no tick runs, so the
            -- refresh happens here instead.
            self.NeedsFullRefresh = true
            self.PendingRefresh = true
            if self.Paused then self:Refresh(true) end
        end
    })
    -- KeyPreview would otherwise route every keystroke to the view.
    safeSet(self.SearchEdit, "OnEnter", function() self.SearchFocused = true end)
    safeSet(self.SearchEdit, "OnExit", function() self.SearchFocused = false end)
end

function Console:BuildView(form)
    local theme = self.Theme
    local content, card = theme:CreateCard(form, { Align = "alClient", ContentPad = 1 })
    self.ViewCard = card

    local view = View:New({ Theme = theme, Icons = self.Icons, Meta = Core.Meta })
    local ok, reason = view:Attach(content)
    if not ok then
        -- No canvas on this Cheat Engine build. A themed memo still shows the
        -- log, it just cannot colour it or draw the icons.
        self.View = nil
        self.Memo = theme:CreateMemo(content)
        self.SurfaceReason = reason
        return
    end
    self.View = view
    view.OnFollowChanged = function(value)
        if self.SetFollowButton then self.SetFollowButton(value) end
    end
    view.OnSelectionChanged = function()
        self:UpdateDetail()
        self:UpdateStatus()
    end
    view.OnActivate = function()
        self:SetDetailVisible(true)
        if self.SetDetailButton then self.SetDetailButton(true) end
    end
    -- No OnContextMenu on purpose. The right button selects the row under the
    -- cursor (View:MouseDown) and the LCL shows the attached menu itself.
    -- Popping it by hand as well would show it twice. See Console:BuildMenu.

    -- A paint failure becomes a record on its own channel. The log's dedup
    -- collapses repeats into one line with a counter, and the view stops
    -- painting after five failures in a row.
    view.OnError = function(reason)
        self.Log:Channel("Logger/Internal"):Error(tostring(reason))
    end
end

function Console:BuildDetail(form)
    local theme = self.Theme
    local content, card = theme:CreateCard(form, {
        Align = "alBottom", Height = Console.Defaults.DetailHeight, Title = "Record"
    })
    self.DetailCard = card
    self.DetailMemo = theme:CreateMemo(content, { WordWrap = true, ScrollBars = "ssVertical" })
    -- The splitter is created after the pane it resizes and takes the same
    -- Align. That is how the LCL pairs the two.
    self.DetailSplitter = theme:CreateSplitter(form, { Align = "alBottom", MinSize = 80 })
    self:SetDetailVisible(false)
end

--------------------------------------------------------
--                        Menu                        --
--------------------------------------------------------

--
--- ∑ Builds the context menu. The owner is the log card's PANEL, not the paint
---   surface. The surface is a TGraphicControl with no window handle, so
---   WM_CONTEXTMENU goes to the nearest windowed ancestor, the panel. A menu
---   on the handle-less child would never show. Every other Manifold window
---   attaches to the panel too.
---
---   Nothing calls PopUp for the right button. The LCL shows the attached menu
---   itself, and doing both would show it twice. The toolbar's Menu button is
---   the one place that pops it explicitly.
--- @return nil
--
function Console:BuildMenu()
    local theme = self.Theme
    local host = (self.View and self.View.Parent) or self.Memo or self.Form
    local menu = theme:CreatePopupMenu(host)
    if not menu then return end
    self.Menu = menu

    menu.Add("Copy Selected", function() self:CopySelection() end,
        { Icon = "CopySelected", Shortcut = "Ctrl+C", Key = "copy" })
    menu.Add("Copy as JSON Lines", function() self:CopySelection("jsonl") end,
        { Icon = "File", Key = "copyjson" })
    menu.Add("Select All", function() if self.View then self.View:SelectAll() end end,
        { Icon = "SelectAll", Shortcut = "Ctrl+A", Key = "selectall" })
    menu.Add("-")
    menu.Add("Pin / Unpin", function() self:TogglePin() end, { Icon = "Pin", Key = "pin" })
    menu.Add("Only This Channel", function() self:FilterToChannel() end,
        { Icon = "Channel", Key = "onlychannel" })
    menu.Add("Clear Filters", function() self:ClearFilters() end,
        { Icon = "ClearFilters", Key = "clearfilters" })
    menu.Add("-")

    local viewItem = menu.Add("View", nil, { Icon = "Eye", Key = "view" })
    if viewItem then
        local function option(caption, key, icon, getter, setter)
            menu.Add(caption, function(item)
                local value = not getter()
                setter(value)
                pcall(function() item.Checked = value end)
                self:Refresh(true)
            end, { Parent = viewItem, Icon = icon, Key = key, Checked = getter() })
        end
        option("Timestamps", "opt_stamp", "Recent",
            function() return self.View and self.View.ShowStamp end,
            function(value) if self.View then self.View:SetShowStamp(value) end end)
        option("Channels", "opt_channel", "Channel",
            function() return self.View and self.View.ShowChannel end,
            function(value) if self.View then self.View:SetShowChannel(value) end end)
        option("Structured Fields", "opt_fields", "Metrics",
            function() return self.View and self.View.ShowFields end,
            function(value) if self.View then self.View:SetShowFields(value) end end)
        option("Wrap Long Lines", "opt_wrap", "Wrap",
            function() return self.View and self.View.Wrap end,
            function(value) if self.View then self.View:SetWrap(value) end end)
        menu.Add("-", nil, { Parent = viewItem })
        -- Spelled into the caption instead of set as a Shortcut property. The
        -- LCL renders a popup menu's shortcuts but never dispatches them, so
        -- the accelerator would look real and do nothing. Console:HandleKey
        -- dispatches these.
        menu.Add("Larger Text  (Ctrl +)", function() self:ChangeFontSize(1) end,
            { Icon = "TextLarger", Parent = viewItem, Key = "fontup" })
        menu.Add("Smaller Text  (Ctrl -)", function() self:ChangeFontSize(-1) end,
            { Icon = "TextSmaller", Parent = viewItem, Key = "fontdown" })
    end

    local logItem = menu.Add("Log File", nil, { Icon = "WriteFile", Key = "logfile" })
    if logItem then
        menu.Add("Open Log File", function() self:OpenLogFile() end,
            { Parent = logItem, Icon = "File", Key = "openfile" })
        menu.Add("Open Log Folder", function() self:OpenLogFolder() end,
            { Parent = logItem, Icon = "Folder", Key = "openfolder" })
        menu.Add("Rotate Now", function() self:RotateLog() end,
            { Parent = logItem, Icon = "Rotate", Key = "rotate" })
        menu.Add("Clear Log File", function() self:ClearLogFile() end,
            { Parent = logItem, Icon = "Clear", Key = "clearfile" })
    end

    local diagItem = menu.Add("Diagnostics", nil, { Icon = "Diagnostics", Key = "diagnostics" })
    if diagItem then
        menu.Add("Session Report", function() self:ReportStats() end,
            { Parent = diagItem, Icon = "Metrics", Key = "stats" })
        menu.Add("Icon Probe", function() self:ReportIcons() end,
            { Parent = diagItem, Icon = "SelfCheck", Key = "iconprobe" })
        menu.Add("Emit one record per level", function() self:EmitSamples() end,
            { Parent = diagItem, Icon = "Level", Key = "samples" })
    end

    menu.Add("-")
    menu.Add("Export...", function() self:Export() end, { Icon = "Export", Key = "export" })
    menu.Add("About", function() self:About() end, { Icon = "About", Key = "about" })

    -- The toolbar button gets the same menu attached, so it works by
    -- right-click even on a build where PopUp cannot be called from Lua.
    if self.MenuButton then menu.Attach(self.MenuButton) end
end

--
--- ∑ Pops the menu up at the cursor, for the toolbar button. PopUp wants
---   SCREEN coordinates and getMousePos returns those, but no script shipping
---   with Cheat Engine uses it, so it counts as optional. Without it the menu
---   lands at the window's own corner, wrong but visible, rather than at (0,0)
---   on the desktop.
--- @return nil
--
function Console:ShowMenu()
    if not self.Menu then return end
    local x, y
    local getMousePos = rawget(_G, "getMousePos")
    if type(getMousePos) == "function" then
        pcall(function() x, y = getMousePos() end)
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        x, y = 0, 0
        pcall(function()
            x = (tonumber(self.Form.Left) or 0) + 24
            y = (tonumber(self.Form.Top) or 0) + 96
        end)
    end
    if not (pcall(function() self.Menu.Menu.popup(x, y) end)) then
        -- No PopUp binding on this Cheat Engine. Say so rather than look like
        -- a dead button. The log's dedup collapses the repeat into a counter.
        self.Log:Channel("Logger/Internal"):Warning(
            "This Cheat Engine cannot open a menu from a button. " ..
            "Right-click the log, or right-click the Menu button.")
    end
end

--------------------------------------------------------
--                      Keyboard                      --
--------------------------------------------------------

--
--- ∑ Installs the window's key handler. Cheat Engine's OnKeyDown binding takes
---   the RETURN VALUE as the new key, which is how the LCL's var Key: Word is
---   exposed. Return 0 to swallow a key, return it unchanged to let it reach
---   the focused control. Both HandleKey implementations already report
---   whether they consumed the key, so that answer decides.
--- @param form userdata
--- @return nil
--
function Console:BuildKeys(form)
    pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(_, key)
            if self:HandleKey(key) then return 0 end
            return key
        end
    end)
end

function Console:HandleKey(key)
    local isKeyPressed = rawget(_G, "isKeyPressed")
    local control = false
    if type(isKeyPressed) == "function" then
        pcall(function() control = isKeyPressed(0x11) == true end)
    end
    -- Ctrl+F reaches the search box from anywhere, including from inside it.
    if control and key == 70 then
        pcall(function() self.SearchEdit.SetFocus() end)
        return true
    end
    -- Everything else belongs to the search box while it has focus. Otherwise
    -- Ctrl+A and the arrow keys never reach the field.
    if self.SearchFocused then
        if key == 27 then
            self.SearchEdit.Text = ""
            return true
        end
        return false
    end
    if control and key == 67 then self:CopySelection() return true end
    -- VK_OEM_PLUS / VK_ADD and VK_OEM_MINUS / VK_SUBTRACT, so the shortcut
    -- works on the main row and on the numeric keypad.
    if control and (key == 0xBB or key == 0x6B) then self:ChangeFontSize(1) return true end
    if control and (key == 0xBD or key == 0x6D) then self:ChangeFontSize(-1) return true end
    if key == 116 then self:Refresh(true) return true end          -- F5
    if key == 112 then self:About() return true end                -- F1
    if key == 19 or (control and key == 80) then                   -- Pause / Ctrl+P
        self:SetPaused(not self.Paused)
        if self.SetPausedButton then self.SetPausedButton(self.Paused) end
        return true
    end
    if self.View then return self.View:HandleKey(key) end
    return false
end

--------------------------------------------------------
--                       Refresh                      --
--------------------------------------------------------

function Console:StartTimer()
    local create = rawget(_G, "createTimer")
    if type(create) ~= "function" then return end
    local ok, timer = pcall(create, self.Form)
    if not ok or not timer then return end
    self.Timer = timer
    safeSet(timer, "Interval", Console.Defaults.RefreshInterval)
    safeSet(timer, "OnTimer", function() self:Tick() end)
    safeSet(timer, "Enabled", true)
end

--
--- ∑ One frame. Cheap when nothing changed, the common case. A window left
---   open on an idle table costs one comparison every 120 ms.
--- @return nil
--
function Console:Tick()
    if not self:IsOpen() then return end
    -- Guarded as a whole, since everything before View:Redraw's own guard runs
    -- bare. An unhandled error in a timer callback is printed by Cheat Engine
    -- at the timer's rate, eight lines a second, forever.
    local ok, err = pcall(function()
        -- The theme check sits BEFORE the pause guard. Pausing stops the log
        -- from moving, it does not mean the window may be the wrong colour. A
        -- theme switched while paused would otherwise leave the window half
        -- themed until somebody resumed it. Nothing here resumes the log,
        -- CheckTheme repaints the records already shown and never refreshes.
        self:CheckTheme()
        if self.Paused then return end
        if self.PendingRefresh then
            self.PendingRefresh = false
            self.PendingRedraw = false
            self:Refresh(false)
        elseif self.PendingRedraw or (self.View and self.View.Dirty) then
            self.PendingRedraw = false
            if self.View then self.View:Redraw() end
        end
    end)
    if ok then
        self.TickFailures = 0
        return
    end
    self.TickFailures = (self.TickFailures or 0) + 1
    self.Log:Channel("Logger/Internal"):Error("Refresh failed: " .. tostring(err))
    if self.TickFailures >= 5 then
        pcall(function() self.Timer.Enabled = false end)
        self.Log:Channel("Logger/Internal"):Error(
            "Live refresh stopped after five consecutive failures. F5 still works.")
    end
end

--
--- ∑ Notices that the Cheat Table's theme changed, and re-colours the window.
---   The canvas reads the palette when it paints, so without this it would
---   follow the new theme while every panel, button, label and box kept the
---   one it was built under.
---
---   The check is an identity comparison against forms.ActiveDesignTheme,
---   which Forms:ApplyTheme replaces with a fresh table on every application.
---   One table lookup per tick, not a palette copy.
--- @return boolean # Whether anything was re-coloured.
--
function Console:CheckTheme()
    local source = self.Theme:Source()
    if source == self.ThemeSource then return false end
    self.ThemeSource = source
    self.Theme:Restyle()
    if self.View then
        -- Colors() picks up the new palette itself and drops the composited
        -- icons with it. This only makes sure a frame happens now.
        self.View:Redraw()
    end
    self:UpdateStatus()
    return true
end

--
--- ∑ The filter as a string, so a change is noticed in one comparison instead
---   of a deep table compare every frame.
--- @return string
--
function Console:FilterSignature()
    local filter = self.Filter
    return table.concat({
        tostring(filter.MinRank), tostring(filter.Channel),
        tostring(filter.Search), tostring(filter.PinnedOnly)
    }, "|")
end

--
--- ∑ Re-reads the log through the current filter and repaints. A FULL rebuild
---   walks the entire ring. It is correct at any time, and it runs when the
---   filter changed, when the buffer was cleared, or when the shown list is
---   otherwise unrelated to what it was. An EXTEND walks only what arrived
---   since the last pass, plus whatever dropped off the front of the ring.
---   Extend is the common case, and it makes a refresh O(new), not O(buffer).
--- @param force boolean # Refresh even when paused. A filter change must show
---        immediately, or the controls look dead.
--- @return nil
--
function Console:Refresh(force)
    if not self.Form then return end
    if self.Paused and not force then return end
    self:SyncChannels()
    local signature = self:FilterSignature()
    local full = self.NeedsFullRefresh or signature ~= self.Signature
    self.Signature = signature
    self.NeedsFullRefresh = false

    if full then self:RebuildShown() else self:ExtendShown() end

    if self.View then
        self.View:Sync(self.Shown, full)
        self.View:Redraw()
    elseif self.Memo then
        pcall(function() self.Memo.Lines.Text = Format.Export(self.Shown, "text") end)
    end
    self:UpdateStatus()
    self:UpdateDetail()
end

--
--- ∑ Refills the shown list from the whole ring, in place. The array's
---   identity is the view's evidence that its rows still belong to these
---   records, so it must not be replaced.
--- @return nil
--
function Console:RebuildShown()
    local shown = self.Shown
    for index = #shown, 1, -1 do shown[index] = nil end
    local filter, searchLower = self.Filter, self.SearchLower
    local suppressed, total, highest = 0, 0, 0
    -- ForEach rather than Records(): the latter allocates an array the size of
    -- the buffer before the filter has looked at anything.
    self.Log:ForEach(function(record)
        total = total + 1
        if record.Seq > highest then highest = record.Seq end
        -- The haystack is built only when something is being searched for.
        -- Core.Matches ignores it otherwise, and Format.Prepare would cost a
        -- table index per record for an argument nobody reads.
        local haystack = searchLower and Format.Prepare(record).Haystack or nil
        if Core.Matches(record, filter, haystack, searchLower) then
            shown[#shown + 1] = record
            if record.Suppressed then suppressed = suppressed + 1 end
        end
    end)
    self.ShownSeq = highest
    self.Stats = { Total = total, Shown = #shown, Hidden = total - #shown,
                   Suppressed = suppressed }
end

--
--- ∑ Brings the shown list up to date without walking the ring. Drops the
---   records that fell off the front, appends the ones that arrived, leaves
---   everything between them alone.
--- @return nil
--
function Console:ExtendShown()
    local shown = self.Shown
    local oldest = self.Log:Bounds()
    local total = #shown
    local drop, droppedSuppressed = 0, 0
    while drop < total and shown[drop + 1].Seq < oldest do
        drop = drop + 1
        if shown[drop].Suppressed then droppedSuppressed = droppedSuppressed + 1 end
    end
    if drop > 0 then
        table.move(shown, drop + 1, total, 1)
        for index = total - drop + 1, total do shown[index] = nil end
        -- The counter describes what is SHOWN, so what left comes off it. Skip
        -- this and the status line drifts upward for the life of the window.
        self.Stats.Suppressed = math.max(0, (self.Stats.Suppressed or 0) - droppedSuppressed)
    end

    local filter, searchLower = self.Filter, self.SearchLower
    for _, record in ipairs(self.Log:Since(self.ShownSeq)) do
        if record.Seq > self.ShownSeq then self.ShownSeq = record.Seq end
        local haystack = searchLower and Format.Prepare(record).Haystack or nil
        if Core.Matches(record, filter, haystack, searchLower) then
            shown[#shown + 1] = record
            if record.Suppressed then
                self.Stats.Suppressed = (self.Stats.Suppressed or 0) + 1
            end
        end
    end
    -- The ring's own count already accounts for what it dropped, so Total
    -- never has to be recounted here.
    self.Stats.Total = self.Log.RingCount
    self.Stats.Shown = #shown
    self.Stats.Hidden = math.max(0, self.Stats.Total - self.Stats.Shown)
end

--
--- ∑ Rebuilds the channel dropdown only when the set of channels changed.
---   Rebuilding it every refresh would close it under the cursor and reset the
---   selection each time a record arrived.
--- @return nil
--
function Console:SyncChannels()
    local names = self.Log:ChannelNames()
    local signature = table.concat(names, "\1")
    if signature == self.ChannelSignature then return end
    self.ChannelSignature = signature
    local selected = self.Filter.Channel
    self.ChannelList = names
    pcall(function()
        local combo = self.ChannelCombo
        combo.Items.clear()
        combo.Items.add("All channels")
        for _, name in ipairs(names) do combo.Items.add(name) end
        local index = 0
        for position, name in ipairs(names) do
            if name == selected then index = position break end
        end
        combo.ItemIndex = index
    end)
end

function Console:UpdateStatus()
    local stats = self.Stats or { Shown = 0, Total = 0, Hidden = 0 }
    local session = self.Log:GetStats()
    local parts = { string.format("%d of %d shown", stats.Shown, stats.Total) }
    if stats.Hidden > 0 then parts[#parts + 1] = string.format("%d hidden by filter", stats.Hidden) end
    if session.Dropped > 0 then parts[#parts + 1] = string.format("%d dropped (flood)", session.Dropped) end
    if self.Paused then parts[#parts + 1] = "PAUSED" end
    if self.SurfaceReason then parts[#parts + 1] = "no canvas: " .. self.SurfaceReason end
    safeSet(self.StatusLabel, "Caption", table.concat(parts, "  -  "))

    -- The right-hand side carries the counters worth seeing at a glance, plus
    -- the state of the log file.
    local counters = {}
    for _, level in ipairs({ "CRITICAL", "ERROR", "WARNING" }) do
        local count = session.ByLevel[level] or 0
        if count > 0 then
            counters[#counters + 1] = string.format("%s %d", Core.Meta[level].Tag, count)
        end
    end
    local writer = self.Writer and self.Writer:Status() or nil
    if writer then
        if not writer.Enabled then
            counters[#counters + 1] = "file off"
        elseif writer.Path then
            counters[#counters + 1] = "file " .. Format.Bytes(writer.Bytes)
        end
    end
    safeSet(self.StatusDetail, "Caption", table.concat(counters, "  |  "))
end

--------------------------------------------------------
--                       Actions                      --
--------------------------------------------------------

function Console:SetPaused(value)
    self.Paused = value == true
    if not self.Paused then self:Refresh(true) end
    self:UpdateStatus()
end

function Console:SetDetailVisible(value)
    self.DetailVisible = value == true
    safeSet(self.DetailCard, "Visible", self.DetailVisible)
    safeSet(self.DetailSplitter, "Visible", self.DetailVisible)
    -- Forced, because the pane was empty while hidden. An unchanged selection
    -- is no reason to leave it empty.
    if self.DetailVisible then self:UpdateDetail(true) end
end

--
--- ∑ Renders the focused record in full. The line, every field, the traceback
---   if there is one, and the JSON form for pasting into an issue.
--- @param force boolean|nil # Render even when the selection has not moved.
--- @return nil
--
function Console:UpdateDetail(force)
    if not self.DetailVisible or not self.DetailMemo then return end
    local record = self.View and self.View:FocusedRecord() or nil
    -- Assigning TStrings.Text replaces the whole content and repaints the
    -- memo. Doing that every refresh would re-render a record nobody
    -- reselected.
    local seq = record and record.Seq or 0
    if not force and seq == self.DetailSeq then return end
    self.DetailSeq = seq
    if not record then
        pcall(function() self.DetailMemo.Lines.Text = "Select a record." end)
        return
    end
    local rows = {
        { "Time", Format.Stamp(record, { Date = true }) },
        { "Level", record.Level },
        { "Channel", record.Channel },
        record.Event and { "Event", record.Event } or false,
        (record.Repeats or 1) > 1 and { "Repeats", record.Repeats } or false,
        record.Dropped and { "Dropped after", record.Dropped } or false,
        record.Forced and { "Forced", "yes" } or false,
        record.Suppressed and { "Below level", "kept but not printed" } or false,
        record.Source and { "Source", record.Source } or false,
        { "Message", record.Message }
    }
    if record.Fields then
        rows[#rows + 1] = { "Fields", Format.Stringify(record.Fields) }
    end
    if record.Trace then
        rows[#rows + 1] = { "Traceback", record.Trace }
    end
    rows[#rows + 1] = { "JSON", Format.JsonRecord(record) }
    pcall(function()
        self.DetailMemo.Lines.Text = Format.Block(nil, rows, { Indent = "" })
    end)
end

function Console:CopySelection(mode)
    if not self.View then
        if self.Memo then clipboard(self.Memo.Lines.Text) end
        return
    end
    local records = self.View:SelectedRecords(true)
    if #records == 0 then return end
    clipboard(Format.Export(records, mode or "text"))
    self:Flash(string.format("%d record%s copied", #records, #records == 1 and "" or "s"))
end

function Console:TogglePin()
    if not self.View then return end
    local records = self.View:SelectedRecords()
    if #records == 0 then return end
    -- One decision for the whole selection. If anything is unpinned, pin
    -- everything. Toggling each row on its own makes a multi-row action
    -- unpredictable.
    local anyUnpinned = false
    for _, record in ipairs(records) do
        if not record.Pinned then anyUnpinned = true break end
    end
    for _, record in ipairs(records) do record.Pinned = anyUnpinned end
    -- Pinning can change what a PinnedOnly filter shows, so the list is
    -- rebuilt rather than extended.
    self.NeedsFullRefresh = true
    self:Refresh(true)
end

function Console:FilterToChannel()
    local record = self.View and self.View:FocusedRecord()
    if not record then return end
    self.Filter.Channel = record.Channel
    self.ChannelSignature = nil   -- force the dropdown to re-select
    self.NeedsFullRefresh = true
    self:Refresh(true)
end

function Console:ClearFilters()
    self.Filter.MinRank = 0
    self.Filter.Channel = nil
    self.Filter.Search = nil
    self.SearchLower = nil
    safeSet(self.LevelCombo, "ItemIndex", 0)
    safeSet(self.ChannelCombo, "ItemIndex", 0)
    pcall(function() self.SearchEdit.Text = "" end)
    if self.View then self.View:SetSearch(nil) end
    self:Refresh(true)
end

function Console:ClearBuffer()
    self.Log:Clear()
    self.NeedsFullRefresh = true
    if self.View then self.View:ClearSelection() end
    self:Refresh(true)
end

function Console:ChangeFontSize(delta)
    if not self.View then return end
    self.View:SetFontSize(self.View.FontSize + delta)
    self:Refresh(true)
end

--------------------------------------------------------
--                     Log file                       --
--------------------------------------------------------

function Console:OpenLogFile()
    local status = self.Writer and self.Writer:Status()
    if status and status.Path then shell(status.Path) end
end

function Console:OpenLogFolder()
    local status = self.Writer and self.Writer:Status()
    if status and status.Directory then shell(status.Directory) end
end

function Console:RotateLog()
    if not self.Writer then return end
    self.Writer:Rotate()
    self:Flash("Log file rotated")
    self:UpdateStatus()
end

function Console:ClearLogFile()
    if not self.Writer then return end
    self.Writer:Clear()
    self:Flash("Log file cleared")
    self:UpdateStatus()
end

--------------------------------------------------------
--                       Export                       --
--------------------------------------------------------

--
--- ∑ Writes what is shown to a file. The format follows the extension the user
---   typed, so naming the file also picks between text, JSON lines, CSV and
---   Markdown.
--- @return nil
--
function Console:Export()
    local records = self.View and self.View:SelectedRecords(true)
        or self.Log:Snapshot(self.Filter)
    if not records or #records == 0 then
        self:Flash("Nothing to export")
        return
    end
    local suggestion = string.format("Manifold.Log.%s.log", os.date("%Y%m%d-%H%M%S"))
    local path = self:AskSavePath(suggestion)
    if not path then return end
    local mode = "text"
    local extension = path:match("%.([%w]+)$")
    if extension then
        extension = extension:lower()
        if extension == "jsonl" or extension == "json" then mode = "jsonl"
        elseif extension == "csv" then mode = "csv"
        elseif extension == "md" then mode = "markdown" end
    end
    local handle, err = io.open(path, "wb")
    if not handle then
        self:Flash("Could not write: " .. tostring(err))
        return
    end
    handle:write(Format.Export(records, mode))
    handle:close()
    self:Flash(string.format("%d records written as %s", #records, mode))
end

--
--- ∑ A save dialog, falling back to a themed prompt when Cheat Engine has
---   none. The default directory is the log folder.
--- @param suggestion string
--- @return string|nil
--
function Console:AskSavePath(suggestion)
    local create = rawget(_G, "createSaveDialog")
    local directory = self.Writer and self.Writer.Directory or nil
    if type(create) == "function" then
        local ok, dialog = pcall(create, self.Form)
        if ok and dialog then
            local path
            pcall(function()
                dialog.Title = "Export log"
                dialog.FileName = suggestion
                if directory then dialog.InitialDir = directory end
                dialog.Filter = "Log (*.log)|*.log|JSON lines (*.jsonl)|*.jsonl|" ..
                                "CSV (*.csv)|*.csv|Markdown (*.md)|*.md|All files (*.*)|*.*"
                dialog.DefaultExt = "log"
                if dialog.execute() then path = dialog.FileName end
            end)
            pcall(function() dialog.destroy() end)
            return path
        end
    end
    local fallback = (directory and (directory .. "/") or "") .. suggestion
    return self.Theme:AskText("Export log", "Write to:", fallback)
end

--------------------------------------------------------
--                    Diagnostics                     --
--------------------------------------------------------

--
--- ∑ Logs the session counters as one record, so the report lands with
---   everything else and copies with it.
--- @return nil
--
function Console:ReportStats()
    local stats = self.Log:GetStats()
    local rows = {
        { "Buffered", string.format("%d of %d", stats.Buffered, stats.Capacity) },
        { "Emitted", stats.Total },
        { "Below level", stats.Suppressed },
        { "Collapsed repeats", stats.Deduped },
        { "Dropped (flood)", stats.Dropped },
        stats.Reentrant > 0 and { "Dropped (re-entrant)", stats.Reentrant } or false,
        ""
    }
    for _, level in ipairs(Core.Order) do
        local count = stats.ByLevel[level] or 0
        if count > 0 then rows[#rows + 1] = { level, count } end
    end
    rows[#rows + 1] = ""
    for _, name in ipairs(self.Log:ChannelNames()) do
        local count = stats.ByChannel[name] or 0
        if count > 0 then rows[#rows + 1] = { name, count } end
    end
    local writer = self.Writer and self.Writer:Status() or nil
    if writer then
        rows[#rows + 1] = ""
        rows[#rows + 1] = { "Log file", writer.Path or "(none)" }
        rows[#rows + 1] = { "File size", Format.Bytes(writer.Bytes) }
        if writer.Reason then rows[#rows + 1] = { "File error", writer.Reason } end
    end
    self.Log:ForceInfo(Format.Block("Session report", rows), nil)
    self:Refresh(true)
end

function Console:ReportIcons()
    if not self.Icons then return end
    local probe = self.Icons:Probe()
    local rows = {
        { "createPNG", probe.createPNG },
        { "createImageList", probe.createImageList },
        { "createBitmap", probe.createBitmap },
        { "Folder", probe.folder },
        { "Loaded", tostring(probe.loaded) },
        { "In list", probe.count },
        { "Composites", probe.composites },
        probe.reason and { "Reason", probe.reason } or false
    }
    if probe.missing and #probe.missing > 0 then
        rows[#rows + 1] = { "Missing", table.concat(probe.missing, ", ") }
    end
    rows[#rows + 1] = { "Surface", self.View and self.View.Kind or ("none: " .. tostring(self.SurfaceReason)) }
    self.Log:ForceInfo(Format.Block("Icon probe", rows), nil)
    self:Refresh(true)
end

--
--- ∑ One record per level. Checks a change to the palette, the icon set or the
---   row layout in one glance.
--- @return nil
--
function Console:EmitSamples()
    local channel = self.Log:Channel("Logger/Sample")
    channel:ForceTrace("Trace: the finest grain, off by default.")
    channel:ForceDebug("Debug: what the code was doing.")
    channel:ForceInfo("Info: what happened.", { sample = true, count = 1 })
    channel:ForceSuccess("Success: it worked.")
    channel:ForceWarning("Warning: it worked, but.")
    channel:ForceError("Error: it did not work.")
    channel:ForceCritical("Critical: nothing else will work either.")
    channel:ForceInfo(Format.Block("A block message", {
        { "Rows", "line up on their own" },
        { "Continuations", "hang under the label" },
        { "And", "stay one record" }
    }))
    self:Refresh(true)
end

function Console:About()
    local writer = self.Writer and self.Writer:Status() or nil
    local rows = {
        { "Version", Version.String() },
        { "Authors", Version.Authors() },
        { "Surface", self.View and self.View.Kind or "memo (no canvas)" },
        { "Buffer", string.format("%d of %d records", self.Log.RingCount, self.Log.Capacity) },
        { "Level", self.Log:GetLevelName() },
        { "Channels", table.concat(self.Log:ChannelNames(), ", ") },
        writer and { "Log file", writer.Path or "(none)" } or false,
        "",
        "A side-loadable log console. Any script can take a channel with",
        "ManifoldLogger:Channel('Name') and log into it; the window is optional."
    }
    self.Log:ForceInfo(Format.Block(Version.Full(), rows), nil)
    self:Refresh(true)
end

--
--- ∑ A short-lived message on the status line. The next refresh overwrites it,
---   which is the lifetime a confirmation wants.
--- @param message string
--- @return nil
--
function Console:Flash(message)
    safeSet(self.StatusLabel, "Caption", tostring(message))
end

--------------------------------------------------------
--                      Teardown                      --
--------------------------------------------------------

--
--- ∑ Drops every reference to the window.
--- @param orphaned boolean|nil # The form is already gone. The refresh timer
---        is created with the form as its OWNER, so the form's destructor has
---        already freed it. Disabling or destroying it here would be a
---        use-after-free.
--- @return nil
--
function Console:Release(orphaned)
    if self.Listener then
        self.Log:RemoveListener(self.Listener)
        self.Listener = nil
    end
    if self.Timer then
        if not orphaned then
            pcall(function() self.Timer.Enabled = false end)
            pcall(function() self.Timer.destroy() end)
        end
        self.Timer = nil
    end
    if self.View then self.View:Destroy() end
    -- The theme must not keep closures pointing at controls that are going
    -- away with the window.
    if self.Theme then self.Theme:Forget() end
    self.ThemeSource = false
    self.View, self.Memo, self.Form = nil, nil, nil
    self.Menu, self.DetailMemo, self.MenuButton = nil, nil, nil
    self.StatusLabel, self.StatusDetail = nil, nil
    self.DetailCard, self.DetailSplitter = nil, nil
    self.LevelCombo, self.ChannelCombo, self.SearchEdit = nil, nil, nil
    self.SetPausedButton, self.SetFollowButton, self.SetDetailButton = nil, nil, nil
    -- Everything below belongs to the generation that just went away. A
    -- surviving ChannelSignature is the subtle one. It would tell SyncChannels
    -- there is nothing to add to a dropdown holding only "All channels".
    self.ChannelSignature = nil
    self.Signature = nil
    self.ChannelList = {}
    self.Shown = {}
    self.ShownSeq = 0
    self.DetailSeq = nil
    self.NeedsFullRefresh = true
    self.PendingRefresh = true
    self.TickFailures = 0
end

--
--- ∑ Frees the window for good. The host calls this on a full reload, so no
---   form survives pointing at a dead generation of the module.
--- @return nil
--
function Console:Destroy()
    local form = self.Form
    self:Release(false)
    if form then pcall(function() form.destroy() end) end
end

return Console
