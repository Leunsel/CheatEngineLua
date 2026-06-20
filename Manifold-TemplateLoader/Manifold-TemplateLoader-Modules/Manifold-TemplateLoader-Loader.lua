--[[
    Manifold Template Loader

    The loader keeps template definitions and active Cheat Engine registrations
    separate. This makes reloads deterministic and permits a clean rollback when
    a new template set cannot be registered.
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Log = require("Manifold-TemplateLoader-Log")
local JSON = require("Manifold-TemplateLoader-Json")
local File = require("Manifold-TemplateLoader-File")
local Memory = require("Manifold-TemplateLoader-Memory")
local Manager = require("Manifold-TemplateLoader-Manager")
local UI = require("Manifold-TemplateLoader-UI")

local log = Log:New()
local json = JSON:new()
local file = File:New()
local memory = Memory:New()
local manager = Manager:New()
local ui = UI:New()

local Loader = {
    ConfigPath = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "Manifold-TemplateLoader-Config.json",
    DefaultConfig = {
        SchemaVersion = 3,
        Logger = { Level = "ERROR", LogToFile = true },
        InjectionInfo = { LineCount = 3, RemoveSpaces = true, AddTabs = true, AppendToHookName = "Hook" },
        Memory = {
            AskForHookName = true,
            AskForInjectionAddress = false,
            AllocationSize = "$1000",
            AllocationNear = true,
            DefaultHookName = "Injection"
        }
    }
}
Loader.__index = Loader

local instance = nil

local function deepCopy(source)
    if type(source) ~= "table" then return source end
    local copy = {}
    for key, value in pairs(source) do copy[key] = deepCopy(value) end
    return copy
end

local function mergeKnown(defaults, source)
    local merged = deepCopy(defaults)
    if type(source) ~= "table" then return merged end
    for key, defaultValue in pairs(defaults) do
        local candidate = source[key]
        if candidate ~= nil then
            if type(defaultValue) == "table" then
                merged[key] = mergeKnown(defaultValue, candidate)
            elseif type(candidate) == type(defaultValue) then
                merged[key] = candidate
            end
        end
    end
    return merged
end

local function isAliveAutoInjectForm(form)
    if not form then return false end
    local ok, className = pcall(function() return form.ClassName end)
    if not ok or className ~= "TfrmAutoInject" then return false end
    local handleOk, handle = pcall(function() return form.Handle end)
    return not handleOk or handle == nil or handle ~= 0
end

local function getAutoInjectFormKey(form)
    local handleOk, handle = pcall(function() return form.Handle end)
    if handleOk and handle and handle ~= 0 then return "handle:" .. tostring(handle) end
    -- TfrmAutoInject instances share the same Name while the add-notification
    -- fires, so Name cannot safely identify a window here.
    return "object:" .. tostring(form)
end

local function safeMenuImage(imageList, bitmap)
    if not imageList or not bitmap then return -1 end
    local ok, index = pcall(function() return imageList.add(bitmap) end)
    return ok and index or -1
end

function Loader:New()
    if not instance then
        instance = setmetatable({
            Config = nil,
            TemplateDefinitions = {},
            RegisteredTemplates = {},
            RegisteredByCaption = {},
            AutoInjectForms = {},
            FormIndices = setmetatable({}, { __mode = "k" }),
            FormTemplateGeneration = setmetatable({}, { __mode = "k" }),
            TemplateGeneration = 0,
            ReloadInProgress = false,
            DependencyReloadInProgress = false,
            FormNotificationRegistered = false
        }, Loader)
        instance:LoadConfig()
        instance:DiscoverTemplates()
    end
    return instance
end

function Loader:AdoptRuntimeState(previous)
    self.AutoInjectForms = previous.AutoInjectForms or {}
    self.AutoInjectForm = previous.AutoInjectForm
    self.FormIndices = previous.FormIndices or setmetatable({}, { __mode = "k" })
    self.FormTemplateGeneration = previous.FormTemplateGeneration or setmetatable({}, { __mode = "k" })
    self.TemplateGeneration = previous.TemplateGeneration or 0
end

function Loader:LogReload(message, isError)
    local prefix = "[Reload] " .. tostring(message)
    if isError then
        log:ForceError(prefix)
    else
        log:ForceInfo(prefix)
    end
end

function Loader:AdvanceTemplateGeneration()
    self.TemplateGeneration = (self.TemplateGeneration or 0) + 1
    self.FormTemplateGeneration = self.FormTemplateGeneration or setmetatable({}, { __mode = "k" })
    for _, form in ipairs(self:GetTrackedForms()) do
        self.FormTemplateGeneration[form] = self.TemplateGeneration
    end
end

function Loader:QueueHotReloadUIRefresh(onComplete)
    local generation = self.TemplateGeneration or 0
    local attempts = 0
    local formCount = #self:GetTrackedForms()
    self:LogReload(string.format("UI refresh queued for %d Auto Assembler window(s).", formCount))

    local created, timer = pcall(createTimer)
    if not created or not timer then
        self:LogReload("Could not schedule UI refresh: " .. tostring(timer), true)
        return false, timer
    end
    timer.Interval = 75
    timer.OnTimer = function()
        local refreshOk, refreshErr = pcall(function()
            if self.TemplateGeneration ~= generation then
                timer.destroy()
                return
            end
            attempts = attempts + 1
            if attempts == 1 then
                self:LogReload("Rebuilding Template Loader settings menu.")
                self:RebuildOptionsMenus()
            end

            local rebuilt = 0
            for _, form in ipairs(self:GetTrackedForms()) do
                local root = ui:FindMenuItem(form, "emplate1")
                if root then
                    local ok, err = self:BuildMenu(root, form)
                    if ok then
                        rebuilt = rebuilt + 1
                    else
                        log:Warning("[Loader] Menu rebuild failed: " .. tostring(err))
                    end
                end
            end
            self:LogReload(string.format("Template menu categorization pass %d/4 completed for %d window(s).", attempts, rebuilt))

            -- CE adds registered template items asynchronously. A few short passes
            -- make the menu rebuild deterministic without touching user windows.
            if attempts >= 4 then
                timer.destroy()
                self:LogReload("Hot reload UI refresh completed.")
                if type(onComplete) == "function" then pcall(onComplete) end
            end
        end)
        if not refreshOk then
            pcall(function() timer.destroy() end)
            self:LogReload("UI refresh failed: " .. tostring(refreshErr), true)
        end
    end
    return true
end

function Loader:ScheduleTemplateMenuRebuild()
    self:QueueHotReloadUIRefresh()
end

-- Configuration -------------------------------------------------------------

function Loader:LoadConfig()
    local loaded = nil
    if file:Exists(self.ConfigPath) then
        local source, readErr = file:ReadFile(self.ConfigPath)
        if not source then
            log:Error("[Loader] Could not read configuration: " .. tostring(readErr))
        else
            local ok, decoded = pcall(function() return json:decode(source) end)
            if ok and type(decoded) == "table" then
                loaded = decoded
            else
                log:Error("[Loader] Configuration is invalid; defaults are used without overwriting the file.")
            end
        end
    end

    self.Config = mergeKnown(self.DefaultConfig, loaded)
    self:ApplyConfig()

    if not loaded and not file:Exists(self.ConfigPath) then
        self:SaveConfig()
    end
    return self.Config
end

function Loader:SaveConfig()
    local ok, encoded = pcall(function() return json:encode_pretty(self.Config) end)
    if not ok then
        log:Error("[Loader] Failed to encode configuration: " .. tostring(encoded))
        return false
    end
    local saved, err = file:WriteFile(self.ConfigPath, encoded)
    if not saved then
        log:Error("[Loader] Failed to save configuration: " .. tostring(err))
        return false
    end
    return true
end

function Loader:CreateConfig()
    self.Config = deepCopy(self.DefaultConfig)
    self:ApplyConfig()
    return self:SaveConfig()
end

function Loader:ResetConfig()
    self.Config = deepCopy(self.DefaultConfig)
    self:ApplyConfig()
    if self:SaveConfig() then
        log:ForceInfo("[Loader] Configuration reset to defaults.")
    end
end

function Loader:ApplyConfig()
    local logger = self.Config.Logger
    local level = type(logger.Level) == "string" and logger.Level:upper() or "ERROR"
    logger.Level = log.LogLevel[level] and level or "ERROR"
    logger.LogToFile = logger.LogToFile == true
    log:SetLogLevel(log.LogLevel[logger.Level])
    log.LogToFile = logger.LogToFile

    local injection = self.Config.InjectionInfo
    if not memory:SetInjInfoLineCount(injection.LineCount) then injection.LineCount = self.DefaultConfig.InjectionInfo.LineCount end
    injection.RemoveSpaces = injection.RemoveSpaces == true
    injection.AddTabs = injection.AddTabs == true
    if not memory:SetInjInfoRemoveSpaces(injection.RemoveSpaces) then injection.RemoveSpaces = true end
    if not memory:SetInjInfoAddTabs(injection.AddTabs) then injection.AddTabs = true end
    if not memory:SetAppendToHookName(injection.AppendToHookName) then injection.AppendToHookName = "Hook" end

    local options = self.Config.Memory
    options.AskForHookName = options.AskForHookName == true
    options.AskForInjectionAddress = options.AskForInjectionAddress == true
    options.AllocationNear = options.AllocationNear == true
    if not memory:SetAskForHookName(options.AskForHookName) then options.AskForHookName = true end
    if not memory:SetAskForInjectionAddress(options.AskForInjectionAddress) then options.AskForInjectionAddress = false end
    if not memory:SetAllocationNear(options.AllocationNear) then options.AllocationNear = true end
    if not memory:SetAllocationSize(options.AllocationSize) then options.AllocationSize = "$1000" end
    options.AllocationSize = memory.AllocationSize
    if not memory:SetDefaultHookName(options.DefaultHookName) then options.DefaultHookName = "Injection" end
end

-- Template discovery and registration --------------------------------------

function Loader:DiscoverTemplates()
    self.TemplateDefinitions = manager:DiscoverTemplates()
    return self.TemplateDefinitions
end

function Loader:GetTemplateDefinitions()
    return self.TemplateDefinitions or {}
end

function Loader:CreateRegistrationPlan(definitions)
    local shortcuts, captions, plan = {}, {}, {}
    for _, template in ipairs(definitions or {}) do
        local settings = template.settings or {}
        local caption = settings.Caption
        if type(caption) ~= "string" or caption == "" then
            return nil, "Template '" .. tostring(template.fileName) .. "' has no caption"
        end
        if captions[caption] then return nil, "Duplicate template caption: " .. caption end
        captions[caption] = true

        local shortcut = settings.Shortcut or ""
        if shortcut ~= "" then
            if shortcuts[shortcut] then
                log:Warning(string.format("[Loader] Shortcut '%s' for '%s' conflicts with '%s' and was disabled.",
                    shortcut, caption, shortcuts[shortcut]))
                shortcut = ""
            else
                shortcuts[shortcut] = caption
            end
        end
        plan[#plan + 1] = { template = template, caption = caption, shortcut = shortcut }
    end
    return plan
end

function Loader:RegisterTemplate(planEntry)
    local template = planEntry.template
    local callback = function(script, sender)
        self:GetTemplateScript(template, script, sender)
    end
    local ok, id = pcall(registerAutoAssemblerTemplate, planEntry.caption, callback, planEntry.shortcut)
    if not ok or not id then
        return nil, "Cheat Engine could not register '" .. planEntry.caption .. "': " .. tostring(id)
    end
    self:LogReload(string.format("Registered template '%s' (id=%s, shortcut=%s).",
        planEntry.caption, tostring(id), planEntry.shortcut ~= "" and planEntry.shortcut or "<none>"))
    return { id = id, caption = planEntry.caption, shortcut = planEntry.shortcut, template = template }
end

function Loader:LoadTemplates(definitions)
    if definitions == nil and #self.RegisteredTemplates > 0 then
        return true
    end
    definitions = definitions or self.TemplateDefinitions
    local plan, planErr = self:CreateRegistrationPlan(definitions)
    if not plan then return false, planErr end
    self:LogReload(string.format("Registering %d template callback(s).", #plan))

    local active, byCaption = {}, {}
    for _, entry in ipairs(plan) do
        local registered, err = self:RegisterTemplate(entry)
        if not registered then
            for _, previous in ipairs(active) do pcall(unregisterAutoAssemblerTemplate, previous.id) end
            return false, err
        end
        active[#active + 1] = registered
        byCaption[registered.caption] = registered
    end
    self.RegisteredTemplates = active
    self.RegisteredByCaption = byCaption
    log:Info(string.format("[Loader] Registered %d template(s).", #active))
    self:LogReload(string.format("Template registration completed: %d/%d callback(s) active.", #active, #plan))
    return true
end

function Loader:UnloadTemplates()
    self:LogReload(string.format("Unregistering %d active template callback(s).", #(self.RegisteredTemplates or {})))
    for _, entry in ipairs(self.RegisteredTemplates or {}) do
        if entry.id then
            local ok, err = pcall(unregisterAutoAssemblerTemplate, entry.id)
            if not ok then
                self:LogReload("Failed to unregister '" .. entry.caption .. "': " .. tostring(err), true)
            else
                self:LogReload("Unregistered template '" .. entry.caption .. "' (id=" .. tostring(entry.id) .. ").")
            end
        end
    end
    self.RegisteredTemplates = {}
    self.RegisteredByCaption = {}
end

function Loader:RemoveOldMenuEntries(rootMenu)
    if not rootMenu then return end
    ui:RemoveManagedItems(rootMenu)

    -- registerAutoAssemblerTemplate creates plain root entries only. They have
    -- no ownership marker, so this caption-based cleanup is the necessary
    -- custom bridge before the next registration pass.
    local captions = {}
    for _, template in ipairs(self:GetTemplateDefinitions()) do
        captions[template.settings.Caption] = true
    end
    for index = rootMenu.Count - 1, 0, -1 do
        local item = rootMenu:getItem(index)
        if item and captions[item.Caption] then rootMenu:delete(index) end
    end
end

function Loader:BuildMenu(rootMenu, form)
    if not rootMenu then return false, "Template root menu not found" end
    local indices = form and self:GetMenuIndices(form) or { Template = -1, Inject = -1 }
    local beforeCount = tonumber(rootMenu.Count) or 0
    self:LogReload(string.format("Categorizing template menu (root items=%d, definitions=%d).",
        beforeCount, #self:GetTemplateDefinitions()))
    local ok, result = ui:CategorizeMenuItems(self, rootMenu, indices)
    if ok then
        self:LogReload(string.format("Template menu categorization completed (root items=%d -> %d).",
            beforeCount, tonumber(rootMenu.Count) or 0))
    else
        self:LogReload("Template menu categorization failed: " .. tostring(result), true)
    end
    return ok, result
end

function Loader:GetTrackedForms()
    local forms, unique = {}, {}
    local function add(form)
        local key = isAliveAutoInjectForm(form) and getAutoInjectFormKey(form) or nil
        if key and not unique[key] then
            forms[#forms + 1] = form
            unique[key] = true
        end
    end
    for _, form in ipairs(self.AutoInjectForms) do
        add(form)
    end
    for index = 0, getFormCount() - 1 do
        add(getForm(index))
    end
    self.AutoInjectForms = forms
    self.FormIndices = setmetatable({}, { __mode = "k" })
    for _, form in ipairs(forms) do self.FormIndices[form] = true end
    return forms
end

function Loader:DestroyAutoInjectForms()
    local forms = self:GetTrackedForms()
    self:LogReload(string.format("Closing %d tracked Auto Assembler window(s) before reload.", #forms))

    local closed = 0
    for _, form in ipairs(forms) do
        local ok, err = pcall(function()
            -- Close lets Cheat Engine tear down the form and its menu items in
            -- the normal lifecycle.  Calling destroy directly can leave CE
            -- with stale menu references while template callbacks are swapped.
            form:Close()
        end)
        if ok then
            closed = closed + 1
        else
            self:LogReload("Failed to close Auto Assembler form: " .. tostring(err), true)
        end
    end

    self.AutoInjectForms = {}
    self.AutoInjectForm = nil
    self.FormIndices = setmetatable({}, { __mode = "k" })
    self.FormTemplateGeneration = setmetatable({}, { __mode = "k" })
    self:LogReload(string.format("Closed %d/%d Auto Assembler window(s).", closed, #forms))
    return closed, #forms
end

function Loader:CleanupTemplateMenus()
    for _, form in ipairs(self:GetTrackedForms()) do
        local root = ui:FindMenuItem(form, "emplate1")
        if root then self:RemoveOldMenuEntries(root) end
    end
end

function Loader:RebuildTemplateMenus()
    for _, form in ipairs(self:GetTrackedForms()) do
        local root = ui:FindMenuItem(form, "emplate1")
        if root then
            local ok, err = self:BuildMenu(root, form)
            if not ok then log:Warning("[Loader] Menu rebuild failed: " .. tostring(err)) end
        end
    end
end

function Loader:RefreshTemplates()
    self.TemplateGeneration = self.TemplateGeneration or 0
    self:LogReload("Template registry reload started.")
    local previousDefinitions = self.TemplateDefinitions
    local newDefinitions = manager:DiscoverTemplates()
    if #newDefinitions == 0 then
        log:Warning("[Loader] Reload canceled: no valid templates were found. Existing templates remain active.")
        return false, "No valid templates found"
    end
    local plan, planErr = self:CreateRegistrationPlan(newDefinitions)
    if not plan then
        return false, planErr
    end
    self:LogReload(string.format("Discovered and validated %d template(s).", #plan))

    self:LogReload("Unregistering current template callbacks.")
    self:UnloadTemplates()
    self.TemplateDefinitions = newDefinitions
    self:LogReload("Registering updated template callbacks.")
    local loaded, loadErr = self:LoadTemplates(newDefinitions)
    if not loaded then
        log:Error("[Loader] New template registration failed; restoring the previous set: " .. tostring(loadErr))
        self.TemplateDefinitions = previousDefinitions
        local restored, restoreErr = self:LoadTemplates(previousDefinitions)
        return false, restored and loadErr or (loadErr .. " | rollback failed: " .. tostring(restoreErr))
    end

    self.TemplateGeneration = self.TemplateGeneration + 1
    self:LogReload(string.format(
        "Reloaded %d template(s) globally (generation %d). Open a new Auto Assembler window to use the updated template menu.",
        #newDefinitions, self.TemplateGeneration))
    return true
end

function Loader:ReloadTemplates()
    if self.ReloadInProgress then
        log:Warning("[Loader] Template reload request ignored because another reload is still running.")
        return false
    end

    self.ReloadInProgress = true
    local callOk, ok, err = pcall(function() return self:RefreshTemplates() end)
    self.ReloadInProgress = false

    if not callOk then
        log:ForceError("[Loader] Template reload aborted by an internal error: " .. tostring(ok))
        return false
    end
    if not ok then log:ForceWarning("[Loader] Template reload failed: " .. tostring(err)) end
    return ok
end

-- Parsing and compilation ---------------------------------------------------

function Loader:GetMemoryOverrides(settings)
    settings = settings or {}
    local overrides = {}
    for _, key in ipairs({ "AskForHookName", "AskForInjectionAddress", "AppendToHookName", "AllocationSize", "AllocationNear", "DefaultHookName" }) do
        if settings[key] ~= nil then overrides[key] = settings[key] end
    end
    return overrides
end

function Loader:GetEnvironment(template)
    local environment, err = memory:GetMemoryInfo(self:GetMemoryOverrides(template and template.settings))
    if not environment then return nil, err end
    environment.TemplateSettings = template and template.settings or {}
    environment.FinalCompilation = false
    environment._safe = function(value) return value == nil and "" or tostring(value) end
    setmetatable(environment, { __index = _G }) -- keeps existing advanced templates compatible
    return environment
end

function Loader:CompileFile(path, environment)
    path = manager:NormalizePath(path)
    if not path or not file:Exists(path) then return nil, "Template file was not found: " .. tostring(path) end
    local source, err = file:ReadFile(path)
    if not source then return nil, err end
    if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
    return self:Compile(source, environment, path)
end

function Loader:AppendLiteral(builder, text)
    if text ~= "" then builder[#builder + 1] = string.format("_ret[#_ret + 1] = %q", text) end
end

function Loader:Compile(template, environment, sourceName)
    if type(template) ~= "string" then return nil, "Template source must be a string" end
    local builder, position, length = { "local _ret = {}", "local _safe = _safe or function(v) return v == nil and '' or tostring(v) end" }, 1, #template

    while position <= length do
        local expressionStart = template:find("<<", position, true)
        local codeStart = template:find("<%", position, true)
        local start = expressionStart
        if codeStart and (not start or codeStart < start) then start = codeStart end
        if not start then
            self:AppendLiteral(builder, template:sub(position))
            break
        end

        self:AppendLiteral(builder, template:sub(position, start - 1))
        local tag = template:sub(start, start + 1)
        local closeTag = tag == "<<" and ">>" or "%>"
        local contentStart = start + 2
        local closeStart = template:find(closeTag, contentStart, true)
        if not closeStart then
            local before = template:sub(1, start)
            local line = select(2, before:gsub("\n", "")) + 1
            return nil, string.format("Unclosed %s block at line %d", tag, line)
        end

        local content = template:sub(contentStart, closeStart - 1)
        if tag == "<<" then
            content = content:match("^%s*(.-)%s*$")
            if content == "" then return nil, "Empty expression block" end
            builder[#builder + 1] = "_ret[#_ret + 1] = _safe((" .. content .. "))"
        else
            builder[#builder + 1] = content
        end
        position = closeStart + 2
    end

    builder[#builder + 1] = "return table.concat(_ret)"
    local chunk, compileErr = load(table.concat(builder, "\n"), "@" .. (sourceName or "template"), "t", environment)
    if not chunk then return nil, "Template syntax error: " .. tostring(compileErr) end
    local ok, result = pcall(chunk)
    if not ok then return nil, "Template execution error: " .. tostring(result) end
    if type(result) ~= "string" then return nil, "Template did not produce text" end
    return result
end

function Loader:CompileHeaderTemplate(environment)
    local path = manager:NormalizePath(manager:GetTemplateFolder() .. sep .. "Header" .. manager:GetScriptExtension())
    if not file:Exists(path) then
        log:Warning("[Loader] Header template not found; generation continues without it.")
        return ""
    end
    return self:CompileFile(path, environment)
end

function Loader:ApplyCompiledTemplate(text, script)
    if type(text) ~= "string" then return false, "Compiled template is not text" end
    if not script then return false, "Auto Assembler editor is unavailable" end

    local ok, err = pcall(function()
        if type(script.addText) == "function" then
            script.addText(text)
        else
            local current = script.getText()
            script.clear()
            script.setText((current or "") .. text)
        end
    end)
    return ok, err
end

function Loader:ReportTemplateError(template, message)
    local label = template and template.settings and template.settings.Caption or "Template"
    local text = string.format("%s could not be generated.\n\n%s\n\nSee the Template Loader log for details.", label, tostring(message))
    log:Error("[Loader] " .. text)
    if type(messageDialog) == "function" then pcall(messageDialog, text, mtError, mbOK) end
end

function Loader:GetTemplateScript(template, script)
    local environment, environmentErr = self:GetEnvironment(template)
    if not environment then self:ReportTemplateError(template, environmentErr); return false end

    local header, headerErr = self:CompileHeaderTemplate(environment)
    if not header then self:ReportTemplateError(template, headerErr); return false end
    environment.Header = header

    local compiled, compileErr = self:CompileFile(template.scriptPath, environment)
    if not compiled then self:ReportTemplateError(template, compileErr); return false end

    local applied, applyErr = self:ApplyCompiledTemplate(compiled, script)
    if not applied then self:ReportTemplateError(template, applyErr); return false end
    return true
end

-- Menu lifecycle ------------------------------------------------------------

function Loader:GetMenuIndices(form)
    if self.FormIndices[form] then return self.FormIndices[form] end
    local imageList = form and form.aaImageList
    local memoryView = type(getMemoryViewForm) == "function" and getMemoryViewForm() or nil
    local indices = {
        Eye = safeMenuImage(imageList, memoryView and memoryView.Watchmemoryallocations1 and memoryView.Watchmemoryallocations1.Bitmap),
        Template = safeMenuImage(imageList, memoryView and memoryView.AutoInject1 and memoryView.AutoInject1.Bitmap),
        Toggle = safeMenuImage(imageList, memoryView and memoryView.CreateThread1 and memoryView.CreateThread1.Bitmap),
        Log = safeMenuImage(imageList, memoryView and memoryView.miDebugSetAddress and memoryView.miDebugSetAddress.Bitmap),
        Inject = safeMenuImage(imageList, memoryView and memoryView.InjectDLL1 and memoryView.InjectDLL1.Bitmap),
        Level = safeMenuImage(imageList, memoryView and memoryView.MenuItem14 and memoryView.MenuItem14.Bitmap)
    }
    self.FormIndices[form] = indices
    return indices
end

function Loader:BuildUICallbacks()
    local config = self.Config
    return {
        memory = memory,
        onLevelChange = function(level, sender)
            if not log.LogLevel[level] then return end
            config.Logger.Level = level
            log:SetLogLevel(log.LogLevel[level])
            if sender and sender.Parent then
                for index = 0, sender.Parent.Count - 1 do
                    local item = sender.Parent:getItem(index)
                    item.Checked = item.Caption == level
                end
            end
            self:SaveConfig()
        end,
        onLogToFile = function(sender)
            config.Logger.LogToFile = not config.Logger.LogToFile
            log.LogToFile = config.Logger.LogToFile
            if sender then sender.Checked = config.Logger.LogToFile end
            self:SaveConfig()
        end,
        onViewLog = function()
            if file:Exists(log.LogFileName) then shellExecute(log.LogFileName) end
        end,
        onOpenFolder = function()
            local folder = manager:GetTemplateFolder()
            if file:FolderExists(folder) then shellExecute(folder) end
        end,
        onSetLineCount = function()
            local value = inputQuery("Injection information", "Number of surrounding instructions:", tostring(config.InjectionInfo.LineCount))
            local number = tonumber(value)
            if number and memory:SetInjInfoLineCount(number) then
                config.InjectionInfo.LineCount = number
                self:SaveConfig()
            end
        end,
        onSetAppend = function()
            local value = inputQuery("Hook-name suffix", "Suffix added to generated hook symbols (empty is allowed):", config.InjectionInfo.AppendToHookName)
            if value ~= nil and memory:SetAppendToHookName(value) then
                config.InjectionInfo.AppendToHookName = memory.AppendToHookName
                self:SaveConfig()
            end
        end,
        onSetAllocationSize = function()
            local value = inputQuery("Allocation size", "Positive decimal or $HEX size:", config.Memory.AllocationSize)
            if value ~= nil and memory:SetAllocationSize(value) then
                config.Memory.AllocationSize = memory.AllocationSize
                self:SaveConfig()
            end
        end,
        onSetDefaultHookName = function()
            local value = inputQuery("Default hook name", "Used when asking for a hook name is disabled:", config.Memory.DefaultHookName)
            if value ~= nil and memory:SetDefaultHookName(value) then
                config.Memory.DefaultHookName = memory.DefaultHookName
                self:SaveConfig()
            end
        end,
        onToggle = function(section, key, setter)
            return function(sender)
                local value = not (config[section][key] == true)
                if setter(value) then
                    config[section][key] = value
                    if sender then sender.Checked = value end
                    self:SaveConfig()
                end
            end
        end,
        onReloadTemplates = function() self:ReloadTemplates() end,
        onReloadDependencies = function()
            local host = _G.ManifoldTemplateLoaderHost
            if host and host.Loader == self and type(host.HotReload) == "function" then
                host:HotReload()
            else
                self:ReloadDependencies()
            end
        end,
        onResetConfig = function()
            if messageDialog("Reset Template Loader configuration?", mtConfirmation, mbYes, mbNo) == mrYes then
                self:ResetConfig()
                self:RebuildOptionsMenus()
            end
        end
    }
end

function Loader:RebuildOptionsMenu(form)
    if not form or not form.MainMenu1 then return end
    ui:RemoveManagedItems(form.MainMenu1)
    ui:BuildTree(form.MainMenu1, ui:GetMainMenuTree(self.Config, self:GetMenuIndices(form), self:BuildUICallbacks()))
end

function Loader:RebuildOptionsMenus()
    for _, form in ipairs(self:GetTrackedForms()) do self:RebuildOptionsMenu(form) end
end

function Loader:SetupMenu(form)
    if not isAliveAutoInjectForm(form) then return end
    local root = ui:FindMenuItem(form, "emplate1")
    local generation = self.TemplateGeneration or 0
    local formGeneration = self.FormTemplateGeneration and self.FormTemplateGeneration[form]
    self:LogReload(string.format("Setup timer fired for %s (generation=%s, current=%s, template root=%s).",
        getAutoInjectFormKey(form), tostring(formGeneration), tostring(generation), root and "found" or "missing"))
    if root and formGeneration == generation then
        ui:AddSeparatorAfter(root, "CheatTablecompliantcodee1")
        local built, buildErr = self:BuildMenu(root, form)
        if not built then self:LogReload("Menu setup skipped: " .. tostring(buildErr), true) end
    elseif root then
        self:LogReload("Menu setup skipped because the form belongs to an older template generation.")
    end
    self:RebuildOptionsMenu(form)
    pcall(function()
        form.Assemblescreen.ScrollBars = "ssAutoBoth"
        form.Assemblescreen.RightEdge = -1
        form.Panel2.BorderStyle = "bsNone"
    end)
end

function Loader:TrackAutoInjectForm(form)
    if not isAliveAutoInjectForm(form) then return end
    local formKey = getAutoInjectFormKey(form)
    self.AutoInjectForms[#self.AutoInjectForms + 1] = form
    self.AutoInjectForm = form
    self.FormTemplateGeneration = self.FormTemplateGeneration or setmetatable({}, { __mode = "k" })
    self.TemplateGeneration = self.TemplateGeneration or 0
    self.FormTemplateGeneration[form] = self.TemplateGeneration
    self:LogReload(string.format("Tracking Auto Assembler form %s (tracked=%d, generation=%d); scheduling setup.",
        formKey, #self.AutoInjectForms, self.TemplateGeneration))
    createTimer(50, function()
        local ok, err = pcall(function() self:SetupMenu(form) end)
        if not ok then self:LogReload("Auto Assembler setup failed for " .. formKey .. ": " .. tostring(err), true) end
    end)
end

function Loader:AttachMenuToForm()
    local host = _G.ManifoldTemplateLoaderHost
    if host and type(host.Attach) == "function" then
        host:Attach(self)
        return
    end
    if self.FormNotificationRegistered then return end
    self.FormNotificationRegistered = true
    registerFormAddNotification(function(form) self:TrackAutoInjectForm(form) end)
    for index = 0, getFormCount() - 1 do self:TrackAutoInjectForm(getForm(index)) end
    log:Info("[Loader] Attached Template Loader menu to Auto Assembler forms.")
end

-- Dependency reload ---------------------------------------------------------

function Loader:ReloadDependencies()
    local host = _G.ManifoldTemplateLoaderHost
    if host and host.Loader == self and type(host.HotReload) == "function" then
        return host:HotReload()
    end
    if self.DependencyReloadInProgress or self.ReloadInProgress then
        log:Warning("[Loader] A reload is already in progress.")
        return false
    end
    self.DependencyReloadInProgress = true

    local callOk, ok, err = pcall(function()
        local names = {
            "Manifold-TemplateLoader-Log",
            "Manifold-TemplateLoader-Json",
            "Manifold-TemplateLoader-File",
            "Manifold-TemplateLoader-Memory",
            "Manifold-TemplateLoader-Manager",
            "Manifold-TemplateLoader-UI"
        }
        local oldCache, loaded = {}, {}
        for _, name in ipairs(names) do
            oldCache[name] = package.loaded[name]
            package.loaded[name] = nil
        end

        for _, name in ipairs(names) do
            local required, module = pcall(require, name)
            if not required then
                for _, restoreName in ipairs(names) do package.loaded[restoreName] = oldCache[restoreName] end
                return false, "Module reload was rolled back: " .. tostring(module)
            end
            loaded[name] = module
        end

        -- Commit only after every dependency was loaded successfully.
        Log, JSON, File, Memory, Manager, UI = loaded[names[1]], loaded[names[2]], loaded[names[3]], loaded[names[4]], loaded[names[5]], loaded[names[6]]
        log, json, file, memory, manager, ui = Log:New(), JSON:new(), File:New(), Memory:New(), Manager:New(), UI:New()
        self.FormIndices = setmetatable({}, { __mode = "k" })
        self:LoadConfig()
        if not self:ReloadTemplates() then return false, "Template registration failed after module reload" end
        self:QueueHotReloadUIRefresh()
        return true
    end)

    self.DependencyReloadInProgress = false
    if not callOk then
        log:ForceError("[Loader] Module reload aborted by an internal error: " .. tostring(ok))
        return false
    end
    if not ok then
        log:ForceError("[Loader] " .. tostring(err))
        return false
    end
    log:ForceInfo("[Loader] Modules and templates were reloaded safely for new Auto Assembler windows.")
    return true
end

return Loader
