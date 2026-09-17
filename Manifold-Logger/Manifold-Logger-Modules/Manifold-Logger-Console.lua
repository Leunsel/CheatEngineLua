--[[
    The console window.

    Top to bottom it holds a toolbar, a filter row, the log card, the detail
    card under its splitter, and the status line. The toolbar is seven icon
    buttons in three groups at the left, the search field in whatever room
    they leave and the menu button at the right edge. The filter row holds the
    level choice, the channel choice and a button that clears all three
    filters. The detail card and its splitter stay hidden until somebody asks
    for them.

    Everything is aligned and nothing is placed by hand next to an aligned
    sibling. The LCL puts the LAST created alTop or alLeft control outermost
    and the FIRST created alBottom or alRight one, and a window built hidden is
    laid out in one pass with every sibling still standing at zero, so a tie
    is decided by the build order. The build order here follows that rule,
    and the two top bars and the status line are also given first positions
    far apart that say their order outright, see stackAt. A hidden control
    keeps the bounds it had, and an alBottom stack sorts by the far edge, so
    the detail card and its splitter are moved to the top edge whenever they
    are shown or resized. Their far edge is then their height and the status
    line stays below them.

    The least size is worked out and never written down. The width is what
    the toolbar and the filter row need with the search field showing its
    whole placeholder. The height is the bars, four log rows and three lines
    of the detail card, which is counted even while it is hidden, so showing
    it at the least height never makes anything overlap.

    Refresh is throttled. The log calls back on every record, but the callback
    only sets a flag. A timer turns the newest flag into one read of the log
    every RefreshInterval milliseconds, or into a repaint and a fresh detail
    card when a record already shown was only repeated. Pause stops that tick
    from taking new records into the view. It stops neither the recording nor
    the painting, so nothing is lost and the frame timer still paints what is
    shown. Resuming reads what arrived meanwhile, and so does every command
    that refreshes on purpose, F5, a new level, channel or search and the View
    options among them.

    Painting belongs to a second timer. A click, a wheel notch and a mouse
    move only mark the log view dirty, and the frame timer paints it within
    fifteen milliseconds. The same tick runs the theme's settle pass, which is
    what gives an owner drawn combo box its input colour after Windows first
    painted it black.

    The detail card takes its height from the log card. Showing or hiding it
    keeps the selected record on screen. A following log waits on that
    record with Follow still pressed, until the next record arrives or
    somebody scrolls.

    Closing hides the window. OnClose returns caHide, so the filter, the scroll
    position and the selection survive a close and reopen. Escape clears the
    search first, then the selection, and hides the window once there is
    nothing left to clear. The host frees the window explicitly when it is
    finished with it.

    Focus is tracked, not queried. KeyPreview is on so the view gets arrow keys
    and Ctrl+A, which would otherwise be swallowed. KeyPreview also takes every
    keystroke away from the search box, so the box reports its own focus
    through OnEnter and OnExit. Reading form.ActiveControl back and comparing
    it is not reliable, because two lookups of the same Cheat Engine object
    need not produce the same Lua value.

    Nothing in this file raises into Cheat Engine. A build that fails half way
    frees what it made and says so in the log, and every timer handler is
    guarded and stops itself after five failures in a row.
]]

local Core = require("Manifold-Logger-Core")
local Format = require("Manifold-Logger-Format")
local View = require("Manifold-Logger-View")
local Version = require("Manifold-Logger-Version")

local Console = {}
Console.__index = Console

--------------------------------------------------------
--                     Constants                      --
--------------------------------------------------------

Console.Defaults = {
    Width = 980,
    Height = 620,
    --- Milliseconds between two reads of the log while records arrive.
    RefreshInterval = 120,
    --- Windows rounds a timer up to its own 15.6 ms tick, so fifteen is the
    --- smallest honest frame interval and sixteen is a whole tick slower.
    FrameInterval = 15,
    --- The detail card's height until somebody drags its splitter.
    DetailHeight = 170,
    --- How long a flashed message holds the status line before the counts
    --- come back.
    FlashSeconds = 2.5,
    --- A timer whose handler failed this many times in a row stops, rather
    --- than reporting the same defect several times a second forever.
    MaxFailures = 5
}

