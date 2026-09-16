--[[
    The record tree, drawn row by row on one canvas.

    This is the face of the whole window. It shows the Cheat Table's address
    list as a tree with a colour per record, an activation box, a type tag, an
    address, a value, badges and a coloured edge where the problem check found
    something. Cheat Engine's own tree control can do none of that from Lua. It
    publishes no custom draw, no hit test and no per node colour, so the only
    way to show a record the way this window wants to show it is to paint it.

    The tree never walks Cheat Engine. Records builds a snapshot, Records
    flattens it into rows, and this module paints those rows and answers the
    mouse and the keyboard over them. That split is what keeps a tree of four
    thousand records cheap, because only the rows on screen are ever touched
    and the walk happens on a timer somewhere else.

    Three Cheat Engine facts shape the interaction. The mouse trampoline drops
    the LCL's shift state, so Ctrl and Shift are read with isKeyPressed at the
    moment of the click. A mouse button arrives as an integer, so the right
    button is one. A canvas is a graphic control that never takes focus, so the
    window feeds keys in here by hand through HandleKey.

    Identity is the record id and never the wrapper and never the row number.
    Selection, the collapsed set, the focus and the scroll position are all
    kept by id, so a refresh that moved every record leaves the window looking
    at the same records it was looking at before.

    Everything a person can see is drawn with fillRect, line and textOut. There
    is no textRect anywhere, because its first argument is a rectangle table and
    it renders through Cheat Engine's formatted text renderer, which would read
    a record description as markup.

    One more fact about textOut decides how a row is painted. It is opaque. It
    fills the cell it writes into with the current brush before the glyphs go
    down, so whatever the last fill left behind becomes the background of the
    next piece of text. That is why the brush goes back to the row tone after
    the check box and after a highlight, and why a filter match is drawn as its
    own piece of text on its own brush rather than as a fill behind the whole
    description.

    A word on the two lists of names. The public readers Rows and Selection are
    methods, so what they read lives under another name inside the instance.
    A field and a method of one name cannot both exist, because the field would
    shadow the method and the call would try to call a table.
]]

local SurfaceModule = require("Manifold-AddressList-Surface")
local RecordsModule = require("Manifold-AddressList-Records")
local TypesModule = require("Manifold-AddressList-Types")

local Scroll = SurfaceModule.Scroll
local SurfaceDefaults = SurfaceModule.Defaults

local Tree = {}
Tree.__index = Tree

--
--- ∑ The measurements the tree lays a row out with. Everything else comes from
---   the measured font, so a larger font moves the columns with the text.
--
Tree.Defaults = {
    --- The coloured strip at the very left of a row that carries a problem.
    --- Three pixels is enough to see at a glance and narrow enough that it
    --- never looks like a column of its own.
    Edge = 3,
    --- One level of nesting. Sixteen matches what Cheat Engine's own tree uses
    --- and it leaves room for the expand arrow at every depth.
    Indent = 16,
    --- The gap between the expand arrow and the description.
    Gap = 4,
    --- The gap between where a description may end and where the type tag
    --- begins. One pad reads as no gap at all, so a description that had to be
    --- cut runs its ellipsis straight into the tag and the two read as one
    --- word. Three characters of air is enough to see the column change.
    ColumnGap = 18,
    --- The gap between a description and the badges that annotate it. They
    --- belong to the description in front of them, so they sit close to it and
    --- well away from the type column.
    BadgeGap = 8,
    --- The type tag column, in characters. Five holds WSTR and P8B.
    TypeChars = 5,
    --- The address column, in characters. Twenty holds a module name with an
    --- offset, which is what most pointer records show.
    AddressChars = 20,
    --- The value column, in characters, right aligned.
    ValueChars = 18,
    --- What the description keeps whatever else has to go. The tree card can be
    --- dragged down to three hundred and twenty pixels, which is narrower than
    --- the four columns at full width, so something has to give and it is never
    --- the description.
    MinDescriptionChars = 16,
    --- How far each column on the right may shrink before it is dropped.
    MinTypeChars = 3,
    MinAddressChars = 8,
    MinValueChars = 6
}

local Defaults = Tree.Defaults

--- Virtual key codes. Named here because a number in a branch says nothing
--- about which key it is.
local VK_CONTROL, VK_SHIFT = 0x11, 0x10
local VK_RETURN, VK_SPACE = 13, 32
local VK_PRIOR, VK_NEXT, VK_END, VK_HOME = 33, 34, 35, 36
local VK_LEFT, VK_UP, VK_RIGHT, VK_DOWN = 37, 38, 39, 40
local VK_A = 65
local VK_MULTIPLY = 0x6A

--- Cheat Engine's own value for a record with no colour of its own, and the
--- value an older build stored for the same thing. A record colour is compared
--- against these and never against black.
local DEFAULT_COLOR, DEFAULT_COLOR_ALT = 0x80000008, 0x20000000

--- The smallest difference in luminance between a record's own colour and the
--- row behind it. The same number the rest of the segment corrects with.
local CONTRAST = 70

--- How deep a walk goes before it decides the snapshot lies to it. A record
--- tree is never this deep, so reaching it means a cycle.
local MAX_DEPTH = 512

--- What a record nobody named shows instead of nothing at all. A row with an
--- empty widest column reads as a broken row rather than as a record without a
--- description.
local NO_DESCRIPTION = "(no description)"

--- The three dots a cut piece of text ends or breaks with. ASCII, because a
--- canvas draws what the font has and a single glyph ellipsis is not in every
--- one of them.
local ELLIPSIS = "..."

--------------------------------------------------------
--                   Small helpers                    --
--------------------------------------------------------

--- Sends one line to the log channel when there is one.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--- Calls one of the owner's hooks. A defect in the window must not take the
--- tree down with it, because the tree is what the person is looking at.
local function fire(handler, ...)
    if type(handler) ~= "function" then return end
    pcall(handler, ...)
end

--- Whether a colour is the one Cheat Engine gives every record that was never
--- coloured. The global is read at call time so a build that spells it
--- differently still works.
local function isDefaultColor(color)
    if color == nil then return true end
    if color == DEFAULT_COLOR or color == DEFAULT_COLOR_ALT then return true end
    return color == rawget(_G, "clWindowText")
end

--- Walks an id argument. A list carries the id as the value and a set carries
--- it as the key, and both shapes reach Select.
local function eachID(ids, visit)
    if type(ids) ~= "table" then return end
    for key, value in pairs(ids) do
        if type(value) == "number" then visit(value)
        elseif value == true and type(key) == "number" then visit(key) end
    end
end

--- Modifier state, read from Cheat Engine at the moment of the click. The
--- binding drops the LCL's shift argument, so the event cannot carry it.
local function pressed(self, key)
    local down = self.IsKeyDown
    if type(down) ~= "function" then return false end
    local ok, answer = pcall(down, key)
    return ok and answer == true
end

--- A muted or accent colour as it is drawn on one row. A selected or hovered
--- row is a tone those colours were not picked for, so there the surface
--- lifts them against it. A plain row and a stripe keep them as they are.
local function onRow(surface, color, background, lifted)
    if lifted and surface ~= nil and type(surface.Legible) == "function" then
        return surface:Legible(color, background)
    end
    return color
