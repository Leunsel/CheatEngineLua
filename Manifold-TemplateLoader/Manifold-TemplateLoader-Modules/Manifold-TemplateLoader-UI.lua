--[[
    Manifold-TemplateLoader-UI.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 1.0.0
    LICENSE : MIT
    CREATED : 2025-11-15
    UPDATED : 2025-11-16
    
    MIT License:
        Copyright (c) 2025 Leunsel

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    This file is part of the Manifold TemplateLoader system.
]]

local UI = {
    instance = nil
}
UI.__index = UI

local Log     = require("Manifold-TemplateLoader-Log")
local log     = Log:New()

function UI:New()
    if not self.instance then
        self.instance = setmetatable({}, UI)
    end
    return self.instance
end

local function createMenu(parent, opts)
    local item = createMenuItem(parent)
    for k, v in pairs(opts or {}) do
        item[k] = v
    end
    -- Add to correct parent location
    if parent == parent.Owner.MainMenu1 then
        parent.Items:add(item)
    else
        parent:add(item)
    end
    return item
end

local function getLogLevelMenu(currentLevel, indices, onLevelChange)
    local levels = { "DEBUG", "INFO", "WARNING", "ERROR" }
    local items = {}
    for _, level in ipairs(levels) do
        table.insert(items, {
            caption = level,
            name = "LogLevel_" .. level,
            radio = true,
            checked = (level == currentLevel),
            onClick = function(sender)
                onLevelChange(level, sender)
            end
        })
    end
    return items
end

local function getLoggerMenu(config, indices, onLevelChange, onLogToFile, onViewLog)
    return {
        {
            caption = "Log Level",
            name = "LogLevelMenu",
            image = indices.Level,
            sub = getLogLevelMenu(config.Logger.Level or "INFO", indices, onLevelChange)
        },
        {
            caption = "Log to File",
            name = "LogToFile",
            image = indices.Log,
            autoCheck = true,
            checked = config.Logger.LogToFile == true,
            onClick = onLogToFile
        },
        {
            caption = "View Log File",
            name = "ViewLogFile",
            image = indices.Eye,
            onClick = onViewLog
        }
    }
end

local function getInjectionMenu(config, indices, memory, onSetLineCount, onSetAppend, onToggle, onOpenFolder)
    return {
        {
            caption = "Set Info Line Count...",
            name = "SetInjInfoLineCount",
            onClick = onSetLineCount
        },
        {
            caption = "Set Append To Hook Name...",
            name = "SetAppendToHookName",
            onClick = onSetAppend
        },
        {
            caption = "Remove Spaces",
            name = "SetInjInfoRemoveSpaces",
            autoCheck = true,
            checked = config.InjectionInfo.RemoveSpaces == true,
            onClick = onToggle("RemoveSpaces", function(v) memory:SetInjInfoRemoveSpaces(v) end)
        },
        {
            caption = "Add Tabs",
            name = "SetInjInfoAddTabs",
            autoCheck = true,
            checked = config.InjectionInfo.AddTabs == true,
            onClick = onToggle("AddTabs", function(v) memory:SetInjInfoAddTabs(v) end)
        },
        {
            caption = "Open Template Folder",
            name = "ViewTemplateFolder",
            image = indices.Eye,
            onClick = onOpenFolder
        }
    }
end

function UI:BuildTree(parent, tree)
    for _, entry in ipairs(tree) do
        local item = createMenu(parent, {
            Caption   = entry.caption,
            Name      = entry.name,
            ImageIndex = entry.image,
            AutoCheck = entry.autoCheck,
            RadioItem = entry.radio,
            Checked   = entry.checked,
            OnClick   = entry.onClick
        })
        if entry.sub then
            self:BuildTree(item, entry.sub)
        end
    end
end

