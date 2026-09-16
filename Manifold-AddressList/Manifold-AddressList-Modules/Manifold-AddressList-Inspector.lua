--[[
    The inspector shell and the Properties page.

    The shell owns the tab strip and one panel per page, shows exactly one of
    those panels and gates every page change through the page that is being
    left. A selection moving in the tree goes through the same gate, because a
    page that edits one record loses its buffer the moment that record changes
    and a click somewhere else must not be a quiet way to throw work away. The
    tree has already moved by then, so Cancel answers false and the window puts
    the selection back.

    It is also the only writer of the card header counter, which shows the
    active page's title and nothing else. A page whose title changes between
    two syncs, a star that comes or goes or a toggle that shows other rows,
    asks for the counter again through its OnTitleChanged hook, so the header
    never trails the page by a tick. The hint of the row under the mouse
    goes up to the window through OnHint, and the window shows it on its status
    line. A hint is a sentence and the header has room for a word or two next
    to the card title, so a hint written up there ran over the title and out of
    the card. A strip of its own along the bottom of the card took two lines
    from every page whether it had anything to say or not, and those were the
    lines a list needed in the smallest window. The status line already runs
    the whole width of the window and says nothing a person is reading while
    the mouse is on a row.

    Every tab says its whole caption. The shell works out how wide its tabs
    have to be from the longest caption in the theme's own text measurement,
    and the window keeps the inspector at least as wide as five of those, so a
    tab never reads Prop and three dots.

    A tab whose page cannot handle the current selection stays clickable. The
    page behind it draws an empty state that says why, because a tab that greys
    itself out teaches nothing and a person then has to guess what a Pointer
    page wants from them.

    No page writes to a record. A page builds a transaction and hands it up
    through OnCommit, and the window answers with ok, how many changes landed
    and which ones did not. A page clears what it was holding only when the
    commit said ok and at least one change landed, and otherwise it keeps the
    buffer, stays dirty and says why through OnStatus. Anything that cannot be
    undone goes up through OnAct instead, which is the window's guarded path, so
    activation and a value write never reach the journal.

    The Properties page is that schema in a grid. It reads the definitions out
    of Properties, asks what the whole selection agrees on, and emits one
    transaction for the whole selection, so fourteen records change under one
    undo entry. What it knows about Cheat Engine is only what the schema could
    not hide for it.
      * IsReadable is a flag Cheat Engine sets inside its own value getter and
        nowhere else, so the row has to read the value of every subject record
        before it means anything. Without that a perfectly healthy record
        reports itself unreadable. The schema does the read through its Prime
        hook and the hint tells the person why the row behaves that way.
      * The base of a pointer record belongs to the Pointer page, so the Address
        row is drawn read only with a hint that says where to edit it. Writing
        Address here would throw the offsets away, and one fact wants one
        writer.
      * Live sync rebuilds these rows four times a second, so the rebuild is
        skipped outright while the grid has an editor open, and a refresh never
        discards what somebody typed.
      * Active and Value are not undoable, so they leave through OnAct. Running
        a script and writing process memory are things the journal cannot take
        back, and pretending otherwise would be worse than not offering it.

    Nothing in this file raises. Every Cheat Engine touch, every hook the window
    owns and every theme call is wrapped, because a defect in one of them must
    cost a row and never the frame.
]]

local Properties = require("Manifold-AddressList-Properties")
local Types = require("Manifold-AddressList-Types")

--------------------------------------------------------
--                    Shared helpers                  --
--------------------------------------------------------

--- One guarded property write. A control that was freed and a property this
--- Cheat Engine does not have both answer false instead of raising.
local function safeSet(control, property, value)
    if control == nil then return false end
    return (pcall(function() control[property] = value end))
end

--- Calls one of the owner's hooks. A defect inside a hook costs the action and
--- never the window around it.
local function fire(hook, ...)
    if type(hook) ~= "function" then return false end
    return (pcall(hook, ...))
end

--- One log line, or nothing at all when this segment runs without a log.
local function say(self, level, message)
    local log = self and self.Log
    if log == nil then return end
    local method = log[level]
    if type(method) ~= "function" then return end
    pcall(method, log, message)
end

--- Sends one sentence to the status line. The window decides what to do with
--- it, and a window that assigned no hook simply hears nothing.
local function status(self, text)
    if text == nil or text == "" then return false end
    return fire(self.OnStatus, tostring(text))
end

--
--- ∑ Runs something that opens a modal through the window's own guard.
---
---   A modal runs a nested message loop, so the sync timer and the frame timer
---   would both fire inside it. The window counts that with a busy counter and
---   this is how a page reaches it. Without the hook the call still happens,
---   because a colour picker that never opens is worse than one that opens
---   while a timer ticks.
--- @param owner table # The page or the inspector.
--- @param fn function
--- @return any # Whatever fn answered, or nil when it did not finish.
--
local function guarded(owner, fn)
    local hook = owner and owner.OnGuard
    if type(hook) ~= "function" then
        local ok, value = pcall(fn)
        if ok then return value end
        return nil
    end
    local ok, value = pcall(hook, fn)
    if ok then return value end
    return nil
end

