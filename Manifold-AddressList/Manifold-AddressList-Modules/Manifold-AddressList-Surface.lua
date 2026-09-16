--[[
    One canvas, drawn by hand, shared by every list this window shows.

    Cheat Engine gives Lua no scroll box and no owner drawn list control, so a
    record tree with a colour per record, a property grid with in place editors
    and a results strip all have to be painted onto a canvas. This module is
    the engine underneath all of them. It is a port of Manifold-Logger-View,
    which has been doing exactly this for the log console, and every part that
    was proven there is kept the way it was.

    The surface is probed, because Cheat Engine's control set varies by build.
    createPaintBox gives a TGraphicControl with a Canvas and an OnPaint, which
    is blitted from an off screen bitmap of our own. createImage gives a TImage
    whose Picture.Bitmap is already off screen, and that is the live path. With
    neither of the two, Attach reports false and the owner falls back to a
    themed memo.

    Painting is owned by one Frame service, which the Window builds and hands
    to everything that draws. A surface marks itself dirty and the frame timer
    paints the dirty ones a few milliseconds later. Nothing paints inside a
    mouse move, because painting there saturates the thread and a resize drag
    turns into a slide show. One frame is one protected call and not one per
    drawing operation, and five failures in a row stop the surface instead of
    filling Cheat Engine's log.

    Three Cheat Engine facts shape the event handling. A TGraphicControl never
    receives WM_MOUSEWHEEL, so the wheel handlers go on the surface and on its
    windowed parent as well. A wheel event carries the mouse position and no
    delta at all, so the direction is which of the two handlers ran and the
    surface makes its own delta from that. A mouse button arrives as an integer
    and never as the name of one, so the right button is one.

    Text is measured, truncated and drawn with textOut. canvas.textRect is
    never called from here. Its first argument is a rectangle table and it
    renders through Cheat Engine's formatted text renderer, which would read a
    record description as markup. The check box and the expand arrow are drawn
    with fillRect and line, so no font has to carry a glyph for them.

    Every drawing helper here puts the brush, the pen and the font back the way
    it found them. textOut is opaque and fills its own cell with the brush
    before the glyphs go down, so a helper that walked away with the brush on
    its own colour would tint the next piece of text on the row. A record row
    draws five check boxes and then five pieces of text, so the tinting is not
    an edge case, it is the normal path, and Cheat Engine's own address list
    behaves the same way. Setting the brush style to bsClear would stop the
    tinting and also stop fillRect painting anything, so it is not a way out.

    Surface.ListPainter is the column driven list that every simple list in
    this window uses. The results strip, the pointer level list, the hotkey
    table and the drop down preview would otherwise each invent hit testing,
    hover, a selection model and a scrollbar of their own.
]]

local Surface = {}
Surface.__index = Surface

--
--- ∑ The numbers the whole engine measures from. Everything else is derived
---   from the font, so a change of font size moves the rows and the columns
---   without a second table of sizes.
--
Surface.Defaults = {
    --- Consolas 10 is the family size, and Settings.FontSize is the one place
    --- it is remembered.
    FontSize = 10,
    --- The same bounds Settings clamps to. Below seven a canvas cannot be read
    --- and above sixteen a row eats the window.
    MinFontSize = 7,
    MaxFontSize = 16,
    --- The drawn scrollbar. Twelve pixels is what the log console uses and it
    --- is wide enough to grab with a mouse.
    ScrollWidth = 12,
    --- A thumb shorter than this cannot be hit, however long the list is.
    MinThumb = 24,
    --- Rows per wheel notch. The event carries no delta, so this is the delta.
    WheelRows = 3,
    --- The gap at the left edge and between two columns.
    PadX = 6,
    --- Added to the measured text height to make a row. Consolas 10 lands on
    --- twenty one pixels, which is the family row height.
    RowPadding = 6,
    --- Consecutive frame failures before the surface gives up. An API mismatch
    --- fails on every frame, so repeating the report forever helps nobody.
    MaxFailures = 5,
    --- The double click window, in milliseconds, for the builds that deliver
    --- no OnDblClick of their own.
    DoubleMs = 400,
    --- How far the second click may land from the first and still count.
    DoubleSlop = 4,
    --- The drawn check box, eleven pixels square with a two pixel inner margin.
    CheckSize = 11,
    --- The drawn expand arrow, nine pixels square.
    ExpandSize = 9,
    --- The contrast a muted or accent colour keeps against a selected or
    --- hovered row, as the ratio WCAG measures. Four and a half to one is what
    --- it asks of text this size. Dark-Aqua put its muted colour on a
    --- selection at two and a half and on a hovered grid row at three.
    ReadableRatio = 4.5,
    --- Where the lift starts and how much stricter each round asks Theme.Contrast
    --- to be, in luma. Seventy is the distance the rest of the segment corrects
    --- with, and ten more a round reaches the ratio without overshooting it.
    ContrastStart = 70,
    ContrastStep = 10
}

local Defaults = Surface.Defaults

--------------------------------------------------------
--                    Pure geometry                   --
--------------------------------------------------------

--
--- ∑ Scrolling as arithmetic over plain numbers, with no canvas anywhere near
---   it. The same functions the log console has been scrolling with, kept
---   pure so the interesting cases can be tested without Cheat Engine.
--
local Scroll = {}
Surface.Scroll = Scroll

--
--- ∑ Clamps a scroll position to something that exists.
--- @param top number # Index of the first visible row, 1-based.
--- @param visible number # Rows that fit.
--- @param count number # Rows in total.
--- @return number
--
function Scroll.Clamp(top, visible, count)
    local maximum = math.max(1, (count or 0) - (visible or 0) + 1)
    top = tonumber(top) or 1
    if top < 1 then return 1 end
    if top > maximum then return maximum end
    return math.floor(top)
end

--- The scroll position that shows the last row.
function Scroll.Bottom(visible, count)
    return math.max(1, (count or 0) - (visible or 0) + 1)
end

--
--- ∑ Where the scrollbar thumb sits, in track coordinates. Nothing comes back
---   when everything fits, and then no thumb is drawn at all.
--- @param top number
--- @param visible number
--- @param count number
--- @param track number # Track height in pixels.
--- @param minimum number|nil # Smallest thumb, twenty four by default.
--- @return number|nil, number|nil # y and height.
--
function Scroll.Thumb(top, visible, count, track, minimum)
    minimum = minimum or Defaults.MinThumb
    count, visible, track = count or 0, visible or 0, track or 0
    if count <= visible or track <= 0 then return nil end
    local height = math.max(minimum, math.floor(track * visible / count))
    height = math.min(height, track)
    local span = math.max(1, count - visible)
    local progress = math.min(1, math.max(0, ((tonumber(top) or 1) - 1) / span))
    return math.floor(progress * (track - height)), height
end

--
--- ∑ The inverse of Scroll.Thumb. Which scroll position a thumb dragged to y
---   stands for.
--- @param y number
--- @param thumbHeight number
--- @param track number
--- @param visible number
--- @param count number
--- @return number
--
function Scroll.TopForThumb(y, thumbHeight, track, visible, count)
    local room = (track or 0) - (thumbHeight or 0)
    if room <= 0 then return 1 end
    local progress = math.min(1, math.max(0, (tonumber(y) or 0) / room))
    local span = math.max(0, (count or 0) - (visible or 0))
    return Scroll.Clamp(1 + math.floor(progress * span + 0.5), visible, count)
end

--
--- ∑ The row index at a pixel offset inside the list area, or nothing above
---   the first row and below the last one.
--- @param y number|nil
--- @param top number
--- @param rowHeight number
--- @param count number
--- @return number|nil
--
function Scroll.RowAt(y, top, rowHeight, count)
    -- y is nil when a Cheat Engine build hands the handler fewer arguments
    -- than expected. Refusing is right, raising would fire per mouse move.
    if type(y) ~= "number" or (rowHeight or 0) <= 0 or y < 0 then return nil end
    local index = (tonumber(top) or 1) + math.floor(y / rowHeight)
    if index < 1 or index > (count or 0) then return nil end
    return index
end

--
--- ∑ How many whole rows fit in a height. At least one, because a list one
---   pixel high still has to show something.
--- @param height number
--- @param rowHeight number
--- @return number
--
function Scroll.Visible(height, rowHeight)
    if (rowHeight or 0) <= 0 then return 0 end
    return math.max(1, math.floor((height or 0) / rowHeight))
