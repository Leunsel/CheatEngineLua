--[[
    Dynamic Auto Assembler menu construction.

    All items created by this module carry a Tag marker, allowing a reload to
    remove only its own UI and leave Cheat Engine and user-provided menu entries
    untouched.
]]

local Log = require("Manifold-TemplateLoader-Log")
local log = Log:New()

local UI = { ManagedMenuTag = 1297374284 }
UI.__index = UI

local instance = nil

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function itemContainer(menu)
    if menu and menu.ClassName == "TMainMenu" then return menu.Items end
    return menu
end

local function childCount(menu)
    local container = itemContainer(menu)
    return container and tonumber(container.Count) or 0
end

local function getChild(menu, index)
    local container = itemContainer(menu)
    return container and container.getItem and container:getItem(index) or nil
end

local function addToParent(parent, item)
    if parent.ClassName == "TMainMenu" then
        parent.Items:add(item)
    else
        parent:add(item)
    end
end

local function createMenu(parent, options)
    local item = createMenuItem(parent)
    for key, value in pairs(options or {}) do item[key] = value end
    item.Tag = UI.ManagedMenuTag
    addToParent(parent, item)
    return item
end

local function categoryParts(value)
    local parts = {}
    -- '>' is the explicit hierarchy separator. '/' stays available for labels
    -- such as the bundled "x86/x64" categories.
    for part in tostring(value or "Templates"):gmatch("[^>]+") do
        part = trim(part)
        if part ~= "" then parts[#parts + 1] = part end
    end
    return #parts > 0 and parts or { "Templates" }
end

local function categoryCaption(value)
    local order, caption = value:match("^%s*%[([%-]?%d+)%]%s*(.-)%s*$")
    return caption and caption ~= "" and caption or value, tonumber(order) or math.huge
end

function UI:New()
    if not instance then instance = setmetatable({}, UI) end
    return instance
end

function UI:RemoveManagedItems(parent)
    if not parent then return end
    local container = itemContainer(parent)
    for index = childCount(parent) - 1, 0, -1 do
        local item = getChild(parent, index)
        if item and item.Tag == self.ManagedMenuTag then
            container:delete(index)
        end
    end
end

function UI:BuildTree(parent, tree)
    for _, entry in ipairs(tree or {}) do
        if entry.separator then
            createMenu(parent, { Caption = "-", Name = entry.name or "ManifoldSeparator" })
        else
            local item = createMenu(parent, {
                Caption = entry.caption,
                Name = entry.name,
                ImageIndex = entry.image,
                AutoCheck = entry.autoCheck == true,
                RadioItem = entry.radio == true,
                Checked = entry.checked == true,
                OnClick = entry.onClick
            })
            if entry.sub then self:BuildTree(item, entry.sub) end
        end
    end
end

function UI:FindMenuItem(form, name)
    local function visit(menu)
        if not menu then return nil end
        if menu.Name == name then return menu end
        for index = 0, childCount(menu) - 1 do
            local found = visit(getChild(menu, index))
            if found then return found end
        end
        return nil
    end

    if form and form.MainMenu1 and form.MainMenu1.Items then
        local found = visit(form.MainMenu1.Items)
        if found then return found end
    end
    for index = 0, (form and form.ComponentCount or 0) - 1 do
        local component = form.Component[index]
        if component and component.ClassName == "TMenuItem" and component.Name == name then return component end
    end
    return nil
end

function UI:AddSeparatorAfter(parentMenu, itemName)
    if not parentMenu then return false end
    for index = 0, childCount(parentMenu) - 1 do
        local item = getChild(parentMenu, index)
        if item and item.Name == itemName then
            local nextItem = getChild(parentMenu, index + 1)
            if nextItem and nextItem.Caption == "-" then return false end
            local separator = createMenuItem(parentMenu)
            separator.Caption = "-"
            parentMenu:insert(index + 1, separator)
            return true
        end
    end
    return false
end

local function loggerMenu(config, indices, callbacks)
    local levels, levelItems = { "DEBUG", "INFO", "WARNING", "ERROR" }, {}
    for _, level in ipairs(levels) do
        levelItems[#levelItems + 1] = {
            caption = level,
            name = "ManifoldLogLevel_" .. level,
            radio = true,
            checked = config.Logger.Level == level,
            onClick = function(sender) callbacks.onLevelChange(level, sender) end
        }
    end
    return {
        { caption = "Log level", name = "ManifoldLogLevel", image = indices.Level, sub = levelItems },
        { caption = "Write log file", name = "ManifoldLogToFile", image = indices.Log, autoCheck = true,
          checked = config.Logger.LogToFile == true, onClick = callbacks.onLogToFile },
        { caption = "View log file", name = "ManifoldViewLog", image = indices.Eye, onClick = callbacks.onViewLog }
    }
end

local function injectionMenu(config, callbacks)
    return {
        { caption = "Set info line count...", name = "ManifoldSetInfoLines", onClick = callbacks.onSetLineCount },
        { caption = "Remove spaces", name = "ManifoldRemoveSpaces", autoCheck = true,
          checked = config.InjectionInfo.RemoveSpaces == true,
          onClick = callbacks.onToggle("InjectionInfo", "RemoveSpaces", function(value) callbacks.memory:SetInjInfoRemoveSpaces(value) end) },
        { caption = "Indent information", name = "ManifoldAddTabs", autoCheck = true,
          checked = config.InjectionInfo.AddTabs == true,
          onClick = callbacks.onToggle("InjectionInfo", "AddTabs", function(value) callbacks.memory:SetInjInfoAddTabs(value) end) },
        { caption = "Hook-name suffix...", name = "ManifoldSetSuffix", onClick = callbacks.onSetAppend }
    }
end

local function memoryMenu(config, callbacks)
    return {
        { caption = "Ask for hook name", name = "ManifoldAskHookName", autoCheck = true,
          checked = config.Memory.AskForHookName == true,
          onClick = callbacks.onToggle("Memory", "AskForHookName", function(value) callbacks.memory:SetAskForHookName(value) end) },
        { caption = "Ask for injection address", name = "ManifoldAskAddress", autoCheck = true,
          checked = config.Memory.AskForInjectionAddress == true,
          onClick = callbacks.onToggle("Memory", "AskForInjectionAddress", function(value) callbacks.memory:SetAskForInjectionAddress(value) end) },
        { caption = "Allocate near injection", name = "ManifoldAllocationNear", autoCheck = true,
          checked = config.Memory.AllocationNear == true,
          onClick = callbacks.onToggle("Memory", "AllocationNear", function(value) callbacks.memory:SetAllocationNear(value) end) },
        { caption = "Set allocation size...", name = "ManifoldAllocationSize", onClick = callbacks.onSetAllocationSize },
        { caption = "Default hook name...", name = "ManifoldDefaultHookName", onClick = callbacks.onSetDefaultHookName }
    }
end

function UI:GetMainMenuTree(config, indices, callbacks)
    return {
        {
            caption = "Template Loader", name = "ManifoldTemplateLoader", image = indices.Template,
            sub = {
                { caption = "Template settings", name = "ManifoldInjectionSettings", image = indices.Template,
                  sub = injectionMenu(config, callbacks) },
                { caption = "Memory defaults", name = "ManifoldMemorySettings", image = indices.Inject,
                  sub = memoryMenu(config, callbacks) },
                { caption = "Logging", name = "ManifoldLoggerSettings", image = indices.Log,
                  sub = loggerMenu(config, indices, callbacks) },
                { separator = true, name = "ManifoldActionsSeparator" },
                { caption = "Reload templates (new AA windows)", name = "ManifoldReloadTemplates", image = indices.Toggle,
                  onClick = callbacks.onReloadTemplates },
                { caption = "Hot reload modules and templates", name = "ManifoldReloadModules", image = indices.Toggle,
                  onClick = callbacks.onReloadDependencies },
                { caption = "Open template folder", name = "ManifoldOpenFolder", image = indices.Eye,
                  onClick = callbacks.onOpenFolder },
                { caption = "Reset configuration", name = "ManifoldResetConfig", image = indices.Toggle,
                  onClick = callbacks.onResetConfig }
            }
        }
    }
end

function UI:CategorizeMenuItems(loader, rootMenu, indices)
    if not rootMenu then return false, "Template root menu was not found" end

    -- Categories own their children; they are only removed immediately before a
    -- full template re-registration creates fresh root entries.
    local templates = loader:GetTemplateDefinitions()
    local lookup = {}
    for _, template in ipairs(templates) do
        lookup[template.settings.Caption] = template
    end

    local grouped, rootItems, matched = {}, {}, 0
    for index = childCount(rootMenu) - 1, 0, -1 do
        local item = getChild(rootMenu, index)
        local template = item and lookup[item.Caption]
        if template then
            matched = matched + 1
            rootMenu:delete(index)
            local settings = template.settings
            if settings.InSubMenu == false then
                rootItems[#rootItems + 1] = { item = item, template = template }
            else
                local category = settings.SubMenuName or "Templates"
                grouped[category] = grouped[category] or {}
                grouped[category][#grouped[category] + 1] = { item = item, template = template }
            end
        end
    end

    table.sort(rootItems, function(a, b) return a.template.settings.Caption:lower() < b.template.settings.Caption:lower() end)
    for _, entry in ipairs(rootItems) do
        entry.item.ImageIndex = indices.Template
        rootMenu:add(entry.item)
    end

    local categories = {}
    for category in pairs(grouped) do categories[#categories + 1] = category end
    table.sort(categories, function(a, b)
        local aCaption, aOrder = categoryCaption(a)
        local bCaption, bOrder = categoryCaption(b)
        return aOrder == bOrder and aCaption:lower() < bCaption:lower() or aOrder < bOrder
    end)

    local menuByPath, categorySequence = {}, 0
    for _, category in ipairs(categories) do
        local parent, path = rootMenu, ""
        for _, rawPart in ipairs(categoryParts(category)) do
            path = path == "" and rawPart or path .. "/" .. rawPart
            if not menuByPath[path] then
                local caption = categoryCaption(rawPart)
                categorySequence = categorySequence + 1
                menuByPath[path] = createMenu(parent, { Caption = caption, Name = "ManifoldCategory" .. tostring(categorySequence), ImageIndex = indices.Inject })
            end
            parent = menuByPath[path]
        end

        local entries = grouped[category]
        table.sort(entries, function(a, b)
            local aOrder = tonumber(a.template.settings.MenuOrder) or math.huge
            local bOrder = tonumber(b.template.settings.MenuOrder) or math.huge
            return aOrder == bOrder and a.item.Caption:lower() < b.item.Caption:lower() or aOrder < bOrder
        end)
        for _, entry in ipairs(entries) do
            entry.item.ImageIndex = indices.Template
            parent:add(entry.item)
        end
    end

    log:Info(string.format("[UI] Categorized %d root template item(s) into %d category group(s).", matched, #categories))
    return true
end

return UI
