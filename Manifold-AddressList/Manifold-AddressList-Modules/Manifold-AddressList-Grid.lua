--[[
    The property grid, which is the body of the inspector.

    It is a canvas like everything else in this window. Cheat Engine has no
    scroll box and no owner drawn grid, and a row where a label, a check box, a
    colour swatch and a warning mark share one line has to be painted by hand.
    The rows come from the Properties schema, so this file knows what a row
    looks like and nothing at all about memory records.

    The hard part is editing in place, and live sync is the reason. The window
    rebuilds the rows four times a second, so a grid that rebuilt itself from
    nothing would throw away half typed text several times a second. SetRows
    while an editor is open therefore keeps the editor, leaves the edited row's
    text exactly as it was and only re-lays the rows around it. A commit
    happens on Enter, on Tab, on a click on another row and on an explicit
    save, and never from SetRows.

    There is one themed edit and one themed combo box for the whole grid. Both
    are made once at Attach as children of the windowed panel the canvas sits
    in, and they are moved over the value cell of the row being edited. A
    windowed control always paints above a graphic control beside it, so the
    frame timer never paints over an open editor, and a control that is not
    aligned does not shrink the alClient canvas underneath it. One editor per
    row would spend a window handle per edit and leak a control per row.

    Losing focus commits a normal row and cancels a dangerous one. A canvas
    never takes focus, so the Window clears the form's ActiveControl when a
    canvas is clicked and that is how the editor hears about it. The same
    thought is why a click on another row commits before it moves the focus.

    Everything else is the shared surface. Scrolling, the drawn scrollbar, the
    wheel, the check box and the arrow all live there, and the grid only says
    what a row looks like and what a click on one means.

    One Cheat Engine fact shapes the painting. textOut is opaque. It fills the
    cell it writes into with the current brush before the glyphs go down, so a
    check box or a colour swatch leaves its own colour behind and the next piece
    of text on that row would be painted on it. The brush goes back to the row
    tone before every piece of text for that reason.
]]

local Properties = require("Manifold-AddressList-Properties")

local Grid = {}
Grid.__index = Grid

--- What a value the selected records do not agree on reads as. Properties owns
--- the sentinel, so the text comes from there rather than from a second copy
--- that could drift away from it.
Grid.MixedText = tostring(Properties.MIXED)

--
--- ∑ The numbers the layout is built from. Everything else is measured off the
---   font, so a larger font moves the rows without a second table of sizes.
--
Grid.Defaults = {
    --- The most of the row the label column is ever allowed to take. It only
    --- bites on a grid whose labels are longer than half the panel, because the
    --- column is normally sized for the labels it actually holds.
    LabelShare = 0.52,
    --- How wide the label column is when the labels do not need that much. The
    --- inspector is a side panel and not a window of its own, and two fifths of
    --- it cut labels such as Hide children while inactive in half while the
    --- value beside them was a check box and an empty half column. Two hundred
    --- pixels is the longest label the Properties schema has.
    LabelMin = 200,
    --- What is left for a value once the label has had its share. A window
    --- narrow enough to reach this is narrower than the smallest window we
    --- allow, so this only matters while one is being dragged.
    ValueMin = 60,
    --- The colour swatch, fourteen by twelve, drawn before the hex text.
    SwatchWidth = 14,
    SwatchHeight = 12,
    --- The gap at the edge and between the two columns. The same six pixels
    --- the surface pads its own columns with.
    Pad = 6,
    --- The drawn scrollbar. The surface owns the real width and this is only
    --- the fallback for a grid built without one.
    ScrollWidth = 12,
    --- The drawn check box and the drawn arrow, both from the surface.
    CheckSize = 11,
    ExpandSize = 9,
    --- The mark on a row that runs a script or writes process memory. ASCII,
    --- because a canvas draws what the font has and nothing more.
    DangerMark = "!",
    --- How wide the editor is allowed to get, in case a value column ends up
    --- absurd while a splitter is being dragged.
    MinEditorWidth = 24
}

--
--- ∑ The virtual keys the grid answers, by name, so the handler reads as what
---   it does rather than as a list of numbers.
--
Grid.Keys = {
    Tab = 9, Enter = 13, Escape = 27, Space = 32,
    PageUp = 33, PageDown = 34, End = 35, Home = 36,
    Left = 37, Up = 38, Right = 39, Down = 40, F2 = 113
}

local Defaults = Grid.Defaults
local Keys = Grid.Keys

--------------------------------------------------------
--                  Guarded touches                   --
--------------------------------------------------------

--- One guarded property write. A control that was freed and a property this
--- build does not have both come back as false instead of as a raise.
local function safeSet(control, property, value)
    if control == nil then return false end
    return (pcall(function() control[property] = value end))
end

--- One guarded property read, nil when the read did not work.
local function safeGet(control, property)
    if control == nil then return nil end
    local ok, value = pcall(function() return control[property] end)
    if ok then return value end
    return nil
end

--- One log line, or nothing at all when this segment runs without a log.
local function say(self, level, message)
    local log = self.Log
    if not log or type(log[level]) ~= "function" then return end
    pcall(log[level], log, message)
end

