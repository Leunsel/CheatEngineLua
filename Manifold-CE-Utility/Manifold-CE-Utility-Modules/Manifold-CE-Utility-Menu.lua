--[[
    The menu: one root entry in Cheat Engine's main menu bar built from a
    spec table the host provides, the caption ticker, and the check marks
    on the settings entries.

    Every item this module creates carries Tag = MenuTag. Removal sweeps the
    main menu for that tag rather than trusting the reference it kept, so a
    generation whose root was lost, or a re-execution that never got to
    remove its menu, cannot leave an entry behind.

    Spec entries:
        "-"                                      a separator
        { Caption, OnClick, Icon, Shortcut }     an action
        { Caption, Items = { ... } }             a submenu
        { Caption, OnClick, Checked = fn }       a checkable entry; fn returns
                                                 the state to show

    The ticker rotates the caption by code points, not bytes, so a caption
    with a character outside ASCII does not fall apart mid-glyph.
]]

local Menu = {}
Menu.__index = Menu

function Menu:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Icons = deps.Icons,
        Settings = deps.Settings,
        Tag = deps.MenuTag,
        Root = nil,
        Container = nil,
        Checkable = {},
        Timer = nil,
        Ticker = nil
    }, Menu)
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Menu:Installed()
    return self.Root ~= nil
end

--------------------------------------------------------
--                        Caption                     --
--------------------------------------------------------

function Menu:Caption(text)
    local settings = self.Settings
    return (settings.Prefix or "") .. tostring(text or "") .. (settings.Suffix or "")
end

function Menu:SetCaption(text)
    local root = self.Root
    if not root then return false end
    local caption = self:Caption(text)
    local ok = self.CE:RunInMain(function() root.Caption = caption end)
    return ok == true
end

--------------------------------------------------------
--                        Building                    --
--------------------------------------------------------

--
--- ∑ Builds the root entry and everything under it.
--- @param spec table
--- @return boolean, string|nil
--
function Menu:Install(spec)
    if self.Root then return true end
    local createItem = rawget(_G, "createMenuItem")
    if type(createItem) ~= "function" then return false, "createMenuItem is not available" end
    local mainMenu = self.CE:MainMenu()
    if not mainMenu then return false, "the main menu is not available" end
    local container = self.CE:Get(mainMenu, "Items")
    if not container then return false, "the main menu has no item list" end

    local root
    local built = pcall(function()
        root = createItem(mainMenu)
        root.Caption = self:Caption(self.Settings.MenuCaption)
        root.Tag = self.Tag
        container.add(root)
    end)
    if not built or not root then return false, "could not create the root menu item" end
    self.Root, self.Container, self.Checkable = root, container, {}

    if not self.Icons:AttachTo(root) and self.Icons.Reason then
        self.Log:Warning("Menu icons unavailable: " .. tostring(self.Icons.Reason))
    end
    self:AddItems(root, spec, mainMenu)
    self:RefreshChecks()
    self:StartTicker()
    return true
end

function Menu:AddItems(parent, items, mainMenu)
    for _, entry in ipairs(items or {}) do
        if entry == "-" then
            self:AddSeparator(parent, mainMenu)
        else
            self:AddItem(parent, entry, mainMenu)
        end
    end
end

function Menu:AddSeparator(parent, mainMenu)
    local createItem = rawget(_G, "createMenuItem")
    local item
    pcall(function()
        item = createItem(mainMenu)
        item.Caption = "-"
        item.Tag = self.Tag
        parent.add(item)
    end)
    return item
end

