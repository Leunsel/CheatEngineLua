--[[
    The one icon this tool needs.

    A context menu entry does not carry its own picture. A TMenuItem resolves
    its ImageIndex against the nearest ancestor that has an image list, and for
    an item sitting in the disassembler's popup that ancestor is the popup
    itself. Cheat Engine builds that popup with Images set to mvImageList, its
    own memory view list, which can be read straight off the component:

        TPopupMenu debuggerpopup Images mvImageList OnPopup debuggerpopupPopup

    So the picture has to go into a list that belongs to Cheat Engine. This
    module adds exactly one image to it, once per session, and remembers the
    index it was given.

    The index is kept in a global slot rather than in this module. Re-executing
    the entry point drops every module from package.loaded, so a value held
    here would be lost and the same picture would be added again on every
    reload until the list filled up with copies. The list object is remembered
    alongside the index, and the pair is only reused when the same list comes
    back, so a rebuilt memory view gets a fresh entry instead of an index that
    no longer means anything.

    Four things about Cheat Engine's image handling that this depends on, all
    of them learned the hard way in the sibling segments:

    Loading a picture goes through createPNG. Asking createBitmap to load a PNG
    does not work, because TBitmap reads BMP only and nothing sniffs the format
    first. createPNG with no arguments allocates at screen size, so it is asked
    for one pixel and loadFromFile replaces the contents and the dimensions
    anyway.

    The PNG signature is checked before the file is handed over. CE's binding
    around graphic.loadFromFile has no exception handling of its own.

    imagelist.add never answers minus one. Handed something it cannot use it
    returns the count from before the insert, which is a valid looking index
    for an image that is not there. Success is judged by watching the count
    rise instead.

    TMenuItem.SetImageIndex returns early when the new value equals the old one
    and again when no list resolves, so minus one is written first to force a
    real change. Menu glyphs can also be switched off by the application or by
    Windows, so they are asked for explicitly.

    None of this is required for the menu to work. Every step reports failure
    and the entry simply appears without a picture.
]]

local sep = package.config:sub(1, 1)

local Icons = {}
Icons.__index = Icons

Icons.Folder = "Manifold-Icons"
Icons.ModulesFolder = "Manifold-SigMaker-Modules"
Icons.FileName = "Manifold-Copy.png"
Icons.IconSize = 16

--- The slot that survives a reload. It holds the list the image went into and
--- the index it was given.
Icons.GlobalKey = "__MANIFOLD_SIGMAKER_ICON__"

function Icons:New(options)
    options = options or {}
    return setmetatable({ Root = options.Root, Reason = nil }, Icons)
end

--
--- ∑ The full path of the icon file.
--- @return string
--
function Icons:Path()
    local root = self.Root
    if not root then
        local getPath = rawget(_G, "getAutorunPath")
        root = type(getPath) == "function" and getPath() or ""
        root = root .. Icons.ModulesFolder .. sep
    end
    return root .. Icons.Folder .. sep .. Icons.FileName
end

--
--- ∑ True when the file is there and really begins with the PNG signature.
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
--- ∑ Loads the file into a picture object Cheat Engine can put in a list.
--- @return userdata|nil, string|nil
--
function Icons:Load()
    local path = self:Path()
    local okMagic, magicReason = looksLikePng(path)
    if not okMagic then return nil, path .. " is " .. tostring(magicReason) end
    local createPNG = rawget(_G, "createPNG")
    if type(createPNG) ~= "function" then return nil, "createPNG is not available" end
    local made, png = pcall(createPNG, 1, 1)
    if not made or png == nil then return nil, "createPNG failed" end
    local loaded = pcall(function() png.loadFromFile(path) end)
    if not loaded then
        pcall(function() png.destroy() end)
        return nil, "the file could not be read as a picture"
    end
    return png
end

--
--- ∑ The index of our picture inside the given list, adding it the first time
---   it is asked for. A failure is remembered so a broken installation does
---   not retry on every menu build.
--- @param list userdata # An image list belonging to Cheat Engine.
--- @return number|nil, string|nil
--
function Icons:IndexIn(list)
    if list == nil then return nil, "the menu has no image list" end
    local cached = rawget(_G, Icons.GlobalKey)
    if type(cached) == "table" and cached.List == list and type(cached.Index) == "number" then
        return cached.Index
    end
    if self.Reason then return nil, self.Reason end

    local png, loadReason = self:Load()
    if not png then
        self.Reason = loadReason
        return nil, loadReason
    end

    local okBefore, before = pcall(function() return list.Count end)
    before = (okBefore and tonumber(before)) or 0
    local added, index = pcall(function() return list.add(png) end)
    local okAfter, after = pcall(function() return list.Count end)
    after = okAfter and tonumber(after) or before
    pcall(function() png.destroy() end)

    if not added or after <= before or type(index) ~= "number" then
        self.Reason = "the image list would not take the picture"
        return nil, self.Reason
    end
    _G[Icons.GlobalKey] = { List = list, Index = index }
    return index
end

--
--- ∑ Puts the picture on a menu item.
--- @param item userdata
--- @param list userdata # The list the item resolves its index against.
--- @return boolean, string|nil
--
function Icons:Apply(item, list)
    local index, reason = self:IndexIn(list)
    if not index or item == nil then return false, reason end
    pcall(function() item.ImageIndex = -1 end)
    local ok = pcall(function() item.ImageIndex = index end)
    pcall(function() item.GlyphShowMode = "gsmAlways" end)
    return ok == true
end

return Icons
