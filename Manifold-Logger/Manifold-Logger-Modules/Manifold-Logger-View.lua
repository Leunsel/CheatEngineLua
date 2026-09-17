--[[
    The log view. A virtual, owner drawn list painted onto a canvas. A memo is
    one colour. A TListView can colour its rows through OnCustomDrawItem, but
    its selection bar and its header stay system drawn, so a themed window
    would still carry one bar in the system colours. Painting the list here
    means the canvas owns every pixel, which buys icons, per level hue,
    striping, a themed selection, search highlights and badges.

    Only on screen rows are touched. Rows are built incrementally. Arrivals
    append, records leaving the ring drop rows off the front, and a full
    rebuild happens only when the filter, the wrap mode or the font changed.
    A frame is one pcall, not one per drawing call. Five consecutive failures
    stop the view instead of filling Cheat Engine's log.

    Nothing paints inside a mouse event. A move, a click, a wheel notch and a
    key only change the state and mark the view dirty, and the owner's frame
    timer paints it a few milliseconds later. Painting inside OnMouseMove
    saturates the thread, because Cheat Engine delivers a move for every
    pixel. Flush is the call the timer makes.

    canvas.getTextWidth is a Win32 text extent call. The reference measurement
    that gives an average character width is only taken when a frame finds the
    metrics missing or the size changed, which is the first frame, a resize and
    any change that drops the metrics, such as a new font size, and again when
    a wider channel moves the columns. Every other frame reuses it, and a line
    is only measured for real near a column edge. In Consolas, which every
    Manifold window uses, the estimate is exact.

    textOut is opaque. It fills its own cell with the brush before the glyphs
    go down, so the brush decides what a piece of text sits on. A search hit
    is therefore drawn as a run of its own on the highlight brush, never as a
    band with the whole message typed over it, which would wipe the band out.
    Setting the brush style to bsClear would stop that, and would stop
    fillRect painting anything as well, so it is not a way out.

    The surface is probed, because Cheat Engine's control set varies by build.
    createPaintBox gives a TGraphicControl with a Canvas and OnPaint, blitted
    from an off screen bitmap. No script shipped with Cheat Engine 7.5 uses it,
    so it may not exist. createImage gives a TImage, as ceshare scripts do. Its
    Picture.Bitmap is already off screen, created by TPicture.GetBitmap on
    first access, and that is the live path. With neither, Attach returns false
    and the caller falls back to a themed memo.

    Cheat Engine's binding drops the LCL's Shift argument, so OnMouseDown
    arrives as (sender, button, x, y) and OnMouseMove as (sender, x, y).
    Coordinates are the last two numbers, correct under both. A TPaintBox and
    a TImage are TGraphicControls with no window handle, so WM_MOUSEWHEEL
    reaches the nearest windowed ancestor. The wheel handler goes on the
    surface and on the parent panel, and only on OnMouseWheelUp and Down.

    View.Layout is pure geometry over plain tables, testable without Cheat
    Engine.
]]

local Format = require("Manifold-Logger-Format")

local View = {}
View.__index = View

--- The rank of WARNING in Manifold-Logger-Core, copied rather than required.
--- The view renders records, whoever produced them, so it does not depend on
--- the log.
local WARN_RANK = 40

--------------------------------------------------------
--                    Pure geometry                   --
--------------------------------------------------------

local Layout = {}
View.Layout = Layout