function UI:GetMainMenuTree(config, indices, callbacks)
    return {
        {
            caption = "Template Options",
            name = "TemplateOptions",
            sub = {
                {
                    caption = "Logger Settings",
                    name = "LoggerSettings",
                    image = indices.Log,
                    sub = getLoggerMenu(
                        config,
                        indices,
                        callbacks.onLevelChange,
                        callbacks.onLogToFile,
                        callbacks.onViewLog
                    )
                },
                {
                    caption = "Injection Settings",
                    name = "InjectionSettings",
                    image = indices.Template,
                    sub = getInjectionMenu(
                        config,
                        indices,
                        callbacks.memory,
                        callbacks.onSetLineCount,
                        callbacks.onSetAppend,
                        callbacks.onToggle,
                        callbacks.onOpenFolder
                    )
                },
                {
                    caption = "Reload Dependencies",
                    name = "ReloadDependencies",
                    image = indices.Toggle,
                    onClick = callbacks.onReloadDependencies
                },
                {
                    caption = "Reload Templates",
                    name = "ReloadTemplates",
                    image = indices.Toggle,
                    onClick = callbacks.onReloadTemplates
                },
                {
                    caption = "Reset Configuration",
                    name = "ResetConfig",
                    image = indices.Toggle,
                    onClick = callbacks.onResetConfig
                }
            }
        }
    }
end

function UI:FindMenuItem(form, name)
    for i = 0, form.ComponentCount - 1 do
        local comp = form.Component[i]
        if comp.ClassName == "TMenuItem" and comp.Name == name then
            return comp
        end
    end
    return nil
end

function UI:AddSeparatorAfter(parentMenu, itemName)
    if not parentMenu or parentMenu.Count == 0 then
        return false
    end
    for i = 0, parentMenu.Count - 1 do
        local item = parentMenu:getItem(i)
        if item.Name == itemName then
            local nextIndex = i + 1
            if nextIndex < parentMenu.Count then
                local nextItem = parentMenu:getItem(nextIndex)
                if nextItem.Caption == "-" then
                    return false
                end
            end
            local sep = createMenuItem(parentMenu)
            sep:setCaption("-")
            parentMenu:insert(nextIndex, sep)
            return true
        end
    end
    return false
end

function UI:CategorizeMenuItems(loader, menu, indices)
    log:ForceInfo("[UI] Starting menu categorization...")
    local template1 = menu
    if not template1 then
        log:Error("[UI] Cannot categorize: menu reference is nil!")
        return
    end
    if not loader or not loader.RegisteredTemplates then
        log:Error("[UI] Cannot categorize: loader or templates missing!")
        return
    end
    log:Info(string.format("[UI] Loaded %d registered templates to categorize.",
        #loader.RegisteredTemplates))
    local lookup = {}
    for _, t in ipairs(loader.RegisteredTemplates) do
        local caption = (t.settings and t.settings.Caption) or t.fileName
        local sub = (t.settings and t.settings.SubMenuName) or "Templates"
        lookup[caption] = { template = t, sub = sub }
        log:Debug(string.format("[UI] Registered template '%s' → category '%s'", caption, sub))
    end
    local itemsPerCategory = {}
    for i = template1.Count - 1, 0, -1 do
        local item = template1:getItem(i)
        if item and item.ClassName == "TMenuItem" then
            local info = lookup[item.Caption]
            if info then
                itemsPerCategory[info.sub] = itemsPerCategory[info.sub] or {}
                table.insert(itemsPerCategory[info.sub], item)
                template1:delete(i)
                log:Info(string.format("[UI] Removed '%s' from root menu (will categorize under '%s').",
                    item.Caption, info.sub))
            end
        end
    end
    local names = {}
    for n in pairs(itemsPerCategory) do table.insert(names, n) end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    log:Info(string.format("[UI] Found %d category group(s).", #names))
    local categories = {}
    for _, sub in ipairs(names) do
        local items = itemsPerCategory[sub]
        log:ForceInfo(string.format("[UI] Creating submenu for category '%s' with %d item(s).",
            sub, #items))
        table.sort(items, function(a, b) return a.Caption:lower() < b.Caption:lower() end)
        local subMenu = categories[sub]
        if not subMenu then
            subMenu = createMenuItem(template1)
            subMenu:setCaption(sub)
            subMenu.ImageIndex = indices.Inject
            template1:add(subMenu)
            categories[sub] = subMenu
            log:Info(string.format("[UI] Submenu '%s' created.", sub))
        end
        for _, item in ipairs(items) do
            item.ImageIndex = indices.Template
            subMenu:add(item)
            log:Info(string.format("[UI] Placed template '%s' → '%s'", item.Caption, sub))
        end
        log:Info(string.format("[UI] Finished category '%s'.", sub))
    end
    log:ForceInfo("[UI] Menu categorization completed.")
end

return UI