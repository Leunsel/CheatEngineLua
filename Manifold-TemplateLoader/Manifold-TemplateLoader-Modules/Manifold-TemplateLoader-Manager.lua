--[[
    Manifold.TemplateLoader.Manager.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    VERSION : 2.0.0
    LICENSE : MIT
    CREATED : 2025-06-21
    UPDATED : 2025-06-24
    
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

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Log = require("Manifold-TemplateLoader-Log")
local File = require("Manifold-TemplateLoader-File")
local Memory = require("Manifold-TemplateLoader-Memory")

local log = Log:New()
local file = File:New()
local memory = Memory:New()

local Manager = {
    ScriptExtension = ".CEA",
    LuaExtension = ".Settings.lua",
    TemplateFolder = getAutorunPath() .. "Manifold-TemplateLoader-Templates"
}
Manager.__index = Manager

local instance = nil

function Manager:New()
    if not instance then
        instance = setmetatable({}, Manager)
    end
    return instance
end

function Manager:GetScriptExtension()
    return self.ScriptExtension
end

function Manager:GetLuaExtension()
    return self.LuaExtension
end

function Manager:GetTemplateFolder()
    return self.TemplateFolder
end

function Manager:NormalizePath(path)
    -- Always use forward slashes and remove trailing slashes
    return (path or ""):gsub("\\", "/"):gsub("//+", "/"):gsub("/+$", "")
end

function Manager:DiscoverTemplates()
    log:Info("[Manager] Discovering templates in: " .. tostring(self.TemplateFolder))
    local templates = {}
    local templateFolder = self:NormalizePath(self.TemplateFolder)
    if not templateFolder or type(templateFolder) ~= "string" or templateFolder == "" then
        log:Error("[Manager] Template folder path is invalid or nil.")
        return templates
    end
    if not file:FolderExists(templateFolder) then
        log:Warning("[Manager] Template folder does not exist: " .. tostring(templateFolder))
        return templates
    end
    local files = file:ScanFolder(templateFolder, false)
    log:Debug(string.format("[Manager] Found %d files in template folder: %s", #files, templateFolder))
    for _, filepath in ipairs(files) do
        local normFilePath = self:NormalizePath(filepath)
        local base = normFilePath:match("([^/]+)$")
        if base:sub(-#self.ScriptExtension) == self.ScriptExtension then
            local templateName = base:sub(1, -#self.ScriptExtension - 1)
            local settingsPath = self:NormalizePath(templateFolder .. "/" .. templateName .. self.LuaExtension)
            local scriptPath = normFilePath
            local settings, scriptContent = self:LoadFileSafely(templateName, settingsPath, scriptPath)
            if settings and scriptContent then
                log:Info(string.format("[Manager] Found template: %s", templateName))
                templates[#templates + 1] = {
                    name = templateName,
                    scriptPath = scriptPath,
                    settingsPath = settingsPath,
                    settings = settings,
                    scriptContent = scriptContent,
                    fileName = templateName
                }
            else
                log:Warning(string.format("[Manager] Skipped template (missing settings or script): %s", templateName))
            end
        end
    end
    log:Info(string.format("[Manager] Total templates discovered: %d", #templates))
    return templates
end

function Manager:LoadSettings(settingsPath)
    settingsPath = self:NormalizePath(settingsPath)
    log:Debug("[Manager] Loading settings: " .. tostring(settingsPath))
    if not file:Exists(settingsPath) then
        log:Warning("[Manager] Settings file does not exist: " .. tostring(settingsPath))
        return nil
    end
    local status, settings = pcall(dofile, settingsPath)
    if status then
        log:Info("[Manager] Loaded settings successfully: " .. tostring(settingsPath))
        return settings
    else
        log:Error("[Manager] Failed to load settings: " .. tostring(settingsPath))
    end
    return nil
end

function Manager:LoadScript(scriptPath)
    scriptPath = self:NormalizePath(scriptPath)
    log:Debug("[Manager] Loading script: " .. tostring(scriptPath))
    if not file:Exists(scriptPath) then
        log:Warning("[Manager] Script file does not exist: " .. tostring(scriptPath))
        return nil
    end
    local fileHandle, err = io.open(scriptPath, "r")
    if not fileHandle then
        log:Error("[Manager] Failed to open script file: " .. tostring(scriptPath) .. " (" .. tostring(err) .. ")")
        return nil
    end
    local script = fileHandle:read("*a")
    fileHandle:close()
    log:Info("[Manager] Loaded script successfully: " .. tostring(scriptPath))
    return script
end

function Manager:LoadFileSafely(templateName, settingsPath, scriptPath)
    log:Debug(string.format("[Manager] LoadFileSafely called for template: %s", templateName))
    local settings = templateName ~= "Header" and self:LoadSettings(settingsPath) or nil
    local script = self:LoadScript(scriptPath)
    if (templateName ~= "Header" and not settings) or not script then
        log:Warning(string.format("[Manager] Missing settings or script for template: %s", templateName))
        return nil, nil
    end
    return settings, script
end

function Manager:InitTemplate(templateName)
    log:Info("[Manager] Initializing template: " .. tostring(templateName))
    local templateFolder = self:NormalizePath(self.TemplateFolder)
    local settingsPath = self:NormalizePath(templateFolder .. "/" .. templateName .. self.LuaExtension)
    local scriptPath = self:NormalizePath(templateFolder .. "/" .. templateName .. self.ScriptExtension)
    local settings, scriptContent = self:LoadFileSafely(templateName, settingsPath, scriptPath)
    if not settings or not scriptContent then
        log:Warning("[Manager] Could not initialize template: " .. tostring(templateName))
        return
    end
    for key, value in pairs(settings) do
        if type(key) == "string" and type(value) == "string" then
            scriptContent = scriptContent:gsub("<<" .. key .. ">>", value)
        end
    end
    log:Info("[Manager] Template initialized: " .. tostring(templateName))
    return scriptContent
end

return Manager