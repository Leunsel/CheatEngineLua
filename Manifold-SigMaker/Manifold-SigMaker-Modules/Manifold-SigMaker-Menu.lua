--[[
    The entries in the memory view.

    Both halves of the tool are reached from the disassembler's context menu,
    and the finding half also from a keyboard shortcut. Those are two places,
    because they have to be.

    THE CONTEXT MENU. The entries hang on the memory view form and not on the
    disassembler control. The form owns a published TPopupMenu named
    "debuggerpopup" that already has an OnPopup handler of its own, and that
    component is the way in. The disassembler control itself is reached as
    getMemoryViewForm().DisassemblerView, and its PopupMenu property is nil.
    getVisibleDisassembler() is no help either. It is deprecated and returns a
    stub whose PopupMenu is nil as well.

    THE SHORTCUT. A key is dispatched by the focused form through its main
    menu. An item sitting in a popup menu is never asked about it, whatever
    its Shortcut property says, so a shortcut needs an item in a menu bar to
    live in. The memory view has its own, reached as the form's Menu, and a
    small root entry is added there to carry the shortcut. The context menu
    entry then shows the same key beside its caption, but only once the menu
    bar entry that actually answers it is really there. A key printed next to
    an entry that cannot be triggered by it would be a lie.

    The pictures work the way they do everywhere else in Cheat Engine. An item
    does not own a picture. It resolves its ImageIndex against the image list
    of the menu it sits in, and that list belongs to Cheat Engine, so the
    picture has to be put there. Manifold-SigMaker-Icons does that once per
    session and remembers the index. A failure anywhere along the way costs an
    entry its picture and nothing else.

    Every item created here carries Tag = MenuTag. Removal sweeps both menus
    for that tag rather than trusting the references it kept. A generation
    that lost its items cannot leave an entry behind, and neither can a script
    that ran again without ever removing its own. That is the same pattern the
    Logger and the CE Utility use. Each of them owns a different tag number,
    so the three never sweep each other's items.
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
        Items = {},        -- every item built, in both menus
        Popup = nil,
        MenuBar = nil,     -- the container the root entry sits in
        Root = nil
    }, Menu)
end

function Menu:Installed()
    return self.Popup ~= nil
end

--- Whether the key is really answered by something.
function Menu:ShortcutInstalled()
    return self.Root ~= nil
end

--------------------------------------------------------
--                       Building                     --
--------------------------------------------------------

