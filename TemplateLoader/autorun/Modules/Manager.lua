local NAME = "TemplateLoader.Manager"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Engine Template Framework (Manager)"

--[[
    -- To debug the module, use the following setup to load modules from the autorun folder:
    local sep = package.config:sub(1, 1)
    package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
    local Manager = require("Manager")
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
local Logger = require("Logger")
local File = require("File")
local Memory = require("Memory")

local Manager = {}

function Manager.normalizePath(path)
    return path:gsub("\\", "/"):gsub("//+", "/"):match("^(.-)/?$")
end

local CEA_EXTENSION = ".CEA"
local LUA_EXTENSION = ".Settings.lua"
local TEMPLATES_FOLDER = Manager.normalizePath(getAutorunPath() .. "Templates") .. sep

function Manager.getCeaExtension()
    return CEA_EXTENSION
end

function Manager.getLuaExtension()
    return LUA_EXTENSION
end

function Manager.getTemplatesFolder()
    return TEMPLATES_FOLDER
end

function Manager.discoverTemplates()
    local templates = {}
    local folderPath = Manager.normalizePath(TEMPLATES_FOLDER)

    if not File.exists(folderPath) then
        Logger.error("Manager: Templates folder not found: " .. folderPath)
        return templates
    end

    local files = File.scanFolder(folderPath, false)

    for _, file in ipairs(files) do
        if file:sub(-#CEA_EXTENSION) == CEA_EXTENSION then
            local templateName = file:match("([^/\\]+)" .. CEA_EXTENSION .. "$")
            if templateName then
                local settingsPath = folderPath .. sep .. templateName .. LUA_EXTENSION
                local scriptPath = file

                local settings, scriptContent = Manager.safeLoad(templateName, settingsPath, scriptPath)
                if settings and scriptContent then
                    templates[#templates + 1] = {
                        name = templateName,
                        scriptPath = scriptPath,
                        settingsPath = settingsPath,
                        settings = settings,
                        scriptContent = scriptContent,
                        fileName = templateName:gsub(CEA_EXTENSION, "")
                    }
                end
            end
        end
    end

    Logger.info("Manager: Discovered templates: " .. #templates)
    return templates
end

function Manager.safeLoad(templateName, settingsPath, scriptPath)
    local settings, scriptContent

    if templateName ~= "Header" then
        local status, err = pcall(function()
            settings = Manager.loadTemplateSettings(templateName, settingsPath)
        end)
        if not status then
            Logger.error("Manager: Failed to load settings for template: " .. templateName .. " - " .. err)
            return nil, nil
        end
    else
        settings = nil
        Logger.info("Manager: Skipping settings load for template: " .. templateName)
    end

    local status, err = pcall(function()
        scriptContent = Manager.loadTemplateScript(templateName, scriptPath)
    end)
    if not status then
        Logger.error("Manager: Failed to load script for template: " .. templateName .. " - " .. err)
        return nil, nil
    end

    return settings, scriptContent
end

function Manager.loadTemplateSettings(templateName, settingsPath)
    Logger.info("Manager: Loading settings for template: " .. templateName)

    if not File.exists(settingsPath) then
        error("Settings file not found: " .. settingsPath)
    end

    local status, settings = pcall(dofile, settingsPath)
    if not status then
        error("Error loading settings for template: " .. templateName .. " - " .. settings)
    end

    Logger.debug("Manager: Settings loaded successfully for template: " .. templateName)
    return settings
end

function Manager.loadTemplateScript(templateName, scriptPath)
    Logger.info("Manager: Loading script for template: " .. templateName)

    if not File.exists(scriptPath) then
        error("Script file not found: " .. scriptPath)
    end

    local scriptContent = File.readFile(scriptPath)
    Logger.debug("Manager: Script loaded successfully for template: " .. templateName)
    return scriptContent
end

function Manager.initializeTemplate(templateName)
    Logger.info("Manager: Initializing template: " .. templateName)

    local settingsPath = TEMPLATES_FOLDER .. sep .. templateName .. LUA_EXTENSION
    local scriptPath = TEMPLATES_FOLDER .. sep .. templateName .. CEA_EXTENSION
    local settings, scriptContent = Manager.safeLoad(templateName, settingsPath, scriptPath)

    if not settings or not scriptContent then
        return
    end

    for key, value in pairs(settings) do
        if type(key) == "string" and type(value) == "string" then
            scriptContent = scriptContent:gsub("<<" .. key .. ">>", value)
            Logger.debug(string.format("Manager: Applied setting: %s = %s", key, value))
        else
            Logger.warn("Manager: Invalid key-value pair in settings. Key: " .. tostring(key) .. ", Value: " .. tostring(value))
        end
    end

    Logger.info("Manager: Template initialized successfully: " .. templateName)
    Logger.debug("Manager: Final script content for " .. templateName .. ":\n" .. scriptContent)
end

return Manager