end

--
--- ∑ How much width a list gives up to its scrollbar. The whole strip when it
---   holds more rows than fit, and nothing at all when everything fits.
---
---   A list that kept the strip while nothing scrolled ended twelve pixels
---   short of the fields and buttons around it. The owner asks this before it
---   lays a row out, from the rows it is about to paint and the rows its height
---   holds, and never from what the last frame left behind. So the frame in
---   which a list grows past the window is already the frame with the strip
---   and the thumb in it. The strip takes width and never height, so reserving
---   it cannot change how many rows fit, and the answer cannot flip back and
---   forth between two frames.
--- @param count number # Rows in total.
--- @param visible number # Rows that fit.
--- @return number # Pixels to keep free at the right edge.
--
function Scroll.Strip(count, visible)
    if (tonumber(count) or 0) > (tonumber(visible) or 0) then return Defaults.ScrollWidth end
    return 0
end

--------------------------------------------------------
--                  The frame service                 --
--------------------------------------------------------

--
--- ∑ The one owner of painting. Every surface in the window registers with it
---   and the window ticks it on a timer.
---
---   Without this each of the seven things that draw would invent its own way
---   to get a frame, and a theme change would have no single place to say that
---   everything on screen is now wrong. It lives in this file because it
---   belongs to the painting layer and to nothing else.
--
local Frame = {}
Frame.__index = Frame
Surface.Frame = Frame

--- Windows rounds a timer up to its own 15.6 ms tick, so fifteen is the
--- smallest honest interval and sixteen is twice as slow as it looks.
Frame.Interval = 15

--
--- ∑ Builds the service. It creates nothing and owns no timer, because the
---   Window owns the timer and calls Tick.
--- @param services table|nil # Log, Settings, Theme and Visible, a function
---        that says whether the form is on screen. Without a Theme the tick
---        settles the theme its surfaces paint with.
--- @return table
--
function Frame:New(services)
    services = services or {}
    local settings = services.Settings
    return setmetatable({
        Log      = services.Log,
        Settings = settings,
        Theme    = services.Theme,
        Visible  = services.Visible,     -- nil means always visible
        Surfaces = {},                   -- in the order they registered
        Ticks    = 0,
        Painted  = 0,                    -- frames actually painted
        FontSize = (settings and settings.FontSize) or Defaults.FontSize
    }, Frame)
end