--- A private copy of a list of ids, so nothing the caller does to their table
--- reaches into the page afterwards.
local function copyIDs(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do out[#out + 1] = id end
    return out
end

--- Whether two id lists name the same records in the same order.
local function sameIDs(first, second)
    if #first ~= #second then return false end
    for index = 1, #first do
        if first[index] ~= second[index] then return false end
    end
    return true
end

--
--- ∑ Whether showing these ids would take from a page something nobody has
---   written yet.
---
---   A page that edits one record out of the selection loses what is in its
---   editor the moment that record changes, and a page that keeps its work per
---   record loses nothing at all. So the page is asked in its own terms rather
---   than guessed at from the id list, and a page that answers neither question
---   is left alone. The gate has to stay silent where there is nothing to lose,
---   or a pending hotkey edit would put a dialog in front of every click in the
---   tree.
--- @param page table
--- @param ids table # The ids the selection is moving to.
--- @param snapshot table|nil
--- @return boolean
--
local function losesBuffer(page, ids, snapshot)
    -- One subject made of the whole selection, which is the drop-down page.
    if type(page.SameSubject) == "function" then
        local ok, same = pcall(page.SameSubject, page, ids)
        if ok then return same ~= true end
    end
    -- One record picked out of the selection, which is the script page and the
    -- pointer page. A selection they cannot edit at all moves them too, because
    -- the page then has no subject and reads the record again.
    if type(page.SubjectOf) == "function" and page.ID ~= nil then
        local ok, id = pcall(page.SubjectOf, page, ids, snapshot)
        if ok then return id ~= page.ID end
    end
    return false
end

--- Turns a list of ids or a set of them into a set, because the window hands
--- changed ids over in both shapes.
local function idSet(ids)
    local set = {}
    if type(ids) ~= "table" then return set end
    for _, id in ipairs(ids) do set[id] = true end
    for id, value in pairs(ids) do
        if value == true and type(id) == "number" then set[id] = true end
    end
    return set
end

--- The description of one record, or a readable stand in when it has none.
local function nameOf(snapshot, id)
    local node = snapshot ~= nil and snapshot.ByID and snapshot.ByID[id] or nil
    local name = node and node.Description
    if type(name) == "string" and name ~= "" then return name end
    return "#" .. tostring(id)
end

--
--- ∑ The label one transaction carries, which is what the undo menu shows and
---   what the status line flashes.
---
---   One record is named, because a person reading Colour on Health knows
---   exactly what they are about to put back. Many records are counted, because
---   fourteen names would not fit and would not help.
--- @param label string # The property's own label.
--- @param ids table # The records the change touches.
--- @param snapshot table|nil
--- @return string
--
local function labelFor(label, ids, snapshot)
    local count = #ids
    if count == 1 then
        return label .. " on '" .. nameOf(snapshot, ids[1]) .. "'"
    end
    return label .. " on " .. count .. " records"
end

--------------------------------------------------------
--                 The Properties page                --
--------------------------------------------------------

local Page = {}
Page.__index = Page

--- The tab this page lives behind, kept here so the shell and the page agree
--- on one spelling.
Page.Key = "Properties"

--
--- ∑ The categories that start shut.
---
---   The first four carry what a person opened the inspector to look at. The
---   last two are long lists of flags that would push everything else off the
---   canvas on every selection.
--
Page.CollapsedAtStart = { Group = true, Advanced = true }

--- The virtual keys the page answers by itself. Everything else goes straight
--- to the grid.
Page.Keys = { F2 = 113 }

--- The two lines the grid shows when there is nothing to list, and the pair for
--- a selection whose records have all gone.
Page.EmptyNone = {
    Title = "Nothing is selected",
    Hint = "Pick a record in the list to see what it holds."
}
Page.EmptyGone = {
    Title = "Those records are gone",
    Hint = "Cheat Engine no longer has them. Pick another record."
}

--
--- ∑ The two values Cheat Engine stores for a record that has no colour of its
---   own.
---
---   A swatch is only drawn for a real colour. clWindowText is a system colour
---   and filling a rectangle with it would paint a square nobody chose, so the
---   default reads as the word Default and draws no swatch at all.
--
local DEFAULT_COLORS = { [0x80000008] = true, [0x20000000] = true }

--- Whether a property means the same thing for every record in the selection.
--- A row that does not apply to all of them is left out rather than shown with
--- a value only some of the records really have.
local function appliesToAll(props, def, mrs, nodes)
    for index = 1, #mrs do
        if not props:Applies(def, mrs[index], nodes[index]) then return false end
    end
    return true
end

--
--- ∑ Builds the page. Nothing is created until Build, because the inspector
---   makes its pages before it has panels to put them on.
--- @param services table|nil # Theme, Surface and Grid as classes, plus
---        Properties, Types, Records, CE, Log, Settings and Frame.
--- @return table
--
function Page:New(services)
    services = services or {}
    return setmetatable({
        Theme        = services.Theme,
        SurfaceClass = services.Surface,
        GridClass    = services.Grid,
        Properties   = services.Properties,
        Types        = services.Types or Types,
        Records      = services.Records,
        CE           = services.CE,
        Log          = services.Log,
        Settings     = services.Settings,
        Frame        = services.Frame,

        Panel  = nil,
        Grid   = nil,
        Ready  = false,
        Reason = nil,

        --- The records this page is about, by id, and the snapshot they were
        --- read from. No memory record is ever kept, because a record that goes
        --- away leaves a wrapper that faults on the next read.
        IDs      = {},
        Snapshot = nil,

        --- What the last commit reported, so Save can answer whether the buffer
        --- may be cleared.
        LastResult = nil,

        OnCommit = nil,      -- (tx) -> ok, applied, failures
        OnAct    = nil,      -- (label, ids, fn) -> ok
        OnStatus = nil,      -- (text)
        OnHint   = nil,      -- (text or nil) the hovered row's hint, for the status line
        OnGuard  = nil       -- (fn) -> result, the window's busy guard
    }, Page)
end

--
--- ∑ Creates the grid on the page's panel and wires it up.
---
---   The collapsed categories are seeded here and then belong to the grid,
---   which keeps them for as long as the page lives. That is what makes the
---   state last a session without a second copy of it drifting out of step.
--- @param parent userdata
--- @return boolean, string|nil
--
function Page:Build(parent)
    self.Panel = parent
    local class = self.GridClass
    if class == nil then
        self.Reason = "the Properties page was built without the grid class"
        say(self, "Warning", "The Properties page has no grid class, so it shows nothing.")
        return false, self.Reason
    end
    local grid = class:New({
        Theme = self.Theme, Surface = self.SurfaceClass, Log = self.Log,
        Settings = self.Settings, Frame = self.Frame, Name = "Properties"
    })
    self.Grid = grid
    local ok, reason = grid:Attach(parent)
    if not ok then self.Reason = reason end
    grid.OnCommit = function(key, value) self:Committed(key, value) end
    grid.OnPick   = function(key) self:Picked(key) end
    grid.OnHover  = function(row) self:Hovered(row) end
    grid:SetCollapsed(Page.CollapsedAtStart)
    grid:SetEmpty(Page.EmptyNone.Title, Page.EmptyNone.Hint)
    self.Ready = ok == true
    return self.Ready, self.Reason
end

-- What the page is looking at -------------------------------------------------

--
--- ∑ Points the page at a selection and draws it.
---
---   A changed subject closes an open editor without committing it. What was
---   typed was meant for the records that were selected when the box opened,
---   and writing it into different ones is the one mistake a property grid must
---   never make.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return boolean
--
function Page:Show(ids, snapshot)
    local wanted = copyIDs(ids)
    local changed = not sameIDs(wanted, self.IDs)
    self.IDs = wanted
    if snapshot ~= nil then self.Snapshot = snapshot end
    if changed and self.Grid ~= nil then self.Grid:CancelEdit() end
    self:Rebuild()
    return true
end

--
--- ∑ Redraws after a sync or a commit, and does nothing at all while somebody
---   is typing.
---
---   Live sync calls this four times a second. A rebuild under an open editor
---   would move the ground the person is standing on, so the whole pass is
---   skipped instead. The editor closes on Enter, on Tab, on a click somewhere
---   else and on Save, and the next refresh after that catches up.
--- @param snapshot table|nil
--- @param changedIds table|nil # A list or a set. Nothing means everything.
--- @return boolean # Whether the rows were rebuilt.
--
function Page:Refresh(snapshot, changedIds)
    if snapshot ~= nil then self.Snapshot = snapshot end
    local grid = self.Grid
    if grid ~= nil and grid:IsEditing() then return false end
    if changedIds ~= nil and not self:Touches(changedIds) then return false end
    self:Rebuild()
    return true
end

--- Whether a set of changed ids holds any record this page is showing. A
--- commit somewhere else in the table is not this page's business.
function Page:Touches(changedIds)
    local set = idSet(changedIds)
    for _, id in ipairs(self.IDs) do
        if set[id] then return true end
    end
    return false
end

--
--- ∑ The memory records behind the selection, with the node of each one.
---
---   The node comes from the snapshot when there is one, because it already
---   carries everything the schema asks about and reading it again would cost
---   eight Cheat Engine calls per record. A record that is gone is dropped
---   rather than resolved to nil, so every list this returns is dense.
--- @return table, table, table # Records, nodes and the ids that survived.
--
function Page:Subject()
    local mrs, nodes, ids = {}, {}, {}
    local records, snapshot, props = self.Records, self.Snapshot, self.Properties
    for _, id in ipairs(self.IDs) do
        local mr = nil
        if records ~= nil then mr = records:Resolve(id, snapshot) end
        if mr ~= nil then
            local node = snapshot ~= nil and snapshot.ByID and snapshot.ByID[id] or nil
            if node == nil or node.Loaded ~= true then
                node = props ~= nil and props:NodeOf(mr) or node or {}
            end
            mrs[#mrs + 1] = mr
            nodes[#nodes + 1] = node
            ids[#ids + 1] = id
        end
    end
    return mrs, nodes, ids
end

-- The rows --------------------------------------------------------------------

--
--- ∑ Hands the grid a fresh set of rows and picks the right empty state when
---   there are none.
--- @return number # How many rows were handed over.
--
function Page:Rebuild()
    local grid = self.Grid
    if grid == nil then return 0 end
    local rows = self:Rows()
    if #rows == 0 then
        local empty = #self.IDs == 0 and Page.EmptyNone or Page.EmptyGone
        grid:SetEmpty(empty.Title, empty.Hint)
    end
    grid:SetRows(rows)
    return #rows
end

--
--- ∑ Every row the selection deserves, in the schema's own order.
---
---   The detail is loaded first, because Applies reads the type, the group flag
---   and the offset count out of the node, and a node the re-read window has not
---   reached yet carries none of them. A category with no surviving row is left
---   out completely rather than shown as a heading over nothing.
--- @return table
--
function Page:Rows()
    local rows = {}
    local props = self.Properties
    if props == nil then return rows end
    if self.Records ~= nil and self.Snapshot ~= nil and #self.IDs > 0 then
        pcall(function() self.Records:EnsureDetail(self.Snapshot, self.IDs) end)
    end
    local mrs, nodes = self:Subject()
    if #mrs == 0 then return rows end
    local many = #mrs > 1
    local collapsed = self.Grid ~= nil and self.Grid:CollapsedKeys() or {}
    for _, category in ipairs(Properties.Categories) do
        local body = {}
        for _, def in ipairs(Properties.List) do
            if def.Category == category and appliesToAll(props, def, mrs, nodes) then
                body[#body + 1] = self:RowFor(def, mrs, nodes, many)
            end
        end
        if #body > 0 then
            rows[#rows + 1] = {
                Kind = "category", Key = category, Label = category,
                Collapsed = collapsed[category] == true
            }
            for _, row in ipairs(body) do rows[#rows + 1] = row end
        end
    end
    return rows
end

--
--- ∑ One property row for the whole selection.
---
---   The value is what every record agrees on, or the mixed marker. A row that
---   is read only for any one of the records is read only for all of them, and
---   it carries that record's hint, because the reason it cannot be edited is
---   the useful part.
--- @param def table
--- @param mrs table
--- @param nodes table
--- @param many boolean # Whether more than one record is selected.
--- @return table
--
function Page:RowFor(def, mrs, nodes, many)
    local props = self.Properties
    local value = props:Common(mrs, def.Key, nodes)
    local mixed = value == Properties.MIXED

    local readOnly, hintNode = false, nodes[1]
    for index = 1, #nodes do
        if props:ReadOnly(def, nodes[index]) then
            readOnly, hintNode = true, nodes[index]
            break
        end
    end
    local hint = props:HintFor(def, hintNode)
    if many and def.Bulk == false then
        readOnly = true
        hint = "This one is changed on a single record at a time."
    end

    -- A script says what activating it really does, so on a mixed selection the
    -- louder of the two warnings is the one that is shown.
    local danger = nil
    for index = 1, #nodes do
        local one = props:DangerFor(def, nodes[index])
        if one ~= nil and (danger == nil or Types.IsScript(nodes[index])) then
            danger = one
        end
    end

    local row = {
        Kind = "property", Key = def.Key, Label = def.Label or def.Key,
        Editor = def.Editor, Text = props:Format(def.Key, value),
        Value = (not mixed) and value or nil,
        Mixed = mixed, ReadOnly = readOnly, Danger = danger, Hint = hint
    }
    if def.Editor == "bool" then
        row.Checked = value == true
    elseif def.Editor == "enum" then
        row.Choices = props:Choices(def)
    elseif def.Editor == "color" and type(value) == "number"
        and not DEFAULT_COLORS[value] and value ~= self:DefaultColor() then
        row.Swatch = value
    end
    return row
end

--- What this Cheat Engine calls a record with no colour of its own. It is read
--- through the wrapper rather than written down, because it is a system colour
--- and a literal would be wrong on a build that numbers them differently.
function Page:DefaultColor()
    local ce = self.CE
    if ce == nil or type(ce.Constant) ~= "function" then return 0x80000008 end
    local ok, value = pcall(ce.Constant, ce, "clWindowText", 0x80000008)
    if ok and type(value) == "number" then return value end
    return 0x80000008
end

-- Editing ---------------------------------------------------------------------

--
--- ∑ What the grid hands back when a row was edited.
---
---   Text arrives as text and is parsed by the schema, a box arrives as a
---   boolean and a list arrives as the choice's own value. A property the
---   journal cannot put back leaves through the act path instead, and
---   everything else becomes one transaction for the whole selection.
--- @param key string
--- @param value any
--- @return boolean # Whether anything was sent upwards.
--
function Page:Committed(key, value)
    local def = Properties.ByKey[key]
    local props = self.Properties
    self.LastResult = nil
    if def == nil or props == nil then return false end

    local wanted = value
    if type(value) == "string" then
        local parsed, err = props:Parse(key, value)
        if parsed == nil then
            self.LastResult = { Ok = false, Applied = 0 }
            status(self, err or "That is not a value this property takes.")
            return false
        end
        wanted = parsed
    end

    local mrs, nodes, ids = self:Subject()
    if #mrs == 0 then
        self.LastResult = { Ok = false, Applied = 0 }
        status(self, "Those records are gone, so nothing was written.")
        return false
    end
    if def.Undoable == false then return self:Run(def, ids, wanted) end

    local changes, skipped = props:Plan(mrs, key, wanted, nodes)
    if #changes == 0 then
        -- Nothing to do is not a failure. A value that already reads that way
        -- leaves a clean page, and a refusal says why.
        if #skipped > 0 then
            self.LastResult = { Ok = false, Applied = 0 }
            status(self, skipped[1].Reason)
        end
        return false
    end
    for _, change in ipairs(changes) do change.Kind = "property" end

    local ids2 = {}
    for _, change in ipairs(changes) do ids2[#ids2 + 1] = change.ID end
    local label = labelFor(def.Label or def.Key, ids2, self.Snapshot)
    local ok, applied, failures = self:Send({ Label = label, Changes = changes })
    self.LastResult = { Ok = ok, Applied = applied, Failures = failures }
    if not ok or applied <= 0 then
        status(self, label .. " did not happen. " .. self:WhyNot(failures))
        return false
    end
    if failures ~= nil and #failures > 0 then
        status(self, label .. ", " .. #failures .. " failed.")
    end
    -- The window refreshes after a commit as well, but doing it here means the
    -- new value is on screen before the next sync tick rather than a quarter of
    -- a second later.
    self:Rebuild()
    return true
end

--- The first reason a commit gave, as a sentence to put after the label.
function Page:WhyNot(failures)
    if type(failures) == "table" and failures[1] ~= nil then
        local reason = failures[1].Reason
        if type(reason) == "string" and reason ~= "" then return reason end
    end
    return "Cheat Engine did not take the change."
end

--
--- ∑ Hands one transaction to the window and reports what came back.
--- @param tx table # Label and Changes.
--- @return boolean, number, table|nil # ok, how many landed and the failures.
--
function Page:Send(tx)
    local hook = self.OnCommit
    if type(hook) ~= "function" then
        status(self, "This window cannot write records right now.")
        return false, 0, nil
    end
    local ran, ok, applied, failures = pcall(hook, tx)
    if not ran then return false, 0, nil end
    return ok == true, tonumber(applied) or 0, failures
end

--
--- ∑ The path for Active and Value, which undo cannot take back.
---
---   The work itself runs inside the window's own act, so the busy counter, the
---   script activation question, the logging and the refresh all happen where
---   they happen for the tree and for the popup menu. This page only says what
---   to write and to which records.
--- @param def table
--- @param ids table
--- @param value any
--- @return boolean
--
function Page:Run(def, ids, value)
    local hook = self.OnAct
    local label = labelFor(def.Label or def.Key, ids, self.Snapshot)
    if type(hook) ~= "function" then
        status(self, "This window cannot run that right now.")
        return false
    end
    local page = self
    local ran, ok = pcall(hook, label, ids, function()
        local applied, failures = 0, {}
        for _, id in ipairs(ids) do
            local mr = page.Records ~= nil and page.Records:Resolve(id, page.Snapshot) or nil
            if mr == nil then
                failures[#failures + 1] = { ID = id, Reason = "The record is gone." }
            else
                local done, reason = page.Properties:Write(mr, def.Key, value)
                if done then
                    applied = applied + 1
                else
                    failures[#failures + 1] = { ID = id, Reason = reason }
                end
            end
        end
        return applied, failures
    end)
    self.LastResult = { Ok = ran and ok == true, Applied = (ran and ok == true) and 1 or 0 }
    if not ran or ok ~= true then
        status(self, label .. " did not happen.")
        return false
    end
    self:Rebuild()
    return true
end

--
--- ∑ A row the grid cannot edit in place, which is the colour.
---
---   The picker is a modal, so it goes through the window's guard. What comes
---   back is an ordinary property change and takes the ordinary path, which is
---   how a colour ends up in the same undo history as everything else.
--- @param key string
--- @return boolean
--
function Page:Picked(key)
    if key ~= "Color" then return false end
    local ce, props = self.CE, self.Properties
    if ce == nil or type(ce.PickColor) ~= "function" or props == nil then
        status(self, "This Cheat Engine has no colour picker.")
        return false
    end
    local mrs, nodes = self:Subject()
    if #mrs == 0 then
        status(self, "Those records are gone, so nothing was written.")
        return false
    end
    local current = props:Common(mrs, "Color", nodes)
    local start = type(current) == "number" and current or nil
    local chosen = guarded(self, function() return ce:PickColor(start) end)
    if type(chosen) ~= "number" then return false end
    return self:Committed("Color", chosen)
end

--- The hovered row's hint, on its way through the inspector to the window's
--- status line. A row with no hint gives the line its own text back.
function Page:Hovered(row)
    local hint = nil
    if type(row) == "table" and type(row.Hint) == "string" and row.Hint ~= "" then
        hint = row.Hint
    end
    fire(self.OnHint, hint)
end

-- The dirty gate --------------------------------------------------------------

--
--- ∑ What is sitting in the open editor and has not been written yet.
---
---   An editor that is merely open holds nothing, so switching tabs past one
---   asks no question. A list box commits on the change the person made, so it
---   never holds anything either. Only typed text that differs from what the
---   box opened with counts.
--- @return table|nil # Key and Text, or nothing.
--
function Page:Pending()
    local grid = self.Grid
    if grid == nil or not grid:IsEditing() then return nil end
    local edit = rawget(grid, "Edit")
    if type(edit) ~= "table" or edit.Editor == "enum" then return nil end
    local ok, text = pcall(function() return edit.Control.Text end)
    if not ok then return nil end
    local current = tostring(text == nil and "" or text)
    if current == tostring(edit.Start == nil and "" or edit.Start) then return nil end
    return { Key = edit.Key, Text = current }
end

function Page:IsDirty()
    return self:Pending() ~= nil
end

--
--- ∑ Writes what is in the open editor.
---
---   The answer is whether the buffer may be cleared, which is what the leave
---   gate needs. A commit that Cheat Engine refused leaves the text where it
---   was and answers false, so the person stays on the page with their typing
---   intact.
--- @return boolean
--
function Page:Save()
    if not self:IsDirty() then return true end
    self.LastResult = nil
    self.Grid:CommitEdit()
    local result = self.LastResult
    if result == nil then
        -- The grid closed the editor and nothing needed writing, which is a
        -- clean page either way.
        return true
    end
    return result.Ok == true and result.Applied > 0
end

--- Throws the open editor away without writing it.
function Page:Discard()
    if self.Grid == nil then return false end
    return self.Grid:CancelEdit()
end

--- What the card header counter shows while this page is active.
function Page:Title()
    local count = #self.IDs
    if count == 0 then return "Nothing selected" end
    if count == 1 then return nameOf(self.Snapshot, self.IDs[1]) end
    return count .. " records"
end

--
--- ∑ The keys the page answers. The grid owns nearly all of them.
---
---   F2 is the exception. The window offers it as edit the description, so a
---   press that lands on a category or on a row nobody can edit goes to the
---   description row instead of doing nothing.
--- @param key number # Virtual key code.
--- @return boolean # Whether the key was used.
--
function Page:HandleKey(key)
    local grid = self.Grid
    if grid == nil then return false end
    if key == Page.Keys.F2 and not grid:IsEditing() then
        local row = grid:FocusedRow()
        local usable = type(row) == "table" and row.Kind == "property" and not row.ReadOnly
        if not usable and grid:RowByKey("Description") ~= nil then
            grid:FocusKey("Description")
            return (grid:BeginEdit("Description")) == true
        end
    end
    return grid:HandleKey(key) == true
end

--- Releases the grid. The panel belongs to the form and outlives the page.
function Page:Destroy()
    if self.Grid ~= nil then
        pcall(function() self.Grid:Destroy() end)
        self.Grid = nil
    end
    self.Panel, self.Snapshot, self.LastResult = nil, nil, nil
    self.IDs = {}
    self.Ready = false
end

--------------------------------------------------------
--                     The shell                      --
--------------------------------------------------------

local Inspector = {}
Inspector.__index = Inspector

--- The Properties page class, so the window and the tests can reach it without
--- a file of its own for one page.
Inspector.PropertiesPage = Page

--
--- ∑ The tabs, in the order they are shown.
---
---   The hints name the shortcut in parentheses, the way every button in this
---   window does, because a tab strip is the only place a person will look for
---   what Ctrl and E do.
--
Inspector.Tabs = {
    { Key = "Properties", Caption = "Properties",
      Hint = "Everything the selected records hold, in one grid. (Ctrl+1)" },
    { Key = "Pointer", Caption = "Pointer",
      Hint = "The pointer chain of one record, level by level. (Ctrl+P)" },
    { Key = "Script", Caption = "Script",
      Hint = "The Auto Assembler script of one record. (Ctrl+E)" },
    { Key = "DropDown", Caption = "Drop-down",
      Hint = "The list a record offers instead of raw values. (Ctrl+4)" },
    { Key = "Hotkeys", Caption = "Hotkeys",
      Hint = "Every hotkey on the selection, and the clashes between them. (Ctrl+5)" }
}

--- The tab a fresh window opens on when the settings hold nothing usable.
Inspector.DefaultPage = "Properties"

--
--- ∑ The narrowest content area every page is laid out for, in pixels.
---
---   Every page is checked at this width with nothing overlapping and nothing
---   cut. Narrower than this the field rows still stay clear of each other,
---   but the text boxes get too short to read an address in. The shell itself
---   asks for more whenever its tabs need more, which ContentMinWidth says, so
---   in the window a page is never given less than this and usually more.
--
Inspector.MinWidth = 300

--
--- ∑ The tab strip's own spacing, as the theme lays a strip out.
---
---   TabGap stands between two tabs, TabEdge at both ends of the strip, which
---   is the page edge every page starts and ends its controls on, and TabPad
---   is what a caption keeps clear of the edges of its tab, the bevel and a
---   margin on each side together. The theme keeps these to itself, so they
---   are written down here, and the inspector test lays a real strip out at
---   the width worked out from them to prove the two still agree.
--
Inspector.TabGap = 4
Inspector.TabEdge = 6
Inspector.TabPad = 10

--- What a line height is taken to be before the theme can say.
local LINE_HEIGHT = 15

--- What a cut text ends in.
local ELLIPSIS = "..."

--- How many characters a string holds. UTF-8 aware, with a byte count for a
--- string that is not valid UTF-8.
local function textLength(text)
    local lib = rawget(_G, "utf8")
    if type(lib) == "table" and type(lib.len) == "function" then
        local count = lib.len(text)
        if count then return count end
    end
    return #text
end

--- The characters of a string from first to last, never cutting one in half.
local function textSlice(text, first, last)
    local lib = rawget(_G, "utf8")
    if type(lib) ~= "table" or type(lib.offset) ~= "function" or not lib.len(text) then
        return text:sub(first, last)
    end
    local count = lib.len(text)
    if last > count then last = count end
    if first > last then return "" end
    local from = lib.offset(text, first)
    local to = lib.offset(text, last + 1)
    return text:sub(from, (to or (#text + 1)) - 1)
end

--
--- ∑ Breaks a sentence into lines of a fixed number of characters and keeps
---   at most so many of them.
---
---   The breaks go where Windows puts them when it wraps a label, at the
---   spaces, and a word longer than a whole line is split, because the
---   system would let it stick out past the edge. When the text needs more
---   lines than it may have, the last line is filled with as much of the rest
---   as fits and ends in dots. Consolas is monospaced, so a count of
---   characters is a width.
---
---   The lines come back joined with a line break, so a label shows exactly
---   these lines and does not wrap them a second time.
--- @param text string|nil
--- @param perLine number # Characters that fit on one line.
--- @param lines number # The most lines there may be.
--- @return string, boolean # What to show, and whether anything was cut.
--
function Inspector.WrapText(text, perLine, lines)
    local clean = tostring(text == nil and "" or text):gsub("%s+", " ")
    clean = clean:gsub("^ ", ""):gsub(" $", "")
    perLine = math.floor(tonumber(perLine) or 0)
    lines = math.max(1, math.floor(tonumber(lines) or 1))
    if clean == "" then return "", false end
    if perLine <= 0 then return "", true end

    local out, current = {}, ""
    local function push()
        out[#out + 1] = current
        current = ""
    end
    for word in clean:gmatch("%S+") do
        while textLength(word) > perLine do
            if current ~= "" then push() end
            out[#out + 1] = textSlice(word, 1, perLine)
            word = textSlice(word, perLine + 1, textLength(word))
        end
        if word ~= "" then
            if current == "" then
                current = word
            elseif textLength(current) + 1 + textLength(word) <= perLine then
                current = current .. " " .. word
            else
                push()
                current = word
            end
        end
    end
    if current ~= "" then push() end
    if #out <= lines then return table.concat(out, "\n"), false end

    -- The last line that may be shown takes the rest of the text as far as it
    -- goes, so a cut note says as much as its lines can hold.
    local kept = {}
    for index = 1, lines - 1 do kept[index] = out[index] end
    local rest = table.concat(out, " ", lines)
    local room = perLine - #ELLIPSIS
    local last
    if room <= 0 then
        last = ELLIPSIS:sub(1, perLine)
    else
        last = textSlice(rest, 1, room):gsub("%s+$", "") .. ELLIPSIS
    end
    kept[lines] = last
    return table.concat(kept, "\n"), true
end

--- The character width and line height of the segment font, and what GDI
--- answers for Consolas at ten points when the theme cannot say.
local function metricsOf(theme)
    local charWidth, lineHeight = 7, LINE_HEIGHT
    if theme ~= nil and type(theme.TextMetrics) == "function" then
        local ok, measuredWidth, measuredHeight = pcall(theme.TextMetrics, theme)
        if ok then
            if tonumber(measuredWidth) and measuredWidth > 0 then charWidth = measuredWidth end
            if tonumber(measuredHeight) and measuredHeight > 0 then lineHeight = measuredHeight end
        end
    end
    return charWidth, lineHeight
end

--
--- ∑ How wide one tab has to be for every caption to be read whole.
---
---   The longest caption is measured in the theme's own character width at
---   the segment font size, which is the size and the font a tab caption is
---   drawn in. Consolas is monospaced and its bold face has the same advance,
---   so a count of characters is the width. The theme cuts a caption to the
---   whole characters its room holds, so the width is checked the way the
---   theme will read it, which keeps a scaled display with a fractional
---   character width from losing the last letter to rounding.
--- @param theme table|nil
--- @return number # Pixels, the caption's room and the tab's own pad together.
--
function Inspector.TabWidth(theme)
    local charWidth = metricsOf(theme)
    local longest = 0
    for _, tab in ipairs(Inspector.Tabs) do
        longest = math.max(longest, textLength(tostring(tab.Caption or tab.Key or "")))
    end
    local room = math.ceil(longest * charWidth)
    while math.floor(room / charWidth) < longest do room = room + 1 end
    return room + Inspector.TabPad
end

--
--- ∑ How wide the tab strip has to be for every tab to stand on one row at
---   its full width, with a gap between two tabs and the page edge at both
---   ends.
---
---   The theme keeps the page edge at every width, so a strip one pixel
---   narrower than this puts the last tab on a second row rather than letting
---   the row stand out past the page.
--- @param theme table|nil
--- @return number
--
function Inspector.StripWidth(theme)
    local count = #Inspector.Tabs
    return count * Inspector.TabWidth(theme) + (count - 1) * Inspector.TabGap
        + 2 * Inspector.TabEdge
end

--
--- ∑ The narrowest the inspector's content area may be, which is the wider of
---   what the tab strip needs and what every page is laid out for.
---
---   The window adds its card around this and keeps the inspector at least
---   that wide, and the window's own minimum width is worked out from it.
--- @param theme table|nil
--- @return number
--
function Inspector.ContentMinWidth(theme)
    return math.max(Inspector.MinWidth, Inspector.StripWidth(theme))
end

--- A note may wrap onto this many lines before it is cut.
local NOTE_LINES = 12

--
--- ∑ Wraps a label to a width and gives it the height its lines need, which is
---   nothing at all for an empty text.
---
---   The pages stack their explanatory lines at the top, and a label that
---   sizes itself only does so once its parent has a window, so a page that
---   was built hidden would stack them at the wrong height. Worked out here
---   the height is known the moment the text is, and a note that says nothing
---   takes no room and never has to be hidden, which would change the order
---   the stack is laid out in. A label that does not know its width yet gets
---   its text on one line and the first resize wraps it.
--- @param theme table|nil
--- @param label userdata
--- @param text string|nil
--- @param width number|nil # Pixels the text may use.
--- @param lines number|nil # The most lines it may take.
--- @return number, boolean # The height it took, and whether the text was cut.
--
function Inspector.FitNote(theme, label, text, width, lines)
    text = text == nil and "" or tostring(text)
    local charWidth, lineHeight = metricsOf(theme)
    local shown, cut = text, false
    width = tonumber(width)
    if width ~= nil and width > 0 then
        shown, cut = Inspector.WrapText(text, math.floor(width / charWidth), lines or NOTE_LINES)
    end
    local count = 0
    if shown ~= "" then
        local _, breaks = shown:gsub("\n", "\n")
        count = breaks + 1
    end
    local height = count * lineHeight
    safeSet(label, "AutoSize", false)
    safeSet(label, "WordWrap", true)
    safeSet(label, "Caption", shown)
    safeSet(label, "Height", height)
    safeSet(label, "Hint", cut and text or "")
    safeSet(label, "ShowHint", cut)
    return height, cut
end

--- The services a page is built with. Copied by name so a window that hands
--- over more than this cannot leak anything unexpected into a page.
local PAGE_SERVICES = {
    "Theme", "Surface", "Frame", "Grid", "Properties",
    "Types", "Records", "CE", "Log", "Settings"
}

--- Whether a tab key is one this shell knows.
local function knownTab(key)
    for _, tab in ipairs(Inspector.Tabs) do
        if tab.Key == key then return tab end
    end
    return nil
end

--
--- ∑ Builds the shell. Nothing is created until Build, so the window can hold
---   an inspector before the card it lives in exists.
--- @param services table|nil # The page services plus Pages, which holds the
---        Pointer, Script, DropDown and Hotkeys classes.
--- @return table
--
function Inspector:New(services)
    services = services or {}
    local bag = {}
    for _, name in ipairs(PAGE_SERVICES) do bag[name] = services[name] end
    return setmetatable({
        Theme    = services.Theme,
        Log      = services.Log,
        Settings = services.Settings,
        Services = bag,
        Classes  = services.Pages or {},

        Content = nil,
        Strip   = nil,
        Panels  = {},        -- tab key to the panel that holds the page
        Pages   = {},        -- tab key to the page instance
        Empties = {},        -- tab key to the empty state of a page we lack
        Active  = nil,

        IDs      = {},
        Snapshot = nil,
        --- The hint of the row the mouse is on, whole, or nothing. The window
        --- decides how much of it its status line can show.
        Hint = nil,
        --- The title the counter was last given, so a page asking again for
        --- the same words costs the window nothing.
        Pushed = nil,

        OnCommit = nil,      -- (tx) -> ok, applied, failures
        OnAct    = nil,      -- (label, ids, fn) -> ok
        OnStatus = nil,      -- (text)
        OnTitle  = nil,      -- (text) the card header counter, one writer only
        OnHint   = nil,      -- (text or nil) the hovered row's hint, for the status line
        OnGuard  = nil       -- (fn) -> result, the window's busy guard
    }, Inspector)
end

--
--- ∑ Creates the tab strip and one panel per page inside the inspector card.
---
---   Every panel is aligned to the client area and all but one are hidden. The
---   LCL leaves a hidden control out of its alignment pass altogether, so the
---   visible panel gets the whole area under the strip and the others cost
---   nothing at all.
---
---   The tabs carry no width of their own. The strip shares its width out
---   evenly whenever it changes size and never gives a tab less than its
---   longest caption needs. A strip too narrow for five of those starts a
---   second row rather than cutting a caption, and the window keeps the
---   inspector wide enough that it never has to.
--- @param content userdata # The card's content panel.
--- @return boolean
--
function Inspector:Build(content)
    self.Content = content
    local wanted = nil
    if self.Settings ~= nil and type(self.Settings.Get) == "function" then
        local ok, value = pcall(self.Settings.Get, self.Settings, "InspectorPage")
        if ok and type(value) == "string" then wanted = value end
    end
    if knownTab(wanted) == nil then wanted = Inspector.DefaultPage end

    local theme = self.Theme
    if theme ~= nil and type(theme.CreateTabStrip) == "function" then
        local ok, strip = pcall(theme.CreateTabStrip, theme, content, {
            Tabs = Inspector.Tabs, Selected = wanted,
            MinTabWidth = Inspector.TabWidth(theme),
            OnChange = function(key) self:Tabbed(key) end
        })
        if ok and type(strip) == "table" then self.Strip = strip end
    end
    if self.Strip == nil then
        say(self, "Warning", "This window could not build the inspector tabs, "
            .. "so only the Properties page is reachable.")
    end

    for _, tab in ipairs(Inspector.Tabs) do
        local panel = self:MakePanel(content)
        self.Panels[tab.Key] = panel
        safeSet(panel, "Visible", false)
        self:MakePage(tab, panel)
    end
    self.Active = nil
    self:ShowPage(wanted)
    return true
end

--- One panel for one page. Without a theme it falls back to a plain panel, so
--- a themeless build still shows its pages.
function Inspector:MakePanel(parent)
    local theme = self.Theme
    if theme ~= nil and type(theme.CreatePanel) == "function" then
        local ok, panel = pcall(theme.CreatePanel, theme, parent, {
            Align = "alClient", ColorKey = "COLOR_INPUT"
        })
        if ok and panel ~= nil then return panel end
    end
    local create = rawget(_G, "createPanel")
    if type(create) ~= "function" then return nil end
    local ok, panel = pcall(create, parent)
    if not ok or panel == nil then return nil end
    safeSet(panel, "Parent", parent)
    safeSet(panel, "Align", "alClient")
    safeSet(panel, "Caption", "")
    return panel
end

--
--- ∑ Builds one page and wires its hooks to the shell's own.
---
---   A page class that is not installed leaves an empty state behind on its
---   panel instead. The tab still works, so a person clicking Script is told
---   what is missing rather than met with a dead button.
--- @param tab table
--- @param panel userdata|nil
--- @return table|nil
--
function Inspector:MakePage(tab, panel)
    local class = tab.Key == Page.Key and Page or self.Classes[tab.Key]
    if type(class) ~= "table" or type(class.New) ~= "function" then
        self:MakeEmpty(tab, panel)
        return nil
    end
    local ok, page = pcall(class.New, class, self.Services)
    if not ok or type(page) ~= "table" then
        say(self, "Warning", "The " .. tab.Caption .. " page could not be built.")
        self:MakeEmpty(tab, panel)
        return nil
    end
    page.OnCommit = function(tx) return self:Commit(tx) end
    page.OnAct    = function(label, ids, fn) return self:Act(label, ids, fn) end
    page.OnStatus = function(text) return status(self, text) end
    page.OnHint   = function(text) self:Hovered(text) end
    page.OnGuard  = function(fn) return guarded(self, fn) end
    page.OnTitleChanged = function() return self:Retitle(page) end
    self.Pages[tab.Key] = page
    if panel ~= nil and type(page.Build) == "function" then
        pcall(page.Build, page, panel)
    end
    return page
end

--- The two lines shown on a tab whose page this copy of the segment does not
--- have. It names the file, because that is the one thing that fixes it.
function Inspector:MakeEmpty(tab, panel)
    local theme = self.Theme
    if panel == nil or theme == nil or type(theme.CreateEmptyState) ~= "function" then
        return nil
    end
    local ok, empty = pcall(theme.CreateEmptyState, theme, panel)
    if not ok or type(empty) ~= "table" then return nil end
    empty.Set("The " .. tab.Caption .. " page is not installed",
        "Copy Manifold-AddressList-" .. tab.Key .. ".lua into the modules folder.")
    self.Empties[tab.Key] = empty
    return empty
end

-- Moving between pages --------------------------------------------------------

--- The tab strip reported a click. A page that refuses to be left puts the
--- strip back on itself, because the strip presses a tab before anyone asks.
function Inspector:Tabbed(key)
    if key == self.Active then return end
    if self:ShowPage(key) then return end
    if self.Strip ~= nil then pcall(self.Strip.Select, self.Active, true) end
end

--
--- ∑ Shows one page and hides the rest.
---
---   The leaving page is asked first, so a page holding an unsaved change can
---   stop the move. The panels are hidden before the wanted one is shown, so
---   two of them are never aligned to the client area at the same time.
--- @param key string
--- @return boolean # Whether the page is now the active one.
--
function Inspector:ShowPage(key)
    if knownTab(key) == nil then return false end
    if key == self.Active then return true end
    if self.Active ~= nil and not self:CanLeave("page") then return false end

    for tabKey, panel in pairs(self.Panels) do
        if tabKey ~= key then safeSet(panel, "Visible", false) end
    end
    safeSet(self.Panels[key], "Visible", true)
    self.Active = key
    if self.Strip ~= nil then pcall(self.Strip.Select, key, true) end
    if self.Settings ~= nil and type(self.Settings.Set) == "function" then
        pcall(self.Settings.Set, self.Settings, "InspectorPage", key)
    end
    local page = self.Pages[key]
    if page ~= nil and type(page.Show) == "function" then
        pcall(page.Show, page, self.IDs, self.Snapshot)
    end
    self:Hovered(nil)
    self:PushTitle()
    return true
end

--- Which page is on screen.
function Inspector:Page()
    return self.Active
end

--- The instance behind one tab, for the window and for the tests.
function Inspector:PageFor(key)
    return self.Pages[key]
end

--- Whether the active page is holding something that was never written. Only
--- the active page can be, because every move away already went through the
--- gate.
function Inspector:IsDirty()
    local page = self.Pages[self.Active]
    if page == nil or type(page.IsDirty) ~= "function" then return false end
    local ok, dirty = pcall(page.IsDirty, page)
    return ok and dirty == true
end

--
--- ∑ The gate every page change, every selection move and the window's own
---   close go through.
---
---   Save, Discard and Cancel, and the answer is whether leaving is allowed.
---   Save that Cheat Engine refused counts as no, because the person's change
---   is still sitting there and throwing it away for them would be the wrong
---   way to be helpful.
--- @param reason string|nil # page, selection or close.
--- @return boolean
--
function Inspector:CanLeave(reason)
    local page = self.Pages[self.Active]
    if page == nil or type(page.IsDirty) ~= "function" then return true end
    local ok, dirty = pcall(page.IsDirty, page)
    if not ok or dirty ~= true then return true end

    local choice = self:Ask(page, reason)
    if choice == "discard" then
        pcall(page.Discard, page)
        return true
    end
    if choice ~= "save" then return false end
    local ran, saved = pcall(page.Save, page)
    if ran and saved == true then return true end
    status(self, "The change was not saved, so the page stayed where it was.")
    return false
end

--
--- ∑ Asks what to do with an unsaved change.
---
---   Without a themed question there is nothing safe to assume. Saving on the
---   person's behalf writes a record they never confirmed and discarding throws
---   their work away, so the move is refused and the reason is said out loud.
--- @param page table
--- @param reason string|nil
--- @return string # save, discard or cancel.
--
function Inspector:Ask(page, reason)
    local theme = self.Theme
    local title = "This page"
    if type(page.Title) == "function" then
        local ok, text = pcall(page.Title, page)
        if ok and type(text) == "string" and text ~= "" then title = text end
    end
    if theme == nil or type(theme.AskChoice) ~= "function" then
        status(self, "There is an unsaved change on this page. "
            .. "Save it or discard it before leaving.")
        return "cancel"
    end
    local message = "Leaving the page now would lose it."
    if reason == "close" then message = "Closing the window now would lose it." end
    if reason == "selection" then
        message = "Moving to another record now would lose it."
    end
    local chosen = guarded(self, function()
        return theme:AskChoice({
            Caption = "Unsaved change",
            Title = title .. " has a change that was never written.",
            Message = message,
            Choices = {
                { Key = "save", Caption = "Save" },
                { Key = "discard", Caption = "Discard" },
                { Key = "cancel", Caption = "Cancel" }
            }
        })
    end)
    if chosen ~= "save" and chosen ~= "discard" then return "cancel" end
    return chosen
end

-- What the window tells the inspector -----------------------------------------

--
--- ∑ Points the inspector at a selection.
---
---   A page holding something nobody wrote is asked first, exactly the way a
---   page change asks it, because a click in the tree would otherwise throw
---   twenty minutes of typing away without a dialog, a status line or a log
---   line. Cancel answers false and nothing here moves, so the window can put
---   the tree back on the record the page is still editing.
---
---   A forced move is never asked about. That is the tree reporting a selection
---   it had to change itself, a record that went away under a sync tick or one
---   the filter hid, and a question raised out of a timer tick would open a
---   modal inside a nested message loop this segment works hard to keep clear.
--- @param ids table|nil
--- @param snapshot table|nil
--- @param forced boolean|nil # The selection moved on its own, so do not ask.
--- @return boolean # False when the page refused to be left.
--
function Inspector:SetSelection(ids, snapshot, forced)
    local wanted = copyIDs(ids)
    local page = self.Pages[self.Active]
    if forced ~= true and page ~= nil and not sameIDs(wanted, self.IDs)
        and self:IsDirty() and losesBuffer(page, wanted, snapshot or self.Snapshot)
        and not self:CanLeave("selection") then
        return false
    end
    self.IDs = wanted
    if snapshot ~= nil then self.Snapshot = snapshot end
    if page ~= nil and type(page.Show) == "function" then
        pcall(page.Show, page, self.IDs, self.Snapshot)
    end
    self:Hovered(nil)
    self:PushTitle()
    return true
end

--
--- ∑ A sync or a commit happened. Only the page on screen is told, because the
---   other pages are shown their selection again the moment they are opened.
--- @param snapshot table|nil
--- @param changedIds table|nil
--- @return boolean
--
function Inspector:Refresh(snapshot, changedIds)
    if snapshot ~= nil then self.Snapshot = snapshot end
    local page = self.Pages[self.Active]
    if page ~= nil and type(page.Refresh) == "function" then
        pcall(page.Refresh, page, self.Snapshot, changedIds)
    end
    self:PushTitle()
    return true
end

--- Keys reach the active page and nowhere else.
function Inspector:HandleKey(key)
    local page = self.Pages[self.Active]
    if page == nil or type(page.HandleKey) ~= "function" then return false end
    local ok, handled = pcall(page.HandleKey, page, key)
    return ok and handled == true
end

-- The header counter and the hovered hint -------------------------------------

--
--- ∑ A page reported which row the mouse is on.
---
---   The row's hint goes up to the window through OnHint, which shows it on
---   its status line, and nothing means the mouse left the row, so the line
---   gets its own text back. The window's hook is only called when the hint
---   really changed, because a mouse move reports the same row many times a
---   second. The header counter is not touched, and the inspector never
---   reaches into the window for its status bar.
--- @param text string|nil
--- @return boolean # Whether the hint changed.
--
function Inspector:Hovered(text)
    local wanted = nil
    if type(text) == "string" and text ~= "" then wanted = text end
    if wanted == self.Hint then return false end
    self.Hint = wanted
    fire(self.OnHint, wanted)
    return true
end

--- The whole hint of the row the mouse is on, or nothing.
function Inspector:HintText()
    return self.Hint or ""
end

--
--- ∑ Writes the card header counter. This is the only place that does, and
---   it only ever writes the active page's title.
---
---   The window hands the text to the card's own setter, which cuts it to
---   the room the card title leaves, so a long record name ends in dots
---   before it could reach the title.
--- @return string # What the counter now says.
--
function Inspector:PushTitle()
    local text = self:TitleText()
    self.Pushed = text
    fire(self.OnTitle, text)
    return text
end

--
--- ∑ A page says its title may have changed, and the counter follows at once.
---
---   A title changes between two syncs as well, when a page turns dirty or
---   clean or a toggle on it shows other rows, and the counter used to wait
---   for the next sync to say so. A page calls this through its
---   OnTitleChanged hook whenever that can happen. Only the page on screen is
---   heard, because the counter never shows another page's title, and the
---   window is only told when the text really differs from what it was last
---   given, because a page asks on every character typed.
--- @param page table # The page that asked.
--- @return boolean # Whether the counter was written.
--
function Inspector:Retitle(page)
    if page == nil or self.Pages[self.Active] ~= page then return false end
    if self:TitleText() == self.Pushed then return false end
    self:PushTitle()
    return true
end

--- The active page's title, which is what the counter says.
function Inspector:TitleText()
    local page = self.Pages[self.Active]
    if page == nil or type(page.Title) ~= "function" then return "" end
    local ok, title = pcall(page.Title, page)
    if ok and type(title) == "string" then return title end
    return ""
end

-- Passing work upwards --------------------------------------------------------

--- A page's transaction on its way to the window's commit funnel.
function Inspector:Commit(tx)
    local hook = self.OnCommit
    if type(hook) ~= "function" then return false, 0, nil end
    local ran, ok, applied, failures = pcall(hook, tx)
    if not ran then return false, 0, nil end
    return ok == true, tonumber(applied) or 0, failures
end

--- A page's non-undoable action on its way to the window's guarded act.
function Inspector:Act(label, ids, fn)
    local hook = self.OnAct
    if type(hook) ~= "function" then return false end
    local ran, ok = pcall(hook, label, ids, fn)
    return ran and ok == true
end

--- Releases every page. The panels and the strip belong to the card, which the
--- window destroys with the form. A hint still showing is taken back first,
--- so the status line does not keep the words of a row that is gone.
function Inspector:Destroy()
    self:Hovered(nil)
    for _, page in pairs(self.Pages) do
        if type(page.Destroy) == "function" then pcall(page.Destroy, page) end
    end
    self.Pages, self.Panels, self.Empties = {}, {}, {}
    self.Strip, self.Content, self.Active = nil, nil, nil
    self.Snapshot, self.Hint, self.Pushed = nil, nil, nil
    self.IDs = {}
end

return Inspector
