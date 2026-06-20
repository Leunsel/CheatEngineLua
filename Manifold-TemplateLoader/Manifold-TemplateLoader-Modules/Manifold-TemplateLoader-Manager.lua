--[[
    Template discovery and settings validation.

    Settings files intentionally run in a minimal environment. They are data files,
    not plug-ins, so they must not receive filesystem, process or Cheat Engine APIs.
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Log = require("Manifold-TemplateLoader-Log")
local File = require("Manifold-TemplateLoader-File")

local log = Log:New()
local file = File:New()

local Manager = {
    ScriptExtension = ".CEA",
    LuaExtension = ".Settings.lua",
    TemplateFolder = getAutorunPath() .. "Manifold-TemplateLoader-Templates"
}
Manager.__index = Manager

local instance = nil

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function copyTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

function Manager:New()
    if not instance then
        instance = setmetatable({}, Manager)
    end
    return instance
end

function Manager:GetScriptExtension() return self.ScriptExtension end
function Manager:GetLuaExtension() return self.LuaExtension end
function Manager:GetTemplateFolder() return self.TemplateFolder end

function Manager:NormalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    return path:gsub("\\", "/"):gsub("//+", "/"):gsub("/+$", "")
end

function Manager:GetSettingsEnvironment()
    return {
        ipairs = ipairs,
        pairs = pairs,
        tonumber = tonumber,
        tostring = tostring,
        math = math,
        string = string,
        table = table
    }
end

function Manager:ValidateSettings(templateName, settings, settingsPath)
    if type(settings) ~= "table" then
        return nil, "Settings must return a table"
    end

    local normalized = copyTable(settings)
    normalized.Caption = trim(settings.Caption) or templateName
    if normalized.Caption == "" then
        return nil, "Caption must not be empty"
    end

    if settings.Shortcut ~= nil and type(settings.Shortcut) ~= "string" then
        return nil, "Shortcut must be a string or nil"
    end
    normalized.Shortcut = trim(settings.Shortcut or "") or ""

    if settings.InSubMenu ~= nil and type(settings.InSubMenu) ~= "boolean" then
        return nil, "InSubMenu must be a boolean"
    end
    normalized.InSubMenu = settings.InSubMenu ~= false

    if settings.SubMenuName ~= nil and type(settings.SubMenuName) ~= "string" then
        return nil, "SubMenuName must be a string"
    end
    normalized.SubMenuName = trim(settings.SubMenuName or "Templates") or "Templates"

    for _, key in ipairs({ "AskForInjectionAddress", "AskForHookName", "AllocationNear" }) do
        if settings[key] ~= nil and type(settings[key]) ~= "boolean" then
            return nil, key .. " must be a boolean"
        end
    end
    for _, key in ipairs({ "AppendToHookName", "DefaultHookName" }) do
        if settings[key] ~= nil and type(settings[key]) ~= "string" then
            return nil, key .. " must be a string"
        end
    end
    if settings.AllocationSize ~= nil and type(settings.AllocationSize) ~= "string" and type(settings.AllocationSize) ~= "number" then
        return nil, "AllocationSize must be a string or number"
    end
    if settings.MenuOrder ~= nil and type(settings.MenuOrder) ~= "number" then
        return nil, "MenuOrder must be a number"
    end

    normalized.SourcePath = settingsPath
    return normalized
end

function Manager:LoadSettings(settingsPath, templateName)
    settingsPath = self:NormalizePath(settingsPath)
    if not settingsPath or not file:Exists(settingsPath) then
        return nil, "Settings file not found"
    end

    local source, readErr = file:ReadFile(settingsPath)
    if not source then return nil, readErr end

    local chunk, compileErr = load(source, "@" .. settingsPath, "t", self:GetSettingsEnvironment())
    if not chunk then
        return nil, "Settings syntax error: " .. tostring(compileErr)
    end

    local ok, settings = pcall(chunk)
    if not ok then
        return nil, "Settings execution failed: " .. tostring(settings)
    end
    return self:ValidateSettings(templateName, settings, settingsPath)
end

function Manager:DiscoverTemplates()
    local templates = {}
    local templateFolder = self:NormalizePath(self.TemplateFolder)
    if not templateFolder or not file:FolderExists(templateFolder) then
        log:Warning("[Manager] Template folder is unavailable: " .. tostring(templateFolder))
        return templates
    end

    local captions = {}
    local files = file:ScanFolder(templateFolder, false)
    for _, path in ipairs(files) do
        local baseName = path:match("([^/]+)$")
        if baseName and baseName:sub(-#self.ScriptExtension) == self.ScriptExtension then
            local name = baseName:sub(1, -#self.ScriptExtension - 1)
            if name ~= "Header" then
                local settingsPath = self:NormalizePath(templateFolder .. "/" .. name .. self.LuaExtension)
                local settings, err = self:LoadSettings(settingsPath, name)
                if not settings then
                    log:Warning(string.format("[Manager] Skipped '%s': %s", name, tostring(err)))
                elseif captions[settings.Caption] then
                    log:Error(string.format(
                        "[Manager] Skipped '%s': Caption '%s' is already used by '%s'.",
                        name, settings.Caption, captions[settings.Caption]))
                else
                    captions[settings.Caption] = name
                    templates[#templates + 1] = {
                        name = name,
                        fileName = name,
                        scriptPath = self:NormalizePath(path),
                        settingsPath = settingsPath,
                        settings = settings
                    }
                end
            end
        end
    end

    table.sort(templates, function(a, b)
        local aOrder = tonumber(a.settings.MenuOrder) or math.huge
        local bOrder = tonumber(b.settings.MenuOrder) or math.huge
        if aOrder ~= bOrder then return aOrder < bOrder end
        return a.settings.Caption:lower() < b.settings.Caption:lower()
    end)
    log:Info(string.format("[Manager] Discovered %d valid template(s).", #templates))
    return templates
end

function Manager:LoadScript(scriptPath)
    scriptPath = self:NormalizePath(scriptPath)
    if not scriptPath then return nil, "Invalid script path" end
    return file:ReadFile(scriptPath)
end

function Manager:InitTemplate(templateName)
    if type(templateName) ~= "string" or templateName == "" then return nil, "Invalid template name" end
    local folder = self:NormalizePath(self.TemplateFolder)
    local settingsPath = self:NormalizePath(folder .. "/" .. templateName .. self.LuaExtension)
    local scriptPath = self:NormalizePath(folder .. "/" .. templateName .. self.ScriptExtension)
    local settings, settingsErr = self:LoadSettings(settingsPath, templateName)
    if not settings then return nil, settingsErr end
    local script, scriptErr = self:LoadScript(scriptPath)
    if not script then return nil, scriptErr end
    return script, settings
end

return Manager