--
--- ∑ Wraps one line so that no row it becomes is wider than width, indents
---   included.
---
---   The line's own leading space stays on its first row, and every
---   continuation carries that space and one indent more, so a wrapped line
---   reads as one paragraph rather than as new records. The continuations are
---   wrapped to the width their prefix leaves, which is what keeps them
---   inside the column. A prefix that would take more than half the width is
---   dropped, because a column that narrow has no room for it.
--- @param text string
--- @param width number
--- @param measure function # text to width, in the unit width is in.
--- @param indent string
--- @return table # The texts of the rows, one at least.
--
function Layout.WrapLine(text, width, measure, indent)
    if width <= 0 or measure(text) <= width then return { text } end
    local space = text:match("^%s*")
    local body = text:sub(#space + 1)
    local lead = space
    if measure(lead) > width / 2 then lead = "" end
    local pieces = Format.Wrap(body, width - measure(lead), measure)
    local out = { lead .. pieces[1] }
    if #pieces == 1 then return out end
    local prefix = lead .. (indent or "")
    if measure(prefix) > width / 2 then prefix = "" end
    -- Format.Wrap keeps every character of a line that starts with one, so
    -- the first piece is a prefix of the body and the rest follows it.
    local rest = body:sub(#pieces[1] + 1)
    for _, piece in ipairs(Format.Wrap(rest, width - measure(prefix), measure)) do
        out[#out + 1] = prefix .. piece
    end
    return out
end

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
            for _, piece in ipairs(Layout.WrapLine(text, width, measure, indent)) do
                push(piece, first, "message")
                first = false
            end
        else
            push(text, first, "message")
            first = false
        end
    end
    -- Fields and traceback lines wrap the same way in wrap mode, since a
    -- wrapped row is drawn as it is and never cut.
    local function extra(text, kind)
        if wrapping then
            for _, piece in ipairs(Layout.WrapLine(text, width, measure, indent)) do
                push(piece, false, kind)
            end
        else
            push(text, false, kind)
        end
    end
    if options.ShowFields and prepared.Fields ~= "" then
        extra(indent .. prepared.Fields, "fields")
    end
    if options.ShowTrace and record.Trace then
        for _, line in ipairs(Format.Lines(record.Trace)) do
            extra(indent .. line, "trace")
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
--- ∑ How much width the scrollbar takes from the rows.
---
---   A list that fits has no scrollbar, so its rows run to the right edge and
---   a click there lands on a row. The answer comes from the rows there are
---   and the rows the height holds, never from the last frame, and the strip
---   takes width and never height. Reserving it therefore cannot change how
---   many rows fit, and the answer cannot flip between two frames.
--- @param count number # Rows in total.
--- @param visible number # Rows that fit.
--- @param width number|nil # The strip's width, the default scrollbar width unless given.
--- @return number # Pixels to keep free at the right edge.
--
function Layout.Strip(count, visible, width)
    if (tonumber(count) or 0) > (tonumber(visible) or 0) then
        return width or View.Defaults.ScrollWidth
    end
    return 0
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

--
--- ∑ Where a search needle occurs in a piece of text, as pairs of one based
---   start and stop offsets.
---
---   Bounded, because a single character search over a long line would
---   otherwise produce hundreds of highlights. A hit that runs past limit is
---   cut there, which is how the ellipsis of a cut line stays unhighlighted.
--- @param text string
--- @param needle string|nil # Already lowercase.
--- @param limit number|nil # The last offset a hit may cover, the whole text unless given.
--- @return table # { { start, stop }, ... }
--
function Layout.Spans(text, needle, limit)
    local out = {}
    if type(text) ~= "string" or type(needle) ~= "string" or needle == "" then return out end
    limit = math.min(#text, tonumber(limit) or #text)
    local haystack = text:lower()
    local from = 1
    while #out < View.Defaults.MaxMatches do
        local start, stop = haystack:find(needle, from, true)
        if not start or start > limit then break end
        out[#out + 1] = { start, math.min(stop, limit) }
        from = stop + 1
    end
    return out
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
    --- Search highlights drawn per row.
    MaxMatches  = 8,
    --- Consecutive paint failures before giving up.
    MaxFailures = 5,
    --- The contrast a colour keeps against a selected or hovered row and
    --- against a search hit, as the ratio WCAG measures. Four and a half to
    --- one is what it asks of text this size. The ERROR hue sat at two to one
    --- on a selection and a muted stamp at two and a half.
    ReadableRatio = 4.5,
    --- Where the lift starts and how much stricter each round asks the theme's
    --- Contrast to be, in luma. Seventy is what Contrast asks for when it is
    --- given nothing, and ten more a round reaches the ratio without
    --- overshooting it.
    ContrastStart = 70,
    ContrastStep = 10,
    --- The empty state, used until the owner says something better through
    --- SetEmpty.
    EmptyTitle = "Nothing to show",
    EmptyHint = "Lower the level, clear the filter, or wait for the first line."
}

--
--- ∑ Colours for a view whose theme has none to give, or leaves some out.
---   Only the tests, a broken install and a theme from another version ever
---   see them, and they exist so the painter can index the table without
---   checking every key first. They are the Address List's own fallback.
--
View.Fallback = {
    Background = 0x1B1B1B, Stripe = 0x222222, Hover = 0x2E2E2E,
    Selection = 0x4A3B25, SelectionText = 0xE8E8E8, Gutter = 0x202020,
    Rule = 0x333333, Text = 0xE8E8E8, Muted = 0x9A9A9A, Accent = 0xD8A24A,
    Match = 0x5A4A2A, Scroll = 0x202020, Thumb = 0x3A3A3A, ThumbHover = 0xD8A24A,
    Error = 0x5C5CFF, Warning = 0x3DB8FF, Info = 0x9A9A9A,
    Check = 0xD8A24A, CheckBorder = 0x4A4A4A, Header = 0x272727, Focus = 0xD8A24A
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
        Kind     = nil,      -- paintbox or image
        Buffer   = nil,      -- off screen bitmap, paint box path only
        Parent   = nil,
        Reason   = nil,
        Disabled = false,

        Records  = {},       -- the owner's array, held by reference
        Rows     = {},
        BuiltCount = 0,      -- records already expanded into Rows
        FirstSeq = nil,      -- Seq of Records[1] when the rows were built
        RowsDirty= true,
        PendingFrom = nil,   -- first record index still to be expanded

        ChannelWidths = {},  -- channel name to measured pixels
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
        EmptyTitle = View.Defaults.EmptyTitle,
        EmptyHint  = View.Defaults.EmptyHint,

        Selection = {},      -- record Seq to true
        Anchor    = nil,     -- row index a shift click ranges from
        AnchorSeq = nil,     -- the record the anchor was set on
        Current   = nil,     -- row index the last click landed on
        CurrentSeq = nil,    -- the record that click landed on
        Hover     = nil,     -- row index under the cursor
        MouseX    = nil,     -- where the cursor was last seen, nil once it left
        MouseY    = nil,
        ScrollHover = false, -- the cursor is on the scrollbar thumb
        HintText  = nil,     -- what OnHint was last told
        Dragging  = false,   -- scrollbar thumb drag in progress
        DragOffset= 0,
        Strip     = 0,       -- the scrollbar width the last frame reserved

        Metrics  = nil,      -- computed on the first paint
        CachedPalette = nil, -- the palette the derived colours were built from
        SurfaceColors = nil,
        LevelColors = nil,
        LegibleCache = nil,  -- lifted colours, per row tone, see Legible
        LegibleFor = nil,    -- the colour table that cache belongs to
        CharWidth = 0,       -- average, for the cheap width estimate
        EmptyStyle = nil,    -- probed once, see _Frame
        Dirty    = true,
        Painting = false,
        PaintFailures = 0,

        OnActivate = nil,
        OnSelectionChanged = nil,
        OnContextMenu = nil,
        OnFollowChanged = nil,
        --- Called with a sentence about the row under the cursor, or nil when
        --- there is nothing to say. See HintFor.
        OnHint = nil,
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
            pcall(self.OnError, name .. " failed, " .. tostring(result))
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
    -- falls through to DoMouseWheelUp and Down only when it did not report
    -- the event handled, so setting both scrolls twice a notch where Handled
    -- is dropped on the way out of Lua.
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
    -- The paint box path from here on.
    local create = rawget(_G, "createBitmap")
    if type(create) ~= "function" then return nil end
    -- Grow only. A resize drag delivers a new size on every WM_SIZE, and
    -- rebuilding a GDI bitmap of the whole client area each time is the
    -- costliest part of a resize. A buffer larger than the control is
    -- harmless, the blit starts at the origin and the control clips the rest.
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
---   append stays an append instead of a fresh snapshot. Three cases, the
---   cheapest first. When the front moved, records fell out of the ring and
---   their rows are dropped. When the tail grew, only the new records are
---   expanded. Anything else is a rebuild.
--- @param records table
--- @param full boolean|nil # Force a rebuild, because the filter, the wrap mode or the font changed.
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
    if self.Current then self.Current = math.max(1, self.Current - drop) end
    if self.Hover then self.Hover = math.max(1, self.Hover - drop) end
end

--
--- ∑ Expands records from the given index to the end into rows.
---   measure is only needed in wrap mode, so the non wrapping path never
---   touches the canvas at all.
--- @param from number
--- @param measure function|nil
--- @return nil
--
function View:BuildFrom(from, measure)
    local records, rows = self.Records, self.Rows
    local options = {
        Wrap = self.Wrap,
        -- MessageW always keeps the scrollbar's column, so how a line wraps
        -- never depends on whether the list scrolls.
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

--
--- ∑ The first row of the record with this Seq, or of the first record after
---   it when that one is gone, or nil.
--- @param seq number
--- @return number|nil
--
function View:RowOfSeq(seq)
    if type(seq) ~= "number" then return nil end
    local rows = self.Rows
    for index = 1, #rows do
        if rows[index].Record.Seq == seq then return index end
    end
    for index = 1, #rows do
        if (tonumber(rows[index].Record.Seq) or 0) > seq then return index end
    end
    return nil
end

--
--- ∑ Throws every row away and expands the whole list again.
---
---   A rebuild renumbers the rows, so the three row indices the view keeps
---   are carried across by their records. The record at the top stays at the
---   top of a list somebody scrolled away from the tail, a shift click still
---   ranges from the record it was anchored on, and the record the last click
---   landed on is still found by its row. A following list is pinned to its
---   tail by the frame anyway.
--- @param measure function|nil
--- @return nil
--
function View:RebuildRows(measure)
    -- The new first row of a record, or nothing when the record is gone.
    local function rowOf(seq)
        if seq == nil then return nil end
        local row = self:RowOfSeq(seq)
        local entry = row and self.Rows[row]
        return (entry and entry.Record.Seq == seq) and row or nil
    end
    local topEntry = (not self.Follow) and self.Rows[self.Top] or nil
    local topSeq = topEntry and topEntry.Record.Seq or nil
    self.Rows = {}
    self.BuiltCount = 0
    self.FirstSeq = self.Records[1] and self.Records[1].Seq or nil
    self.ChannelWidth = 0
    for _, width in pairs(self.ChannelWidths) do
        if width > self.ChannelWidth then self.ChannelWidth = width end
    end
    self:BuildFrom(1, measure)
    if topSeq ~= nil then self.Top = self:RowOfSeq(topSeq) or self.Top end
    if self.AnchorSeq ~= nil then self.Anchor = rowOf(self.AnchorSeq) end
    if self.CurrentSeq ~= nil then self.Current = rowOf(self.CurrentSeq) end
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

--
--- ∑ The text to highlight. Matching ignores case.
--- @param text string|nil # Nothing or an empty string clears it.
--- @return nil
--
function View:SetSearch(text)
    self.Search = (type(text) == "string" and text ~= "") and text or nil
    self.SearchLower = self.Search and self.Search:lower() or nil
    self:Invalidate()
end

--
--- ∑ What the view says when it has no rows. The owner knows why, an empty
---   buffer or a filter that hides everything, and the view does not.
--- @param title string|nil # The bold first line.
--- @param hint string|nil # The muted second line.
--- @return boolean # Whether anything changed.
--
function View:SetEmpty(title, hint)
    title = title ~= nil and tostring(title) or nil
    hint = hint ~= nil and tostring(hint) or nil
    if title == self.EmptyTitle and hint == self.EmptyHint then return false end
    self.EmptyTitle, self.EmptyHint = title, hint
    self:Invalidate()
    return true
end

--- Everything that changes how a row is SHAPED forces a rebuild. Everything
--- that only changes how it is PAINTED does not.
local function reshape(self)
    self.RowsDirty = true
    self.Metrics = nil
    self:Invalidate()
end

function View:SetWrap(value)
    self.Wrap = value == true
    reshape(self)
end

function View:SetShowChannel(value)
    self.ShowChannel = value == true
    self.Metrics = nil
    if self.Wrap then self.RowsDirty = true end
    self:Invalidate()
end

function View:SetShowStamp(value)
    self.ShowStamp = value == true
    self.Metrics = nil
    if self.Wrap then self.RowsDirty = true end
    self:Invalidate()
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
--- ∑ Turns tail following on or off, telling the owner so a toolbar toggle
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
--- ∑ Scrolls to a row and asks for a frame. The owner's frame timer paints it
---   within one tick, so a wheel notch still shows at once.
--- @param top number
--- @param keepFollow boolean|nil
--- @return boolean # Whether the position moved.
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
    self:Invalidate()
    return true
end

function View:ScrollBy(rows)
    return self:ScrollTo(self.Top + rows)
end

function View:ScrollToEnd()
    self.Top = Layout.Bottom(self:VisibleRows(), self:RowCount())
    self:Invalidate()
    return true
end

function View:PageDown() return self:ScrollBy(self:VisibleRows() - 1) end
function View:PageUp() return self:ScrollBy(-(self:VisibleRows() - 1)) end

--------------------------------------------------------
--                      Selection                     --
--------------------------------------------------------

function View:ClearSelection()
    self.Selection = {}
    self.Anchor, self.AnchorSeq = nil, nil
    self.Current, self.CurrentSeq = nil, nil
    self:Invalidate()
    if self.OnSelectionChanged then pcall(self.OnSelectionChanged) end
end

--- Whether any record is selected.
function View:HasSelection()
    return next(self.Selection) ~= nil
end

--
--- ∑ Selects one row's record, or extends or toggles the selection.
---
---   Whatever the mode, the row the click landed on becomes the current one,
---   because that is the record the person means, and the detail card shows
---   it, see SelectedRecord. A range leaves the anchor where it was, so the
---   next shift click still ranges from the same record.
--- @param row number
--- @param mode string|nil # replace, the default, or toggle, or range.
--- @return nil
--
function View:Select(row, mode)
    local entry = self.Rows[row]
    if not entry then return end
    local seq = entry.Record.Seq
    mode = mode or "replace"
    if mode == "replace" then
        self.Selection = { [seq] = true }
        self.Anchor, self.AnchorSeq = row, seq
    elseif mode == "toggle" then
        self.Selection[seq] = not self.Selection[seq] or nil
        self.Anchor, self.AnchorSeq = row, seq
    elseif mode == "range" then
        local from = self.Anchor or row
        local first, last = math.min(from, row), math.max(from, row)
        self.Selection = {}
        for index = first, last do
            local candidate = self.Rows[index]
            if candidate then self.Selection[candidate.Record.Seq] = true end
        end
    end
    self.Current, self.CurrentSeq = row, seq
    self:Invalidate()
    if self.OnSelectionChanged then pcall(self.OnSelectionChanged) end
end

function View:SelectAll()
    self.Selection = {}
    for _, record in ipairs(self.Records) do self.Selection[record.Seq] = true end
    self:Invalidate()
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

--
--- ∑ The record a context menu acts on. The one under the cursor, or the
---   first selected one.
--- @return table|nil
--
function View:FocusedRecord()
    local entry = self.Hover and self.Rows[self.Hover]
    if entry then return entry.Record end
    local selected = self:SelectedRecords()
    return selected[1]
end

--
--- ∑ The record a detail pane shows. The one the last click landed on, a
---   shift click included, while it is still selected, otherwise the first
---   selected one. A ctrl click that takes a record out of the selection
---   therefore never leaves the pane on that record.
---
---   The cursor never moves it. A pane that followed the hovered row would
---   jump to whatever the mouse rests on while records scroll past under it.
--- @return table|nil
--
function View:SelectedRecord()
    local seq = self.CurrentSeq
    if seq ~= nil and self.Selection[seq] then
        -- Current is a row index, and a rebuild renumbers the rows, so it is
        -- only trusted while it still points at the same record.
        local entry = self.Current and self.Rows[self.Current]
        if entry and entry.Record.Seq == seq then return entry.Record end
        for _, record in ipairs(self.Records) do
            if record.Seq == seq then return record end
        end
    end
    local records = self.Records
    for index = 1, #records do
        if self.Selection[records[index].Seq] then return records[index] end
    end
    return nil
end

--------------------------------------------------------
--                       Metrics                      --
--------------------------------------------------------

--
--- ∑ Column geometry, measured against the real font.
---
---   Four measurements, not one per record. The timestamp and the level tag
---   are fixed width strings, the channel column comes from the widths cached
---   per distinct channel name, and CharWidth is the reference the row loop
---   tests a line against before measuring it.
---
---   ScrollX, ListWidth and MessageW all keep the scrollbar's column, whether
---   or not the list scrolls. Wrapping measures against MessageW, so a row
---   count never depends on the strip. Whether the strip is really there is
---   decided per frame, see Layout.Strip.
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
--                       Colours                      --
--------------------------------------------------------

--- The palette a theme that cannot give one stands for. One table, so a
--- broken theme does not look like a new palette on every frame.
local NO_PALETTE = {}

--- A colour table with every key the painter reads. What the theme gave wins
--- and the fallback fills the gaps, so a theme from another version can
--- neither raise nor paint a key as black.
local function withFallback(colors)
    local out = {}
    if type(colors) == "table" then
        for key, value in pairs(colors) do out[key] = value end
    end
    for key, value in pairs(View.Fallback) do
        if type(out[key]) ~= "number" then out[key] = value end
    end
    return out
end

--
--- ∑ The palette and everything derived from it, recomputed only when the
---   theme actually moved.
---
---   The theme's Surface derives a dozen colours and its LevelColors runs a
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
    if not theme then
        if not self.SurfaceColors then
            self.SurfaceColors, self.LevelColors = withFallback(nil), {}
        end
        return {}, self.SurfaceColors, self.LevelColors
    end
    -- GetPalette caches against the design theme's own identity, so a
    -- changed palette is a changed table. Comparing the reference is both the
    -- cheapest check and the exact one.
    local okPalette, palette = pcall(theme.GetPalette, theme)
    if not okPalette or type(palette) ~= "table" then palette = self.CachedPalette or NO_PALETTE end
    if palette ~= self.CachedPalette or not self.SurfaceColors then
        self.CachedPalette = palette
        local okSurface, colors = pcall(theme.Surface, theme, palette)
        self.SurfaceColors = withFallback(okSurface and colors or nil)
        local okLevels, levels = pcall(theme.LevelColors, theme, palette)
        self.LevelColors = (okLevels and type(levels) == "table") and levels or {}
        if self.Icons then pcall(self.Icons.Invalidate, self.Icons) end
    end
    return palette, self.SurfaceColors, self.LevelColors
end

--- One channel of a colour as the light it gives off, the way sRGB defines
--- it, from a byte of nought to two hundred and fifty five.
local function linear(byte)
    local value = byte / 255
    if value <= 0.03928 then return value / 12.92 end
    return ((value + 0.055) / 1.055) ^ 2.4
end

--- The relative luminance of a Cheat Engine colour. The low byte is red and
--- the high byte blue, and each weight only means something on the channel
--- it was measured for.
local function luminance(color)
    color = math.floor(tonumber(color) or 0) % 0x1000000
    local red = color % 256
    local green = math.floor(color / 256) % 256
    local blue = math.floor(color / 65536) % 256
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
end

--
--- ∑ How far apart two colours are to the eye, as the contrast ratio WCAG
---   measures. One is no difference at all and twenty one is black on white.
--- @param first number
--- @param second number
--- @return number
--
function View.Ratio(first, second)
    local a, b = luminance(first), luminance(second)
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
end

--
--- ∑ A colour that can be read on the tone it is drawn over.
---
---   A level hue and the muted colour are picked to read on the plain rows. A
---   selected row leans towards the accent and a hovered one towards white,
---   so the same colour can land at two to one there, which nobody can read.
---   It goes through the theme's Contrast against that tone, asking for a
---   little more distance each round until the measured ratio holds or the
---   colour cannot move any further. A colour that already reads comes back
---   as it is.
---
---   Remembered per colour table, because a frame asks for the same handful
---   of pairs on every row and a new palette is the only thing that changes
---   the answers. A view with no theme, a colour that is not a plain blue
---   green red triple and a theme whose Contrast raises all hand the colour
---   back untouched.
--- @param color number
--- @param background number # The tone of the row or of the highlight.
--- @return number
--
function View:Legible(color, background)
    if type(color) ~= "number" or type(background) ~= "number" then return color end
    if color < 0 or color > 0xFFFFFF or background < 0 or background > 0xFFFFFF then
        return color
    end
    if self.LegibleCache == nil or self.LegibleFor ~= self.SurfaceColors then
        self.LegibleCache, self.LegibleFor = {}, self.SurfaceColors
    end
    local known = self.LegibleCache[background]
    if known == nil then
        known = {}
        self.LegibleCache[background] = known
    end
    local answer = known[color]
    if answer ~= nil then return answer end

    answer = color
    local theme = self.Theme
    local contrast = nil
    if theme ~= nil then
        local ok, found = pcall(function() return theme.Contrast end)
        if ok and type(found) == "function" then contrast = found end
    end
    local defaults = View.Defaults
    local best = View.Ratio(color, background)
    if contrast ~= nil and best < defaults.ReadableRatio then
        local minimum = defaults.ContrastStart
        local broken = false
        while minimum <= 255 do
            local ok, value = pcall(contrast, color, background, minimum)
            if not ok or type(value) ~= "number" then
                broken = true
                break
            end
            local ratio = View.Ratio(value, background)
            -- The best one so far, because a colour that starts on the wrong
            -- side of a middle tone passes through the background on its way.
            if ratio > best then answer, best = value, ratio end
            if best >= defaults.ReadableRatio then break end
            minimum = minimum + defaults.ContrastStep
        end
        -- The theme's Contrast stops a fifth of the way short of white or
        -- black, which a middle tone such as the search highlight can need
        -- the rest of. Plain white or black is the last resort, whichever
        -- reads better.
        if not broken and best < defaults.ReadableRatio then
            for _, extreme in ipairs({ 0xFFFFFF, 0x000000 }) do
                local ratio = View.Ratio(extreme, background)
                if ratio > best then answer, best = extreme, ratio end
            end
        end
    end
    known[color] = answer
    return answer
end

--------------------------------------------------------
--                      Painting                      --
--------------------------------------------------------

--
--- ∑ Asks for a frame. Record arrival, a click, a wheel notch and a mouse
---   move all come through here, and the owner's timer paints them, so a
---   burst costs one frame.
--- @return nil
--
function View:Invalidate()
    self.Dirty = true
end

--
--- ∑ Paints when something asked for a frame, and does nothing otherwise.
---   This is what the owner's frame timer calls.
--- @return boolean # Whether a frame was painted.
--
function View:Flush()
    if not self.Dirty then return false end
    return self:Redraw()
end

--
--- ∑ Renders a frame now. One protected call for the whole frame, not one per
---   drawing operation. An API mismatch fails on every frame anyway, so a
---   guard per call would only repeat the same report on every row.
---
---   The dirty flag drops before the frame, so a frame that asks for another
---   one, a re-wrap after a wider channel arrived, gets it.
--- @return boolean
--
function View:Redraw()
    if not self.Surface or self.Painting or self.Disabled then return false end
    self.Painting = true
    self.Dirty = false
    local ok, err = pcall(self._Frame, self)
    self.Painting = false
    if ok then
        self.PaintFailures = 0
        self:SyncHint()
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

--
--- ∑ Cuts a string to fit a pixel width, appending an ellipsis. The estimate
---   short circuits the common case. At Consolas it is exact, and at a
---   proportional font it only measures when the line is near the edge.
--- @param text string
--- @param limit number
--- @param charWidth number # The average character width of the frame.
--- @param measure function # The frame's text width.
--- @return string
--
local function fitText(text, limit, charWidth, measure)
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

--- A colour lifted against the row tone, on the two rows whose tone the
--- colour was not picked for.
local function onRow(self, color, background, lifted)
    if lifted then return self:Legible(color, background) end
    return color
end

--- The badge a record's first row carries, or nil.
local function badgeOf(record)
    local badge = nil
    if (record.Repeats or 1) > 1 then badge = "x" .. record.Repeats end
    if record.Dropped then
        badge = (badge and (badge .. " ") or "") .. "+" .. record.Dropped
    end
    return badge
end

--
--- ∑ Draws a message with its search hits.
---
---   The hits are filled first, from a pixel under the row's top to a pixel
---   over its bottom, so a hit reads as a band and not as a strip the
---   height of the glyphs. Then the text goes down in runs, and the brush
---   is switched to the highlight for every hit. The opaque cell of a hit
---   run therefore carries the band's own colour, and the cell of a plain
---   run the row's, so neither wipes the other out. Each run starts where
---   the text before it ends when measured as one piece, so a run and its
---   band always line up.
---
---   The brush and the font colour are left on the row's.
--- @param ctx table # The frame, see _Frame.
--- @param x number
--- @param top number # The row's top edge.
--- @param text string
--- @param spans table # From Layout.Spans.
--- @param background number
--- @param color number # The message colour.
--- @param hitColor number # The message colour on the highlight.
--- @return nil
--
local function paintHits(ctx, x, top, text, spans, background, color, hitColor)
    local canvas, brush, font, measure = ctx.Canvas, ctx.Brush, ctx.Font, ctx.Measure
    local highlight = ctx.Colors.Match
    local textY = top + ctx.Metrics.TextY
    local right = ctx.RowRight

    local edges = {}
    brush.Color = highlight
    for index = 1, #spans do
        local start, stop = spans[index][1], spans[index][2]
        local left = x + measure(text:sub(1, start - 1))
        local finish = x + measure(text:sub(1, stop))
        edges[index] = { left, finish }
        if left < right then
            canvas.fillRect(left, top + 1, math.min(right, finish), top + ctx.Metrics.RowHeight - 1)
        end
    end

    local cursor, cursorX = 1, x
    for index = 1, #spans do
        local start, stop = spans[index][1], spans[index][2]
        if start > cursor then
            brush.Color = background
            font.Color = color
            canvas.textOut(cursorX, textY, text:sub(cursor, start - 1))
        end
        brush.Color = highlight
        font.Color = hitColor
        canvas.textOut(edges[index][1], textY, text:sub(start, stop))
        cursor, cursorX = stop + 1, edges[index][2]
    end
    brush.Color = background
    font.Color = color
    if cursor <= #text then
        canvas.textOut(cursorX, textY, text:sub(cursor))
    end
end

--
--- ∑ Paints one row.
--- @param ctx table # The frame, see _Frame.
--- @param row number
--- @return nil
--
function View:_PaintRow(ctx, row)
    local canvas, brush, font = ctx.Canvas, ctx.Brush, ctx.Font
    local metrics, surface, defaults = ctx.Metrics, ctx.Colors, View.Defaults
    local rowHeight, rowRight = metrics.RowHeight, ctx.RowRight
    local entry = self.Rows[row]
    local record = entry.Record
    local top = (row - self.Top) * rowHeight
    local level = record.Level
    local rank = tonumber(record.Rank) or 0
    local levelColor = ctx.LevelColors[level] or surface.Text

    -- Row background. Selection wins over hover, hover over the stripe.
    -- Striping reads Seq, not a list position, so records leaving the ring
    -- cannot renumber every row that is left. The colours on a selected or a
    -- hovered row are lifted against its tone, because they were picked for
    -- the plain rows.
    -- Hover lights the whole record the way a selection does, every wrapped
    -- piece and every field and traceback row of it, because a click on any
    -- of those rows picks that record. Lighting only the row under the
    -- cursor showed a third of a wrapped line as the thing a click takes.
    local selected = self.Selection[record.Seq] == true
    local hovered = self.Hover and self.Rows[self.Hover]
    local background, lifted = surface.Background, false
    if selected then
        background, lifted = surface.Selection, true
    elseif hovered and hovered.Record == record then
        background, lifted = surface.Hover, true
    elseif (tonumber(record.Seq) or 0) % 2 == 0 then
        background = surface.Stripe
    end
    brush.Color = background
    canvas.fillRect(0, top, rowRight, top + rowHeight)

    -- Pin marker in the gutter, and a level coloured edge for anything at
    -- WARNING or above, so a problem is findable by peripheral vision while
    -- scrolling past.
    if record.Pinned then
        brush.Color = onRow(self, surface.Accent, background, lifted)
        canvas.fillRect(0, top + 2, 3, top + rowHeight - 2)
    elseif rank >= WARN_RANK then
        brush.Color = onRow(self, levelColor, background, lifted)
        canvas.fillRect(0, top, 2, top + rowHeight)
    end
    brush.Color = background

    local textY = top + metrics.TextY
    local emptyStyle = ctx.EmptyStyle
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
            brush.Color = onRow(self, levelColor, background, lifted)
            canvas.fillRect(metrics.IconX + 3, top + metrics.IconY + 3,
                metrics.IconX + defaults.IconSize - 3,
                top + metrics.IconY + defaults.IconSize - 3)
            brush.Color = background
        end
        if self.ShowStamp and metrics.StampW > 0 then
            font.Color = onRow(self, surface.Muted, background, lifted)
            canvas.textOut(metrics.StampX, textY, Format.Prepare(record).Stamp)
        end
        font.Color = onRow(self, levelColor, background, lifted)
        font.Style = "[fsBold]"
        canvas.textOut(metrics.TagX, textY, meta and meta.Tag or tostring(level or ""):sub(1, 3))
        font.Style = emptyStyle
        entry.ChannelCut = false
        if self.ShowChannel and metrics.ChannelW > 0 then
            local channel = record.Channel or ""
            local shownChannel = ctx.Fit(channel, metrics.ChannelW - defaults.PadX)
            entry.ChannelCut = shownChannel ~= channel
            font.Color = onRow(self, surface.Muted, background, lifted)
            canvas.textOut(metrics.ChannelX, textY, shownChannel)
        end
    end

    -- The message. WARNING and above, and SUCCESS, carry their colour into the
    -- text. The rest stay in the reading colour so a normal log is not a
    -- rainbow.
    local messageColor = selected and surface.SelectionText or surface.Text
    if rank >= WARN_RANK or level == "SUCCESS" then messageColor = levelColor end
    if record.Suppressed then messageColor = surface.Muted end
    if entry.Kind == "trace" or entry.Kind == "fields" then messageColor = surface.Muted end

    -- The badge is worked out first, because the message has to end before
    -- it. A message cut by the badge fill would lose its tail with no dots.
    local badge = entry.First and badgeOf(record) or nil
    local messageX = metrics.MessageX
    local limit = ctx.MessageW
    local badgeX, badgeWidth = nil, 0
    if badge then
        badgeWidth = ctx.Measure(badge .. " ")
        badgeX = rowRight - badgeWidth - 2
        limit = limit - badgeWidth - 4
    end

    local text = entry.Text
    local shown
    if self.Wrap and not badge then
        -- Wrapped rows were built to fit already.
        shown = text
    else
        shown = ctx.Fit(text, limit)
    end
    entry.Cut = shown ~= text

    local spans = nil
    if ctx.SearchLower then
        local reach = entry.Cut and (#shown - 3) or #shown
        spans = Layout.Spans(shown, ctx.SearchLower, reach)
        if #spans == 0 then spans = nil end
    end
    if spans then
        paintHits(ctx, messageX, top, shown, spans, background,
            onRow(self, messageColor, background, lifted),
            self:Legible(messageColor, surface.Match))
    else
        font.Color = onRow(self, messageColor, background, lifted)
        canvas.textOut(messageX, textY, shown)
    end

    -- Repeat and drop badges, right aligned against the scrollbar or the
    -- edge. The fill is a guard for a column too narrow to hold both.
    if badge then
        brush.Color = background
        canvas.fillRect(badgeX - 4, top + 1, rowRight, top + rowHeight - 1)
        font.Color = onRow(self, surface.Accent, background, lifted)
        font.Style = "[fsBold]"
        canvas.textOut(badgeX, textY, badge)
        font.Style = emptyStyle
    end
end

--
--- ∑ The empty state. Two lines centred in the view, a bold title in the
---   reading colour and a hint in the muted one, each cut to the width with
---   an ellipsis. The brush is the background, because textOut fills its cell
---   with it, and the font colour and style are put back afterwards.
--- @param ctx table # The frame, see _Frame.
--- @return nil
--
function View:_PaintEmpty(ctx)
    local canvas, brush, font = ctx.Canvas, ctx.Brush, ctx.Font
    local width, height = ctx.Width, ctx.Height
    local rowHeight = ctx.Metrics.RowHeight
    local room = math.max(0, width - 2 * View.Defaults.PadX)
    local wasColor, wasStyle = font.Color, font.Style
    brush.Color = ctx.Colors.Background
    local function centred(text, y)
        -- Fitted under the font it is drawn in, so a bold title is measured
        -- bold.
        local shown = ctx.Fit(text, room)
        if shown == "" then return end
        local measured = ctx.Measure(shown)
        canvas.textOut(math.max(0, math.floor((width - measured) / 2)), y, shown)
    end
    local y = math.max(0, math.floor(height / 2) - rowHeight)
    local title, hint = self.EmptyTitle, self.EmptyHint
    if title and title ~= "" then
        font.Style = "[fsBold]"
        font.Color = ctx.Colors.Text
        centred(title, y)
        font.Style = ctx.EmptyStyle
    end
    if hint and hint ~= "" then
        font.Color = ctx.Colors.Muted
        centred(hint, y + rowHeight)
    end
    if wasColor ~= nil then font.Color = wasColor end
    if wasStyle ~= nil then font.Style = wasStyle end
end

function View:_Frame()
    local width, height = self:Size()
    local canvas, present = self:AcquireCanvas(width, height)
    if not canvas then return end

    local theme = self.Theme
    local _, surface, levelColors = self:Colors()
    local defaults = View.Defaults

    -- Font and Brush are read once a frame and handed on. Every read of a
    -- canvas property builds a fresh wrapper in Cheat Engine.
    local font = canvas.Font
    local brush = canvas.Brush

    -- The empty font style is probed once. "[]" is the empty set, which a
    -- Lazarus style property expects, but a build whose binding takes the
    -- value as a plain string rejects it, and a raise here kills every frame.
    if self.EmptyStyle == nil then
        self.EmptyStyle = pcall(function() font.Style = "[]" end) and "[]" or ""
    end
    local emptyStyle = self.EmptyStyle

    font.Name = theme and theme.FontName or "Consolas"
    font.Size = self.FontSize
    font.Style = emptyStyle

    -- Metrics depend on the font, which was only just applied, and on the
    -- size, which changes with the window.
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
    elseif self.PendingFrom then
        self:BuildFrom(self.PendingFrom, measure)
        self.PendingFrom = nil
    end
    if self.ChannelWidth ~= channelBefore then
        -- A new, wider channel moves the columns. Re-measure now and, in wrap
        -- mode, wrap again in this same frame, so no frame shows rows wrapped
        -- for a column that is no longer there. The second build finds every
        -- channel already measured, so the width cannot move again.
        self.Metrics = self:Measure(canvas, width, height)
        metrics = self.Metrics
        if self.Wrap then self:RebuildRows(measure) end
    end

    local rows = self.Rows
    local count = #rows
    local visible = self:VisibleRows()
    -- Following means the newest row is in view, whatever moved since the
    -- last frame, an arrival, a resize or a font change.
    if self.Follow then self.Top = Layout.Bottom(visible, count) end
    self.Top = Layout.Clamp(self.Top, visible, count)

    local strip = Layout.Strip(count, visible, defaults.ScrollWidth)
    self.Strip = strip
    local rowRight = width - strip

    -- The row under a cursor that did not move can still change, when the
    -- list scrolled or records arrived, so it is found again from where the
    -- cursor was last seen.
    if self.MouseY ~= nil and not self.Dragging then
        local onStrip = strip > 0 and type(self.MouseX) == "number" and self.MouseX >= rowRight
        self.Hover = (not onStrip) and Layout.RowAt(self.MouseY, self.Top, metrics.RowHeight, count) or nil
    end

    brush.Color = surface.Background
    canvas.fillRect(0, 0, width, height)

    local charWidth = self.CharWidth
    local ctx = {
        Canvas = canvas, Brush = brush, Font = font,
        Metrics = metrics, Colors = surface, LevelColors = levelColors,
        EmptyStyle = emptyStyle, Measure = measure,
        Width = width, Height = height, RowRight = rowRight,
        -- The message ends a pad before the strip, or before the edge when
        -- there is no strip.
        MessageW = math.max(40, rowRight - defaults.PadX - metrics.MessageX),
        SearchLower = self.SearchLower,
        Fit = function(text, limit) return fitText(text, limit, charWidth, measure) end
    }

    local last = math.min(count, self.Top + visible - 1)
    for row = self.Top, last do
        self:_PaintRow(ctx, row)
    end

    if count == 0 then self:_PaintEmpty(ctx) end

    if strip > 0 then
        self:_PaintScrollbar(canvas, brush, metrics, surface, count, visible)
    else
        self.ThumbY, self.ThumbH, self.ScrollHover = nil, nil, false
    end
    if present then present() end
end

--
--- ∑ The scrollbar, drawn rather than delegated to a native control, so it
---   follows the theme and the whole view stays one surface. Only called for
---   a list that scrolls.
--- @return nil
--
function View:_PaintScrollbar(canvas, brush, metrics, surface, count, visible)
    local x, width = metrics.ScrollX, metrics.ScrollW
    brush.Color = surface.Scroll
    canvas.fillRect(x, 0, x + width, metrics.Height)
    local y, height = Layout.Thumb(self.Top, visible, count, metrics.Height)
    self.ThumbY, self.ThumbH = y, height
    if not y then
        self.ScrollHover = false
        return
    end
    -- The thumb moves under a cursor that stands still while records arrive,
    -- so whether the cursor is on it is decided against where it is now.
    local mouseX, mouseY = self.MouseX, self.MouseY
    self.ScrollHover = type(mouseX) == "number" and type(mouseY) == "number"
        and mouseX >= x and mouseY >= y and mouseY <= y + height
    brush.Color = (self.Dragging or self.ScrollHover) and surface.ThumbHover or surface.Thumb
    canvas.fillRect(x + 2, y + 1, x + width - 2, y + height - 1)
end

--------------------------------------------------------
--                        Hints                       --
--------------------------------------------------------

--
--- ∑ A sentence about one row, for the status bar.
---
---   The whole text when the last frame had to cut it, the whole channel
---   when the channel column did, and then what the row's marks mean. A row
---   with nothing hidden and nothing marked has nothing to say.
--- @param row number
--- @return string|nil
--
function View:HintFor(row)
    local entry = row and self.Rows[row]
    if not entry then return nil end
    local record = entry.Record
    local parts = {}
    if entry.ChannelCut and record.Channel then parts[#parts + 1] = tostring(record.Channel) end
    if entry.Cut then
        local text = tostring(entry.Text or ""):match("^%s*(.-)%s*$")
        if text ~= "" then parts[#parts + 1] = text end
    end
    local marks = {}
    if entry.First then
        if (record.Repeats or 1) > 1 then marks[#marks + 1] = "repeated " .. record.Repeats .. " times" end
        if record.Dropped then marks[#marks + 1] = record.Dropped .. " dropped after this" end
    end
    if record.Pinned then marks[#marks + 1] = "pinned" end
    local text = table.concat(parts, "  ")
    if #marks > 0 then
        local said = table.concat(marks, ", ")
        text = text ~= "" and (text .. "  -  " .. said) or said
    end
    if text == "" then return nil end
    return text
end

--
--- ∑ Tells the owner about the row under the cursor, when that changed.
---   Nothing is said while the thumb is dragged, and nil once the cursor has
---   nothing to say, so the owner can put its own text back.
--- @return boolean # Whether OnHint was called.
--
function View:SyncHint()
    local text = nil
    if self.Hover and not self.Dragging then text = self:HintFor(self.Hover) end
    if text == self.HintText then return false end
    self.HintText = text
    if self.OnHint then pcall(self.OnHint, text) end
    return true
end

--------------------------------------------------------
--                    Interaction                     --
--------------------------------------------------------

--- Modifier state, read from Cheat Engine rather than from the event. The
--- binding does not pass the shift state argument through at all.
local function modifiers()
    local isKeyPressed = rawget(_G, "isKeyPressed")
    if type(isKeyPressed) ~= "function" then return false, false end
    local control, shift = false, false
    pcall(function() control = isKeyPressed(0x11) == true end) -- VK_CONTROL
    pcall(function() shift = isKeyPressed(0x10) == true end)   -- VK_SHIFT
    return control, shift
end

--
--- ∑ Which part of the scrollbar a point is on, or nil. A list with no thumb
---   has no scrollbar to hit, so a click at its right edge lands on a row.
--- @param x number|nil
--- @param y number|nil
--- @return string|nil # thumb, track-up or track-down
--
function View:ScrollbarHit(x, y)
    local metrics = self.Metrics
    local thumbY, thumbH = self.ThumbY, self.ThumbH
    if not metrics or not thumbY or (self.Strip or 0) <= 0 then return nil end
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    if x < metrics.ScrollX then return nil end
    if y < thumbY then return "track-up" end
    if y > thumbY + (thumbH or 0) then return "track-down" end
    return "thumb"
end

function View:MouseDown(button, x, y)
    local metrics = self.Metrics
    if not metrics or type(x) ~= "number" or type(y) ~= "number" then return end
    self.MouseX, self.MouseY = x, y
    -- The right button lets the owner show its menu over whatever is under
    -- the cursor, without disturbing an existing multi row selection.
    -- Cheat Engine passes the button as the TMouseButton ordinal on some
    -- builds and as the enum name on others. Both spellings are accepted.
    if button == 1 or button == "mbRight" then
        local row = Layout.RowAt(y, self.Top, metrics.RowHeight, #self.Rows)
        if row then
            local entry = self.Rows[row]
            if not self.Selection[entry.Record.Seq] then self:Select(row, "replace") end
            self.Hover = row
            self:Invalidate()
        end
        if self.OnContextMenu then pcall(self.OnContextMenu, x, y, self:FocusedRecord()) end
        return
    end
    local part = self:ScrollbarHit(x, y)
    if part == "thumb" then
        self.Dragging = true
        self.DragOffset = y - self.ThumbY
        self:Invalidate()
        return
    elseif part then
        -- A click in the track pages towards the click, the way a native
        -- scrollbar does.
        local visible = self:VisibleRows()
        self:ScrollBy(part == "track-up" and -visible or visible)
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
        self:Invalidate()
        self:SyncHint()
    end
end

--
--- ∑ A mouse move. It changes the state and asks for a frame, and never
---   paints, because Cheat Engine delivers a move for every pixel.
--- @param x number|nil
--- @param y number|nil
--- @return nil
--
function View:MouseMove(x, y)
    local metrics = self.Metrics
    if not metrics or type(y) ~= "number" then return end
    self.MouseX, self.MouseY = x, y
    if self.Dragging then
        local top = Layout.TopForThumb(y - self.DragOffset, self.ThumbH or 24,
            metrics.Height, self:VisibleRows(), #self.Rows)
        self:ScrollTo(top)
        return
    end
    local part = self:ScrollbarHit(x, y)
    local onThumb = part == "thumb"
    if onThumb ~= (self.ScrollHover == true) then
        self.ScrollHover = onThumb
        self:Invalidate()
    end
    local row = nil
    if not part then row = Layout.RowAt(y, self.Top, metrics.RowHeight, #self.Rows) end
    if row ~= self.Hover then
        self.Hover = row
        self:Invalidate()
        self:SyncHint()
    end
end

function View:MouseLeave()
    self.MouseX, self.MouseY = nil, nil
    if self.Hover ~= nil or self.ScrollHover then
        self.Hover, self.ScrollHover = nil, false
        self:Invalidate()
    end
    self:SyncHint()
end

function View:Activate()
    local record = self:FocusedRecord()
    if record and self.OnActivate then pcall(self.OnActivate, record) end
end

--
--- ∑ Keyboard handling, called by the owning window's OnKeyDown.
---
---   Escape only counts as used when there was a selection to clear, so the
---   owner can give the key a meaning of its own once nothing is selected.
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
    if key == 27 then                                            -- Escape
        if not self:HasSelection() then return false end
        self:ClearSelection()
        return true
    end
    return false
end

--
--- ∑ The surface changed size. The next frame measures again, re-wraps in
---   wrap mode and keeps a following list on its newest row, so a resize drag
---   costs one frame per timer tick and not one per WM_SIZE.
--- @return nil
--
function View:OnResize()
    self:Invalidate()
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
    -- Not destroyed. The bitmap belongs to the TImage's Picture, which the
    -- form frees along with the control.
    self.PictureBitmap = nil
    self.Rows = {}
    self.Records = {}
    self.BuiltCount = 0
    self.Hover, self.MouseX, self.MouseY = nil, nil, nil
    self.HintText = nil
    self.LegibleCache, self.LegibleFor = nil, nil
end

return View
