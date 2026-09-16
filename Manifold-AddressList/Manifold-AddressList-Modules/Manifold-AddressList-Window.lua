--[[
    The window controller. This is the file that makes the segment one thing.

    It owns the form, the two timers, the record tree, the results strip and the
    inspector, and it is the only place that writes to a record. Everything a
    page, the tree or a menu wants done arrives here as either a transaction or
    an act, and both of those go through one funnel that resolves records by id,
    applies them through one table of appliers, collects what failed and writes
    down what landed. Nothing else in the segment touches a memory record.

    Why it is shaped this way.
      * Cheat Engine has no event for a record that changed, so the window polls
        on a timer. A poll that reads everything every time would cost more than
        the window is worth on a table of four thousand records, so the structure
        walk, the detail re-read and the value read each run on their own
        schedule and the detail budget is measured and adapted every tick.
      * Ids start again from one in every Cheat Table. An undo held across a
        table change would write into unrelated records, so a snapshot that
        shares no record with the one before it drops the history, the problems,
        the results and the selection, and says so.
      * A modal runs a nested message loop and deactivating a group with
        moDeactivateChildrenAsWell pumps messages, so both timers can fire in the
        middle of an edit. Busy is a counter rather than a flag, because these
        nest, and both timers return at once while it is above zero.
      * A paint box and an image are graphic controls. They never take focus and
        they never see the mouse wheel, so the keyboard is routed by the pane
        that last got a mouse down on a canvas and the wheel handlers sit on the
        windowed parent. A mouse down on any canvas clears the form's active
        control first, so an open grid editor sees its own OnExit and commits or
        cancels before the click is answered.
      * Activating an Auto Assembler record runs its script with no dialog of
        Cheat Engine's own, so the one place that writes Active asks first. With
        Async on, the write returns before the script finished, so the ids that
        were still running are followed until Cheat Engine reports what happened.

    Two things here read as deviations and are deliberate. The appliers take the
    window as their first argument, because a table of plain functions cannot
    reach the records service otherwise, and an applier may answer a third value
    holding the extra changes Cheat Engine made of its own accord so undo can put
    those back too. An act cannot read an intention off a function, so the first
    word of its label is what says it activates something.

    Nothing in this file raises into Cheat Engine. Every touch is guarded and a
    defect costs the action and never the window.
]]

local Version = require("Manifold-AddressList-Version")
local RecordsModule = require("Manifold-AddressList-Records")
local SurfaceModule = require("Manifold-AddressList-Surface")
local TreeModule = require("Manifold-AddressList-Tree")
local ResultsModule = require("Manifold-AddressList-Results")
local GridModule = require("Manifold-AddressList-Grid")
local InspectorModule = require("Manifold-AddressList-Inspector")
local TypesModule = require("Manifold-AddressList-Types")

local Window = {}
Window.__index = Window

--------------------------------------------------------
--                     Constants                      --
--------------------------------------------------------

Window.Defaults = {
    --- Windows rounds a timer up to its own 15.6 ms tick, so fifteen is the
    --- smallest honest frame interval and sixteen is a whole tick slower.
    FrameInterval = 15,

    --- The window never opens lower than this. Its least width is not a
    --- number written here. It is worked out from the tree's minimum, the
    --- inspector's and the toolbar's, see MinimumWidth.
    MinHeight = 480,

    --- The tree's width when nothing was stored, and the least it gets when
    --- the settings cannot say. The settings hold a stored width to the same
    --- floor.
    TreeWidth = 540,
    TreeMinWidth = 320,

    --- What the frame of a sizeable window takes off its width at 96 dpi,
    --- eight pixels on each side.
    FrameWidth = 16,

    --- How long one sync tick may spend re-reading detail. Above this the
    --- budget halves, below half of it the budget grows again.
    DetailBudgetMs = 8,
    DetailStart = 64,
    DetailMin = 8,
    DetailMax = 400,
    DetailStep = 16,

    --- The structure walk runs every fourth tick while it stays under four
    --- milliseconds and every twentieth once it costs more than that.
    StructureCostMs = 4,
    StructureFast = 4,
    StructureSlow = 20,

    --- Values come from process memory, so they are read every other tick and
    --- only for the rows that are on screen.
    ValueEvery = 2,

    --- The palette is a table identity comparison, so asking four times a
    --- second would be free and asking once a second is still immediate.
    ThemeEvery = 4,

    --- A sync that failed this many times in a row turns live sync off rather
    --- than reporting the same defect four times a second forever.
    MaxSyncFailures = 5,

    --- A first load slower than this is worth saying out loud, because the
    --- window is unresponsive while it happens.
    SlowLoadMs = 150,

    --- How long a flashed message holds the status line before the ordinary
    --- counts come back.
    FlashSeconds = 2.5,

    --- How long an async script may run before the window stops following it.
    PendingSeconds = 30,

    --- A sync that takes longer than this is reported in the status line, so a
    --- table large enough to feel slow says why.
    SlowSyncMs = 20
}

--- Every virtual key this window answers, named so no branch reads as a
--- number nobody can look up.
Window.Keys = {
    Escape = 27, Enter = 13, Space = 32,
    F2 = 113, F5 = 116, F7 = 118,
    Up = 38, Down = 40,
    A = 65, C = 67, E = 69, F = 70, G = 71, H = 72, P = 80, Y = 89, Z = 90,
    One = 49, Five = 53,
    Plus = 0xBB, Add = 0x6B, Minus = 0xBD, Subtract = 0x6D,
    Control = 0x11, Shift = 0x10
}

--
--- ∑ The acts that run a record's script.
---
---   Act is handed a label, a list of ids and a function, and a function says
---   nothing about what it is about to write. The first word of the label is
---   what marks an act as an activation, which is why every caller inside this
---   window spells it one of these ways and the Properties page labels its
---   Active row with the property's own name.
--
Window.ActivationWords = { Active = true, Activate = true, Deactivate = true }

--- What the find bar can look through, in the order the box offers them.
Window.FindFields = {
    { Label = "Descriptions", Fields = { Description = true } },
    { Label = "Descriptions and scripts", Fields = { Description = true, Script = true } },
    { Label = "Scripts", Fields = { Script = true } },
    { Label = "Drop-down lists", Fields = { DropDown = true } },
    { Label = "Everything", Fields = { Description = true, Script = true, DropDown = true } }
}

--- Which records a find runs over. Visible means the rows the filter shows.
Window.FindScopes = { "All", "Visible", "Selection" }

--- The three strips the results card can hold.
Window.ResultKinds = { Problems = true, Matches = true, Changes = true }

local Defaults = Window.Defaults
local Keys = Window.Keys

--- The toolbar's height and the height of every control on it, which leaves
--- the same six pixels above and below each one.
local TOOLBAR_HEIGHT, TOOL_HEIGHT = 40, 28

--- What a toolbar button keeps clear in front of itself, and what the filter
--- keeps clear of the buttons on either side of it.
local TOOL_GAP, FILTER_GAP = 4, 8

--- What the empty filter shows. The filter is never made narrower than this
--- text, so the hint in it can always be read whole.
local FILTER_PLACEHOLDER = "filter, try is:script or type:aa"

--- The border of a field row and the pad inside it, on both sides together.
--- The theme's field row numbers, one pixel and six.
local FILTER_FRAME = 2 * (1 + 6)

--- The space a card keeps around itself, the splitter between the two cards,
--- and the pad a card leaves around its content.
local CARD_GAP, SPLITTER_WIDTH, CARD_PAD = 8, 5, 1

--- A card's body sits one pixel inside its border, so the content of a card is
--- this much narrower than the card on both sides together.
local CARD_INSET = 2 * (1 + CARD_PAD)

--- What the left half of the status line keeps clear of the right half, two
--- characters of the segment font.
local STATUS_GAP = 14

--- Everything across the window that is neither the tree nor the inspector.
--- The space in front of the tree, the space behind it, the splitter, and the
--- space in front of and behind the inspector. Two aligned neighbours are as
--- far apart as the larger of their spacings, and the splitter has none, so
--- each gap is one card's spacing and never two.
local PANE_CHROME = 4 * CARD_GAP + SPLITTER_WIDTH

--- The change list handed to the inspector on a tick where nothing it draws
--- moved. A page asks whether the changed ids name one of its records and
--- leaves itself alone when they do not, so an empty list is how a sync says
--- there is nothing to redraw. Nobody writes into it.
local NOTHING = {}

--------------------------------------------------------
--                   Guarded touches                  --
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

--- Calls one hook without letting a defect inside it reach the caller.
local function fire(hook, ...)
    if type(hook) ~= "function" then return nil end
    local ok, value = pcall(hook, ...)
    if ok then return value end
    return nil
end

--- One log line, or nothing at all when this window runs without a log.
local function say(self, level, message)
    local log = self and self.Log
    if log == nil then return false end
    local method = log[level]
    if type(method) ~= "function" then return false end
    return (pcall(method, log, message))
end

