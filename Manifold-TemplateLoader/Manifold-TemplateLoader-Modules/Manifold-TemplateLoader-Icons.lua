--[[
    Custom menu icons for the Template Loader.

    Loads the PNGs in Manifold-Icons/ into a dedicated TImageList and hands out
    indices. The list is OURS: nothing is added to CE's own aaImageList, so no
    index CE relies on can shift, and a hot reload cannot grow a shared list
    without bound.

    The API facts this file depends on, all read out of the CE 7.5 and Lazarus
    sources rather than assumed:

      * createPNG(w,h) returns a TPortableNetworkGraphic, which descends
        TFPImageBitmap -> TCustomBitmap. CE's customimagelist_add casts its
        first argument to exactly TCustomBitmap, so a PNG object is the one
        conversion-free thing you can hand it.
      * createBitmap():loadFromFile('x.png') does NOT work. TBitmap reads only
        BMP (GetReaderClass -> TLazReaderBMP) and TGraphic.LoadFromFile does no
        format sniffing, so it runs the BMP reader over PNG bytes and raises.
      * createPicture() is a TPicture, which is NOT a TCustomBitmap. Handing one
        to add() is an unchecked pointer type-pun, and picture.getBitmap()
        CONVERTS in place and FREES the PNG behind your back. Avoided entirely.
      * graphic.loadFromFile has no try/except in CE's binding, so it must be
        pcall'd, and we pre-check the PNG magic so the decoder never sees input
        it could choke on.
      * imagelist.add NEVER returns -1. Given nil it returns the pre-insert
        Count - a phantom index for an image that was never added - so success
        is verified by watching Count actually increase.
      * Alpha survives. TCustomImageList.Insert copies RGBA per pixel and the
        Win32 list is created ILC_COLOR32; Masked/DrawingStyle defaults are
        already correct and must NOT be touched.
      * A size mismatch STRETCHES (TFPImageCanvas.StretchDraw), it does not
        centre or clip. The PNGs are 16x16 and so is this list, so nothing is
        resampled.
]]

local sep = package.config:sub(1, 1)

local Icons = {}
Icons.__index = Icons

local instance = nil

Icons.Folder = "Manifold-Icons"
Icons.IconSize = 16

--- Level name -> file. SUCCESS has no log level; it marks "log file is on".
Icons.Files = {
    DEBUG    = "Manifold-Debug.png",
    INFO     = "Manifold-Info.png",
    WARNING  = "Manifold-Warning.png",
    ERROR    = "Manifold-Error.png",
    CRITICAL = "Manifold-Critical.png",
    SUCCESS  = "Manifold-Success.png",
}

function Icons:New()
    if not instance then
        instance = setmetatable({
            List = nil,
            Index = {},
            Loaded = false,
            Reason = nil,
        }, Icons)
    end
    return instance
end

--
--- Absolute path of one icon.
--
function Icons:PathOf(fileName)
    return getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep
        .. self.Folder .. sep .. fileName
end

--
--- True when the file exists and really begins with the PNG signature.
--- CE's graphic.loadFromFile has no try/except, so the decoder must never be
--- handed something it cannot read.
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
--- Loads one PNG into a TPortableNetworkGraphic.
--- @return userdata|nil, string|nil
--
function Icons:LoadGraphic(path)
    local okMagic, magicErr = looksLikePng(path)
    if not okMagic then return nil, magicErr end

    local createFn = rawget(_G, "createPNG")
    if type(createFn) ~= "function" then return nil, "createPNG is not available" end

    -- Explicit 1x1: createPNG defaults to the SCREEN size when called with no
    -- arguments. loadFromFile replaces the contents and the dimensions anyway.
    local ok, png = pcall(createFn, 1, 1)
    if not ok or png == nil then return nil, "createPNG failed: " .. tostring(png) end

    local loaded, loadErr = pcall(function() png.loadFromFile(path) end)
    if not loaded then return nil, "loadFromFile failed: " .. tostring(loadErr) end
    return png
end

