--[[
    The file type image list.

    One 16x16 glyph per file type, drawn in process. No PNGs ship with this
    tool, which is what keeps the autorun package a folder you can copy.

    The technique is the one the Manifold UI Theme Creator uses for its colour
    swatches (Manifold.UI.lua, UI:RebuildImageList): createImageList, set
    Width/Height, hand it to listView.SmallImages, then createBitmap(16,16),
    paint through bmp.Canvas and add() it. This is an adaptation of that
    concept, not a dependency on it; nothing here reaches into Manifold.UI.

    Two differences from the Theme Creator's version, both deliberate:

      * It rebuilds its list every time a colour changes, because its images
        ARE the data. Ours are a fixed set of type glyphs, so the list is
        built once per window and the viewer only assigns indices after that.
      * It trusts add()'s return value. That is not safe: CE's
        customimagelist_add returns the PRE-INSERT Count when it rejects the
        bitmap, so a failed add yields a plausible-looking index for an image
        that is not there. Success is confirmed by watching Count grow.
        (The same trap is documented in Manifold-TemplateLoader-Icons.)

    Sizing matters too. A bitmap that does not match the list's Width/Height
    is STRETCHED by TFPImageCanvas.StretchDraw, not clipped, so the list size
    is read back after setting it rather than assumed.

    The glyph is a small file chip: a muted page with a three pixel spine in
    the type's accent colour. Colour carries the meaning, the shape stays
    constant, and at 16px it reads as a marker rather than as an illustration.
    The background is painted in the list's own background colour because the
    bitmaps are added unmasked, so the glyph has to blend rather than float.
]]

local Images = {}
Images.__index = Images

Images.Size = 16

function Images:New(services)
    services = services or {}
    return setmetatable({
        Log = services.Log,
        Types = services.Types,
        List = nil,
        Index = {},
        Background = nil,
        Reason = nil
    }, Images)
end

function Images:Fail(message)
    self.Reason = message
    if type(self.Log) == "function" then self.Log("Icons: " .. tostring(message), true) end
end

--
--- ∑ Paints one file chip onto a fresh bitmap.
---   fillRect(x1,y1,x2,y2) excludes the right and bottom edge, so the page is
---   x 3..12 and y 2..13, ten by twelve pixels inside a sixteen pixel tile.
--- @param typeRecord table # The type whose accent colour to use.
--- @param background number # The colour the list sits on.
--- @return userdata|nil # A bitmap, or nil when Cheat Engine refused.
--
function Images:DrawChip(typeRecord, background)
    local size = Images.Size
    local ok, bitmap = pcall(createBitmap, size, size)
    if not ok or not bitmap then return nil end
    local painted = pcall(function()
        local canvas = bitmap.Canvas
        canvas.Brush.Color = background
        canvas.fillRect(0, 0, size, size)
        -- The page. Kept dim so the spine is what the eye catches.
        canvas.Brush.Color = self.PageColor or background
        canvas.fillRect(3, 2, 13, 14)
        -- The spine, in the type's colour.
        canvas.Brush.Color = typeRecord.Color
        canvas.fillRect(3, 2, 6, 14)
    end)
    if not painted then
        pcall(function() bitmap.destroy() end)
        return nil
    end
    return bitmap
end

--
--- ∑ Builds the list. Safe to call again: an existing list is returned
---   unchanged unless the background colour moved, which only happens when
---   the palette did.
--- @param palette table # Supplies the list background and page colour.
--- @return boolean # Whether a usable list exists afterwards.
--
function Images:Build(palette)
    local background = (palette and palette.COLOR_INPUT) or 0x000000
    if self.List and self.Background == background then return true end
    if self.List then self:Destroy() end

    local create = rawget(_G, "createImageList")
    if type(create) ~= "function" then
        self:Fail("createImageList is not available; the list runs without icons")
        return false
    end
    local ok, list = pcall(create)
    if not ok or list == nil then
        self:Fail("createImageList failed: " .. tostring(list))
        return false
    end
    -- Width and Height resolve through CE's published-property RTTI rather
    -- than an explicit binding, so read them back instead of trusting the
    -- write. A mismatch would silently stretch every glyph.
    pcall(function() list.Width = Images.Size end)
    pcall(function() list.Height = Images.Size end)
    local okW, width = pcall(function() return list.Width end)
    local okH, height = pcall(function() return list.Height end)
    if okW and okH and (width ~= Images.Size or height ~= Images.Size) then
        pcall(function() list.destroy() end)
        self:Fail(string.format("image list came up %sx%s, expected %dx%d",
            tostring(width), tostring(height), Images.Size, Images.Size))
        return false
    end
    -- Masked and DrawingStyle defaults are already right for 32-bit bitmaps.
    -- Setting them is what breaks alpha, so they are left alone.

    self.Background = background
    self.PageColor = (palette and palette.COLOR_PANEL) or background
    local index, added = {}, 0
    for _, typeRecord in ipairs(self.Types.All()) do
        local bitmap = self:DrawChip(typeRecord, background)
        if bitmap then
            local before = tonumber(list.Count) or 0
            local okAdd, position = pcall(function() return list.add(bitmap) end)
            local after = tonumber(list.Count) or before
            -- add() never returns -1. On refusal it hands back the pre-insert
            -- Count, so Count is the only honest signal.
            if okAdd and after > before and type(position) == "number" then
                index[typeRecord.Key] = position
                added = added + 1
            end
            pcall(function() bitmap.destroy() end)
        end
    end
    if added == 0 then
        pcall(function() list.destroy() end)
        self:Fail("no glyphs could be added; the list runs without icons")
        return false
    end
    self.List = list
    self.Index = index
    self.Reason = nil
    return true
end

--
--- ∑ The image list, or nil when it could not be built.
--- @return userdata|nil
--
function Images:GetList()
    return self.List
end

--
--- ∑ The image index for a type key.
--- @param key string # A type record's Key.
--- @return number # The index, or -1 when there is no icon for it.
--
function Images:IndexOf(key)
    local position = self.Index[key]
    if position == nil then return -1 end
    return position
end

--
--- ∑ Releases the list. Called when the window closes so a reopen does not
---   leave the previous list attached to a freed control.
--- @return nil # No return value.
--
function Images:Destroy()
    if self.List then
        pcall(function() self.List.destroy() end)
    end
    self.List = nil
    self.Index = {}
    self.Background = nil
end

return Images