end

--- The colour a severity draws in. An unknown severity reads as information
--- rather than as nothing, so a row with a problem always shows an edge.
local function severityColor(colors, severity)
    if severity == "error" then return colors.Error end
    if severity == "warning" then return colors.Warning end
    return colors.Info
end

--
--- ∑ Every place a needle occurs in a piece of text, as character ranges.
---
---   Plain and never a Lua pattern. A description full of brackets and percent
---   signs is completely normal and a pattern would either raise or paint the
---   wrong characters.
--- @param text string
--- @param needles table # Lowered needles from the query.
--- @return table|nil # Ranges of two numbers, or nothing when there is no hit.
--
local function spansOf(text, needles)
    if type(needles) ~= "table" or #needles == 0 or text == "" then return nil end
    local lower, out = text:lower(), nil
    for _, needle in ipairs(needles) do
        if needle ~= "" then
            local from = 1
            while true do
                local start, stop = lower:find(needle, from, true)
                if start == nil then break end
                out = out or {}
                out[#out + 1] = { start, stop }
                from = stop + 1
            end
        end
    end
    return out
end

--
--- ∑ The ranges in order, with the ones that touch joined into one.
---
---   Two needles can hit the same characters, and the description is drawn one
---   piece at a time now, so overlapping ranges would draw the same letters
---   twice and push everything after them along by their width.
--- @param spans table|nil # Ranges of two numbers, in any order.
--- @return table|nil
--
local function mergeSpans(spans)
    if type(spans) ~= "table" or #spans == 0 then return nil end
    table.sort(spans, function(left, right)
        if left[1] == right[1] then return left[2] < right[2] end
        return left[1] < right[1]
    end)
    local out = { { spans[1][1], spans[1][2] } }
    for index = 2, #spans do
        local last, span = out[#out], spans[index]
        if span[1] <= last[2] + 1 then
            if span[2] > last[2] then last[2] = span[2] end
        else
            out[#out + 1] = { span[1], span[2] }
        end
    end
    return out
end

--
--- ∑ Cuts text to a pixel width by taking characters out of the MIDDLE and
---   keeping both ends.
---
---   The address column needs this and nothing else does. Four records inside
---   one module all begin with the same module name, so cutting the tail off
---   leaves four rows reading the same thing and throws away the offset, which
---   is the only part that tells them apart. The tail therefore gets the
---   larger half of whatever room is left.
---
---   The character count is an estimate off the measured character width,
---   which is exact at Consolas, and the measurement afterwards is what makes
---   it right at anything else.
--- @param canvas userdata
--- @param text string
--- @param width number # Pixels available.
--- @param charWidth number|nil # The measured width of one character.
--- @return string
--
local function elideMiddle(canvas, text, width, charWidth)
    text = tostring(text or "")
    width = tonumber(width) or 0
    if text == "" or width <= 0 then return "" end
    local function measure(value) return tonumber(canvas.getTextWidth(value)) or 0 end
    if measure(text) <= width then return text end
    charWidth = tonumber(charWidth) or 0
    if charWidth <= 0 then charWidth = measure("0") end
    if charWidth <= 0 then return "" end
    local keep = math.min(math.floor(width / charWidth) - #ELLIPSIS, #text - 1)
    if keep < 2 then return "" end
    local tail = math.ceil(keep / 2)
    local head = keep - tail
    local function build() return text:sub(1, head) .. ELLIPSIS .. text:sub(#text - tail + 1) end
    local shown = build()
    -- Whichever end is longer gives a character back, so the two stay near
    -- enough to even and the loop cannot run past the ellipsis on its own.
    while measure(shown) > width do
        if tail > head and tail > 1 then
            tail = tail - 1
        elseif head > 0 then
            head = head - 1
        else
            return ""
        end
        shown = build()
    end
    return shown
end

--
--- ∑ The badges a record earns, as short pieces of ASCII in the order they
---   are worth keeping.
---
---   They follow the description rather than sitting in a column of their own,
---   because a record with a hotkey or a drop-down list is the exception and a
---   column would cost every row the width of one. Following the description
---   is also what makes them read as a note about that description, which is
---   what they are.
---
---   The hotkey count comes first because nothing else on the row says it. The
---   link comes last because it only qualifies the list badge in front of it,
---   so it is the first to go when a row is short of room.
--- @param node table
--- @return table|nil # The pieces, or nothing when the record earns none.
--
local function badgeParts(node)
    local parts = nil
    local hotkeys = tonumber(node.HotkeyCount) or 0
    if hotkeys > 0 then parts = { "hk" .. math.floor(hotkeys) } end
    if (tonumber(node.DropDownCount) or 0) > 0 then
        parts = parts or {}
        parts[#parts + 1] = "dd"
    end
    if node.DropDownLinked == true then
        parts = parts or {}
        parts[#parts + 1] = "lnk"
    end
    return parts
end

--
--- ∑ The badges that fit behind a description, and the room they take.
---
---   The name is what a person reads a row for, and the badges are a note
---   about it, so the note gives way first. A description keeps all of itself
---   or MinDescriptionChars worth of width, whichever is less, before a single
---   badge is drawn. Short of that the last badge goes, then the one before
---   it, and a row with too little room for any of them shows none. A tree at
---   its narrowest used to cut Main hand to Mai and three dots to keep dd and
---   lnk behind it.
--- @param canvas userdata
--- @param parts table|nil # From badgeParts.
--- @param description string # What the description column would draw.
--- @param room number # Pixels from the description's start to its column end.
--- @param charWidth number
--- @return string, number # The badges to draw and the width they take, gap included.
--
local function fitBadges(canvas, parts, description, room, charWidth)
    if parts == nil or #parts == 0 then return "", 0 end
    local own = 0
    if description ~= "" then own = tonumber(canvas.getTextWidth(description)) or 0 end
    local keep = math.min(own, math.floor(Defaults.MinDescriptionChars * (charWidth or 0)))
    for count = #parts, 1, -1 do
        local text = table.concat(parts, " ", 1, count)
        local width = (tonumber(canvas.getTextWidth(text)) or 0) + Defaults.BadgeGap
        if width < room and room - width >= keep then return text, width end
    end
    return "", 0
end

--- True when the filter asks about problems, which is the one predicate that
--- needs another part of the window to have run first.
local function asksAboutProblems(query)
    if query == nil then return false end
    for _, predicate in ipairs(query.Predicates) do
        if predicate.Kind == "is" and predicate.Value == "problem" then return true end
    end
    return false
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the tree. Nothing is created until Attach, so a window can hold one
---   before it has a panel to put it on.
--- @param services table|nil # Theme, Surface, Records, Types, Log, Settings,
---        Frame, CE and an optional IsKeyDown.
--- @return table
--
function Tree:New(services)
    services = services or {}
    local settings = services.Settings
    local ce = services.CE
    local isKeyDown = services.IsKeyDown
    if type(isKeyDown) ~= "function" and ce ~= nil and type(ce.IsKeyDown) == "function" then
        isKeyDown = function(key) return ce:IsKeyDown(key) end
    end
    if type(isKeyDown) ~= "function" then
        isKeyDown = function(key)
            local fn = rawget(_G, "isKeyPressed")
            if type(fn) ~= "function" then return false end
            return fn(key) == true
        end
    end
    return setmetatable({
        Theme = services.Theme,
        Log = services.Log,
        Settings = settings,
        Frame = services.Frame,
        CE = ce,
        IsKeyDown = isKeyDown,
        -- The classes. Records is taken as an instance as happily as a class,
        -- because an instance reaches every pure function through its own
        -- metatable and only an instance can load detail.
        SurfaceClass = services.Surface or SurfaceModule,
        Records = services.Records or RecordsModule,
        Types = services.Types or TypesModule,

        Surface = nil,          -- the canvas, built by Attach
        Parent = nil,

        Snapshot = nil,
        RowList = {},           -- what Flatten produced, in draw order
        RowByID = {},           -- id to its index in RowList
        Collapsed = {},         -- ids the person closed by hand
        SelectionSet = {},      -- id to true
        SelectionCount = 0,
        Focus = nil,            -- the id the keyboard moves from
        Anchor = nil,           -- the row a shift click ranges from
        Hover = nil,            -- the row index under the mouse

        Query = nil,            -- the parsed filter
        QueryText = "",
        Visible = nil,          -- ids a filter allows, nil while there is none
        Matches = nil,
        Matched = 0,            -- how many records the filter matched
        ForceOpen = nil,        -- shown open while a filter is on
        NeedsProblems = false,  -- the filter asked about problems and there are none yet
        AskedForProblems = false,

        Problems = nil,         -- id to severity, nil until the check has run
        Values = {},            -- id to a table of Text and Readable

        ShowValues = settings == nil or settings.ShowValues ~= false,
        ShowAddresses = settings == nil or settings.ShowAddresses ~= false,

        Geometry = nil,         -- rebuilt on every paint, read by the hit test
        ColorCache = {},        -- record colour and row background to a colour
        ColorsSeen = nil,       -- the colour table the cache was built against

        OnSelectionChanged = nil,
        OnToggleActive = nil,
        OnOpen = nil,
        OnContext = nil,
        -- The filter asked for is problem and nothing has checked the table
        -- yet, so the window is asked to run the check once.
        OnNeedProblems = nil
    }, Tree)
end

--
--- ∑ Creates the canvas inside parent and takes its mouse events.
---
---   A build with neither a paint box nor an image reports false here and the
---   window falls back. Everything else in this module keeps working without a
---   canvas, so the rows, the selection and the keys can be driven headless.
--- @param parent userdata
--- @return boolean, string|nil
--
function Tree:Attach(parent)
    self.Parent = parent
    local surface = self.SurfaceClass:New({
        Theme = self.Theme, Log = self.Log, Settings = self.Settings,
        Frame = self.Frame, Name = "Tree"
    })
    self.Surface = surface
    local ok, reason = surface:Attach(parent)
    if not ok then
        say(self, "Warning", "The record tree has no canvas, " .. tostring(reason))
        return false, reason
    end
    surface:SetPainter(function(_, canvas, width, height, colors, metrics)
        self:Paint(canvas, width, height, colors, metrics)
    end)
    surface.OnMouseDown = function(button, x, y) self:MouseDown(button, x, y) end
    surface.OnMouseMove = function(x, y) self:MouseMove(x, y) end
    surface.OnMouseLeave = function() self:MouseLeave() end
    surface.OnDoubleClick = function(x, y) self:DoubleClick(x, y) end
    return true
end

--- Asks for a frame. Every change that moves a pixel ends here.
function Tree:Invalidate()
    if self.Surface then self.Surface:Invalidate() end
end

--------------------------------------------------------
--                      The rows                      --
--------------------------------------------------------

--
--- ∑ Rebuilds the flat row list from the snapshot, the collapsed set and the
---   filter, and remembers where every id landed.
---
---   Called after anything that can change which rows exist. It allocates one
---   table per row and nothing else, so it is cheap enough to run on a filter
---   keystroke over a few thousand records.
--- @return number # How many rows there are now.
--
function Tree:Rebuild()
    local rows = self.Records.Flatten(self.Snapshot, self.Collapsed,
        self.Visible, self.ForceOpen, self.Matches)
    self.RowList = rows
    local byID = {}
    for index, row in ipairs(rows) do byID[row.ID] = index end
    self.RowByID = byID
    if self.Hover ~= nil and rows[self.Hover] == nil then self.Hover = nil end
    if self.Anchor ~= nil and rows[self.Anchor] == nil then self.Anchor = nil end
    self:Invalidate()
    return #rows
end

--- The rows as they are drawn. The tests read this and so does the window when
--- it needs the order a range selection runs in.
function Tree:Rows()
    return self.RowList
end

function Tree:Count()
    return #self.RowList
end

--
--- ∑ Takes a new snapshot without losing the person's place in it.
---
---   Selection, focus, the collapsed set and the scroll position are all kept
---   by id. Ids that are gone are dropped, and the focus moves to the nearest
---   row that survived, so a refresh after a record was deleted in Cheat Engine
---   leaves the keyboard somewhere sensible.
--- @param snapshot table|nil
--- @return number # How many rows there are now.
--
function Tree:SetSnapshot(snapshot)
    local previousRows = self.RowList
    local surface = self.Surface
    local topID = nil
    if surface ~= nil and previousRows[surface.Top] ~= nil then
        topID = previousRows[surface.Top].ID
    end
    local previousFocus = self.Focus

    self.Snapshot = snapshot
    local byID = snapshot and snapshot.ByID or {}

    -- Anything keyed by an id that is gone would otherwise grow forever, and
    -- ids are reused when another Cheat Table is loaded, so a stale entry is
    -- not merely wasteful but wrong.
    local dropped = false
    for id in pairs(self.SelectionSet) do
        if byID[id] == nil then
            self.SelectionSet[id] = nil
            self.SelectionCount = self.SelectionCount - 1
            dropped = true
        end
    end
    for id in pairs(self.Collapsed) do
        if byID[id] == nil then self.Collapsed[id] = nil end
    end
    for id in pairs(self.Values) do
        if byID[id] == nil then self.Values[id] = nil end
    end
    if self.Focus ~= nil and byID[self.Focus] == nil then self.Focus = nil end

    -- A filter has to run again, because the matches were worked out against
    -- the snapshot that has just been replaced.
    if self.Query ~= nil and not self.Query.Empty then self:RunQuery() end
    self:Rebuild()

    if self.Focus == nil and previousFocus ~= nil then
        self.Focus = self:NearestSurvivor(previousRows, previousFocus)
    end
    if topID ~= nil then
        local index = self.RowByID[topID]
        if index ~= nil and surface ~= nil then surface:ScrollTo(index) end
    end
    if dropped then self:ReportSelection(true) end
    return #self.RowList
end

--
--- ∑ The id nearest to the one that went away, searched outward in the order
---   the rows were drawn before the refresh.
---
---   Only a record that has a row now counts, so the keyboard never lands on
---   something the person cannot see.
--- @param rows table # The rows as they were.
--- @param id number # The id that is gone.
--- @return number|nil
--
function Tree:NearestSurvivor(rows, id)
    local start = nil
    for index, row in ipairs(rows) do
        if row.ID == id then
            start = index
            break
        end
    end
    if start == nil then return nil end
    for step = 1, #rows do
        local after = rows[start + step]
        if after ~= nil and self.RowByID[after.ID] ~= nil then return after.ID end
        local before = rows[start - step]
        if before ~= nil and self.RowByID[before.ID] ~= nil then return before.ID end
    end
    return nil
end

--------------------------------------------------------
--                     The filter                     --
--------------------------------------------------------

--- Runs the parsed query over the snapshot and keeps what came back. The
--- visible set is also the set shown open, which is how a match inside a
--- collapsed group appears without touching what the person collapsed.
function Tree:RunQuery()
    local query = self.Query
    if query == nil or query.Empty then
        self.Visible, self.Matches, self.ForceOpen, self.Matched = nil, nil, nil, 0
        return 0
    end
    query.Problems = self.Problems
    local visible, matches, count = self.Records.Match(self.Snapshot, query)
    self.Visible, self.Matches, self.Matched = visible, matches, count
    self.ForceOpen = visible
    return count
end

--
--- ∑ Sets the filter text and shows what it matches.
---
---   Detail is loaded first when this tree was given a Records service that can
---   reach Cheat Engine, because the filter asks about types, options and
---   hotkey counts that the re-read window may not have reached yet.
---
---   A filter that asks about problems when nothing has checked the table yet
---   asks the window to run the check, once, and says so in its empty state.
--- @param text string|nil
--- @return number # How many records matched.
--
function Tree:SetQuery(text)
    self.QueryText = text or ""
    local query = self.Records.ParseQuery(self.QueryText)
    self.Query = query

    if not query.Empty and self.Snapshot ~= nil
        and type(self.Records.EnsureDetail) == "function" and self.Records.CE ~= nil then
        pcall(function() self.Records:EnsureDetail(self.Snapshot, nil) end)
    end

    self.NeedsProblems = asksAboutProblems(query) and self.Problems == nil
    if self.NeedsProblems and not self.AskedForProblems then
        self.AskedForProblems = true
        fire(self.OnNeedProblems)
    end
    if not self.NeedsProblems then self.AskedForProblems = false end

    self:RunQuery()
    self:Rebuild()
    self:IntersectSelection()
    return self.Matched
end

--- How many records the filter matched, for the status line. The count is kept
--- rather than recomputed, because a refresh re-runs the filter and the status
--- line asks for the answer on every tick.
function Tree:MatchedCount()
    return self.Matched
end

--- The filter text as the person typed it.
function Tree:Filter()
    return self.QueryText
end

--
--- ∑ Drops everything from the selection that the filter hides.
---
---   The count in the status bar has to be the count the next action will
---   touch, so a selection that still reached records nobody can see would make
---   Activate and Colour do more than the person asked for.
--- @return boolean # Whether anything was dropped.
--
function Tree:IntersectSelection()
    local visible = self.Visible
    if visible == nil then return false end
    local dropped = false
    for id in pairs(self.SelectionSet) do
        if not visible[id] then
            self.SelectionSet[id] = nil
            self.SelectionCount = self.SelectionCount - 1
            dropped = true
        end
    end
    if self.Focus ~= nil and not visible[self.Focus] then
        self.Focus = nil
        dropped = true
    end
    if dropped then
        self:Invalidate()
        self:ReportSelection(true)
    end
    return dropped
end

--------------------------------------------------------
--              What the window feeds in              --
--------------------------------------------------------

--
--- ∑ The worst severity per record, from the problem check.
--- @param problems table|nil # id to error, warning or info.
--- @return nil
--
function Tree:SetProblems(problems)
    self.Problems = problems
    if asksAboutProblems(self.Query) then
        self.NeedsProblems = problems == nil
        self:RunQuery()
        self:Rebuild()
        self:IntersectSelection()
        return
    end
    self:Invalidate()
end

--
--- ∑ The display values of the rows that were on screen.
---
---   Merged rather than replaced. The window reads values for visible rows
---   only, so replacing would blank every row that scrolled out of sight and
---   back again for one frame.
--- @param values table|nil # id to a table of Text and Readable.
--- @return nil
--
function Tree:SetValues(values)
    if type(values) ~= "table" then return end
    for id, value in pairs(values) do self.Values[id] = value end
    self:Invalidate()
end

--- Which of the two optional columns are drawn. Reading a value reads process
--- memory, so showing the column at all is a choice.
function Tree:SetColumns(columns)
    columns = columns or {}
    if columns.ShowValues ~= nil then self.ShowValues = columns.ShowValues == true end
    if columns.ShowAddresses ~= nil then self.ShowAddresses = columns.ShowAddresses == true end
    self:Invalidate()
end

--
--- ∑ The ids that are on screen right now, which is what the window reads
---   values for.
--- @return table # A list of ids in draw order.
--
function Tree:VisibleIDs()
    local out = {}
    local surface = self.Surface
    local first = surface and surface.Top or 1
    local visible = surface and surface.Visible or #self.RowList
    local last = math.min(#self.RowList, first + visible - 1)
    for index = first, last do
        local row = self.RowList[index]
        if row ~= nil then out[#out + 1] = row.ID end
    end
    return out
end

--------------------------------------------------------
--                     Selection                      --
--------------------------------------------------------

--
--- ∑ Tells the window what is selected now. One writer, so the status bar and
---   the inspector cannot disagree about it.
---
---   Forced means the tree changed the selection itself rather than a person
---   moving it, which is a record that went away and a record the filter hid.
---   Nobody may be asked to confirm one of those, because both arrive out of a
---   sync tick or out of a keystroke in the filter box and neither could be put
---   back if the answer were no.
--- @param forced boolean|nil
--- @return nil
--
function Tree:ReportSelection(forced)
    fire(self.OnSelectionChanged, self:Selection(), self.Focus, forced == true)
end

--
--- ∑ The selected ids, in pre-order.
---
---   Walking the snapshot rather than the rows is deliberate. A selected record
---   inside a group the person collapsed is still selected, and an action has
---   to reach it.
--- @return table
--
function Tree:Selection()
    local out = {}
    local snapshot = self.Snapshot
    if snapshot == nil then
        for id in pairs(self.SelectionSet) do out[#out + 1] = id end
        table.sort(out)
        return out
    end
    for _, node in ipairs(snapshot.Order) do
        if self.SelectionSet[node.ID] then out[#out + 1] = node.ID end
    end
    return out
end

function Tree:Focused()
    return self.Focus
end

function Tree:IsSelected(id)
    return self.SelectionSet[id] == true
end

--
--- ∑ Replaces the selection.
--- @param ids table|nil # A list of ids or a set of them.
--- @param focusId number|nil # Where the keyboard should sit afterwards.
--- @param scroll boolean|nil # Whether to bring the focus on screen.
--- @return number # How many records are selected now.
--
function Tree:Select(ids, focusId, scroll)
    local snapshot = self.Snapshot
    local selection, count = {}, 0
    eachID(ids, function(id)
        if snapshot ~= nil and snapshot.ByID[id] == nil then return end
        if selection[id] then return end
        selection[id] = true
        count = count + 1
    end)
    self.SelectionSet, self.SelectionCount = selection, count
    if focusId ~= nil and selection[focusId] then
        self.Focus = focusId
    elseif count > 0 then
        self.Focus = self:Selection()[1]
    else
        self.Focus = nil
    end
    self.Anchor = self.Focus ~= nil and self.RowByID[self.Focus] or nil
    if scroll and self.Focus ~= nil then self:ScrollToID(self.Focus) end
    self:Invalidate()
    self:ReportSelection()
    return count
end

--- Selects every row the filter and the collapsed set leave on screen. That is
--- what Ctrl and A mean in a tree, and it is also exactly the set an action
--- would be expected to touch.
function Tree:SelectAll()
    local selection, count = {}, 0
    for _, row in ipairs(self.RowList) do
        selection[row.ID] = true
        count = count + 1
    end
    self.SelectionSet, self.SelectionCount = selection, count
    if self.Focus == nil or selection[self.Focus] == nil then
        self.Focus = self.RowList[1] and self.RowList[1].ID or nil
    end
    self.Anchor = self.Focus ~= nil and self.RowByID[self.Focus] or nil
    self:Invalidate()
    self:ReportSelection()
    return count
end

function Tree:ClearSelection()
    if self.SelectionCount == 0 and self.Focus == nil then return 0 end
    self.SelectionSet, self.SelectionCount = {}, 0
    self.Focus, self.Anchor = nil, nil
    self:Invalidate()
    self:ReportSelection()
    return 0
end

--
--- ∑ Selects one row the way a click on it would, which is also how the
---   keyboard moves.
--- @param index number # A row index.
--- @param mode string|nil # replace, toggle or range.
--- @return nil
--
function Tree:SelectRow(index, mode)
    local row = self.RowList[index]
    if row == nil then return end
    mode = mode or "replace"
    if mode == "toggle" then
        if self.SelectionSet[row.ID] then
            self.SelectionSet[row.ID] = nil
            self.SelectionCount = self.SelectionCount - 1
        else
            self.SelectionSet[row.ID] = true
            self.SelectionCount = self.SelectionCount + 1
        end
        self.Anchor = index
    elseif mode == "range" then
        local from = self.Anchor or index
        local first, last = math.min(from, index), math.max(from, index)
        self.SelectionSet, self.SelectionCount = {}, 0
        for step = first, last do
            local candidate = self.RowList[step]
            if candidate ~= nil then
                self.SelectionSet[candidate.ID] = true
                self.SelectionCount = self.SelectionCount + 1
            end
        end
    else
        self.SelectionSet = { [row.ID] = true }
        self.SelectionCount = 1
        self.Anchor = index
    end
    self.Focus = row.ID
    self:Invalidate()
    self:ReportSelection()
end

--------------------------------------------------------
--                     Expanding                      --
--------------------------------------------------------

--- Opens or closes one record and rebuilds the rows.
function Tree:Toggle(id)
    local node = self.Snapshot and self.Snapshot.ByID[id]
    if node == nil or #node.Children == 0 then return false end
    if self.Collapsed[id] then
        self.Collapsed[id] = nil
    else
        self.Collapsed[id] = true
    end
    self:Rebuild()
    return true
end

--
--- ∑ Opens a record, and everything under it when asked.
--- @param id number
--- @param recursive boolean|nil
--- @return boolean # Whether anything moved.
--
function Tree:Expand(id, recursive)
    if self.Snapshot == nil then return false end
    local moved = self.Collapsed[id] ~= nil
    self.Collapsed[id] = nil
    if recursive then
        for _, child in ipairs(self.Records.Descendants(self.Snapshot, id)) do
            if self.Collapsed[child] ~= nil then moved = true end
            self.Collapsed[child] = nil
        end
    end
    if moved then self:Rebuild() end
    return moved
end

--- Closes a record, and everything under it when asked.
function Tree:Collapse(id, recursive)
    local snapshot = self.Snapshot
    if snapshot == nil then return false end
    local moved = false
    local node = snapshot.ByID[id]
    if node ~= nil and #node.Children > 0 and self.Collapsed[id] == nil then
        self.Collapsed[id] = true
        moved = true
    end
    if recursive then
        for _, child in ipairs(self.Records.Descendants(snapshot, id)) do
            local other = snapshot.ByID[child]
            if other ~= nil and #other.Children > 0 and self.Collapsed[child] == nil then
                self.Collapsed[child] = true
                moved = true
            end
        end
    end
    if moved then self:Rebuild() end
    return moved
end

function Tree:ExpandAll()
    if next(self.Collapsed) == nil then return false end
    self.Collapsed = {}
    self:Rebuild()
    return true
end

function Tree:CollapseAll()
    local snapshot = self.Snapshot
    if snapshot == nil then return false end
    local moved = false
    for _, node in ipairs(snapshot.Order) do
        if #node.Children > 0 and self.Collapsed[node.ID] == nil then
            self.Collapsed[node.ID] = true
            moved = true
        end
    end
    if moved then self:Rebuild() end
    return moved
end

--
--- ∑ Opens whatever has to be open for a record to be on a row, then brings
---   that row on screen.
--- @param id number
--- @return boolean # Whether the record has a row now.
--
function Tree:ScrollToID(id)
    local snapshot = self.Snapshot
    if snapshot == nil then return false end
    if self.RowByID[id] == nil then
        local node, guard, opened = snapshot.ByID[id], 0, false
        while node ~= nil and node.ParentID ~= nil and guard < MAX_DEPTH do
            if self.Collapsed[node.ParentID] ~= nil then
                self.Collapsed[node.ParentID] = nil
                opened = true
            end
            node = snapshot.ByID[node.ParentID]
            guard = guard + 1
        end
        if opened then self:Rebuild() end
    end
    local index = self.RowByID[id]
    if index == nil then return false end
    self:EnsureVisible(index)
    return true
end

--- Moves the scroll as little as it takes to put a row on screen.
function Tree:EnsureVisible(index)
    local surface = self.Surface
    if surface == nil then return end
    local visible = math.max(1, surface.Visible)
    if index < surface.Top then
        surface:ScrollTo(index)
    elseif index > surface.Top + visible - 1 then
        surface:ScrollTo(index - visible + 1)
    end
end

--------------------------------------------------------
--                       Layout                       --
--------------------------------------------------------

--
--- ∑ Where every column sits, worked out from the measured character width.
---
---   The columns on the right are given the widths section three point two asks
---   for, and they shrink and then drop when the card is too narrow to hold
---   them. A description cut down to nothing tells the person nothing at all,
---   so it is the one thing that never gives.
---
---   How many rows fit is worked out before anything else, because it decides
---   whether the scrollbar strip is kept free at all. A tree that fits runs its
---   rows and its value column to the right edge of the card.
--- @param width number
--- @param height number
--- @param metrics table
--- @return table
--
function Tree:Layout(width, height, metrics)
    local pad = SurfaceDefaults.PadX
    local rowHeight = metrics.RowHeight
    local visible = Scroll.Visible(height - rowHeight, rowHeight)
    local strip = Scroll.Strip(#self.RowList, visible)
    local listWidth = math.max(0, width - strip)

    local checkX = Defaults.Edge + pad
    local glyphX = checkX + SurfaceDefaults.CheckSize + pad
    local descriptionX = glyphX + SurfaceDefaults.ExpandSize + Defaults.Gap

    local function chars(count) return math.floor(count * metrics.CharWidth) end

    -- In the order they are drawn, left to right.
    local columns = {
        { Key = "Type", Want = chars(Defaults.TypeChars),
          Min = chars(Defaults.MinTypeChars), Show = true },
        { Key = "Address", Want = chars(Defaults.AddressChars),
          Min = chars(Defaults.MinAddressChars), Show = self.ShowAddresses },
        { Key = "Value", Want = chars(Defaults.ValueChars),
          Min = chars(Defaults.MinValueChars), Show = self.ShowValues }
    }
    -- And in the order they give way, each one shrinking and then going before
    -- the next is touched. The address goes first. It is the widest column, it
    -- rarely changes, and the inspector's Properties page shows it in full for
    -- the selected record anyway. The value is the last of the two optional
    -- columns to go, because a value is what a person keeps the window open to
    -- watch. The type tag is a few characters wide and outlasts both.
    local yielding = { columns[2], columns[3], columns[1] }
    local minimum = chars(Defaults.MinDescriptionChars)
    -- The gap is spent before the columns are, so a tree too narrow to hold
    -- everything drops a column rather than closing the gap the description
    -- needs to read as its own column.
    local function room()
        local spent = pad + Defaults.ColumnGap
        for _, column in ipairs(columns) do
            if column.Show then spent = spent + column.Want + pad end
        end
        return listWidth - descriptionX - spent
    end
    for _, column in ipairs(yielding) do
        if column.Show and room() < minimum then
            local give = math.min(minimum - room(), column.Want - column.Min)
            if give > 0 then column.Want = column.Want - give end
            if room() < minimum then column.Show = false end
        end
    end

    local right = listWidth - pad
    local boxes = {}
    for index = #columns, 1, -1 do
        local column = columns[index]
        if column.Show then
            boxes[column.Key] = { X = right - column.Want, W = column.Want }
            right = right - column.Want - pad
        end
    end

    return {
        Width = width, Height = height, ListWidth = listWidth, Strip = strip,
        RowHeight = rowHeight, HeaderHeight = rowHeight,
        CharWidth = metrics.CharWidth,
        Visible = visible,
        Top = 1,
        CheckX = checkX, CheckY = math.floor((rowHeight - SurfaceDefaults.CheckSize) / 2),
        GlyphX = glyphX, ExpandY = math.floor((rowHeight - SurfaceDefaults.ExpandSize) / 2),
        DescriptionX = descriptionX,
        DescriptionEnd = math.max(descriptionX, right - Defaults.ColumnGap),
        TextY = math.floor((rowHeight - metrics.TextHeight) / 2),
        Type = boxes.Type, Address = boxes.Address, Value = boxes.Value
    }
end

--------------------------------------------------------
--                      Painting                      --
--------------------------------------------------------

--
--- ∑ The colour a record's description draws in, corrected against the row it
---   sits on.
---
---   A table author picks a colour against Cheat Engine's own white list, so on
---   a dark palette half of them would be unreadable. Contrast lifts a colour
---   until it stands away from the background. The answers are cached, because
---   the correction is a short loop and a full window of rows would run it
---   forty times a frame for the same handful of colours.
--- @param node table
--- @param background number
--- @param colors table
--- @return number
--
function Tree:DescriptionColor(node, background, colors)
    if isDefaultColor(node.Color) then return colors.Text end
    if self.ColorsSeen ~= colors then
        self.ColorCache, self.ColorsSeen = {}, colors
    end
    local key = tostring(node.Color) .. "/" .. tostring(background)
    local cached = self.ColorCache[key]
    if cached ~= nil then return cached end
    local answer = node.Color
    local theme = self.Theme
    if theme ~= nil and type(theme.Contrast) == "function" then
        local ok, value = pcall(theme.Contrast, node.Color, background, CONTRAST)
        if ok and type(value) == "number" then answer = value end
    end
    self.ColorCache[key] = answer
    return answer
end

--- The two lines a tree with no rows shows in the middle of its canvas. An
--- empty canvas with nothing written on it reads as a broken window.
function Tree:EmptyState()
    if self.Snapshot == nil or self.Snapshot.Count == 0 then
        return "The address list is empty", "Records you add in Cheat Engine appear here."
    end
    if self.NeedsProblems then
        return "No problems found yet", "Press F7 to check the table."
    end
    return "No records match the filter", "Clear it with Esc."
end

--
--- ∑ Draws the whole tree. Only the rows on screen are touched, whatever the
---   table costs to hold.
--- @param canvas userdata
--- @param width number
--- @param height number
--- @param colors table
--- @param metrics table
--- @return nil
--
function Tree:Paint(canvas, width, height, colors, metrics)
    local surface = self.Surface
    local geometry = self:Layout(width, height, metrics)
    self.Geometry = geometry

    local rows = self.RowList
    surface:SetScroll(#rows, geometry.Visible)
    geometry.Top = surface.Top

    local font = surface:FontOf(canvas)
    local brush = surface:BrushOf(canvas)
    local empty = surface.EmptyStyle or ""

    -- The column titles, on the gutter tone, so the eye has something to read
    -- the columns against on a tree of records that are all one colour. The bar
    -- runs the full width and not only the list width, because the scrollbar
    -- starts below it and the corner between the two would otherwise be the one
    -- unpainted notch in the whole canvas.
    brush.Color = colors.Header
    canvas.fillRect(0, 0, geometry.Width, geometry.HeaderHeight)
    -- A hairline under the bar. The chrome tone is a quiet step away from the
    -- rows, so this is what separates the titles from the first record rather
    -- than a brighter fill would.
    brush.Color = colors.Rule
    canvas.fillRect(0, geometry.HeaderHeight - 1, geometry.Width, geometry.HeaderHeight)
    brush.Color = colors.Header
    -- The chrome tone is not a row tone either, and a muted title reads at
    -- three and a half to one on it under Dark-Aqua, so it is lifted too.
    font.Color = onRow(surface, colors.Muted, colors.Header, true)
    -- Every title sits where the thing it names sits. The description starts at
    -- the description column and not at the arrow in front of it, and the value
    -- is right aligned because the values under it are.
    canvas.textOut(geometry.DescriptionX, geometry.TextY, "Description")
    if geometry.Type then canvas.textOut(geometry.Type.X, geometry.TextY, "Type") end
    if geometry.Address then canvas.textOut(geometry.Address.X, geometry.TextY, "Address") end
    if geometry.Value then
        local measured = tonumber(canvas.getTextWidth("Value")) or 0
        canvas.textOut(geometry.Value.X + geometry.Value.W - measured, geometry.TextY, "Value")
    end

    if #rows == 0 then
        local title, hint = self:EmptyState()
        surface:DrawEmpty(canvas, width, height, colors, title, hint)
    else
        local last = math.min(#rows, surface.Top + geometry.Visible - 1)
        for index = surface.Top, last do
            self:PaintRow(canvas, rows[index], index, colors, geometry, font, brush, empty)
        end
    end
    -- Called when the tree fits as well. It draws nothing then, and it is what
    -- lets go of the thumb a longer tree left behind.
    surface:PaintScrollbar(canvas, width - SurfaceDefaults.ScrollWidth,
        geometry.HeaderHeight, height - geometry.HeaderHeight, colors)
end

--
--- ∑ Draws one row, left to right, in the order section three point two lists
---   the columns.
--- @return nil
--
function Tree:PaintRow(canvas, row, index, colors, geometry, font, brush, empty)
    local node = row.Node or {}
    local surface = self.Surface
    local rowHeight = geometry.RowHeight
    local top = geometry.HeaderHeight + (index - geometry.Top) * rowHeight
    local textY = top + geometry.TextY

    -- The stripe keys on the pre-order index rather than on the row number, so
    -- collapsing a group does not repaint every row below it in the other tone.
    local background = colors.Background
    -- Whether the row is a selected or hovered tone. Every muted and accent
    -- piece below is lifted against it then, the way DescriptionColor lifts a
    -- record's own colour on every row.
    local lifted = false
    if self.SelectionSet[row.ID] then
        background, lifted = colors.Selection, true
    elseif index == self.Hover then
        background, lifted = colors.Hover, true
    elseif ((tonumber(node.Index) or 0) % 2) == 1 then
        background = colors.Stripe
    end
    brush.Color = background
    canvas.fillRect(0, top, geometry.ListWidth, top + rowHeight)

    local severity = self.Problems and self.Problems[row.ID]
    if severity then
        brush.Color = severityColor(colors, severity)
        canvas.fillRect(0, top, Defaults.Edge, top + rowHeight)
    end

    -- Cheat Engine lets a group header be toggled as well, so every row has a
    -- box and not only the ones that carry a value.
    surface:DrawCheck(canvas, geometry.CheckX, top + geometry.CheckY, node.Active == true, colors)

    local indentX = geometry.GlyphX + (row.Depth or 0) * Defaults.Indent
    if row.HasChildren then
        surface:DrawExpand(canvas, indentX, top + geometry.ExpandY, row.Expanded, colors,
            lifted and background or nil)
    end

    local textX = indentX + SurfaceDefaults.ExpandSize + Defaults.Gap
    local room = geometry.DescriptionEnd - textX

    -- The badges are a note about the description. They are drawn right behind
    -- it and take their room from it, but only as long as the description
    -- keeps enough of itself to be read.
    local description = node.Description
    local named = type(description) == "string" and description ~= ""
    local reads = ""
    if named then
        reads = description
    elseif node.Loaded == true then
        reads = NO_DESCRIPTION
    end
    local badges, badgeWidth = fitBadges(canvas, badgeParts(node), reads, room, geometry.CharWidth)

    -- Every piece of text from here on sits on the row, and Cheat Engine's
    -- textOut fills the cell it writes into with the brush before the glyphs go
    -- down, so the brush goes back to the row tone after anything that moved it.
    brush.Color = background
    local written = 0
    if not named then
        -- Only once the record has really been read. A node the detail sweep
        -- has not reached yet has no description because nobody asked for one,
        -- and saying it has none would be a lie for one frame.
        local shown = ""
        if node.Loaded == true then
            shown = surface:TextFit(canvas, NO_DESCRIPTION, room - badgeWidth)
        end
        if shown ~= "" then
            font.Color = onRow(surface, colors.Muted, background, lifted)
            written = surface:DrawRuns(canvas, textX, textY, shown, nil, background)
        end
    else
        local shown = surface:TextFit(canvas, description, room - badgeWidth)
        if shown ~= "" then
            font.Color = self:DescriptionColor(node, background, colors)
            local bold = node.IsGroupHeader == true
            if bold then font.Style = "[fsBold]" end
            written = self:PaintDescription(canvas, shown, textX, top, textY,
                rowHeight, colors, brush, background)
            if bold then font.Style = empty end
        end
    end

    if badges ~= "" then
        brush.Color = background
        font.Color = onRow(surface, colors.Muted, background, lifted)
        canvas.textOut(textX + written + (written > 0 and Defaults.BadgeGap or 0),
            textY, badges)
    end

    brush.Color = background
    local box = geometry.Type
    if box ~= nil then
        local tag = self.Types.TagFor(node)
        if tag ~= "" then
            -- A script and a group are the two rows a person scans for, so they
            -- carry the accent and every other tag stays quiet.
            local accent = self.Types.IsScript(node) or node.IsGroupHeader == true
            font.Color = onRow(surface, accent and colors.Accent or colors.Muted,
                background, lifted)
            canvas.textOut(box.X, textY, surface:TextFit(canvas, tag, box.W))
        end
    end

    box = geometry.Address
    if box ~= nil then
        local address = node.AddressString
        if type(address) == "string" and address ~= "" then
            -- Cut out of the middle here and nowhere else. Every record in one
            -- module shares the module name, so keeping the head and dropping
            -- the offset would make four different records read the same.
            local shown = elideMiddle(canvas, address, box.W, geometry.CharWidth)
            if shown ~= "" then
                font.Color = onRow(surface, colors.Muted, background, lifted)
                canvas.textOut(box.X, textY, shown)
            end
        end
    end

    -- A group header has no value and a script's value is the script, so both
    -- are left out rather than shown as two question marks.
    box = geometry.Value
    if box ~= nil and node.IsGroupHeader ~= true and not self.Types.IsScript(node) then
        local value = self.Values[row.ID]
        local text = value and value.Text or nil
        if type(text) == "string" and text ~= "" then
            local shown = surface:TextFit(canvas, text, box.W)
            local measured = tonumber(canvas.getTextWidth(shown)) or 0
            font.Color = onRow(surface, (value.Readable == false) and colors.Muted or colors.Text,
                background, lifted)
            canvas.textOut(box.X + box.W - measured, textY, shown)
        end
    end

    if self.Focus == row.ID then
        brush.Color = colors.Focus
        canvas.fillRect(0, top, geometry.ListWidth, top + 1)
        canvas.fillRect(0, top + rowHeight - 1, geometry.ListWidth, top + rowHeight)
        canvas.fillRect(0, top, 1, top + rowHeight)
        canvas.fillRect(geometry.ListWidth - 1, top, geometry.ListWidth, top + rowHeight)
    end
end

--
--- ∑ Draws one description, with the filter's hits on the match tone and the
---   rest of it on the row.
---
---   Cheat Engine's textOut is opaque. It fills the cell it is about to write
---   into with the current brush before the glyphs go down, so a description
---   drawn in one call paints its whole width in one colour and a fill behind
---   it is gone the moment the text lands. The surface draws it in runs for
---   that reason, one brush per run, and the results strip does the same
---   through the same helper.
---
---   The band goes down first all the same, because the text cell is a few
---   pixels shorter than the row and the fill is what makes a hit read as a
---   highlight on the row rather than as a box around the letters.
--- @param canvas userdata
--- @param shown string # The description as it will be drawn, already cut.
--- @param textX number
--- @param top number # The top of the row.
--- @param textY number # Where the text sits, already absolute.
--- @param rowHeight number
--- @param colors table
--- @param brush userdata
--- @param background number # The tone the row was painted in.
--- @return number # How wide it came out, so the badges know where to start.
--
function Tree:PaintDescription(canvas, shown, textX, top, textY, rowHeight, colors, brush, background)
    local surface = self.Surface
    local spans = nil
    if self.Query ~= nil then spans = mergeSpans(spansOf(shown, self.Query.Text)) end

    if spans ~= nil then
        brush.Color = colors.Match
        for _, span in ipairs(spans) do
            local before = tonumber(canvas.getTextWidth(shown:sub(1, span[1] - 1))) or 0
            local hit = tonumber(canvas.getTextWidth(shown:sub(span[1], span[2]))) or 0
            if hit > 0 then
                canvas.fillRect(textX + before, top + 1,
                    textX + before + hit, top + rowHeight - 1)
            end
        end
    end

    local width = surface:DrawRuns(canvas, textX, textY, shown, spans,
        background, colors.Match)
    brush.Color = background
    return width
end

--------------------------------------------------------
--                     The mouse                      --
--------------------------------------------------------

--
--- ∑ The row under a point and which part of it was hit.
--- @param x number|nil
--- @param y number|nil
--- @return table|nil, string|nil, number|nil # The row, the part and the index.
--
function Tree:HitTest(x, y)
    local geometry = self.Geometry
    if geometry == nil or type(y) ~= "number" then return nil end
    if type(x) == "number" and x >= geometry.ListWidth then return nil end
    if y < geometry.HeaderHeight then return nil end
    local index = Scroll.RowAt(y - geometry.HeaderHeight, geometry.Top,
        geometry.RowHeight, #self.RowList)
    if index == nil then return nil end
    local row = self.RowList[index]
    if row == nil then return nil end
    if type(x) ~= "number" then return row, nil, index end
    if x >= geometry.CheckX and x <= geometry.CheckX + SurfaceDefaults.CheckSize then
        return row, "check", index
    end
    local indentX = geometry.GlyphX + (row.Depth or 0) * Defaults.Indent
    if row.HasChildren and x >= indentX and x <= indentX + SurfaceDefaults.ExpandSize then
        return row, "expand", index
    end
    return row, "text", index
end

--- The row at a vertical position, whatever the horizontal one is.
function Tree:RowAt(y)
    local row = self:HitTest(nil, y)
    return row
end

--
--- ∑ A click. The box toggles activation, the arrow toggles the branch and
---   everything else moves the selection.
--- @param button number # Zero is left and one is right, always an integer.
--- @param x number
--- @param y number
--- @return nil
--
function Tree:MouseDown(button, x, y)
    local row, part, index = self:HitTest(x, y)

    if button == 1 then
        -- The menu opens over what the person pointed at, so an unselected row
        -- is selected first and a selected one leaves a multiple selection
        -- alone.
        if row ~= nil and not self.SelectionSet[row.ID] then
            self:SelectRow(index, "replace")
        end
        fire(self.OnContext, row and row.ID or nil)
        return
    end
    if button ~= 0 and button ~= nil then return end

    if row == nil then
        self:ClearSelection()
        return
    end
    if part == "check" then
        fire(self.OnToggleActive, { row.ID })
        return
    end
    if part == "expand" then
        self:Toggle(row.ID)
        return
    end
    local control, shift = pressed(self, VK_CONTROL), pressed(self, VK_SHIFT)
    self:SelectRow(index, shift and "range" or (control and "toggle") or "replace")
end

function Tree:MouseMove(x, y)
    local _, _, index = self:HitTest(x, y)
    if index ~= self.Hover then
        self.Hover = index
        self:Invalidate()
    end
end

function Tree:MouseLeave()
    if self.Hover ~= nil then
        self.Hover = nil
        self:Invalidate()
    end
end

--- A double click opens the record, which is what the inspector's own pages
--- treat as the request to edit it. A double click on the box or the arrow is
--- two toggles and nothing more.
function Tree:DoubleClick(x, y)
    local row, part = self:HitTest(x, y)
    if row == nil or part == "check" or part == "expand" then return end
    fire(self.OnOpen, row.ID)
end

--------------------------------------------------------
--                    The keyboard                    --
--------------------------------------------------------

--- The row the keyboard moves from, or nothing when the focus has no row.
function Tree:FocusRow()
    if self.Focus == nil then return nil end
    return self.RowByID[self.Focus]
end

--- Moves the focus to a row that exists and takes the selection with it.
function Tree:MoveFocus(index, extend)
    local count = #self.RowList
    if count == 0 then return false end
    index = math.max(1, math.min(count, math.floor(index)))
    self:SelectRow(index, extend and "range" or "replace")
    self:EnsureVisible(index)
    return true
end

--
--- ∑ The keys the tree answers. A canvas never takes focus, so the window
---   feeds them in from its own key handler.
--- @param key number # A virtual key code.
--- @return boolean # Whether the key was used.
--
function Tree:HandleKey(key)
    local control, shift = pressed(self, VK_CONTROL), pressed(self, VK_SHIFT)
    if key == VK_A and control then
        self:SelectAll()
        return true
    end
    local rows = self.RowList
    if #rows == 0 then return false end
    local surface = self.Surface
    local page = math.max(1, (surface and surface.Visible or 1) - 1)
    local index = self:FocusRow() or 0

    if key == VK_UP then return self:MoveFocus(index - 1, shift) end
    if key == VK_DOWN then return self:MoveFocus(index + 1, shift) end
    if key == VK_PRIOR then return self:MoveFocus(index - page, shift) end
    if key == VK_NEXT then return self:MoveFocus(index + page, shift) end
    if key == VK_HOME then return self:MoveFocus(1, shift) end
    if key == VK_END then return self:MoveFocus(#rows, shift) end

    local row = rows[index]
    if key == VK_LEFT then
        if row == nil then return false end
        if row.HasChildren and row.Expanded then
            self:Collapse(row.ID)
            return true
        end
        local parent = row.Node and row.Node.ParentID or nil
        if parent ~= nil and self.RowByID[parent] ~= nil then
            return self:MoveFocus(self.RowByID[parent], false)
        end
        return true
    end
    if key == VK_RIGHT then
        if row == nil then return false end
        if not row.HasChildren then return true end
        if not row.Expanded then
            self:Expand(row.ID)
            return true
        end
        local first = row.Node and row.Node.Children[1] or nil
        if first ~= nil and self.RowByID[first] ~= nil then
            return self:MoveFocus(self.RowByID[first], false)
        end
        return true
    end
    if key == VK_SPACE then
        local ids = self:Selection()
        if #ids > 0 then fire(self.OnToggleActive, ids) end
        return true
    end
    if key == VK_RETURN then
        if self.Focus ~= nil then fire(self.OnOpen, self.Focus) end
        return true
    end
    if key == VK_MULTIPLY then
        if self.Focus ~= nil then self:Expand(self.Focus, true) end
        return true
    end
    return false
end

--------------------------------------------------------
--                      Teardown                      --
--------------------------------------------------------

--- Releases the canvas and leaves the frame service. The panel it was drawn on
--- belongs to the window and is freed with it.
function Tree:Destroy()
    if self.Surface ~= nil then
        self.Surface:Destroy()
        self.Surface = nil
    end
    self.Parent, self.Geometry = nil, nil
    self.RowList, self.RowByID = {}, {}
    self.Snapshot, self.Values, self.Problems = nil, {}, nil
    self.ColorCache, self.ColorsSeen = {}, nil
end

return Tree