--- Calls one of the owner's hooks. A defect in an owner's hook degrades to a
--- row that did nothing rather than to a broken frame.
local function fire(hook, ...)
    if type(hook) ~= "function" then return false end
    return (pcall(hook, ...))
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the grid. Nothing is created until Attach, because a page builds
---   its grid long before it has a panel to put one on.
--- @param services table|nil # Theme, Surface as the class, Log, Settings,
---        Frame and an optional Name for the log lines.
--- @return table
--
function Grid:New(services)
    services = services or {}
    local class = services.Surface
    local sizes = (class and class.Defaults) or {}
    return setmetatable({
        Theme        = services.Theme,
        SurfaceClass = class,
        Log          = services.Log,
        Settings     = services.Settings,
        Frame        = services.Frame,
        Name         = services.Name or "Grid",

        --- The scroll arithmetic, taken from the surface so there is one copy
        --- of it and not two that disagree about the last row.
        Math    = class and class.Scroll or nil,

        Surface = nil,
        Parent  = nil,
        Ready   = false,
        Reason  = nil,

        --- The rows as they were handed over, and the ones a collapsed
        --- category leaves on screen. The painter and every hit test read the
        --- second, everything a page asks about reads the first.
        RowsAll   = {},
        RowsShown = {},
        Collapsed = {},          -- category key to true or false
        --- The longest property label in hand, in characters. The label column
        --- is sized for it, so it never takes room the labels do not need.
        WidestLabel = 0,

        FocusedKey = nil,
        HoverIndex = nil,
        HoverKey   = nil,
        Geometry   = nil,        -- filled on every paint, read by hit tests
        Empty      = { Title = "No properties to show", Hint = "Select a record in the list." },

        --- The two in place editors and the state of the one that is open.
        Editor  = nil,           -- the themed edit
        Combo   = nil,           -- the themed combo box
        Edit    = nil,           -- Key, Row, Editor, Danger, Control, Start, Choices
        Loading = false,         -- true while values are put into a control
        Suppress = false,        -- true while the grid itself hides an editor
        EditorShown = false,

        OnCommit = nil,          -- (key, value)
        OnPick   = nil,          -- (key)
        OnHover  = nil           -- (row or nil)
    }, Grid)
end

--
--- ∑ Creates the canvas and the two editors inside a windowed panel.
---
---   The editors are children of the panel and not of the canvas, because a
---   paint box is a graphic control and can hold no child at all. They are
---   made once here and moved about afterwards.
--- @param parent userdata
--- @return boolean, string|nil
--
function Grid:Attach(parent)
    self.Parent = parent
    local class = self.SurfaceClass
    if class == nil then
        self.Reason = "the grid was built without the Surface class"
        return false, self.Reason
    end
    local surface = class:New({
        Theme = self.Theme, Log = self.Log, Settings = self.Settings,
        Frame = self.Frame, Name = self.Name
    })
    local ok, reason = surface:Attach(parent)
    if not ok then
        self.Reason = reason
        return false, reason
    end
    self.Surface = surface
    surface:SetPainter(function(_, canvas, width, height, colors, metrics)
        self:Paint(canvas, width, height, colors, metrics)
    end)
    surface.OnMouseDown = function(button, x, y) self:MouseDown(button, x, y) end
    surface.OnMouseMove = function(x, y) self:MouseMove(x, y) end
    surface.OnMouseLeave = function() self:MouseLeave() end
    surface.OnDoubleClick = function(x, y) self:DoubleClick(x, y) end
    self:CreateEditors(parent)
    self.Ready = true
    return true
end

--
--- ∑ Makes the one edit and the one combo box the whole grid shares.
---
---   A theme that cannot build them leaves the grid readable and not editable,
---   which is the right way round. The handlers go on afterwards, because
---   writing Text into an edit fires its OnChange and a handler wired first
---   would run before there is any state for it to read.
--- @param parent userdata
--- @return boolean # Whether both editors exist.
--
function Grid:CreateEditors(parent)
    local theme = self.Theme
    if theme == nil then
        self.Reason = "this window has no theme, so the grid shows values without editing them"
        return false
    end
    if type(theme.CreateEdit) == "function" then
        local ok, control = pcall(theme.CreateEdit, theme, parent, { Width = 160, Height = 20 })
        if ok then self.Editor = control end
    end
    if type(theme.CreateCombo) == "function" then
        local ok, control = pcall(theme.CreateCombo, theme, parent, { Width = 160 })
        if ok then self.Combo = control end
    end
    -- Each one on its own. A list of the two would stop at the first nil and
    -- the second control would go without its handlers on a build that has
    -- only one of the two constructors.
    local function wire(control)
        if control == nil then return end
        safeSet(control, "Visible", false)
        safeSet(control, "TabStop", true)
        safeSet(control, "OnKeyDown", function(_, key) return self:EditorKey(key) end)
        safeSet(control, "OnExit", function() self:FocusLost() end)
    end
    wire(self.Editor)
    wire(self.Combo)
    -- The combo commits on the user's own change, so its handler goes on last
    -- and reads the loading flag, because filling the list is not a change a
    -- person made.
    safeSet(self.Combo, "OnChange", function() self:ComboChanged() end)
    if self.Editor == nil or self.Combo == nil then
        say(self, "Warning", "The grid could not build both in place editors, "
            .. "so some rows are shown without one.")
        return false
    end
    return true
end

--- Asks for a frame. The frame service paints it a few milliseconds later.
function Grid:Invalidate()
    if self.Surface then self.Surface:Invalidate() end
end

--------------------------------------------------------
--                      The rows                      --
--------------------------------------------------------

--- The category a row belongs to, which is the nearest category above it.
local function categoryOf(self, key)
    local current = nil
    for _, row in ipairs(self.RowsAll) do
        if row.Kind == "category" then current = row end
        if row.Key == key then return current end
    end
    return nil
end

