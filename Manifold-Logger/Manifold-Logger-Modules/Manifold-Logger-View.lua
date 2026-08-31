--[[
    The log view. A virtual, owner-drawn list painted onto a canvas. A memo is
    one colour, and a TListView's per-row colour is only reachable through
    OnCustomDrawItem, which Cheat Engine does not expose. Painting it here buys
    icons, per-level hue, striping, selection, search highlights and badges.

    Only on-screen rows are touched. Rows are built incrementally: arrivals
    append, records leaving the ring drop rows off the front, and a full
    rebuild happens only when the filter, the wrap mode or the font changed.
    A frame is one pcall, not one per drawing call. Five consecutive failures
    stop the view instead of filling Cheat Engine's log.

    canvas.getTextWidth is a Win32 text-extent call. One reference measurement
    per frame gives an average character width, and a line is only measured for
    real near a column edge. In Consolas, which every Manifold window uses, the
    estimate is exact.

    The surface is probed, because Cheat Engine's control set varies by build.
    createPaintBox gives a TGraphicControl with a Canvas and OnPaint, blitted
    from an off-screen bitmap. No script shipped with Cheat Engine 7.5 uses it,
    so it may not exist. createImage gives a TImage, as ceshare scripts do. Its
    Picture.Bitmap is already off screen, created by TPicture.GetBitmap on
    first access, and that is the live path. With neither, Attach returns false
    and the caller falls back to a themed memo.

    Cheat Engine's binding drops the LCL's Shift argument, so OnMouseDown
    arrives as (sender, button, x, y) and OnMouseMove as (sender, x, y).
    Coordinates are the last two numbers, correct under both. A TPaintBox and
    a TImage are TGraphicControls with no window handle, so WM_MOUSEWHEEL
    reaches the nearest windowed ancestor. The wheel handler goes on the
    surface and on the parent panel, and only on OnMouseWheelUp/Down.

    View.Layout is pure geometry over plain tables, testable without Cheat
    Engine.
]]

local Format = require("Manifold-Logger-Format")

local View = {}
View.__index = View

--- Manifold-Logger-Core.Levels.WARNING, copied rather than required. The view
--- renders records, whoever produced them, so it does not depend on the log.
local WARN_RANK = 40

--------------------------------------------------------
--                    Pure geometry                   --
--------------------------------------------------------

local Layout = {}
View.Layout = Layout