--- Registers a surface. A second Add of the same one changes nothing, so a
--- caller may register in New and again after Attach without paying twice.
function Frame:Add(surface)
    if type(surface) ~= "table" then return false end
    for _, known in ipairs(self.Surfaces) do
        if known == surface then return false end
    end
    self.Surfaces[#self.Surfaces + 1] = surface
    return true
end

--- Forgets a surface. Destroy calls this, which is what keeps a closed page
--- from being painted after its canvas went away.
function Frame:Remove(surface)
    for index, known in ipairs(self.Surfaces) do
        if known == surface then
            table.remove(self.Surfaces, index)
            return true
        end
    end
    return false
end

function Frame:Count()
    return #self.Surfaces
end

--- Marks every surface dirty. This is what a theme change and a restyle use,
--- because after one of those everything on screen is painted in colours that
--- no longer exist.
function Frame:Invalidate()
    for _, surface in ipairs(self.Surfaces) do surface.Dirty = true end
end

--
--- ∑ Gives the theme its turn to put right what only exists after Windows
---   painted a native control once, which is the brush of a combo box.
---
---   The tick is the one moment that is known to come after those paints,
---   because Windows hands out a timer message only when no paint is
---   waiting. A frame built without a theme asks the theme its surfaces paint
---   with, which in this window is the one theme there is. A theme without
---   the method, or one that raises, costs this tick nothing.
--- @return nil
--
function Frame:Settle()
    local theme = self.Theme
    if theme == nil then
        for index = 1, #self.Surfaces do
            theme = self.Surfaces[index].Theme
            if theme ~= nil then break end
        end
    end
    if type(theme) == "table" and type(theme.Settle) == "function" then
        pcall(theme.Settle, theme)
    end
end

--
--- ∑ Paints the surfaces that asked for it. The whole tick is skipped while
---   the form is hidden, because painting a window nobody can see costs the
---   same as painting one somebody can.
---
---   The theme is settled before anything is painted. What a painter shows
---   in this tick has not been painted by Windows yet, so it waits for the
---   next one.
--- @return number # How many surfaces were painted.
--
function Frame:Tick()
    if self.Visible and not self.Visible() then return 0 end
    self.Ticks = self.Ticks + 1
    self:Settle()
    local painted = 0
    local surfaces = self.Surfaces
    for index = 1, #surfaces do
        local surface = surfaces[index]
        if surface and surface.Dirty and not surface.Disabled then
            if surface:Render() then painted = painted + 1 end
        end
    end
    self.Painted = self.Painted + painted
    return painted
end

--
--- ∑ Changes the font size for every canvas at once and remembers it.
---
---   The size lives in Settings and nowhere else, so the clamp lives there
---   too. A surface never decides its own size, which is why the owners do not
---   call SetFontSize on a surface themselves.
--- @param size number
--- @return number, boolean # The size in force and whether it moved.
--
function Frame:SetFontSize(size)
    size = math.floor(tonumber(size) or self.FontSize)
    local settings = self.Settings
    if settings and type(settings.Set) == "function" then
        settings:Set("FontSize", size)
        size = tonumber(settings.FontSize) or size
    else
        size = math.max(Defaults.MinFontSize, math.min(Defaults.MaxFontSize, size))
    end
    if size == self.FontSize then return size, false end
    self.FontSize = size
    for _, surface in ipairs(self.Surfaces) do surface:SetFontSize(size) end
    return size, true
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--- One guarded property write. A control that is gone and a property a build
--- does not have both come back as false rather than as a raise.
local function safeSet(control, property, value)
    if not control then return false end
    return (pcall(function() control[property] = value end))
end

--
--- ∑ The last two numbers in an argument list.
---
---   Cheat Engine's binding drops the LCL's Shift argument from mouse events,
---   so OnMouseDown arrives as sender, button, x, y and OnMouseMove as sender,
---   x, y. Taking the last two numbers is correct under both.
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

Surface.Coordinates = coordinates

--
--- ∑ Colours for a surface that has no theme at all. Only the tests and a
---   broken install ever see them, and they exist so a painter can index the
---   table without checking every key first.
---
---   They follow the same spacing the themed ones are derived with. The three
---   row tones step away from the background and Header sits between the stripe
---   and the hover, because chrome belongs to the frame rather than being a
---   brighter fourth row state.
--
Surface.Fallback = {
    Background = 0x1B1B1B, Stripe = 0x222222, Hover = 0x2E2E2E,
    Selection = 0x4A3B25, SelectionText = 0xE8E8E8, Gutter = 0x202020,
    Rule = 0x333333, Text = 0xE8E8E8, Muted = 0x9A9A9A, Accent = 0xD8A24A,
    Match = 0x5A4A2A, Scroll = 0x202020, Thumb = 0x3A3A3A, ThumbHover = 0xD8A24A,
    Error = 0x5C5CFF, Warning = 0x3DB8FF, Info = 0x9A9A9A,
    Check = 0xD8A24A, CheckBorder = 0x4A4A4A, Header = 0x272727, Focus = 0xD8A24A
}

--
--- ∑ Builds a surface. Nothing is created until Attach, and the surface joins
---   the frame service straight away so an owner cannot forget to register it.
--- @param services table|nil # Theme, Log, Name, Settings and Frame.
--- @return table
--
function Surface:New(services)
    services = services or {}
    local settings = services.Settings
    local instance = setmetatable({
        Theme    = services.Theme,
        Log      = services.Log,
        Settings = settings,
        Frame    = services.Frame,
        Name     = services.Name or "Surface",
        --- os.clock in seconds. The tests replace it to steer the double click
        --- window without sleeping.
        Clock    = services.Clock or os.clock,

        Control  = nil,      -- the paint box or image that takes the events
        Kind     = nil,      -- paintbox or image
        Parent   = nil,      -- the windowed control the wheel really reaches
        Buffer   = nil,      -- our own off screen bitmap, paint box path only
        BufferWidth = 0,
        BufferHeight = 0,
        PictureBitmap = nil, -- the image path's own off screen bitmap
        Reason   = nil,      -- why it is not painting
        Disabled = false,

        Painter  = nil,      -- fn(surface, canvas, width, height, colors, metrics)
        List     = nil,      -- the ListPainter, when one was made here
        Dirty    = true,
        Painting = false,
        Frames   = 0,
        PaintFailures = 0,
        HandlerReported = false,

        FontSize = tonumber(settings and settings.FontSize) or Defaults.FontSize,
        EmptyStyle = nil,    -- probed once, see _Frame
        MetricsCache = nil,
        CachedPalette = nil,
        SurfaceColors = nil,
        -- Lifted colours by row tone and then by colour, and the colour table
        -- they were worked out for. See Legible.
        LegibleCache = nil,
        LegibleFor = nil,

        -- The wrappers of the frame being painted. Each read of Font, Brush or
        -- Pen builds a new one in Cheat Engine, so they are read once and the
        -- drawing helpers reuse them.
        FrameCanvas = nil, FrameFont = nil, FrameBrush = nil, FramePen = nil,

        Width = 0, Height = 0,
        Top = 1, Count = 0, Visible = 1,

        ScrollX = nil, ScrollY = 0, ScrollW = 0, ScrollH = 0,
        ThumbY = nil, ThumbH = 0, ScrollHover = false,
        Dragging = false, DragOffset = 0,

        MouseX = nil, MouseY = nil, Inside = false,
        DownX = nil, DownY = nil, DownAt = -1000000, DownWasDouble = false,
        DownCount = 0, DoubleAtDown = nil, NativeDouble = false,

        OnMouseDown = nil, OnMouseUp = nil, OnMouseMove = nil, OnMouseLeave = nil,
        OnDoubleClick = nil, OnWheel = nil, OnResize = nil
    }, Surface)
    local frame = services.Frame
    if frame and type(frame.Add) == "function" then frame:Add(instance) end
    return instance
end

--- One log line, or nothing at all when this segment runs without a log.
local function say(self, level, message)
    local log = self.Log
    if not log or type(log[level]) ~= "function" then return end
    pcall(log[level], log, message)
end

--------------------------------------------------------
--                    The control                     --
--------------------------------------------------------

--
--- ∑ Creates the paint surface inside parent and wires its events.
---
---   The probe order is deliberate. A paint box is the lighter control and
---   blits from a bitmap we own, and an image is what every Cheat Engine share
---   script uses, so one of the two is there on any build worth supporting.
--- @param parent userdata
--- @return boolean, string|nil
--
function Surface:Attach(parent)
    self.Parent = parent
    local createPaintBox = rawget(_G, "createPaintBox")
    if type(createPaintBox) == "function" then
        local ok, box = pcall(createPaintBox, parent)
        if ok and box then self.Control, self.Kind = box, "paintbox" end
    end
    if not self.Control then
        local createImage = rawget(_G, "createImage")
        if type(createImage) == "function" then
            local ok, image = pcall(createImage, parent)
            if ok and image then
                self.Control, self.Kind = image, "image"
                safeSet(image, "Stretch", false)
                safeSet(image, "Center", false)
                safeSet(image, "AutoSize", false)
            end
        end
    end
    if not self.Control then
        self.Reason = "this Cheat Engine has neither createPaintBox nor createImage"
        say(self, "Warning", self.Name .. " could not be attached, " .. self.Reason)
        return false, self.Reason
    end
    safeSet(self.Control, "Parent", parent)
    safeSet(self.Control, "Align", "alClient")
    self:WireEvents()
    self.Dirty = true
    return true
end

--
--- ∑ Wraps an event handler so a defect in it degrades instead of reporting
---   once per mouse move. The first failure is named, the rest are silent.
--- @param name string # What to call it in the report.
--- @param fn function
--- @return function
--
function Surface:Guard(name, fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        if not self.HandlerReported then
            self.HandlerReported = true
            say(self, "Warning", self.Name .. " " .. name .. " failed, " .. tostring(result))
        end
    end
end

--
--- ∑ Installs the handlers. OnPaint only exists on the paint box path, where
---   it blits the buffer. The image path is already showing the bitmap it was
---   drawn into, so it has nothing to blit.
--- @return nil
--
function Surface:WireEvents()
    local control = self.Control
    if self.Kind == "paintbox" then
        safeSet(control, "OnPaint", self:Guard("paint", function() self:Blit() end))
    end
    safeSet(control, "OnResize", self:Guard("resize", function() self:Resized() end))
    safeSet(control, "OnMouseDown", self:Guard("mouse down", function(_, button, ...)
        local x, y = coordinates(...)
        self:MouseDown(button, x, y)
    end))
    safeSet(control, "OnMouseUp", self:Guard("mouse up", function(_, button, ...)
        local x, y = coordinates(...)
        self:MouseUp(button, x, y)
    end))
    safeSet(control, "OnMouseMove", self:Guard("mouse move", function(_, ...)
        local x, y = coordinates(...)
        self:MouseMove(x, y)
    end))
    safeSet(control, "OnMouseLeave", self:Guard("mouse leave", function() self:MouseLeave() end))
    safeSet(control, "OnDblClick", self:Guard("double click", function() self:DoubleClick() end))

    -- Up and Down only, and never OnMouseWheel. TControl.DoMouseWheel calls
    -- OnMouseWheel first and only falls through to the two when it was not
    -- reported handled, so setting all three scrolls twice a notch. The two
    -- handlers also go on the parent, because a paint box and an image are
    -- graphic controls with no window handle and the wheel message stops at
    -- the nearest windowed ancestor.
    local up = self:Guard("wheel up", function() return self:Wheel(-1) end)
    local down = self:Guard("wheel down", function() return self:Wheel(1) end)
    for _, target in ipairs({ control, self.Parent }) do
        if target then
            safeSet(target, "OnMouseWheelUp", up)
            safeSet(target, "OnMouseWheelDown", down)
        end
    end
end

--
--- ∑ The size of the drawable area.
--- @return number, number
--
function Surface:Size()
    local width, height = 0, 0
    pcall(function()
        width = tonumber(self.Control.Width) or 0
        height = tonumber(self.Control.Height) or 0
    end)
    self.Width, self.Height = width, height
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
function Surface:AcquireCanvas(width, height)
    if width <= 0 or height <= 0 then return nil end
    if self.Kind == "image" then
        local canvas
        local ok = pcall(function()
            -- TPicture.GetBitmap hands back the same object once it has made
            -- one, so it is resolved once and kept. Reaching through Picture
            -- every frame is two lookups through Cheat Engine's RTTI fallback.
            local bitmap = self.PictureBitmap
            if not bitmap then
                bitmap = self.Control.Picture.Bitmap
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
        return canvas, function() pcall(function() self.Control.repaint() end) end
    end
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
    return canvas, function() pcall(function() self.Control.repaint() end) end
end

--
--- ∑ Puts the off screen buffer on the control. Only the paint box path needs
---   it, and only OnPaint calls it. The image path is already showing the
---   bitmap that was drawn into.
--- @return boolean
--
function Surface:Blit()
    if self.Kind ~= "paintbox" or not self.Buffer or not self.Control then return false end
    return (pcall(function() self.Control.Canvas.draw(0, 0, self.Buffer) end))
end

--------------------------------------------------------
--                      Painting                      --
--------------------------------------------------------

--- Asks for a frame. The frame service paints it on its next tick, which is
--- what keeps a burst of mouse moves down to one repaint.
function Surface:Invalidate()
    self.Dirty = true
end

--
--- ∑ Installs the painter. It is called once per frame with the canvas, the
---   size, the colours and the metrics, and it is the only place an owner
---   draws anything.
--- @param fn function|nil
--- @return nil
--
function Surface:SetPainter(fn)
    self.Painter = type(fn) == "function" and fn or nil
    self:Invalidate()
end

--
--- ∑ The colours every canvas in this window paints from, cached against the
---   palette's identity.
---
---   Theme.GetPalette hands back the same table until a Cheat Table applies a
---   different theme, so comparing the reference is both the cheapest check
---   and the exact one. Theme.Surface owns the values, this only caches them.
--- @return table
--
function Surface:Colors()
    local theme = self.Theme
    if not theme or type(theme.Surface) ~= "function" then return Surface.Fallback end
    local palette
    if type(theme.GetPalette) == "function" then
        local ok, active = pcall(theme.GetPalette, theme)
        if ok then palette = active end
    end
    if palette ~= self.CachedPalette or not self.SurfaceColors then
        local ok, colors = pcall(theme.Surface, theme, palette)
        if not ok or type(colors) ~= "table" then return Surface.Fallback end
        self.CachedPalette, self.SurfaceColors = palette, colors
    end
    return self.SurfaceColors
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
function Surface.Ratio(first, second)
    local a, b = luminance(first), luminance(second)
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
end

--
--- ∑ A colour that can be read on the row tone it is drawn over.
---
---   A muted or an accent colour is picked to read on the plain rows. A
---   selected row leans towards the accent and a hovered one towards white, so
---   the same colour can land at two to one there, which nobody can read. It
---   goes through Theme.Contrast against that tone, the way the tree treats a
---   record's own colour, asking for a little more distance each round until
---   the measured ratio holds or the colour cannot move any further. A colour
---   that already reads comes back as it is.
---
---   Remembered per colour table, because a frame asks for the same handful
---   of pairs on every row and a new palette is the only thing that changes
---   the answers. A surface with no theme, a colour that is not a plain blue
---   green red triple and a theme whose Contrast raises all hand the colour
---   back untouched.
--- @param color number
--- @param background number # The tone of the row or of the header bar.
--- @return number
--
function Surface:Legible(color, background)
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
    local best = Surface.Ratio(color, background)
    if contrast ~= nil and best < Defaults.ReadableRatio then
        local minimum = Defaults.ContrastStart
        while minimum <= 255 do
            local ok, value = pcall(contrast, color, background, minimum)
            if not ok or type(value) ~= "number" then break end
            local ratio = Surface.Ratio(value, background)
            -- The best one so far, because a colour that starts on the wrong
            -- side of a middle tone passes through the background on its way.
            if ratio > best then answer, best = value, ratio end
            if best >= Defaults.ReadableRatio then break end
            minimum = minimum + Defaults.ContrastStep
        end
    end
    known[color] = answer
    return answer
end

--
--- ∑ Row and character geometry, measured against the real font once per font
---   size.
---
---   getTextWidth is a Win32 text extent call, so one reference measurement
---   per font size gives the average character width and a column only gets
---   measured for real near its edge. In Consolas the estimate is exact.
--- @param canvas userdata
--- @return table # CharWidth, TextHeight, RowHeight and the size they are for.
--
function Surface:Metrics(canvas)
    local cache = self.MetricsCache
    if cache and cache.FontSize == self.FontSize then return cache end
    local textHeight = 0
    local charWidth = 0
    pcall(function()
        textHeight = tonumber(canvas.getTextHeight("Ag")) or 0
        charWidth = (tonumber(canvas.getTextWidth("0123456789")) or 0) / 10
    end)
    if textHeight <= 0 then textHeight = self.FontSize + 6 end
    if charWidth <= 0 then charWidth = math.max(1, self.FontSize * 0.6) end
    cache = {
        FontSize = self.FontSize,
        CharWidth = charWidth,
        TextHeight = math.floor(textHeight),
        RowHeight = math.floor(textHeight) + Defaults.RowPadding
    }
    self.MetricsCache = cache
    return cache
end

--
--- ∑ Changes the font size of this one canvas. The frame service is the only
---   caller, because the size lives once in Settings and every canvas in the
---   window shows it at the same size.
--- @param size number
--- @return boolean # Whether it moved.
--
function Surface:SetFontSize(size)
    size = math.floor(tonumber(size) or self.FontSize)
    size = math.max(Defaults.MinFontSize, math.min(Defaults.MaxFontSize, size))
    if size == self.FontSize then return false end
    self.FontSize = size
    self.MetricsCache = nil
    self:Invalidate()
    return true
end

--- The font wrapper of the frame being painted, or a fresh one outside a
--- frame. Reading it from the canvas costs about four microseconds, which is
--- why a painter must never read it per row.
function Surface:FontOf(canvas)
    if canvas == self.FrameCanvas and self.FrameFont then return self.FrameFont end
    return canvas.Font
end

function Surface:BrushOf(canvas)
    if canvas == self.FrameCanvas and self.FrameBrush then return self.FrameBrush end
    return canvas.Brush
end

function Surface:PenOf(canvas)
    if canvas == self.FrameCanvas and self.FramePen then return self.FramePen end
    return canvas.Pen
end

--
--- ∑ Renders one frame. One protected call for the whole frame and not one
---   per drawing operation, because an API mismatch fails on every row anyway
---   and a guard per call would only repeat the same report.
--- @return boolean # Whether the frame was painted.
--
function Surface:Render()
    -- Already painting means a modal or a deactivation pumped messages and the
    -- frame timer came round again in the middle of a frame.
    if not self.Control or self.Disabled or self.Painting then return false end
    self.Painting = true
    local ok, err = pcall(self._Frame, self)
    self.Painting = false
    self.Dirty = false
    if ok then
        self.PaintFailures = 0
        self.Frames = self.Frames + 1
        return true
    end
    self.PaintFailures = self.PaintFailures + 1
    self.Reason = tostring(err)
    if self.PaintFailures >= Defaults.MaxFailures then
        self.Disabled = true
        say(self, "Error", self.Name .. " stopped painting after "
            .. Defaults.MaxFailures .. " failures in a row, " .. self.Reason)
    end
    return false
end

function Surface:_Frame()
    local width, height = self:Size()
    if width <= 0 or height <= 0 then return end
    local canvas, show = self:AcquireCanvas(width, height)
    if not canvas then return end

    -- Each read of Font, Brush or Pen builds a new wrapper in Cheat Engine, so
    -- the three are read once here and every drawing helper reuses them. That
    -- is also why the style probe below goes through this font and not through
    -- another read of the canvas.
    local font, brush, pen = canvas.Font, canvas.Brush, canvas.Pen
    self.FrameCanvas, self.FrameFont, self.FrameBrush, self.FramePen = canvas, font, brush, pen

    -- The empty font style is probed once. The empty set is what a Lazarus
    -- style property expects, and a build whose binding takes the value as a
    -- plain string rejects it, where a raise would kill every frame.
    if self.EmptyStyle == nil then
        self.EmptyStyle = pcall(function() font.Style = "[]" end) and "[]" or ""
    end

    font.Name = (self.Theme and self.Theme.FontName) or "Consolas"
    font.Size = self.FontSize
    font.Style = self.EmptyStyle

    local colors = self:Colors()
    local metrics = self:Metrics(canvas)

    brush.Color = colors.Background
    canvas.fillRect(0, 0, width, height)

    if self.Painter then
        self.Painter(self, canvas, width, height, colors, metrics)
    end
    if show then show() end
end

--------------------------------------------------------
--                      Scrolling                     --
--------------------------------------------------------

--
--- ∑ Tells the surface how long the list is and how much of it fits. The
---   painter works both out from the size it was handed, so it says so here
---   and the scrollbar and the wheel follow.
---
---   It never asks for a frame. It is called from inside the painter, and a
---   painter that dirtied its own surface would paint forever.
--- @param count number
--- @param visible number
--- @return number # The scroll position after clamping.
--
function Surface:SetScroll(count, visible)
    self.Count = math.max(0, math.floor(tonumber(count) or 0))
    self.Visible = math.max(1, math.floor(tonumber(visible) or 1))
    self.Top = Scroll.Clamp(self.Top, self.Visible, self.Count)
    return self.Top
end

--- What the owner needs to know about the scroll position, as a plain table.
function Surface:ScrollState()
    return { Top = self.Top, Visible = self.Visible, Count = self.Count }
end

--
--- ∑ Scrolls to a row and asks for a frame when it moved.
--- @param top number
--- @return boolean # Whether the position changed.
--
function Surface:ScrollTo(top)
    local clamped = Scroll.Clamp(top, self.Visible, self.Count)
    if clamped == self.Top then return false end
    self.Top = clamped
    self:Invalidate()
    return true
end

function Surface:ScrollBy(rows)
    return self:ScrollTo(self.Top + (tonumber(rows) or 0))
end

--
--- ∑ Paints the scrollbar and remembers where it put it, so a later click can
---   be answered without the canvas.
---
---   The bar is drawn rather than delegated to a native control, because a
---   native one would keep Cheat Engine's own colours and the window would
---   stop looking like one surface.
---
---   A list that fits gets no track at all. A full height empty rail down the
---   side of a list of four rows says there is more to see when there is not.
---   Its owner gives the rows that width back as well, see Scroll.Strip, and
---   still calls this every frame, because this is also what forgets a thumb
---   a longer list drew, so a click at the right edge of a short one lands on
---   its row and not on a bar that is gone.
---
---   The brush is put back the way it was found, because a painter usually
---   draws the bar last and then goes on to the next thing with it.
--- @param canvas userdata
--- @param x number # Left edge of the bar.
--- @param y number # Top of the track.
--- @param height number # Track height.
--- @param colors table
--- @return boolean # Whether a thumb was drawn at all.
--
function Surface:PaintScrollbar(canvas, x, y, height, colors)
    local width = Defaults.ScrollWidth
    self.ScrollX, self.ScrollY, self.ScrollW, self.ScrollH = x, y, width, height
    local thumbY, thumbHeight = Scroll.Thumb(self.Top, self.Visible, self.Count, height)
    if not thumbY then
        self.ThumbY, self.ThumbH = nil, 0
        return false
    end
    local brush = self:BrushOf(canvas)
    local was = brush.Color
    brush.Color = colors.Scroll or colors.Background
    canvas.fillRect(x, y, x + width, y + height)
    self.ThumbY, self.ThumbH = y + thumbY, thumbHeight
    brush.Color = ((self.Dragging or self.ScrollHover) and colors.ThumbHover) or colors.Thumb
    canvas.fillRect(x + 2, self.ThumbY + 1, x + width - 2, self.ThumbY + thumbHeight - 1)
    if was ~= nil then brush.Color = was end
    return true
end

--
--- ∑ Which part of the scrollbar a point is on, or nothing when the point is
---   somewhere else. A bar with no thumb has nothing to hit, because there is
---   nothing to scroll.
--- @param x number
--- @param y number
--- @return string|nil # thumb, track-up or track-down.
--
function Surface:ScrollbarHit(x, y)
    if self.ScrollX == nil or self.ThumbY == nil then return nil end
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    if x < self.ScrollX or x > self.ScrollX + self.ScrollW then return nil end
    if y < self.ScrollY or y > self.ScrollY + self.ScrollH then return nil end
    if y < self.ThumbY then return "track-up" end
    if y > self.ThumbY + self.ThumbH then return "track-down" end
    return "thumb"
end

--------------------------------------------------------
--                    Interaction                     --
--------------------------------------------------------

--- The clock in milliseconds. os.clock counts processor seconds, which is
--- close enough for a double click window and needs no Cheat Engine at all.
function Surface:Now()
    local ok, value = pcall(self.Clock)
    if not ok or type(value) ~= "number" then return 0 end
    return value * 1000
end

--- Notes a mouse down and says whether it completed a double click. A third
--- click does not make a second double, which is what DownWasDouble is for.
local function noteDown(self, x, y)
    local now = self:Now()
    local slop = Defaults.DoubleSlop
    local near = self.DownX ~= nil
        and math.abs(x - self.DownX) <= slop and math.abs(y - self.DownY) <= slop
    local quick = (now - self.DownAt) <= Defaults.DoubleMs
    local double = near and quick and not self.DownWasDouble
    self.DownX, self.DownY, self.DownAt, self.DownWasDouble = x, y, now, double
    self.DownCount = self.DownCount + 1
    return double
end

--
--- ∑ A mouse down. The scrollbar is answered here and everything else goes to
---   the owner, which is what keeps four owners from writing the same drag.
--- @param button number # Zero is left and one is right. Always an integer.
--- @param x number
--- @param y number
--- @return nil
--
function Surface:MouseDown(button, x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    self.MouseX, self.MouseY, self.Inside = x, y, true
    local double = noteDown(self, x, y)
    local part = (button == 0 or button == nil) and self:ScrollbarHit(x, y) or nil
    if part == "thumb" then
        self.Dragging = true
        self.DragOffset = y - self.ThumbY
        self:Invalidate()
        return
    elseif part == "track-up" then
        self:ScrollBy(-self.Visible)
        return
    elseif part == "track-down" then
        self:ScrollBy(self.Visible)
        return
    end
    if self.OnMouseDown then self.OnMouseDown(button, x, y) end
    -- The LCL delivers the second down of a double click as a mouse down as
    -- well, so the owner sees both and the order is the real one.
    if double and not self.NativeDouble then
        -- Which down it was, so the control's own OnDblClick arriving right
        -- behind this one can tell that it is the same click.
        self.DoubleAtDown = self.DownCount
        if self.OnDoubleClick then self.OnDoubleClick(x, y) end
    end
end

function Surface:MouseUp(button, x, y)
    if self.Dragging then
        self.Dragging = false
        self:Invalidate()
    end
    if self.OnMouseUp then self.OnMouseUp(button, x, y) end
end

--
--- ∑ A mouse move. It marks the surface dirty and never paints. Painting here
---   saturates the thread, and Cheat Engine delivers a move for every pixel.
--- @param x number
--- @param y number
--- @return nil
--
function Surface:MouseMove(x, y)
    if type(y) ~= "number" then return end
    self.MouseX, self.MouseY, self.Inside = x, y, true
    if self.Dragging then
        local top = Scroll.TopForThumb(y - self.DragOffset - self.ScrollY,
            self.ThumbH, self.ScrollH, self.Visible, self.Count)
        self:ScrollTo(top)
        return
    end
    local over = self:ScrollbarHit(x, y) == "thumb"
    if over ~= self.ScrollHover then
        self.ScrollHover = over
        self:Invalidate()
    end
    if self.OnMouseMove then self.OnMouseMove(x, y) end
end

function Surface:MouseLeave()
    self.Inside = false
    self.MouseX, self.MouseY = nil, nil
    if self.ScrollHover then
        self.ScrollHover = false
        self:Invalidate()
    end
    if self.OnMouseLeave then self.OnMouseLeave() end
end

--- The control's own double click, on the builds that deliver one. From here
--- on the synthesised one is not needed and stops firing.
---
--- A real OnDblClick arrives right behind the down that completed the click,
--- with no other down in between, and that is how the one already fired is
--- told apart from a later one this handler has to fire itself.
function Surface:DoubleClick()
    local duplicate = self.DoubleAtDown == self.DownCount
    self.NativeDouble = true
    self.DoubleAtDown = nil
    if duplicate then return end
    if self.OnDoubleClick then self.OnDoubleClick(self.MouseX or 0, self.MouseY or 0) end
end

--
--- ∑ A wheel notch. The event carries no delta, so the direction is which of
---   the two handlers ran and this is where it becomes a number.
---
---   The owner hook runs first. A hook that reports true has dealt with the
---   notch itself, which is how a page zooms or refuses to scroll.
--- @param delta number # Minus one is up and one is down.
--- @return boolean # Always true, so the LCL stops passing the notch on.
--
function Surface:Wheel(delta)
    local handled = false
    if self.OnWheel then handled = self.OnWheel(delta) == true end
    if not handled then self:ScrollBy(delta * Defaults.WheelRows) end
    return true
end

--- A resize changes nothing we measured from the font, so it only asks for a
--- frame and tells the owner the new size.
function Surface:Resized()
    local width, height = self:Size()
    self:Invalidate()
    if self.OnResize then self.OnResize(width, height) end
end

--------------------------------------------------------
--                  Drawing helpers                   --
--------------------------------------------------------

--
--- ∑ Cuts a string to fit a pixel width and appends an ellipsis.
---
---   The character estimate short circuits the common case, so a full window
---   of rows costs a handful of real measurements. At Consolas the estimate is
---   exact. This is the only truncation path in the segment, because textRect
---   would render a record description through Cheat Engine's markup renderer.
--- @param canvas userdata
--- @param text string
--- @param width number # Pixels available.
--- @return string
--
function Surface:TextFit(canvas, text, width)
    text = tostring(text or "")
    width = tonumber(width) or 0
    if text == "" or width <= 0 then return "" end
    local measure = function(value) return tonumber(canvas.getTextWidth(value)) or 0 end
    local cache = self.MetricsCache
    local charWidth = cache and cache.CharWidth or 0
    if charWidth > 0 and #text * charWidth <= width * 0.9 then return text end
    if measure(text) <= width then return text end
    local low, high = 0, #text
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if measure(text:sub(1, middle) .. "...") <= width then low = middle else high = middle - 1 end
    end
    if low <= 0 then return "" end
    return text:sub(1, low) .. "..."
end

--
--- ∑ Which of the three states a check box value stands for.
---
---   A grid row for several records at once holds a mixed boolean rather than
---   a true or a false, and that value is a table, so asking whether it is
---   truthy would draw it ticked. The three answers are named here once so the
---   tree, the grid and the pages cannot each guess differently.
--- @param value any
--- @return string # on, off or mixed.
--
function Surface.CheckState(value)
    if value == true then return "on" end
    if value == false or value == nil then return "off" end
    if type(value) == "table" then return "mixed" end
    if value == "mixed" or value == "<mixed>" then return "mixed" end
    return "on"
end

--
--- ∑ The check box the tree and the grid both draw. A border, and inside it a
---   filled square when it is ticked or a bar across the middle when the rows
---   it stands for disagree.
---
---   Drawn with fillRect and nothing else. A Unicode tick depends on the font
---   having the glyph, and Consolas at ten pixels renders several of the
---   candidates as a box.
---
---   The brush is put back the way it was found. textOut in Cheat Engine is
---   opaque and fills its own cell with the brush before the glyphs go down,
---   so a box that walked away leaving the brush on the border or the tick
---   colour would paint the next piece of text on that colour. A row in the
---   tree draws five of these and then five pieces of text, which is how the
---   whole list ended up looking highlighted. Cheat Engine's own address list
---   has the same shape, and bsClear is not the way out of it because it
---   would stop fillRect painting anything at all.
--- @param canvas userdata
--- @param x number
--- @param y number
--- @param checked boolean|table|string|nil # True, false or a mixed marker.
--- @param colors table
--- @return number # The size it drew, so a caller can lay out the next column.
--
function Surface:DrawCheck(canvas, x, y, checked, colors)
    local size = Defaults.CheckSize
    local brush = self:BrushOf(canvas)
    local was = brush.Color
    local state = Surface.CheckState(checked)
    brush.Color = colors.CheckBorder or colors.Muted
    canvas.fillRect(x, y, x + size, y + 1)
    canvas.fillRect(x, y + size - 1, x + size, y + size)
    canvas.fillRect(x, y, x + 1, y + size)
    canvas.fillRect(x + size - 1, y, x + size, y + size)
    if state == "on" then
        brush.Color = colors.Check or colors.Accent
        canvas.fillRect(x + 2, y + 2, x + size - 2, y + size - 2)
    elseif state == "mixed" then
        -- A bar across the middle, the way every tri state box draws it. It is
        -- the tick colour so the box still reads as set, and it is thin so it
        -- never gets mistaken for a full one at a glance.
        local middle = y + math.floor(size / 2)
        brush.Color = colors.Check or colors.Accent
        canvas.fillRect(x + 2, middle - 1, x + size - 2, middle + 2)
    end
    if was ~= nil then brush.Color = was end
    return size
end

--
--- ∑ The expand arrow, a solid triangle pointing right when the record is
---   collapsed and down when it is open. Four line calls, no glyph.
---
---   The pen goes back the way it was found, for the same reason the check box
---   puts the brush back. A painter sets its colours per column and would
---   otherwise have to repeat itself after every glyph.
---
---   The arrow is muted, so on a selected or hovered row and on a header bar
---   it is lifted against that tone like the text beside it. A painter says
---   so by handing the tone over, and a plain row hands nothing.
--- @param canvas userdata
--- @param x number
--- @param y number
--- @param expanded boolean
--- @param colors table
--- @param background number|nil # The tone to stay readable on.
--- @return number # The size it drew.
--
function Surface:DrawExpand(canvas, x, y, expanded, colors, background)
    local size = Defaults.ExpandSize
    local pen = self:PenOf(canvas)
    local was = pen.Color
    local color = colors.Muted or colors.Text
    if background ~= nil then color = self:Legible(color, background) end
    pen.Color = color
    for step = 0, 3 do
        if expanded then
            canvas.line(x + step, y + 2 + step, x + size - 1 - step, y + 2 + step)
        else
            canvas.line(x + 2 + step, y + step, x + 2 + step, y + size - 1 - step)
        end
    end
    if was ~= nil then pen.Color = was end
    return size
end

--
--- ∑ The centred two line message a list shows when it has nothing in it. An
---   empty canvas with no words on it reads as a broken window.
---
---   The message sits on the canvas background, so the brush is put on that
---   colour here and not taken from whoever painted last. textOut is opaque
---   and fills its cell with the brush, and a list with a header left it on
---   the header tone, which put both lines on a box of that colour. A painter
---   that draws a bar or a check box before the message can no longer tint it.
---
---   The brush, the font colour and the font style are all put back, so a
---   painter that draws an empty state and then carries on with a header or a
---   scrollbar finds them the way it left them.
--- @param canvas userdata
--- @param width number
--- @param height number
--- @param colors table
--- @param title string
--- @param hint string|nil
--- @return nil
--
function Surface:DrawEmpty(canvas, width, height, colors, title, hint)
    local metrics = self:Metrics(canvas)
    local font = self:FontOf(canvas)
    local brush = self:BrushOf(canvas)
    local empty = self.EmptyStyle or ""
    local wasColor, wasStyle, wasBrush = font.Color, font.Style, brush.Color
    brush.Color = colors.Background
    local function centre(text)
        local measured = tonumber(canvas.getTextWidth(text)) or 0
        return math.max(0, math.floor((width - measured) / 2))
    end
    local y = math.max(0, math.floor(height / 2) - metrics.RowHeight)
    if title and title ~= "" then
        font.Style = "[fsBold]"
        font.Color = colors.Text
        canvas.textOut(centre(title), y, title)
        font.Style = empty
    end
    if hint and hint ~= "" then
        font.Color = colors.Muted
        canvas.textOut(centre(hint), y + metrics.RowHeight, hint)
    end
    if wasColor ~= nil then font.Color = wasColor end
    if wasStyle ~= nil then font.Style = wasStyle end
    if wasBrush ~= nil then brush.Color = wasBrush end
end

--
--- ∑ Draws a piece of text with some of its characters on a highlight, which
---   is how a filter match and a search hit are shown.
---
---   It draws the text in runs and switches the brush between them, rather
---   than filling a rectangle and typing over it. textOut is opaque, so a fill
---   that went down first would be painted over by the very text it was meant
---   to sit behind, and the highlight would either vanish or spread across the
---   whole column depending on which colour the brush was left on. Switching
---   the brush per run is what makes the opacity do the work.
---
---   The brush is put back the way it was found.
--- @param canvas userdata
--- @param x number
--- @param y number
--- @param text string
--- @param spans table|nil # { { Start, Stop }, ... } over text, one based.
--- @param background number|nil # What the row behind the text is painted in.
--- @param highlight number|nil # What a matched run sits on.
--- @return number # How wide the text came out, so a caller can go on.
--
function Surface:DrawRuns(canvas, x, y, text, spans, background, highlight)
    text = tostring(text or "")
    if text == "" then return 0 end
    local brush = self:BrushOf(canvas)
    local was = brush.Color
    local left = x
    local function run(piece, color)
        if piece == "" then return end
        if color ~= nil then brush.Color = color end
        canvas.textOut(left, y, piece)
        left = left + (tonumber(canvas.getTextWidth(piece)) or 0)
    end
    if type(spans) ~= "table" or #spans == 0 then
        run(text, background)
    else
        local cursor = 1
        for _, span in ipairs(spans) do
            local start = math.floor(tonumber(span.Start or span[1]) or 1)
            local stop = math.min(#text, math.floor(tonumber(span.Stop or span[2]) or 0))
            if start < cursor then start = cursor end
            if stop >= start then
                run(text:sub(cursor, start - 1), background)
                run(text:sub(start, stop), highlight)
                cursor = stop + 1
            end
        end
        run(text:sub(cursor), background)
    end
    if was ~= nil then brush.Color = was end
    return left - x
end

--------------------------------------------------------
--                   The list painter                 --
--------------------------------------------------------

--
--- ∑ A column driven list with hit testing, hover, one selected row, keyboard
---   handling and its own scrollbar.
---
---   The results strip, the pointer level list, the hotkey table and the drop
---   down preview are all the same list with different columns, so they share
---   this one instead of growing four selection models between three builders.
---   A list with a multiple selection is the record tree, which is its own
---   module for that reason.
---
---   An item is a plain table. A column reads item[Key], or calls its own Text
---   function, so no item has to be reshaped to be shown.
--
local List = {}
List.__index = List
Surface.ListClass = List

--- The text of one column for one item. A column's own Text function wins,
--- which is how a computed column such as a formatted key combination works.
local function columnText(column, item)
    if column.Text then
        local ok, text = pcall(column.Text, item)
        if ok and text ~= nil then return tostring(text) end
        return ""
    end
    local value = item[column.Key]
    if value == nil then return "" end
    if value == true then return "yes" end
    if value == false then return "no" end
    return tostring(value)
end

--- The colour of one column for one item, in the order a caller expects. The
--- column's own function first, then the item's override, then the column's
--- colour key, then the reading colour.
local function columnColor(column, item, colors)
    local answer
    if column.ColorFor then
        local ok, value = pcall(column.ColorFor, item, colors)
        if ok then answer = value end
    end
    if answer == nil and type(item.ColorKeys) == "table" then
        answer = item.ColorKeys[column.Key]
    end
    if answer == nil then answer = column.ColorKey end
    if type(answer) == "string" then return colors[answer] or colors.Text end
    if type(answer) == "number" then return answer end
    return colors.Text
end

--
--- ∑ Builds a list on this surface. It installs itself as the painter and
---   takes the mouse hooks, so the owner only sets items and reads back what
---   is selected.
--- @param options table|nil # Columns, Header, Stripe, Empty, OnPick and OnOpen.
--- @return table
--
function Surface:ListPainter(options)
    options = options or {}
    local list = setmetatable({
        Surface  = self,
        Columns  = {},
        Items    = {},
        Header   = options.Header == true,
        Stripe   = options.Stripe ~= false,
        Empty    = options.Empty,        -- { Title, Hint }
        Selected = nil,                  -- index into Items
        Hover    = nil,
        Geometry = nil,                  -- filled on every paint, read by HitTest
        OnPick   = options.OnPick,
        OnOpen   = options.OnOpen
    }, List)
    list:SetColumns(options.Columns)
    self.List = list
    self:SetPainter(function(_, canvas, width, height, colors, metrics)
        list:Paint(canvas, width, height, colors, metrics)
    end)
    self.OnMouseDown = function(button, x, y) list:MouseDown(button, x, y) end
    self.OnMouseMove = function(x, y) list:MouseMove(x, y) end
    self.OnMouseLeave = function() list:MouseLeave() end
    self.OnDoubleClick = function() list:Open() end
    return list
end

--
--- ∑ Sets the columns. Width is in characters, and a width of zero means the
---   column takes what is left, so a message column grows with the window
---   while a tag column does not.
--- @param columns table|nil
--- @return nil
--
function List:SetColumns(columns)
    local out = {}
    for index, column in ipairs(columns or {}) do
        out[index] = {
            Key      = column.Key or ("column" .. index),
            Title    = column.Title,
            Width    = math.max(0, tonumber(column.Width) or 0),
            Align    = column.Align == "right" and "right" or "left",
            ColorKey = column.ColorKey or "Text",
            Bold     = column.Bold == true,
            Text     = column.Text,
            ColorFor = column.ColorFor
        }
    end
    self.Columns = out
    self.Surface:Invalidate()
end

--
--- ∑ Replaces the items. The selected item is followed by identity, so a
---   refresh that rebuilt the list keeps the row the user was on.
--- @param items table|nil
--- @return nil
--
function List:SetItems(items)
    local previous = self.Selected and self.Items[self.Selected] or nil
    self.Items = items or {}
    self.Selected = nil
    if previous ~= nil then
        for index, item in ipairs(self.Items) do
            if item == previous then
                self.Selected = index
                break
            end
        end
    end
    self.Hover = nil
    self.Surface:SetScroll(#self.Items, self.Surface.Visible)
    self.Surface:Invalidate()
end

function List:Count() return #self.Items end
function List:All() return self.Items end
function List:At(index) return self.Items[index] end
function List:SelectedIndex() return self.Selected end

--- The selected item, or nothing when the list is empty or nothing was picked.
--- The index of it is a separate reader, because an owner usually wants one or
--- the other and never both.
function List:SelectedItem()
    if not self.Selected then return nil end
    return self.Items[self.Selected]
end

function List:SetEmpty(title, hint)
    self.Empty = { Title = title, Hint = hint }
    self.Surface:Invalidate()
end

--
--- ∑ Selects one row and, unless it was asked to stay quiet, tells the owner.
--- @param index number|nil
--- @param silent boolean|nil
--- @return table|nil # The item now selected.
--
function List:Select(index, silent)
    index = tonumber(index)
    if index == nil or index < 1 or index > #self.Items then
        self.Selected = nil
        self.Surface:Invalidate()
        return nil
    end
    index = math.floor(index)
    self.Selected = index
    self:EnsureVisible(index)
    self.Surface:Invalidate()
    local item = self.Items[index]
    if not silent and self.OnPick then self.OnPick(item, index) end
    return item
end

function List:ClearSelection()
    self.Selected = nil
    self.Surface:Invalidate()
end

--- Opens the selected row. Double click and Enter both land here.
function List:Open()
    local item = self:SelectedItem()
    if item and self.OnOpen then self.OnOpen(item, self.Selected) end
    return item
end

--- Brings a row on screen without moving it more than it has to.
function List:EnsureVisible(index)
    local surface = self.Surface
    local visible = math.max(1, surface.Visible)
    if index < surface.Top then
        surface:ScrollTo(index)
    elseif index > surface.Top + visible - 1 then
        surface:ScrollTo(index - visible + 1)
    end
end

--
--- ∑ Where the columns sit, worked out from the measured character width.
---
---   How many rows fit is worked out first and the scrollbar strip after it,
---   so the columns of a list that fits run to its right edge and a list that
---   scrolls makes room for the bar in the same frame it starts to draw one.
--- @param width number
--- @param height number
--- @param metrics table
--- @return table
--
function List:Layout(width, height, metrics)
    local pad = Defaults.PadX
    local headerHeight = self.Header and metrics.RowHeight or 0
    local visible = Scroll.Visible(height - headerHeight, metrics.RowHeight)
    local strip = Scroll.Strip(#self.Items, visible)
    local listWidth = math.max(0, width - strip)
    local fixed, flexible = 0, 0
    for _, column in ipairs(self.Columns) do
        if column.Width > 0 then
            fixed = fixed + math.floor(column.Width * metrics.CharWidth) + pad
        else
            flexible = flexible + 1
        end
    end
    local room = math.max(0, listWidth - pad - fixed)
    local share = flexible > 0 and math.floor(room / flexible) or 0
    local x, boxes = pad, {}
    for index, column in ipairs(self.Columns) do
        local columnWidth = column.Width > 0
            and math.floor(column.Width * metrics.CharWidth) or share
        boxes[index] = { X = x, W = columnWidth }
        x = x + columnWidth + pad
    end
    return {
        Width = width, Height = height, ListWidth = listWidth, Strip = strip,
        Boxes = boxes, RowHeight = metrics.RowHeight,
        HeaderHeight = headerHeight, Visible = visible, Top = 1
    }
end

--- The match spans of one column, or nothing when this column has none.
local function spansOf(item, column)
    local spans = type(item.Spans) == "table" and item.Spans[column.Key] or nil
    if type(spans) ~= "table" or #spans == 0 then return nil end
    return spans
end

--- Paints the match spans of one column over the full height of the row, so a
--- hit reads as a band and not as a strip the height of the glyphs. The text
--- runs go down afterwards and carry the same colour in their own cells, which
--- is what keeps the band whole under an opaque textOut.
---
--- The brush is put back, because the caller goes straight on to the text. It
--- is handed the x the text will really start at and not the left edge of the
--- column, so a right aligned column does not get its band drawn somewhere
--- the text never reaches.
local function paintSpans(self, canvas, textX, box, top, geometry, colors, shown, spans)
    local surface = self.Surface
    local brush = surface:BrushOf(canvas)
    local was = brush.Color
    brush.Color = colors.Match
    for _, span in ipairs(spans) do
        local start = math.max(1, tonumber(span.Start or span[1]) or 1)
        local stop = math.min(#shown, tonumber(span.Stop or span[2]) or 0)
        if stop >= start then
            local before = tonumber(canvas.getTextWidth(shown:sub(1, start - 1))) or 0
            local hit = tonumber(canvas.getTextWidth(shown:sub(start, stop))) or 0
            local left = textX + before
            local right = math.min(box.X + box.W, left + hit)
            canvas.fillRect(left, top + 1, right, top + geometry.RowHeight - 1)
        end
    end
    if was ~= nil then brush.Color = was end
end

--
--- ∑ Paints the whole list. Only the rows on screen are touched, whatever the
---   list cost to build.
--- @param canvas userdata
--- @param width number
--- @param height number
--- @param colors table
--- @param metrics table
--- @return nil
--
function List:Paint(canvas, width, height, colors, metrics)
    local surface = self.Surface
    local geometry = self:Layout(width, height, metrics)
    local rowHeight = geometry.RowHeight
    local listTop = geometry.HeaderHeight
    local visible = geometry.Visible
    surface:SetScroll(#self.Items, visible)
    geometry.Top = surface.Top
    self.Geometry = geometry

    local font = surface:FontOf(canvas)
    local brush = surface:BrushOf(canvas)
    local empty = surface.EmptyStyle or ""
    local textY = math.floor((rowHeight - metrics.TextHeight) / 2)

    if self.Header then
        -- The bar runs the full width and not only the list width, the way the
        -- tree's does. The scrollbar of a list that scrolls starts below it, and
        -- the corner above the bar would otherwise be the one unpainted notch.
        brush.Color = colors.Header
        canvas.fillRect(0, 0, width, rowHeight)
        -- A hairline under the bar. The chrome tone is a quiet step away from
        -- the rows, so this is what stops the titles running into the first
        -- row rather than a brighter fill would.
        brush.Color = colors.Rule
        canvas.fillRect(0, rowHeight - 1, width, rowHeight)
        brush.Color = colors.Header
        font.Color = surface:Legible(colors.Muted, colors.Header)
        for index, column in ipairs(self.Columns) do
            local box = geometry.Boxes[index]
            if column.Title and box.W > 0 then
                canvas.textOut(box.X, textY, surface:TextFit(canvas, column.Title, box.W))
            end
        end
    end

    if #self.Items == 0 then
        local message = self.Empty
        if message then
            surface:DrawEmpty(canvas, width, height, colors, message.Title, message.Hint)
        end
        surface:PaintScrollbar(canvas, width - Defaults.ScrollWidth, listTop,
            height - listTop, colors)
        return
    end

    local last = math.min(#self.Items, surface.Top + visible - 1)
    for index = surface.Top, last do
        local item = self.Items[index]
        local top = listTop + (index - surface.Top) * rowHeight
        local background = colors.Background
        -- A selected or hovered row is a tone the column colours were not
        -- picked for, so on those two every colour is lifted against it.
        local lifted = false
        if index == self.Selected then
            background, lifted = colors.Selection, true
        elseif index == self.Hover then
            background, lifted = colors.Hover, true
        elseif self.Stripe and index % 2 == 0 then
            background = colors.Stripe
        end
        brush.Color = background
        canvas.fillRect(0, top, geometry.ListWidth, top + rowHeight)

        for columnIndex, column in ipairs(self.Columns) do
            local box = geometry.Boxes[columnIndex]
            local text = columnText(column, item)
            if text ~= "" and box.W > 0 then
                local shown = surface:TextFit(canvas, text, box.W)
                if shown ~= "" then
                    local x = box.X
                    if column.Align == "right" then
                        x = box.X + box.W - (tonumber(canvas.getTextWidth(shown)) or 0)
                    end
                    local spans = spansOf(item, column)
                    if spans then
                        paintSpans(self, canvas, x, box, top, geometry, colors, shown, spans)
                    end
                    local color = columnColor(column, item, colors)
                    if lifted then color = surface:Legible(color, background) end
                    font.Color = color
                    if column.Bold then font.Style = "[fsBold]" end
                    surface:DrawRuns(canvas, x, top + textY, shown, spans, background, colors.Match)
                    if column.Bold then font.Style = empty end
                end
            end
        end
    end

    -- Called when the list fits as well. It draws nothing then, and it is what
    -- lets go of the thumb a longer list left behind.
    surface:PaintScrollbar(canvas, width - Defaults.ScrollWidth, listTop, height - listTop, colors)
end

--
--- ∑ The row under a point, or nothing over the header, over the scrollbar and
---   under the last row.
--- @param x number|nil
--- @param y number|nil
--- @return number|nil
--
function List:HitTest(x, y)
    local geometry = self.Geometry
    if not geometry or type(y) ~= "number" then return nil end
    if type(x) == "number" and x >= geometry.ListWidth then return nil end
    if y < geometry.HeaderHeight then return nil end
    return Scroll.RowAt(y - geometry.HeaderHeight, geometry.Top, geometry.RowHeight, #self.Items)
end

function List:MouseDown(button, x, y)
    local index = self:HitTest(x, y)
    if not index then return end
    -- The right button picks a row it was not on and leaves a row it was on
    -- alone, so a menu opens over what the user pointed at.
    if button == 1 and self.Selected == index then return end
    self:Select(index)
end

function List:MouseMove(x, y)
    local index = self:HitTest(x, y)
    if index ~= self.Hover then
        self.Hover = index
        self.Surface:Invalidate()
    end
end

function List:MouseLeave()
    if self.Hover ~= nil then
        self.Hover = nil
        self.Surface:Invalidate()
    end
end

--
--- ∑ The keys a list answers. The owner calls this from its own key handler,
---   because a canvas never takes focus and so never sees a key itself.
--- @param key number # Virtual key code.
--- @return boolean # Whether the key was used.
--
function List:HandleKey(key)
    local count = #self.Items
    if count == 0 then return false end
    local page = math.max(1, self.Surface.Visible - 1)
    local index = self.Selected or 0
    if key == 38 then return self:Step(index - 1) end
    if key == 40 then return self:Step(index + 1) end
    if key == 33 then return self:Step(index - page) end
    if key == 34 then return self:Step(index + page) end
    if key == 36 then return self:Step(1) end
    if key == 35 then return self:Step(count) end
    if key == 13 then
        self:Open()
        return true
    end
    return false
end

--- Moves the selection to a row that exists. Off either end lands on the row
--- at that end, the way every list in Windows behaves.
function List:Step(index)
    local count = #self.Items
    if count == 0 then return false end
    index = math.max(1, math.min(count, math.floor(index)))
    self:Select(index)
    return true
end

--------------------------------------------------------
--                      Teardown                      --
--------------------------------------------------------

--
--- ∑ Releases what this surface owns and leaves the frame service. The control
---   itself belongs to its parent form and is freed with it.
--- @return nil
--
function Surface:Destroy()
    local frame = self.Frame
    if frame and type(frame.Remove) == "function" then frame:Remove(self) end
    if self.Buffer then
        pcall(function() self.Buffer.destroy() end)
        self.Buffer = nil
    end
    self.BufferWidth, self.BufferHeight = 0, 0
    -- The image path's bitmap belongs to the TImage's Picture, which the form
    -- frees along with the control, so it is dropped and not destroyed.
    self.PictureBitmap = nil
    self.Control, self.Kind, self.Parent = nil, nil, nil
    self.FrameCanvas, self.FrameFont, self.FrameBrush, self.FramePen = nil, nil, nil, nil
    self.Painter, self.List = nil, nil
    self.MetricsCache, self.SurfaceColors, self.CachedPalette = nil, nil, nil
    self.LegibleCache, self.LegibleFor = nil, nil
    self.Dirty = false
end

return Surface