--- Rebuilds the drawn rows from the whole set and the collapsed categories,
--- then makes sure the focus still stands on a row somebody can see.
local function rebuild(self)
    local shown, hidden = {}, false
    for _, row in ipairs(self.RowsAll) do
        if row.Kind == "category" then
            hidden = row.Collapsed == true
            shown[#shown + 1] = row
        elseif not hidden then
            shown[#shown + 1] = row
        end
    end
    self.RowsShown = shown
    if self.FocusedKey ~= nil and self:IndexOf(self.FocusedKey) == nil then
        -- The row went with the selection or into a collapsed category. Focus
        -- on a row nobody can see would move the wrong one with the arrow
        -- keys, so it falls back to the category that holds it.
        local category = categoryOf(self, self.FocusedKey)
        self.FocusedKey = category and category.Key or nil
    end
    -- The hover is followed by key and not by position. A sync rebuilds the
    -- rows several times a second and the mouse does not move while somebody
    -- reads a row, so a hover kept by position would blink off under it.
    self.HoverIndex = self.HoverKey and self:IndexOf(self.HoverKey) or nil
    if self.HoverIndex == nil then self.HoverKey = nil end
    if self.Surface then self.Surface:SetScroll(#shown, self.Surface.Visible) end
end

--
--- ∑ Replaces the rows, keeping the scroll position, the focused row, the
---   collapsed categories and, above all, an open editor.
---
---   Live sync calls this several times a second. Committing from here would
---   write half typed text into a record, and rebuilding the row under the
---   editor would move the ground while somebody is standing on it. So the
---   edited row keeps the text it had when the editor opened and only the rows
---   around it are re-laid.
--- @param rows table|nil # Category and property rows in display order.
--- @return number # How many rows are drawn after collapsing.
--
function Grid:SetRows(rows)
    rows = rows or {}
    local edit = self.Edit
    local replacement = nil
    for _, row in ipairs(rows) do
        if row.Kind == "category" then
            -- The grid remembers which categories are shut, so a rebuild does
            -- not open every one of them again under the mouse.
            local remembered = self.Collapsed[row.Key]
            if remembered == nil then
                remembered = row.Collapsed == true
                self.Collapsed[row.Key] = remembered
            end
            row.Collapsed = remembered
        elseif edit ~= nil and row.Key == edit.Key then
            replacement = row
            row.Text = edit.Row.Text
            row.Value = edit.Row.Value
            row.Mixed = edit.Row.Mixed
        end
    end
    self.RowsAll = rows
    -- Measured here rather than on every frame, and over every row rather than
    -- the drawn ones, so shutting a category does not move the value column.
    local widest = 0
    for _, row in ipairs(rows) do
        if row.Kind ~= "category" then
            local length = #tostring(row.Label or row.Key or "")
            if length > widest then widest = length end
        end
    end
    self.WidestLabel = widest
    rebuild(self)
    if edit ~= nil then
        if replacement == nil then
            -- The property is no longer in the selection, so there is nothing
            -- left to write to. Cancelling loses the typing, committing would
            -- write it into a record the user is no longer looking at.
            self:CancelEdit()
        else
            edit.Row = replacement
        end
    end
    self:PlaceEditor()
    self:Invalidate()
    return #self.RowsShown
end

--- Every row as it was handed over, collapsed categories included.
function Grid:Rows()
    return self.RowsAll
end

--- The rows that are drawn, which is the set the arrow keys and the mouse move
--- through.
function Grid:Shown()
    return self.RowsShown
end

function Grid:Count()
    return #self.RowsShown
end

--- One row by key, whether it is drawn or inside a collapsed category.
function Grid:RowByKey(key)
    if key == nil then return nil end
    for _, row in ipairs(self.RowsAll) do
        if row.Key == key then return row end
    end
    return nil
end

--- Where a key sits among the drawn rows, which is what the painter and the
--- editor both measure from.
function Grid:IndexOf(key)
    if key == nil then return nil end
    for index, row in ipairs(self.RowsShown) do
        if row.Key == key then return index end
    end
    return nil
end

--- The two line message shown when there is nothing to list. An empty canvas
--- with no words on it reads as a broken window.
function Grid:SetEmpty(title, hint)
    self.Empty = { Title = title, Hint = hint }
    self:Invalidate()
end

--------------------------------------------------------
--                     Categories                     --
--------------------------------------------------------

--
--- ∑ Opens or shuts one category and remembers which it is.
--- @param key string
--- @param collapsed boolean|nil # Nothing means the other way round.
--- @return boolean # Whether anything moved.
--
function Grid:ToggleCategory(key, collapsed)
    local row = self:RowByKey(key)
    if row == nil or row.Kind ~= "category" then return false end
    if collapsed == nil then collapsed = not (row.Collapsed == true) end
    if row.Collapsed == collapsed then return false end
    row.Collapsed = collapsed
    self.Collapsed[key] = collapsed
    rebuild(self)
    -- An editor inside a category that just shut has no row under it any more.
    if self:IsEditing() and self:IndexOf(self.Edit.Key) == nil then self:CancelEdit() end
    self:PlaceEditor()
    self:Invalidate()
    return true
end

--- Which categories are shut, as a fresh table, so a page can put them back
--- after it rebuilt the grid from a different selection.
function Grid:CollapsedKeys()
    local out = {}
    for key, value in pairs(self.Collapsed) do out[key] = value end
    return out
end

--- Puts a remembered set of shut categories back.
function Grid:SetCollapsed(set)
    self.Collapsed = {}
    for key, value in pairs(set or {}) do self.Collapsed[key] = value == true end
    for _, row in ipairs(self.RowsAll) do
        if row.Kind == "category" then
            local remembered = self.Collapsed[row.Key]
            if remembered == nil then
                remembered = row.Collapsed == true
                self.Collapsed[row.Key] = remembered
            end
            row.Collapsed = remembered
        end
    end
    rebuild(self)
    self:Invalidate()
end

--------------------------------------------------------
--                       Focus                        --
--------------------------------------------------------

function Grid:Focused()
    return self.FocusedKey
end

function Grid:FocusedRow()
    return self:RowByKey(self.FocusedKey)
end

function Grid:FocusedIndex()
    return self:IndexOf(self.FocusedKey)
end

--
--- ∑ Moves the focus to one key and brings it on screen.
---
---   A key inside a shut category opens that category first, because F2 on the
---   description has to work whether or not Identity happens to be open.
--- @param key string|nil
--- @return boolean # Whether the focus moved there.
--
function Grid:FocusKey(key)
    if key == nil then
        self.FocusedKey = nil
        self:Invalidate()
        return false
    end
    if self:IndexOf(key) == nil and self:RowByKey(key) ~= nil then
        local category = categoryOf(self, key)
        if category then self:ToggleCategory(category.Key, false) end
    end
    local index = self:IndexOf(key)
    if index == nil then return false end
    self.FocusedKey = key
    self:EnsureVisible(index)
    self:Invalidate()
    return true
end

--- Focus by drawn position, which is what a click and the arrow keys use.
function Grid:FocusIndex(index)
    local row = self.RowsShown[index]
    if row == nil then return false end
    self.FocusedKey = row.Key
    self:EnsureVisible(index)
    self:Invalidate()
    return true
end

--- Brings a row on screen without moving it further than it has to.
function Grid:EnsureVisible(index)
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
--- ∑ Where the two columns sit, worked out from the measured character width.
---
---   The label column is as wide as the labels it is holding and no wider, with
---   a floor so the value column stays in the same place while a selection
---   changes the rows, and a ceiling so a grid of very long labels cannot eat
---   the whole panel. A share of the row on its own was the wrong rule. It made
---   the column too narrow to read in a side panel and far too wide in a broad
---   one, and the value column paid for both.
---
---   The scrollbar strip is kept free only while the rows do not fit, the way
---   the tree and every list do. A grid that kept it for good ended its rows
---   twelve pixels short of the fields and buttons on every other page. How
---   many rows fit is worked out first and the strip after it, from the rows
---   about to be painted, so the frame a category opens past the bottom in is
---   already laid out for the bar it draws. The strip takes width and never
---   height, so it cannot change how many rows fit, and the answer cannot flip
---   between two frames.
---
---   The label column is measured against the width without the strip whether
---   the strip is there or not. Opening a category that makes the grid scroll
---   moves the right end of the values and nothing else, so the labels and the
---   left edge of every value stay where the eye left them.
--- @param width number
--- @param height number
--- @param metrics table
--- @return table
--
function Grid:Layout(width, height, metrics)
    local pad = Defaults.Pad
    local rowHeight = metrics.RowHeight
    local scroll = self.Math
    local visible
    if scroll ~= nil and type(scroll.Visible) == "function" then
        visible = scroll.Visible(height, rowHeight)
    else
        visible = math.max(1, math.floor((tonumber(height) or 0) / math.max(1, rowHeight or 1)))
    end
    local bar = (self.SurfaceClass and self.SurfaceClass.Defaults
        and self.SurfaceClass.Defaults.ScrollWidth) or Defaults.ScrollWidth
    local strip
    if scroll ~= nil and type(scroll.Strip) == "function" then
        strip = scroll.Strip(#self.RowsShown, visible)
    else
        strip = #self.RowsShown > visible and bar or 0
    end
    local listWidth = math.max(0, width - strip)
    local steady = math.max(0, width - bar)
    local room = math.max(0, steady - pad - pad - Defaults.ValueMin)
    local charWidth = metrics.CharWidth or 7
    local wanted = math.floor((self.WidestLabel or 0) * charWidth) + pad
    local ceiling = math.max(Defaults.LabelMin, math.floor(steady * Defaults.LabelShare))
    local labelWidth = math.max(Defaults.LabelMin, math.min(ceiling, wanted))
    labelWidth = math.min(labelWidth, room)
    local labelX = pad
    local valueX = labelX + labelWidth + pad
    local dangerWidth = math.floor(charWidth + 0.5) + pad
    return {
        Width = width, ListWidth = listWidth, ScrollWidth = bar, Strip = strip,
        LabelX = labelX, LabelWidth = labelWidth,
        ValueX = valueX, ValueWidth = math.max(0, listWidth - valueX - pad),
        DangerWidth = dangerWidth,
        -- How far the mixed marker of a boolean row reaches, so the hit test
        -- can cover the whole of it without a canvas to measure it with.
        MixedWidth = math.floor(#Grid.MixedText * charWidth),
        RowHeight = rowHeight, TextHeight = metrics.TextHeight,
        Top = 1, Visible = visible
    }
end

--------------------------------------------------------
--                      Painting                      --
--------------------------------------------------------

--
--- ∑ The colour a swatch may be drawn in, or nothing when the row has no
---   colour of its own to show.
---
---   Cheat Engine's default record colour is clWindowText, which is a system
---   colour index with its top bit set and not a blue green red triple. It is a
---   number all the same, so a swatch drawn in it comes out black and tells the
---   person the record was coloured black when nobody ever coloured it. A
---   record without a colour gets no swatch, and no system colour index ever
---   reaches the canvas.
--- @param value any
--- @return number|nil
--
local function swatchColor(value)
    if type(value) ~= "number" then return nil end
    if value < 0 or value > 0xFFFFFF then return nil end
    local default = rawget(_G, "clWindowText")
    if type(default) == "number" and value == default then return nil end
    return math.floor(value)
end

--- The colour a swatch is drawn with, and its little border, so a dark record
--- colour on a dark row still reads as a square.
local function drawSwatch(self, canvas, x, y, color, colors)
    local brush = self.Surface:BrushOf(canvas)
    brush.Color = colors.CheckBorder or colors.Muted
    canvas.fillRect(x, y, x + Defaults.SwatchWidth, y + Defaults.SwatchHeight)
    brush.Color = color
    canvas.fillRect(x + 1, y + 1, x + Defaults.SwatchWidth - 1, y + Defaults.SwatchHeight - 1)
end

--- One row's background, in the order a person expects to see it, and
--- whether that is the focused or the hovered tone.
local function backgroundOf(self, row, index, colors)
    if row.Key == self.FocusedKey then return colors.Selection, true end
    if index == self.HoverIndex then return colors.Hover, true end
    if index % 2 == 0 then return colors.Stripe, false end
    return colors.Background, false
end

--- A colour as it is drawn on one row. The focused and the hovered tone are
--- not what the muted, warning and accent colours were picked for, and a
--- muted label on a hovered row read at three to one under Dark-Aqua, so on
--- those the surface lifts them against the tone. The category bar is always
--- lifted, because it is chrome and never a plain row.
local function onRow(self, color, background, lifted)
    local surface = self.Surface
    if lifted and surface ~= nil and type(surface.Legible) == "function" then
        return surface:Legible(color, background)
    end
    return color
end

--
--- ∑ Paints the whole grid. Only the rows on screen are touched, however long
---   the schema is.
--- @param canvas userdata
--- @param width number
--- @param height number
--- @param colors table
--- @param metrics table
--- @return nil
--
function Grid:Paint(canvas, width, height, colors, metrics)
    local surface = self.Surface
    local geometry = self:Layout(width, height, metrics)
    local rowHeight = geometry.RowHeight
    local visible = geometry.Visible
    surface:SetScroll(#self.RowsShown, visible)
    geometry.Top = surface.Top
    self.Geometry = geometry

    local font = surface:FontOf(canvas)
    local brush = surface:BrushOf(canvas)
    local empty = surface.EmptyStyle or ""
    local textY = math.floor((rowHeight - metrics.TextHeight) / 2)

    if #self.RowsShown == 0 then
        local message = self.Empty
        if message then
            surface:DrawEmpty(canvas, width, height, colors, message.Title, message.Hint)
        end
        surface:PaintScrollbar(canvas, width - geometry.ScrollWidth, 0, height, colors)
        self:PlaceEditor()
        return
    end

    local last = math.min(#self.RowsShown, surface.Top + visible - 1)
    for index = surface.Top, last do
        local row = self.RowsShown[index]
        local top = (index - surface.Top) * rowHeight
        if row.Kind == "category" then
            brush.Color = colors.Header
            canvas.fillRect(0, top, geometry.ListWidth, top + rowHeight)
            surface:DrawExpand(canvas, Defaults.Pad,
                top + math.floor((rowHeight - Defaults.ExpandSize) / 2),
                not (row.Collapsed == true), colors, colors.Header)
            font.Style = "[fsBold]"
            font.Color = onRow(self, colors.Accent, colors.Header, true)
            local x = Defaults.Pad + Defaults.ExpandSize + Defaults.Pad
            canvas.textOut(x, top + textY,
                surface:TextFit(canvas, row.Label or row.Key, geometry.ListWidth - x))
            font.Style = empty
        else
            local background, lifted = backgroundOf(self, row, index, colors)
            brush.Color = background
            canvas.fillRect(0, top, geometry.ListWidth, top + rowHeight)
            font.Color = onRow(self, colors.Muted, background, lifted)
            canvas.textOut(geometry.LabelX, top + textY,
                surface:TextFit(canvas, row.Label or row.Key, geometry.LabelWidth))
            self:PaintValue(canvas, row, geometry, top, textY, colors, font, brush,
                background, lifted)
        end
    end

    surface:PaintScrollbar(canvas, width - geometry.ScrollWidth, 0, height, colors)
    self:PlaceEditor()
end

--
--- ∑ The value half of one property row.
---
---   The cell of the row being edited is left blank, because the editor is a
---   windowed control sitting over it and painting underneath it would only
---   show through while the editor is being moved.
---
---   Cheat Engine's textOut fills its cell with the brush before the glyphs go
---   down, so the brush goes back to the row tone after the check box and after
---   the swatch, both of which leave their own colour on it.
---
---   On the focused and the hovered row every colour is lifted against the
---   row tone, which the painter says with lifted.
--- @return nil
--
function Grid:PaintValue(canvas, row, geometry, top, textY, colors, font, brush, background, lifted)
    local surface = self.Surface
    if self.Edit ~= nil and self.Edit.Key == row.Key and self.EditorShown then return end
    local x = geometry.ValueX
    local room = geometry.ValueWidth
    if row.Danger then room = math.max(0, room - geometry.DangerWidth) end

    if row.Editor == "bool" then
        if row.Mixed then
            -- A box shows one state and the records do not share one, so the
            -- marker stands on its own and starts where every other mixed
            -- marker in the grid starts. A box in front of it would both lie
            -- about the value and put this one row out of line with the rest.
            brush.Color = background
            font.Color = onRow(self, colors.Muted, background, lifted)
            canvas.textOut(x, top + textY, surface:TextFit(canvas, Grid.MixedText, room))
        else
            surface:DrawCheck(canvas, x,
                top + math.floor((geometry.RowHeight - Defaults.CheckSize) / 2),
                row.Checked == true, colors)
        end
    else
        local swatch = swatchColor(row.Swatch)
        if row.Editor == "color" and swatch ~= nil then
            drawSwatch(self, canvas, x,
                top + math.floor((geometry.RowHeight - Defaults.SwatchHeight) / 2),
                swatch, colors)
            x = x + Defaults.SwatchWidth + Defaults.Pad
            room = math.max(0, room - Defaults.SwatchWidth - Defaults.Pad)
        end
        local text = row.Text
        if row.Mixed then text = Grid.MixedText end
        if text ~= nil and text ~= "" and room > 0 then
            brush.Color = background
            font.Color = onRow(self, (row.Mixed or row.ReadOnly) and colors.Muted or colors.Text,
                background, lifted)
            canvas.textOut(x, top + textY, surface:TextFit(canvas, tostring(text), room))
        end
    end

    if row.Danger then
        brush.Color = background
        font.Color = onRow(self, colors.Warning, background, lifted)
        local mark = Defaults.DangerMark
        local markWidth = tonumber(canvas.getTextWidth(mark)) or 0
        canvas.textOut(geometry.ListWidth - Defaults.Pad - markWidth, top + textY, mark)
    end
end

--------------------------------------------------------
--                    Hit testing                     --
--------------------------------------------------------

--
--- ∑ The row under a point and the part of it that was hit.
---
---   The parts are what a click means. A check box toggles, a swatch opens the
---   colour dialog, a category opens or shuts and everything else only moves
---   the focus.
--- @param x number|nil
--- @param y number|nil
--- @return table|nil, string|nil, number|nil # The row, the part and its index.
--
function Grid:HitTest(x, y)
    local geometry = self.Geometry
    if geometry == nil or type(y) ~= "number" then return nil end
    if type(x) == "number" and x >= geometry.ListWidth then return nil end
    local index
    if self.Math then
        index = self.Math.RowAt(y, geometry.Top, geometry.RowHeight, #self.RowsShown)
    end
    if index == nil then return nil end
    local row = self.RowsShown[index]
    if row == nil then return nil end
    if row.Kind == "category" then return row, "expand", index end
    if type(x) ~= "number" then return row, "label", index end
    if x < geometry.ValueX then return row, "label", index end
    if row.Editor == "bool" then
        -- A mixed row draws its marker where the box would have been, so the
        -- marker is what a click lands on and the whole of it answers.
        local reach = Defaults.CheckSize
        if row.Mixed then reach = geometry.MixedWidth or reach end
        if x <= geometry.ValueX + reach then return row, "check", index end
    end
    if row.Editor == "color" and swatchColor(row.Swatch) ~= nil
        and x <= geometry.ValueX + Defaults.SwatchWidth then
        return row, "swatch", index
    end
    return row, "value", index
end

--- The row at a pixel offset, which is what a popup menu asks for.
function Grid:RowAt(y)
    local row = self:HitTest(nil, y)
    return row
end

--------------------------------------------------------
--                     The mouse                      --
--------------------------------------------------------

--
--- ∑ A mouse down. An open editor on another row commits first, which is the
---   click part of the commit rule.
--- @param button number # Zero is left and one is right, always an integer.
--- @param x number
--- @param y number
--- @return nil
--
function Grid:MouseDown(button, x, y)
    local row, part, index = self:HitTest(x, y)
    if row == nil then return end
    if self:IsEditing() and self.Edit.Key ~= row.Key then self:CommitEdit() end
    self:FocusIndex(index)
    if button ~= 0 and button ~= nil then return end
    if row.Kind == "category" then
        self:ToggleCategory(row.Key)
        return
    end
    if row.ReadOnly then return end
    if part == "check" then self:Toggle(row) return end
    if part == "swatch" then self:Pick(row) return end
end

function Grid:MouseMove(x, y)
    local row, _, index = self:HitTest(x, y)
    if index == self.HoverIndex then return end
    self.HoverIndex = index
    self.HoverKey = row and row.Key or nil
    self:Invalidate()
    fire(self.OnHover, row)
end

function Grid:MouseLeave()
    if self.HoverIndex == nil then return end
    self.HoverIndex, self.HoverKey = nil, nil
    self:Invalidate()
    fire(self.OnHover, nil)
end

--
--- ∑ A double click opens the editor of the row under it.
---
---   A check box and a swatch already acted on the first of the two downs, so
---   they are left alone here rather than acting a third time.
--- @param x number
--- @param y number
--- @return nil
--
function Grid:DoubleClick(x, y)
    local row, part, index = self:HitTest(x, y)
    if row == nil or row.Kind == "category" then return end
    if part == "check" or part == "swatch" then return end
    self:FocusIndex(index)
    self:Activate(row)
end

--------------------------------------------------------
--                  Acting on a row                   --
--------------------------------------------------------

--
--- ∑ What Enter, F2 and a double click all mean on one row, which depends on
---   what the row is.
--- @param row table|nil
--- @return boolean # Whether the row did anything.
--
function Grid:Activate(row)
    row = row or self:FocusedRow()
    if row == nil then return false end
    if row.Kind == "category" then return self:ToggleCategory(row.Key) end
    if row.ReadOnly then return false end
    if row.Editor == "bool" then return self:Toggle(row) end
    if row.Editor == "color" or row.Editor == "button" then return self:Pick(row) end
    return (self:BeginEdit(row.Key))
end

--
--- ∑ Flips a boolean row and tells the owner what it should become.
---
---   A row the records disagree on goes to on, because that is the one answer
---   that means the same thing for every record in the selection.
--- @param row table
--- @return boolean
--
function Grid:Toggle(row)
    if row == nil or row.Kind ~= "property" or row.ReadOnly then return false end
    if row.Editor ~= "bool" then return false end
    local value = not (row.Checked == true)
    if row.Mixed then value = true end
    fire(self.OnCommit, row.Key, value)
    return true
end

--- Reports a row the owner has to open a dialog for, which is a colour and any
--- row whose editor is a button.
function Grid:Pick(row)
    if row == nil or row.Kind ~= "property" or row.ReadOnly then return false end
    fire(self.OnPick, row.Key)
    return true
end

--------------------------------------------------------
--                  Editing in place                  --
--------------------------------------------------------

function Grid:IsEditing()
    return self.Edit ~= nil
end

function Grid:EditingKey()
    return self.Edit and self.Edit.Key or nil
end

--- Which of the two controls a row is edited with. An enum takes the combo box
--- and everything with text in it takes the edit.
local function controlFor(self, row)
    if row.Editor == "enum" then return self.Combo end
    return self.Editor
end

--
--- ∑ Opens the editor on one row.
---
---   A colour row and a button row have no editor to open, so they report
---   through OnPick instead and the owner shows the dialog. A boolean is
---   toggled and never typed into.
--- @param key string|nil # Nothing means the focused row.
--- @return boolean, string|nil
--
function Grid:BeginEdit(key)
    key = key or self.FocusedKey
    local row = self:RowByKey(key)
    if row == nil or row.Kind ~= "property" then return false, "There is no such row." end
    if row.ReadOnly then
        return false, row.Hint or "This value cannot be edited here."
    end
    if row.Editor == "color" or row.Editor == "button" then
        return self:Pick(row), nil
    end
    if row.Editor == "bool" then
        return false, "A check box is toggled with Space."
    end
    local control = controlFor(self, row)
    if control == nil then
        return false, "This Cheat Engine has no control to edit the value with."
    end
    -- An editor already open somewhere else commits, because the user moved on
    -- and what they typed there was meant.
    if self:IsEditing() and self.Edit.Key ~= key then self:CommitEdit() end
    if self:IsEditing() then return true end
    self:FocusKey(key)

    local start = nil
    self.Loading = true
    if row.Editor == "enum" then
        local choices = row.Choices or {}
        pcall(function() control.Items.clear() end)
        for _, choice in ipairs(choices) do
            pcall(function() control.Items.add(tostring(choice.Label or choice.Value)) end)
        end
        local selected = -1
        if not row.Mixed then
            for index, choice in ipairs(choices) do
                if choice.Value == row.Value
                    or tostring(choice.Label) == tostring(row.Text) then
                    selected = index - 1
                    start = choice.Value
                    break
                end
            end
        end
        safeSet(control, "ItemIndex", selected)
        self.Edit = {
            Key = key, Row = row, Editor = row.Editor, Danger = row.Danger,
            Control = control, Start = start, Choices = choices
        }
    else
        -- A mixed row starts empty, so anything typed into it is a value the
        -- user meant for every record and not a value one of them happened to
        -- have.
        start = row.Mixed and "" or tostring(row.Text or "")
        safeSet(control, "Text", start)
        self.Edit = {
            Key = key, Row = row, Editor = row.Editor, Danger = row.Danger,
            Control = control, Start = start, Choices = nil
        }
    end
    self.Loading = false

    self:PlaceEditor()
    pcall(function() control.bringToFront() end)
    pcall(function() control.setFocus() end)
    self:Invalidate()
    return true
end

--
--- ∑ Takes what is in the editor, closes it and hands the value to the owner.
---
---   The editor closes before the owner hears about it, because the owner
---   writes the record and then hands the grid new rows, and a rebuild that
---   found the editor still open would try to keep it.
--- @return boolean # Whether a value was handed over.
--
function Grid:CommitEdit()
    local edit = self.Edit
    if edit == nil then return false end
    local value = nil
    if edit.Editor == "enum" then
        local index = tonumber(safeGet(edit.Control, "ItemIndex")) or -1
        local choice = index >= 0 and edit.Choices[index + 1] or nil
        if choice == nil then
            self:CancelEdit()
            return false
        end
        value = choice.Value
    else
        value = tostring(safeGet(edit.Control, "Text") or "")
    end
    self:CloseEditor()
    if value == edit.Start then return false end
    fire(self.OnCommit, edit.Key, value)
    return true
end

--- Shuts the editor and tells nobody, which is what Escape and a row that went
--- away both need.
function Grid:CancelEdit()
    if self.Edit == nil then return false end
    self:CloseEditor()
    return true
end

--- Hides both controls and forgets the open edit. The suppress flag is up
--- while it happens, because hiding a focused control moves the focus and the
--- exit handler would otherwise commit the edit that is being closed.
function Grid:CloseEditor()
    self.Suppress = true
    safeSet(self.Editor, "Visible", false)
    safeSet(self.Combo, "Visible", false)
    self.Suppress = false
    self.EditorShown = false
    self.Edit = nil
    self:Invalidate()
end

--
--- ∑ Moves the open editor over its row, and hides it while the row is
---   scrolled off the canvas.
---
---   The editor sits in the panel and the canvas fills the panel, so the row
---   position is the editor position plus wherever the canvas starts. The
---   canvas is aligned to the client area, so that offset is almost always
---   zero, and reading it costs nothing next to being wrong when it is not.
--- @return boolean # Whether the editor is on screen.
--
function Grid:PlaceEditor()
    local edit = self.Edit
    if edit == nil then return false end
    local geometry, surface = self.Geometry, self.Surface
    if geometry == nil or surface == nil then return false end
    local index = self:IndexOf(edit.Key)
    local position = index and (index - surface.Top) or nil
    if position == nil or position < 0 or position >= math.max(1, surface.Visible) then
        if self.EditorShown then
            self.Suppress = true
            safeSet(edit.Control, "Visible", false)
            self.Suppress = false
            self.EditorShown = false
        end
        return false
    end
    local offsetX = tonumber(safeGet(surface.Control, "Left")) or 0
    local offsetY = tonumber(safeGet(surface.Control, "Top")) or 0
    local rowHeight = geometry.RowHeight
    local width = math.max(Defaults.MinEditorWidth, geometry.ValueWidth)
    self.Suppress = true
    safeSet(edit.Control, "Left", offsetX + geometry.ValueX)
    safeSet(edit.Control, "Top", offsetY + position * rowHeight + 1)
    safeSet(edit.Control, "Width", width)
    safeSet(edit.Control, "Height", math.max(8, rowHeight - 2))
    safeSet(edit.Control, "Visible", true)
    self.Suppress = false
    self.EditorShown = true
    return true
end

--
--- ∑ The keys an open editor answers. Everything else is the edit's own, which
---   is what keeps Ctrl and Z inside the box.
--- @param key number
--- @return number # Zero swallows the key, anything else passes it on.
--
function Grid:EditorKey(key)
    if self.Edit == nil then return key end
    if key == Keys.Enter or key == Keys.Tab then
        self:CommitEdit()
        return 0
    end
    if key == Keys.Escape then
        self:CancelEdit()
        return 0
    end
    return key
end

--- The combo box commits on the user's own change, because a dropped list is
--- picked from once and there is nothing else to wait for.
function Grid:ComboChanged()
    if self.Loading or self.Edit == nil then return end
    if self.Edit.Editor ~= "enum" then return end
    self:CommitEdit()
end

--
--- ∑ The editor lost the focus. A normal row commits, because the user moved
---   on and meant what they typed. A dangerous row cancels, because running a
---   script or writing process memory is not something to do by accident on
---   the way to somewhere else.
--- @return nil
--
function Grid:FocusLost()
    if self.Suppress or self.Edit == nil then return end
    if self.Edit.Danger then
        self:CancelEdit()
    else
        self:CommitEdit()
    end
end

--------------------------------------------------------
--                        Keys                        --
--------------------------------------------------------

--- Moves the focus by drawn position and lands on the row at the end when it
--- was asked for one past it.
function Grid:Step(index)
    local count = #self.RowsShown
    if count == 0 then return false end
    index = math.max(1, math.min(count, math.floor(index)))
    return self:FocusIndex(index)
end

--
--- ∑ The keys the grid answers. The owner calls this, because a canvas never
---   takes the focus and so never sees a key of its own.
--- @param key number # Virtual key code.
--- @return boolean # Whether the key was used.
--
function Grid:HandleKey(key)
    if self:IsEditing() then
        -- While an editor is open the box owns the keyboard. Only the three
        -- keys that close it are answered here, so a window shortcut cannot
        -- reach past an open editor.
        if key == Keys.Enter or key == Keys.Tab then
            self:CommitEdit()
            return true
        end
        if key == Keys.Escape then
            self:CancelEdit()
            return true
        end
        return false
    end
    local count = #self.RowsShown
    if count == 0 then return false end
    local index = self:FocusedIndex() or 0
    local page = math.max(1, ((self.Surface and self.Surface.Visible) or 10) - 1)
    if key == Keys.Up then return self:Step(index - 1) end
    if key == Keys.Down then return self:Step(index + 1) end
    if key == Keys.PageUp then return self:Step(index - page) end
    if key == Keys.PageDown then return self:Step(index + page) end
    if key == Keys.Home then return self:Step(1) end
    if key == Keys.End then return self:Step(count) end
    local row = self.RowsShown[index]
    if key == Keys.Left then
        if row and row.Kind == "category" and row.Collapsed ~= true then
            return self:ToggleCategory(row.Key, true)
        end
        local category = row and categoryOf(self, row.Key) or nil
        if category then return self:FocusKey(category.Key) end
        return false
    end
    if key == Keys.Right then
        if row and row.Kind == "category" and row.Collapsed == true then
            return self:ToggleCategory(row.Key, false)
        end
        return self:Step(index + 1)
    end
    if key == Keys.Space then
        if row == nil then return false end
        if row.Kind == "category" then return self:ToggleCategory(row.Key) end
        if row.Editor == "bool" then return self:Toggle(row) end
        return false
    end
    if key == Keys.Enter or key == Keys.F2 then return self:Activate(row) end
    return false
end

--------------------------------------------------------
--                      Teardown                      --
--------------------------------------------------------

--
--- ∑ Releases the canvas and both editors. The panel they sit in belongs to
---   the form, but the controls were made here, so they are freed here as
---   well and a page that is rebuilt does not leave two boxes behind.
--- @return nil
--
function Grid:Destroy()
    self:CancelEdit()
    if self.Surface then
        self.Surface:Destroy()
        self.Surface = nil
    end
    if self.Editor then pcall(function() self.Editor.destroy() end) end
    if self.Combo then
        -- The theme watches the combo box until its brush is settled, so it is
        -- told first and never reads the box after it is gone.
        local theme = self.Theme
        if theme ~= nil and type(theme.ForgetCombo) == "function" then
            pcall(theme.ForgetCombo, theme, self.Combo)
        end
        pcall(function() self.Combo.destroy() end)
    end
    self.Editor, self.Combo = nil, nil
    self.Parent, self.Geometry = nil, nil
    self.RowsAll, self.RowsShown = {}, {}
    self.FocusedKey, self.HoverIndex, self.HoverKey = nil, nil, nil
    self.EditorShown, self.Ready = false, false
end

return Grid
