--[[
    The icon set for the menu.

    A sibling of Manifold-Logger-Icons, trimmed to what a menu needs: one
    TImageList and an index per item. The canvas half of the Logger's module
    has no use here.

    The 1.x utility borrowed bitmaps off Cheat Engine's own menu items and
    pushed them into the main form's image list. Every re-execution added
    seven more images to a list Cheat Engine owns, and which bitmaps existed
    depended on which forms had been built yet. This module ships its own
    PNGs and its own list instead, so the menu looks the same on every start
    and nothing of Cheat Engine's is modified.

    API facts, out of the CE 7.5 and Lazarus sources:
      * createPNG(w,h) returns a TPortableNetworkGraphic, which
        customimagelist_add accepts. createBitmap():loadFromFile('x.png')
        does not work: TBitmap reads BMP only and TGraphic.LoadFromFile does
        no format sniffing.
      * graphic.loadFromFile has no try/except in CE's binding, so it is
        pcall'd, and the PNG magic is checked before the decoder sees the
        file.
      * imagelist.add never returns -1. Given nil it returns the pre-insert
        Count, a phantom index for an image it did not add. Success is
        checked by watching Count rise.
      * TMenuItem has no ImageList property. Children resolve their
        ImageIndex against the nearest ancestor's SubMenuImages, so the list
        is attached to the root item, once.
      * TMenuItem.SetImageIndex early-exits when the new value equals the old
        and when no list resolves, so -1 is written first to force a real
        transition, after the list is attached.

    None of this is required for the menu to work. Every entry point reports
    failure and the entries simply have no glyph.
]]

local sep = package.config:sub(1, 1)

local Icons = {}
Icons.__index = Icons

local instance = nil

Icons.Folder = "Manifold-Icons"
Icons.ModulesFolder = "Manifold-CE-Utility-Modules"
Icons.IconSize = 16

--- Logical name to file.
Icons.Files = {
    LuaEngine     = "Manifold-Development.png",
    MemoryView    = "Manifold-Memory.png",
    Dissect       = "Manifold-Detail.png",
    Generate      = "Manifold-Generation.png",
    Remove        = "Manifold-Clear.png",
    TableFiles    = "Manifold-File.png",
    LogConsole    = "Manifold-Logging.png",
    Deactivate    = "Manifold-Pause.png",
    DeactivateAll = "Manifold-Reset.png",
    Normalize     = "Manifold-Validate.png",
    Compact       = "Manifold-Eye.png",
    Folder        = "Manifold-Folder.png",
    Settings      = "Manifold-Settings.png",
    About         = "Manifold-About.png"
}

--
--- ∑ The singleton. One image list per Cheat Engine session. A re-execution
---   that built a second one would leak the first, and every menu item still
---   pointing at it would resolve indices against a list nobody updates.
--- @param options table|nil # { Root }, autorun path override for tests.
--- @return table
--
function Icons:New(options)
    if not instance then
        instance = setmetatable({
            Root = nil,
            List = nil,
            Index = {},
            Graphics = {},
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
--- ∑ True when the file exists and really begins with the PNG signature.
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
    -- Match the artwork exactly so add never reaches StretchDraw. Width and
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
            local before = tonumber(list.Count) or 0
            local added, position = pcall(function() return list.add(png) end)
            local after = tonumber(list.Count) or before
            if added and after > before and type(position) == "number" then
                index[name] = position
            else
                missing[#missing + 1] = fileName .. " (add rejected it)"
            end
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

function Icons:Available()
    return self.Loaded or self:Load()
end

--
--- ∑ Attaches the list to a parent menu item so its CHILDREN resolve their
---   ImageIndex against it. An item's own SubMenuImages never applies to
---   itself, only to what hangs under it.
--- @param parentItem userdata
--- @return boolean
--
function Icons:AttachTo(parentItem)
    local list = self:GetList()
    if not parentItem or not list then return false end
    return (pcall(function() parentItem.SubMenuImages = list end)) == true
end

--
--- ∑ Sets an icon on one item. Only after AttachTo ran on its parent.
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
    -- "show menu icons" setting. Ask for them explicitly. A failure is
    -- ignored, the enum is only reachable through CE's RTTI fallback.
    pcall(function() item.GlyphShowMode = "gsmAlways" end)
    return ok == true
end

--
--- ∑ Releases everything. The singleton stays, so a later Load rebuilds from
---   scratch rather than handing out destroyed userdata.
--- @return nil
--
function Icons:Destroy()
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
--- ∑ Diagnostic. Run it once and read the result before trusting the rest
---   of this file on a Cheat Engine build it has not seen.
--- @return table
--
function Icons:Probe()
    local report = {
        createPNG = type(rawget(_G, "createPNG")),
        createImageList = type(rawget(_G, "createImageList")),
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
    return report
end

return Icons
