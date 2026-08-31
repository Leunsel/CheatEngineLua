--[[
    The icon set, for menus and for the canvas.

    Menus want a TImageList and an index per item, the same mechanism
    Manifold-TemplateLoader-Icons uses. The log view draws its own glyphs on a
    canvas at whatever y a row sits at, so a list index is no use there. Each
    icon is composited once onto an opaque bitmap of the row's background
    colour and cached, by icon then by background, and the cache is dropped
    when the palette moves, the only time a background changes. The LCL will
    alpha-blend a TPortableNetworkGraphic through Canvas.Draw on Win32, but
    that is a StretchMaskBlt per glyph, per row, per repaint, and a build that
    does not blend draws a black tile.

    API facts, out of the CE 7.5 and Lazarus sources:
      * createPNG(w,h) returns a TPortableNetworkGraphic, descending
        TFPImageBitmap, TCustomBitmap, TGraphic. Valid for both
        customimagelist_add (casts to TCustomBitmap) and canvas.draw (wants a
        TGraphic).
      * createBitmap():loadFromFile('x.png') does not work. TBitmap reads BMP
        only (GetReaderClass gives TLazReaderBMP) and TGraphic.LoadFromFile
        does no format sniffing, so the BMP reader runs over PNG bytes and
        raises.
      * createPicture() is a TPicture, not a TGraphic. Passing one to add() or
        canvas.draw is an unchecked pointer type-pun, and picture.getBitmap()
        converts in place and frees the PNG. Unused here.
      * graphic.loadFromFile has no try/except in CE's binding, so it is
        pcall'd, and the PNG magic is checked before the decoder sees the file.
      * imagelist.add never returns -1. Given nil it returns the pre-insert
        Count, a phantom index for an image it did not add. Success is checked
        by watching Count rise.
      * A size mismatch stretches (TFPImageCanvas.StretchDraw), it does not
        centre or clip. The PNGs and the list are both 16x16.

    None of this is required for the console to work. Every entry point reports
    failure and the view falls back to a drawn glyph in the level's colour.
]]

local sep = package.config:sub(1, 1)

local Icons = {}
Icons.__index = Icons

local instance = nil

Icons.Folder = "Manifold-Icons"
Icons.ModulesFolder = "Manifold-Logger-Modules"
Icons.IconSize = 16

--- Logical name to file. The level names match Manifold-Logger-Core.Meta.Icon,
--- the rest are the console's own verbs.
Icons.Files = {
    -- Levels
    Trace         = "Manifold-Trace.png",
    Debug         = "Manifold-Debug.png",
    Info          = "Manifold-Info.png",
    Success       = "Manifold-Success.png",
    Warning       = "Manifold-Warning.png",
    Error         = "Manifold-Error.png",
    Critical      = "Manifold-Critical.png",
    -- Console verbs
    Pause         = "Manifold-Pause.png",
    Follow        = "Manifold-Follow.png",
    Search        = "Manifold-Search.png",
    Filter        = "Manifold-Filter.png",
    Wrap          = "Manifold-Wrap.png",
    Export        = "Manifold-Export.png",
    Clear         = "Manifold-Clear.png",
    ClearFilters  = "Manifold-Clear-Filters.png",
    Pin           = "Manifold-Pin.png",
    Channel       = "Manifold-Channel.png",
    Detail        = "Manifold-Detail.png",
    Metrics       = "Manifold-Metrics.png",
    -- Shared Manifold set
    Copy          = "Manifold-Copy.png",
    CopySelected = "Manifold-Copy-Selected.png",
    SelectAll     = "Manifold-Select-All.png",
    Eye           = "Manifold-Eye.png",
    File          = "Manifold-File.png",
    Folder        = "Manifold-Folder.png",
    Level         = "Manifold-Level.png",
    Logging       = "Manifold-Logging.png",
    Reset         = "Manifold-Reset.png",
    Reload        = "Manifold-Reload.png",
    Settings      = "Manifold-Settings.png",
    Status        = "Manifold-Status.png",
    WriteFile     = "Manifold-WriteFile.png",
    About         = "Manifold-About.png",
    Recent        = "Manifold-Recent.png",
    Diagnostics   = "Manifold-Diagnostics.png",
    SelfCheck     = "Manifold-SelfCheck.png",
    Memory        = "Manifold-Memory.png",
    Favorite      = "Manifold-Favorite.png",
    FavoriteOff   = "Manifold-FavoriteOff.png",
    TextSmaller   = "Manifold-Smaller-Text.png",
    TextLarger    = "Manifold-Larger-Text.png",
    Rotate        = "Manifold-Rotate-Text.png",
    WrapLongLines = "Manifold-Wrap-Long-Lines.png"
}

