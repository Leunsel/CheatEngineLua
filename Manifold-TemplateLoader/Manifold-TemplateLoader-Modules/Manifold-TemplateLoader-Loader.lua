--[[
    Manifold.TemplateLoader.Loader.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 2.0.1
    LICENSE : MIT
    CREATED : 2025-06-21
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

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Log     = require("Manifold-TemplateLoader-Log")
local JSON    = require("Manifold-TemplateLoader-Json")
local File    = require("Manifold-TemplateLoader-File")
local Memory  = require("Manifold-TemplateLoader-Memory")
local Manager = require("Manifold-TemplateLoader-Manager")
local UI      = require("Manifold-TemplateLoader-UI")

local log     = Log:New()
local file    = File:New()
local memory  = Memory:New()
local manager = Manager:New()
local ui      = UI:New()
local json    = JSON:new()

local Loader = {
    RegisteredTemplates = {},
    ConfigPath = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "Manifold-TemplateLoader-Config.json",
    Config = nil,
    DefaultConfig = {
        Logger = { Level = "ERROR", LogToFile = true },
        InjectionInfo = { LineCount = 3, RemoveSpaces = true, AddTabs = true, AppendToHookName = "Hook" }
    },
    AutoInjectForm = nil,
    AutoInjectForms = {}
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
    if not instance then
        instance = setmetatable({}, Loader)
        instance:LoadConfig()
        instance.RegisteredTemplates = manager:DiscoverTemplates()
    end
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
    local usedShortcuts = {}
    for _, template in ipairs(self.RegisteredTemplates) do
        local shortcut = template.settings and template.settings.Shortcut
        if shortcut and shortcut ~= "" then
            if usedShortcuts[shortcut] then
                log:Error(string.format(
                    "[Loader] Shortcut conflict for '%s': '%s' is already used by template '%s'.",
                    template.fileName, shortcut, usedShortcuts[shortcut]))
                template.settings.Shortcut = ""
            else
                usedShortcuts[shortcut] = template.fileName
            end
        end
        self:RegisterTemplate(template)
    end
end

function Loader:RegisterTemplate(template)
    local caption = template.settings.Caption
    local shortcut = template.settings and template.settings.Shortcut
    log:Info("[Loader] Registering template: " .. tostring(caption))
    local function templateFunc(script, sender)
        self:GetTemplateScript(template, script, sender)
    end
    local id = registerAutoAssemblerTemplate(caption, templateFunc, shortcut)
    if not id then
        log:Error("[Loader] Failed to register template: " .. tostring(caption))
        return
    end
    self.RegisteredTemplates[caption] = {
        id = id,
        caption = caption,
        file = template.fileName,
        subMenu = template.settings.SubMenuName or "Templates",
        settings = template.settings,
        templateObj = template
    }
    if shortcut == nil then
        log:Info(string.format("[Loader] Registered template '%s' with id %d (no shortcut set)", caption, id))
    elseif shortcut == "" then
        log:Info(string.format("[Loader] Registered template '%s' with id %d (empty shortcut)", caption, id))
    else
        log:Info(string.format("[Loader] Registered template '%s' with id %d and shortcut '%s'", caption, id, shortcut))
    end
end

function Loader:UnregisterTemplate(caption)
    local entry = self.RegisteredTemplates[caption]
    if not entry then
        log:Warning("[Loader] Tried to unregister unknown template: " .. tostring(caption))
        return
    end
    if entry.id then
        unregisterAutoAssemblerTemplate(entry.id)
        log:Info(string.format("[Loader] Unregistered template '%s' (id=%d)", caption, entry.id))
    else
        log:Error(string.format("[Loader] Template '%s' has no id to unregister!", caption))
    end
    self.RegisteredTemplates[caption] = nil
end

function Loader:GetTemplateScript(template, script, sender)
    log:Info("[Loader] Getting script for template: " .. tostring(template.fileName))
    local env = self:GetEnvironment()
    if not env then
        -- local fileName   = tostring(template.fileName or "<unknown>")
        -- local scriptPath = tostring(template.scriptPath or "<unknown>")
        -- local senderName = tostring((sender and sender.Name) or sender or "<unknown>")
        -- local msg =
        --     "Failed to initialize template environment.\n\n" ..
        --     "Template: " .. fileName .. "\n" ..
        --     "Script Path: " .. scriptPath .. "\n" ..
        --     "Triggered By: " .. senderName .. "\n\n" ..
        --     "This means the loader could not create a runtime environment for the template.\n" ..
        --     "Possible causes:\n" ..
        --     "  • The template contains syntax errors\n" ..
        --     "  • A required module failed to load\n" ..
        --     "  • An internal failure occurred inside the environment builder\n\n" ..
        --     "Check the log for more detailed error output."
        -- messageDialog("Template Environment Error", msg, mtError, mbOK)
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
    local f, err = io.open(path, "rb")
    if not f then
        log:Error(string.format(
            "[Loader] Failed to open file '%s'. Error: %s\nPossible causes:\n- UTF-8 file name?\n- Permissions?\n- CE sandbox?",
            tostring(path), tostring(err)))
        return nil, tostring(err)
    end
    local raw = f:read("*all")
    f:close()
    if not raw then
        log:Error("[Loader] File read returned nil for: " .. tostring(path))
        return nil, "File read error"
    end
    -- UTF-8 BOM detection
    if raw:sub(1,3) == "\239\187\191" then
        log:Info("[Loader] UTF-8 BOM detected in file: " .. path)
        raw = raw:sub(4) -- strip BOM
    end
    -- Non-UTF8 characters? (not a guarantee, but a good indicator...)
    if not raw:match("^[%z\1-\127\194-\244][\128-\191]*") then
        log:Warning("[Loader] Potential non-UTF8 characters detected in file: " .. path)
    end
    return self:Compile(raw, env)
end

local function getSafeLongBracket(text)
    local eq = ""
    while text:find("%[" .. eq .. "%[", 1, true) or text:find("%]" .. eq .. "%]", 1, true) do
        eq = eq .. "="
    end
    return eq
end

function Loader:Append(builder, text, code)
    if code then
        builder[#builder + 1] = code
    else
        local eq = getSafeLongBracket(text)
        local fmt = '_ret[#_ret + 1] = [%s[\n%s]%s]'
        builder[#builder + 1] = string.format(fmt, eq, text, eq)
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

function Loader:UnloadTemplates()
    log:ForceInfo("[Loader] Unloading templates...")
    for caption, id in pairs(self.RegisteredTemplates) do
        unregisterAutoAssemblerTemplate(id.id)
        log:ForceInfo("[Loader] Unregistered template: " .. tostring(caption))
    end
    self.RegisteredTemplates = {}
    log:ForceInfo("[Loader] All templates unloaded.")
end

function Loader:RemoveOldMenuEntries(template1)
    if not template1 then
        log:Warning("[Loader] RemoveOldMenuEntries aborted: template1 menu item not found.")
        return
    end
    local myCaptions = {}
    local mySubMenus = {}
    for _, template in ipairs(self.RegisteredTemplates or {}) do
        local settings = template.settings or {}
        local cap = settings.Caption or template.fileName
        local sub = settings.SubMenuName or "Templates"
        myCaptions[cap] = true
        mySubMenus[sub] = true
    end
    for i = template1.Count - 1, 0, -1 do
        local item = template1:getItem(i)
        if myCaptions[item.Caption] then
            template1:delete(i)
        end
    end
    for i = template1.Count - 1, 0, -1 do
        local item = template1:getItem(i)
        if item.Count ~= nil and mySubMenus[item.Caption] then
            template1:delete(i)
        end
    end
end

function Loader:BuildMenu(template1)
    if not template1 then
        log:Warning("[Loader] BuildMenu aborted: template1 menu item not found.")
        return
    end
    log:Info(string.format(
        "[Loader] Building template menu with %d template(s)...",
        #(self.RegisteredTemplates or {})))
    self:LoadTemplates()
    ui:CategorizeMenuItems(self, template1, self.Indices)
    log:Info("[Loader] Menu successfully rebuilt.")
end

function Loader:ReloadTemplates()
    log:ForceInfo("[Loader] Starting template reload...")
    if #self.AutoInjectForms == 0 then
        log:ForceWarning("[Loader] Reload aborted: No TfrmAutoInject instances available.")
        return
    end
    local latestForm = self.AutoInjectForms[#self.AutoInjectForms]
    local oldForms = { table.unpack(self.AutoInjectForms, 1, #self.AutoInjectForms - 1) }
    log:Info(string.format("[Loader] Active forms: latest=%s, old=%d",
        latestForm and (latestForm.Name or "<unnamed>") or "<nil>",
        #oldForms))
    if #oldForms > 0 then
        log:ForceWarning(string.format(
            "[Loader] Detected %d additional AutoInject window(s) that must be closed for safe reload.",
            #oldForms))
        local messageText = string.format(
            "There are %d other AutoInject window(s) currently open.\n\n" ..
            "Each AutoInject window runs as an independent instance. Keeping old windows open can lead to:\n" ..
            "  • Conflicting template states\n" ..
            "  • Stale or dangling references\n" ..
            "  • Inconsistent or outdated UI elements\n\n" ..
            "To ensure a clean reload of templates, the old windows need to be closed.\n\n" ..
            "IMPORTANT\n" ..
            "Closing these windows will discard any unsaved scripts.\n" ..
            "Please make sure you have saved all your work before continuing.\n\n" ..
            "Do you want to close all old AutoInject windows now?",
            #oldForms)
        local result = messageDialog("Reload Templates", messageText, mtConfirmation, mbYes, mbNo)
        if result ~= mrYes then
            log:ForceInfo("[Loader] User canceled reload: Old windows remain open.")
            self.AutoInjectForm = latestForm
            return
        end
        log:Info("[Loader] User confirmed closing old windows.")
    end
    local template1 = ui:FindMenuItem(latestForm, "emplate1")
    if not template1 then
        log:ForceWarning("[Loader] Warning: Menu entry 'emplate1' not found. Menu rebuild will be skipped.")
    else
        log:Info("[Loader] Located template menu entry 'emplate1'.")
        self:RemoveOldMenuEntries(template1)
        log:Info("[Loader] Removed old template menu entries.")
    end
    log:Info("[Loader] Unloading previously loaded templates...")
    self:UnloadTemplates()
    self.RegisteredTemplates = manager:DiscoverTemplates()
    log:ForceInfo(string.format("[Loader] Template discovery complete: %d template(s) found.",
        #self.RegisteredTemplates))
    log:Info("[Loader] Loading templates into environment...")
    for _, oldForm in ipairs(oldForms) do
        if oldForm and oldForm.ClassName == "TfrmAutoInject" and oldForm.Handle then
            log:Info(string.format("[Loader] Closing old AutoInject form: %s",
                oldForm.Name or "<unnamed>"))
            oldForm:Close()
        else
            log:Warning("[Loader] Skipping invalid or already closed form reference.")
        end
    end
    self.AutoInjectForms = { latestForm }
    self.AutoInjectForm = latestForm
    if template1 then
        log:Info("[Loader] Rebuilding template menu UI...")
        self:BuildMenu(template1)
        log:ForceInfo("[Loader] Template menu successfully rebuilt.")
    else
        log:ForceWarning("[Loader] Menu rebuild skipped: 'emplate1' menu item missing.")
    end
    log:ForceInfo("[Loader] Template reload complete.")
end

function Loader:ReloadDependencies()
    log:ForceInfo("[Loader] Reloading dependencies...")
    if self.AutoInjectForm and self.AutoInjectForm.Handle then
        local form = self.AutoInjectForm
        local oldUI = ui
        local root = oldUI:FindMenuItem(form, "emplate1")
        if root then
            log:ForceInfo("[Loader] Removing old menu entries...")
            self:RemoveOldMenuEntries(root)
        else
            log:ForceWarning("[Loader] Old menu cleanup skipped: 'emplate1' not found.")
        end
    end
    local modules = {
        "Manifold-TemplateLoader-Log",
        "Manifold-TemplateLoader-File",
        "Manifold-TemplateLoader-Memory",
        "Manifold-TemplateLoader-Manager",
        "Manifold-TemplateLoader-UI"
    }
    for _,m in pairs(modules) do
        package.loaded[m] = nil
    end
    local nLog      = require("Manifold-TemplateLoader-Log")
    local nFile     = require("Manifold-TemplateLoader-File")
    local nMemory   = require("Manifold-TemplateLoader-Memory")
    local nManager  = require("Manifold-TemplateLoader-Manager")
    local nUI       = require("Manifold-TemplateLoader-UI")
    log     = nLog:New()
    file    = nFile:New()
    memory  = nMemory:New()
    manager = nManager:New()
    ui      = nUI:New()
    log:ForceInfo("[Loader] Modules reloaded...")
    if #self.AutoInjectForms > 1 then
        local latest = self.AutoInjectForms[#self.AutoInjectForms]
        for i = 1, #self.AutoInjectForms - 1 do
            local old = self.AutoInjectForms[i]
            if old and old.Handle then old:Close() end
        end
        self.AutoInjectForms = { latest }
        self.AutoInjectForm  = latest
    end
    if self.AutoInjectForm and self.AutoInjectForm.Handle then
        log:ForceInfo("[Loader] Rebuilding UI (menu)...")
        local form = self.AutoInjectForm
        local timer = createTimer()
        timer.Interval = 50
        timer.OnTimer = function()
            timer.destroy()
            local root = ui:FindMenuItem(form, "emplate1")
            if root then
                self:BuildMenu(root)
                log:ForceInfo("[Loader] UI rebuild complete. [SECONDARY RELOAD]")
            else
                log:ForceWarning("[Loader] Menu rebuild skipped: 'emplate1' not found. [SECONDARY RELOAD]")
            end
        end
    end
    log:ForceInfo("[Loader] Dependency reload completed. [MAIN RELOAD]")
end

function Loader:BuildUICallbacks(indices)
    local config = self.Config
    local memory = memory
    local log = log
    local manager = manager
    return {
        memory = memory,
        onLevelChange = function(level, sender)
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
        end,
        onLogToFile = function(sender)
            config.Logger.LogToFile = not config.Logger.LogToFile
            log.LogToFile = config.Logger.LogToFile
            sender.Checked = log.LogToFile
            self:SaveConfig()
            log:Info("[Loader] Log to File " .. (log.LogToFile and "enabled" or "disabled"))
        end,
        onViewLog = function()
            local logPath = log.LogFileName or "Manifold-TemplateLoader-Log.txt"
            if file:Exists(logPath) then
                shellExecute(logPath)
            else
                messageDialog("Log File does not exist:\n" .. logPath, mtWarning, mbOK)
            end
        end,
        onOpenFolder = function()
            local templateFolderPath = manager:GetTemplateFolder()
            if file:FolderExists(templateFolderPath) then
                shellExecute(templateFolderPath)
            else
                log:Error("[Loader] Template Folder does not seem to exist!")
            end
        end,
        onSetLineCount = function()
            local val = inputQuery("Set Injection Info Line Count", "Enter line count (number > 0):", tostring(config.InjectionInfo.LineCount or ""))
            local num = tonumber(val)
            if num and num > 0 then
                config.InjectionInfo.LineCount = num
                memory:SetInjInfoLineCount(num)
                self:SaveConfig()
            end
        end,
        onSetAppend = function()
            local val = inputQuery("Set Append To Hook Name", "Enter value for AppendToHookName (string):", tostring(config.InjectionInfo.AppendToHookName or ""))
            if val ~= nil then
                config.InjectionInfo.AppendToHookName = val
                if memory.AppendToHookName then
                    memory:SetAppendToHookName(val)
                end
                self:SaveConfig()
            end
        end,
        onToggle = function(optKey, setter)
            return function(sender)
                local newVal = not config.InjectionInfo[optKey]
                config.InjectionInfo[optKey] = newVal
                setter(newVal)
                self:SaveConfig()
                sender.Checked = newVal
            end
        end,
        onReloadDependencies = function()
            self:ReloadDependencies()
        end,
        onReloadTemplates = function()
            self:ReloadTemplates()
        end,
        onResetConfig = function()
            if messageDialog("Are you sure you want to reset the configuration to defaults?", mtConfirmation, mbYes, mbNo) == mrYes then
                self:ResetConfig()
            end
        end
    }
end

function Loader:SetupMenu(form)
    log:Debug("[Loader] Initializing menu...")
    local template1 = ui:FindMenuItem(form, "emplate1")
    if template1 then
        if ui:AddSeparatorAfter(template1, "CheatTablecompliantcodee1") then
            log:Info("[Loader] Separator after 'Cheat Table Framework Code' added.")
        else
            log:Warning("[Loader] Target menu item not found inside emplate1!")
        end
    else
        log:Warning("[Loader] emplate1 not found!")
    end
    local indices = self.Indices
    local aaImageList = form.aaImageList
    local mvForm = getMemoryViewForm()
    indices = {
        Eye = aaImageList.add(mvForm.Watchmemoryallocations1.Bitmap),
        Template = aaImageList.add(mvForm.AutoInject1.Bitmap),
        Toggle = aaImageList.add(mvForm.CreateThread1.Bitmap),
        Log = aaImageList.add(mvForm.miDebugSetAddress.Bitmap),
        Inject = aaImageList.add(mvForm.InjectDLL1.Bitmap),
        Level = aaImageList.add(mvForm.MenuItem14.Bitmap),
    }
    self.Indices = indices
    local menuTree = ui:GetMainMenuTree(self.Config, indices, self:BuildUICallbacks())
    ui:BuildTree(form.MainMenu1, menuTree)
    ui:CategorizeMenuItems(self, template1, indices)
    -- DEBUG
    -- for i = 0, form.ComponentCount - 1 do
    --     log:ForceInfo("[Loader] Component: " .. form.Component[i].Name)
    -- end
    -- if _G.ui and type(_G.ui.ApplyThemeToAutoInject) == "function" then
    --     _G.ui:ApplyThemeToAutoInject(form)
    -- end
    form.Assemblescreen.ScrollBars = 'ssAutoBoth'
    form.Assemblescreen.RightEdge = -1
    form.Panel2.BorderStyle = "bsNone"
end

function Loader:AttachMenuToForm()
    local function onFormCreate(form)
        if form.ClassName == "TfrmAutoInject" then
            table.insert(self.AutoInjectForms, form)
            self.AutoInjectForm = form
            createTimer(50, function() self:SetupMenu(form) end)
        end
    end
    log:Info("[Loader] Attaching menu to TfrmAutoInject form.")
    registerFormAddNotification(onFormCreate)
end

return Loader