--
--- ∑ Expands one record into physical rows, appended to rows.
---
---   One record is one row or several. A block message, a traceback and a
---   wrapped line each take more than one. Rows point back at their record, so
---   selection and copying work in records while drawing works in rows.
---
---   Rows do not carry their record's position in the list. Zebra striping
---   reads record.Seq, which never changes, so records falling off the front
---   of the ring cannot force a renumbering pass.
--- @param record table
--- @param options table|nil # { Wrap, Width, Measure, ShowFields, ShowTrace, Indent }
--- @param rows table|nil # Appended to, created when absent.
--- @return table # rows
--
function Layout.ExpandRecord(record, options, rows)
    options = options or {}
    rows = rows or {}
    local width = options.Width or 0
    local measure = options.Measure
    local indent = options.Indent or "    "
    local wrapping = options.Wrap == true and width > 0 and measure ~= nil

    local function push(text, first, kind)
        rows[#rows + 1] = { Record = record, Text = text, First = first == true, Kind = kind }
    end

    local prepared = Format.Prepare(record)
    local lines = prepared.Lines
    local first = true
    for lineIndex = 1, #lines do
        local text = lineIndex == 1 and lines[lineIndex] or (indent .. lines[lineIndex])
        if wrapping then
            local pieces = Format.Wrap(text, width, measure)
            for pieceIndex = 1, #pieces do
                -- A wrapped continuation is indented again, so a long line
                -- reads as one paragraph rather than as new records.
                push(pieceIndex > 1 and (indent .. pieces[pieceIndex]) or pieces[pieceIndex],
                     first, "message")
                first = false
            end
        else
            push(text, first, "message")
            first = false
        end
    end
    if options.ShowFields and prepared.Fields ~= "" then
        local text = indent .. prepared.Fields
        if wrapping then
            for _, piece in ipairs(Format.Wrap(text, width, measure)) do
                push(piece, false, "fields")
            end
        else
            push(text, false, "fields")
        end
    end
    if options.ShowTrace and record.Trace then
        for _, line in ipairs(Format.Lines(record.Trace)) do
            push(indent .. line, false, "trace")
        end
    end
    return rows
end

--
--- ∑ Expands a whole list of records. The bulk form of ExpandRecord.
--- @param records table
--- @param options table|nil
--- @return table
--
function Layout.BuildRows(records, options)
    local rows = {}
    for index = 1, #records do
        Layout.ExpandRecord(records[index], options, rows)
    end
    return rows
end

--
--- ∑ Clamps a scroll position to something that exists.
--- @param top number # Index of the first visible row, 1-based.
--- @param visible number # Rows that fit.
--- @param count number # Rows in total.
--- @return number
--
function Layout.Clamp(top, visible, count)
    local maximum = math.max(1, count - visible + 1)
    if top < 1 then return 1 end
    if top > maximum then return maximum end
    return math.floor(top)
end

--- The scroll position that shows the last row.
function Layout.Bottom(visible, count)
    return math.max(1, count - visible + 1)
end

--
--- ∑ Where the scrollbar thumb sits, in track coordinates.
---   Returns nil when everything fits and no thumb should be drawn.
--- @param top number
--- @param visible number
--- @param count number
--- @param track number # Track height in pixels.
--- @param minimum number|nil # Smallest thumb, default 24.
--- @return number|nil, number|nil # y, height
--
function Layout.Thumb(top, visible, count, track, minimum)
    minimum = minimum or 24
    if count <= visible or track <= 0 then return nil end
    local height = math.max(minimum, math.floor(track * visible / count))
    height = math.min(height, track)
    local span = math.max(1, count - visible)
    local progress = math.min(1, math.max(0, (top - 1) / span))
    return math.floor(progress * (track - height)), height
end

--
--- ∑ Inverse of Layout.Thumb. The scroll position a thumb dragged to y means.
--- @param y number
--- @param thumbHeight number
--- @param track number
--- @param visible number
--- @param count number
--- @return number
--
function Layout.TopForThumb(y, thumbHeight, track, visible, count)
    local room = track - thumbHeight
    if room <= 0 then return 1 end
    local progress = math.min(1, math.max(0, y / room))
    local span = math.max(0, count - visible)
    return Layout.Clamp(1 + math.floor(progress * span + 0.5), visible, count)
end

--
--- ∑ Row index at a pixel offset inside the list area, or nil above or below
---   the rows that exist.
--- @param y number|nil
--- @param top number
--- @param rowHeight number
--- @param count number
--- @return number|nil
--
function Layout.RowAt(y, top, rowHeight, count)
    -- y is nil when a Cheat Engine build hands the handler fewer arguments
    -- than expected. Refusing is right, raising would fire per mouse move.
    if type(y) ~= "number" or rowHeight <= 0 or y < 0 then return nil end
    local index = top + math.floor(y / rowHeight)
    if index < 1 or index > count then return nil end
    return index
end

--
--- ∑ How many whole rows fit in a height.
--- @param height number
--- @param rowHeight number
--- @return number
--
function Layout.Visible(height, rowHeight)
    if rowHeight <= 0 then return 0 end
    return math.max(1, math.floor(height / rowHeight))
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

View.Defaults = {
    FontSize    = 10,
    MinFontSize = 7,
    MaxFontSize = 20,
    ScrollWidth = 12,
    GutterWidth = 5,
    IconSize    = 16,
    PadX        = 6,
    WheelRows   = 3,
    MaxMatches  = 8,     -- search highlights drawn per row
    MaxFailures = 5      -- consecutive paint failures before giving up
}

--
--- ∑ Builds a view. Nothing is created until Attach.
--- @param services table # { Theme, Icons, Meta (Core.Meta) }
--- @return table
--
function View:New(services)
    services = services or {}
    return setmetatable({
        Theme    = services.Theme,
        Icons    = services.Icons,
        Meta     = services.Meta or {},

        Surface  = nil,      -- the control that receives paint and mouse events
        Kind     = nil,      -- "paintbox" | "image"
        Buffer   = nil,      -- off-screen bitmap (paintbox path only)
        Parent   = nil,
        Reason   = nil,
        Disabled = false,

        Records  = {},       -- the owner's array, held by reference
        Rows     = {},
        BuiltCount = 0,      -- records already expanded into Rows
        FirstSeq = nil,      -- Seq of Records[1] when the rows were built
        RowsDirty= true,
        PendingFrom = nil,   -- first record index still to be expanded

        ChannelWidths = {},  -- channel name -> measured pixels
        ChannelWidth  = 0,   -- widest channel among the built rows

        Top      = 1,
        Follow   = true,
        Wrap     = false,
        ShowStamp   = true,
        ShowChannel = true,
        ShowFields  = true,
        ShowTrace   = true,
        FontSize = View.Defaults.FontSize,
        Search   = nil,
        SearchLower = nil,

        Selection = {},      -- record Seq -> true
        Anchor    = nil,     -- row index a shift-click ranges from
        Hover     = nil,     -- row index under the cursor
        Dragging  = false,   -- scrollbar thumb drag in progress
        DragOffset= 0,

        Metrics  = nil,      -- computed on the first paint
        CachedPalette = nil, -- the palette the derived colours were built from
        SurfaceColors = nil,
        LevelColors = nil,
        CharWidth = 0,       -- average, for the cheap width estimate
        EmptyStyle = nil,    -- probed once, see _Frame
        Dirty    = true,
        Painting = false,
        PaintFailures = 0,

        OnActivate = nil,
        OnSelectionChanged = nil,
        OnContextMenu = nil,
        OnFollowChanged = nil,
        OnError = nil
    }, View)
end

--------------------------------------------------------
--                      Surface                       --
--------------------------------------------------------

local function safeSet(control, property, value)
    if not control then return false end
    return (pcall(function() control[property] = value end))
end

--
--- ∑ The last two numbers in an argument list.
---
---   Cheat Engine's binding drops the LCL's Shift argument from mouse events,
---   so OnMouseDown arrives as (sender, button, x, y) and OnMouseMove as
---   (sender, x, y). Taking the last two numbers is correct under both, and
---   under the LCL's own shapes as well.
--- @return number|nil, number|nil
--
local function coordinates(...)
    local x, y
    for index = select("#", ...), 1, -1 do
        local value = select(index, ...)
        if type(value) == "number" then
            if y == nil then
                y = value
            else
                x = value
                break
            end
        end
    end
    return x, y
end

View.Coordinates = coordinates

--
--- ∑ Creates the paint surface inside parent and wires its events.
--- @param parent userdata
--- @return boolean, string|nil
--
function View:Attach(parent)
    self.Parent = parent
    local createPaintBox = rawget(_G, "createPaintBox")
    if type(createPaintBox) == "function" then
        local ok, box = pcall(createPaintBox, parent)
        if ok and box then
            self.Surface, self.Kind = box, "paintbox"
        end
    end
    if not self.Surface then
        local createImage = rawget(_G, "createImage")
        if type(createImage) == "function" then
            local ok, image = pcall(createImage, parent)
            if ok and image then
                self.Surface, self.Kind = image, "image"
                safeSet(image, "Stretch", false)
                safeSet(image, "Center", false)
                safeSet(image, "AutoSize", false)
            end
        end
    end
    if not self.Surface then
        self.Reason = "this Cheat Engine has neither createPaintBox nor createImage"
        return false, self.Reason
    end
    safeSet(self.Surface, "Parent", parent)
    safeSet(self.Surface, "Align", "alClient")
    self:WireEvents()
    return true
end

--
--- ∑ Wraps an event handler so a defect in it degrades instead of printing
---   once per event.
---
---   An unguarded handler that raises fails on every mouse move, and Cheat
---   Engine prints each one into the Lua Engine window. One protected call per
---   event costs far less. The first failure goes out through OnError, where
---   the log's own dedup collapses a repeat into a counter.
--- @param name string # What to call it in the report.
--- @param fn function
--- @return function
--
function View:Guard(name, fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        if self.OnError then
            pcall(self.OnError, name .. " failed: " .. tostring(result))
        end
    end
end

--
--- ∑ Installs the event handlers.
--- @return nil
--
function View:WireEvents()
    local surface = self.Surface
    if self.Kind == "paintbox" then
        safeSet(surface, "OnPaint", self:Guard("paint", function() self:Present() end))
    end
    safeSet(surface, "OnResize", self:Guard("resize", function() self:OnResize() end))
    safeSet(surface, "OnMouseDown", self:Guard("mouse down", function(_, button, ...)
        local x, y = coordinates(...)
        self:MouseDown(button, x, y)
    end))
    safeSet(surface, "OnMouseUp", self:Guard("mouse up", function(_, button, ...)
        local x, y = coordinates(...)
        self:MouseUp(button, x, y)
    end))
    safeSet(surface, "OnMouseMove", self:Guard("mouse move", function(_, ...)
        local x, y = coordinates(...)
        self:MouseMove(x, y)
    end))
    safeSet(surface, "OnMouseLeave", self:Guard("mouse leave", function() self:MouseLeave() end))
    safeSet(surface, "OnDblClick", self:Guard("double click", function() self:Activate() end))

    -- Up and Down only. TControl.DoMouseWheel calls OnMouseWheel first and
    -- falls through to DoMouseWheelUp/Down only when it did not report the
    -- event handled, so setting both scrolls twice a notch where Handled is
    -- dropped on the way out of Lua.
    local up = self:Guard("wheel up",
        function() self:ScrollBy(-View.Defaults.WheelRows) return true end)
    local down = self:Guard("wheel down",
        function() self:ScrollBy(View.Defaults.WheelRows) return true end)
    for _, control in ipairs({ surface, self.Parent }) do
        safeSet(control, "OnMouseWheelUp", up)
        safeSet(control, "OnMouseWheelDown", down)
    end
end

--
--- ∑ Size of the drawable area.
--- @return number, number
--
function View:Size()
    local width, height = 0, 0
    pcall(function()
        width = tonumber(self.Surface.Width) or 0
        height = tonumber(self.Surface.Height) or 0
    end)
    return width, height
end

--
--- ∑ The canvas to render into, plus a function that puts it on screen.
---
---   The image path renders straight into the picture's bitmap, which is
---   already off screen. The paint box path renders into a bitmap of our own
---   that OnPaint blits, because painting inside OnPaint flickers on a scroll.
--- @param width number
--- @param height number
--- @return userdata|nil, function|nil
--
function View:AcquireCanvas(width, height)
    if width <= 0 or height <= 0 then return nil end
    if self.Kind == "image" then
        local canvas
        local ok = pcall(function()
            -- TPicture.GetBitmap returns the same object once it has made one,
            -- so it is resolved once and kept. Reaching through Picture every
            -- frame is two lookups through Cheat Engine's RTTI fallback.
            local bitmap = self.PictureBitmap
            if not bitmap then
                bitmap = self.Surface.Picture.Bitmap
                self.PictureBitmap = bitmap
            end
            if tonumber(bitmap.Width) ~= width then bitmap.Width = width end
            if tonumber(bitmap.Height) ~= height then bitmap.Height = height end
            canvas = bitmap.Canvas
        end)
        if not ok or not canvas then
            self.PictureBitmap = nil
            return nil
        end
        return canvas, function() pcall(function() self.Surface.repaint() end) end
    end
    -- paintbox
    local create = rawget(_G, "createBitmap")
    if type(create) ~= "function" then return nil end
    -- Grow only. A resize drag delivers a new size on every WM_SIZE, and
    -- rebuilding a GDI bitmap of the whole client area each time is the
    -- costliest part of a resize. A buffer larger than the control is
    -- harmless, the blit starts at (0,0) and the control clips the rest.
    local needWidth = math.max(width, self.BufferWidth or 0)
    local needHeight = math.max(height, self.BufferHeight or 0)
    if self.Buffer and (self.BufferWidth < width or self.BufferHeight < height) then
        pcall(function() self.Buffer.destroy() end)
        self.Buffer = nil
    end
    if not self.Buffer then
        local ok, bitmap = pcall(create, needWidth, needHeight)
        if not ok or not bitmap then return nil end
        self.Buffer = bitmap
        self.BufferWidth, self.BufferHeight = needWidth, needHeight
    end
    local canvas
    if not pcall(function() canvas = self.Buffer.Canvas end) or not canvas then return nil end
    return canvas, function() pcall(function() self.Surface.repaint() end) end
end

--
--- ∑ Blits the buffer. Only the paint box path needs it. The image path is
---   already showing the bitmap it was drawn into.
--- @return nil
--
function View:Present()
    if self.Kind ~= "paintbox" or not self.Buffer then return end
    pcall(function() self.Surface.Canvas.draw(0, 0, self.Buffer) end)
end

--------------------------------------------------------
--                   The record list                  --
--------------------------------------------------------

--
--- ∑ Takes the owner's record array and works out how much of the row list
---   can be kept.
---
---   The array is held by reference and the owner mutates it in place, so an
---   append stays an append instead of a fresh snapshot. Three cases, cheapest
---   first:
---     front moved: records fell out of the ring, drop their rows
---     tail grew: expand only the new records
---     anything else: rebuild
--- @param records table
--- @param full boolean|nil # Force a rebuild (filter, wrap or font changed).
--- @return nil
--
function View:Sync(records, full)
    records = records or {}
    if full or records ~= self.Records then
        self.Records = records
        self.RowsDirty = true
        self.PendingFrom = nil
        self:Invalidate()
        return
    end
    local first = records[1]
    if not first then
        self.Rows, self.BuiltCount, self.FirstSeq = {}, 0, nil
        self.RowsDirty = false
        self.PendingFrom = nil
        self.Top = 1
        self:Invalidate()
        return
    end
    if self.BuiltCount > 0 and self.FirstSeq and first.Seq ~= self.FirstSeq then
        self:TrimTo(first.Seq)
    end
    if #records < self.BuiltCount then
        self.RowsDirty = true
    elseif #records > self.BuiltCount then
        self.PendingFrom = self.PendingFrom or (self.BuiltCount + 1)
    end
    self:Invalidate()
end

--
--- ∑ Drops the rows of records older than firstSeq, which is what a ring that
---   wrapped leaves behind. The scroll position moves with them, so the window
---   does not jump by the number of rows that vanished off the top.
--- @param firstSeq number
--- @return nil
--
function View:TrimTo(firstSeq)
    local rows = self.Rows
    local total = #rows
    local drop, records = 0, 0
    while drop < total and rows[drop + 1].Record.Seq < firstSeq do
        drop = drop + 1
        if rows[drop].First then records = records + 1 end
    end
    if drop == 0 then return end
    table.move(rows, drop + 1, total, 1)
    for index = total - drop + 1, total do rows[index] = nil end
    self.BuiltCount = math.max(0, self.BuiltCount - records)
    self.FirstSeq = firstSeq
    self.Top = math.max(1, self.Top - drop)
    if self.Anchor then self.Anchor = math.max(1, self.Anchor - drop) end
    if self.Hover then self.Hover = math.max(1, self.Hover - drop) end
end

--
--- ∑ Expands records from..#Records into rows.
---   measure is only needed in wrap mode, so the non-wrapping path never
---   touches the canvas at all.
--- @param from number
--- @param measure function|nil
--- @return nil
--
function View:BuildFrom(from, measure)
    local records, rows = self.Records, self.Rows
    local options = {
        Wrap = self.Wrap,
        Width = self.Metrics and self.Metrics.MessageW or 0,
        Measure = measure,
        ShowFields = self.ShowFields,
        ShowTrace = self.ShowTrace
    }
    local widths = self.ChannelWidths
    for index = from, #records do
        local record = records[index]
        Layout.ExpandRecord(record, options, rows)
        local channel = record.Channel
        if channel and widths[channel] == nil then
            -- Measured once per distinct channel for the life of the window,
            -- not once per record per frame.
            widths[channel] = measure and measure(channel) or (#channel * self.CharWidth)
            if widths[channel] > self.ChannelWidth then
                self.ChannelWidth = widths[channel]
            end
        end
    end
    self.BuiltCount = #records
    if self.FirstSeq == nil and records[1] then self.FirstSeq = records[1].Seq end
end

--- Throws every row away and expands the whole list again.
function View:RebuildRows(measure)
    self.Rows = {}
    self.BuiltCount = 0
    self.FirstSeq = self.Records[1] and self.Records[1].Seq or nil
    self.ChannelWidth = 0
    for _, width in pairs(self.ChannelWidths) do
        if width > self.ChannelWidth then self.ChannelWidth = width end
    end
    self:BuildFrom(1, measure)
end

--------------------------------------------------------
--                       State                        --
--------------------------------------------------------

--
--- ∑ Replaces the visible records. The blunt form of Sync, for a caller that
---   hands over a different array each time.
--- @param records table
--- @return nil
--
function View:SetRecords(records)
    self:Sync(records, records ~= self.Records)
end

function View:SetSearch(text)
    self.Search = (type(text) == "string" and text ~= "") and text or nil
    self.SearchLower = self.Search and self.Search:lower() or nil
    self:Redraw()
end

--- Everything that changes how a row is SHAPED forces a rebuild. Everything
--- that only changes how it is PAINTED does not.
local function reshape(self)
    self.RowsDirty = true
    self.Metrics = nil
    self:Redraw()
end

function View:SetWrap(value)
    self.Wrap = value == true
    reshape(self)
end

function View:SetShowChannel(value)
    self.ShowChannel = value == true
    self.Metrics = nil
    if self.Wrap then self.RowsDirty = true end
    self:Redraw()
end

function View:SetShowStamp(value)
    self.ShowStamp = value == true
    self.Metrics = nil
    if self.Wrap then self.RowsDirty = true end
    self:Redraw()
end

function View:SetShowFields(value)
    self.ShowFields = value == true
    reshape(self)
end

function View:SetFontSize(size)
    size = math.floor(tonumber(size) or self.FontSize)
    size = math.max(View.Defaults.MinFontSize, math.min(View.Defaults.MaxFontSize, size))
    if size == self.FontSize then return false end
    self.FontSize = size
    -- The font decides every measurement, so the cached channel widths are
    -- wrong too.
    self.ChannelWidths, self.ChannelWidth = {}, 0
    reshape(self)
    return true
end

--
--- ∑ Turns tail-following on or off, telling the owner so a toolbar toggle
---   can follow suit.
--- @param value boolean
--- @return nil
--
function View:SetFollow(value)
    value = value == true
    if self.Follow == value then return end
    self.Follow = value
    if value then self:ScrollToEnd() end
    if self.OnFollowChanged then pcall(self.OnFollowChanged, value) end
end

--------------------------------------------------------
--                      Scrolling                     --
--------------------------------------------------------

function View:RowCount()
    return #self.Rows
end

function View:VisibleRows()
    local metrics = self.Metrics
    if not metrics then return 1 end
    return Layout.Visible(metrics.ListHeight, metrics.RowHeight)
end

--
--- ∑ Scrolls to a row and repaints immediately. Interaction must not wait for
---   the refresh timer. A wheel notch that takes a frame to appear reads as a
---   slow window.
--- @param top number
--- @param keepFollow boolean|nil
--- @return boolean
--
function View:ScrollTo(top, keepFollow)
    local visible = self:VisibleRows()
    local count = self:RowCount()
    local clamped = Layout.Clamp(top, visible, count)
    if clamped == self.Top then return false end
    self.Top = clamped
    if not keepFollow then
        -- Reaching the end re-arms following, leaving it disarms it. A log
        -- must not scroll away under someone who is reading it.
        self:SetFollow(clamped >= Layout.Bottom(visible, count))
    end
    self:Redraw()
    return true
end

function View:ScrollBy(rows)
    return self:ScrollTo(self.Top + rows)
end

function View:ScrollToEnd()
    self.Top = Layout.Bottom(self:VisibleRows(), self:RowCount())
    self:Redraw()
    return true
end

function View:PageDown() return self:ScrollBy(self:VisibleRows() - 1) end
function View:PageUp() return self:ScrollBy(-(self:VisibleRows() - 1)) end

--------------------------------------------------------
--                      Selection                     --
--------------------------------------------------------

function View:ClearSelection()
    self.Selection = {}
    self.Anchor = nil
    self:Redraw()
    if self.OnSelectionChanged then pcall(self.OnSelectionChanged) end
end

--
--- ∑ Selects one row's record, or extends or toggles the selection.
--- @param row number
--- @param mode string|nil # "replace" (default), "toggle", "range"
--- @return nil
--
function View:Select(row, mode)
    local entry = self.Rows[row]
    if not entry then return end
    mode = mode or "replace"
    if mode == "replace" then
        self.Selection = { [entry.Record.Seq] = true }
        self.Anchor = row
    elseif mode == "toggle" then
        local seq = entry.Record.Seq
        self.Selection[seq] = not self.Selection[seq] or nil
        self.Anchor = row
    elseif mode == "range" then
        local from = self.Anchor or row
        local first, last = math.min(from, row), math.max(from, row)
        self.Selection = {}
        for index = first, last do
            local candidate = self.Rows[index]
            if candidate then self.Selection[candidate.Record.Seq] = true end
        end
    end
    self:Redraw()
    if self.OnSelectionChanged then pcall(self.OnSelectionChanged) end
end

function View:SelectAll()
    self.Selection = {}
    for _, record in ipairs(self.Records) do self.Selection[record.Seq] = true end
    self:Redraw()
    if self.OnSelectionChanged then pcall(self.OnSelectionChanged) end
end

--
--- ∑ The selected records, in display order. Falls back to everything on
---   screen when nothing is selected, so Copy copies the visible log rather
---   than nothing.
--- @param fallbackToAll boolean|nil
--- @return table
--
function View:SelectedRecords(fallbackToAll)
    local out = {}
    for _, record in ipairs(self.Records) do
        if self.Selection[record.Seq] then out[#out + 1] = record end
    end
    if #out == 0 and fallbackToAll then return self.Records end
    return out
end

--- The record the cursor is over, or the first selected one.
function View:FocusedRecord()
    local entry = self.Hover and self.Rows[self.Hover]
    if entry then return entry.Record end
    local selected = self:SelectedRecords()
    return selected[1]
end

--------------------------------------------------------
--                       Metrics                      --
--------------------------------------------------------

--
--- ∑ Column geometry, measured against the real font.
---
---   Four measurements, not one per record. The timestamp and the level tag
---   are fixed-width strings, the channel column comes from the widths cached
---   per distinct channel name, and CharWidth is the reference the row loop
---   tests a line against before measuring it.
--- @param canvas userdata
--- @param width number
--- @param height number
--- @return table
--
function View:Measure(canvas, width, height)
    local defaults = View.Defaults
    local function textWidth(text)
        return tonumber(canvas.getTextWidth(text)) or 0
    end
    local textHeight = tonumber(canvas.getTextHeight("Ag")) or 0
    if textHeight <= 0 then textHeight = self.FontSize + 6 end
    self.CharWidth = textWidth("0123456789") / 10
    if self.CharWidth <= 0 then self.CharWidth = math.max(1, self.FontSize * 0.6) end

    local rowHeight = math.max(defaults.IconSize + 2, textHeight + 4)
    local x = defaults.GutterWidth
    local iconX = x
    x = x + defaults.IconSize + defaults.PadX

    local stampWidth = self.ShowStamp and textWidth("00:00:00.000 ") or 0
    local stampX = x
    x = x + stampWidth

    local tagWidth = textWidth("CRT ") + 4
    local tagX = x
    x = x + tagWidth

    local channelWidth = 0
    if self.ShowChannel then
        -- Bounded so a deeply nested channel name cannot eat the message
        -- column.
        channelWidth = math.max(0, math.min(self.ChannelWidth + defaults.PadX,
            math.floor(width * 0.22)))
    end
    local channelX = x
    x = x + channelWidth

    local scrollWidth = defaults.ScrollWidth
    local messageX = x
    local messageWidth = math.max(40, width - messageX - scrollWidth - defaults.PadX)

    return {
        Width = width, Height = height,
        RowHeight = rowHeight, TextHeight = textHeight,
        ListWidth = width - scrollWidth, ListHeight = height,
        IconX = iconX, IconY = math.floor((rowHeight - defaults.IconSize) / 2),
        StampX = stampX, StampW = stampWidth,
        TagX = tagX, TagW = tagWidth,
        ChannelX = channelX, ChannelW = channelWidth,
        MessageX = messageX, MessageW = messageWidth,
        ScrollX = width - scrollWidth, ScrollW = scrollWidth,
        TextY = math.floor((rowHeight - textHeight) / 2)
    }
end

--------------------------------------------------------
--                      Painting                      --
--------------------------------------------------------

--- Schedules a repaint for the owner's next tick. Used for record arrival, to
--- coalesce a burst. Interaction calls Redraw directly.
function View:Invalidate()
    self.Dirty = true
end

--
--- ∑ The palette and everything derived from it, recomputed only when the
---   theme actually moved.
---
---   Theme:Surface derives thirteen colours and Theme:LevelColors runs a
---   contrast loop for each of seven levels. The answer changes when a Cheat
---   Table applies a different theme, which is approximately never.
---
---   A palette change also invalidates every composited icon, since each was
---   baked against a row background that no longer exists. This is the only
---   place that can notice.
--- @return table, table, table # palette, surface colours, level colours
--
function View:Colors()
    local theme = self.Theme
    if not theme then return {}, {}, {} end
    -- Theme:GetPalette caches against the design theme's own identity, so a
    -- changed palette is a changed table. Comparing the reference is both the
    -- cheapest check and the exact one.
    local palette = theme:GetPalette()
    if palette ~= self.CachedPalette then
        self.CachedPalette = palette
        self.SurfaceColors = theme:Surface(palette)
        self.LevelColors = theme:LevelColors(palette)
        if self.Icons then self.Icons:Invalidate() end
    end
    return palette, self.SurfaceColors, self.LevelColors
end

--
--- ∑ Start and stop offsets of every match of needle in text, flattened into
---   one array. Bounded, because a single-character search over a long line
---   would otherwise produce hundreds of highlights.
--- @param text string
--- @param needle string # Already lowercase.
--- @return table
--
local function matches(text, needle)
    local out = {}
    if not needle or needle == "" then return out end
    local haystack = text:lower()
    local from = 1
    while #out < View.Defaults.MaxMatches * 2 do
        local start, stop = haystack:find(needle, from, true)
        if not start then break end
        out[#out + 1] = start
        out[#out + 1] = stop
        from = stop + 1
    end
    return out
end

--
--- ∑ Renders a frame. One protected call for the whole frame, not one per
---   drawing operation. An API mismatch fails on every frame anyway, so a
---   guard per call would only repeat the same report on every row.
--- @return boolean
--
function View:Redraw()
    if not self.Surface or self.Painting or self.Disabled then return false end
    self.Painting = true
    local ok, err = pcall(self._Frame, self)
    self.Painting = false
    self.Dirty = false
    if ok then
        self.PaintFailures = 0
        return true
    end
    self.PaintFailures = self.PaintFailures + 1
    self.Reason = tostring(err)
    if self.OnError then pcall(self.OnError, self.Reason) end
    if self.PaintFailures >= View.Defaults.MaxFailures then
        self.Disabled = true
        if self.OnError then
            pcall(self.OnError, "the log view stopped painting after "
                .. View.Defaults.MaxFailures .. " consecutive failures")
        end
    end
    return false
end

function View:_Frame()
    local width, height = self:Size()
    local canvas, present = self:AcquireCanvas(width, height)
    if not canvas then return end

    local theme = self.Theme
    local palette, surface, levelColors = self:Colors()
    local defaults = View.Defaults

    -- The empty font style is probed once. "[]" is the empty set, which a
    -- Lazarus style property expects, but a build whose binding takes the
    -- value as a plain string rejects it, and a raise here kills every frame.
    if self.EmptyStyle == nil then
        self.EmptyStyle = pcall(function() canvas.Font.Style = "[]" end) and "[]" or ""
    end
    local emptyStyle = self.EmptyStyle

    local font = canvas.Font
    font.Name = theme and theme.FontName or "Consolas"
    font.Size = self.FontSize
    font.Style = emptyStyle

    -- Metrics depend on the font, which was only just applied, and on the
    -- width, which changes with the window.
    if not self.Metrics or self.Metrics.Width ~= width or self.Metrics.Height ~= height then
        self.Metrics = self:Measure(canvas, width, height)
        if self.Wrap then self.RowsDirty = true end
    end
    local metrics = self.Metrics

    local function measure(text) return tonumber(canvas.getTextWidth(text)) or 0 end
    local channelBefore = self.ChannelWidth
    if self.RowsDirty then
        self:RebuildRows(measure)
        self.RowsDirty = false
        self.PendingFrom = nil
        if self.Follow then self.Top = Layout.Bottom(self:VisibleRows(), #self.Rows) end
    elseif self.PendingFrom then
        self:BuildFrom(self.PendingFrom, measure)
        self.PendingFrom = nil
        if self.Follow then self.Top = Layout.Bottom(self:VisibleRows(), #self.Rows) end
    end
    if self.ChannelWidth ~= channelBefore then
        -- A new, wider channel moves the columns. Re-measure now and, in wrap
        -- mode, re-wrap on the next frame.
        self.Metrics = self:Measure(canvas, width, height)
        metrics = self.Metrics
        if self.Wrap then self.RowsDirty = true end
    end

    local rows = self.Rows
    local count = #rows
    local visible = self:VisibleRows()
    self.Top = Layout.Clamp(self.Top, visible, count)

    local brush = canvas.Brush
    brush.Color = surface.Background or 0x000000
    canvas.fillRect(0, 0, width, height)

    local charWidth = self.CharWidth
    local messageX, messageW = metrics.MessageX, metrics.MessageW
    local rowHeight = metrics.RowHeight
    local listWidth = metrics.ListWidth
    local searchLower = self.SearchLower

    --- Cuts a string to fit a pixel width, appending an ellipsis. The estimate
    --- short-circuits the common case. At Consolas it is exact, and at a
    --- proportional font it only measures when the line is near the edge.
    local function fit(text, limit)
        if limit <= 0 then return "" end
        if #text * charWidth <= limit * 0.9 then return text end
        if measure(text) <= limit then return text end
        local low, high = 0, #text
        while low < high do
            local middle = math.floor((low + high + 1) / 2)
            if measure(text:sub(1, middle) .. "...") <= limit then low = middle else high = middle - 1 end
        end
        return text:sub(1, low) .. "..."
    end

    local last = math.min(count, self.Top + visible - 1)
    for row = self.Top, last do
        local entry = rows[row]
        local record = entry.Record
        local top = (row - self.Top) * rowHeight
        local level = record.Level
        local levelColor = levelColors[level] or surface.Text or 0xFFFFFF

        -- Row background. Selection wins over hover, hover over the stripe.
        -- Striping reads Seq, not a list position, so records leaving the ring
        -- cannot renumber every row that is left.
        local background = surface.Background
        if self.Selection[record.Seq] then
            background = surface.Selection
        elseif self.Hover == row then
            background = surface.Hover
        elseif record.Seq % 2 == 0 then
            background = surface.Stripe
        end
        brush.Color = background
        canvas.fillRect(0, top, listWidth, top + rowHeight)

        -- Pin marker in the gutter, and a level-coloured edge for anything at
        -- WARNING or above, so a problem is findable by peripheral vision
        -- while scrolling past.
        if record.Pinned then
            brush.Color = surface.Accent
            canvas.fillRect(0, top + 2, 3, top + rowHeight - 2)
        elseif record.Rank >= WARN_RANK then
            brush.Color = levelColor
            canvas.fillRect(0, top, 2, top + rowHeight)
        end
        brush.Color = background

        local textY = top + metrics.TextY
        if entry.First then
            local drawn = false
            local meta = self.Meta[level]
            if self.Icons and meta and meta.Icon then
                drawn = self.Icons:DrawOn(canvas, metrics.IconX, top + metrics.IconY,
                    meta.Icon, background)
            end
            if not drawn then
                -- No icon set. A filled square in the level colour still tells
                -- the levels apart at a glance.
                brush.Color = levelColor
                canvas.fillRect(metrics.IconX + 3, top + metrics.IconY + 3,
                    metrics.IconX + defaults.IconSize - 3,
                    top + metrics.IconY + defaults.IconSize - 3)
                brush.Color = background
            end
            if self.ShowStamp and metrics.StampW > 0 then
                font.Color = surface.Muted
                canvas.textOut(metrics.StampX, textY, Format.Prepare(record).Stamp)
            end
            font.Color = levelColor
            font.Style = "[fsBold]"
            canvas.textOut(metrics.TagX, textY, meta and meta.Tag or level:sub(1, 3))
            font.Style = emptyStyle
            if self.ShowChannel and metrics.ChannelW > 0 then
                font.Color = surface.Muted
                canvas.textOut(metrics.ChannelX, textY,
                    fit(record.Channel or "", metrics.ChannelW - defaults.PadX))
            end
        end

        -- The message. WARNING and above carry their colour into the text, the
        -- rest stay in the reading colour so a normal log is not a rainbow.
        local messageColor = surface.Text
        if record.Rank >= WARN_RANK or level == "SUCCESS" then messageColor = levelColor end
        if record.Suppressed then messageColor = surface.Muted end
        if entry.Kind == "trace" or entry.Kind == "fields" then messageColor = surface.Muted end

        local text = entry.Text
        local shown = self.Wrap and text or fit(text, messageW)
        -- Search highlights are painted underneath and the text goes over
        -- them, so a match reads as a background change rather than a second
        -- colour.
        if searchLower then
            local spans = matches(shown, searchLower)
            if #spans > 0 then
                brush.Color = surface.Match
                for index = 1, #spans, 2 do
                    local x0 = measure(shown:sub(1, spans[index] - 1))
                    local hit = measure(shown:sub(spans[index], spans[index + 1]))
                    canvas.fillRect(messageX + x0, top + 1, messageX + x0 + hit, top + rowHeight - 1)
                end
                brush.Color = background
            end
        end
        font.Color = messageColor
        canvas.textOut(messageX, textY, shown)

        -- Repeat and drop badges, right aligned against the scrollbar.
        if entry.First and ((record.Repeats or 1) > 1 or record.Dropped) then
            local badge
            if (record.Repeats or 1) > 1 then badge = "x" .. record.Repeats end
            if record.Dropped then
                badge = (badge and (badge .. " ") or "") .. "+" .. record.Dropped
            end
            local badgeWidth = measure(badge .. " ")
            local badgeX = listWidth - badgeWidth - 2
            brush.Color = background
            canvas.fillRect(badgeX - 4, top + 1, listWidth, top + rowHeight - 1)
            font.Color = surface.Accent
            font.Style = "[fsBold]"
            canvas.textOut(badgeX, textY, badge)
            font.Style = emptyStyle
        end
    end

    if count == 0 then
        brush.Color = surface.Background
        font.Color = surface.Muted
        canvas.textOut(messageX, math.floor(height / 2) - metrics.TextHeight,
            "Nothing to show. Lower the level, clear the filter, or wait for the first line.")
    end

    self:_PaintScrollbar(canvas, metrics, surface, count, visible)
    if present then present() end
end

--
--- ∑ The scrollbar, drawn rather than delegated to a native control, so it
---   follows the theme and the whole view stays one surface.
--- @return nil
--
function View:_PaintScrollbar(canvas, metrics, surface, count, visible)
    local x, width = metrics.ScrollX, metrics.ScrollW
    local brush = canvas.Brush
    brush.Color = surface.Scroll
    canvas.fillRect(x, 0, x + width, metrics.Height)
    local y, height = Layout.Thumb(self.Top, visible, count, metrics.Height)
    self.ThumbY, self.ThumbH = y, height
    if not y then return end
    brush.Color = self.Dragging and surface.ThumbHover or surface.Thumb
    canvas.fillRect(x + 2, y + 1, x + width - 2, y + height - 1)
end

--------------------------------------------------------
--                    Interaction                     --
--------------------------------------------------------

--- Modifier state, read from Cheat Engine rather than from the event. The
--- binding does not pass the shift-state argument through at all.
local function modifiers()
    local isKeyPressed = rawget(_G, "isKeyPressed")
    if type(isKeyPressed) ~= "function" then return false, false end
    local control, shift = false, false
    pcall(function() control = isKeyPressed(0x11) == true end) -- VK_CONTROL
    pcall(function() shift = isKeyPressed(0x10) == true end)   -- VK_SHIFT
    return control, shift
end

function View:MouseDown(button, x, y)
    local metrics = self.Metrics
    if not metrics or type(x) ~= "number" or type(y) ~= "number" then return end
    -- Right button: let the owner show its menu over whatever is under the
    -- cursor, without disturbing an existing multi-row selection.
    -- Cheat Engine passes the button as the TMouseButton ordinal on some
    -- builds and as the enum name on others. Both spellings are accepted.
    if button == 1 or button == "mbRight" then
        local row = Layout.RowAt(y, self.Top, metrics.RowHeight, #self.Rows)
        if row then
            local entry = self.Rows[row]
            if not self.Selection[entry.Record.Seq] then self:Select(row, "replace") end
            self.Hover = row
        end
        if self.OnContextMenu then pcall(self.OnContextMenu, x, y, self:FocusedRecord()) end
        return
    end
    if x >= metrics.ScrollX then
        local thumbY, thumbH = self.ThumbY, self.ThumbH
        if thumbY and y >= thumbY and y <= thumbY + thumbH then
            self.Dragging = true
            self.DragOffset = y - thumbY
            self:Redraw()
        else
            -- A click in the track pages towards the click, the way a native
            -- scrollbar does.
            self:ScrollBy(y < (thumbY or 0) and -self:VisibleRows() or self:VisibleRows())
        end
        return
    end
    local row = Layout.RowAt(y, self.Top, metrics.RowHeight, #self.Rows)
    if not row then
        self:ClearSelection()
        return
    end
    local control, shift = modifiers()
    self:Select(row, shift and "range" or (control and "toggle") or "replace")
end

function View:MouseUp()
    if self.Dragging then
        self.Dragging = false
        self:Redraw()
    end
end

function View:MouseMove(x, y)
    local metrics = self.Metrics
    if not metrics or type(y) ~= "number" then return end
    if self.Dragging then
        local top = Layout.TopForThumb(y - self.DragOffset, self.ThumbH or 24,
            metrics.Height, self:VisibleRows(), #self.Rows)
        self:ScrollTo(top)
        return
    end
    local row = Layout.RowAt(y, self.Top, metrics.RowHeight, #self.Rows)
    if row ~= self.Hover then
        self.Hover = row
        self:Redraw()
    end
end

function View:MouseLeave()
    if self.Hover then
        self.Hover = nil
        self:Redraw()
    end
end

function View:Activate()
    local record = self:FocusedRecord()
    if record and self.OnActivate then pcall(self.OnActivate, record) end
end

--
--- ∑ Keyboard handling, called by the owning window's OnKeyDown.
--- @param key number # Virtual key code.
--- @return boolean # Whether the key was consumed.
--
function View:HandleKey(key)
    local control = select(1, modifiers())
    if key == 38 then self:ScrollBy(-1) return true end          -- Up
    if key == 40 then self:ScrollBy(1) return true end           -- Down
    if key == 33 then self:PageUp() return true end              -- PageUp
    if key == 34 then self:PageDown() return true end            -- PageDown
    if key == 36 then self:ScrollTo(1) return true end           -- Home
    if key == 35 then self:SetFollow(true) return true end       -- End
    if key == 65 and control then self:SelectAll() return true end -- Ctrl+A
    if key == 27 then self:ClearSelection() return true end      -- Escape
    return false
end

function View:OnResize()
    self.Metrics = nil
    -- Only wrapping depends on the width, so a resize costs a re-measure and,
    -- in wrap mode alone, a rebuild.
    if self.Wrap then self.RowsDirty = true end
    if self.Follow then
        self:ScrollToEnd()
    else
        self:Redraw()
    end
end

--
--- ∑ Releases the bitmaps this view owns. The surface itself belongs to its
---   parent form and is freed with it.
--- @return nil
--
function View:Destroy()
    if self.Buffer then
        pcall(function() self.Buffer.destroy() end)
        self.Buffer = nil
    end
    self.Surface = nil
    -- Not destroyed: the bitmap belongs to the TImage's Picture, which the
    -- form frees along with the control.
    self.PictureBitmap = nil
    self.Rows = {}
    self.Records = {}
    self.BuiltCount = 0
end

return View