--
--- ∑ The singleton. One image list per Cheat Engine session. A hot reload that
---   built a second one would leak the first, and every menu item still
---   pointing at it would resolve indices against a list nobody updates.
--- @param options table|nil # { Root }, autorun path override for tests.
--- @return table
--
function Icons:New(options)
    if not instance then
        instance = setmetatable({
            Root = nil,
            List = nil,
            Index = {},      -- name -> image list index
            Graphics = {},   -- name -> TPortableNetworkGraphic, for the canvas
            Composites = {}, -- name -> background -> opaque TBitmap
            CompositeCount = 0,
            Loaded = false,
            Reason = nil,
            Missing = {}
        }, Icons)
    end
    if options and options.Root then instance.Root = options.Root end
    return instance
end

--
--- ∑ Absolute path of one icon file.
--- @param fileName string
--- @return string
--
function Icons:PathOf(fileName)
    local root = self.Root
    if not root then
        local getPath = rawget(_G, "getAutorunPath")
        root = type(getPath) == "function" and getPath() or ""
        root = root .. self.ModulesFolder .. sep
    end
    return root .. self.Folder .. sep .. fileName
end

--
--- ∑ True when the file exists and really begins with the PNG signature. CE's
---   graphic.loadFromFile has no try/except, so the decoder must never be
---   handed something it cannot read.
--- @param path string
--- @return boolean, string|nil
--
local function looksLikePng(path)
    local handle = io.open(path, "rb")
    if not handle then return false, "not found" end
    local magic = handle:read(8)
    handle:close()
    if magic ~= "\137PNG\r\n\26\n" then return false, "not a PNG" end
    return true
end

--
--- ∑ Loads one PNG into a TPortableNetworkGraphic.
--- @param path string
--- @return userdata|nil, string|nil
--
function Icons:LoadGraphic(path)
    local okMagic, magicErr = looksLikePng(path)
    if not okMagic then return nil, magicErr end
    local createFn = rawget(_G, "createPNG")
    if type(createFn) ~= "function" then return nil, "createPNG is not available" end
    -- createPNG with no arguments defaults to the SCREEN size, so ask for 1x1.
    -- loadFromFile replaces contents and dimensions anyway.
    local ok, png = pcall(createFn, 1, 1)
    if not ok or png == nil then return nil, "createPNG failed: " .. tostring(png) end
    local loaded, loadErr = pcall(function() png.loadFromFile(path) end)
    if not loaded then return nil, "loadFromFile failed: " .. tostring(loadErr) end
    return png
end