--
--- Builds the image list and loads every icon into it. Idempotent.
--- @return boolean, string|nil # loaded, reason when it did not
--
function Icons:Load()
    if self.Loaded then return true end
    if self.Reason then return false, self.Reason end   -- do not retry a hard failure
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
    -- Height go through CE's published-property RTTI fallback rather than an
    -- explicit binding, so read them back instead of trusting the write.
    pcall(function() list.Width = self.IconSize end)
    pcall(function() list.Height = self.IconSize end)
    local okW, width = pcall(function() return list.Width end)
    local okH, height = pcall(function() return list.Height end)
    if okW and okH and (width ~= self.IconSize or height ~= self.IconSize) then
        self.Reason = string.format("image list is %sx%s, icons are %dx%d - refusing to ship stretched art",
            tostring(width), tostring(height), self.IconSize, self.IconSize)
        return false, self.Reason
    end
    local index, loadedCount, missing = {}, 0, {}
    for name, fileName in pairs(self.Files) do
        local png, err = self:LoadGraphic(self:PathOf(fileName))
        if png then
            -- add() never returns -1; given nil it returns the pre-insert Count
            -- for an image it did not insert. Watch Count instead.
            local before = tonumber(list.Count) or 0
            local added, position = pcall(function() return list.add(png) end)
            local after = tonumber(list.Count) or before
            if added and after > before and type(position) == "number" then
                index[name] = position
                loadedCount = loadedCount + 1
            else
                missing[#missing + 1] = fileName .. " (add rejected it)"
            end
        else
            missing[#missing + 1] = fileName .. " (" .. tostring(err) .. ")"
        end
    end
    if loadedCount == 0 then
        self.Reason = "no icons could be loaded: " .. table.concat(missing, ", ")
        return false, self.Reason
    end
    self.List = list
    self.Index = index
    self.Loaded = true
    self.Missing = missing
    return true
end

--
--- The image list, or nil when loading failed.
--
function Icons:GetList()
    if not self.Loaded and not self:Load() then return nil end
    return self.List
end

--
--- Index of one icon inside GetList(), or nil.
--- @param name string # DEBUG / INFO / WARNING / ERROR / CRITICAL / SUCCESS
--
function Icons:GetIndex(name)
    if not self.Loaded and not self:Load() then return nil end
    return self.Index[name]
end

--
--- Attaches this list to a parent menu item so its CHILDREN resolve their
--- ImageIndex against it.
---
--- SubMenuImages, not ImageList. TMenuItem has no ImageList property in any
--- Lazarus version - CE's lua_setProperty stashes unknown property writes in
--- the userdata's metatable inside a try..except, so `item.ImageList = list`
--- assigns cleanly, reads back correctly, and does absolutely nothing.
--- Resolution is TMenuItem.GetImageList: it starts at the item's PARENT and
--- walks up to the nearest ancestor with a non-nil SubMenuImages, then falls
--- back to the owning menu's Images. Because the walk starts at Parent, an
--- item's own SubMenuImages never applies to itself - only to its children,
--- which is exactly what is wanted here.
--- @return boolean
--
function Icons:AttachTo(parentItem)
    local list = self:GetList()
    if not parentItem or not list then return false end
    local ok = pcall(function() parentItem.SubMenuImages = list end)
    return ok == true
end

--
--- Sets an icon on one item.
--- TMenuItem.SetImageIndex early-exits when the new value equals the old, and
--- again when no image list resolves - so write -1 first to guarantee a real
--- transition, and only after SubMenuImages is already attached to the parent.
--- @return boolean
--
function Icons:Apply(item, name)
    local position = self:GetIndex(name)
    if not item or not position then return false end
    pcall(function() item.ImageIndex = -1 end)
    local ok = pcall(function() item.ImageIndex = position end)
    -- Menu glyphs can be suppressed by Application.ShowMenuGlyphs or the OS
    -- "show menu icons" setting. Ask for them explicitly; ignore a failure,
    -- since the enum is only reachable through CE's RTTI fallback.
    pcall(function() item.GlyphShowMode = "gsmAlways" end)
    return ok == true
end

--
--- Diagnostic. Run this once in CE and read the log before trusting any of the
--- above: none of it was executed when it was written.
--- @return table
--
function Icons:Probe()
    local report = {
        createPNG = type(rawget(_G, "createPNG")),
        createImageList = type(rawget(_G, "createImageList")),
        folder = self:PathOf(""),
        files = {},
    }
    for name, fileName in pairs(self.Files) do
        local path = self:PathOf(fileName)
        local okMagic, magicErr = looksLikePng(path)
        report.files[name] = okMagic and "ok" or tostring(magicErr)
    end
    local loaded, reason = self:Load()
    report.loaded = loaded
    report.reason = reason
    report.count = self.List and tonumber(self.List.Count) or 0
    report.indices = self.Index
    report.missing = self.Missing
    return report
end

return Icons