--- Every virtual key the window answers, named so no branch reads as a
--- number nobody can look up.
Console.Keys = {
    Escape = 27, Pause = 19, F1 = 112, F5 = 116,
    A = 65, C = 67, F = 70, P = 80,
    Plus = 0xBB, Add = 0x6B, Minus = 0xBD, Subtract = 0x6D,
    Control = 0x11
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
--- ∑ The toolbar's buttons in reading order, left to right. A dash is a
---   separator. The buttons carry no caption, so the hint is where each one
---   says its name, and the theme adds the shortcut to it in brackets.
--
Console.Tools = {
    { Key = "Pause", Icon = "Pause", Shortcut = "Ctrl+P", Toggle = true,
      Hint = "Pause. Hold new records out of the view until you resume or refresh. Nothing is lost." },
    { Key = "Follow", Icon = "Follow", Shortcut = "End", Toggle = true,
      Hint = "Follow. Keep the newest record in view." },
    { Key = "Wrap", Icon = "WrapLongLines", Toggle = true,
      Hint = "Wrap. Wrap long lines instead of cutting them." },
    "-",
    { Key = "Copy", Icon = "Copy", Shortcut = "Ctrl+C",
      Hint = "Copy the selection, or everything shown." },
    { Key = "Export", Icon = "Export",
      Hint = "Export the selection, or everything shown, to a file. The extension picks the format." },
    { Key = "Clear", Icon = "Clear",
      Hint = "Clear the buffer. The counters and the log file are untouched." },
    "-",
    { Key = "Detail", Icon = "Detail", Toggle = true,
      Hint = "Detail. Show the whole record, its fields and its traceback." }
}

--- What each toolbar button does. A toggle is told its new state.
local TOOL_ACTIONS = {
    Pause = function(self, pressed) self:SetPaused(pressed) end,
    Follow = function(self, pressed) self:SetFollow(pressed) end,
    Wrap = function(self, pressed) self:SetWrap(pressed) end,
    Copy = function(self) self:CopySelection() end,
    Export = function(self) self:Export() end,
    Clear = function(self) self:ClearBuffer() end,
    Detail = function(self, pressed) self:SetDetailVisible(pressed) end
}

local Defaults = Console.Defaults
local Keys = Console.Keys

--- The toolbar's height and the height of every control on it, which leaves
--- six pixels above and below each one.
local TOOLBAR_HEIGHT, TOOL_HEIGHT = 40, 28

--- The filter row's height, and what it keeps clear of the toolbar above it.
local FILTER_HEIGHT, FILTER_TOP = 34, 2

--- What both bars keep clear of the window's sides.
local BAR_SIDE = 8

--- What a tool button keeps clear in front of itself, and what a field keeps
--- clear of the controls on either side of it.
local TOOL_GAP, FIELD_GAP = 4, 8

--- What the frame of a sizeable window takes off its width and its height at
--- 96 dpi. Eight pixels on each side, and the caption bar with the bottom
--- edge.
local FRAME_WIDTH, FRAME_HEIGHT = 16, 39

--- What the empty search field says. The field is never made narrower than
--- this text, so the hint in it can always be read whole, and it is short so
--- the window can be narrow.
local SEARCH_PLACEHOLDER = "search, any case"

--- The border of a field row and the pad inside it, on both sides together.
--- The theme's field row numbers, one pixel and six.
local FIELD_FRAME = 2 * (1 + 6)

--- What a field row keeps around its label text, the pad in front of it and
--- the gap behind it. The theme's field row numbers, six and six.
local FIELD_LABEL_CHROME = 6 + 6

--- What a closed combo box in a field row takes besides its text. Two pixels
--- of pad on each side of the text, and the twenty three pixels of rim and
--- arrow button Windows keeps around the item, less the three pixel rim the
--- row's clip hides on each side. The frame around the box comes on top.
local COMBO_CHROME = 2 * 2 + 23 - 2 * 3 + FIELD_FRAME

--- The labels in front of the two choices, and the first channel choice.
local LEVEL_LABEL, CHANNEL_LABEL = "Level", "Channel"
local ALL_CHANNELS = "All channels"

--- The space a card keeps around itself, and the splitter's height.
local CARD_GAP, SPLITTER_HEIGHT = 8, 5

--- A card's border, the height of its title strip, and the pad the log card
--- leaves around its canvas and the detail card around its memo.
local CARD_BORDER, CARD_HEADER, VIEW_PAD, DETAIL_PAD = 1, 24, 1, 6

--- Everything between the filter row and the status line that is neither of
--- the two cards. The space above the log card, the space under it, the
--- splitter, and the space above and under the detail card. Two aligned
--- neighbours are as far apart as the larger of their spacings, and the
--- splitter has none, so each gap is one card's spacing and never two.
local CARD_CHROME = 4 * CARD_GAP + SPLITTER_HEIGHT

--- The log card is this much taller than its canvas.
local VIEW_INSET = 2 * (CARD_BORDER + VIEW_PAD)

--- The fewest log rows and detail lines the least window height keeps.
local VIEW_MIN_ROWS, DETAIL_MIN_LINES = 4, 3

--- What the bars take when they cannot be measured, their spacing included.
--- The toolbar sits eight below the caption, the filter row two below the
--- toolbar, and the status line four above the bottom edge.
local TOOLBAR_STACK = 8 + TOOLBAR_HEIGHT
local FILTER_STACK = FILTER_TOP + FILTER_HEIGHT
local STATUS_STACK = 24 + 4

--- What the left half of the status line keeps clear of the right half, two
--- characters of the console font, and the share of the bar the right half
--- may take at most.
local STATUS_GAP, STATUS_RIGHT_SHARE = 14, 0.5

--- What stands between two counters in the right half of the status line.
local STATUS_SEPARATOR = "  |  "

--- What leads the left half of the status line while the log is paused, and
--- what stands between two parts of the left half.
local PAUSED_MARK, STATUS_JOIN = "PAUSED", "  -  "

--- How far apart stacked siblings are given their first position, so no two
--- of them can ever tie. The alignment moves each one to where it belongs,
--- so the number only decides the order, and a stack stays shorter than
--- STACK_SLOTS.
local STACK_STEP, STACK_SLOTS = 10000, 10

--- The channel internal failures are reported on.
local INTERNAL = "Logger/Internal"

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
        Timer   = nil,        -- the refresh tick
        FrameTimer = nil,     -- the paint tick
        Listener= nil,

        --- The toolbar's buttons by key, each as Panel, Enable, Press and
        --- Label, the shape the Address List window keeps.
        Buttons = {},
        ToolBar = nil, FilterBar = nil, MenuButton = nil, ClearButton = nil,
        SearchRow = nil, SearchEdit = nil, SearchParts = nil,
        LevelRow = nil, LevelCombo = nil, LevelParts = nil,
        ChannelRow = nil, ChannelCombo = nil, ChannelParts = nil,
        ViewCard = nil,
        DetailCard = nil, DetailContent = nil, DetailMemo = nil, DetailSplitter = nil,
        DetailCounter = nil, SetDetailCounter = nil,
        StatusBar = nil, StatusLabel = nil, StatusDetail = nil,

        --- What the toolbar and the filter row need across, measured when
        --- they were built.
        ToolBarNeed = 0,
        FilterBarNeed = 0,
        --- The detail height somebody asked for, which a low window takes
        --- away and a taller one gives back, and the height the last fit left.
        DetailWanted = nil,
        DetailFitted = nil,
        Fitting = false,

        Paused  = false,
        PendingRefresh = true,   -- a record arrived, re-read the log
        PendingRedraw = false,   -- nothing arrived, but the picture changed
        NeedsFullRefresh = true, -- the shown list cannot be extended, only rebuilt
        SearchFocused = false,
        --- True while the console writes the search field itself, so the
        --- change that write fires is not taken for typing.
        Quiet = false,
        DetailVisible = false,
        ExportMode = "text",

        --- The record whose first row a detail card toggle keeps on screen,
        --- until the next frame has placed it, and the record a following
        --- log is held on while Follow waits. See KeepInView.
        KeepSeq = nil,
        HeldSeq = nil,

        --- The status line. A flashed message while it lasts, then the hint of
        --- the row under the mouse, then the counts.
        FlashText = nil, FlashUntil = 0,
        HoverText = nil,
        StatusText = "",
        StatusRight = "",
        StatusRightParts = {},  -- the counters the right half is made of

        TickFailures = 0,
        FrameFailures = 0,
        FrameStopped = false,

        -- Rank zero is the "All" choice, so the level box and the filter agree
        -- from the start.
        Filter  = { MinRank = 0, Channel = nil, Search = nil },
        ThemeSource = false,      -- the design theme table the chrome was coloured from
        SearchLower = nil,        -- lowered once per change, not once per record
        Signature = nil,          -- the filter, as a string, to notice a change
        ChannelSignature = nil,   -- so the channel list is only rebuilt when it moved
        ChannelList = {},
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

--- One guarded property write. A control that was freed and a property this
--- Cheat Engine does not have both answer false instead of raising.
local function safeSet(control, property, value)
    if control == nil then return false end
    return (pcall(function() control[property] = value end))
end

--- One guarded property read. Nothing comes back when the read did not work.
local function safeGet(control, property)
    if control == nil then return nil end
    local ok, value = pcall(function() return control[property] end)
    if ok then return value end
    return nil
end

--- A whole number, or nothing when the value was never one.
local function integer(value)
    local number = tonumber(value)
    if number == nil or number ~= number then return nil end
    return math.tointeger(math.floor(number))
end

--- The plural s, so a count and its noun never disagree.
local function plural(count)
    return count == 1 and "" or "s"
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

--- Whether a key is held. The key events carry no shift state in Cheat
--- Engine, so this is the only way to ask.
local function held(key)
    local isKeyPressed = rawget(_G, "isKeyPressed")
    if type(isKeyPressed) ~= "function" then return false end
    local ok, down = pcall(isKeyPressed, key)
    return ok and down == true
end

--- Gives a control a minimum height through its constraints, which the LCL
--- honours in every alignment pass and a splitter reads before it moves.
local function setMinHeight(control, height)
    if control == nil then return false end
    return (pcall(function() control.Constraints.MinHeight = height end))
end

--- The same for the width.
local function setMinWidth(control, width)
    if control == nil then return false end
    return (pcall(function() control.Constraints.MinWidth = width end))
end

--- The space a control keeps on its left and on its right, Around included.
--- A control whose spacing cannot be read keeps none.
local function sideSpacing(control)
    local left, right = 0, 0
    pcall(function()
        local spacing = control.BorderSpacing
        local around = tonumber(spacing.Around) or 0
        left = (tonumber(spacing.Left) or 0) + around
        right = (tonumber(spacing.Right) or 0) + around
    end)
    return left, right
end

--- The same above and below.
local function endSpacing(control)
    local top, bottom = 0, 0
    pcall(function()
        local spacing = control.BorderSpacing
        local around = tonumber(spacing.Around) or 0
        top = (tonumber(spacing.Top) or 0) + around
        bottom = (tonumber(spacing.Bottom) or 0) + around
    end)
    return top, bottom
end

--- How much width a row of controls takes at most, each with its own spacing
--- on both sides. Two neighbours share the larger of their spacings, so the
--- real row is never wider than this.
local function rowWidth(controls)
    local total = 0
    for _, control in ipairs(controls) do
        local left, right = sideSpacing(control)
        total = total + left + (integer(safeGet(control, "Width")) or 0) + right
    end
    return total
end

--- How much height one bar takes with its spacing, or the fallback when the
--- bar is not there or cannot say.
local function stackHeight(control, fallback)
    local height = integer(safeGet(control, "Height"))
    if height == nil then return fallback end
    local top, bottom = endSpacing(control)
    return top + height + bottom
end

--
--- ∑ Gives an aligned control its place among the siblings that share its
---   alignment. Slot one is the outermost.
---
---   A control built hidden starts in its parent's corner, and siblings that
---   all start there are ordered by the LCL's tie break. A first position far
---   apart for each slot leaves the tie break nothing to decide. The
---   alignment then moves the control to where it belongs, so the number is
---   never seen. Once a control has been placed its real position counts, so
---   the slots are handed out outermost first, and a stack whose inner
---   member is hidden and shown later puts that member at the near edge when
---   it is shown, see StackDetail.
--- @param control userdata
--- @param align string # alTop or alBottom.
--- @param slot number # From one, below STACK_SLOTS.
--- @return boolean
--
local function stackAt(control, align, slot)
    if align == "alTop" then return safeSet(control, "Top", slot * STACK_STEP) end
    if align == "alBottom" then
        -- A bottom aligned control is ordered by its bottom edge, the larger
        -- one outermost.
        return safeSet(control, "Top", (STACK_SLOTS - slot) * STACK_STEP)
    end
    return false
end

--- Pixels per character and per line of the console font at one size, seven
--- and the rounded em and two when the theme cannot say.
local function metricsOf(theme, size)
    size = tonumber(size) or 10
    local charWidth, lineHeight = 0, 0
    if theme ~= nil and type(theme.TextMetrics) == "function" then
        local ok, width, height = pcall(theme.TextMetrics, theme, size)
        if ok then
            charWidth = tonumber(width) or 0
            lineHeight = tonumber(height) or 0
        end
    end
    if charWidth <= 0 then charWidth = 7 end
    if lineHeight <= 0 then lineHeight = math.floor(size * 96 / 72 + 0.5) + 2 end
    return charWidth, lineHeight
end

--- The size the theme draws its controls in.
local function themeFontSize(theme)
    return tonumber(theme and theme.FontSize) or 10
end

--------------------------------------------------------
--                       Window                       --
--------------------------------------------------------

--
--- ∑ Shows the console, building it on first use.
---
---   A new window is restyled after it is shown, because Cheat Engine
---   overwrites some colours when the handles are made, which for a window
---   built hidden is at show.
--- @return userdata|nil # The form, or nothing when it could not be built.
--
function Console:Open()
    if self.Form then
        local alive = pcall(function() self.Form.Visible = true end)
        if alive then
            pcall(function() self.Form.bringToFront() end)
            -- A theme may have been applied while the window was hidden.
            self:CheckTheme()
            self:Refresh(true)
            return self.Form
        end
        -- The form was destroyed outside our control. Fall through and
        -- rebuild instead of doing nothing.
        self:Release(true)
    end
    if self:Build() == nil then return nil end
    self:Refresh(true)
    if self.View then self.View:ScrollToEnd() end
    safeSet(self.Form, "Visible", true)
    if self.Theme ~= nil then pcall(self.Theme.Restyle, self.Theme) end
    if self.View then self.View:Invalidate() end
    return self.Form
end

--
--- ∑ Hides the window. The buffer, the log and every setting stay.
--- @return nil
--
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

--- Whether the form is on screen, as one guarded read and nothing else. The
--- frame timer asks this sixty times a second.
function Console:FormVisible()
    return safeGet(self.Form, "Visible") == true
end

--
--- ∑ Writes one record about the console itself. The log's dedup collapses a
---   repeat into a counter, so a defect that happens every tick is one line.
--- @param level string # Warning or Error.
--- @param message string
--- @return boolean
--
function Console:Report(level, message)
    local log = self.Log
    if log == nil then return false end
    return (pcall(function()
        local channel = log:Channel(INTERNAL)
        channel[level](channel, tostring(message))
    end))
end

--
--- ∑ Constructs the window and everything in it.
---
---   A failure half way frees what was built and says so, rather than leaving
---   a half built window behind for the next Open to show. The most likely
---   cause is a modules folder copied in part, where this file meets an older
---   theme.
--- @return userdata|nil # The form, or nothing when it could not be built.
--
function Console:Build()
    local theme = self.Theme
    if theme == nil then return nil end
    -- Nothing from a previous window may be re-coloured through this one.
    pcall(theme.Forget, theme)
    local caption = string.format("%s - %s", Version.Full(), self.Log.Name or "Manifold")
    -- EscCloses stays off. Escape clears the search and the selection first,
    -- so this window owns its own key handler. The least size is final once
    -- the bars are built, see HoldSize.
    local form = theme:CreateWindow(caption, Defaults.Width, Defaults.Height, {
        MinWidth = self:MinimumWidth(), MinHeight = self:MinimumHeight(),
        EscCloses = false
    })
    if form == nil then
        self:Report("Warning", "This Cheat Engine cannot make a window, so the console stays closed.")
        return nil
    end
    self.Form = form
    local ok, err = pcall(self.BuildParts, self, form)
    if ok then return form end
    self:Release(false)
    pcall(function() form.destroy() end)
    self:Report("Error", "The console could not be built, so it stays closed. " .. tostring(err)
        .. ". Copy the whole modules folder when updating the Logger.")
    return nil
end

--
--- ∑ Everything inside the form, in the one order the LCL allows.
---
---   alBottom puts the first created control outermost, so the status line
---   comes first, then the detail card and then its splitter. alTop puts the
---   last created one outermost, and the two bars carry their slots as well,
---   so the toolbar is handed slot one and built first and the filter row
---   slot two. The log card fills what is left.
--- @param form userdata
--- @return nil
--
function Console:BuildParts(form)
    local theme = self.Theme
    -- 1 status line, 2 detail card, 3 detail splitter.
    self:BuildStatusBar(form)
    self:BuildDetail(form)
    -- 4 toolbar, 5 filter row.
    self:BuildToolBar(form)
    self:BuildFilterBar(form)
    -- 6 log card.
    self:BuildView(form)
    self:HoldSize(form)
    self:BuildMenu()
    self:BuildKeys(form)

    self.ThemeSource = theme:Source()

    -- Live updates. The listener only sets a flag, the timer decides when that
    -- becomes a repaint. A new record has to be filtered and appended, a dedup
    -- update only changes a counter the record already carries, and a clear
    -- invalidates the shown list outright. Bridged producers can log from a
    -- worker thread, so nothing in here may touch a control.
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
    self:StartTimers(form)

    safeSet(form, "OnClose", function()
        -- Hide, do not free. See the file header. caHide is ordinal 1 in
        -- TCloseAction, which is what the fallback stands for.
        self:Close()
        return rawget(_G, "caHide") or 1
    end)
end

--
--- ∑ The status line. The left half is cut to its own width, so it is fitted
---   again whenever that width moves, which is the window resizing or the
---   right half taking more or less of the bar. It ends a gap short of the
---   right half, or a cut sentence would run straight into the counts.
--- @param form userdata
--- @return userdata # The bar.
--
function Console:BuildStatusBar(form)
    local theme = self.Theme
    self.StatusLabel, self.StatusBar, self.StatusDetail = theme:CreateStatusBar(form, "")
    stackAt(self.StatusBar, "alBottom", 1)
    pcall(function() self.StatusLabel.BorderSpacing.Right = STATUS_GAP end)
    local function fit() pcall(self.FitStatus, self) end
    safeSet(self.StatusLabel, "OnResize", fit)
    safeSet(self.StatusBar, "OnResize", fit)
    return self.StatusBar
end

--
--- ∑ The detail card and the splitter above it, both hidden. A hidden control
---   is left out of the alignment pass, so the log card gets their height
---   until somebody asks for the detail.
---
---   The splitter is created after the card and takes the same Align, which
---   is how the LCL pairs the two. The counter in the card's title strip says
---   which record is shown, fitted into the room the title leaves.
--- @param form userdata
--- @return userdata # The card.
--
function Console:BuildDetail(form)
    local theme = self.Theme
    local content, card, _, counter, setCounter = theme:CreateCard(form, {
        Align = "alBottom", Height = self.DetailWanted or Defaults.DetailHeight,
        Title = "Record", Counter = "", ContentPad = DETAIL_PAD
    })
    self.DetailContent, self.DetailCard = content, card
    self.DetailCounter, self.SetDetailCounter = counter, setCounter
    self.DetailMemo = theme:CreateMemo(content, { WordWrap = true, ScrollBars = "ssVertical" })
    self.DetailSplitter = theme:CreateSplitter(form, {
        Align = "alBottom", Height = SPLITTER_HEIGHT, MinSize = self:DetailMinHeight()
    })
    self.DetailVisible = false
    self.DetailFitted = nil
    safeSet(self.DetailSplitter, "Visible", false)
    safeSet(card, "Visible", false)
    return card
end

--
--- ∑ The toolbar. Seven icon buttons in three groups on the left, the menu
---   button at the right edge, and the search field in whatever room is left
---   between them.
---
---   The left group is built right to left, because alLeft puts the last
---   created control leftmost. Nothing writes a bound to a button after it is
---   built, which would move it to the front of that tie break.
---
---   The search field is alClient. It takes what the two stacks leave and
---   shrinks with the window, and the window's least width keeps that room at
---   least as wide as the placeholder, which the build measures here.
--- @param form userdata
--- @return userdata # The bar.
--
function Console:BuildToolBar(form)
    local theme = self.Theme
    local bar = theme:CreateToolBar(form, TOOLBAR_HEIGHT)
    self.ToolBar = bar
    stackAt(bar, "alTop", 1)
    local spare = TOOLBAR_HEIGHT - TOOL_HEIGHT
    local above, below = spare // 2, spare - spare // 2
    local placed = {}
    local pressed = {
        Pause = self.Paused == true, Follow = true, Wrap = false,
        Detail = self.DetailVisible == true
    }

    for index = #Console.Tools, 1, -1 do
        local tool = Console.Tools[index]
        if tool == "-" then
            placed[#placed + 1] = theme:CreateToolSeparator(bar)
        else
            local action = TOOL_ACTIONS[tool.Key]
            -- No Spacing, so the theme centres the button in the bar.
            local panel, enable, press, _, label = theme:CreateToolButton(bar, {
                Icon = tool.Icon, Align = "alLeft", Height = TOOL_HEIGHT,
                Hint = tool.Hint, Shortcut = tool.Shortcut,
                Toggle = tool.Toggle, Pressed = pressed[tool.Key],
                OnClick = function(state)
                    if action then action(self, state) end
                end
            })
            self.Buttons[tool.Key] = { Panel = panel, Enable = enable, Press = press, Label = label }
            placed[#placed + 1] = panel
        end
    end

    -- The one alRight control. It keeps as much space behind it as Pause
    -- keeps in front, so the bar looks the same at both ends.
    local menu = theme:CreateToolButton(bar, {
        Icon = "Settings", Align = "alRight", Height = TOOL_HEIGHT,
        Hint = "Menu. Everything else, which is also on right-click in the log.",
        Spacing = { Left = TOOL_GAP, Right = TOOL_GAP, Top = above, Bottom = below },
        OnClick = function() self:ShowMenu() end
    })
    self.MenuButton = menu
    placed[#placed + 1] = menu

    -- A field row with no label, so the search has the frame every other
    -- input here has and its text sits on the bar's middle line.
    local row, edit, _, parts = theme:CreateFieldRow(bar, {
        Kind = "edit", LabelWidth = 0, Align = "alClient", Height = TOOL_HEIGHT,
        ColorKey = "COLOR_PANEL",
        Placeholder = SEARCH_PLACEHOLDER,
        Hint = "Filter and highlight, plain text, any case. (Ctrl+F)",
        Spacing = { Left = FIELD_GAP, Right = FIELD_GAP, Top = above, Bottom = below },
        OnChange = function(text)
            if self.Quiet then return end
            self:SearchChanged(text)
        end
    })
    self.SearchRow, self.SearchEdit, self.SearchParts = row, edit, parts
    -- KeyPreview would otherwise route every keystroke to the view.
    safeSet(edit, "OnEnter", function() self.SearchFocused = true end)
    safeSet(edit, "OnExit", function() self.SearchFocused = false end)

    local barLeft, barRight = sideSpacing(bar)
    self.ToolBarNeed = barLeft + rowWidth(placed)
        + FIELD_GAP + self:SearchMinWidth() + FIELD_GAP + barRight
    return bar
end

--
--- ∑ The filter row under the toolbar. The level choice at the left, the
---   clear button at the right edge under the menu button, and the channel
---   choice between them.
---
---   Both choices are field rows, so their boxes are framed and drawn in the
---   input colours like the search field above them. The level row is as
---   wide as its label and its longest level need, and the channel row takes
---   the rest and never less than its label and the first choice need.
--- @param form userdata
--- @return userdata # The bar.
--
function Console:BuildFilterBar(form)
    local theme = self.Theme
    local bar = theme:CreatePanel(form, {
        Align = "alTop", Height = FILTER_HEIGHT, ColorKey = "COLOR_PANEL",
        Spacing = { Left = BAR_SIDE, Right = BAR_SIDE, Top = FILTER_TOP }
    })
    self.FilterBar = bar
    stackAt(bar, "alTop", 2)
    local spare = FILTER_HEIGHT - TOOL_HEIGHT
    local above, below = spare // 2, spare - spare // 2

    -- The only alRight child, with the menu button's spacing, so the two
    -- icons stand in one column.
    self.ClearButton = theme:CreateToolButton(bar, {
        Icon = "ClearFilters", Align = "alRight", Height = TOOL_HEIGHT,
        Hint = "Clear filters. Level, channel and search go back to showing everything.",
        Spacing = { Left = TOOL_GAP, Right = TOOL_GAP, Top = above, Bottom = below },
        OnClick = function() self:ClearFilters() end
    })

    local captions = {}
    for index, choice in ipairs(Console.LevelChoices) do captions[index] = choice.Caption end
    local levelLabel = self:LabelColumn(LEVEL_LABEL)
    -- The only alLeft child. It starts where Pause starts above it.
    local levelRow, levelCombo, _, levelParts = theme:CreateFieldRow(bar, {
        Kind = "combo", Label = LEVEL_LABEL, LabelWidth = levelLabel,
        Align = "alLeft", Width = levelLabel + self:ComboNeed(captions),
        Height = TOOL_HEIGHT, ColorKey = "COLOR_PANEL",
        Items = captions, ItemIndex = self:LevelIndex(self.Filter.MinRank),
        Hint = "Hide everything below this level. The records are kept either way.",
        Spacing = { Left = TOOL_GAP, Top = above, Bottom = below },
        OnChange = function(index) self:LevelChanged(index) end
    })
    self.LevelRow, self.LevelCombo, self.LevelParts = levelRow, levelCombo, levelParts

    local channelRow, channelCombo, _, channelParts = theme:CreateFieldRow(bar, {
        Kind = "combo", Label = CHANNEL_LABEL, LabelWidth = self:LabelColumn(CHANNEL_LABEL),
        Align = "alClient", Height = TOOL_HEIGHT, ColorKey = "COLOR_PANEL",
        Items = { ALL_CHANNELS }, ItemIndex = 0,
        Hint = "Show one producer only. Sub-channels of the choice are included.",
        Spacing = { Left = FIELD_GAP, Right = FIELD_GAP, Top = above, Bottom = below },
        OnChange = function(index) self:ChannelChanged(index) end
    })
    self.ChannelRow, self.ChannelCombo, self.ChannelParts = channelRow, channelCombo, channelParts
    setMinWidth(channelRow, self:ChannelMinWidth())
    self.ChannelList = {}
    -- The list was just made with its first choice only, so the next refresh
    -- has to fill it whatever the last window held.
    self.ChannelSignature = nil

    local barLeft, barRight = sideSpacing(bar)
    self.FilterBarNeed = barLeft + rowWidth({ levelRow, self.ClearButton })
        + FIELD_GAP + self:ChannelMinWidth() + FIELD_GAP + barRight
    return bar
end

--
--- ∑ The log card, which fills what the bars and the detail card leave, and
---   the canvas view inside it. A Cheat Engine without a canvas gets a themed
---   memo instead, which shows the log in one colour.
--- @param form userdata
--- @return userdata # The card.
--
function Console:BuildView(form)
    local theme = self.Theme
    local content, card = theme:CreateCard(form, { Align = "alClient", ContentPad = VIEW_PAD })
    self.ViewCard = card

    local view = View:New({ Theme = theme, Icons = self.Icons, Meta = Core.Meta })
    local ok, reason = view:Attach(content)
    if not ok then
        -- No canvas on this Cheat Engine build. A themed memo still shows the
        -- log, it just cannot colour it or draw the icons.
        self.View = nil
        self.Memo = theme:CreateMemo(content)
        self.SurfaceReason = reason
        return card
    end
    self.View = view
    -- Whatever changes Follow in the view, End or a scroll that reached the
    -- newest row, also ends a wait KeepInView started.
    view.OnFollowChanged = function(value)
        self.HeldSeq = nil
        self:PressTool("Follow", value)
    end
    view.OnSelectionChanged = function()
        self:UpdateDetail()
        self:UpdateStatus()
    end
    view.OnActivate = function() self:SetDetailVisible(true) end
    -- The row under the mouse says what it hides, on the status line.
    view.OnHint = function(text) self:ShowHover(text) end
    -- No OnContextMenu on purpose. The right button selects the row under the
    -- cursor and the LCL shows the attached menu itself. Popping it by hand as
    -- well would show it twice. See BuildMenu.

    -- A paint failure becomes a record on its own channel. The log's dedup
    -- collapses repeats into one line with a counter, and the view stops
    -- painting after five failures in a row.
    view.OnError = function(message)
        self:Report("Error", message)
    end
    return card
end

--------------------------------------------------------
--                    The window size                 --
--------------------------------------------------------

--
--- ∑ Holds the window at its least size and keeps the detail card fitted.
---
---   The form cannot be made smaller than MinimumWidth and MinimumHeight, and
---   both cards carry their own least height as a constraint, which the LCL
---   splitter reads when it works out how far a drag may go. The detail card
---   is fitted into the room the log card's least height leaves whenever the
---   window changes size and whenever a drag ends.
--- @param form userdata
--- @return number, number # The least width and height.
--
function Console:HoldSize(form)
    local width, height = self:MinimumWidth(), self:MinimumHeight()
    pcall(function()
        local constraints = form.Constraints
        constraints.MinWidth = width
        constraints.MinHeight = height
    end)
    local current = integer(safeGet(form, "Width"))
    if current ~= nil and current < width then safeSet(form, "Width", width) end
    current = integer(safeGet(form, "Height"))
    if current ~= nil and current < height then safeSet(form, "Height", height) end
    setMinHeight(self.ViewCard, self:ViewCardMinHeight())
    setMinHeight(self.DetailCard, self:DetailMinHeight())

    local function fit() pcall(self.FitDetail, self) end
    safeSet(form, "OnResize", fit)
    -- OnMoved comes once the mouse is let go. With rsUpdate the card already
    -- followed the drag, so this only takes note of the height it was given.
    safeSet(self.DetailSplitter, "OnMoved", fit)
    return width, height
end

--
--- ∑ The least the window may be across. What the toolbar or the filter row
---   needs, whichever is wider, and the frame. Both were measured from their
---   controls when they were built, so a wider button or a longer label moves
---   this with it.
--- @return number
--
function Console:MinimumWidth()
    local content = math.max(tonumber(self.ToolBarNeed) or 0, tonumber(self.FilterBarNeed) or 0)
    return content + FRAME_WIDTH
end

--
--- ∑ The least the window may be high. The frame, the two bars and the status
---   line, both cards at their least and what stands between them. The detail
---   card is counted while it is hidden, so showing it never makes the log
---   card smaller than its own least.
--- @return number
--
function Console:MinimumHeight()
    return FRAME_HEIGHT + self:BarsHeight() + CARD_CHROME
        + self:ViewCardMinHeight() + self:DetailMinHeight()
end

--- What the toolbar, the filter row and the status line take, their spacing
--- included, measured from the bars once they exist.
function Console:BarsHeight()
    return stackHeight(self.ToolBar, TOOLBAR_STACK)
        + stackHeight(self.FilterBar, FILTER_STACK)
        + stackHeight(self.StatusBar, STATUS_STACK)
end

--
--- ∑ The height of one log row. The view's own rule, one line and four
---   pixels and never less than an icon and two, taken at the size a new
---   view starts at, which is the size the window is built for.
--- @return number
--
function Console:RowHeight()
    local _, lineHeight = metricsOf(self.Theme, View.Defaults.FontSize)
    return math.max(View.Defaults.IconSize + 2, lineHeight + 4)
end

--- The log card's least height, four rows and the card around them.
function Console:ViewCardMinHeight()
    return VIEW_MIN_ROWS * self:RowHeight() + VIEW_INSET
end

--- The detail card's least height, three lines of the memo with the pad, the
--- title strip and the border around them.
function Console:DetailMinHeight()
    local _, lineHeight = metricsOf(self.Theme, themeFontSize(self.Theme))
    return 2 * CARD_BORDER + CARD_HEADER + 2 * DETAIL_PAD + DETAIL_MIN_LINES * lineHeight
end

--- How wide a text is in the console font. Every text measured here is plain
--- ASCII, so its length in bytes is its length.
function Console:TextWidth(text)
    local charWidth = metricsOf(self.Theme, themeFontSize(self.Theme))
    return math.ceil(#tostring(text or "") * charWidth)
end

--- The narrowest the search field may get, its placeholder whole and the
--- frame around it.
function Console:SearchMinWidth()
    return self:TextWidth(SEARCH_PLACEHOLDER) + FIELD_FRAME
end

--- A label column as wide as its label needs, with the field row's pad in
--- front and its gap behind.
function Console:LabelColumn(label)
    return self:TextWidth(label) + FIELD_LABEL_CHROME
end

--- How wide a combo box field needs to be, its label column left out, for
--- the longest of its items to show whole in the closed box.
function Console:ComboNeed(items)
    local widest = 0
    for _, item in ipairs(items or {}) do
        widest = math.max(widest, self:TextWidth(item))
    end
    return widest + COMBO_CHROME
end

--- The narrowest the channel row may get, its label and its first choice
--- whole.
function Console:ChannelMinWidth()
    return self:LabelColumn(CHANNEL_LABEL) + self:ComboNeed({ ALL_CHANNELS })
end

--
--- ∑ The tallest the detail card may be right now, which is the window's
---   client height less everything that is not the detail card, the log
---   card's least height included.
--- @return number|nil # Nothing while the window cannot say how high it is.
--
function Console:DetailRoom()
    local form = self.Form
    if form == nil then return nil end
    local client = integer(safeGet(form, "ClientHeight"))
    if client == nil or client <= 0 then
        local height = integer(safeGet(form, "Height"))
        if height == nil then return nil end
        client = height - FRAME_HEIGHT
    end
    if client <= 0 then return nil end
    return client - self:BarsHeight() - CARD_CHROME - self:ViewCardMinHeight()
end

--
--- ∑ Moves the detail card and its splitter to the top edge of the window.
---
---   A bottom aligned control is ordered by its bottom edge, and a hidden one
---   keeps the bounds it had, so a card shown after the window shrank could
---   sort below the status line. At the top edge the card's bottom is its
---   height, which is less than the room the window has, and the splitter's
---   is its own five pixels, which is less than the card's. The alignment
---   moves both back at once, so the position is never seen.
--- @return nil
--
function Console:StackDetail()
    safeSet(self.DetailCard, "Top", 0)
    safeSet(self.DetailSplitter, "Top", 0)
end

--
--- ∑ Fits the detail card into the room the log card's least height leaves.
---
---   The card gets the height that was asked for, cut to the room there is
---   and never below its own least. A lower window takes height from the
---   card and a taller one gives it back up to what was asked for. A height
---   that differs from the one the last fit left was set by a drag, and that
---   becomes the wish from then on.
---
---   The height is written before the position. Writing the height realigns
---   the window at once, and a card that grew can stand below the status line
---   for that moment, which the position written after it puts right.
--- @return number|nil # The card's height now, or nothing while it is hidden.
--
function Console:FitDetail()
    local card = self.DetailCard
    if card == nil or self.Fitting or not self.DetailVisible then return nil end
    local current = integer(safeGet(card, "Height"))
    if current == nil then return nil end
    local floor = self:DetailMinHeight()
    local room = self:DetailRoom()
    local dragged = self.DetailFitted ~= nil and current ~= self.DetailFitted
    local wanted = current
    if not dragged and self.DetailWanted ~= nil then wanted = self.DetailWanted end
    if dragged and room ~= nil then wanted = math.min(wanted, room) end
    wanted = math.max(floor, wanted)
    self.DetailWanted = wanted
    local target = wanted
    if room ~= nil then target = math.max(floor, math.min(wanted, room)) end
    self.DetailFitted = target
    if target ~= current then
        self.Fitting = true
        safeSet(card, "Height", target)
        self:StackDetail()
        self.Fitting = false
    end
    return target
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
---   itself, and doing both would show it twice. The toolbar's menu button is
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
        -- Wrap is on the toolbar as well, so it goes through SetWrap, which
        -- keeps the button and this check in step.
        option("Wrap Long Lines", "opt_wrap", "Wrap",
            function() return self.View and self.View.Wrap end,
            function(value) self:SetWrap(value) end)
        menu.Add("-", nil, { Parent = viewItem })
        -- Spelled into the caption instead of set as a Shortcut property. The
        -- LCL renders a popup menu's shortcuts but never dispatches them, so
        -- the accelerator would look real and do nothing. HandleKey
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

    -- The menu button gets the same menu attached, so it works by right-click
    -- even on a build where PopUp cannot be called from Lua.
    if self.MenuButton then menu.Attach(self.MenuButton) end
end

--
--- ∑ Pops the menu up at the cursor, for the toolbar's menu button. PopUp
---   wants SCREEN coordinates and getMousePos returns those, but no script
---   shipping with Cheat Engine uses it, so it counts as optional. Without it
---   the menu lands at the window's own corner, wrong but visible, rather
---   than at the top left of the desktop.
--- @return boolean # Whether the menu was popped up.
--
function Console:ShowMenu()
    if not self.Menu then return false end
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
    if pcall(function() self.Menu.Menu.popup(x, y) end) then return true end
    -- No PopUp binding on this Cheat Engine. Say so where the person is
    -- looking, and in the log, rather than look like a dead button.
    local sentence = "This Cheat Engine cannot open a menu from a button. "
        .. "Right-click the log, or right-click the menu button."
    self:Flash(sentence)
    self:Report("Warning", sentence)
    return false
end

--------------------------------------------------------
--                      Keyboard                      --
--------------------------------------------------------

--
--- ∑ Installs the window's key handler. Cheat Engine's OnKeyDown binding takes
---   the RETURN VALUE as the new key, which is how the LCL's var Key is
---   exposed. Return 0 to swallow a key, return it unchanged to let it reach
---   the focused control. HandleKey reports whether it consumed the key, so
---   that answer decides.
--- @param form userdata
--- @return boolean
--
function Console:BuildKeys(form)
    return (pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(_, key)
            if self:HandleKey(key) then return 0 end
            return key
        end
    end))
end

--
--- ∑ The window's key table.
---
---   Ctrl+F and Escape work from anywhere. Everything else belongs to the
---   search field while it has focus, otherwise Ctrl+A and the arrow keys
---   never reach it, and to the log view when it does not.
--- @param key number # A virtual key code.
--- @return boolean # Whether the key was consumed.
--
function Console:HandleKey(key)
    local control = held(Keys.Control)
    if control and key == Keys.F then
        self:FocusSearch()
        return true
    end
    if key == Keys.Escape then return self:Escape() end
    if self.SearchFocused then return false end
    if control and key == Keys.C then
        self:CopySelection()
        return true
    end
    -- The plus and minus keys on the main row and on the numeric keypad.
    if control and (key == Keys.Plus or key == Keys.Add) then
        self:ChangeFontSize(1)
        return true
    end
    if control and (key == Keys.Minus or key == Keys.Subtract) then
        self:ChangeFontSize(-1)
        return true
    end
    if key == Keys.F5 then
        self:Refresh(true)
        return true
    end
    if key == Keys.F1 then
        self:About()
        return true
    end
    if key == Keys.Pause or (control and key == Keys.P) then
        self:SetPaused(not self.Paused)
        return true
    end
    if self.View then return self.View:HandleKey(key) == true end
    return false
end

--
--- ∑ What Escape does, in the order a person expects it.
---
---   The search first, because that is what is most likely in the way, then
---   the selection. Only when there is nothing left to put away does it hide
---   the window. An empty search field that has the focus hands the key back,
---   so an Escape meant for the field never hides the window.
--- @return boolean # Whether Escape was used for something.
--
function Console:Escape()
    local text = safeGet(self.SearchEdit, "Text")
    if (type(text) == "string" and text ~= "") or self.Filter.Search ~= nil then
        self:ClearSearch()
        return true
    end
    local view = self.View
    if view ~= nil and view:HasSelection() then
        view:ClearSelection()
        return true
    end
    if self.SearchFocused then return false end
    self:Close()
    return true
end

--- Puts the keyboard into the search field.
function Console:FocusSearch()
    return (pcall(function() self.SearchEdit.setFocus() end))
end

--------------------------------------------------------
--                       Refresh                      --
--------------------------------------------------------

--
--- ∑ The two timers. The refresh tick reads the log, the frame tick paints.
---   Both are owned by the form, so the form's destructor frees them.
--- @param form userdata
--- @return boolean # Whether this Cheat Engine has timers at all.
--
function Console:StartTimers(form)
    local create = rawget(_G, "createTimer")
    if type(create) ~= "function" then return false end
    local okRefresh, timer = pcall(create, form)
    if okRefresh and timer then
        self.Timer = timer
        safeSet(timer, "Interval", Defaults.RefreshInterval)
        safeSet(timer, "OnTimer", function() self:Tick() end)
        safeSet(timer, "Enabled", true)
    end
    local okFrame, frame = pcall(create, form)
    if okFrame and frame then
        self.FrameTimer = frame
        self.FrameStopped = false
        safeSet(frame, "Interval", Defaults.FrameInterval)
        safeSet(frame, "OnTimer", function() self:FrameTick() end)
        safeSet(frame, "Enabled", true)
    end
    return true
end

--- Whether the frame timer is there to paint, so the refresh tick can leave
--- a repaint to it.
function Console:FramePainting()
    return self.FrameTimer ~= nil and not self.FrameStopped
end

--
--- ∑ One refresh. Cheap when nothing changed, the common case. A window left
---   open on an idle table costs one comparison every 120 ms.
--- @return nil
--
function Console:Tick()
    if not self:IsOpen() then return end
    -- Guarded as a whole. An unhandled error in a timer callback is printed
    -- by Cheat Engine at the timer's rate, eight lines a second, forever.
    local ok, err = pcall(function()
        -- The theme check sits BEFORE the pause guard. Pausing stops the log
        -- from moving, it does not mean the window may be the wrong colour. A
        -- theme switched while paused would otherwise leave the window half
        -- themed until somebody resumed it. Nothing here resumes the log,
        -- CheckTheme repaints the records already shown and never refreshes.
        self:CheckTheme()
        -- Without a frame timer the settle pass runs here instead.
        if not self:FramePainting() and self.Theme ~= nil
            and type(self.Theme.Settle) == "function" then
            self.Theme:Settle()
        end
        -- A flashed message has to run out even while the log stands still.
        if self.FlashText ~= nil then self:FitStatus() end
        if self.Paused then return end
        local view = self.View
        if self.PendingRefresh then
            -- Refresh lowers both flags itself.
            self:Refresh(false)
        elseif self.PendingRedraw or (view and view.Dirty) then
            local repeated = self.PendingRedraw
            self.PendingRedraw = false
            if view then
                if self:FramePainting() then
                    view:Invalidate()
                else
                    self:PlaceView()
                    view:Redraw()
                end
            end
            -- A repeat or a drop changed a record that is already shown, and
            -- the detail card may be showing it. Its key notices when the
            -- count moved, so any other record costs one comparison.
            if repeated then self:UpdateDetail() end
        end
    end)
    if ok then
        self.TickFailures = 0
        return
    end
    self.TickFailures = (self.TickFailures or 0) + 1
    self:Report("Error", "Refresh failed: " .. tostring(err))
    if self.TickFailures >= Defaults.MaxFailures then
        pcall(function() self.Timer.Enabled = false end)
        self:Report("Error", "Live refresh stopped after five consecutive failures. F5 still works.")
    end
end

--
--- ∑ One frame, on the frame timer. The settle pass, then a repaint of the
---   log view when something asked for one. Nothing at all while the window
---   is hidden.
--- @return boolean # Whether the view painted.
--
function Console:FrameTick()
    if not self:FormVisible() then return false end
    local ok, painted = pcall(self.PaintFrame, self)
    if ok then
        self.FrameFailures = 0
        return painted == true
    end
    self.FrameFailures = (self.FrameFailures or 0) + 1
    self:Report("Error", "A frame failed. " .. tostring(painted))
    if self.FrameFailures >= Defaults.MaxFailures then
        self.FrameStopped = true
        pcall(function() self.FrameTimer.Enabled = false end)
        self:Report("Error", "Painting on the frame timer stopped after five consecutive failures. "
            .. "The refresh tick paints instead.")
    end
    return false
end

--- The body of a frame, unguarded. FrameTick guards it.
function Console:PaintFrame()
    local theme = self.Theme
    if theme ~= nil and type(theme.Settle) == "function" then theme:Settle() end
    local view = self.View
    if view == nil then return false end
    self:PlaceView()
    return view:Flush() == true
end

--------------------------------------------------------
--               The selection in view                --
--------------------------------------------------------

--
--- ∑ What every paint does first. A wait something else ended is let go,
---   then a detail card toggle is answered.
--- @return boolean # Whether the log was moved.
--
function Console:PlaceView()
    self:WatchHold()
    return self:KeepInView()
end

--
--- ∑ How many log rows the view holds at the height it has right now. The
---   detail card changes that height the moment it is shown or hidden, and
---   the view only measures it again when it paints.
--- @return number|nil # Nothing while the view has never been measured.
--
function Console:RowsThatFit()
    local view = self.View
    local metrics = view and view.Metrics
    if metrics == nil then return nil end
    local height = integer(safeGet(view.Surface, "Height"))
    local rowHeight = tonumber(metrics.RowHeight) or 0
    if height == nil or height <= 0 or rowHeight <= 0 then return nil end
    return View.Layout.Visible(height, rowHeight)
end

--
--- ∑ Notes the selected record before the detail card changes the log's
---   height, when its first row is on screen. The next paint keeps that row
---   on screen, see KeepInView. A second toggle before that paint keeps the
---   first note, which is what was on screen.
--- @return boolean # Whether a record is noted.
--
function Console:NoteSelection()
    if self.KeepSeq ~= nil then return true end
    local view = self.View
    if view == nil then return false end
    local record = view:SelectedRecord()
    if record == nil then return false end
    local top = integer(view.Top) or 1
    local last = math.min(view:RowCount(), top + view:VisibleRows() - 1)
    for row = top, last do
        local entry = view.Rows[row]
        if entry ~= nil and entry.First and entry.Record.Seq == record.Seq then
            self.KeepSeq = record.Seq
            return true
        end
    end
    return false
end

--
--- ∑ Puts the record a detail card toggle noted back on screen, now that the
---   log has its new height.
---
---   A following log shows its newest rows, so a card that takes height away
---   would push the noted record off the top. Following waits instead. The
---   record's first row goes to the top of the log and the Follow button
---   stays pressed. The next record that arrives ends the wait and the log
---   follows it, and so do End and a scroll to the newest row. Any other
---   scroll ends it and turns Follow off, see WatchHold. Records that arrived
---   and are not drawn yet win at once.
---
---   A log that does not follow scrolls as little as it takes.
--- @return boolean # Whether the log was moved.
--
function Console:KeepInView()
    local seq = self.KeepSeq
    local view = self.View
    if seq == nil or view == nil then return false end
    -- Rows about to be rebuilt number themselves anew, so the note waits for
    -- the paint after the one that rebuilds them.
    if view.RowsDirty then return false end
    self.KeepSeq = nil
    local visible = self:RowsThatFit()
    local head = view:RowOfSeq(seq)
    local entry = head and view.Rows[head]
    if visible == nil or entry == nil or entry.Record.Seq ~= seq then return false end

    if view.Follow or self.HeldSeq ~= nil then
        if head >= View.Layout.Bottom(visible, view:RowCount()) then
            -- Following shows it, so a wait has nothing left to do.
            self:ReleaseHold()
            return false
        end
        if view.PendingFrom ~= nil then return false end
        -- Straight onto the field, so the view tells nobody. The button stays
        -- pressed, because Follow is only waiting.
        view.Follow = false
        self.HeldSeq = seq
        view.Top = head
        view:Invalidate()
        return true
    end

    local top = integer(view.Top) or 1
    if head < top then
        view.Top = head
    elseif head > top + visible - 1 then
        view.Top = head - visible + 1
    else
        return false
    end
    view:Invalidate()
    return true
end

--
--- ∑ Ends a wait and follows again, which is what a new record does.
--- @return boolean # Whether there was a wait to end.
--
function Console:ReleaseHold()
    if self.HeldSeq == nil then return false end
    self.HeldSeq = nil
    local view = self.View
    if view ~= nil then view:SetFollow(true) end
    return true
end

--
--- ∑ Notices that something other than a new record moved a held log.
---
---   The view ended the wait itself when it follows again. A log whose top
---   row is still the held record's first row is still waiting. A held
---   record that is gone, cleared or filtered away, leaves nothing to wait
---   on, so the log follows again. Anything else was a scroll. One that
---   reached the newest row follows, the way the view's own scroll does, and
---   one that did not turns Follow off for real, so the log never jumps away
---   from somebody reading it.
--- @return boolean # Whether the wait ended.
--
function Console:WatchHold()
    local seq = self.HeldSeq
    if seq == nil then return false end
    local view = self.View
    if view == nil or view.Follow then
        self.HeldSeq = nil
        return true
    end
    local top = integer(view.Top) or 1
    local entry = view.Rows[top]
    if entry ~= nil and entry.First and entry.Record.Seq == seq then return false end
    local head = view:RowOfSeq(seq)
    local found = head ~= nil and view.Rows[head].Record.Seq == seq
    if not found or top >= View.Layout.Bottom(view:VisibleRows(), view:RowCount()) then
        return self:ReleaseHold()
    end
    self.HeldSeq = nil
    self:PressTool("Follow", false)
    return true
end

--
--- ∑ Notices that the Cheat Table's theme changed, and re-colours the window.
---   The canvas reads the palette when it paints, so without this it would
---   follow the new theme while every panel, button, label and box kept the
---   one it was built under.
---
---   The check is an identity comparison against forms.ActiveDesignTheme,
---   which the ApplyTheme of Manifold.Forms replaces with a fresh table on
---   every application. One table lookup per tick, not a palette copy.
--- @return boolean # Whether anything was re-coloured.
--
function Console:CheckTheme()
    local source = self.Theme:Source()
    if source == self.ThemeSource then return false end
    self.ThemeSource = source
    self.Theme:Restyle()
    if self.View then
        -- The view picks up the new palette itself and drops the composited
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
---
---   It paints at once rather than asking the frame timer. It runs on the
---   refresh tick or after a command, never inside a mouse move.
---
---   A refresh that runs answers whatever the listener asked for, so it
---   lowers both flags, and it lowers them before it reads the log. A record
---   that arrives while it runs raises them again for the next tick.
--- @param force boolean # Refresh even when paused. A filter change must show
---        immediately, or the controls look dead.
--- @return nil
--
function Console:Refresh(force)
    if not self.Form then return end
    if self.Paused and not force then return end
    self.PendingRefresh = false
    self.PendingRedraw = false
    self:SyncChannels()
    local signature = self:FilterSignature()
    local full = self.NeedsFullRefresh or signature ~= self.Signature
    self.Signature = signature
    self.NeedsFullRefresh = false

    local seen = tonumber(self.ShownSeq) or 0
    if full then self:RebuildShown() else self:ExtendShown() end
    -- A record newer than any read before that the filter shows is an
    -- arrival, and Follow never waits past one. A filter that shows more of
    -- the old records is none.
    local newest = self.Shown[#self.Shown]
    if newest ~= nil and (tonumber(newest.Seq) or 0) > seen then self:ReleaseHold() end

    if self.View then
        self.View:Sync(self.Shown, full)
        self:UpdateEmpty()
        self:PlaceView()
        self.View:Redraw()
    elseif self.Memo then
        pcall(function() self.Memo.Lines.Text = Format.Export(self.Shown, "text") end)
    end
    self:UpdateStatus()
    self:UpdateDetail()
end

--
--- ∑ Tells the view what to say when it has no rows. An empty buffer and a
---   filter that hides everything are different situations and get
---   different sentences.
--- @return boolean # Whether the view's text changed.
--
function Console:UpdateEmpty()
    local view = self.View
    if view == nil or type(view.SetEmpty) ~= "function" or #self.Shown > 0 then return false end
    local stats = self.Stats or {}
    if (stats.Total or 0) == 0 then
        return view:SetEmpty("No records yet",
            "Any script logs here through ManifoldLogger:Channel('Name').")
    end
    local hidden = stats.Hidden or 0
    local advice = self.Filter.Search ~= nil and "Esc empties the search."
        or "Clear filters shows them again."
    return view:SetEmpty("Nothing matches", string.format("%d record%s %s hidden by the filter. %s",
        hidden, plural(hidden), hidden == 1 and "is" or "are", advice))
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
    -- ForEach rather than Records, which allocates an array the size of the
    -- buffer before the filter has looked at anything.
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
---   selection each time a record arrived. Setting ItemIndex fires nothing, so
---   the filter is not touched by this.
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
        combo.Items.add(ALL_CHANNELS)
        for _, name in ipairs(names) do combo.Items.add(name) end
        local index = 0
        for position, name in ipairs(names) do
            if name == selected then index = position break end
        end
        combo.ItemIndex = index
    end)
end

--------------------------------------------------------
--                    The status line                 --
--------------------------------------------------------

--- The clock a flash is timed on, in seconds.
function Console:Now()
    local ticks = rawget(_G, "getTickCount")
    if type(ticks) == "function" then
        local ok, value = pcall(ticks)
        if ok and tonumber(value) then return tonumber(value) / 1000 end
    end
    return os.clock()
end

--
--- ∑ Holds one sentence on the status line for a couple of seconds.
---
---   It overrides the counts rather than sitting beside them, because the
---   counts are always true and a message is only worth reading right after
---   the thing it is about. The refresh tick lets it run out.
--- @param message string|nil
--- @return boolean
--
function Console:Flash(message)
    if message == nil or message == "" then return false end
    self.FlashText = tostring(message)
    self.FlashUntil = self:Now() + Defaults.FlashSeconds
    self:FitStatus()
    return true
end

--
--- ∑ The hint of the log row under the mouse, or nothing once the mouse left
---   it. A flashed message still wins while it lasts.
--- @param text string|nil
--- @return string # What the left half says in full now.
--
function Console:ShowHover(text)
    local wanted = nil
    if type(text) == "string" and text ~= "" then wanted = text end
    self.HoverText = wanted
    return self:FitStatus()
end

--
--- ∑ Which sentence the left half of the status line is for right now. A
---   flashed message while it lasts, then the hovered row's hint, then the
---   counts. A flash that ran out is let go here, so nothing else has to
---   remember to.
---
---   PAUSED leads the counts, and it leads a flash or a hint just the same.
---   Pausing lasts until somebody resumes, and a sentence that only lasts
---   while the mouse rests somewhere must not hide it. The theme cuts a
---   sentence at its end, so the marker in front survives the cut.
--- @return string
--
function Console:StatusWanted()
    local sentence = nil
    if self.FlashText ~= nil then
        if self:Now() < (self.FlashUntil or 0) then
            sentence = self.FlashText
        else
            self.FlashText = nil
        end
    end
    if sentence == nil then sentence = self.HoverText end
    if sentence == nil then return self.StatusText or "" end
    if self.Paused then return PAUSED_MARK .. STATUS_JOIN .. sentence end
    return sentence
end

--
--- ∑ Puts both halves of the status line on their labels, each cut to the
---   room it has with the whole sentence in the label's hint.
---
---   The right half is fitted first, because it takes its width out of the
---   bar and the left half is fitted into what is left. It gets what the left
---   half's whole text leaves, and never less than half the bar, so a long
---   sentence cannot push the counts out and short counts never cut a short
---   sentence. A label that does not know its width yet shows the whole text,
---   and the resize it gets once the window is laid out fits it.
--- @return string # What the left half says in full.
--
function Console:FitStatus()
    local theme = self.Theme
    local canFit = theme ~= nil and type(theme.FitText) == "function"
    local text = self:StatusWanted()
    self.StatusLeft = text
    local right = self.StatusRight or ""
    local detail = self.StatusDetail
    if detail ~= nil then
        local room = self:StatusRightRoom(text)
        local shown = self:RightPartsFor(room)
        -- The whole right half goes into the hint when counters were left out.
        local hint = shown ~= right and right or nil
        if not (canFit and room > 0 and pcall(theme.FitText, theme, detail, shown, room, hint)) then
            safeSet(detail, "Caption", right)
        end
    end

    local label = self.StatusLabel
    if label == nil then return text end
    local width = integer(safeGet(label, "Width"))
    if canFit and width ~= nil and width > 0
        and pcall(theme.FitText, theme, label, text, width) then
        return text
    end
    safeSet(label, "Caption", text)
    safeSet(label, "Hint", "")
    safeSet(label, "ShowHint", false)
    return text
end

--
--- ∑ How wide the right half of the status line may be. What the bar has
---   inside the two labels' spacing and the gap between them, less what the
---   left half's text needs, and never less than half the bar.
--- @param left string # The left half's whole text.
--- @return number # Pixels, or zero while the bar cannot say how wide it is.
--
function Console:StatusRightRoom(left)
    local barWidth = integer(safeGet(self.StatusBar, "Width"))
    if barWidth == nil or barWidth <= 0 then return 0 end
    local labelLeft = sideSpacing(self.StatusLabel)
    local _, detailRight = sideSpacing(self.StatusDetail)
    local inner = barWidth - labelLeft - STATUS_GAP - detailRight
    local half = math.floor(barWidth * STATUS_RIGHT_SHARE)
    return math.max(half, inner - self:TextWidth(left))
end

--
--- ∑ As many whole counters of the right half as fit a width, in their order,
---   with dots behind them when some were left out. A counter cut in half
---   says nothing, so the theme only cuts when not even the first one fits.
--- @param room number # Pixels.
--- @return string
--
function Console:RightPartsFor(room)
    local parts = self.StatusRightParts or {}
    local whole = table.concat(parts, STATUS_SEPARATOR)
    if room <= 0 or self:TextWidth(whole) <= room then return whole end
    for count = #parts - 1, 1, -1 do
        local candidate = table.concat(parts, STATUS_SEPARATOR, 1, count) .. STATUS_SEPARATOR .. "..."
        if self:TextWidth(candidate) <= room then return candidate end
    end
    return whole
end

--
--- ∑ The counts on both ends of the status line. PAUSED leads the left half,
---   so a cut never hides it.
--- @return string, string, table # The left half, the right half and the
---         counters the right half is made of.
--
function Console:StatusCounts()
    local stats = self.Stats or { Shown = 0, Total = 0, Hidden = 0 }
    local session = self.Log:GetStats()
    local parts = {}
    if self.Paused then parts[#parts + 1] = PAUSED_MARK end
    parts[#parts + 1] = string.format("%d of %d shown", stats.Shown or 0, stats.Total or 0)
    if (stats.Hidden or 0) > 0 then
        parts[#parts + 1] = string.format("%d hidden by filter", stats.Hidden)
    end
    if (session.Dropped or 0) > 0 then
        parts[#parts + 1] = string.format("%d dropped (flood)", session.Dropped)
    end
    if self.SurfaceReason then parts[#parts + 1] = "no canvas: " .. self.SurfaceReason end

    -- The right half carries the counters worth seeing at a glance, plus the
    -- state of the log file.
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
    return table.concat(parts, STATUS_JOIN), table.concat(counters, STATUS_SEPARATOR), counters
end

--
--- ∑ Writes the status line. The counts are always worked out and the right
---   half always shows its own. The left half shows them only when neither a
---   flashed message nor a hovered row's hint is holding it, and PAUSED
---   whatever holds it.
--- @return string, string # What the left half says in full, and the right half.
--
function Console:UpdateStatus()
    local left, right, counters = self:StatusCounts()
    self.StatusText = left
    self.StatusRight = right
    self.StatusRightParts = counters
    return self:FitStatus(), right
end

--------------------------------------------------------
--                       Actions                      --
--------------------------------------------------------

--- Shows a toggle button's state without clicking it.
function Console:PressTool(key, value)
    local parts = self.Buttons and self.Buttons[key]
    if parts == nil or type(parts.Press) ~= "function" then return false end
    return (pcall(parts.Press, value == true))
end

function Console:SetPaused(value)
    self.Paused = value == true
    self:PressTool("Pause", self.Paused)
    if not self.Paused then self:Refresh(true) end
    self:UpdateStatus()
end

--- Turns tail following on or off. The view tells the button back. Either
--- way a wait KeepInView started is over, because somebody decided.
function Console:SetFollow(value)
    self.HeldSeq = nil
    if self.View then
        self.View:SetFollow(value == true)
        self:PressTool("Follow", self.View.Follow)
    else
        self:PressTool("Follow", false)
    end
end

--
--- ∑ Turns wrapping on or off. The toolbar and the menu both reach this, so
---   it keeps the other one in step.
--- @param value boolean
--- @return boolean # Wrapping as it is now.
--
function Console:SetWrap(value)
    value = value == true
    if self.View then self.View:SetWrap(value) else value = false end
    self:PressTool("Wrap", value)
    if self.Menu and type(self.Menu.Check) == "function" then
        pcall(self.Menu.Check, "opt_wrap", value)
    end
    return value
end

--
--- ∑ Shows or hides the detail card.
---
---   A card shown after the window changed size is fitted first and moved to
---   the top edge with its splitter, see StackDetail, and it is shown before
---   the splitter. A splitter shown first would be placed right above the
---   status line and the card would then sort under it.
---
---   Showing or hiding the card changes the log's height, so the selected
---   record is noted first and the next paint keeps it on screen, see
---   KeepInView.
--- @param value boolean
--- @return nil
--
function Console:SetDetailVisible(value)
    value = value == true
    if value ~= (self.DetailVisible == true) then self:NoteSelection() end
    self.DetailVisible = value
    if value then
        self:FitDetail()
        self:StackDetail()
        safeSet(self.DetailCard, "Visible", true)
        safeSet(self.DetailSplitter, "Visible", true)
    else
        safeSet(self.DetailSplitter, "Visible", false)
        safeSet(self.DetailCard, "Visible", false)
    end
    self:PressTool("Detail", value)
    -- Forced, because the card was empty while hidden. An unchanged selection
    -- is no reason to leave it empty.
    if value then self:UpdateDetail(true) end
end

--
--- ∑ What the detail card's counter says about a record. Its level tag, its
---   channel, its time and its marks, so the record is known before the memo
---   is read.
--- @param record table|nil
--- @return string
--
function Console:DetailSummary(record)
    if record == nil then return "nothing selected" end
    local meta = Core.Meta[record.Level]
    local parts = {
        ((meta and meta.Tag) or tostring(record.Level or "")):gsub("%s+$", ""),
        tostring(record.Channel or ""),
        Format.Prepare(record).Stamp
    }
    if (record.Repeats or 1) > 1 then parts[#parts + 1] = "x" .. record.Repeats end
    if record.Dropped then parts[#parts + 1] = "+" .. record.Dropped .. " dropped" end
    return table.concat(parts, "  ")
end

--- Writes the detail card's counter, fitted when the card can fit it.
function Console:SetDetailSummary(text)
    self.DetailSummaryText = text
    if type(self.SetDetailCounter) == "function" and pcall(self.SetDetailCounter, text) then
        return true
    end
    return safeSet(self.DetailCounter, "Caption", text)
end

--
--- ∑ Renders the selected record in full. The line, every field, the
---   traceback if there is one, and the JSON form for pasting into an issue.
---
---   The selected record and not the one under the mouse, so the card stays
---   put while the mouse moves over rows that scroll past.
--- @param force boolean|nil # Render even when nothing moved.
--- @return nil
--
function Console:UpdateDetail(force)
    if not self.DetailVisible or not self.DetailMemo then return end
    local record = self.View and self.View:SelectedRecord() or nil
    -- Assigning TStrings.Text replaces the whole content and repaints the
    -- memo. Doing that every refresh would re-render a record nobody
    -- reselected. A repeat or a drop changes what the card says about the
    -- same record, so both are part of the key.
    local seq = record and record.Seq or 0
    local key = record and string.format("%d:%d:%s", seq, record.Repeats or 1,
        tostring(record.Dropped)) or "0"
    if not force and key == self.DetailKey then return end
    self.DetailSeq, self.DetailKey = seq, key
    self:SetDetailSummary(self:DetailSummary(record))
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
    self:Flash(string.format("%d record%s copied", #records, plural(#records)))
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

--- The index of a level choice, or of All when no choice has that rank.
function Console:LevelIndex(rank)
    for index, choice in ipairs(Console.LevelChoices) do
        if choice.Rank == rank then return index - 1 end
    end
    return 0
end

--- The level box moved. The field row hands over the new ItemIndex.
function Console:LevelChanged(index)
    local choice = Console.LevelChoices[(tonumber(index) or 0) + 1]
    self.Filter.MinRank = choice and choice.Rank or 0
    self:Refresh(true)
end

--- The channel box moved. Zero is every channel.
function Console:ChannelChanged(index)
    index = tonumber(index) or 0
    self.Filter.Channel = index > 0 and self.ChannelList[index] or nil
    self:Refresh(true)
end

--
--- ∑ The search text changed, by typing or by the console itself.
---
---   The filter is only flagged and the tick coalesces it. A search change
---   arrives per keystroke, and the refresh timer exists to stop each one
---   re-filtering the whole buffer. Paused, no tick refreshes, so the refresh
---   happens here instead.
--- @param text string|nil
--- @return nil
--
function Console:SearchChanged(text)
    text = type(text) == "string" and text or ""
    self.Filter.Search = (text ~= "" and text) or nil
    self.SearchLower = self.Filter.Search and self.Filter.Search:lower() or nil
    if self.View then self.View:SetSearch(text) end
    self.NeedsFullRefresh = true
    self.PendingRefresh = true
    if self.Paused then self:Refresh(true) end
end

--
--- ∑ Empties the search field and the search filter. Writing the field fires
---   its change handler in Cheat Engine, which is kept quiet here so the
---   search is dropped exactly once.
--- @return nil
--
function Console:ClearSearch()
    self.Quiet = true
    if self.SearchParts and type(self.SearchParts.Set) == "function" then
        pcall(self.SearchParts.Set, "")
    else
        safeSet(self.SearchEdit, "Text", "")
    end
    self.Quiet = false
    self:SearchChanged("")
end

function Console:ClearFilters()
    self.Filter.MinRank = 0
    self.Filter.Channel = nil
    -- Setting a combo box's ItemIndex fires nothing, so the refresh below is
    -- what applies the two.
    if self.LevelParts and type(self.LevelParts.Set) == "function" then
        pcall(self.LevelParts.Set, 0)
    else
        safeSet(self.LevelCombo, "ItemIndex", 0)
    end
    if self.ChannelParts and type(self.ChannelParts.Set) == "function" then
        pcall(self.ChannelParts.Set, 0)
    else
        safeSet(self.ChannelCombo, "ItemIndex", 0)
    end
    self:ClearSearch()
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
--- ∑ Writes the selection, or what is shown, to a file. The format follows the
---   extension the user typed, so naming the file also picks between text,
---   JSON lines, CSV and Markdown.
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
        self:Flash("Could not write " .. tostring(err))
        return
    end
    handle:write(Format.Export(records, mode))
    handle:close()
    self:Flash(string.format("%d record%s written as %s", #records, plural(#records), mode))
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
    return self.Theme:AskText("Export log", "Write to", fallback)
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
    rows[#rows + 1] = ""
    rows[#rows + 1] = { "Window", string.format("least %dx%d", self:MinimumWidth(), self:MinimumHeight()) }
    rows[#rows + 1] = { "Frame timer", self.FrameTimer == nil and "none"
        or (self.FrameStopped and "stopped" or "running") }
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
        "ManifoldLogger:Channel('Name') and log into it. The window is optional."
    }
    self.Log:ForceInfo(Format.Block(Version.Full(), rows), nil)
    self:Refresh(true)
end

--------------------------------------------------------
--                      Teardown                      --
--------------------------------------------------------

--
--- ∑ Drops every reference to the window.
--- @param orphaned boolean|nil # The form is already gone. Both timers are
---        created with the form as their OWNER, so the form's destructor has
---        already freed them. Disabling or destroying one here would be a
---        use-after-free.
--- @return nil
--
function Console:Release(orphaned)
    if self.Listener then
        self.Log:RemoveListener(self.Listener)
        self.Listener = nil
    end
    for _, name in ipairs({ "Timer", "FrameTimer" }) do
        local timer = self[name]
        if timer ~= nil then
            if not orphaned then
                pcall(function() timer.Enabled = false end)
                pcall(function() timer.destroy() end)
            end
            self[name] = nil
        end
    end
    if self.View then self.View:Destroy() end
    -- The theme must not keep closures pointing at controls that are going
    -- away with the window.
    if self.Theme then pcall(self.Theme.Forget, self.Theme) end
    self.ThemeSource = false
    self.View, self.Memo, self.Form = nil, nil, nil
    self.Menu, self.DetailMemo, self.MenuButton, self.ClearButton = nil, nil, nil, nil
    self.StatusLabel, self.StatusDetail, self.StatusBar = nil, nil, nil
    self.ToolBar, self.FilterBar, self.ViewCard = nil, nil, nil
    self.DetailCard, self.DetailContent, self.DetailSplitter = nil, nil, nil
    self.DetailCounter, self.SetDetailCounter = nil, nil
    self.LevelRow, self.LevelCombo, self.LevelParts = nil, nil, nil
    self.ChannelRow, self.ChannelCombo, self.ChannelParts = nil, nil, nil
    self.SearchRow, self.SearchEdit, self.SearchParts = nil, nil, nil
    self.Buttons = {}
    self.ToolBarNeed, self.FilterBarNeed = 0, 0
    self.DetailFitted, self.Fitting = nil, false
    self.DetailVisible = false
    self.KeepSeq, self.HeldSeq = nil, nil
    self.SearchFocused, self.Quiet = false, false
    self.FlashText, self.FlashUntil, self.HoverText = nil, 0, nil
    self.StatusText, self.StatusRight, self.StatusLeft = "", "", nil
    self.StatusRightParts = nil
    -- Everything below belongs to the generation that just went away. A
    -- surviving ChannelSignature is the subtle one. It would tell SyncChannels
    -- there is nothing to add to a dropdown holding only "All channels".
    self.ChannelSignature = nil
    self.Signature = nil
    self.ChannelList = {}
    self.Shown = {}
    self.ShownSeq = 0
    self.DetailSeq, self.DetailKey = nil, nil
    self.NeedsFullRefresh = true
    self.PendingRefresh = true
    self.TickFailures = 0
    self.FrameFailures, self.FrameStopped = 0, false
end

--
--- ∑ Frees the window for good. The host calls this on a full reload, so no
---   form survives pointing at a dead generation of the module. Both timers
---   are stopped before the form goes.
--- @return nil
--
function Console:Destroy()
    local form = self.Form
    self:Release(false)
    if form then pcall(function() form.destroy() end) end
end

return Console