--
--- ∑ Builds the image list and loads every icon into it. Idempotent. A hard
---   failure is remembered, not retried on every menu build.
--- @return boolean, string|nil
--
function Icons:Load()
    if self.Loaded then return true end
    if self.Reason then return false, self.Reason end
    local createList = rawget(_G, "createImageList")
    if type(createList) ~= "function" then
        self.Reason = "createImageList is not available"
        return false, self.Reason
    end
    local ok, list = pcall(createList)
    if not ok or list == nil then
        self.Reason = "createImageList failed: " .. tostring(list)
        return false, self.Reason
    end
    -- Match the artwork exactly so Insert never reaches StretchDraw. Width and
    -- Height go through CE's published-property RTTI fallback, so read them
    -- back instead of trusting the write.
    pcall(function() list.Width = self.IconSize end)
    pcall(function() list.Height = self.IconSize end)
    local okW, width = pcall(function() return list.Width end)
    local okH, height = pcall(function() return list.Height end)
    if okW and okH and (width ~= self.IconSize or height ~= self.IconSize) then
        pcall(function() list.destroy() end)
        self.Reason = string.format("image list is %sx%s, icons are %dx%d, refusing to ship stretched art",
            tostring(width), tostring(height), self.IconSize, self.IconSize)
        return false, self.Reason
    end
    local index, graphics, loadedCount, missing = {}, {}, 0, {}
    for name, fileName in pairs(self.Files) do
        local png, err = self:LoadGraphic(self:PathOf(fileName))
        if png then
            -- add() never returns -1. Given nil it returns the pre-insert
            -- Count for an image it did not insert. Watch Count instead.
            local before = tonumber(list.Count) or 0
            local added, position = pcall(function() return list.add(png) end)
            local after = tonumber(list.Count) or before
            if added and after > before and type(position) == "number" then
                index[name] = position
            else
                missing[#missing + 1] = fileName .. " (add rejected it)"
            end
            -- Kept whatever the list said. The canvas path uses the graphic
            -- directly and never touches the list.
            graphics[name] = png
            loadedCount = loadedCount + 1
        else
            missing[#missing + 1] = fileName .. " (" .. tostring(err) .. ")"
        end
    end
    if loadedCount == 0 then
        pcall(function() list.destroy() end)
        self.Reason = "no icons could be loaded: " .. table.concat(missing, ", ")
        return false, self.Reason
    end
    self.List = list
    self.Index = index
    self.Graphics = graphics
    self.Missing = missing
    self.Loaded = true
    return true
end

--- The image list, or nil when loading failed.
function Icons:GetList()
    if not self.Loaded and not self:Load() then return nil end
    return self.List
end

--- Index of one icon inside GetList(), or nil.
function Icons:GetIndex(name)
    if not self.Loaded and not self:Load() then return nil end
    return self.Index[name]
end

--- The raw graphic, for callers that draw it themselves.
function Icons:GetGraphic(name)
    if not self.Loaded and not self:Load() then return nil end
    return self.Graphics[name]
end

function Icons:Available()
    return self.Loaded or self:Load()
end

--------------------------------------------------------
--                     Menu glyphs                    --
--------------------------------------------------------

--
--- ∑ Attaches this list to a parent menu item so its CHILDREN resolve their
---   ImageIndex against it.
---
---   SubMenuImages, not ImageList. TMenuItem has no ImageList property in any
---   Lazarus version, and CE's lua_setProperty stashes unknown property writes
---   in the userdata's metatable inside a try/except, so writing item.ImageList
---   assigns cleanly, reads back correctly, and does nothing. Resolution is
---   TMenuItem.GetImageList, which starts at the item's PARENT and walks up to
---   the nearest ancestor with a non-nil SubMenuImages, then falls back to the
---   owning menu's Images. An item's own SubMenuImages never applies to itself,
---   only to its children.
--- @param parentItem userdata
--- @return boolean
--
function Icons:AttachTo(parentItem)
    local list = self:GetList()
    if not parentItem or not list then return false end
    return (pcall(function() parentItem.SubMenuImages = list end)) == true
end

--
--- ∑ Sets an icon on one item. TMenuItem.SetImageIndex early-exits when the new
---   value equals the old, and again when no image list resolves. So write -1
---   first to force a real transition, and only after SubMenuImages is attached
---   to the parent.
--- @param item userdata
--- @param name string
--- @return boolean
--
function Icons:Apply(item, name)
    local position = self:GetIndex(name)
    if not item or not position then return false end
    pcall(function() item.ImageIndex = -1 end)
    local ok = pcall(function() item.ImageIndex = position end)
    -- Menu glyphs can be suppressed by Application.ShowMenuGlyphs or the OS
    -- "show menu icons" setting. Ask for them explicitly. A failure is ignored,
    -- the enum is only reachable through CE's RTTI fallback.
    pcall(function() item.GlyphShowMode = "gsmAlways" end)
    return ok == true
end

--------------------------------------------------------
--                    Canvas glyphs                   --
--------------------------------------------------------

--
--- ∑ An opaque 16x16 bitmap of one icon over one background colour, built on
---   first use and cached. The row draw is then a plain opaque blit, so it
---   costs the same whatever the widgetset thinks about alpha, and the blend
---   runs once per icon and background, not once per row per repaint.
--- @param name string
--- @param background number # Cheat Engine BGR colour of the row underneath.
--- @return userdata|nil
--
function Icons:Composite(name, background)
    -- Two levels rather than one key built by concatenation. This is called
    -- once per visible row per frame, and a built key would allocate and hash
    -- a string per row per frame for nothing.
    local byBackground = self.Composites[name]
    if byBackground == nil then
        byBackground = {}
        self.Composites[name] = byBackground
    end
    local cached = byBackground[background]
    if cached ~= nil then
        -- false is a remembered failure. Retrying it on every row would turn
        -- one broken icon into a stall.
        return cached or nil
    end
    local graphic = self:GetGraphic(name)
    if not graphic then
        byBackground[background] = false
        return nil
    end
    local createFn = rawget(_G, "createBitmap")
    if type(createFn) ~= "function" then
        byBackground[background] = false
        return nil
    end
    local size = self.IconSize
    local ok, bitmap = pcall(createFn, size, size)
    if not ok or not bitmap then
        byBackground[background] = false
        return nil
    end
    local painted = pcall(function()
        local canvas = bitmap.Canvas
        canvas.Brush.Color = background
        canvas.fillRect(0, 0, size, size)
        canvas.draw(0, 0, graphic)
    end)
    if not painted then
        pcall(function() bitmap.destroy() end)
        byBackground[background] = false
        return nil
    end
    byBackground[background] = bitmap
    self.CompositeCount = self.CompositeCount + 1
    return bitmap
end

--
--- ∑ Draws one icon at (x, y) on a canvas.
--- @param canvas userdata
--- @param x number
--- @param y number
--- @param name string
--- @param background number # The colour already painted underneath.
--- @return boolean # False when the caller should draw its own fallback glyph.
--
function Icons:DrawOn(canvas, x, y, name, background)
    if not canvas or not name then return false end
    local bitmap = self:Composite(name, background)
    if bitmap then
        -- The caller draws inside its own protected frame, and the composite
        -- is already a bitmap this canvas accepted once.
        canvas.draw(x, y, bitmap)
        return true
    end
    -- No composite. Try the graphic straight onto the canvas. A build that
    -- blends looks identical, one that does not draws a black tile, so a
    -- failure is reported and the caller's fallback wins.
    local graphic = self:GetGraphic(name)
    if not graphic then return false end
    return (pcall(function() canvas.draw(x, y, graphic) end)) == true
end

--
--- ∑ Drops the composited bitmaps. Called when the palette changes, since each
---   one is baked against a background colour that no longer exists.
--- @return nil
--
function Icons:Invalidate()
    for _, byBackground in pairs(self.Composites) do
        for _, bitmap in pairs(byBackground) do
            if bitmap then pcall(function() bitmap.destroy() end) end
        end
    end
    self.Composites = {}
    self.CompositeCount = 0
end

--
--- ∑ Releases everything. The singleton stays, so a later Load rebuilds from
---   scratch rather than handing out destroyed userdata.
--- @return nil
--
function Icons:Destroy()
    self:Invalidate()
    for _, graphic in pairs(self.Graphics) do
        pcall(function() graphic.destroy() end)
    end
    self.Graphics = {}
    if self.List then pcall(function() self.List.destroy() end) end
    self.List = nil
    self.Index = {}
    self.Loaded = false
    self.Reason = nil
end

--
--- ∑ Diagnostic. Run it once and read the result before trusting the rest of
---   this file on a Cheat Engine build it has not seen.
--- @return table
--
function Icons:Probe()
    local report = {
        createPNG = type(rawget(_G, "createPNG")),
        createImageList = type(rawget(_G, "createImageList")),
        createBitmap = type(rawget(_G, "createBitmap")),
        folder = self:PathOf(""),
        files = {}
    }
    for name, fileName in pairs(self.Files) do
        local okMagic, magicErr = looksLikePng(self:PathOf(fileName))
        report.files[name] = okMagic and "ok" or tostring(magicErr)
    end
    local loaded, reason = self:Load()
    report.loaded = loaded
    report.reason = reason
    report.count = self.List and tonumber(self.List.Count) or 0
    report.indices = self.Index
    report.missing = self.Missing
    report.composites = self.CompositeCount
    return report
end

return Icons