--
--- ∑ One entry. The click handler is wrapped so a failing action is logged
---   under its caption instead of surfacing as a Cheat Engine error box.
--- @param parent userdata
--- @param entry table
--- @param mainMenu userdata
--- @return userdata|nil
--
function Menu:AddItem(parent, entry, mainMenu)
    local createItem = rawget(_G, "createMenuItem")
    local caption = tostring(entry.Caption or "")
    local item
    local made = pcall(function()
        item = createItem(mainMenu)
        item.Caption = caption
        item.Tag = self.Tag
        if type(entry.Shortcut) == "string" and entry.Shortcut ~= "" then
            item.Shortcut = entry.Shortcut
        end
        if type(entry.OnClick) == "function" then
            item.OnClick = function()
                local ok, err = pcall(entry.OnClick)
                if not ok then
                    self.Log:Error(string.format("'%s' failed: %s", caption, tostring(err)))
                end
            end
        end
        parent.add(item)
    end)
    if not made or not item then
        self.Log:Warning("Could not create the menu entry '" .. caption .. "'.")
        return nil
    end
    if entry.Icon then self.Icons:Apply(item, entry.Icon) end
    if type(entry.Checked) == "function" then
        self.Checkable[#self.Checkable + 1] = { Item = item, Checked = entry.Checked }
    end
    if entry.Items then self:AddItems(item, entry.Items, mainMenu) end
    return item
end

--- Re-applies the check marks. Called after every settings change.
function Menu:RefreshChecks()
    for _, entry in ipairs(self.Checkable) do
        local state = false
        local ok, result = pcall(entry.Checked)
        if ok then state = result == true end
        pcall(function() entry.Item.Checked = state end)
    end
end

--------------------------------------------------------
--                        Removal                     --
--------------------------------------------------------

--
--- ∑ Takes the menu down. Every tagged item in the main menu, not just the
---   root still held, so nothing from an earlier generation survives.
--- @return boolean
--
function Menu:Remove()
    self:StopTicker()
    local root, container = self.Root, self.Container
    if not container then
        local mainMenu = self.CE:MainMenu()
        container = mainMenu and self.CE:Get(mainMenu, "Items") or nil
    end
    self.Root, self.Container, self.Checkable = nil, nil, {}
    if not root and not container then return false end
    local detached = {}
    if container then
        pcall(function()
            for index = (tonumber(container.Count) or 0) - 1, 0, -1 do
                local child = container.getItem(index)
                if child and child.Tag == self.Tag then
                    container.delete(index)
                    detached[#detached + 1] = child
                end
            end
        end)
    end
    local rootDestroyed = false
    for _, item in ipairs(detached) do
        if item == root then rootDestroyed = true end
        pcall(function() item.destroy() end)
    end
    if root and not rootDestroyed then pcall(function() root.destroy() end) end
    return true
end

--------------------------------------------------------
--                        Ticker                      --
--------------------------------------------------------

local function glyphs(text)
    local points = {}
    local ok = pcall(function()
        for _, code in utf8.codes(text) do points[#points + 1] = utf8.char(code) end
    end)
    if not ok then
        points = {}
        for index = 1, #text do points[index] = text:sub(index, index) end
    end
    return points
end

function Menu:StopTicker()
    local timer = self.Timer
    self.Timer, self.Ticker = nil, nil
    if timer then
        pcall(function() timer.Enabled = false end)
        pcall(function() timer.destroy() end)
    end
end

--
--- ∑ Resets the caption and, when animation is on, starts rotating it.
--- @return boolean # Whether a timer is running.
--
function Menu:StartTicker()
    self:StopTicker()
    if not self.Root then return false end
    local settings = self.Settings
    local label = trim(settings.MenuCaption)
    self:SetCaption(label)
    if not settings.AnimatedCaption then return false end
    local points = glyphs(" " .. label .. " ")
    if #points < 3 then return false end

    local timer = self.CE:Call("createTimer", nil, false)
    if not timer then
        self.Log:Warning("Caption animation: createTimer is not available.")
        return false
    end
    self.Timer, self.Ticker = timer, points
    local interval = settings:ClampInterval(settings.AnimationInterval)
    local armed = pcall(function()
        timer.Interval = interval
        timer.OnTimer = function()
            local ok, err = pcall(function()
                if not self.Root or self.Timer ~= timer then
                    self:StopTicker()
                    return
                end
                table.insert(points, table.remove(points, 1))
                self:SetCaption(table.concat(points))
            end)
            if not ok then
                self.Log:Warning("Caption animation stopped: " .. tostring(err))
                self:StopTicker()
            end
        end
        timer.Enabled = true
    end)
    if not armed then
        self.Log:Warning("Caption animation: the timer could not be armed.")
        self:StopTicker()
        return false
    end
    return true
end

return Menu