--
--- ∑ One item, wherever it is going to hang. The click handler is wrapped so
---   a failing action is logged under its caption instead of surfacing as a
---   Cheat Engine error box.
--- @param owner userdata # The menu the item belongs to.
--- @param entry table # { Caption, OnClick, Icon, Shortcut }
--- @param shortcut string|nil # Set only where it will be dispatched.
--- @return userdata|nil
--
function Menu:Build(owner, entry, shortcut)
    local createItem = rawget(_G, "createMenuItem")
    if type(createItem) ~= "function" then return nil end
    local caption = tostring(entry.Caption or "")
    local item
    local made = pcall(function()
        item = createItem(owner)
        item.Caption = caption
        item.Tag = self.Tag
        if type(entry.OnClick) == "function" then
            item.OnClick = function()
                local ok, err = pcall(entry.OnClick)
                if not ok then
                    self.Log:Error(string.format("'%s' failed: %s", caption, tostring(err)))
                end
            end
        end
    end)
    if not made or not item then
        self.Log:Warning("Could not create the menu entry '" .. caption .. "'.")
        return nil
    end
    -- On its own, because a key Cheat Engine cannot parse is worth losing the
    -- key over and not the entry it was going on.
    if type(shortcut) == "string" and shortcut ~= "" then
        if not pcall(function() item.Shortcut = shortcut end) then
            self.Log:Warning(string.format(
                "'%s' is not a shortcut Cheat Engine understands, so '%s' has no key. " ..
                "They are written like 'Ctrl+Shift+F'.", shortcut, caption))
        end
    end
    self.Items[#self.Items + 1] = item
    return item
end

--
--- ∑ Adds the entries to the disassembler context menu, and the shortcut
---   carrier to the memory view's menu bar.
--- @param spec table # A list of { Caption, OnClick, Icon, Shortcut }.
--- @return boolean, string|nil
--
function Menu:Install(spec)
    if self.Popup then return true end
    if type(rawget(_G, "createMenuItem")) ~= "function" then
        return false, "createMenuItem is not available"
    end
    local popup, reason = self.CE:DisassemblerPopup()
    if not popup then return false, reason end

    -- The menu bar first. Whether it worked decides if the context menu
    -- entries are allowed to advertise a key.
    local keyed = self:InstallMenuBar(spec)

    local list = self.CE:Get(popup, "Images")
    local added = 0
    for _, entry in ipairs(spec) do
        local item = self:Build(popup, entry, keyed and entry.Shortcut or nil)
        if item and pcall(function() popup.Items.add(item) end) then
            added = added + 1
            self:Decorate(item, list, entry)
        end
    end
    if added == 0 then
        self:Remove()
        return false, "could not create the menu items"
    end
    self.Popup = popup
    return true
end

--
--- ∑ The root entry in the memory view's own menu bar, which is the only
---   place a shortcut is dispatched from. Its absence costs the key and
---   nothing else, so it is reported as a debug line and not as a failure.
--- @param spec table
--- @return boolean
--
function Menu:InstallMenuBar(spec)
    if self.Settings.Find.MenuBar == false then return false end
    local menu, reason = self.CE:MemoryViewMenu()
    if not menu then
        self.Log:Debug("No keyboard shortcut: " .. tostring(reason) .. ".")
        return false
    end
    local container = self.CE:Get(menu, "Items")
    if not container then
        self.Log:Debug("No keyboard shortcut: the memory view menu has no item list.")
        return false
    end

    local createItem = rawget(_G, "createMenuItem")
    local root
    local built = pcall(function()
        root = createItem(menu)
        root.Caption = tostring(self.Settings.Find.MenuBarCaption or "Manifold")
        root.Tag = self.Tag
        container.add(root)
    end)
    if not built or not root then
        self.Log:Debug("No keyboard shortcut: the menu bar entry could not be created.")
        return false
    end
    self.Items[#self.Items + 1] = root

    local list = self.CE:Get(menu, "Images")
    local added = 0
    for _, entry in ipairs(spec) do
        local item = self:Build(menu, entry, entry.Shortcut)
        if item and pcall(function() root.add(item) end) then
            added = added + 1
            self:Decorate(item, list, entry)
        end
    end
    if added == 0 then
        pcall(function() container.delete(container.Count - 1) end)
        pcall(function() root.destroy() end)
        return false
    end
    self.Root, self.MenuBar = root, container
    return true
end

--
--- ∑ The picture, which is a nicety and never a reason to fail.
---
---   A menu with no image list at all is not worth a line. Cheat Engine gives
---   the disassembler popup one and its menu bar none, so reporting that as a
---   failure would print the same two debug lines on every single start.
--- @param item userdata
--- @param list userdata|nil # The image list the item resolves against.
--- @param entry table
--
function Menu:Decorate(item, list, entry)
    if not self.Icons or not entry.Icon or list == nil then return end
    local shown, reason = self.Icons:Apply(item, list, entry.Icon)
    if not shown and reason then
        self.Log:Debug(string.format("The menu entry '%s' has no picture: %s.",
            tostring(entry.Caption), tostring(reason)))
    end
end

--------------------------------------------------------
--                       Removal                      --
--------------------------------------------------------

--
--- ∑ Detaches every item carrying the tag from one container.
--- @param container userdata|nil
--- @param found table # Collects what came off.
--
local function sweep(self, container, found)
    if not container then return end
    pcall(function()
        for index = (tonumber(container.Count) or 0) - 1, 0, -1 do
            local child = container.getItem(index)
            if child and child.Tag == self.Tag then
                container.delete(index)
                found[#found + 1] = child
            end
        end
    end)
end

--
--- ∑ Takes every entry down. Both menus are swept for the tag, so an item
---   from an earlier generation goes with them, and anything this object
---   built but never managed to hang anywhere is destroyed as well.
--- @return boolean
--
function Menu:Remove()
    local popup = self.Popup or (self.CE:DisassemblerPopup())
    local bar = self.MenuBar
    if not bar then
        local menu = self.CE:MemoryViewMenu()
        bar = menu and self.CE:Get(menu, "Items") or nil
    end
    local built = self.Items
    self.Popup, self.MenuBar, self.Root, self.Items = nil, nil, nil, {}
    if not popup and not bar and #built == 0 then return false end

    local detached = {}
    if popup then sweep(self, self.CE:Get(popup, "Items"), detached) end
    sweep(self, bar, detached)

    local destroyed = {}
    for _, item in ipairs(detached) do
        destroyed[item] = true
        pcall(function() item.destroy() end)
    end
    -- A child of a root that has just been destroyed goes with it, and asking
    -- it to destroy itself twice is not worth the risk, so only what the
    -- sweep did not reach is destroyed here.
    for _, item in ipairs(built) do
        if not destroyed[item] and self.CE:Get(item, "Parent") == nil then
            pcall(function() item.destroy() end)
        end
    end
    return true
end

return Menu
