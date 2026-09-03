--[[
    The entry in the disassembler's context menu.

    The entry carries the Manifold copy picture. An item does not own a
    picture of its own. It resolves its ImageIndex against the image list of
    the menu it sits in, and that list belongs to Cheat Engine, so the picture
    has to be put there. Manifold-SigMaker-Icons does that once per session and
    remembers the index. A failure anywhere along the way costs the entry its
    picture and nothing else.

    It hangs on the memory view form and not on the disassembler control.
    The form owns a published TPopupMenu named "debuggerpopup" that
    already has an OnPopup handler of its own, and that component is the way
    in. The disassembler control itself is reached as
    getMemoryViewForm().DisassemblerView, and its PopupMenu property is nil.
    getVisibleDisassembler() is no help either. It is deprecated and returns a
    stub whose PopupMenu is nil as well.

    Every item created here carries Tag = MenuTag. Removal sweeps the menu for
    that tag rather than trusting the reference it kept. A generation that lost
    its item reference cannot leave an entry behind, and neither can a script
    that ran again without ever removing its own. That is the same pattern the
    Logger and the CE Utility use. Each of them owns a different tag number, so
    the three never sweep each other's items.
]]

local Menu = {}
Menu.__index = Menu

function Menu:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Settings = deps.Settings,
        Icons = deps.Icons,
        Tag = deps.MenuTag,
        Item = nil,
        Popup = nil
    }, Menu)
end

function Menu:Installed()
    return self.Item ~= nil
end

--
--- ∑ Adds the entry to the disassembler context menu.
--- @param onClick function
--- @return boolean, string|nil
--
function Menu:Install(onClick)
    if self.Item then return true end
    local createItem = rawget(_G, "createMenuItem")
    if type(createItem) ~= "function" then return false, "createMenuItem is not available" end
    local popup, reason = self.CE:DisassemblerPopup()
    if not popup then return false, reason end

    local caption = self.Settings.MenuCaption
    local item
    local built = pcall(function()
        item = createItem(popup)
        item.Caption = caption
        item.Tag = self.Tag
        item.OnClick = function()
            local ok, err = pcall(onClick)
            if not ok then
                self.Log:Error(string.format("'%s' failed: %s", caption, tostring(err)))
            end
        end
        popup.Items.add(item)
    end)
    if not built or not item then return false, "could not create the menu item" end
    self.Item, self.Popup = item, popup

    -- The picture is a nicety and never a reason to fail. An item resolves its
    -- ImageIndex against the image list of the popup it sits in, which belongs
    -- to Cheat Engine, so the list is read off the component and handed over.
    if self.Icons then
        local list = self.CE:Get(popup, "Images")
        local shown, iconReason = self.Icons:Apply(item, list)
        if not shown and iconReason then
            self.Log:Debug("The menu entry has no picture: " .. tostring(iconReason) .. ".")
        end
    end
    return true
end

--
--- ∑ Takes the entry down. Every item in the popup carrying the tag goes,
---   not only the one this object still holds.
--- @return boolean
--
function Menu:Remove()
    local item, popup = self.Item, self.Popup
    if not popup then popup = (self.CE:DisassemblerPopup()) end
    self.Item, self.Popup = nil, nil
    if not item and not popup then return false end

    local detached = {}
    if popup then
        pcall(function()
            local items = popup.Items
            for index = (tonumber(items.Count) or 0) - 1, 0, -1 do
                local child = items.getItem(index)
                if child and child.Tag == self.Tag then
                    items.delete(index)
                    detached[#detached + 1] = child
                end
            end
        end)
    end
    local destroyed = false
    for _, child in ipairs(detached) do
        if child == item then destroyed = true end
        pcall(function() child.destroy() end)
    end
    if item and not destroyed then pcall(function() item.destroy() end) end
    return true
end

return Menu
