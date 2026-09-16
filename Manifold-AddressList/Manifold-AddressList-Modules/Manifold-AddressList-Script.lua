--[[
    The script page, where one Auto Assembler record is edited.

    The editor comes from Theme.CreateCodeView, which hands back a control and
    two closures, and this page reads and writes the text through those two and
    never through the control. That is the whole point of the pair. Cheat Engine
    builds with createSynEdit give a highlighted editor with a gutter, builds
    without it give a themed memo, and the text lives behind a different
    property on each of them. A page reaching for Lines.Text itself would work
    on one and quietly do nothing on the other, which is the split the floor
    rule forbids. Save, Revert, Check and Go to line all work either way, and
    the only things the memo loses are the colours and the line numbers.

    Saving an active script asks first. Setting Active on an Auto Assembler
    record runs its section there and then, so a script that is on right now was
    enabled by the text that is about to be replaced, and its [DISABLE] section
    is the only thing that can undo what that text did. Replacing both halves
    under a running script leaves the process holding changes nothing can take
    back. The question is asked through OnAct, because a modal dialog runs a
    nested message loop and the window has to stop its timers around it.

    Check never runs the script. autoAssembleCheck assembles both sections
    without writing to the process, so it is safe to press at any time, and it
    is the only way to find out whether a script would work before turning it
    on. Cheat Engine's message usually carries the line it failed on, which is
    pulled out and handed to the results strip so a click lands on that line.

    The page writes nothing into a record. Save builds one script change and
    hands it up through OnCommit, and the editor is only accepted as saved when
    the commit came back ok with something applied.

    The page has the shape the Pointer page has. Check and Go to line sit over
    the editor in a flow bar, which wraps them onto a second line instead of
    sliding one under the other. Revert and Save are the only thing along the
    bottom and are placed from the right edge by hand, Save outermost, because
    the button that commits sits at the edge on every page. Sharing one bar
    with left aligned buttons is how Save once ended up under Go to line on the
    narrowest window.
]]

local TypesModule = require("Manifold-AddressList-Types")

local Script = {}
Script.__index = Script

--- What the inspector calls this page and what its tab says.
Script.Key = "Script"
Script.Caption = "Script"

--- The code view mode. One is Auto Assembler, which is the only highlighter
--- this page ever wants.
local MODE_AUTO_ASSEMBLER = 1

--- Virtual key codes. The window hands a raw code in, so the modifiers are read
--- back through Cheat Engine rather than arriving with the key.
local VK_CONTROL = 17
local VK_S = 0x53
local VK_G = 0x47

--- How many lines above the one asked for stay on screen after a jump, so the
--- line lands with some context above it rather than against the top edge.
local JUMP_MARGIN = 3

--- A button's height on the bars, the space between two of them, and the space
--- over and under the lines of the bar along the bottom. The Pointer, Drop-down
--- and Hotkeys pages use the same numbers, so Revert and Save stand exactly
--- where those pages put their pair when a person switches between them.
local BUTTON_HEIGHT, BAR_GAP, BAR_PAD = 26, 6, 5

--- The space the bar along the bottom keeps at its two ends, which is the page
--- edge every other page ends its rows and buttons on. It is not the bar's
--- padding. The two were one number here once, and Save stood a pixel right
--- of every other page's Apply.
local PAGE_EDGE = 6

--- The width of Save and Revert, which every button along the bottom of a page
--- shares.
local BUTTON_WIDTH = 64

--- The space round the tool buttons over the editor. Check starts on the page
--- edge.
local TOOL_PAD_X, TOOL_PAD_TOP, TOOL_PAD_BOTTOM = PAGE_EDGE, 4, 6

--
--- ∑ The two sections Check assembles, in the order it reports them.
---
---   Enable is checked first because that is the half a person writes first and
---   the half whose failure stops everything.
--
Script.Sections = {
    { Name = "[ENABLE]", Enable = true },
    { Name = "[DISABLE]", Enable = false }
}

--------------------------------------------------------
--                    Small helpers                   --
--------------------------------------------------------

