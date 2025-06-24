--[[
    Manifold.TemplateLoader.Loader.lua
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

local Log     = require("Manifold-TemplateLoader-Log")
local Json    = require("Manifold-TemplateLoader-Json")
local File    = require("Manifold-TemplateLoader-File")
local Memory  = require("Manifold-TemplateLoader-Memory")
local Manager = require("Manifold-TemplateLoader-Manager")

local log     = Log:New()
local json    = Json:new()
local file    = File:New()
local memory  = Memory:New()
local manager = Manager:New()

local Loader = {
    RegisteredTemplates = {},
    ConfigPath = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "Manifold-TemplateLoader-Config.json",
    Config = nil,
    DefaultConfig = {
        Logger = { Level = "ERROR", LogToFile = true },
        InjectionInfo = { LineCount = 3, RemoveSpaces = true, AddTabs = true, AppendToHookName = "Hook" }
    }
}
Loader.__index = Loader
local instance = nil

local function deepCopy(src)
    if type(src) ~= "table" then return src end
    local dst = {}
    for k, v in pairs(src) do
        dst[k] = type(v) == "table" and deepCopy(v) or v
    end
    return dst
end

function Loader:New()
    if not instance then instance = setmetatable({}, Loader) end
    instance:LoadConfig()
    instance.RegisteredTemplates = manager:DiscoverTemplates()
    log:Info("[Loader] Discovered templates: " .. tostring(#instance.RegisteredTemplates))
    return instance
end

function Loader:LoadConfig()
    log:Info("[Loader] Loading configuration from " .. self.ConfigPath)
    local configLoaded = false
    if file:Exists(self.ConfigPath) then
        local content = file:ReadFile(self.ConfigPath)
        local ok, config = pcall(function() return json:decode(content) end)
        if ok and type(config) == "table" then
            self.Config = deepCopy(self.DefaultConfig)
            for section, sectionData in pairs(config) do
                if type(sectionData) == "table" and type(self.Config[section]) == "table" then
                    for k, v in pairs(sectionData) do
                        self.Config[section][k] = v
                    end
                else
                    self.Config[section] = sectionData
                end
            end
            configLoaded = true
            log:Info("[Loader] Config loaded and applied from JSON.")
        else
            log:Warning("[Loader] Failed to parse config, using defaults.")
        end
    end
    if not configLoaded then
        self.Config = deepCopy(self.DefaultConfig)
        self:SaveConfig()
        log:Info("[Loader] Created default config at: " .. self.ConfigPath)
    end
    self:ApplyLoggerConfig()
    self:ApplyInjectionInfoConfig()
end

function Loader:SaveConfig()
    file:WriteFile(self.ConfigPath, json:encode_pretty(self.Config))
    log:Info("[Loader] Configuration saved to " .. self.ConfigPath)
end

function Loader:CreateConfig()
    self.Config = deepCopy(self.DefaultConfig)
    self:SaveConfig()
    log:Info("[Loader] Created default config at: " .. self.ConfigPath)
end

function Loader:ResetConfig()
    self.Config = deepCopy(self.DefaultConfig)
    self:SaveConfig()
    self:ApplyLoggerConfig()
    self:ApplyInjectionInfoConfig()
    log:ForceInfo("[Loader] Configuration reset to defaults. Please open a new AutoAssembly form to see changes.")
end

function Loader:ApplyLoggerConfig()
    local logger = self.Config.Logger or {}
    if logger.Level and log.LogLevel[logger.Level] then
        log:SetLogLevel(log.LogLevel[logger.Level])
    end
    if logger.LogToFile ~= nil then
        log.LogToFile = logger.LogToFile
    end
end

function Loader:ApplyInjectionInfoConfig()
    local inj = self.Config.InjectionInfo or {}
    if inj.LineCount and type(inj.LineCount) == "number" and inj.LineCount > 0 then
        memory:SetInjInfoLineCount(inj.LineCount)
    end
    if inj.RemoveSpaces ~= nil then
        memory:SetInjInfoRemoveSpaces(inj.RemoveSpaces)
    end
    if inj.AddTabs ~= nil then
        memory:SetInjInfoAddTabs(inj.AddTabs)
    end
    if inj.AppendToHookName ~= nil then
        memory:SetAppendToHookName(inj.AppendToHookName)
    end
end

function Loader:GetEnvironment()
    local env = memory:GetMemoryInfo()
    if not env then 
        log:Error("[Loader] Failed to get memory info for environment")
        return nil
    end
    env.FinalCompilation = false
    setmetatable(env, { __index = _G })
    env._safe = function(v) return v == nil and "" or tostring(v) end
    return env
end

function Loader:LoadTemplates()
    if not self.RegisteredTemplates or #self.RegisteredTemplates == 0 then
        log:Warning("[Loader] No templates to load")
        return
    end
    for _, template in ipairs(self.RegisteredTemplates) do
        self:RegisterTemplate(template)
    end
end

function Loader:RegisterTemplate(template)
    local caption = template.fileName
    local shortcut = template.settings and template.settings.shortcut
    log:Info("[Loader] Registering template: " .. tostring(caption))
    local id = registerAutoAssemblerTemplate(
        caption,
        function(script, sender) self:GetTemplateScript(template, script, sender) end,
        shortcut
    )
    if id then
        self.RegisteredTemplates[caption] = id
        log:Info("[Loader] Registered template '" .. tostring(caption) .. "' with id " .. tostring(id))
    else
        log:Error("[Loader] Failed to register template: " .. tostring(caption))
    end
end

function Loader:UnregisterTemplate(caption)
    local id = self.RegisteredTemplates[caption]
    if id then
        unregisterAutoAssemblerTemplate(id)
        self.RegisteredTemplates[caption] = nil
        log:Info("[Loader] Unregistered template: " .. tostring(caption))
    else
        log:Warning("[Loader] Tried to unregister unknown template: " .. tostring(caption))
    end
end

function Loader:GetTemplateScript(template, script, sender)
    log:Info("[Loader] Getting script for template: " .. tostring(template.fileName))
    local env = self:GetEnvironment()
    if not env then
        log:Error("[Loader] No environment for template: " .. tostring(template.fileName))
        return
    end
    env.Header = self:CompileHeaderTemplate(env)
    local compiledTemplate = self:CompileFile(template.scriptPath, env)
    if compiledTemplate then
        self:ApplyCompiledTemplate(compiledTemplate, script)
        log:Info("[Loader] Applied compiled template: " .. tostring(template.fileName))
    else
        log:Error("[Loader] Failed to compile template: " .. tostring(template.fileName))
    end
end

function Loader:CompileHeaderTemplate(env)
    local headerPath = manager:NormalizePath(manager:GetTemplateFolder() .. sep .. "Header" .. manager:GetScriptExtension())
    log:Info("[Loader] Compiling header template: " .. headerPath)
    if file:Exists(headerPath) then
        local compiledHeader, err = self:CompileFile(headerPath, env)
        if compiledHeader then
            log:Info("[Loader] Compiled header template successfully")
            return compiledHeader
        else
            log:Error("[Loader] Failed to compile header template: " .. tostring(err))
        end
    else
        log:Warning("[Loader] Header template not found: " .. headerPath)
    end
    return nil
end

function Loader:CompileFile(path, env)
    path = manager:NormalizePath(path)
    log:Info("[Loader] Compiling file: " .. tostring(path))
    if not path or not file:Exists(path) then
        log:Error("[Loader] File not found: " .. tostring(path))
        return nil, "File not found"
    end
    local f, err = io.open(path, "r")
    if not f then
        log:Error("[Loader] Failed to open file: " .. tostring(path) .. " (" .. tostring(err) .. ")")
        return nil, tostring(err)
    end
    local template = f:read("*all")
    f:close()
    return self:Compile(template, env)
end

function Loader:Append(builder, text, code)
    if code then
        builder[#builder + 1] = code
    else
        local fmt = '_ret[#_ret + 1] = [%s[\n%s]%s]'
        local mlsFix = string.rep('=', 10)
        builder[#builder + 1] = string.format(fmt, mlsFix, text, mlsFix)
    end
end

function Loader:RunBlock(builder, text)
    local tag = text:sub(1, 2)
    if tag == '<<' then
        local code = text:sub(3, #text - 2):gsub("^%s*(.-)%s*$", "%1")
        self:Append(builder, nil, string.format('_ret[#_ret + 1] = _safe(%s)', code))
    elseif tag == '<%' then
        local code = text:sub(3, #text - 2)
        self:Append(builder, nil, code)
    else
        self:Append(builder, text)
    end
end

function Loader:Compile(template, env)
    if not template or template == '' then
        log:Warning("Loader: Empty template.")
        return ''
    end
    local builder = { '_ret = {}' }
    local pos = 1
    while pos <= #template do
        local startTag = template:find('<[<%%]', pos)
        if not startTag then
            self:Append(builder, template:sub(pos))
            break
        end
        self:Append(builder, template:sub(pos, startTag - 1))
        local tagType = template:sub(startTag, startTag + 1)
        local endTag
        if tagType == '<<' then
            endTag = template:find('>>', startTag)
            if not endTag then
                log:Error("Loader: Missing closing tag for block: " .. template:sub(startTag, startTag + 2))
                error("Loader: Missing closing tag for block: " .. template:sub(startTag, startTag + 2))
            end
            self:RunBlock(builder, template:sub(startTag, endTag + 1))
            pos = endTag + 2
        elseif tagType == '<%' then
            endTag = template:find('%%>', startTag)
            if not endTag then
                log:Error("Loader: Missing closing tag for block: " .. template:sub(startTag, startTag + 2))
                error("Loader: Missing closing tag for block: " .. template:sub(startTag, startTag + 2))
            end
            self:RunBlock(builder, template:sub(startTag, endTag + 1))
            pos = endTag + 2
        else
            log:Error("Loader: Unknown tag type at position " .. tostring(startTag))
            break
        end
    end
    builder[#builder + 1] = 'return table.concat(_ret)'
    log:Info("Loader: Builder completed.")
    local func, err = load(table.concat(builder, '\n'), 'template', 't', env)
    if not func then
        log:Error("Loader: Error compiling template: " .. tostring(err))
        return nil, err
    end
    return func()
end

function Loader:ApplyCompiledTemplate(compiledTemplate, script)
    if type(script.addText) == 'function' then
        script.addText(compiledTemplate)
    else
        local s = script.getText()
        script.clear()
        script.setText(s .. compiledTemplate)
    end
end

function Loader:GenerateTemplateScript(template, script, sender)
    local env = self:GetEnvironment()
    if not env then return end
    env.Header = self:CompileHeaderTemplate(env)
    local compiledTemplate = self:CompileFile(template.scriptPath, env)
    if compiledTemplate then
        self:ApplyCompiledTemplate(compiledTemplate, script)
    end
end

function Loader:UnloadTemplates()
    log:ForceInfo("[Loader] Unloading templates...")
    for caption, id in pairs(self.RegisteredTemplates) do
        unregisterAutoAssemblerTemplate(id)
        log:ForceInfo("[Loader] Unregistered template: " .. tostring(caption))
    end
    self.RegisteredTemplates = {}
    log:ForceInfo("[Loader] All templates unloaded.")
end

function Loader:ReloadTemplates()
    log:ForceInfo("[Loader] Reloading templates...")
    self:UnloadTemplates()
    self.RegisteredTemplates = manager:DiscoverTemplates()
    log:ForceInfo("[Loader] Discovered templates: " .. tostring(#self.RegisteredTemplates))
    self:LoadTemplates()
end

function Loader:ReloadDependencies()
    log:ForceInfo("[Loader] Reloading dependencies...")
    package.loaded["Manifold-TemplateLoader-Manager"] = nil
    package.loaded["Manifold-TemplateLoader-Memory"] = nil
    package.loaded["Manifold-TemplateLoader-File"] = nil
    package.loaded["Manifold-TemplateLoader-Log"] = nil
    Log = require("Manifold-TemplateLoader-Log")
    log = Log:New()
    log:ForceInfo("[Loader] Log Module reloaded successfully.")
    File = require("Manifold-TemplateLoader-File")
    log:ForceInfo("[Loader] File module reloaded successfully.")
    file = File:New()
    Memory = require("Manifold-TemplateLoader-Memory")
    memory = Memory:New()
    log:ForceInfo("[Loader] Memory module reloaded successfully.")
    Manager = require("Manifold-TemplateLoader-Manager")
    manager = Manager:New()
    log:ForceInfo("[Loader] Manager module reloaded successfully.")
    log:ForceInfo("[Loader] All dependencies reloaded successfully.")
end

local function createMenu(parent, opts)
    local item = createMenuItem(parent)
    for k, v in pairs(opts or {}) do
        item[k] = v
    end
    if parent == parent.Owner.MainMenu1 then
        parent.Items:add(item)
    else
        parent:add(item)
    end
    return item
end

local function buildMenuTree(parent, tree)
    for _, entry in ipairs(tree) do
        local item = createMenu(parent, {
            Caption = entry.caption,
            Name = entry.name,
            ImageIndex = entry.image,
            AutoCheck = entry.autoCheck,
            RadioItem = entry.radio,
            Checked = entry.checked,
            OnClick = entry.onClick
        })
        if entry.sub then
            buildMenuTree(item, entry.sub)
        end
    end
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
            image = indices.BreakAndTrace,
            sub = getLogLevelMenu(config.Logger.Level or "INFO", indices, onLevelChange)
        },
        {
            caption = "Log to File",
            name = "LogToFile",
            image = indices.Reload,
            autoCheck = true,
            checked = config.Logger.LogToFile == true,
            onClick = onLogToFile
        },
        {
            caption = "View Log File",
            name = "ViewLogFile",
            image = indices.Reload,
            onClick = onViewLog
        }
    }
end

local function getInjectionMenu(config, memory, onSetLineCount, onSetAppendToHookName, onToggle)
    return {
        {
            caption = "Set Info Line Count...",
            name = "SetInjInfoLineCount",
            onClick = onSetLineCount
        },
        {
            caption = "Set Append To Hook Name...",
            name = "SetAppendToHookName",
            onClick = onSetAppendToHookName
        },
        {
            caption = "Remove Spaces",
            name = "SetInjInfoRemoveSpaces",
            autoCheck = true,
            checked = config.InjectionInfo.RemoveSpaces == true,
            onClick = onToggle("RemoveSpaces", memory.SetInjInfoRemoveSpaces)
        },
        {
            caption = "Add Tabs",
            name = "SetInjInfoAddTabs",
            autoCheck = true,
            checked = config.InjectionInfo.AddTabs == true,
            onClick = onToggle("AddTabs", memory.SetInjInfoAddTabs)
        }
    }
end

local function getMainMenuTree(self, indices)
    local config = self.Config
    local memory = memory
    local function onLevelChange(level, sender)
        local numericLevel = log.LogLevel[level]
        if numericLevel then
            log:SetLogLevel(numericLevel)
            local parent = sender.Parent
            for i = 0, parent.Count - 1 do
                parent[i].Checked = (parent[i].Caption == level)
            end
            config.Logger.Level = level
            self:SaveConfig()
            log:ForceInfo("[Loader] Log level set to " .. level)
        else
            log:ForceError("[Loader] Invalid log level: " .. tostring(level))
        end
    end
    local function onLogToFile(sender)
        config.Logger.LogToFile = not config.Logger.LogToFile
        log.LogToFile = config.Logger.LogToFile
        sender.Checked = log.LogToFile
        self:SaveConfig()
        log:Info("[Loader] Log to File " .. (log.LogToFile and "enabled" or "disabled"))
    end
    local function onViewLog()
        local logPath = log.LogFileName or "Manifold-TemplateLoader-Log.txt"
        if file:Exists(logPath) then
            shellExecute(logPath)
        else
            messageDialog("Log File does not exist:\n" .. logPath, mtWarning, mbOK)
        end
    end
    local function onSetLineCount()
        local val = inputQuery("Set Injection Info Line Count", "Enter line count (number > 0):", tostring(config.InjectionInfo.LineCount or ""))
        local num = tonumber(val)
        if num and num > 0 then
            config.InjectionInfo.LineCount = num
            memory:SetInjInfoLineCount(num)
            self:SaveConfig()
        end
    end
    local function onSetAppendToHookName()
        local val = inputQuery("Set Append To Hook Name", "Enter value for AppendToHookName (string):", tostring(config.InjectionInfo.AppendToHookName or ""))
        if val ~= nil then
            config.InjectionInfo.AppendToHookName = val
            if memory.AppendToHookName then
                memory:SetAppendToHookName(val)
            end
            self:SaveConfig()
        end
    end
    local function onToggle(optKey, setter)
        return function(sender)
            local newVal = not config.InjectionInfo[optKey]
            config.InjectionInfo[optKey] = newVal
            setter(newVal)
            self:SaveConfig()
            sender.Checked = newVal
        end
    end
    return {
        {
            caption = "Template Options",
            name = "TemplateOptions",
            sub = {
                {
                    caption = "Logger Settings",
                    name = "LoggerSettings",
                    image = indices.BreakAndTrace,
                    sub = getLoggerMenu(config, indices, onLevelChange, onLogToFile, onViewLog)
                },
                {
                    caption = "Injection Settings",
                    name = "InjectionSettings",
                    image = indices.BreakAndTrace,
                    sub = getInjectionMenu(config, memory, onSetLineCount, onSetAppendToHookName, onToggle)
                },
                {
                    caption = "Reload Dependencies",
                    name = "ReloadDependencies",
                    image = indices.Resync,
                    onClick = function() self:ReloadDependencies() end
                },
                {
                    caption = "Reload Templates",
                    name = "ReloadTemplates",
                    image = indices.Resync,
                    onClick = function() self:ReloadTemplates() end
                },
                {
                    caption = "Reset Configuration",
                    name = "ResetConfig",
                    image = indices.Resync,
                    onClick = function()
                        if messageDialog("Are you sure you want to reset the configuration to defaults?", mtConfirmation, mbYes, mbNo) == mrYes then
                            self:ResetConfig()
                        end
                    end
                }
            }
        }
    }
end

function Loader:SetupMenu(form)
    log:Debug("[Loader] Initializing menu...")
    local aaImageList = form.aaImageList
    local memoryViewForm = getMemoryViewForm()
    local indices = {
        Resync = aaImageList.add(MainForm.miResyncFormsWithLua.Bitmap),
        BreakAndTrace = aaImageList.add(memoryViewForm.miBreakAndTrace.Bitmap),
        Reload = aaImageList.add(memoryViewForm.miLoadTrace.Bitmap)
    }
    local menuTree = getMainMenuTree(self, indices)
    buildMenuTree(form.MainMenu1, menuTree)
end

function Loader:AttachMenuToForm()
    local function onFormCreate(form)
        if form.ClassName == "TfrmAutoInject" then
            createTimer(50, function() self:SetupMenu(form) end)
        end
    end
    log:Info("[Loader] Attaching menu to TfrmAutoInject form.")
    registerFormAddNotification(onFormCreate)
end

return Loader