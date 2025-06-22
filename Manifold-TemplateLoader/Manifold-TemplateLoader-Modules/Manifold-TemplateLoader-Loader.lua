--[[
    Manifold.TemplateLoader.Loader.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 2.0.0
    LICENSE : MIT
    CREATED : 2025-06-21
    UPDATED : 2025-06-22
    
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
local Json = require("Manifold-TemplateLoader-Json")
local File = require("Manifold-TemplateLoader-File")
local Memory = require("Manifold-TemplateLoader-Memory")
local Manager = require("Manifold-TemplateLoader-Manager")

local log = Log:New()
local json = Json:new()
local file = File:New()
local memory = Memory:New()
local manager = Manager:New()

local Loader = { 
    RegisteredTemplates = {},
    ConfigPath = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "Manifold-TemplateLoader-Config.json",
    Config = {
        Logger = {
            Level = "INFO",
            LogToFile = true
        },
        InjectionInfo = {
            LineCount = 3,
            RemoveSpaces = true,
            AddTabs = true,
            AppendToHookName = "Hook"
        }
    }
}
Loader.__index = Loader
local instance = nil

function Loader:New()
    if not instance then
        instance = setmetatable({}, Loader)
    end
    instance:LoadConfig()
    instance.RegisteredTemplates = manager:DiscoverTemplates()
    log:Info("[Loader] Discovered templates: " .. tostring(#instance.RegisteredTemplates))
    return instance
end

function Loader:LoadConfig()
    log:Info("[Loader] Loading configuration from " .. self.ConfigPath)
    if file:Exists(self.ConfigPath) then
        local content = file:ReadFile(self.ConfigPath)
        local ok, config = pcall(function() return json:decode(content) end)
        if ok and type(config) == "table" then
            self.Config = config
            self:ApplyLoggerConfig()
            self:ApplyInjectionInfoConfig()
            log:Info("[Loader] Config loaded from JSON.")
        else
            log:Warning("[Loader] Failed to parse config, using defaults.")
            self:CreateConfig()
        end
    else
        log:Warning("[Loader] Configuration file not found: " .. self.ConfigPath)
        self:CreateConfig()
    end
end

function Loader:SaveConfig()
    local encoded = json:encode_pretty(self.Config)
    file:WriteFile(self.ConfigPath, encoded)
    log:Info("[Loader] Configuration saved to " .. self.ConfigPath)
end

function Loader:CreateConfig()
    self.Config = {
        Logger = {
            Level = "INFO",
            LogToFile = false
        },
        InjectionInfo = {
            LineCount = 3,
            RemoveSpaces = true,
            AddTabs = true,
            AppendToHookName = "Hook"
        }
    }
    self:SaveConfig()
    log:Info("[Loader] Created default config at: " .. self.ConfigPath)
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
    log:Info("[Loader] Unloading templates...")
    for caption, id in pairs(self.RegisteredTemplates) do
        unregisterAutoAssemblerTemplate(id)
        log:Info("[Loader] Unregistered template: " .. tostring(caption))
    end
    self.RegisteredTemplates = {}
    log:Info("[Loader] All templates unloaded.")
end

function Loader:ReloadTemplates()
    log:Info("[Loader] Reloading templates...")
    self:UnloadTemplates()
    self.RegisteredTemplates = manager:DiscoverTemplates()
    log:Info("[Loader] Discovered templates: " .. tostring(#self.RegisteredTemplates))
    self:LoadTemplates()
end

function Loader:ReloadDependencies()
    log:Info("[Loader] Reloading dependencies...")
    local modules = {
        "Manifold-TemplateLoader-Log",
        "Manifold-TemplateLoader-File",
        "Manifold-TemplateLoader-Memory",
        "Manifold-TemplateLoader-Manager"
    }
    for _, mod in ipairs(modules) do
        package.loaded[mod] = nil
    end
    Log = require(modules[1])
    File = require(modules[2])
    Memory = require(modules[3])
    Manager = require(modules[4])
    log = Log:New()
    file = File:New()
    memory = Memory:New()
    manager = Manager:New()
    Loader.__index = Loader
    log:Info("[Loader] Dependencies reloaded successfully.")
end

local function addMenuItem(parent, caption, name, opts)
    local item = createMenuItem(parent)
    item.Caption = caption
    item.Name = name
    if opts then
        for k, v in pairs(opts) do
            if k == "OnClick" then
                item.OnClick = v
            elseif item[k] ~= nil then
                item[k] = v
            end
        end
    end
    if parent == parent.Owner.MainMenu1 then
        parent.Items:add(item)
    else
        parent:add(item)
    end
    return item
end

function Loader:SetupLoggerMenu(parent, indices)
    local logLevels = { "DEBUG", "INFO", "WARNING", "ERROR" }
    local logLevelMenu = addMenuItem(parent, "Log Level", "LogLevelMenu", { ImageIndex = indices.BreakAndTrace })
    local currentLevel = self.Config.Logger.Level or "INFO"
    for _, level in ipairs(logLevels) do
        addMenuItem(logLevelMenu, level, "LogLevel_" .. level, {
            RadioItem = true,
            Checked = (level == currentLevel),
            OnClick = function()
                local numericLevel = log.LogLevel[level]
                if numericLevel then
                    log:SetLogLevel(numericLevel)
                    for i = 0, logLevelMenu.Count - 1 do
                        local item = logLevelMenu[i]
                        item.Checked = (item.Caption == level)
                    end
                    self.Config.Logger.Level = level
                    self:SaveConfig()
                    log:ForceInfo("[Loader] Log level set to " .. level)
                else
                    log:ForceError("[Loader] Invalid log level: " .. tostring(level))
                end
            end
        })
    end
    addMenuItem(parent, "Log to File", "LogToFile", {
        AutoCheck = true,
        Checked = self.Config.Logger.LogToFile == true,
        ImageIndex = indices.Reload,
        OnClick = function(sender)
            self.Config.Logger.LogToFile = not self.Config.Logger.LogToFile
            log.LogToFile = self.Config.Logger.LogToFile
            sender.Checked = log.LogToFile
            self:SaveConfig()
            log:Info("[Loader] Log to File " .. (log.LogToFile and "enabled" or "disabled"))
        end
    })
    addMenuItem(parent, "View Log File", "ViewLogFile", {
        ImageIndex = indices.Reload,
        OnClick = function()
            local logPath = log.LogFileName or "Manifold-TemplateLoader-Log.txt"
            if file:Exists(logPath) then
                shellExecute(logPath)
            else
                messageDialog("Log File does not exist:\n" .. logPath, mtWarning, mbOK)
            end
        end
    })
end

function Loader:SetupInjectionInfoMenu(parent)
    local function setLineCount()
        local val = inputQuery("Set Injection Info Line Count", "Enter line count (number > 0):", tostring(self.Config.InjectionInfo.LineCount or ""))
        local num = tonumber(val)
        if num and num > 0 then
            self.Config.InjectionInfo.LineCount = num
            memory:SetInjInfoLineCount(num)
            self:SaveConfig()
            -- messageDialog("Injection Info Line Count set to " .. num, mtInformation, mbOK)
        else
            -- messageDialog("Invalid value.", mtError, mbOK)
        end
    end
    local function setAppendToHookName()
        local val = inputQuery("Set Append To Hook Name", "Enter value for AppendToHookName (string):", tostring(self.Config.InjectionInfo.AppendToHookName or ""))
        if val ~= nil then
            self.Config.InjectionInfo.AppendToHookName = val
            if memory.AppendToHookName then
                memory:SetAppendToHookName(val)
            end
            self:SaveConfig()
            -- messageDialog("AppendToHookName set to '" .. val .. "'", mtInformation, mbOK)
        end
    end
    local function toggleOption(optKey, setter)
        return function(sender)
            local newVal = not self.Config.InjectionInfo[optKey]
            self.Config.InjectionInfo[optKey] = newVal
            setter(newVal)
            self:SaveConfig()
            sender.Checked = newVal
        end
    end
    addMenuItem(parent, "Set Info Line Count...", "SetInjInfoLineCount", { OnClick = setLineCount })
    addMenuItem(parent, "Set Append To Hook Name...", "SetAppendToHookName", { OnClick = setAppendToHookName })
    addMenuItem(parent, "Remove Spaces", "SetInjInfoRemoveSpaces", {
        AutoCheck = true,
        Checked = self.Config.InjectionInfo.RemoveSpaces == true,
        OnClick = toggleOption("RemoveSpaces", memory.SetInjInfoRemoveSpaces)
    })
    addMenuItem(parent, "Add Tabs", "SetInjInfoAddTabs", {
        AutoCheck = true,
        Checked = self.Config.InjectionInfo.AddTabs == true,
        OnClick = toggleOption("AddTabs", memory.SetInjInfoAddTabs)
    })
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
    local templateOptionsMenu = addMenuItem(form.MainMenu1, "Template Options", "TemplateOptions")
    local loggerSettingsMenu = addMenuItem(templateOptionsMenu, "Logger Settings", "LoggerSettings", { ImageIndex = indices.BreakAndTrace })
    local injectionSettingsMenu = addMenuItem(templateOptionsMenu, "Injection Settings", "InjectionSettings", { ImageIndex = indices.BreakAndTrace })
    self:SetupLoggerMenu(loggerSettingsMenu, indices)
    self:SetupInjectionInfoMenu(injectionSettingsMenu)
    local menuItems = {
        { caption = "Reload Dependencies", name = "ReloadDependencies", image = indices.Resync, order = 1, onClick = function() self:ReloadDependencies() end },
        { caption = "Reload Templates",    name = "ReloadTemplates",    image = indices.Resync, order = 2, onClick = function() self:ReloadTemplates() end }
    }
    table.sort(menuItems, function(a, b) return a.order < b.order end)
    for _, v in ipairs(menuItems) do
        addMenuItem(templateOptionsMenu, v.caption, v.name, { ImageIndex = v.image, OnClick = v.onClick })
    end
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