local function trim(text)
    return (tostring(text == nil and "" or text):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- One guarded property write, so a control that is gone and a property this
--- build does not have both come back as false rather than as a raise.
local function safeSet(control, property, value)
    if control == nil then return false end
    return (pcall(function() control[property] = value end))
end

--- One property read as a number, or nil when it cannot be read.
local function readNumber(control, property)
    if control == nil then return nil end
    local ok, value = pcall(function() return control[property] end)
    if not ok then return nil end
    return tonumber(value)
end

--- The width a control lays its children out in, or nil while it has none.
local function innerWidth(control)
    local width = readNumber(control, "ClientWidth")
    if width == nil or width <= 0 then width = readNumber(control, "Width") end
    if width == nil or width <= 0 then return nil end
    return width
end

--- Whether a control is meant to be on screen. One that cannot say counts as
--- shown, so a layout never loses a button it could not ask.
local function isShown(control)
    local ok, value = pcall(function() return control.Visible end)
    return not ok or value ~= false
end

--
--- ∑ Places a bar's buttons from its right edge, the last one outermost, and
---   answers the height their lines need.
---
---   A bar too narrow for all of them side by side starts a new line under the
---   first one, so no button is ever drawn over another. The lines end on the
---   page edge and stand the bar's padding apart from its top and bottom.
--- @param bar userdata
--- @param buttons table # Button panels, in reading order.
--- @return number|nil # The height, or nil while the bar has no width yet.
--
local function placeFromRight(bar, buttons)
    local width = innerWidth(bar)
    if width == nil then return nil end
    local room = math.max(0, width - 2 * PAGE_EDGE)
    local lines, line, used = {}, {}, 0
    for _, control in ipairs(buttons) do
        if isShown(control) then
            local each = readNumber(control, "Width") or 0
            if #line > 0 and used + BAR_GAP + each > room then
                lines[#lines + 1] = { Controls = line, Span = used }
                line, used = {}, 0
            end
            used = #line > 0 and (used + BAR_GAP + each) or each
            line[#line + 1] = control
        end
    end
    if #line > 0 then lines[#lines + 1] = { Controls = line, Span = used } end
    local y = BAR_PAD
    for _, entry in ipairs(lines) do
        local x = width - PAGE_EDGE - entry.Span
        for _, control in ipairs(entry.Controls) do
            safeSet(control, "Left", x)
            safeSet(control, "Top", y)
            x = x + (readNumber(control, "Width") or 0) + BAR_GAP
        end
        y = y + BUTTON_HEIGHT + BAR_GAP
    end
    if #lines == 0 then return 2 * BAR_PAD end
    return y - BAR_GAP + BAR_PAD
end

--- Sends one line to the log channel when there is one.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--- Tells the window what just happened. A page never writes to the status bar
--- itself, it says something and the window decides where that goes.
local function status(self, text)
    if type(self.OnStatus) ~= "function" then return end
    pcall(self.OnStatus, tostring(text == nil and "" or text))
end

--
--- ∑ Two texts with their line endings made the same.
---
---   Cheat Engine keeps a script in a string list, and a string list gives its
---   text back with a break after the last line and with carriage returns in
---   front of every break. Comparing the raw strings would call an untouched
---   editor dirty.
--- @param text string|nil
--- @return string
--
local function normalise(text)
    return (tostring(text == nil and "" or text):gsub("\r\n", "\n"):gsub("\n+$", ""))
end

--- The first reason out of a failure list, so a refused commit says why rather
--- than only that it did not work.
local function reasonOf(failures)
    if type(failures) ~= "table" then return nil end
    for _, failure in ipairs(failures) do
        if type(failure) == "table" and failure.Reason ~= nil then return tostring(failure.Reason) end
        if type(failure) == "string" then return failure end
    end
    return nil
end

--------------------------------------------------------
--                    Pure reading                    --
--------------------------------------------------------

--
--- ∑ The line number inside one of Cheat Engine's assembler messages.
---
---   The wording moves between builds and between the two assemblers, so this
---   looks for the word line followed by a number and, failing that, for a
---   number in front of a colon at the start. Anything else gives nothing,
---   because a wrong line number sends a person to the wrong place.
--- @param message string|nil
--- @return number|nil
--
function Script.LineOf(message)
    if type(message) ~= "string" then return nil end
    local lower = message:lower()
    local found = lower:match("line%s+(%d+)")
    if found == nil then found = lower:match("^%s*(%d+)%s*:") end
    if found == nil then return nil end
    local number = tonumber(found)
    if number == nil or number < 1 then return nil end
    return math.floor(number)
end

--
--- ∑ How many characters come before the start of one line.
---
---   A memo has no caret to move, so a jump there is a selection put at an
---   offset, and this is that offset. Nothing when the text has no such line.
--- @param text string|nil
--- @param line number
--- @return number|nil
--
function Script.OffsetOfLine(text, line)
    if type(text) ~= "string" then return nil end
    line = math.floor(tonumber(line) or 0)
    if line < 1 then return nil end
    if line == 1 then return 0 end
    local index, counted = 1, 1
    while counted < line do
        local found = text:find("\n", index, true)
        if found == nil then return nil end
        index = found + 1
        counted = counted + 1
    end
    return index - 1
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the page. Nothing is created until Build, so the inspector can hold
---   one before its card exists.
--- @param services table|nil # Theme, Surface, Frame, Grid, Properties, Types,
---        Records, CE, Log and Settings.
--- @return table
--
function Script:New(services)
    services = services or {}
    return setmetatable({
        Theme = services.Theme,
        Log = services.Log,
        Settings = services.Settings,
        Frame = services.Frame,
        CE = services.CE,
        Types = services.Types or TypesModule,
        Records = services.Records,
        Properties = services.Properties,

        Parent = nil,
        Host = nil,
        Control = nil,          -- the code view, only ever touched for the caret
        GetText = nil,          -- the only way the text is read
        SetText = nil,          -- the only way the text is written
        Highlighted = false,    -- false on the themed memo fallback
        ToldAboutFallback = false,
        Empty = nil,            -- the themed empty state over the editor
        ToolBar = nil,          -- the flow bar Check and Go to line wrap in
        ActionBar = nil,        -- Revert and Save along the bottom
        Buttons = {},           -- key to setEnabled
        Controls = {},          -- key to the button panel, for the layout checks

        Snapshot = nil,
        IDs = {},
        ID = nil,               -- the one record this page edits
        Reason = nil,           -- why it is showing an empty state instead
        Original = nil,         -- the text as the record holds it
        Loading = false,
        Saving = false,         -- Save is waiting for the window's answer

        OnCommit = nil,
        OnAct = nil,
        OnStatus = nil,
        --- The inspector's busy guard. A modal opened outside it runs a nested
        --- message loop with the window's timers still ticking into it.
        OnGuard = nil,
        --- The hovered hint the inspector header shows. This page has no rows
        --- to hover, so it only ever clears it.
        OnHint = nil,
        --- Optional. The window sets it to take Check's findings into the
        --- results strip. Without it Check still reports through OnStatus.
        OnResults = nil
    }, Script)
end

--
--- ∑ The tool buttons over the editor, in reading order. The flow bar places
---   them in the order they are added and wraps them when the page is narrow.
--
Script.Actions = {
    { Key = "Check", Caption = "Check", Width = 64,
      Hint = "Assemble both sections without running them and list what failed." },
    { Key = "Goto", Caption = "Go to line", Width = 96,
      Hint = "Move the editor to a line number (Ctrl+G)." }
}

--- The two buttons along the bottom, Save at the right edge and Revert to its
--- left.
Script.Commits = {
    { Key = "Revert", Caption = "Revert", Width = BUTTON_WIDTH,
      Hint = "Throw away what you typed and read the record again." },
    { Key = "Save", Caption = "Save", Width = BUTTON_WIDTH,
      Hint = "Write the script to the record as one change (Ctrl+S)." }
}

--
--- ∑ Creates the controls inside the inspector's page panel.
---
---   Top to bottom the page reads the tool buttons, the editor, and Revert and
---   Save. The flow bar is the only control along the top, the commit bar the
---   only one along the bottom, and the editor takes what is left. The empty
---   state is a second alClient panel in the editor's host, shown instead of
---   the editor rather than over it, because two visible alClient children
---   would leave the second one with no room at all.
--- @param parent userdata
--- @return boolean
--
function Script:Build(parent)
    self.Parent = parent
    local theme = self.Theme
    if theme == nil then
        say(self, "Warning", "The script page was built without a theme.")
        return false
    end
    local ok, err = pcall(function()
        self:BuildTools(theme, parent)
        self:BuildCommits(theme, parent)
        local host = theme:CreatePanel(parent, { Align = "alClient", ColorKey = "COLOR_INPUT" })
        self.Host = host
        self.Empty = theme:CreateEmptyState(host)
        safeSet(self.Empty.Panel, "Visible", false)
        self:BuildEditor(theme, host)
    end)
    if not ok then
        say(self, "Warning", "The script page could not be built whole, " .. tostring(err))
    end
    self:Apply()
    return ok
end

--- Check and Go to line, in a bar that wraps them rather than letting one
--- slide under the other.
function Script:BuildTools(theme, parent)
    local bar, add = theme:CreateFlowBar(parent, {
        Align = "alTop", ColorKey = "COLOR_INPUT", Gap = BAR_GAP,
        Padding = { Left = TOOL_PAD_X, Top = TOOL_PAD_TOP,
                    Right = TOOL_PAD_X, Bottom = TOOL_PAD_BOTTOM }
    })
    self.ToolBar = bar
    for _, action in ipairs(Script.Actions) do
        local button, setEnabled = theme:CreateButton(bar, {
            Caption = action.Caption, Width = action.Width, Height = BUTTON_HEIGHT,
            Hint = action.Hint, Spacing = { Around = 0 },
            OnClick = function() self:Run(action.Key) end
        })
        add(button)
        self.Buttons[action.Key] = setEnabled
        self.Controls[action.Key] = button
    end
end

--
--- ∑ Revert and Save, kept to the right edge of a bar of their own and placed
---   by hand whenever the bar changes size, Save outermost.
--- @param theme table
--- @param parent userdata
--- @return nil
--
function Script:BuildCommits(theme, parent)
    local bar = theme:CreatePanel(parent, {
        Align = "alBottom", Height = BUTTON_HEIGHT + 2 * BAR_PAD, ColorKey = "COLOR_INPUT"
    })
    self.ActionBar = bar
    local order = {}
    for index, spec in ipairs(Script.Commits) do
        local button, setEnabled = theme:CreateButton(bar, {
            Caption = spec.Caption, Width = spec.Width, Height = BUTTON_HEIGHT,
            Hint = spec.Hint, Spacing = { Around = 0 },
            OnClick = function()
                if spec.Key == "Save" then self:Save() else self:Revert() end
            end
        })
        order[index] = button
        self.Buttons[spec.Key] = setEnabled
        self.Controls[spec.Key] = button
    end
    -- Taking a new height fires one more resize while this one runs, and that
    -- one has nothing to add.
    local busy = false
    safeSet(bar, "OnResize", function()
        if busy then return end
        busy = true
        pcall(function()
            local height = placeFromRight(bar, order)
            if height ~= nil and readNumber(bar, "Height") ~= height then
                safeSet(bar, "Height", height)
            end
        end)
        busy = false
    end)
end

--- The editor, which the page only ever reads and writes through the two
--- closures the theme hands back with it.
function Script:BuildEditor(theme, host)
    local control, getText, setText = theme:CreateCodeView(host, MODE_AUTO_ASSEMBLER, {
        ReadOnly = false
    })
    self.Control, self.GetText, self.SetText = control, getText, setText
    -- A gutter only exists on the highlighted editor. Reading a member a memo
    -- does not have is a raise in Cheat Engine, so the probe is guarded and its
    -- only use is the one line the page says about it.
    local probed, gutter = pcall(function() return control.Gutter end)
    self.Highlighted = probed and gutter ~= nil
    safeSet(control, "OnChange", function() self:TextChanged() end)
end

--------------------------------------------------------
--                    The subject                     --
--------------------------------------------------------

--
--- ∑ Which record this page can edit, out of what the tree has selected.
---
---   One Auto Assembler record. Cheat Engine keeps no script list on any other
---   record, so a write to one is dropped without a word, and this page refuses
---   rather than pretending the edit landed.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return number|nil # The record id.
--- @return string|nil # Why there is none.
--
function Script:SubjectOf(ids, snapshot)
    if ids == nil or #ids == 0 then return nil, "Nothing is selected" end
    if #ids > 1 then return nil, "More than one record is selected" end
    local id = ids[1]
    local node = snapshot ~= nil and snapshot.ByID ~= nil and snapshot.ByID[id] or nil
    if node == nil then return nil, "That record is gone" end
    if self.Records ~= nil and not node.Loaded then
        pcall(function() self.Records:EnsureDetail(snapshot, { id }) end)
    end
    local types = self.Types or TypesModule
    if not types.IsScript(node) then return nil, "That record is not a script" end
    return id
end

--- The two lines the page shows when it has no script to work on.
Script.Empties = {
    ["Nothing is selected"] = {
        Title = "No record is selected",
        Hint = "Pick one Auto Assembler record in the tree to edit its script."
    },
    ["More than one record is selected"] = {
        Title = "Select one record",
        Hint = "A script belongs to one record, so this page edits one at a time."
    },
    ["That record is gone"] = {
        Title = "That record is gone",
        Hint = "It was removed from the table while this page was open."
    },
    ["That record is not a script"] = {
        Title = "That record has no script",
        Hint = "Change its type to Auto Assembler Script on the Properties page first."
    }
}

--
--- ∑ Points the page at a selection. The same record with an unsaved script
---   keeps what the person typed, because the inspector already asked before
---   the subject was allowed to change.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return nil
--
function Script:Show(ids, snapshot)
    self.Snapshot = snapshot
    self.IDs = ids or {}
    local id, reason = self:SubjectOf(self.IDs, snapshot)
    if id ~= nil and id == self.ID and self:IsDirty() then
        self:Apply()
        return
    end
    self.ID, self.Reason = id, reason
    self:Load()
    if self.ID ~= nil and not self.Highlighted and not self.ToldAboutFallback then
        self.ToldAboutFallback = true
        status(self, "This Cheat Engine has no code editor, so the script is shown in a plain box.")
    end
end

--- Reads the record's own script, and nothing at all when the record is gone.
function Script:ReadRecord()
    local records, props = self.Records, self.Properties
    if self.ID == nil or records == nil or props == nil then return "" end
    local mr = records:Resolve(self.ID, self.Snapshot)
    if mr == nil then return "" end
    local text = props:ReadScript(mr)
    if type(text) ~= "string" then return "" end
    return text
end

--
--- ∑ Throws the editor's content away and reads the record again. Show, a
---   refresh of a clean page and the Revert button all go through here.
---
---   The editor is only written when what it holds is not already the record's
---   text. Writing the same lines back would reset the caret, the scroll and
---   the editor's own undo, and a sync tick doing that four times a second
---   would make the page unusable.
--- @return nil
--
function Script:Load()
    self.Original = self.ID ~= nil and self:ReadRecord() or nil
    local current = self:Current()
    if current == nil or normalise(current) ~= normalise(self.Original) then
        self:Write(self.Original or "")
    end
    self:Apply()
end

--- Writes text into the editor without the page hearing about its own write.
function Script:Write(text)
    if type(self.SetText) ~= "function" then return false end
    self.Loading = true
    local ok = pcall(self.SetText, tostring(text == nil and "" or text))
    self.Loading = false
    return ok
end

--- What the editor holds right now, or nothing when it could not be read.
function Script:Current()
    if type(self.GetText) ~= "function" then return nil end
    local ok, text = pcall(self.GetText)
    if not ok then return nil end
    return tostring(text == nil and "" or text)
end

--------------------------------------------------------
--                     The screen                     --
--------------------------------------------------------

--- Called when the person typed. It only refreshes the buttons and the title,
--- because the editor already holds the text and there is nothing to copy.
function Script:TextChanged()
    if self.Loading then return end
    self:Apply()
end

--
--- ∑ Rebuilds everything around the editor from what the page knows. One call
---   after any change, so nothing can update half of the page.
--- @return nil
--
function Script:Apply()
    local editable = self.ID ~= nil
    if self.Empty ~= nil then
        local message = editable and nil or Script.Empties[self.Reason or ""]
        if message == nil and not editable then
            message = { Title = "Nothing to edit", Hint = "Pick one record in the tree." }
        end
        if message ~= nil then self.Empty.Set(message.Title, message.Hint) end
        safeSet(self.Empty.Panel, "Visible", message ~= nil)
    end
    safeSet(self.Control, "Visible", editable)
    safeSet(self.Control, "ReadOnly", not editable)

    local dirty = self:IsDirty()
    self:Enable("Save", editable and dirty)
    self:Enable("Revert", editable and dirty)
    self:Enable("Check", editable)
    self:Enable("Goto", editable)
end

--- One button's enabled state, when that button was built at all.
function Script:Enable(key, value)
    local setEnabled = self.Buttons[key]
    if type(setEnabled) ~= "function" then return false end
    pcall(setEnabled, value == true)
    return true
end

--------------------------------------------------------
--                Saving and reverting                --
--------------------------------------------------------

--- True while the editor says something the record does not.
function Script:IsDirty()
    if self.ID == nil or self.Original == nil then return false end
    local text = self:Current()
    if text == nil then return false end
    return normalise(text) ~= normalise(self.Original)
end

--- The name this page puts in a label, which is the description or the id when
--- the record has none.
function Script:Name()
    local node = self.Snapshot ~= nil and self.Snapshot.ByID ~= nil
        and self.Snapshot.ByID[self.ID] or nil
    local name = node ~= nil and node.Description or nil
    if name == nil or name == "" then return "#" .. tostring(self.ID) end
    return name
end

--- Whether the record's script is running right now, which is what decides
--- whether saving needs a question in front of it.
function Script:IsActive()
    local node = self.Snapshot ~= nil and self.Snapshot.ByID ~= nil
        and self.Snapshot.ByID[self.ID] or nil
    return node ~= nil and node.Active == true
end

--
--- ∑ Runs a modal through the window's busy guard.
---
---   A modal dialog runs a nested message loop, so the window has to hold its
---   timers while one is open. OnGuard is the hook the inspector wires for
---   exactly that, OnAct is the fallback for a shell that offers only the
---   action path, and a page with neither still opens the dialog, because a
---   question that never gets asked is worse than one asked while a timer
---   ticks.
--- @param label string # What the window logs the pause as, on the OnAct path.
--- @param fn function # The call that opens the dialog.
--- @return any # Whatever fn answered, or nothing when the window refused.
--
function Script:Guarded(label, fn)
    if type(self.OnGuard) == "function" then
        local ok, value = pcall(self.OnGuard, fn)
        if ok then return value end
        return nil
    end
    local answer
    local body = function() answer = fn() end
    if type(self.OnAct) == "function" then
        local ids = self.ID ~= nil and { self.ID } or {}
        local ok = self.OnAct(label, ids, body)
        if ok == false then return nil end
        return answer
    end
    body()
    return answer
end

--
--- ∑ Asks before replacing the text of a script that is running.
---
---   The [DISABLE] section about to be overwritten is the only thing that can
---   undo what the [ENABLE] section already did to the process, so a person has
---   to say that they know.
--- @return boolean
--
function Script:AskAboutActive()
    local ce = self.CE
    if ce == nil then return false end
    return self:Guarded("Save the active script", function()
        return ce:Confirm(
            "Save the script of '" .. self:Name() .. "'.",
            nil,
            "The script is active. Its [DISABLE] section should undo what the [ENABLE] section did, so replacing it now can leave changes nothing can take back.")
    end) == true
end

--
--- ∑ Hands the whole script up as one change.
---
---   The editor is accepted as saved only when the commit came back ok with
---   something applied, which is what keeps an edit alive through a write Cheat
---   Engine refused.
--- @return boolean
--
function Script:Save()
    if self.ID == nil then
        status(self, "There is no script to save.")
        return false
    end
    if not self:IsDirty() then return true end
    local text = self:Current()
    if text == nil then
        status(self, "The editor could not be read.")
        return false
    end
    if type(self.OnCommit) ~= "function" then
        status(self, "This page is not connected to the window.")
        return false
    end
    if self:IsActive() and not self:AskAboutActive() then
        status(self, "The script was left as it was.")
        return false
    end
    self.Saving = true
    local ran, committed, applied, failures = pcall(self.OnCommit, {
        Label = "Script on '" .. self:Name() .. "'",
        Changes = { { Kind = "script", ID = self.ID, Old = self.Original, New = text } }
    })
    self.Saving = false
    if not ran then committed, applied, failures = false, 0, { tostring(committed) } end
    if committed == true and (tonumber(applied) or 0) > 0 then
        self.Original = text
        self:Apply()
        return true
    end
    status(self, reasonOf(failures) or "The script was not written.")
    self:Apply()
    return false
end

--- Throws the editor's content away and reads the record again.
function Script:Discard()
    if self.ID == nil then return end
    self:Load()
end

--- What the Revert button does, which is Discard plus a word about it.
function Script:Revert()
    if not self:IsDirty() then return false end
    self:Discard()
    status(self, "The script was read again from the record.")
    return true
end

--------------------------------------------------------
--                      Checking                      --
--------------------------------------------------------

--
--- ∑ Assembles both sections without running either of them.
---
---   autoAssembleCheck writes nothing to the process, so this is safe at any
---   time and it is the only way to find out whether a script would work
---   before turning it on. A section Cheat Engine could not check at all is
---   reported as that and never as a failure, because the two are different
---   things and a person acting on the wrong one edits a script that was fine.
--- @return boolean # True when both sections assembled.
--
function Script:Check()
    if self.ID == nil then
        status(self, "There is no script to check.")
        return false
    end
    local ce = self.CE
    if ce == nil then
        status(self, "Cheat Engine is not available here.")
        return false
    end
    local text = self:Current()
    if text == nil or trim(text) == "" then
        status(self, "There is nothing to check.")
        return false
    end

    local items, words = {}, {}
    for _, section in ipairs(Script.Sections) do
        local ok, message = ce:AssembleCheck(text, section.Enable)
        if ok == true then
            words[#words + 1] = section.Name .. " assembles"
        elseif ok == false then
            words[#words + 1] = section.Name .. " failed"
            items[#items + 1] = {
                ID = self.ID,
                Severity = "error",
                Code = "ASSEMBLE_FAILED",
                Field = "Script",
                Line = Script.LineOf(message),
                Label = self:Path(),
                Message = section.Name .. " " .. tostring(message)
            }
        else
            words[#words + 1] = section.Name .. " could not be checked, " .. tostring(message)
        end
    end

    self:Report(items)
    status(self, table.concat(words, ".  ") .. ".")
    say(self, "Info", "Checked the script of '" .. self:Name() .. "', "
        .. #items .. " of the two sections failed.")
    return #items == 0
end

--- The path the results strip shows in front of a finding, so a person reading
--- the strip knows which record it belongs to.
function Script:Path()
    local records = self.Records
    if records == nil or self.Snapshot == nil then return self:Name() end
    local ok, path = pcall(records.Path, records, self.Snapshot, self.ID)
    if ok and type(path) == "string" and path ~= "" then return path end
    return self:Name()
end

--
--- ∑ Hands findings to the results strip, when the window wired one up.
---
---   Without OnResults the findings are still reported through OnStatus, so the
---   button is never a button that does nothing.
--- @param items table
--- @return boolean # Whether the strip took them.
--
function Script:Report(items)
    if type(self.OnResults) ~= "function" then return false end
    local ok = pcall(self.OnResults, "Problems", items)
    return ok
end

--------------------------------------------------------
--                    Going to a line                 --
--------------------------------------------------------

--
--- ∑ Moves the editor to one line.
---
---   Both routes are tried and neither raises. The highlighted editor has a
---   caret and a top line, the memo has neither and takes a selection at the
---   character the line starts on instead. Writing the one the control does not
---   have lands on its wrapper and changes nothing.
--- @param line number
--- @return boolean # False when there is no such line.
--
function Script:GoToLine(line)
    line = math.floor(tonumber(line) or 0)
    if line < 1 or self.Control == nil then return false end
    local text = self:Current()
    local offset = Script.OffsetOfLine(text, line)
    if offset == nil then
        status(self, "The script has no line " .. line .. ".")
        return false
    end
    if self.Highlighted then
        safeSet(self.Control, "TopLine", math.max(1, line - JUMP_MARGIN))
        safeSet(self.Control, "CaretX", 1)
        safeSet(self.Control, "CaretY", line)
    else
        safeSet(self.Control, "SelStart", offset)
        safeSet(self.Control, "SelLength", 0)
    end
    pcall(function() self.Control.setFocus() end)
    return true
end

--
--- ∑ Asks which line and goes there. The prompt is a modal, so it goes through
---   the same busy guard the active script question does.
--- @return boolean
--
function Script:AskGoToLine()
    if self.ID == nil then
        status(self, "There is no script to move around in.")
        return false
    end
    local theme = self.Theme
    if theme == nil or type(theme.AskText) ~= "function" then return false end
    local answer = self:Guarded("Go to line", function()
        return theme:AskText("Go to line", "Line number", "")
    end)
    local line = tonumber(answer)
    if line == nil then return false end
    return self:GoToLine(line)
end

--------------------------------------------------------
--                  The page contract                 --
--------------------------------------------------------

--
--- ∑ Runs one of the bottom row's actions by key, so the buttons, the keyboard
---   and the tests all reach the same code.
--- @param key string
--- @return boolean
--
function Script:Run(key)
    if key == "Check" then return self:Check() end
    if key == "Goto" then return self:AskGoToLine() end
    return false
end

--
--- ∑ Takes a newer snapshot without throwing away what the person typed.
---
---   A clean page reads the record again, and Load leaves the editor alone
---   unless the text really moved, so a sync tick costs one property read and
---   nothing on screen.
--- @param snapshot table|nil
--- @param changedIds table|nil # A list or a set of ids. Ignored, because the
---        script itself is compared and that is a better answer.
--- @return nil
--
function Script:Refresh(snapshot, changedIds)
    self.Snapshot = snapshot or self.Snapshot
    if self.ID == nil then
        self:Show(self.IDs, self.Snapshot)
        return
    end
    local node = self.Snapshot ~= nil and self.Snapshot.ByID ~= nil
        and self.Snapshot.ByID[self.ID] or nil
    if node == nil then
        self.ID, self.Reason = nil, "That record is gone"
        self:Load()
        return
    end
    if self:IsDirty() then
        -- While Save waits, the window writes the script, reads the record
        -- again and tells this page before it asks for the header. Reading the
        -- record here makes a page whose script landed clean in time for that
        -- header, and leaves a refused one dirty. The editor is not touched
        -- either way, so a refused script keeps what was typed.
        if self.Saving then self.Original = self:ReadRecord() end
        self:Apply()
        return
    end
    self:Load()
end

--- The line the inspector's header shows while this page is the active one,
--- with the marker that says the editor holds something the record does not.
function Script:Title()
    if self.ID == nil then return self.Reason or "Nothing to edit" end
    local text = self:Name()
    if self:IsActive() then text = text .. ", active" end
    if self:IsDirty() then text = text .. " *" end
    return text
end

--
--- ∑ The keys this page answers. The editor keeps its own keys, so the window
---   only sends these while the editor does not have the focus, except for the
---   two the page owns everywhere.
--- @param key number # A virtual key code.
--- @return boolean # Whether the key was used.
--
function Script:HandleKey(key)
    local ce = self.CE
    local ctrlDown = ce ~= nil and ce:IsKeyDown(VK_CONTROL) or false
    if not ctrlDown then return false end
    if key == VK_S then
        self:Save()
        return true
    end
    if key == VK_G then
        self:AskGoToLine()
        return true
    end
    return false
end

--- Releases what the page holds. Every control belongs to the inspector's page
--- panel and is freed with the form, so nothing is destroyed here.
function Script:Destroy()
    self.Control, self.GetText, self.SetText = nil, nil, nil
    self.Empty, self.Host, self.Parent = nil, nil, nil
    self.ToolBar, self.ActionBar = nil, nil
    self.Buttons, self.Controls = {}, {}
    self.Original, self.ID = nil, nil
end

return Script