--- A whole number, or nothing when the value was never one.
local function integer(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.tointeger(math.floor(number))
end

--- The plural s, so a count and its noun never disagree.
local function s(count)
    return count == 1 and "" or "s"
end

--- A private copy of a list of ids.
local function copyIDs(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do out[#out + 1] = id end
    return out
end

--- A set out of a list of ids or out of a set of them, because both shapes
--- reach this window.
local function idSet(ids)
    local set = {}
    if type(ids) ~= "table" then return set end
    for _, id in ipairs(ids) do set[id] = true end
    for id, value in pairs(ids) do
        if value == true and type(id) == "number" then set[id] = true end
    end
    return set
end

--- Gives a control a minimum width through its constraints, which the LCL
--- honours in every alignment pass and a splitter reads before it moves.
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

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the controller. Nothing is created until Open, so a host can hold
---   a window through a whole session without one existing.
--- @param services table|nil # Theme, Icons, Log, Settings, CE, Types, Records,
---        Properties, Journal, Lint, Search, Export, Version and the classes
---        Surface, Tree, Results, Grid, Inspector and Pages.
--- @return table
--
function Window:New(services)
    services = services or {}
    local instance = setmetatable({
        Theme      = services.Theme,
        Icons      = services.Icons,
        Log        = services.Log,
        Settings   = services.Settings,
        CE         = services.CE,
        Types      = services.Types or TypesModule,
        Records    = services.Records,
        Properties = services.Properties,
        Journal    = services.Journal,
        Lint       = services.Lint,
        Search     = services.Search,
        Export     = services.Export,
        Version    = services.Version or Version,

        SurfaceClass   = services.Surface or SurfaceModule,
        TreeClass      = services.Tree or TreeModule,
        ResultsClass   = services.Results or ResultsModule,
        GridClass      = services.Grid or GridModule,
        InspectorClass = services.Inspector or InspectorModule,
        PageClasses    = services.Pages or {},

        -- The form and everything hanging off it. All nil until Build.
        Form = nil, Frame = nil, Tree = nil, Results = nil, Inspector = nil,
        StatusLabel = nil, StatusBar = nil, StatusDetail = nil,
        ToolBar = nil, FindBar = nil, FilterEdit = nil, FilterRow = nil, MenuButton = nil,
        FindEdit = nil, ReplaceEdit = nil, FieldCombo = nil, ScopeCombo = nil,
        SetCase = nil, GetCase = nil, SetWord = nil, GetWord = nil,
        TreeCard = nil, TreeContent = nil, TreeCounter = nil, TreeSplitter = nil,
        InspectorCard = nil, InspectorContent = nil, InspectorCounter = nil,
        ResultsCard = nil, ResultsContent = nil, ResultsCounter = nil,
        ResultsSplitter = nil,
        TreeMenu = nil, MainMenu = nil, ResultsMenu = nil,
        Buttons = {},            -- key to the panel and closures of a toolbar button
        FrameTimer = nil, SyncTimer = nil,

        --- What the toolbar needs across, measured when it was built.
        ToolBarNeed = 0,
        --- The tree width a person chose or the settings stored, which a
        --- narrow window takes away and a wider one gives back.
        TreeWanted = nil,
        --- The tree width the last fit left, which is how a width somebody
        --- else set is told apart from the one the fit set itself.
        TreeFitted = nil,
        Fitting = false,         -- true while the fit writes the tree width

        --- A counter and not a flag. A modal inside an act inside a commit is
        --- three levels deep and every one of them has to hold the timers off.
        Busy = 0,
        Ticks = 0,
        SyncFailures = 0,
        TickFailures = 0,
        Opened = false,
        Closing = false,

        Snapshot = nil,
        TableStamp = nil,
        Problems = nil,          -- what the last check reported, in order
        ProblemMap = nil,        -- id to the worst severity, nil until a check ran
        ResultKind = nil,
        Pending = {},            -- id to the async activation being followed
        Watched = {},            -- id to the live facts the inspector draws
        Hooked = {},             -- the surfaces whose mouse down is already wrapped

        Pane = "tree",           -- which canvas the keyboard belongs to
        TextFocus = false,       -- a text control the window owns holds focus
        Loading = false,         -- true while a control is filled in code

        --- The design theme table the chrome was coloured from. False and not
        --- nil, because nil is a legitimate source meaning no Cheat Table is
        --- loaded and the first check has to notice that too.
        ThemeSource = false,

        FlashText = nil,
        FlashUntil = 0,
        --- The hint of the inspector row under the mouse, or nothing. It has
        --- the left half of the status line while the mouse is on the row.
        HoverText = nil,
        --- The counts the left half says when nothing else is holding it.
        StatusText = "",
        --- What the left half says in full right now, whatever it was cut to.
        StatusLeft = "",
        StatusRight = "",

        DetailBudget = Defaults.DetailStart,
        StructureCost = 0,
        SyncCost = 0,
        LastSelection = {},
        LastFocus = nil,         -- where the keyboard sat on that selection
        Restoring = false,       -- true while the tree is put back after a Cancel
        MirroredID = nil,        -- the id this window last pushed into Cheat Engine
        FollowedID = nil         -- the id it last took from Cheat Engine
    }, Window)

    -- The journal is the host's, so it survives the window closing. This is
    -- the one place that teaches it how to write, which keeps the appliers
    -- the only writers in the segment.
    local journal = instance.Journal
    if journal ~= nil then
        journal.Apply = function(change, value)
            return instance:ApplyChange(change, value)
        end
    end
    return instance
end

--------------------------------------------------------
--                    The busy gate                   --
--------------------------------------------------------

--
--- ∑ Runs something that can pump messages, with the timers held off.
---
---   A modal runs a nested message loop and a deactivation with
---   moDeactivateChildrenAsWell calls ProcessMessages while it waits, so the
---   frame timer and the sync timer both fire in the middle. The counter is
---   what stops a sync from reading a half written record and what stops a
---   second commit from starting inside the first.
--- @param fn function
--- @return any ... # Whatever fn answered, or nothing when it raised.
--
function Window:Guard(fn)
    if type(fn) ~= "function" then return nil end
    self.Busy = self.Busy + 1
    local results = table.pack(pcall(fn))
    self.Busy = math.max(0, self.Busy - 1)
    if results[1] then return table.unpack(results, 2, results.n) end
    say(self, "Warning", "An action failed. " .. tostring(results[2]))
    return nil
end

--- Whether the timers should stand down right now.
function Window:IsBusy()
    return self.Busy > 0
end

--- Seconds, from Cheat Engine when it offers a clock and from Lua otherwise.
function Window:Now()
    local ce = self.CE
    if ce ~= nil and type(ce.Now) == "function" then
        local ok, value = pcall(ce.Now, ce)
        if ok and type(value) == "number" then return value end
    end
    return os.clock()
end

--------------------------------------------------------
--                    Opening it                      --
--------------------------------------------------------

--
--- ∑ Shows the window, building it on first use.
---
---   The first sync is a full one, so every record has its detail before the
---   first paint. A tree drawn from half loaded nodes shows blank descriptions
---   for a quarter of a second and looks broken.
--- @return boolean
--
function Window:Open()
    if self:IsOpen() then
        safeSet(self.Form, "Visible", true)
        pcall(function() self.Form.bringToFront() end)
        self:Sync(true)
        return true
    end
    if self.Form ~= nil then self:Release() end
    self:Build()
    if self.Form == nil then
        say(self, "Error", "The window could not be built, so nothing opened.")
        return false
    end
    self:Sync(true)
    safeSet(self.Form, "Visible", true)
    -- Cheat Engine overwrites some colours at handle creation, so the restyle
    -- happens after the first show and not before it.
    if self.Theme ~= nil then pcall(self.Theme.Restyle, self.Theme) end
    if self.Frame ~= nil then self.Frame:Invalidate() end
    self.Opened = true
    say(self, "Info", self.Version.Full() .. " opened with "
        .. (self.Snapshot and self.Snapshot.Count or 0) .. " records.")
    return true
end

--
--- ∑ Whether the window is on screen. A form destroyed from outside makes the
---   read raise, and then everything pointing at it is let go rather than kept
---   for a timer to find.
--- @return boolean
--
function Window:IsOpen()
    if self.Form == nil then return false end
    local ok, visible = pcall(function() return self.Form.Visible == true end)
    if not ok then
        self:Release()
        return false
    end
    return visible == true
end

--
--- ∑ Asks the window to close. The close gate can refuse, which is why this
---   answers whether it actually closed.
--- @return boolean
--
function Window:Close()
    if self.Form == nil then return true end
    pcall(function() self.Form.close() end)
    return self.Form == nil
end

--------------------------------------------------------
--                    Building it                     --
--------------------------------------------------------

--
--- ∑ Creates the form and everything in it, in the one order the LCL allows.
---
---   alTop and alLeft put the LAST created control outermost and alBottom and
---   alRight put the FIRST one outermost, so the order here is the order on
---   screen read from the edges inward. Getting it wrong does not look wrong in
---   the source at all, which is why the test asserts every edge.
--- @return userdata|nil # The form.
--
function Window:Build()
    local theme = self.Theme
    if theme == nil then return nil end
    -- Nothing from a previous window may be re-coloured through this one.
    pcall(theme.Forget, theme)

    local settings = self.Settings
    local width = settings and settings.Window and settings.Window.Width or 1180
    local height = settings and settings.Window and settings.Window.Height or 740
    local caption = "Manifold — Address List" .. "  ·  " .. self.Version.String()
    -- EscCloses stays off. Escape clears the filter first, then hides the find
    -- bar, and only closes the window when there is nothing else for it to do,
    -- so this window owns its own key handler. The least width is what the two
    -- panes need so far, and HoldPanes adds the toolbar once that is built.
    local form = theme:CreateWindow(caption, width, height, {
        MinWidth = self:MinimumWidth(), MinHeight = Defaults.MinHeight,
        EscCloses = false
    })
    self.Form = form
    if form == nil then return nil end

    self.Frame = self.SurfaceClass.Frame:New({
        Log = self.Log, Settings = settings,
        Visible = function() return self:FormVisible() end
    })

    -- 1 status bar, 2 results card, 3 results splitter.
    self.StatusLabel, self.StatusBar, self.StatusDetail = theme:CreateStatusBar(form, "")
    -- The left half is cut to its own width, so it is fitted again whenever
    -- that width moves, which is the window resizing or the right half
    -- taking more or less of the bar. It ends a gap short of the right half,
    -- or a cut hint would run straight into the counts.
    pcall(function() self.StatusLabel.BorderSpacing.Right = STATUS_GAP end)
    safeSet(self.StatusLabel, "OnResize", function() self:FitStatus() end)
    self:BuildResults(form)
    -- 4 find bar, 5 toolbar.
    self:BuildFindBar(form)
    self:BuildToolBar(form)
    -- 6 tree splitter, 7 tree card, 8 inspector card.
    self:BuildTree(form)
    self:BuildInspector(form)
    self:HoldPanes(form)

    self:BuildMenus()
    self:BuildKeys(form)
    self:BuildTimers(form)
    self:AdoptSurfaces()

    form.OnClose = function() return self:Closed() end
    return form
end

--- The results strip and the splitter above it, both hidden until something
--- fills them. A hidden control is left out of the alignment pass entirely, so
--- the tree and the inspector get the whole height until then.
function Window:BuildResults(form)
    local theme = self.Theme
    local settings = self.Settings
    local height = settings and settings.ResultsHeight or 180
    local content, card, _, counter = theme:CreateCard(form, {
        Align = "alBottom", Height = height, Title = "Results", Counter = "",
        ContentPad = 1
    })
    self.ResultsContent, self.ResultsCard, self.ResultsCounter = content, card, counter
    self.ResultsSplitter = theme:CreateSplitter(form, {
        Align = "alBottom", Height = 5, MinSize = 90
    })

    local results = self.ResultsClass:New({
        Theme = theme, Surface = self.SurfaceClass, Log = self.Log,
        Settings = settings, Frame = self.Frame
    })
    self.Results = results
    results:Attach(content)
    results.OnPick = function(item) self:ResultPicked(item) end
    results.OnOpen = function(item) self:ResultOpened(item) end

    safeSet(card, "Visible", false)
    safeSet(self.ResultsSplitter, "Visible", false)
end

--
--- ∑ The find and replace bar, hidden until somebody asks for it.
---
---   Everything on it is placed by hand rather than aligned. It is one row of
---   eleven controls and an alignment stack would reverse half of them for no
---   gain at all.
--- @param form userdata
--- @return userdata
--
function Window:BuildFindBar(form)
    local theme = self.Theme
    local settings = self.Settings
    local search = (settings and settings.Search) or {}
    local bar = theme:CreatePanel(form, {
        Align = "alTop", Height = 36, ColorKey = "COLOR_PANEL",
        Spacing = { Left = 8, Right = 8, Top = 2 }
    })
    self.FindBar = bar

    local function label(text, left)
        local control = theme:CreateLabel(bar, text, "muted")
        safeSet(control, "Left", left)
        safeSet(control, "Top", 9)
        return control
    end

    label("Find", 4)
    self.FindEdit = theme:CreateEdit(bar, {
        Left = 44, Top = 5, Width = 180,
        Placeholder = "plain text, never a pattern",
        Hint = "What to look for in the fields chosen on the right."
    })
    self:TrackFocus(self.FindEdit)

    label("Replace", 234)
    self.ReplaceEdit = theme:CreateEdit(bar, {
        Left = 300, Top = 5, Width = 180,
        Placeholder = "leave empty to delete the text",
        Hint = "What every match becomes when you replace all."
    })
    self:TrackFocus(self.ReplaceEdit)

    label("In", 490)
    local captions, chosen = {}, 1
    for index, entry in ipairs(Window.FindFields) do
        captions[index] = entry.Label
        local matches = true
        for _, field in ipairs({ "Description", "Script", "DropDown" }) do
            if (entry.Fields[field] == true) ~= (search[field] == true) then matches = false end
        end
        if matches then chosen = index end
    end
    self.FieldCombo = theme:CreateCombo(bar, {
        Items = captions, ItemIndex = chosen - 1, Left = 516, Top = 5, Width = 190,
        Hint = "Which fields a search reads. A script is the slowest of them.",
        OnChange = function() self:FindFieldsChanged() end
    })

    label("Scope", 716)
    local scopeIndex = 0
    for index, name in ipairs(Window.FindScopes) do
        if name == search.Scope then scopeIndex = index - 1 end
    end
    self.ScopeCombo = theme:CreateCombo(bar, {
        Items = Window.FindScopes, ItemIndex = scopeIndex,
        Left = 766, Top = 5, Width = 110,
        Hint = "All records, the rows the filter shows, or the selection.",
        OnChange = function() self:FindScopeChanged() end
    })

    local casePanel, setCase, getCase = theme:CreateCheck(bar, {
        Caption = "Case", Checked = search.MatchCase == true, Width = 74,
        Hint = "Match upper and lower case exactly.",
        OnChange = function(value) self:SetSearchOption("MatchCase", value) end
    })
    safeSet(casePanel, "Left", 886)
    safeSet(casePanel, "Top", 7)
    self.SetCase, self.GetCase = setCase, getCase

    local wordPanel, setWord, getWord = theme:CreateCheck(bar, {
        Caption = "Word", Checked = search.WholeWord == true, Width = 78,
        Hint = "Only matches that stand on their own.",
        OnChange = function(value) self:SetSearchOption("WholeWord", value) end
    })
    safeSet(wordPanel, "Left", 962)
    safeSet(wordPanel, "Top", 7)
    self.SetWord, self.GetWord = setWord, getWord

    -- The close button is created first so alRight leaves it at the far edge,
    -- with the two verbs to the left of it in reading order.
    theme:CreateButton(bar, {
        Caption = "x", Align = "alRight", Width = 28, Height = 26,
        Hint = "Hide the find bar. (Esc)",
        OnClick = function() self:HideFind() end
    })
    theme:CreateButton(bar, {
        Caption = "Replace all", Align = "alRight", Width = 108, Height = 26,
        Hint = "Write every match. One undo puts all of them back.",
        OnClick = function() self:RunFind(true) end
    })
    theme:CreateButton(bar, {
        Caption = "Find all", Align = "alRight", Width = 96, Height = 26,
        Hint = "List every match in the results strip.",
        OnClick = function() self:RunFind(false) end
    })

    safeSet(bar, "Visible", false)
    return bar
end

--
--- ∑ The toolbar. Seven icon buttons in four groups on the left, the menu
---   button at the right edge, and the filter in whatever room is left between
---   them.
---
---   The buttons carry no caption, so the whole bar fits a narrow window, and
---   the hint is where each one says its name and its shortcut. The left group
---   is built right to left, because alLeft puts the last created control
---   leftmost.
---
---   The filter is alClient and not alRight. An alRight filter keeps its width
---   when the left group already took the room, so a narrow window drew the
---   menu button over Export. An alClient one takes what the two stacks leave
---   and shrinks with the window instead. The window's minimum width keeps
---   that room at least as wide as the placeholder, which the build measures
---   here.
--- @param form userdata
--- @return userdata
--
function Window:BuildToolBar(form)
    local theme = self.Theme
    local bar = theme:CreateToolBar(form, TOOLBAR_HEIGHT)
    self.ToolBar = bar
    local spare = TOOLBAR_HEIGHT - TOOL_HEIGHT
    local above, below = spare // 2, spare - spare // 2
    local placed = {}

    local function button(key, options)
        options.Align = "alLeft"
        options.Height = TOOL_HEIGHT
        local panel, setEnabled, setPressed = theme:CreateToolButton(bar, options)
        self.Buttons[key] = { Enable = setEnabled, Press = setPressed, Panel = panel }
        placed[#placed + 1] = panel
        return panel
    end
    local function separator()
        placed[#placed + 1] = theme:CreateToolSeparator(bar)
    end

    button("Export", { Icon = "Export",
        Hint = "Export. Write the selected records to a file.",
        OnClick = function() self:ExportSelection() end })
    separator()
    button("Problems", { Icon = "Problems", Shortcut = "F7",
        Hint = "Problems. Check the table and list what is wrong with it.",
        OnClick = function() self:RunProblems() end })
    button("Find", { Icon = "Find", Shortcut = "Ctrl+H",
        Hint = "Find and replace across the table.",
        OnClick = function() self:ShowFind(true) end })
    separator()
    button("Redo", { Icon = "Redo", Shortcut = "Ctrl+Y",
        Hint = "Redo. Do the last undone edit again.",
        OnClick = function() self:Redo() end })
    button("Undo", { Icon = "Undo", Shortcut = "Ctrl+Z",
        Hint = "Undo. Put the last edit back.",
        OnClick = function() self:Undo() end })
    separator()

    local settings = self.Settings
    button("Live", { Icon = "Live", Toggle = true,
        Pressed = settings == nil or settings.LiveSync ~= false,
        Hint = "Live sync. Keep reading the address list while this window is open.",
        OnClick = function(pressed) self:SetLiveSync(pressed) end })
    button("Refresh", { Icon = "Refresh", Shortcut = "F5",
        Hint = "Refresh. Read the whole address list again.",
        OnClick = function() self:Sync(true) end })

    -- The one alRight control. It keeps as much space behind it as Refresh
    -- keeps in front, so the bar looks the same at both ends.
    local menuButton = theme:CreateToolButton(bar, {
        Icon = "Settings", Align = "alRight", Height = TOOL_HEIGHT,
        Hint = "Menu. Everything else, which is also on right-click in the record list.",
        Spacing = { Left = TOOL_GAP, Right = TOOL_GAP, Top = above, Bottom = below },
        OnClick = function() self:ShowMainMenu() end
    })
    self.MenuButton = menuButton
    placed[#placed + 1] = menuButton

    -- A field row with no label, so the filter has the frame every other input
    -- in this window has and its text sits on the bar's middle line.
    local row, edit = theme:CreateFieldRow(bar, {
        Kind = "edit", LabelWidth = 0, Align = "alClient", Height = TOOL_HEIGHT,
        ColorKey = "COLOR_PANEL",
        Placeholder = FILTER_PLACEHOLDER,
        Hint = "Show only the records that match. (Ctrl+F)",
        Spacing = { Left = FILTER_GAP, Right = FILTER_GAP, Top = above, Bottom = below },
        OnChange = function()
            if self.Loading then return end
            self:SetFilter(safeGet(self.FilterEdit, "Text"))
        end
    })
    self.FilterRow, self.FilterEdit = row, edit
    self:TrackFocus(edit)

    local barLeft, barRight = sideSpacing(bar)
    self.ToolBarNeed = barLeft + rowWidth(placed)
        + FILTER_GAP + self:FilterMinWidth() + FILTER_GAP + barRight
    return bar
end

--
--- ∑ The narrowest the filter may get, which is its placeholder whole plus
---   the frame around it.
--- @return number
--
function Window:FilterMinWidth()
    local theme = self.Theme
    local charWidth = 0
    if theme ~= nil and type(theme.CharWidth) == "function" then
        local ok, width = pcall(theme.CharWidth, theme)
        if ok then charWidth = tonumber(width) or 0 end
    end
    if charWidth <= 0 then charWidth = 7 end
    -- The placeholder is plain ASCII, so its length in bytes is its length.
    return math.ceil(#FILTER_PLACEHOLDER * charWidth) + FILTER_FRAME
end

--- The splitter and then the card, because alLeft puts the last created
--- control leftmost and the card belongs on the outside. A stored width that
--- does not fit the window is fitted by HoldPanes once the inspector exists.
function Window:BuildTree(form)
    local theme = self.Theme
    local settings = self.Settings
    self.TreeSplitter = theme:CreateSplitter(form, {
        Align = "alLeft", Width = SPLITTER_WIDTH, MinSize = self:TreeMinWidth()
    })
    local stored = integer(settings and settings.TreeWidth) or Defaults.TreeWidth
    local content, card, _, counter = theme:CreateCard(form, {
        Align = "alLeft", Width = math.max(self:TreeMinWidth(), stored),
        Title = "Records", Counter = "", ContentPad = CARD_PAD,
        Spacing = { Around = CARD_GAP }
    })
    self.TreeContent, self.TreeCard, self.TreeCounter = content, card, counter

    local tree = self.TreeClass:New({
        Theme = theme, Surface = self.SurfaceClass, Records = self.Records,
        Types = self.Types, Log = self.Log, Settings = settings,
        Frame = self.Frame, CE = self.CE
    })
    self.Tree = tree
    tree:Attach(content)
    tree.OnSelectionChanged = function(ids, focusId, forced)
        self:SelectionChanged(ids, focusId, forced)
    end
    tree.OnToggleActive = function(ids) self:ToggleActive(ids) end
    tree.OnOpen = function(id) self:OpenRecord(id) end
    tree.OnContext = function() self:MenuOpening() end
    tree.OnNeedProblems = function() self:RunProblems() end
    return card
end

--- The inspector fills what is left. Its pages reach the window through the
--- shell's hooks and never touch a record themselves. Its title goes through
--- the card's own setter, which cuts a long title to the room the header has
--- instead of letting it run over the card's own name. The hint of the row
--- under the mouse comes up through OnHint and goes to the status line.
function Window:BuildInspector(form)
    local theme = self.Theme
    local content, card, _, counter, setCounter = theme:CreateCard(form, {
        Align = "alClient", Title = "Inspector", Counter = "", ContentPad = CARD_PAD,
        Spacing = { Around = CARD_GAP }
    })
    self.InspectorContent, self.InspectorCard, self.InspectorCounter = content, card, counter

    local inspector = self.InspectorClass:New({
        Theme = theme, Surface = self.SurfaceClass, Frame = self.Frame,
        Grid = self.GridClass, Properties = self.Properties, Types = self.Types,
        Records = self.Records, CE = self.CE, Log = self.Log,
        Settings = self.Settings, Pages = self.PageClasses
    })
    self.Inspector = inspector
    inspector.OnCommit = function(tx) return self:Commit(tx) end
    inspector.OnAct = function(label, ids, fn) return self:Act(label, ids, fn) end
    inspector.OnStatus = function(text) self:Flash(text) end
    inspector.OnTitle = function(text)
        if type(setCounter) == "function" then
            if pcall(setCounter, text or "") then return end
        end
        safeSet(counter, "Caption", text or "")
    end
    inspector.OnHint = function(text) self:ShowHover(text) end
    inspector.OnGuard = function(fn) return self:Guard(fn) end
    inspector:Build(content)

    -- Two pages want something only the window can give them. A page class
    -- that is not installed leaves nothing behind here.
    local dropdown = inspector:PageFor("DropDown")
    if dropdown ~= nil then
        dropdown.OnGoTo = function(id) self:Select({ id }) end
    end
    local script = inspector:PageFor("Script")
    if script ~= nil then
        script.OnResults = function(kind, items) self:ShowResults(kind, items) end
    end
    return card
end

--------------------------------------------------------
--                 The two panes' widths              --
--------------------------------------------------------

--
--- ∑ Keeps the inspector at least as wide as its tabs need, whatever the
---   splitter, the window or the stored tree width say.
---
---   Three things do it together. The window cannot be made narrower than
---   both panes' minimums and what the toolbar needs. The two cards carry
---   their minimums as constraints, which the LCL splitter reads when it works
---   out how far a drag may go. And the tree is fitted into the room that is
---   left whenever the window or either card changes size and whenever a drag
---   ends, because an alClient inspector held at its minimum does not push the
---   tree aside. It runs past the right edge of the window instead.
--- @param form userdata
--- @return number # The window's minimum width.
--
function Window:HoldPanes(form)
    local minimum = self:MinimumWidth()
    pcall(function() form.Constraints.MinWidth = minimum end)
    local width = integer(safeGet(form, "Width"))
    if width ~= nil and width < minimum then safeSet(form, "Width", minimum) end
    setMinWidth(self.TreeCard, self:TreeMinWidth())
    setMinWidth(self.InspectorCard, self:InspectorMinWidth())

    -- The inspector alone is not enough. Once it sits at its minimum a wider
    -- tree no longer changes its size, so the tree says so itself.
    local function fit() pcall(self.FitPanes, self) end
    safeSet(form, "OnResize", fit)
    safeSet(self.TreeCard, "OnResize", fit)
    safeSet(self.InspectorCard, "OnResize", fit)
    -- OnMoved comes once the mouse is let go. With rsUpdate the tree already
    -- followed the drag, so this only tidies up what the drag left.
    safeSet(self.TreeSplitter, "OnMoved", fit)
    self:FitPanes()
    return minimum
end

--
--- ∑ The least the window may be across.
---
---   The tree's minimum, the inspector's minimum and everything between and
---   around them, or what the toolbar needs, whichever is wider, plus the
---   frame. Nothing here is a number picked by hand. The inspector's minimum
---   comes from its longest tab caption, so a window at this width shows
---   every tab whole on one row. The splitter's clamp in TreeRoom takes the
---   same inspector minimum, so a drag can never leave less than this gives.
--- @return number
--
function Window:MinimumWidth()
    local panes = self:TreeMinWidth() + PANE_CHROME + self:InspectorMinWidth()
    local content = math.max(panes, tonumber(self.ToolBarNeed) or 0)
    return content + Defaults.FrameWidth
end

--- One end of the bounds the settings hold a stored tree width to, or nothing
--- when the settings cannot say.
local function treeBound(settings, side)
    local value = nil
    pcall(function() value = integer(settings.Bounds.TreeWidth[side]) end)
    if value == nil or value < 1 then return nil end
    return value
end

--- The narrowest the tree gets. The settings' floor for a stored tree width
--- when they have one, so the two can never disagree.
function Window:TreeMinWidth()
    return treeBound(self.Settings, "Min") or Defaults.TreeMinWidth
end

--- The widest a tree width may be asked for, the settings' ceiling, or
--- nothing when there is none.
function Window:TreeMaxWidth()
    return treeBound(self.Settings, "Max")
end

--
--- ∑ The narrowest the inspector card gets, which is what its content needs
---   with the card's border and pad around it.
---
---   The inspector says what its content needs. That is five tabs wide
---   enough for the longest caption in this theme's text measurement, with
---   the gap in front of each and behind the last, and never less than every
---   page is laid out for. An inspector class handed in that cannot say is
---   measured the way the bundled one is.
--- @return number
--
function Window:InspectorMinWidth()
    local content = nil
    for _, class in ipairs({ self.InspectorClass, InspectorModule }) do
        if content == nil and type(class) == "table"
            and type(class.ContentMinWidth) == "function" then
            local ok, width = pcall(class.ContentMinWidth, self.Theme)
            if ok then content = integer(width) end
            if content ~= nil and content <= 0 then content = nil end
        end
    end
    return (content or InspectorModule.MinWidth) + CARD_INSET
end

--
--- ∑ The widest the tree may be right now, which is the window's client width
---   less everything across it that is not the tree, the inspector's minimum
---   included.
--- @return number|nil # Nothing while the window cannot say how wide it is.
--
function Window:TreeRoom()
    local form = self.Form
    if form == nil then return nil end
    local client = integer(safeGet(form, "ClientWidth"))
    if client == nil or client <= 0 then
        local width = integer(safeGet(form, "Width"))
        if width == nil then return nil end
        client = width - Defaults.FrameWidth
    end
    if client <= 0 then return nil end
    return client - PANE_CHROME - self:InspectorMinWidth()
end

--
--- ∑ The tree width a person asked for, by dragging or through the stored
---   setting. A width that differs from the one the last fit left was set by
---   somebody else, and that becomes the wish from then on.
--- @return number|nil
--
function Window:TreeWidthWanted()
    local current = integer(safeGet(self.TreeCard, "Width"))
    if current ~= nil and current ~= self.TreeFitted then return current end
    return self.TreeWanted or current
end

--
--- ∑ Fits the tree into the room the inspector's minimum leaves.
---
---   The tree gets the width that was asked for, cut to the room there is and
---   never below its own minimum. A window made narrower takes width from the
---   tree, and a window made wider gives it back up to what was asked for, so
---   shrinking the window for a moment does not lose the width somebody chose.
---
---   A width asked for by a drag is taken as far as it could go at the size
---   the window had then. Dragging past the inspector's minimum means as wide
---   as it gets, and not that the inspector should stay squeezed once the
---   window is made wider. A stored width is kept whole, because it was chosen
---   in a window that had room for it.
---
---   Writing the width realigns the window and resizes the inspector, which
---   calls this again, and that call finds nothing left to do.
--- @return number|nil # The tree width now, or nothing when there is no tree.
--
function Window:FitPanes()
    local card = self.TreeCard
    if card == nil or self.Fitting then return nil end
    local current = integer(safeGet(card, "Width"))
    if current == nil then return nil end
    local floor = self:TreeMinWidth()
    local room = self:TreeRoom()
    local dragged = self.TreeFitted ~= nil and current ~= self.TreeFitted
    local wanted = self:TreeWidthWanted() or current
    if dragged and room ~= nil then wanted = math.min(wanted, room) end
    local ceiling = self:TreeMaxWidth()
    if ceiling ~= nil then wanted = math.min(wanted, ceiling) end
    wanted = math.max(floor, wanted)
    self.TreeWanted = wanted
    local target = wanted
    if room ~= nil then target = math.max(floor, math.min(wanted, room)) end
    self.TreeFitted = target
    if target ~= current then
        self.Fitting = true
        safeSet(card, "Width", target)
        self.Fitting = false
    end
    return target
end

--- Remembers that a text control has the keyboard. Reading ActiveControl back
--- is not reliable, because two lookups of one Cheat Engine object need not be
--- the same Lua value, so the control says so itself.
function Window:TrackFocus(control)
    if control == nil then return false end
    safeSet(control, "OnEnter", function() self.TextFocus = true end)
    safeSet(control, "OnExit", function() self.TextFocus = false end)
    return true
end

--
--- ∑ Wraps the mouse down of every canvas that has joined the frame service.
---
---   Two things have to happen before a click on a canvas is answered. The pane
---   the keyboard belongs to moves, because a paint box never takes focus and
---   the window has nothing else to go on. And the form's active control is
---   cleared, so a grid editor standing open over a value cell sees its own
---   OnExit and commits or cancels rather than staying open over a row that is
---   no longer the one being edited.
---
---   It runs again on every tick, because a page builds its canvases when it is
---   first shown and those join the service later.
--- @return number # How many surfaces were wrapped this time.
--
function Window:AdoptSurfaces()
    local frame = self.Frame
    if frame == nil then return 0 end
    local added = 0
    for _, surface in ipairs(frame.Surfaces) do
        if not self.Hooked[surface] then
            self.Hooked[surface] = true
            local pane = self:PaneOf(surface)
            local inner = surface.OnMouseDown
            surface.OnMouseDown = function(button, x, y)
                self:CanvasDown(pane)
                if type(inner) == "function" then return inner(button, x, y) end
            end
            added = added + 1
        end
    end
    return added
end

--- Which pane a canvas belongs to. Everything that is not the tree or the
--- results strip lives inside the inspector.
function Window:PaneOf(surface)
    if self.Tree ~= nil and surface == self.Tree.Surface then return "tree" end
    if self.Results ~= nil and surface == self.Results.Surface then return "results" end
    return "inspector"
end

--- A mouse down landed on a canvas. See AdoptSurfaces for why both of these
--- happen before the owner sees the click.
function Window:CanvasDown(pane)
    if pane ~= nil then self.Pane = pane end
    self.TextFocus = false
    safeSet(self.Form, "ActiveControl", nil)
    return self.Pane
end

--------------------------------------------------------
--                      Timers                        --
--------------------------------------------------------

--- One timer for painting and one for reading. Both stand down while the busy
--- counter is above zero.
function Window:BuildTimers(form)
    local create = rawget(_G, "createTimer")
    if type(create) ~= "function" then
        say(self, "Warning", "This Cheat Engine has no timers, so the window "
            .. "only updates when you press F5.")
        return false
    end
    local okFrame, frameTimer = pcall(create, form)
    if okFrame and frameTimer ~= nil then
        self.FrameTimer = frameTimer
        safeSet(frameTimer, "Interval", Defaults.FrameInterval)
        safeSet(frameTimer, "OnTimer", function() self:FrameTick() end)
        safeSet(frameTimer, "Enabled", true)
    end
    local okSync, syncTimer = pcall(create, form)
    if okSync and syncTimer ~= nil then
        self.SyncTimer = syncTimer
        safeSet(syncTimer, "Interval", (self.Settings and self.Settings.SyncInterval) or 250)
        safeSet(syncTimer, "OnTimer", function() self:SyncTick() end)
        safeSet(syncTimer, "Enabled", true)
    end
    return true
end

--- Whether the form is on screen. The frame service asks this every tick, so
--- it is one guarded property read and nothing else.
function Window:FormVisible()
    return safeGet(self.Form, "Visible") == true
end

--- One frame. The service decides which canvases are dirty, and the whole tick
--- is skipped while the window is hidden or something is pumping messages.
function Window:FrameTick()
    if self.Busy > 0 or self.Frame == nil then return 0 end
    local ok, painted = pcall(self.Frame.Tick, self.Frame)
    if ok then return painted or 0 end
    return 0
end

--
--- ∑ One read of the address list, on the sync timer.
---
---   Guarded as a whole. An unhandled error inside a timer handler is printed
---   by Cheat Engine at the timer's own rate, which is four lines a second
---   forever, and five of them in a row turn live sync off instead.
--- @return boolean
--
function Window:SyncTick()
    if self.Busy > 0 then return false end
    if not self:FormVisible() then return false end
    local settings = self.Settings
    if settings ~= nil and settings.LiveSync == false then
        -- Live sync off still follows a script that is running, because the
        -- record it belongs to is mid flight and nobody else is watching it.
        self:FollowPending()
        -- A flashed message still has to run out, or a hovered row's hint
        -- would never get the status line back without a sync.
        if self.FlashText ~= nil then self:FitStatus() end
        return false
    end
    local ok, err = pcall(self.Sync, self, false)
    if ok then
        self.TickFailures = 0
        return true
    end
    self.TickFailures = self.TickFailures + 1
    say(self, "Error", "A sync failed. " .. tostring(err))
    if self.TickFailures >= Defaults.MaxSyncFailures then
        self:SetLiveSync(false)
        say(self, "Warning", "Live sync was turned off after "
            .. Defaults.MaxSyncFailures .. " failures in a row. F5 still works.")
    end
    return false
end

--- Turns the poll on or off and keeps the toolbar button in step.
function Window:SetLiveSync(value)
    value = value == true
    local settings = self.Settings
    if settings ~= nil and type(settings.Set) == "function" then
        pcall(settings.Set, settings, "LiveSync", value)
    end
    local button = self.Buttons.Live
    if button ~= nil and type(button.Press) == "function" then pcall(button.Press, value) end
    if value then self.TickFailures = 0 end
    self:UpdateStatus()
    return value
end

--------------------------------------------------------
--                       Syncing                      --
--------------------------------------------------------

--
--- ∑ Reads what changed in the address list and puts it on screen.
---
---   Three passes on three schedules. The structure walk reads an id and a
---   child count per record and runs when Cheat Engine's own count moved and
---   otherwise on an interval the window measures for itself. The detail pass
---   re-reads a contiguous window of nodes, because getMemoryRecord is only
---   fast when the index asked for sits next to the last one, and its budget is
---   measured so one tick stays inside its own milliseconds. Values are read
---   for the rows on screen only, because reading one reads process memory and
---   can fire the record's own value handler.
--- @param full boolean|nil # Read everything, which is what Open and F5 do.
--- @return boolean # Whether anything on screen changed.
--
function Window:Sync(full)
    local records = self.Records
    if records == nil then return false end
    local started = self:Now()
    self.Ticks = self.Ticks + 1
    local tick = self.Ticks
    local changed = false

    -- Whether the inspector has anything to redraw. A page rebuild reads
    -- twenty five properties per selected record straight out of Cheat Engine,
    -- so it is asked for when something it draws moved and not four times a
    -- second on the chance that it did.
    local moved = full == true

    -- Whether this tick found another Cheat Table in front of it.
    local fresh = false

    if self:WantsStructure(full, tick) then
        local walkStarted = self:Now()
        local snapshot, reason = records:Structure()
        self.StructureCost = (self:Now() - walkStarted) * 1000
        if snapshot == nil then
            self.SyncFailures = self.SyncFailures + 1
            if self.SyncFailures == 1 then
                say(self, "Warning", "The address list could not be read. " .. tostring(reason))
            end
            self:UpdateStatus()
            return false
        end
        self.SyncFailures = 0
        local was = self.TableStamp
        local structure = self:TakeSnapshot(snapshot)
        changed = structure or changed
        moved = moved or structure
        -- Another Cheat Table means not one node carries anything, and a tree
        -- filled in sixty four records a tick would show blank rows for a
        -- quarter of a minute on a large one.
        fresh = was ~= nil and was ~= self.TableStamp
    end

    local snapshot = self.Snapshot
    if snapshot ~= nil then
        if full or fresh then
            -- Every node is read before the first paint. A tree drawn from
            -- half loaded nodes shows blank descriptions for a quarter of a
            -- second and looks broken.
            local loadStarted = self:Now()
            records:Detail(snapshot)
            if full and (self:Now() - loadStarted) * 1000 > Defaults.SlowLoadMs then
                self:Flash("Reading " .. snapshot.Count .. " records...")
            end
            changed = true
        else
            local detailStarted = self:Now()
            local done = records:DetailSome(snapshot, self.DetailBudget)
            self:AdaptBudget((self:Now() - detailStarted) * 1000)
            if done > 0 then
                changed = true
                moved = true
            end
        end
        if self.Tree ~= nil then self.Tree:SetSnapshot(snapshot) end
        if full or (tick % Defaults.ValueEvery) == 0 then
            self:ReadValues()
            if self:WatchSelection() then moved = true end
        end
    end

    if full or (tick % Defaults.ThemeEvery) == 0 then self:CheckTheme() end
    self:AdoptSurfaces()
    self:FollowPending()
    self:MirrorSelection()
    self:FollowCheatEngine()
    if self.Inspector ~= nil then
        -- Nil is everything and an empty list is nothing, so the two are
        -- spelled out. An and or here would hand nothing over both times.
        if moved then self.Inspector:Refresh(self.Snapshot, nil)
        else self.Inspector:Refresh(self.Snapshot, NOTHING) end
    end
    self.SyncCost = (self:Now() - started) * 1000
    self:UpdateStatus()
    return changed
end

--- Whether this tick walks the structure. The walk is cheap but not free, so
--- it runs on a schedule the window measures rather than on every tick.
function Window:WantsStructure(full, tick)
    if full or self.Snapshot == nil then return true end
    local ce = self.CE
    if ce ~= nil then
        local count = integer(ce:Count()) or 0
        if count ~= (self.Snapshot.Count or -1) then return true end
    end
    local every = Defaults.StructureFast
    if self.StructureCost > Defaults.StructureCostMs then every = Defaults.StructureSlow end
    return (tick % every) == 0
end

--- Grows or shrinks the detail budget so one tick stays inside its own time.
--- A window on an idle table stops sweeping altogether, so this costs nothing
--- once everything has been read.
function Window:AdaptBudget(cost)
    if cost > Defaults.DetailBudgetMs then
        self.DetailBudget = math.max(Defaults.DetailMin, math.floor(self.DetailBudget / 2))
    elseif cost < (Defaults.DetailBudgetMs / 2) then
        self.DetailBudget = math.min(Defaults.DetailMax, self.DetailBudget + Defaults.DetailStep)
    end
    return self.DetailBudget
end

--
--- ∑ Takes a fresh snapshot, and drops the world when it belongs to another
---   Cheat Table.
---
---   Ids start again from one in every table. An undo entry, a problem or a
---   selected id held across a table change names a record that has nothing to
---   do with the one it was made against, so all of it goes.
---
---   The journal is told the stamp on every walk and not only on the first
---   one. A window that opened on one table and a journal that outlived it are
---   two different memories of which table this is, and the walk is the one
---   that just read it.
--- @param snapshot table
--- @return boolean # Whether the table changed.
--- @return boolean # Whether an undo history was thrown away with it.
--
function Window:TakeSnapshot(snapshot)
    local previous = self.Snapshot
    local journal = self.Journal
    local held = 0
    if journal ~= nil and type(journal.Count) == "function" then
        held = tonumber(journal:Count()) or 0
    end
    local different = previous ~= nil and not RecordsModule.SameTable(previous, snapshot)
    self.Snapshot = snapshot
    if different then
        self:DropWorld(snapshot)
        return true, held > 0
    end
    local dropped = false
    if journal ~= nil then
        local ok, moved, threw = pcall(journal.SetStamp, journal, snapshot.TableStamp)
        dropped = ok and moved == true and (tonumber(threw) or 0) > 0
    end
    self.TableStamp = snapshot.TableStamp
    return (previous == nil or previous.Signature ~= snapshot.Signature), dropped
end

--
--- ∑ Throws away everything that was keyed by an id from the table before.
--- @param snapshot table
--- @return nil
--
function Window:DropWorld(snapshot)
    local journal = self.Journal
    if journal ~= nil then
        -- Cleared first, so the journal's own report stays quiet and this
        -- window says it once rather than twice.
        pcall(journal.Clear, journal)
        pcall(journal.SetStamp, journal, snapshot.TableStamp)
    end
    self.TableStamp = snapshot.TableStamp
    self.Problems, self.ProblemMap = nil, nil
    self.Pending = {}
    self.Watched = {}
    self.MirroredID, self.FollowedID = nil, nil
    if self.Tree ~= nil then
        self.Tree:ClearSelection()
        self.Tree.Collapsed = {}
        self.Tree:SetProblems(nil)
    end
    if self.Results ~= nil then
        self.ResultKind = nil
        self.Results:SetItems(nil, {})
        self:ShowResultsCard(false)
    end
    self:Flash("A different Cheat Table is loaded. The undo history was dropped.")
    say(self, "Info", "A different Cheat Table is loaded. The undo history was dropped.")
end

--
--- ∑ Reads the display value of the rows that are on screen and nothing else.
--- @param only table|nil # A set of ids. A row on screen outside it is left
---        alone. Nothing reads every row on screen.
--- @return number # How many values were read.
--
function Window:ReadValues(only)
    local settings = self.Settings
    if settings ~= nil and settings.ShowValues == false then return 0 end
    local tree, records = self.Tree, self.Records
    if tree == nil or records == nil or self.Snapshot == nil then return 0 end
    local ids = tree:VisibleIDs()
    if only ~= nil then
        local kept = {}
        for _, id in ipairs(ids) do
            if only[id] then kept[#kept + 1] = id end
        end
        ids = kept
    end
    if #ids == 0 then return 0 end
    local values = records:Values(self.Snapshot, ids)
    tree:SetValues(values)
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    return count
end

--
--- ∑ Watches the few facts the inspector draws that move on their own.
---
---   The inspector used to be rebuilt on every tick, which read twenty five
---   properties per selected record out of Cheat Engine four times a second
---   whether anything had happened or not. It cannot simply be left alone
---   instead, because the value, the activation state and a resolved pointer
---   address all move behind Cheat Engine's back and the grid is the only
---   place they are shown. So those three are read here, for the selection and
---   nothing else, and the rebuild is asked for when one of them moved.
---
---   A selected row that is also on screen is read twice on these ticks, once
---   for the tree's value column and once here. That is two reads a second
---   against the twenty five per record per tick it replaces.
--- @return boolean # Whether something the inspector draws moved.
--
function Window:WatchSelection()
    local records, ce = self.Records, self.CE
    if self.Inspector == nil or records == nil or ce == nil then return false end
    local snapshot = self.Snapshot
    if snapshot == nil then return false end
    local before = self.Watched or {}
    local current, moved = {}, false
    for _, id in ipairs(self:SelectedIDs()) do
        local mark = "gone"
        local mr = records:Resolve(id, snapshot)
        if mr ~= nil then
            mark = tostring(ce:Get(mr, "Value")) .. "\1"
                .. tostring(ce:Get(mr, "Active")) .. "\1"
                .. tostring(ce:Get(mr, "AddressString"))
        end
        current[id] = mark
        if before[id] ~= mark then moved = true end
    end
    self.Watched = current
    return moved
end

--- Notices that the Cheat Table's theme changed and re-colours everything.
--- The canvases read the palette when they paint, so without the invalidate
--- they would follow the new theme a frame later than the panels do.
function Window:CheckTheme()
    local theme = self.Theme
    if theme == nil then return false end
    local source = theme:Source()
    if source == self.ThemeSource then return false end
    self.ThemeSource = source
    pcall(theme.Restyle, theme)
    if self.Frame ~= nil then self.Frame:Invalidate() end
    return true
end

--------------------------------------------------------
--               Following what is running            --
--------------------------------------------------------

--
--- ∑ Follows the scripts that were still running when the write returned.
---
---   With Async on, assigning Active returns before the script finished and
---   AsyncProcessing stays true meanwhile. Cheat Engine reports nothing when it
---   is done, so the ids are kept and re-read until the flag clears, and then
---   the record is told what happened. A script still running after half a
---   minute is let go, because something in it is waiting on the game.
--- @return number # How many are still being followed.
--
function Window:FollowPending()
    local records = self.Records
    local ce = self.CE
    if records == nil or ce == nil then return 0 end
    local now = self:Now()
    local left = 0
    for id, entry in pairs(self.Pending) do
        local mr = records:Resolve(id, self.Snapshot)
        if mr == nil then
            self.Pending[id] = nil
            say(self, "Warning", "The record that was running a script is gone.")
        elseif ce:Get(mr, "AsyncProcessing") == true then
            if (now - entry.At) > Defaults.PendingSeconds then
                self.Pending[id] = nil
                say(self, "Warning", "'" .. self:NameOf(id) .. "' was still running its script after "
                    .. Defaults.PendingSeconds .. " seconds, so this window stopped following it.")
            else
                left = left + 1
            end
        else
            self.Pending[id] = nil
            local failed = ce:Get(mr, "LastAAExecutionFailed") == true
            local name = self:NameOf(id)
            if failed then
                local why = ce:Get(mr, "LastAAExecutionFailedReason")
                local tail = ""
                if type(why) == "string" and why ~= "" and why ~= "Unknown" then
                    tail = " " .. why
                end
                self:Flash("The script on '" .. name .. "' failed." .. tail)
                say(self, "Warning", "The script on '" .. name .. "' failed." .. tail)
            else
                local active = ce:Get(mr, "Active") == true
                self:Flash("'" .. name .. "' finished and is now "
                    .. (active and "active" or "inactive") .. ".")
                say(self, "Info", "'" .. name .. "' finished its script and is now "
                    .. (active and "active" or "inactive") .. ".")
            end
            records:Detail(self.Snapshot, self.Snapshot and self.Snapshot.ByID[id] or nil)
        end
    end
    return left
end

--- The description of one record, or a readable stand in when it has none.
function Window:NameOf(id)
    local node = self.Snapshot and self.Snapshot.ByID and self.Snapshot.ByID[id] or nil
    local name = node and node.Description
    if type(name) == "string" and name ~= "" then return name end
    return "#" .. tostring(id)
end

--
--- ∑ Pushes this window's focus into Cheat Engine's own selection.
---
---   Only when the focus moved since the last push. Writing the selection every
---   tick would fight with Follow below, and the two of them would take turns
---   selecting each other forever.
--- @return boolean
--
function Window:MirrorSelection()
    local settings = self.Settings
    if settings == nil or settings.MirrorSelectionToCE ~= true then return false end
    local tree, ce = self.Tree, self.CE
    if tree == nil or ce == nil then return false end
    local focus = tree:Focused()
    if focus == nil or focus == self.MirroredID then return false end
    if ce:SelectRecord(focus) then
        self.MirroredID = focus
        return true
    end
    return false
end

--- Takes Cheat Engine's selection, unless it is the one this window just
--- wrote, which is the other half of the loop being broken.
function Window:FollowCheatEngine()
    local settings = self.Settings
    if settings == nil or settings.FollowCESelection ~= true then return false end
    local tree, ce = self.Tree, self.CE
    if tree == nil or ce == nil then return false end
    local id = ce:SelectedRecordID()
    if id == nil or id == self.MirroredID or id == self.FollowedID then return false end
    self.FollowedID = id
    tree:Select({ id }, id, true)
    return true
end

--------------------------------------------------------
--                   The commit funnel                --
--------------------------------------------------------

--
--- ∑ The appliers. This table is the only thing in the segment that writes to
---   a memory record.
---
---   Each one takes the window first, because a table of plain functions has no
---   way to reach the records service otherwise. Each answers ok and a reason,
---   and may answer a third value holding a note. A note carrying Changes names
---   what Cheat Engine moved of its own accord, such as the other hide children
---   flag, and the funnel writes those into the transaction so undo puts them
---   back too.
--
Window.Appliers = {
    property = function(self, change, value)
        local props = self.Properties
        if props == nil then return false, "This window has no property service." end
        local mr = self:Record(change.ID)
        if mr == nil then return false, "The record is gone." end
        return props:Write(mr, change.Key, value)
    end,

    pointer = function(self, change, value)
        local props = self.Properties
        if props == nil then return false, "This window has no property service." end
        local mr = self:Record(change.ID)
        if mr == nil then return false, "The record is gone." end
        return props:WritePointer(mr, value)
    end,

    script = function(self, change, value)
        local props = self.Properties
        if props == nil then return false, "This window has no property service." end
        local mr = self:Record(change.ID)
        if mr == nil then return false, "The record is gone." end
        return props:WriteScript(mr, value)
    end,

    dropdown = function(self, change, value)
        local props = self.Properties
        if props == nil then return false, "This window has no property service." end
        local mr = self:Record(change.ID)
        if mr == nil then return false, "The record is gone." end
        return props:WriteDropDown(mr, value)
    end,

    hotkey = function(self, change, value)
        local props = self.Properties
        if props == nil then return false, "This window has no property service." end
        local mr = self:Record(change.ID)
        if mr == nil then return false, "The record is gone." end
        return props:WriteHotkey(mr, change.HotkeyID, change.Key, value)
    end,

    --
    --- ∑ The children of one group are these, in this order.
    ---
    ---   Records that have left the group since are brought back into it
    ---   first, because Cheat Engine's re-append only reorders what a group
    ---   already holds. That is what makes a move between two groups undoable
    ---   as two of these, the target first so the old parent's list has already
    ---   lost them by the time it is asked for.
    --
    order = function(self, change, value)
        local records = self.Records
        if records == nil then return false, "This window has no records service." end
        local parent = change.ParentID or change.ID
        local snapshot = self.Snapshot
        local node = snapshot ~= nil and snapshot.ByID[parent] or nil
        if node == nil then return false, "The group is gone." end

        local held, missing = {}, {}
        for _, id in ipairs(node.Children) do held[id] = true end
        for _, id in ipairs(value or {}) do
            if not held[id] then missing[#missing + 1] = id end
        end
        if #missing > 0 then
            local moved, failures = records:MoveInto(snapshot, missing, parent)
            if #moved < #missing then
                return false, (failures[1] and failures[1].Reason)
                    or "Cheat Engine did not move the records into the group."
            end
            -- Every index after the move is different, so the walk runs again
            -- before anything is re-appended.
            local fresh = records:Structure()
            if fresh ~= nil then self.Snapshot = fresh end
            snapshot = self.Snapshot
        end
        if type(value) ~= "table" or #value == 0 then return true end
        return records:Reorder(snapshot, parent, value)
    end
}

--- The memory record behind an id, resolved fresh every time. A wrapper held
--- past a delete is a use after free.
function Window:Record(id)
    local records = self.Records
    if records == nil then return nil end
    return records:Resolve(id, self.Snapshot)
end

--
--- ∑ Sends one change through its applier. Undo and redo come through here
---   as well, which is what keeps one writer for every path.
--- @param change table
--- @param value any # The value to write, which is Old for an undo.
--- @return boolean, string|nil, table|nil
--
function Window:ApplyChange(change, value)
    if type(change) ~= "table" then return false, "There is no change to apply." end
    local applier = Window.Appliers[change.Kind]
    if applier == nil then
        return false, "This window cannot apply a " .. tostring(change.Kind) .. " change."
    end
    local ok, reason, note = applier(self, change, value)
    return ok == true, reason, note
end

--
--- ∑ The only path an undoable edit takes.
---
---   Every change is resolved by id, applied through the appliers and written
---   down only when it landed, so a transaction that half failed leaves a
---   history describing what really happened. The description cache is rebuilt
---   once for the whole transaction rather than once per record, because
---   rebuilding it per record on a rename of four hundred records is the one
---   thing that makes a bulk edit slow.
--- @param tx table # Label and Changes.
--- @return boolean # Whether the funnel ran at all.
--- @return number # How many changes landed.
--- @return table|nil # One entry of ID, Key and Reason per change that did not.
--
function Window:Commit(tx)
    if type(tx) ~= "table" or type(tx.Changes) ~= "table" then return false, 0, nil end
    local ok, applied, failures = self:Guard(function() return self:CommitNow(tx) end)
    if ok == nil then return false, 0, nil end
    return ok == true, applied or 0, failures
end

function Window:CommitNow(tx)
    local label = tostring(tx.Label or "Edit")
    local landed, failures, touched = {}, {}, {}
    local renamed, reordered = false, false

    for _, change in ipairs(tx.Changes) do
        local ok, reason, note = self:ApplyChange(change, change.New)
        if ok then
            landed[#landed + 1] = change
            touched[change.ID] = true
            if change.Kind == "property" and change.Key == "Description" then renamed = true end
            if change.Kind == "order" then reordered = true end
            -- Cheat Engine changed something else on the way, so undo has to
            -- know about that too.
            if type(note) == "table" and type(note.Changes) == "table" then
                for _, extra in ipairs(note.Changes) do
                    extra.Kind = extra.Kind or "property"
                    landed[#landed + 1] = extra
                    touched[extra.ID] = true
                end
            end
        else
            failures[#failures + 1] = { ID = change.ID, Key = change.Key, Reason = reason }
        end
    end

    local ce = self.CE
    if renamed and ce ~= nil then ce:RebuildDescriptionCache() end
    if #landed > 0 and self.Journal ~= nil then
        pcall(self.Journal.Push, self.Journal, {
            Label = label, Changes = landed, Stamp = os.time()
        })
    end
    if ce ~= nil then ce:RepaintList() end
    self:AfterWrite(touched, reordered)

    if #failures == 0 then
        self:Flash(label .. ".")
        say(self, "Info", label .. ", " .. #landed .. " change" .. s(#landed) .. " written.")
    else
        self:Flash(label .. ", " .. #failures .. " failed.")
        self:ReportFailures(label, #landed, failures)
    end
    return true, #landed, failures
end

--- One warning block naming every record the write did not reach.
function Window:ReportFailures(label, applied, failures)
    local rows = {
        { "Written", applied },
        { "Refused", #failures },
        ""
    }
    for _, failure in ipairs(failures) do
        local name = failure.ID and ("'" .. self:NameOf(failure.ID) .. "'") or "a record"
        local key = failure.Key and (" " .. tostring(failure.Key)) or ""
        rows[#rows + 1] = { name .. key, failure.Reason or "no reason given" }
    end
    local log = self.Log
    if log == nil then return false end
    return (pcall(function() log:Warning(log:Block(label, rows)) end))
end

--
--- ∑ The rows whose value a write to these records can move, which are the
---   records themselves and every linked row on screen.
---
---   A linked drop-down names its record by description and Cheat Engine
---   follows the link each time the value is drawn, so a new list, a new flag
---   or a new name on another record can change what a linked row shows. A
---   screen holds a few dozen rows and a handful of linked ones, so reading
---   every linked one again costs less than working out which points where.
--- @param touched table # A set of ids.
--- @param snapshot table
--- @param shown table # The ids on screen.
--- @return table # A set of ids.
--
local function valueReach(touched, snapshot, shown)
    local reach = {}
    -- A write where nothing landed moved nothing either.
    if next(touched) == nil then return reach end
    for id in pairs(touched) do reach[id] = true end
    for _, id in ipairs(shown) do
        local node = snapshot.ByID[id]
        if node ~= nil and node.DropDownLinked == true then reach[id] = true end
    end
    return reach
end

--
--- ∑ Re-reads what a write touched and puts it on screen.
---
---   The value column is read here as well, for the touched rows that are on
---   screen and the linked rows beside them. What a record shows moves with a
---   value write, a drop-down list, a flag that shows the description, a type
---   or an address. The sync tick only reads values every few ticks, and with
---   live sync off not before F5, so the row showed the old one until then.
--- @param ids table|nil # A set or a list of ids, nil for everything.
--- @param structure boolean|nil # Walk the tree again, which a move needs.
--- @return nil
--
function Window:AfterWrite(ids, structure)
    local records = self.Records
    if records == nil then return end
    if structure then
        local snapshot = records:Structure()
        if snapshot ~= nil then self:TakeSnapshot(snapshot) end
    end
    local snapshot = self.Snapshot
    if snapshot == nil then return end
    local touched = nil
    if ids == nil then
        records:Detail(snapshot)
    else
        touched = idSet(ids)
        for id in pairs(touched) do
            records:Detail(snapshot, snapshot.ByID[id])
        end
    end
    local tree = self.Tree
    if tree ~= nil then
        tree:SetSnapshot(snapshot)
        local reach = nil
        if touched ~= nil then reach = valueReach(touched, snapshot, tree:VisibleIDs()) end
        self:ReadValues(reach)
    end
    if self.Inspector ~= nil then self.Inspector:Refresh(snapshot, ids) end
    self:UpdateStatus()
end

--------------------------------------------------------
--                        Acting                      --
--------------------------------------------------------

--
--- ∑ The path for everything undo cannot take back.
---
---   Activation, a value write, a hotkey test, a hotkey removal and a new
---   record all end here. It is also the only place that writes Active, which
---   is why the script question lives here and not in the three callers that
---   would otherwise each ask it their own way.
--- @param label string # What is happening, in the words the person will read.
--- @param ids table # The records it touches.
--- @param fn function # The work itself, answering applied and failures.
--- @return boolean # Whether it ran.
--
function Window:Act(label, ids, fn)
    if type(fn) ~= "function" then return false end
    label = tostring(label or "Change")
    ids = copyIDs(ids)
    local ok = self:Guard(function() return self:ActNow(label, ids, fn) end)
    return ok == true
end

function Window:ActNow(label, ids, fn)
    if not self:AllowActivation(label, ids) then
        self:Flash(label .. " was not done.")
        return false
    end
    local ran, applied, failures = pcall(fn)
    if not ran then
        say(self, "Warning", label .. " failed. " .. tostring(applied))
        self:Flash(label .. " failed.")
        return false
    end
    applied = tonumber(applied) or 0
    failures = type(failures) == "table" and failures or {}

    local held = self:CollectPending(label, ids)
    local ce = self.CE
    if ce ~= nil then ce:RepaintList() end
    self:AfterWrite(ids, false)

    if #failures == 0 then
        local note = ""
        if held > 0 then
            note = " " .. held .. " script" .. s(held) .. " running in the background."
        end
        self:Flash(label .. "." .. note)
        say(self, "Info", label .. ", " .. applied .. " record" .. s(applied) .. " touched." .. note)
    else
        self:Flash(label .. ", " .. #failures .. " failed.")
        self:ReportFailures(label, applied, failures)
    end
    return true
end

--
--- ∑ Asks before an act that runs a script.
---
---   Activating an Auto Assembler record executes its ENABLE or DISABLE section
---   straight away, with no dialog of Cheat Engine's own. One script asks only
---   when the setting says so, and more than one always asks, because a click
---   that runs eleven scripts is worth a sentence.
--- @param label string
--- @param ids table
--- @return boolean # Whether the act may run.
--
function Window:AllowActivation(label, ids)
    local word = tostring(label):match("^(%a+)")
    if word == nil or not Window.ActivationWords[word] then return true end
    local snapshot = self.Snapshot
    if snapshot == nil then return true end
    local scripts = 0
    for _, id in ipairs(ids) do
        local node = snapshot.ByID[id]
        if node ~= nil and self.Types.IsScript(node) then scripts = scripts + 1 end
    end
    if scripts == 0 then return true end
    local settings = self.Settings
    local always = settings == nil or settings.ConfirmScriptActivation ~= false
    if scripts == 1 and not always then return true end
    local ce = self.CE
    if ce == nil then return false end
    return ce:Confirm("Run the Auto Assembler script of every selected record.",
        scripts, "Undo cannot take back what a script does.") == true
end

--- Remembers the records whose script was still running when the write came
--- back, so the sync tick can say what happened when it finishes.
function Window:CollectPending(label, ids)
    local ce, records = self.CE, self.Records
    if ce == nil or records == nil then return 0 end
    local now, held = self:Now(), 0
    for _, id in ipairs(ids) do
        local mr = records:Resolve(id, self.Snapshot)
        if mr ~= nil and ce:Get(mr, "Async") == true
            and ce:Get(mr, "AsyncProcessing") == true then
            self.Pending[id] = { At = now, Label = label }
            held = held + 1
        end
    end
    return held
end

--- The tree's activation box and its space bar. Both reach the one writer.
function Window:ToggleActive(ids)
    ids = copyIDs(ids)
    if #ids == 0 then return false end
    local snapshot = self.Snapshot
    local wanted = true
    local first = snapshot and snapshot.ByID[ids[1]] or nil
    if first ~= nil and first.Active == true then wanted = false end
    local label = (wanted and "Activate " or "Deactivate ")
        .. (#ids == 1 and ("'" .. self:NameOf(ids[1]) .. "'") or (#ids .. " records"))
    local props, records = self.Properties, self.Records
    if props == nil or records == nil then return false end
    return self:Act(label, ids, function()
        local applied, failures = 0, {}
        for _, id in ipairs(ids) do
            local mr = records:Resolve(id, self.Snapshot)
            if mr == nil then
                failures[#failures + 1] = { ID = id, Reason = "The record is gone." }
            else
                local ok, reason = props:Write(mr, "Active", wanted)
                if ok then applied = applied + 1
                else failures[#failures + 1] = { ID = id, Reason = reason } end
            end
        end
        return applied, failures
    end)
end

--------------------------------------------------------
--                    Undo and redo                   --
--------------------------------------------------------

--
--- ∑ Reads the address list again so undo and redo answer to the Cheat Table
---   that is really in front of them.
---
---   The history outlives the window, the sync timer is off whenever live sync
---   is, and a script calling Undo with no window open never polled at all. So
---   the table is read here rather than trusted from whenever the last tick
---   happened to be. A table that turned out to be another one takes the
---   history with it, which is the whole reason this is not left to a timer.
--- @return boolean # Whether the history was dropped by the read.
--
function Window:RefreshIdentity()
    local records = self.Records
    if records == nil then return false end
    local ok, snapshot = pcall(records.Structure, records)
    if not ok or snapshot == nil then return false end
    local _, dropped = self:TakeSnapshot(snapshot)
    return dropped == true
end

--- Puts the last transaction back. The journal writes through the appliers, so
--- an undo is exactly as guarded as the edit it reverses.
function Window:Undo()
    local journal = self.Journal
    -- Read first, write second. An id from the table before names a record in
    -- the table that is loaded now, and writing the old table's value into it
    -- is the one mistake this window must never make.
    if self:RefreshIdentity() then return false end
    if journal == nil or not journal:CanUndo() then
        self:Flash("There is nothing to undo.")
        return false
    end
    local label = journal:UndoLabel() or "the last edit"
    local applied, skipped = self:Guard(function() return journal:Undo() end)
    return self:AfterHistory("Undid", label, applied, skipped)
end

--- Does the last undone transaction again, in the order it was made.
function Window:Redo()
    local journal = self.Journal
    if self:RefreshIdentity() then return false end
    if journal == nil or not journal:CanRedo() then
        self:Flash("There is nothing to redo.")
        return false
    end
    local label = journal:RedoLabel() or "the last edit"
    local applied, skipped = self:Guard(function() return journal:Redo() end)
    return self:AfterHistory("Redid", label, applied, skipped)
end

--- What the two of them share. The whole snapshot is re-read rather than the
--- ids the transaction named, because undo is rare and a wrong tree is worse
--- than a slow one.
function Window:AfterHistory(verb, label, applied, skipped)
    applied = tonumber(applied) or 0
    skipped = type(skipped) == "table" and skipped or {}
    local ce = self.CE
    if ce ~= nil then
        ce:RebuildDescriptionCache()
        ce:RepaintList()
    end
    self:AfterWrite(nil, true)
    if #skipped == 0 then
        self:Flash(verb .. " " .. label .. ".")
        say(self, "Info", verb .. " " .. label .. ", " .. applied
            .. " change" .. s(applied) .. " written.")
    else
        self:Flash(verb .. " " .. label .. ", " .. #skipped .. " skipped.")
        self:ReportFailures(verb .. " " .. label, applied, skipped)
    end
    return applied > 0
end

--------------------------------------------------------
--                 Filtering and finding              --
--------------------------------------------------------

--- The filter box. Keeping the parsed query is the tree's job, so this only
--- passes the text along and reports the count.
function Window:SetFilter(text)
    local tree = self.Tree
    if tree == nil then return 0 end
    local count = tree:SetQuery(text or "")
    self:UpdateStatus()
    return count
end

--- Puts the caret in the filter box, from anywhere including from inside it.
function Window:FocusFilter()
    if self.FilterEdit == nil then return false end
    self.TextFocus = true
    return (pcall(function() self.FilterEdit.setFocus() end))
end

--- Shows the find bar and puts the caret in it.
function Window:ShowFind(replace)
    if self.FindBar == nil then return false end
    safeSet(self.FindBar, "Visible", true)
    if replace == false then safeSet(self.ReplaceEdit, "Text", "") end
    if self.FindEdit ~= nil then
        self.TextFocus = true
        pcall(function() self.FindEdit.setFocus() end)
    end
    return true
end

--- Hides the find bar again. The text stays, so reopening it carries on.
function Window:HideFind()
    if self.FindBar == nil then return false end
    if safeGet(self.FindBar, "Visible") ~= true then return false end
    safeSet(self.FindBar, "Visible", false)
    self.TextFocus = false
    return true
end

--- Whether the find bar is on screen.
function Window:FindShown()
    return safeGet(self.FindBar, "Visible") == true
end

--- Remembers a find bar check box in the settings, so the next window opens
--- the way this one was left.
function Window:SetSearchOption(key, value)
    local settings = self.Settings
    if settings == nil or type(settings.Set) ~= "function" then return false end
    return (pcall(settings.Set, settings, "Search." .. key, value == true))
end

--- The In box moved, so the three field flags are written as one set.
function Window:FindFieldsChanged()
    local index = (integer(safeGet(self.FieldCombo, "ItemIndex")) or 0) + 1
    local entry = Window.FindFields[index]
    if entry == nil then return false end
    for _, field in ipairs({ "Description", "Script", "DropDown" }) do
        self:SetSearchOption(field, entry.Fields[field] == true)
    end
    return true
end

--- The Scope box moved.
function Window:FindScopeChanged()
    local index = (integer(safeGet(self.ScopeCombo, "ItemIndex")) or 0) + 1
    local scope = Window.FindScopes[index]
    if scope == nil then return false end
    local settings = self.Settings
    if settings == nil or type(settings.Set) ~= "function" then return false end
    return (pcall(settings.Set, settings, "Search.Scope", scope))
end

--- The options a find runs with, read off the bar and off the settings.
function Window:FindOptions()
    local settings = self.Settings
    local search = (settings and settings.Search) or {}
    local index = (integer(safeGet(self.FieldCombo, "ItemIndex")) or 0) + 1
    local entry = Window.FindFields[index] or Window.FindFields[2]
    local options = {
        Needle = safeGet(self.FindEdit, "Text") or "",
        Replacement = safeGet(self.ReplaceEdit, "Text") or "",
        Fields = entry.Fields,
        MatchCase = search.MatchCase == true,
        WholeWord = search.WholeWord == true,
        IDs = nil
    }
    local scopeIndex = (integer(safeGet(self.ScopeCombo, "ItemIndex")) or 0) + 1
    local scope = Window.FindScopes[scopeIndex] or search.Scope or "All"
    options.Scope = scope
    if scope == "Selection" then
        options.IDs = idSet(self:SelectedIDs())
    elseif scope == "Visible" and self.Tree ~= nil then
        local visible = self.Tree.Visible
        if visible ~= nil then options.IDs = visible end
    end
    return options
end

--
--- ∑ Runs the find bar. Find all lists every match, replace all builds one
---   transaction out of the plan and sends it through the commit funnel, so
---   four hundred renames are one undo entry.
--- @param replaceAll boolean|nil
--- @return number # How many matches or how many changes.
--
function Window:RunFind(replaceAll)
    local search, records = self.Search, self.Records
    if search == nil or records == nil or self.Snapshot == nil then return 0 end
    local options = self:FindOptions()
    if options.Needle == "" then
        self:Flash("Type what you are looking for first.")
        return 0
    end
    if not replaceAll then
        local hits = search:Hits(self.Snapshot, options)
        local items = {}
        for index, hit in ipairs(hits) do
            items[index] = {
                ID = hit.ID, Field = hit.Field, Line = hit.Line,
                Column = hit.Column, Length = hit.Length,
                Label = records:Path(self.Snapshot, hit.ID),
                Message = hit.Excerpt
            }
        end
        self:ShowResults("Matches", items)
        self:Flash(#hits .. " match" .. (#hits == 1 and "" or "es") .. " for '"
            .. options.Needle .. "'.")
        return #hits
    end

    local plan, skipped = search:Plan(self.Snapshot, options)
    if #plan == 0 then
        self:Flash("Nothing to replace.")
        if #skipped > 0 then
            self:ReportFailures("Replace all", 0, skipped)
        end
        return 0
    end
    local changes = {}
    for _, entry in ipairs(plan) do
        local change = self:ChangeForField(entry)
        if change ~= nil then changes[#changes + 1] = change end
    end
    local label = "Replace '" .. options.Needle .. "' in " .. #changes
        .. " field" .. s(#changes)
    local ok, applied = self:Commit({ Label = label, Changes = changes })
    if #skipped > 0 then self:ReportFailures(label, applied or 0, skipped) end
    return (ok and applied) or 0
end

--- One replacement, in the shape the applier for its field takes.
function Window:ChangeForField(entry)
    if entry.Field == "Description" then
        return { Kind = "property", ID = entry.ID, Key = "Description",
                 Old = entry.Old, New = entry.New }
    end
    if entry.Field == "Script" then
        return { Kind = "script", ID = entry.ID, Old = entry.Old, New = entry.New }
    end
    if entry.Field == "DropDown" then
        return { Kind = "dropdown", ID = entry.ID,
                 Old = { Text = entry.Old }, New = { Text = entry.New } }
    end
    return nil
end

--------------------------------------------------------
--                  Problems and results              --
--------------------------------------------------------

--
--- ∑ Checks the table and fills the results strip.
---
---   Detail is loaded first, because most of the checks read fields the re-read
---   window may not have reached yet and a check against a half read snapshot
---   reports problems that are not there.
--- @return table # The problems, in pre-order.
--
function Window:RunProblems()
    local lint, records = self.Lint, self.Records
    if lint == nil or records == nil or self.Snapshot == nil then return {} end
    local settings = self.Settings
    local options = {
        ReadValues = settings and settings.Lint and settings.Lint.ReadValues == true,
        Assemble = settings and settings.Lint and settings.Lint.Assemble == true
    }
    local problems, stats = self:Guard(function()
        records:EnsureDetail(self.Snapshot, nil)
        return lint:Run(self.Snapshot, options)
    end)
    problems = problems or {}
    stats = stats or { Errors = 0, Warnings = 0, Infos = 0, Checked = 0, Took = 0 }

    self.Problems = problems
    self.ProblemMap = lint.ByID(problems)
    if self.Tree ~= nil then self.Tree:SetProblems(self.ProblemMap) end

    local items = {}
    for index, problem in ipairs(problems) do
        items[index] = {
            ID = problem.ID, Severity = problem.Severity, Line = problem.Line,
            Field = problem.Field, Label = records:Path(self.Snapshot, problem.ID),
            Message = problem.Message
        }
    end
    self:ShowResults("Problems", items)
    if #problems == 0 then
        self:Flash("No problems found in " .. stats.Checked .. " records.")
        say(self, "Info", "Checked " .. stats.Checked .. " records and found nothing wrong.")
    else
        self:Flash(#problems .. " problem" .. s(#problems) .. " found.")
        local log = self.Log
        if log ~= nil then
            pcall(function()
                log:Info(log:Block("Checked " .. stats.Checked .. " records", {
                    { "Errors", stats.Errors }, { "Warnings", stats.Warnings },
                    { "Notes", stats.Infos },
                    { "Took", string.format("%.1f ms", stats.Took or 0) }
                }))
            end)
        end
    end
    self:UpdateStatus()
    return problems
end

--- The history, newest first, in the results strip.
function Window:ShowChanges()
    local journal = self.Journal
    if journal == nil then return 0 end
    local items = {}
    for index, entry in ipairs(journal:Entries()) do
        items[index] = {
            Tag = os.date("%H:%M:%S", entry.Stamp),
            Label = entry.Undone and "undone" or "",
            Message = entry.Label .. "  (" .. entry.Count
                .. " change" .. s(entry.Count) .. ")"
        }
    end
    self:ShowResults("Changes", items)
    return #items
end

--- Fills the strip and shows it. The kind decides the tag column and the two
--- lines the strip says when it holds nothing.
function Window:ShowResults(kind, items)
    local results = self.Results
    if results == nil then return 0 end
    -- A kind the strip has no empty state for would leave a person with two
    -- blank lines where a sentence belongs, so it falls back to none.
    if kind ~= nil and not Window.ResultKinds[kind] then kind = nil end
    self.ResultKind = kind
    local count = results:SetItems(kind, items or {})
    safeSet(self.ResultsCounter, "Caption", tostring(count))
    self:ShowResultsCard(true)
    return count
end

--- Shows or hides the results card and its splitter together. One without the
--- other leaves a divider floating over the tree.
function Window:ShowResultsCard(shown)
    safeSet(self.ResultsCard, "Visible", shown == true)
    safeSet(self.ResultsSplitter, "Visible", shown == true)
    return shown == true
end

--- A row in the strip was clicked. It moves the tree without opening anything,
--- because a single click is a look and not an edit.
function Window:ResultPicked(item)
    if item == nil or item.ID == nil then return false end
    return self:Select({ item.ID })
end

--- A row in the strip was opened, which takes the inspector to the page that
--- can do something about it.
function Window:ResultOpened(item)
    if item == nil or item.ID == nil then return false end
    -- A refused selection has already asked its question. Going on to the page
    -- would ask the same one a second time for the one double click.
    if not self:Select({ item.ID }) then return false end
    local inspector = self.Inspector
    if inspector == nil then return false end
    if item.Field == "Script" then return inspector:ShowPage("Script") end
    if item.Field == "DropDown" then return inspector:ShowPage("DropDown") end
    return inspector:ShowPage("Properties")
end

--------------------------------------------------------
--                  What the tree asks                --
--------------------------------------------------------

--
--- ∑ The selection moved, so the inspector follows it and the status line
---   counts what the next action will touch.
---
---   The tree moves its own selection before anyone hears about it, so a page
---   that refuses to be left cannot simply be believed and left alone. The ids
---   the window had are kept until the inspector has taken the new ones, and a
---   refusal puts those ids back on the tree instead.
--- @param ids table|nil
--- @param focusId number|nil
--- @param forced boolean|nil # The tree changed the selection itself.
--- @return number # How many records are selected now.
--
function Window:SelectionChanged(ids, focusId, forced)
    local previous, previousFocus = self.LastSelection, self.LastFocus
    local wanted = copyIDs(ids)
    if self.Inspector ~= nil then
        local allowed = self.Inspector:SetSelection(wanted, self.Snapshot,
            forced == true or self.Restoring == true)
        if allowed == false then
            self:RestoreSelection(previous, previousFocus)
            return #self.LastSelection
        end
    end
    self.LastSelection, self.LastFocus = wanted, focusId
    if self.Results ~= nil and focusId ~= nil then
        local index = self.Results:IndexOfID(focusId)
        if index ~= nil then self.Results:Select(index, true) end
    end
    self:UpdateStatus()
    return #self.LastSelection
end

--
--- ∑ Puts the tree back on the records the inspector refused to leave.
---
---   Cancel has to mean the old record stays selected and the buffer stays with
---   it, so the tree is pressed back the way the tab strip is pressed back onto
---   a page that refused. The round trip that causes is marked, because the
---   nested report would otherwise ask the same question again and overwrite
---   what is being put back halfway through.
--- @param ids table|nil
--- @param focusId number|nil
--- @return boolean
--
function Window:RestoreSelection(ids, focusId)
    local tree = self.Tree
    if tree == nil then return false end
    self.Restoring = true
    local ok = pcall(tree.Select, tree, copyIDs(ids), focusId, true)
    self.Restoring = false
    self:UpdateStatus()
    return ok == true
end

--- A record was opened in the tree, which means the page that edits it.
function Window:OpenRecord(id)
    local inspector = self.Inspector
    if inspector == nil or id == nil then return false end
    local node = self.Snapshot and self.Snapshot.ByID[id] or nil
    if node ~= nil and self.Types.IsScript(node) then return inspector:ShowPage("Script") end
    if node ~= nil and self.Types.IsPointer(node) then return inspector:ShowPage("Pointer") end
    return inspector:ShowPage("Properties")
end

--- The ids the next action will touch, in pre-order.
function Window:SelectedIDs()
    if self.Tree == nil then return {} end
    return self.Tree:Selection()
end

--
--- ∑ Selects records from outside the tree, which is what a results row, a
---   linked drop-down and the public object all do.
---
---   The answer is whether the selection really landed. A page holding an
---   unsaved change can refuse to be left, and the tree is then put back where
---   it was, so a caller about to do something with the new selection has to
---   hear that it never got one.
--- @param ids table|nil
--- @return boolean
--
function Window:Select(ids)
    local tree = self.Tree
    if tree == nil then return false end
    ids = copyIDs(ids)
    tree:Select(ids, ids[1], true)
    for _, id in ipairs(ids) do
        if not tree:IsSelected(id) then return false end
    end
    return true
end

--------------------------------------------------------
--                      Structure                     --
--------------------------------------------------------

--- Where the keyboard is, as a record and its siblings. Every move works
--- inside one group, because Cheat Engine offers nothing that reorders the
--- root.
function Window:MoveContext()
    local snapshot = self.Snapshot
    local tree = self.Tree
    if snapshot == nil or tree == nil then return nil end
    local id = tree:Focused()
    if id == nil then return nil end
    local node = snapshot.ByID[id]
    if node == nil then return nil end
    if node.ParentID == nil then
        return nil, "Cheat Engine offers no way to reorder records at the root."
    end
    local parent = snapshot.ByID[node.ParentID]
    if parent == nil then return nil, "The group is gone." end
    local order, index = {}, nil
    for position, child in ipairs(parent.Children) do
        order[position] = child
        if child == id then index = position end
    end
    if index == nil then return nil, "The record is not in its group any more." end
    return { ID = id, ParentID = node.ParentID, Order = order, Index = index }
end

--- Moves the focused record one place up inside its group.
function Window:MoveUp()
    return self:MoveBy(-1)
end

--- Moves the focused record one place down inside its group.
function Window:MoveDown()
    return self:MoveBy(1)
end

function Window:MoveBy(step)
    local context, reason = self:MoveContext()
    if context == nil then
        self:Flash(reason or "There is nothing to move.")
        return false
    end
    local target = context.Index + step
    if target < 1 or target > #context.Order then return false end
    local wanted = copyIDs(context.Order)
    wanted[context.Index], wanted[target] = wanted[target], wanted[context.Index]
    local label = (step < 0 and "Move up " or "Move down ")
        .. "'" .. self:NameOf(context.ID) .. "'"
    local ok, applied = self:Commit({ Label = label, Changes = { {
        Kind = "order", ID = context.ParentID, ParentID = context.ParentID,
        Old = copyIDs(context.Order), New = wanted
    } } })
    return ok and applied > 0
end

--- Puts the children of the focused record's group in description order.
function Window:SortChildren()
    local snapshot = self.Snapshot
    local tree = self.Tree
    if snapshot == nil or tree == nil then return false end
    local id = tree:Focused()
    local node = id and snapshot.ByID[id] or nil
    -- A group header sorts its own children, and a plain record sorts the
    -- group it sits in, which is what a person pointing at a row means.
    local parentId = nil
    if node ~= nil and #node.Children > 0 then parentId = node.ID
    elseif node ~= nil then parentId = node.ParentID end
    if parentId == nil then
        self:Flash("Cheat Engine offers no way to reorder records at the root.")
        return false
    end
    local parent = snapshot.ByID[parentId]
    if parent == nil or #parent.Children < 2 then return false end

    local order = copyIDs(parent.Children)
    local wanted = copyIDs(order)
    table.sort(wanted, function(a, b)
        local first = (snapshot.ByID[a] and snapshot.ByID[a].Description) or ""
        local second = (snapshot.ByID[b] and snapshot.ByID[b].Description) or ""
        if first:lower() == second:lower() then return a < b end
        return first:lower() < second:lower()
    end)
    local ok, applied = self:Commit({
        Label = "Sort " .. #wanted .. " records in '" .. self:NameOf(parentId) .. "'",
        Changes = { { Kind = "order", ID = parentId, ParentID = parentId,
                      Old = order, New = wanted } }
    })
    return ok and applied > 0
end

--
--- ∑ Moves the selection into a group the person picks.
---
---   Records that came out of a group can be put back, because re-appending
---   every child of that group in the old order is a move Cheat Engine can do.
---   Records that came from the root cannot, so that case runs as an act and
---   says so.
--- @return boolean
--
function Window:MoveIntoGroup()
    local snapshot, records, theme = self.Snapshot, self.Records, self.Theme
    if snapshot == nil or records == nil or theme == nil then return false end
    local ids = self:SelectedIDs()
    if #ids == 0 then
        self:Flash("Select the records to move first.")
        return false
    end
    local moving = idSet(ids)
    local items = {}
    for _, node in ipairs(snapshot.Order) do
        if #node.Children > 0 or node.IsGroupHeader then
            local inside = moving[node.ID] == true
            for _, id in ipairs(ids) do
                if RecordsModule.IsAncestor(snapshot, id, node.ID) then inside = true end
            end
            if not inside then
                items[#items + 1] = { Key = tostring(node.ID),
                                      Label = records:Path(snapshot, node.ID) }
            end
        end
    end
    if #items == 0 then
        self:Flash("There is no group to move these into.")
        return false
    end
    local chosen = self:Guard(function()
        return theme:AskPick({ Caption = "Move into group",
            Title = "Which group should these " .. #ids .. " records go into",
            Items = items, Placeholder = "filter the groups" })
    end)
    local targetId = integer(chosen)
    if targetId == nil then return false end

    local fromRoot = false
    for _, id in ipairs(ids) do
        local node = snapshot.ByID[id]
        if node ~= nil and node.ParentID == nil then fromRoot = true end
    end
    local label = "Move " .. #ids .. " record" .. s(#ids)
        .. " into '" .. self:NameOf(targetId) .. "'"
    if fromRoot then
        local ce = self.CE
        if ce ~= nil and not ce:Confirm(label,
            #ids, "Records moved out of the root cannot be moved back by Cheat Engine.") then
            return false
        end
        return self:Act(label, ids, function()
            local moved, failures = records:MoveInto(self.Snapshot, ids, targetId)
            self:AfterWrite(nil, true)
            return #moved, failures
        end)
    end

    -- Every record came out of a group, so the move is two order changes per
    -- group and undo puts them back. The target goes first, because that is
    -- the change that moves them, and by the time the old parents are asked
    -- for their new order the records have already left.
    local moving = {}
    for _, node in ipairs(snapshot.Order) do
        if idSet(ids)[node.ID] then moving[#moving + 1] = node.ID end
    end
    local target = snapshot.ByID[targetId]
    local after = copyIDs(target.Children)
    local held = idSet(target.Children)
    for _, id in ipairs(moving) do
        if not held[id] then after[#after + 1] = id end
    end
    local changes = { { Kind = "order", ID = targetId, ParentID = targetId,
                        Old = copyIDs(target.Children), New = after } }
    local seen, leaving = {}, idSet(moving)
    for _, id in ipairs(moving) do
        local parentId = snapshot.ByID[id].ParentID
        if parentId ~= nil and parentId ~= targetId and not seen[parentId] then
            seen[parentId] = true
            local before, left = copyIDs(snapshot.ByID[parentId].Children), {}
            for _, child in ipairs(before) do
                if not leaving[child] then left[#left + 1] = child end
            end
            changes[#changes + 1] = { Kind = "order", ID = parentId, ParentID = parentId,
                                      Old = before, New = left }
        end
    end
    local ok, applied = self:Commit({ Label = label, Changes = changes })
    return ok and applied > 0
end

--
--- ∑ Makes one record or one group. Cheat Engine deletes records and this
---   window does not, so this is asked for and cannot be undone.
--- @param group boolean|nil # A group header rather than a plain record.
--- @return number|nil # The new id.
--
function Window:NewRecord(group)
    local records, ce = self.Records, self.CE
    if records == nil or ce == nil then return nil end
    local what = group and "group" or "record"
    if not ce:Confirm("Add a new " .. what .. " to this Cheat Table.", nil,
        "Cheat Engine deletes records, this window does not.") then
        return nil
    end
    local parentId = nil
    local focus = self.Tree and self.Tree:Focused() or nil
    local node = focus and self.Snapshot and self.Snapshot.ByID[focus] or nil
    if node ~= nil then
        parentId = (#node.Children > 0 or node.IsGroupHeader) and node.ID or node.ParentID
    end
    local created = nil
    self:Act("New " .. what, {}, function()
        local id, reason = records:Create(parentId, {
            Description = group and "New group" or "New record",
            IsGroupHeader = group == true
        })
        created = id
        if id == nil then return 0, { { Reason = reason } } end
        return 1, {}
    end)
    self:AfterWrite(nil, true)
    if created ~= nil then self:Select({ created }) end
    return created
end

--------------------------------------------------------
--                 Copying and exporting              --
--------------------------------------------------------

--- Copies something about the selection to the clipboard.
function Window:CopyAs(kind)
    local ce, records, snapshot = self.CE, self.Records, self.Snapshot
    if ce == nil or records == nil or snapshot == nil then return false end
    local ids = self:SelectedIDs()
    if #ids == 0 then
        self:Flash("Select a record first.")
        return false
    end
    local lines = {}
    for _, id in ipairs(ids) do
        local node = snapshot.ByID[id]
        if node ~= nil then
            if kind == "address" then
                lines[#lines + 1] = tostring(node.AddressString or "")
            elseif kind == "path" then
                lines[#lines + 1] = records:Path(snapshot, id)
            elseif kind == "pointer" then
                lines[#lines + 1] = self:PointerText(id, node)
            elseif kind == "value" then
                local mr = records:Resolve(id, snapshot)
                lines[#lines + 1] = tostring((mr and ce:Get(mr, "DisplayValue")) or "")
            else
                lines[#lines + 1] = tostring(node.Description or "")
            end
        end
    end
    if kind == "json" then
        local export = self.Export
        if export == nil then return false end
        local items = export:Collect(snapshot, ids, { IncludeChildren = true })
        lines = { export:Build(items, "json") }
    end
    local text = table.concat(lines, "\n")
    ce:ToClipboard(text)
    self:Flash("Copied " .. #ids .. " record" .. s(#ids) .. ".")
    say(self, "Info", "Copied " .. #ids .. " record" .. s(#ids) .. " to the clipboard.")
    return true
end

--- One pointer chain as text, written the way a person reads it, which is the
--- base first and then each dereference.
function Window:PointerText(id, node)
    local props, records = self.Properties, self.Records
    if props == nil or records == nil then return tostring(node.AddressString or "") end
    local mr = records:Resolve(id, self.Snapshot)
    if mr == nil then return tostring(node.AddressString or "") end
    local pointer = props:ReadPointer(mr)
    if type(pointer) ~= "table" then return tostring(node.AddressString or "") end
    local parts = { tostring(pointer.Base or "") }
    -- Offsets come back with Offset zero first and that one is applied last,
    -- so the chain reads backwards from the way Cheat Engine stores it.
    for index = #pointer.Offsets, 1, -1 do
        parts[#parts + 1] = tostring(pointer.Offsets[index])
    end
    return table.concat(parts, " -> ")
end

--- Opens Cheat Engine's memory view on the focused record's address.
function Window:ShowInMemoryView()
    local ce, records = self.CE, self.Records
    local tree = self.Tree
    if ce == nil or records == nil or tree == nil then return false end
    local id = tree:Focused()
    if id == nil then return false end
    local mr = records:Resolve(id, self.Snapshot)
    if mr == nil then return false end
    local address = ce:Get(mr, "CurrentAddress")
    if type(address) ~= "number" or address == 0 then
        self:Flash("'" .. self:NameOf(id) .. "' resolves to nothing right now.")
        return false
    end
    local ok = ce:ShowInMemoryView(address)
    if ok then say(self, "Info", "Showed '" .. self:NameOf(id) .. "' in the memory view.") end
    return ok
end

--- Selects the focused record in Cheat Engine's own list. Cheat Engine holds
--- one selected record, so only the focus goes over.
function Window:SelectInCE()
    local ce, tree = self.CE, self.Tree
    if ce == nil or tree == nil then return false end
    local id = tree:Focused()
    if id == nil then return false end
    local ok = ce:SelectRecord(id)
    if ok then
        self.MirroredID = id
        self:Flash("Selected '" .. self:NameOf(id) .. "' in Cheat Engine.")
    end
    return ok
end

--
--- ∑ Writes the selection to a file the person picks.
---
---   The dialog is a modal, so the whole thing runs inside the busy guard and
---   neither timer fires while it is open.
--- @return boolean
--
function Window:ExportSelection()
    local export, ce = self.Export, self.CE
    if export == nil or ce == nil or self.Snapshot == nil then return false end
    local ids = self:SelectedIDs()
    if #ids == 0 then ids = copyIDs(self.Snapshot.Roots) end
    if #ids == 0 then
        self:Flash("There is nothing to export.")
        return false
    end
    local settings = self.Settings
    local options = (settings and settings.Export) or {}
    local path = self:Guard(function()
        return ce:SaveFile({
            Title = "Export records",
            Filter = "JSON (*.json)|*.json|CSV (*.csv)|*.csv|Markdown (*.md)|*.md|Text (*.txt)|*.txt",
            DefaultExt = "json", FileName = "address-list.json"
        })
    end)
    if type(path) ~= "string" or path == "" then return false end

    local format = export.FormatFor(path) or "json"
    local items = export:Collect(self.Snapshot, ids, {
        IncludeScripts = options.IncludeScripts ~= false,
        IncludeValues = options.IncludeValues == true,
        IncludeChildren = options.IncludeChildren ~= false
    })
    local text = export:Build(items, format)
    local ok, reason = export:Write(path, text)
    if not ok then
        self:Flash("The export failed. " .. tostring(reason))
        say(self, "Warning", "Export to " .. path .. " failed. " .. tostring(reason))
        return false
    end
    self:Flash("Exported " .. #ids .. " record" .. s(#ids) .. ".")
    local log = self.Log
    if log ~= nil then
        pcall(function()
            log:Info(log:Block("Exported the selection", {
                { "Records", #ids }, { "Format", format }, { "File", path },
                { "Bytes", #text }
            }))
        end)
    end
    return true
end

--------------------------------------------------------
--                      The menus                     --
--------------------------------------------------------

--- Both menus, plus the one on the results strip. Every menu is attached to a
--- windowed panel, because a paint box has no window handle and a menu hung
--- off one would never be shown.
function Window:BuildMenus()
    local theme = self.Theme
    if theme == nil then return false end
    self:BuildTreeMenu(theme)
    self:BuildMainMenu(theme)
    self:BuildResultsMenu(theme)
    return true
end

function Window:BuildTreeMenu(theme)
    local host = self.TreeContent
    if host == nil then return nil end
    local menu = theme:CreatePopupMenu(host)
    if menu == nil then return nil end
    self.TreeMenu = menu
    local add = menu.Add

    add("Activate", function() self:ToggleActive(self:SelectedIDs()) end,
        { Key = "activate", Shortcut = "Space", Icon = "Live" })
    add("Edit description", function() self:EditDescription() end,
        { Key = "describe", Shortcut = "F2" })
    add("Script", function() self.Inspector:ShowPage("Script") end,
        { Key = "script", Shortcut = "Ctrl+E", Icon = "Script" })
    add("Pointer", function() self.Inspector:ShowPage("Pointer") end,
        { Key = "pointer", Shortcut = "Ctrl+P" })
    add("-")

    local copyItem = add("Copy", nil, { Key = "copy", Icon = "Copy" })
    if copyItem then
        add("Description", function() self:CopyAs("description") end,
            { Parent = copyItem, Key = "copydesc", Shortcut = "Ctrl+C" })
        add("Address", function() self:CopyAs("address") end,
            { Parent = copyItem, Key = "copyaddr" })
        add("Pointer path", function() self:CopyAs("pointer") end,
            { Parent = copyItem, Key = "copyptr", Shortcut = "Ctrl+Shift+C" })
        add("Value", function() self:CopyAs("value") end,
            { Parent = copyItem, Key = "copyvalue" })
        add("As JSON", function() self:CopyAs("json") end,
            { Parent = copyItem, Key = "copyjson" })
    end
    add("Show in memory view", function() self:ShowInMemoryView() end,
        { Key = "memview", Shortcut = "Ctrl+G", Icon = "MemoryView" })
    add("Select in Cheat Engine", function() self:SelectInCE() end, { Key = "selectce" })
    add("-")
    add("New record here", function() self:NewRecord(false) end, { Key = "newrecord" })
    add("New group here", function() self:NewRecord(true) end,
        { Key = "newgroup", Icon = "Folder" })
    add("Move into group...", function() self:MoveIntoGroup() end, { Key = "moveinto" })
    add("Move up", function() self:MoveUp() end, { Key = "moveup", Shortcut = "Ctrl+Up" })
    add("Move down", function() self:MoveDown() end, { Key = "movedown", Shortcut = "Ctrl+Down" })
    add("Sort children by description", function() self:SortChildren() end, { Key = "sort" })
    add("-")
    add("Expand all", function() self.Tree:ExpandAll() end, { Key = "expandall" })
    add("Collapse all", function() self.Tree:CollapseAll() end, { Key = "collapseall" })
    add("Select children", function() self:SelectChildren() end, { Key = "selectchildren" })
    add("Select same type", function() self:SelectSameType() end, { Key = "selectsame" })
    add("-")
    add("Export selection...", function() self:ExportSelection() end,
        { Key = "export", Icon = "Export" })

    -- The LCL shows an attached menu itself on the right button, so nothing
    -- here pops it. OnPopup is where the enable states and the one caption that
    -- moves are worked out, one moment before they are read.
    safeSet(menu.Menu, "OnPopup", function() self:MenuOpening() end)
    return menu
end

function Window:BuildMainMenu(theme)
    local host = self.MenuButton or self.ToolBar
    if host == nil then return nil end
    local menu = theme:CreatePopupMenu(host)
    if menu == nil then return nil end
    self.MainMenu = menu
    local add = menu.Add
    local settings = self.Settings

    local viewItem = add("View", nil, { Key = "view", Icon = "Eye" })
    if viewItem then
        add("Show values", function() self:ToggleColumn("ShowValues") end,
            { Parent = viewItem, Key = "showvalues",
              Checked = settings == nil or settings.ShowValues ~= false })
        add("Show addresses", function() self:ToggleColumn("ShowAddresses") end,
            { Parent = viewItem, Key = "showaddresses",
              Checked = settings == nil or settings.ShowAddresses ~= false })
        add("-", nil, { Parent = viewItem })
        -- Spelled into the caption. The LCL draws a popup menu's shortcut but
        -- never dispatches it, so an accelerator here would look real and do
        -- nothing. HandleKey dispatches these.
        add("Larger text  (Ctrl +)", function() self:ChangeFontSize(1) end,
            { Parent = viewItem, Key = "fontup" })
        add("Smaller text  (Ctrl -)", function() self:ChangeFontSize(-1) end,
            { Parent = viewItem, Key = "fontdown" })
    end

    local syncItem = add("Sync", nil, { Key = "sync", Icon = "Live" })
    if syncItem then
        add("Live sync", function() self:SetLiveSync(not self:LiveSyncOn()) end,
            { Parent = syncItem, Key = "livesync",
              Checked = settings == nil or settings.LiveSync ~= false })
        add("Follow Cheat Engine selection", function() self:ToggleSetting("FollowCESelection") end,
            { Parent = syncItem, Key = "followce",
              Checked = settings ~= nil and settings.FollowCESelection == true })
        add("Mirror selection to Cheat Engine", function() self:ToggleSetting("MirrorSelectionToCE") end,
            { Parent = syncItem, Key = "mirrorce",
              Checked = settings ~= nil and settings.MirrorSelectionToCE == true })
    end

    local problemItem = add("Problems", nil, { Key = "problems", Icon = "Problems" })
    if problemItem then
        add("Read values while checking", function() self:ToggleSetting("Lint.ReadValues") end,
            { Parent = problemItem, Key = "lintvalues",
              Checked = settings ~= nil and settings.Lint.ReadValues == true })
        add("Assemble scripts while checking", function() self:ToggleSetting("Lint.Assemble") end,
            { Parent = problemItem, Key = "lintassemble",
              Checked = settings ~= nil and settings.Lint.Assemble == true })
    end

    add("-")
    add("Changes this session", function() self:ShowChanges() end,
        { Key = "changes", Icon = "Changes" })
    add("Diagnostics", function() self:Diagnostics() end,
        { Key = "diagnostics", Icon = "Diagnostics" })
    add("About", function() self:About() end, { Key = "about", Icon = "About" })

    safeSet(menu.Menu, "OnPopup", function() self:MainMenuOpening() end)
    if self.MenuButton ~= nil then menu.Attach(self.MenuButton) end
    return menu
end

function Window:BuildResultsMenu(theme)
    local host = self.ResultsContent
    if host == nil then return nil end
    local menu = theme:CreatePopupMenu(host)
    if menu == nil then return nil end
    self.ResultsMenu = menu
    menu.Add("Copy message", function() self:CopyResult(false) end, { Key = "copyone" })
    menu.Add("Copy all", function() self:CopyResult(true) end, { Key = "copyall" })
    menu.Add("Clear", function()
        self:ShowResults(self.ResultKind, {})
        self:ShowResultsCard(false)
    end, { Key = "clear", Icon = "Clear" })
    return menu
end

--
--- ∑ Works out what the tree menu may do, one moment before it is read.
---
---   Every state here depends on the selection and on where the focus sits, and
---   both of those move between two right clicks. Computing them at build time
---   would grey out Move up forever, because at build time there is no
---   selection at all.
--- @return boolean
--
function Window:MenuOpening()
    local menu = self.TreeMenu
    if menu == nil then return false end
    local ids = self:SelectedIDs()
    local many = #ids > 0
    local one = #ids == 1
    local snapshot = self.Snapshot
    local focus = self.Tree and self.Tree:Focused() or nil
    local node = (focus ~= nil and snapshot ~= nil) and snapshot.ByID[focus] or nil
    local context = self:MoveContext()

    -- The verb has to be the one the click will really carry out. Toggling
    -- reads the first selected record and not the focused one, and those two
    -- are different records the moment somebody extends a selection upwards, so
    -- the caption follows the same record the action does.
    local first = (ids[1] ~= nil and snapshot ~= nil) and snapshot.ByID[ids[1]] or nil
    safeSet(menu.Entries and menu.Entries.activate, "Caption",
        (first ~= nil and first.Active == true) and "Deactivate" or "Activate")

    menu.Enable("activate", many)
    menu.Enable("describe", one)
    menu.Enable("script", one and node ~= nil and self.Types.IsScript(node))
    menu.Enable("pointer", one and node ~= nil and not self.Types.IsGroup(node))
    menu.Enable("copy", many)
    menu.Enable("copydesc", many)
    menu.Enable("copyaddr", many)
    menu.Enable("copyptr", many)
    menu.Enable("copyvalue", many)
    menu.Enable("copyjson", many)
    menu.Enable("memview", one and node ~= nil and not self.Types.IsGroup(node))
    menu.Enable("selectce", one)
    menu.Enable("moveinto", many)
    menu.Enable("moveup", context ~= nil and context.Index > 1)
    menu.Enable("movedown", context ~= nil and context.Index < #context.Order)
    menu.Enable("sort", node ~= nil and (#node.Children > 1
        or (node.ParentID ~= nil and snapshot.ByID[node.ParentID] ~= nil
            and #snapshot.ByID[node.ParentID].Children > 1)))
    menu.Enable("selectchildren", node ~= nil and #node.Children > 0)
    menu.Enable("selectsame", one)
    menu.Enable("export", true)
    menu.Enable("newrecord", true)
    menu.Enable("newgroup", true)
    return true
end

--- The menu button's own menu, whose items are all switches, so what it sets
--- just in time is every tick rather than every enable state.
function Window:MainMenuOpening()
    local menu = self.MainMenu
    if menu == nil then return false end
    local settings = self.Settings
    menu.Check("showvalues", settings == nil or settings.ShowValues ~= false)
    menu.Check("showaddresses", settings == nil or settings.ShowAddresses ~= false)
    menu.Check("livesync", self:LiveSyncOn())
    menu.Check("followce", settings ~= nil and settings.FollowCESelection == true)
    menu.Check("mirrorce", settings ~= nil and settings.MirrorSelectionToCE == true)
    menu.Check("lintvalues", settings ~= nil and settings.Lint.ReadValues == true)
    menu.Check("lintassemble", settings ~= nil and settings.Lint.Assemble == true)
    menu.Enable("changes", self.Journal ~= nil and #self.Journal:Entries() > 0)
    return true
end

--- Pops the menu button's menu at the cursor. Without getMousePos it lands at
--- the window's own corner, which is wrong but visible.
function Window:ShowMainMenu()
    local menu = self.MainMenu
    if menu == nil then return false end
    self:MainMenuOpening()
    local x, y
    local getMousePos = rawget(_G, "getMousePos")
    if type(getMousePos) == "function" then
        pcall(function() x, y = getMousePos() end)
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        x, y = 0, 0
        pcall(function()
            x = (integer(self.Form.Left) or 0) + 24
            y = (integer(self.Form.Top) or 0) + 64
        end)
    end
    if not (pcall(function() menu.Menu.popup(x, y) end)) then
        self:Flash("This Cheat Engine cannot open a menu from a button. "
            .. "Right-click the record list instead.")
        return false
    end
    return true
end

--- Whether the poll is on right now.
function Window:LiveSyncOn()
    local settings = self.Settings
    return settings == nil or settings.LiveSync ~= false
end

--- Flips one boolean setting and tells whatever cares about it.
function Window:ToggleSetting(key)
    local settings = self.Settings
    if settings == nil or type(settings.Get) ~= "function" then return false end
    local value = settings:Get(key) ~= true
    pcall(settings.Set, settings, key, value)
    return value
end

--- Flips one of the two optional tree columns.
function Window:ToggleColumn(key)
    local value = self:ToggleSetting(key)
    if self.Tree ~= nil then self.Tree:SetColumns({ [key] = value }) end
    return value
end

--- Larger or smaller text on every canvas at once. The size lives in the
--- settings and the frame service pushes it out, so no canvas decides its own.
function Window:ChangeFontSize(step)
    local frame = self.Frame
    if frame == nil then return nil end
    local size, moved = frame:SetFontSize(frame.FontSize + (tonumber(step) or 0))
    if moved then
        frame:Invalidate()
        self:Flash("Text size " .. size .. ".")
    end
    return size
end

--- Copies one result row, or every one of them.
function Window:CopyResult(all)
    local results, ce = self.Results, self.CE
    if results == nil or ce == nil then return false end
    local lines = {}
    if all then
        for _, item in ipairs(results.Items) do
            lines[#lines + 1] = item.Tag .. "  " .. item.Label .. "  " .. item.Message
        end
    else
        local item = results:Selected()
        if item == nil then return false end
        lines[1] = item.Message
    end
    ce:ToClipboard(table.concat(lines, "\n"))
    self:Flash("Copied " .. #lines .. " line" .. s(#lines) .. ".")
    return true
end

--- Selects every child of the focused record.
function Window:SelectChildren()
    local snapshot, tree = self.Snapshot, self.Tree
    if snapshot == nil or tree == nil then return false end
    local focus = tree:Focused()
    local node = focus and snapshot.ByID[focus] or nil
    if node == nil or #node.Children == 0 then return false end
    tree:Expand(focus, false)
    tree:Select(copyIDs(node.Children), node.Children[1], true)
    return true
end

--- Selects every record of the focused record's type, which is how a person
--- finds all the scripts or all the pointers at once.
function Window:SelectSameType()
    local snapshot, tree = self.Snapshot, self.Tree
    if snapshot == nil or tree == nil then return false end
    local focus = tree:Focused()
    local node = focus and snapshot.ByID[focus] or nil
    if node == nil then return false end
    local tag = self.Types.TagFor(node)
    local ids = {}
    for _, other in ipairs(snapshot.Order) do
        if self.Types.TagFor(other) == tag then ids[#ids + 1] = other.ID end
    end
    tree:Select(ids, focus, true)
    self:Flash(#ids .. " record" .. s(#ids) .. " of the same type.")
    return true
end

--- Puts the Properties page on the description row and starts editing it.
function Window:EditDescription()
    local inspector = self.Inspector
    if inspector == nil then return false end
    if not inspector:ShowPage("Properties") then return false end
    self.Pane = "inspector"
    return inspector:HandleKey(Keys.F2)
end

--------------------------------------------------------
--                     The keyboard                   --
--------------------------------------------------------

--- Installs the key handler. Cheat Engine takes OnKeyDown's RETURN VALUE as
--- the new key, which is how the LCL's var Key is exposed, so zero swallows it
--- and the key itself lets it reach the focused control.
function Window:BuildKeys(form)
    return (pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(_, key) return self:HandleKey(key) end
    end))
end

--- Whether the page on screen has a cell editor open. That box is a text
--- control the window never gave the keyboard to itself, so it is asked for
--- separately from the three edits the window owns.
function Window:GridEditing()
    local inspector = self.Inspector
    if inspector == nil then return false end
    local page = inspector:PageFor(inspector:Page())
    if page == nil then return false end
    local grid = page.Grid
    if grid == nil or type(grid.IsEditing) ~= "function" then return false end
    local ok, editing = pcall(grid.IsEditing, grid)
    return ok and editing == true
end

--- Whether a control that takes typing has the keyboard right now.
function Window:TextFocused()
    if self.TextFocus then return true end
    return self:GridEditing()
end

--- Whether a modifier is held. The mouse and key events carry no shift state
--- in Cheat Engine, so this is the only way to ask.
function Window:Held(key)
    local ce = self.CE
    if ce ~= nil and type(ce.IsKeyDown) == "function" then
        local ok, down = pcall(ce.IsKeyDown, ce, key)
        if ok then return down == true end
    end
    local fn = rawget(_G, "isKeyPressed")
    if type(fn) ~= "function" then return false end
    local ok, down = pcall(fn, key)
    return ok and down == true
end

--
--- ∑ The window's key table.
---
---   A text control keeps every key except the four that have to work from
---   anywhere, because the alternative is a filter box where Ctrl+A selects the
---   tree and Escape closes the window mid word. Everything else goes to the
---   pane the last mouse down landed on.
--- @param key number # A virtual key code.
--- @return number # The key, or zero when this window swallowed it.
--
function Window:HandleKey(key)
    local control = self:Held(Keys.Control)
    local shift = self:Held(Keys.Shift)
    local typing = self:TextFocused()

    -- Four keys work from inside a text control. Ctrl+F is how a person gets
    -- back to the filter box, and the other three are verbs the box has no
    -- meaning for.
    if control and key == Keys.F then
        self:FocusFilter()
        return 0
    end
    if key == Keys.F5 then
        self:Sync(true)
        return 0
    end
    if key == Keys.F7 then
        self:RunProblems()
        return 0
    end
    if key == Keys.Escape then
        if self:Escape() then return 0 end
        return key
    end
    if typing then return key end

    if control and key == Keys.H then
        self:ShowFind(true)
        return 0
    end
    if control and key == Keys.Z then
        if shift then self:Redo() else self:Undo() end
        return 0
    end
    if control and key == Keys.Y then
        self:Redo()
        return 0
    end
    if control and key == Keys.E then
        self:ShowPage("Script")
        return 0
    end
    if control and key == Keys.P then
        self:ShowPage("Pointer")
        return 0
    end
    if control and key >= Keys.One and key <= Keys.Five then
        local tabs = self.InspectorClass.Tabs or {}
        local tab = tabs[key - Keys.One + 1]
        if tab ~= nil then self:ShowPage(tab.Key) end
        return 0
    end
    if control and (key == Keys.Plus or key == Keys.Add) then
        self:ChangeFontSize(1)
        return 0
    end
    if control and (key == Keys.Minus or key == Keys.Subtract) then
        self:ChangeFontSize(-1)
        return 0
    end

    if self.Pane == "tree" then
        if control and key == Keys.C then
            self:CopyAs(shift and "pointer" or "description")
            return 0
        end
        if control and key == Keys.G then
            self:ShowInMemoryView()
            return 0
        end
        if control and key == Keys.Up then
            self:MoveUp()
            return 0
        end
        if control and key == Keys.Down then
            self:MoveDown()
            return 0
        end
        if key == Keys.F2 then
            self:EditDescription()
            return 0
        end
        if self.Tree ~= nil and self.Tree:HandleKey(key) then return 0 end
        return key
    end
    if self.Pane == "results" then
        if self.Results ~= nil and self.Results:HandleKey(key) then return 0 end
        return key
    end
    if self.Inspector ~= nil and self.Inspector:HandleKey(key) then return 0 end
    return key
end

--
--- ∑ What Escape does, in the order a person expects it.
---
---   An open cell editor first. Escape inside one means cancel this cell and
---   nothing else, and the editor is the only thing that can cancel it, so the
---   key is handed straight back even when the filter box holds text. Then the
---   filter, because that is the next thing most likely to be in the way, then
---   the find bar. Only when there is nothing left to put away does it close
---   the window, which is why this window and not the theme owns the key.
--- @return boolean # Whether Escape was used for something.
--
function Window:Escape()
    if self:GridEditing() then return false end
    local filter = safeGet(self.FilterEdit, "Text")
    if type(filter) == "string" and filter ~= "" then
        self.Loading = true
        safeSet(self.FilterEdit, "Text", "")
        self.Loading = false
        self:SetFilter("")
        return true
    end
    if self:FindShown() then
        self:HideFind()
        return true
    end
    if self.TextFocus then return false end
    self:Close()
    return true
end

--- Moves the inspector to one page, which a shortcut and a menu both do.
function Window:ShowPage(key)
    local inspector = self.Inspector
    if inspector == nil then return false end
    self.Pane = "inspector"
    return inspector:ShowPage(key)
end

--------------------------------------------------------
--                    The status line                 --
--------------------------------------------------------

--
--- ∑ Holds one sentence on the status line for a couple of seconds.
---
---   It overrides the counts rather than sitting beside them, because the
---   counts are always true and a message is only worth reading right after the
---   thing it is about.
--- @param text string|nil
--- @return boolean
--
function Window:Flash(text)
    if text == nil or text == "" then return false end
    self.FlashText = tostring(text)
    self.FlashUntil = self:Now() + Defaults.FlashSeconds
    self:FitStatus()
    return true
end

--
--- ∑ The hint of the inspector row under the mouse, or nothing once the mouse
---   left it.
---
---   The hint has the left half of the status line while the mouse is on the
---   row, and the line says its own text again the moment it is gone. A
---   flashed message still wins while it lasts, because it is about something
---   the person just did, and the hint comes back once the flash is over if
---   the mouse is still there.
--- @param text string|nil
--- @return string # What the left half says in full now.
--
function Window:ShowHover(text)
    local wanted = nil
    if type(text) == "string" and text ~= "" then wanted = text end
    self.HoverText = wanted
    return self:FitStatus()
end

--
--- ∑ Which sentence the left half of the status line is for right now.
---
---   A flashed message while it lasts, then the hovered row's hint, then the
---   counts. A flash that ran out is let go here, so nothing else has to
---   remember to.
--- @return string
--
function Window:StatusWanted()
    if self.FlashText ~= nil then
        if self:Now() < self.FlashUntil then return self.FlashText end
        self.FlashText = nil
    end
    if self.HoverText ~= nil then return self.HoverText end
    return self.StatusText or ""
end

--
--- ∑ Puts the left half of the status line on its label, cut to the label's
---   own width with the whole sentence in the label's hint.
---
---   A hint is a sentence and the label shares the bar with the counts on the
---   right, so an uncut hint ran under them. The theme cuts the text to the
---   whole characters that fit, ending in dots. A label that does not know
---   its width yet shows the whole text, and the resize it gets once the
---   window is laid out fits it.
--- @return string # What the left half says in full.
--
function Window:FitStatus()
    local text = self:StatusWanted()
    self.StatusLeft = text
    local label = self.StatusLabel
    if label == nil then return text end
    local width = integer(safeGet(label, "Width"))
    local theme = self.Theme
    if width ~= nil and width > 0 and theme ~= nil and type(theme.FitText) == "function"
        and pcall(theme.FitText, theme, label, text, width) then
        return text
    end
    safeSet(label, "Caption", text)
    safeSet(label, "Hint", "")
    safeSet(label, "ShowHint", false)
    return text
end

--
--- ∑ The counts on both ends of the status line.
--- @return string, string # The left half and the right half.
--
function Window:Status()
    local snapshot = self.Snapshot
    local count = snapshot and snapshot.Count or 0
    local selected = #self:SelectedIDs()
    local matched = self.Tree and self.Tree:MatchedCount() or 0

    local left
    if count == 0 then
        local ce = self.CE
        local open = ce ~= nil and ce:ProcessOpen() == true
        left = open and "This Cheat Table has no records" or "No table loaded"
    else
        local parts = { count .. " record" .. s(count) }
        if selected > 0 then parts[#parts + 1] = selected .. " selected" end
        if matched > 0 then parts[#parts + 1] = matched .. " match" end
        left = table.concat(parts, "  ·  ")
    end

    local groups, scripts, pointers, active = 0, 0, 0, 0
    if snapshot ~= nil then
        for _, node in ipairs(snapshot.Order) do
            if self.Types.IsGroup(node) then groups = groups + 1 end
            if self.Types.IsScript(node) then scripts = scripts + 1 end
            if self.Types.IsPointer(node) then pointers = pointers + 1 end
            if node.Active == true then active = active + 1 end
        end
    end
    local right = {}
    if groups > 0 then right[#right + 1] = groups .. " groups" end
    if scripts > 0 then right[#right + 1] = scripts .. " scripts" end
    if pointers > 0 then right[#right + 1] = pointers .. " pointers" end
    if active > 0 then right[#right + 1] = active .. " active" end
    if self.Problems ~= nil and #self.Problems > 0 then
        right[#right + 1] = #self.Problems .. " problems"
    end
    if self:LiveSyncOn() and self.SyncCost > Defaults.SlowSyncMs then
        right[#right + 1] = string.format("sync %d ms", math.floor(self.SyncCost))
    end
    return left, table.concat(right, " | ")
end

--
--- ∑ Writes the status line.
---
---   The counts are always worked out and the right half always shows its
---   own. The left half shows them only when neither a flashed message nor a
---   hovered row's hint is holding it. The right half is written first,
---   because it takes its width out of the bar and the left half is fitted
---   into what is left.
--- @return string, string # What the left half says in full, and the right half.
--
function Window:UpdateStatus()
    local left, right = self:Status()
    safeSet(self.StatusDetail, "Caption", right)
    self.StatusRight = right
    self.StatusText = left
    safeSet(self.TreeCounter, "Caption",
        tostring(self.Snapshot and self.Snapshot.Count or 0))
    return self:FitStatus(), right
end

--------------------------------------------------------
--                 Diagnostics and about              --
--------------------------------------------------------

--- One block saying what this window is doing right now. The host has a deeper
--- one, this is the part only the window knows.
function Window:Diagnostics()
    local log = self.Log
    local snapshot = self.Snapshot
    local rows = {
        { "Records", snapshot and snapshot.Count or 0 },
        { "Selected", #self:SelectedIDs() },
        { "Filter", (self.Tree and self.Tree:Filter()) or "" },
        { "Live sync", self:LiveSyncOn() and "on" or "off" },
        { "Sync interval", (self.Settings and self.Settings.SyncInterval) or 0 },
        { "Last sync", string.format("%.1f ms", self.SyncCost) },
        { "Structure walk", string.format("%.1f ms", self.StructureCost) },
        { "Detail budget", self.DetailBudget },
        { "Surfaces", self.Frame and self.Frame:Count() or 0 },
        { "Frames painted", self.Frame and self.Frame.Painted or 0 },
        { "Problems", self.Problems and #self.Problems or 0 },
        { "Undo entries", self.Journal and #self.Journal:Entries() or 0 },
        -- How many Cheat Tables have been loaded, which is the number the
        -- undo history hangs off. A report where this and the journal's own
        -- stamp disagree is a report of the bug this row exists to show.
        { "Table loads", RecordsModule.Generation() },
        { "Journal stamp", self.Journal and self.Journal.Stamp or "none" }
    }
    local text = log and log:Block("Address List window", rows) or ""
    if log ~= nil then pcall(log.Info, log, text) end
    return text
end

--- The version block, which the host also reaches for its own About.
function Window:About()
    local log = self.Log
    local rows = {
        { "Version", self.Version.String() },
        { "Authors", self.Version.Authors() },
        { "Records", self.Snapshot and self.Snapshot.Count or 0 },
        ""
    }
    local text = log and log:Block(self.Version.Full(), rows) or self.Version.Full()
    if log ~= nil then pcall(log.Info, log, text) end
    return text
end

--------------------------------------------------------
--                      Closing it                    --
--------------------------------------------------------

--
--- ∑ The close gate, which is what OnClose answers with.
---
---   The active page is asked first, because only the active page can be
---   holding an unsaved change. A person who chose Cancel gets their window
---   back, which is what caNone means, and a Lua OnClose that returns nothing
---   at all means the same thing and would leave a window nobody can close.
--- @return number # caFree or caNone.
--
function Window:Closed()
    local caNone = rawget(_G, "caNone") or 0
    local caFree = rawget(_G, "caFree") or 2
    if self.Closing then return caFree end
    local inspector = self.Inspector
    if inspector ~= nil and not inspector:CanLeave("close") then return caNone end
    self.Closing = true
    self:Persist()
    self:Release()
    self.Closing = false
    say(self, "Info", "The Address List window was closed.")
    return caFree
end

--- Keeps the window's shape for the next time it opens.
function Window:Persist()
    local settings = self.Settings
    if settings == nil or type(settings.Set) ~= "function" then return false end
    local width = integer(safeGet(self.Form, "Width"))
    local height = integer(safeGet(self.Form, "Height"))
    if width then pcall(settings.Set, settings, "Window.Width", width) end
    if height then pcall(settings.Set, settings, "Window.Height", height) end
    -- The width that was asked for and not the one a narrow window left, so
    -- the tree gets it back the next time there is room.
    local treeWidth = self:TreeWidthWanted()
    if treeWidth then pcall(settings.Set, settings, "TreeWidth", treeWidth) end
    local resultsHeight = integer(safeGet(self.ResultsCard, "Height"))
    if resultsHeight then pcall(settings.Set, settings, "ResultsHeight", resultsHeight) end
    return true
end

--
--- ∑ Lets go of everything the form is about to free.
---
---   The journal is the host's and stays, so the history survives a close and
---   reopen. Everything else here points at LCL objects that are going away
---   with the window and would be a use after free the moment a timer found
---   them.
--- @return nil
--
function Window:Release()
    self:StopTimers()
    if self.Inspector ~= nil then
        pcall(self.Inspector.Destroy, self.Inspector)
        self.Inspector = nil
    end
    if self.Tree ~= nil then
        pcall(self.Tree.Destroy, self.Tree)
        self.Tree = nil
    end
    if self.Results ~= nil then
        pcall(self.Results.Destroy, self.Results)
        self.Results = nil
    end
    if self.Icons ~= nil and type(self.Icons.Invalidate) == "function" then
        pcall(self.Icons.Invalidate, self.Icons)
    end
    if self.Theme ~= nil then pcall(self.Theme.Forget, self.Theme) end

    self.Frame, self.Form = nil, nil
    self.StatusLabel, self.StatusBar, self.StatusDetail = nil, nil, nil
    self.ToolBar, self.FindBar, self.FilterEdit, self.MenuButton = nil, nil, nil, nil
    self.FilterRow, self.ToolBarNeed = nil, 0
    self.TreeWanted, self.TreeFitted, self.Fitting = nil, nil, false
    self.FindEdit, self.ReplaceEdit, self.FieldCombo, self.ScopeCombo = nil, nil, nil, nil
    self.SetCase, self.GetCase, self.SetWord, self.GetWord = nil, nil, nil, nil
    self.TreeCard, self.TreeContent, self.TreeCounter, self.TreeSplitter = nil, nil, nil, nil
    self.InspectorCard, self.InspectorContent, self.InspectorCounter = nil, nil, nil
    self.ResultsCard, self.ResultsContent, self.ResultsCounter = nil, nil, nil
    self.ResultsSplitter = nil
    self.TreeMenu, self.MainMenu, self.ResultsMenu = nil, nil, nil
    self.Buttons, self.Hooked = {}, {}
    self.ThemeSource = nil
    self.Opened = false
    self.Pane, self.TextFocus = "tree", false
    self.FlashText, self.FlashUntil = nil, 0
    self.HoverText, self.StatusText = nil, ""
    self.Ticks, self.Busy = 0, 0
end

--- Stops both timers and frees them. A timer left running on a destroyed form
--- fires into nothing several times a second.
function Window:StopTimers()
    for _, name in ipairs({ "FrameTimer", "SyncTimer" }) do
        local timer = self[name]
        if timer ~= nil then
            pcall(function() timer.Enabled = false end)
            pcall(function() timer.destroy() end)
            self[name] = nil
        end
    end
    return true
end

--- Frees the window for good, which is what a host reload does. The form is
--- destroyed after everything pointing at it was let go.
function Window:Destroy()
    local form = self.Form
    self.Closing = true
    self:Release()
    self.Closing = false
    if form ~= nil then pcall(function() form.destroy() end) end
    self.Snapshot, self.Problems, self.ProblemMap = nil, nil, nil
    self.Pending, self.LastSelection = {}, {}
    self.LastFocus, self.Restoring = nil, false
    return true
end

return Window
