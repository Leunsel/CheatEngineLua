--[[
    Runtime: the service container for one loader generation.

    One Runtime instance owns every service (Config, Log, Engine, registries,
    Generator, UI) and all resources created for its generation (menu items,
    timers, viewer forms, template registrations). Ownership is explicit: a
    full reload builds a fresh Runtime as a candidate, validates it, and only
    then does the Host swap it in and tell the old one to release everything.

    This module also carries the 2.x compatibility surface. The public
    globals point here, and methods like LoadTemplates / ReloadTemplates /
    GetTemplateScript keep their old names and semantics.
]]

local Version = require("Manifold-TemplateLoader-Version")
local Errors = require("Manifold-TemplateLoader-Errors")
local LogClass = require("Manifold-TemplateLoader-Log")
local JsonClass = require("Manifold-TemplateLoader-Json")
local FileClass = require("Manifold-TemplateLoader-File")
local CEClass = require("Manifold-TemplateLoader-CE")
local ConfigClass = require("Manifold-TemplateLoader-Config")
local EngineClass = require("Manifold-TemplateLoader-Engine")
local ContextModule = require("Manifold-TemplateLoader-Context")
local InputsClass = require("Manifold-TemplateLoader-Inputs")
local RegistryClass = require("Manifold-TemplateLoader-Registry")
local ExtensionsClass = require("Manifold-TemplateLoader-Extensions")
local GeneratorClass = require("Manifold-TemplateLoader-Generator")
local ThemeClass = require("Manifold-TemplateLoader-Theme")
local UIClass = require("Manifold-TemplateLoader-UI")
local DiagnosticsClass = require("Manifold-TemplateLoader-Diagnostics")

local PROVIDER_MODULES = {
    "Manifold-TemplateLoader-Provider-Runtime",
    "Manifold-TemplateLoader-Provider-Process",
    "Manifold-TemplateLoader-Provider-Instruction",
    "Manifold-TemplateLoader-Provider-Hook",
    "Manifold-TemplateLoader-Provider-Framework"
}

local Runtime = {}
Runtime.__index = Runtime

-- Paths ----------------------------------------------------------------------

local sep = package.config:sub(1, 1)

local function safeGetEnv(name)
    local ok, value = pcall(os.getenv, name)
    return ok and type(value) == "string" and value ~= "" and value or nil
end

local function joinPath(...)
    local parts = {}
    for index = 1, select("#", ...) do
        local part = select(index, ...)
        if type(part) == "string" and part ~= "" then
            part = part:gsub("[/\\]+$", "")
            if #parts > 0 then part = part:gsub("^[/\\]+", "") end
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, sep)
end

local function buildPaths()
    local dataRoot = safeGetEnv("LOCALAPPDATA")
    if not dataRoot then
        local userProfile = safeGetEnv("USERPROFILE")
        dataRoot = userProfile and joinPath(userProfile, "AppData", "Local") or getAutorunPath()
    end
    local configDir = joinPath(dataRoot, "Manifold", "TemplateLoader")
    local logDir = joinPath(configDir, "Logs")
    return {
        ConfigDir = configDir,
        ConfigPath = joinPath(configDir, "Manifold-TemplateLoader-Config.json"),
        LegacyConfigPath = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "Manifold-TemplateLoader-Config.json",
        LogDir = logDir,
        LogFile = joinPath(logDir, "Manifold-TemplateLoader-Log.txt"),
        TemplateFolder = getAutorunPath() .. "Manifold-TemplateLoader-Templates"
    }
end

-- Construction ---------------------------------------------------------------

function Runtime:New()
    local paths = buildPaths()
    local instance = setmetatable({
        Paths = paths,
        Version = Version,
        State = "Idle",
        LastReloadStatus = nil,
        LastGenerationError = nil,
        TemplateGeneration = 0,
        RegisteredTemplates = {},
        RegisteredByCaption = {},
        FormState = {},          -- handleKey -> { Generation, Indices }
        ReloadInProgress = false,
        ProviderReloadInProgress = false,
        FormNotificationRegistered = false,
        ExtensionDefinitions = {}
    }, Runtime)
    instance.File = FileClass:New()
    instance.CE = CEClass:New()
    instance.Log = LogClass:New{ LogFileName = paths.LogFile }
    instance.Json = JsonClass:new()
    instance.Config = ConfigClass:New{
        File = instance.File, Json = instance.Json, Log = instance.Log, Paths = paths
    }
    instance.Config:Load()
    instance:ApplyConfig()
    instance.Engine = EngineClass:New{
        File = instance.File, Log = instance.Log,
        TemplateFolder = paths.TemplateFolder
    }
    instance.Theme = ThemeClass:New{ Log = instance.Log, CE = instance.CE }
    instance.Inputs = InputsClass:New{ CE = instance.CE, Log = instance.Log, Theme = instance.Theme }
    instance.TemplateRegistry = RegistryClass:New{
        File = instance.File, Log = instance.Log, Inputs = instance.Inputs, Paths = paths
    }
    instance:_BuildContextServices()
    instance.UI = UIClass:New{ Log = instance.Log, CE = instance.CE, Paths = paths, Theme = instance.Theme }
    instance.Diagnostics = DiagnosticsClass:New{
        CE = instance.CE, Log = instance.Log, Version = Version, Paths = paths
    }
    instance.Generator.UI = instance.UI
    instance.Generator.OnGenerated = function(template) instance:NoteRecent(template) end
    instance.TemplateRegistry:Adopt(instance.TemplateRegistry:Discover())
    return instance
end

--
--- Builds the context registry, registers the built-in providers and
--- rebuilds the services that hold a reference to it. Also used by the
--- provider reload, which is why it is separate from New.
--
function Runtime:_BuildContextServices()
    local registry = ContextModule.Registry:New{ Log = self.Log }
    local services = {
        CE = self.CE, Log = self.Log, Config = self.Config,
        Version = Version, Engine = self.Engine, File = self.File,
        Paths = self.Paths
    }
    for _, moduleName in ipairs(PROVIDER_MODULES) do
        local provider = require(moduleName)
        local ok, err = provider.Register(registry, services)
        if not ok then
            error("Provider '" .. tostring(provider.Name) .. "' failed to register: " .. tostring(err))
        end
    end
    local valid, issues = registry:Validate()
    if not valid then
        error("Context registry validation failed: " .. table.concat(issues, "; "))
    end
    local extensions = ExtensionsClass:New{ Log = self.Log, ContextRegistry = registry }
    -- The framework publishes each module under its declared global (see
    -- Manifold.Bootstrap), which is the only signal available: Cheat Engine
    -- cannot be asked whether an Auto Assembler command is registered.
    extensions:RegisterCapability("Manifold.AssemblerCommands", function()
        return type(rawget(_G, "assemblerCommands")) == "table"
    end)
    extensions:RegisterCapability("Manifold.Trampolines", function()
        return type(rawget(_G, "assemblerCommands")) == "table"
            and type(rawget(_G, "trampolines")) == "table"
    end)
    -- Replay extensions registered by external code so a provider reload
    -- keeps them without the extension author doing anything.
    for _, definition in ipairs(self.ExtensionDefinitions) do
        local ok, err = extensions:Register(definition)
        if not ok then
            self.Log:ForceError("[Runtime] Extension replay failed: " .. tostring(err))
        end
    end
    self.ContextRegistry = registry
    self.Extensions = extensions
    self.Generator = GeneratorClass:New{
        CE = self.CE, Log = self.Log, Config = self.Config,
        Engine = self.Engine, ContextRegistry = registry,
        Extensions = extensions, Inputs = self.Inputs, Version = Version
    }
    if self.UI then
        self.Generator.UI = self.UI
        self.Generator.OnGenerated = function(template) self:NoteRecent(template) end
    end
end

--
--- Public extension entry point:
---   ManifoldTemplateLoader:RegisterExtension{ Name = ..., ... }
--- The definition is stored so provider reloads can replay it.
--
function Runtime:RegisterExtension(definition)
    local ok, err = self.Extensions:Register(definition)
    if not ok then return false, err end
    self.ExtensionDefinitions[#self.ExtensionDefinitions + 1] = definition
    return true
end

function Runtime:ApplyConfig()
    local logger = self.Config.Data.Logger
    self.Log:SetLogLevel(logger.Level)
    self.Log.LogToFile = logger.LogToFile == true
    if self.Log.LogToFile then
        self.File:EnsureFolder(self.Paths.LogDir)
    end
end

function Runtime:LogReload(message, isError)
    local prefix = "[Reload] " .. tostring(message)
    if isError then
        self.Log:ForceError(prefix)
    else
        self.Log:Info(prefix)
    end
end

-- Template registration ------------------------------------------------------

function Runtime:GetTemplateDefinitions()
    return self.TemplateRegistry:GetDefinitions()
end

function Runtime:CreateRegistrationPlan(definitions)
    return self.TemplateRegistry:CreateRegistrationPlan(definitions or self:GetTemplateDefinitions())
end

function Runtime:_RegisterTemplate(planEntry)
    local template = planEntry.template
    local runtime = self
    local callback = function(script, sender)
        -- Stale-callback guard. After a full reload this closure may still be
        -- reachable through an old menu. Only the active runtime generates.
        local host = rawget(_G, "ManifoldTemplateLoaderHost")
        if host and host.Loader ~= runtime then
            runtime.Log:Warning("[Runtime] Ignored a template callback from a replaced loader generation.")
            return
        end
        runtime:GetTemplateScript(template, script, sender)
    end
    local ok, id = pcall(registerAutoAssemblerTemplate, planEntry.caption, callback, planEntry.shortcut)
    if not ok or not id then
        return nil, "Cheat Engine could not register '" .. planEntry.caption .. "': " .. tostring(id)
    end
    self:LogReload(string.format("Registered template '%s' (id=%s, shortcut=%s).",
        planEntry.caption, tostring(id), planEntry.shortcut ~= "" and planEntry.shortcut or "<none>"))
    return { id = id, caption = planEntry.caption, shortcut = planEntry.shortcut, template = template }
end

function Runtime:LoadTemplates(definitions)
    if definitions == nil and #self.RegisteredTemplates > 0 then
        return true
    end
    definitions = definitions or self:GetTemplateDefinitions()
    local plan, planErr = self.TemplateRegistry:CreateRegistrationPlan(definitions)
    if not plan then return false, planErr end
    self:LogReload(string.format("Registering %d template callback(s).", #plan))
    local active, byCaption = {}, {}
    for _, entry in ipairs(plan) do
        local registered, err = self:_RegisterTemplate(entry)
        if not registered then
            for _, previous in ipairs(active) do pcall(unregisterAutoAssemblerTemplate, previous.id) end
            return false, err
        end
        active[#active + 1] = registered
        byCaption[registered.caption] = registered
    end
    self.RegisteredTemplates = active
    self.RegisteredByCaption = byCaption
    self.Log:InfoF("[Runtime] Registered %d template(s).", #active)
    return true
end

function Runtime:UnloadTemplates()
    self:LogReload(string.format("Unregistering %d active template callback(s).", #(self.RegisteredTemplates or {})))
    for _, entry in ipairs(self.RegisteredTemplates or {}) do
        if entry.id then
            local ok, err = pcall(unregisterAutoAssemblerTemplate, entry.id)
            if not ok then
                self:LogReload("Failed to unregister '" .. entry.caption .. "': " .. tostring(err), true)
            end
        end
    end
    self.RegisteredTemplates = {}
    self.RegisteredByCaption = {}
end

-- Generation entry points ----------------------------------------------------

--
--- 2.x-compatible entry point. The registered template callback. "sender"
--- is the generating TfrmAutoInject when Cheat Engine provides it.
--
function Runtime:GetTemplateScript(template, script, sender)
    self.State = "Generating"
    local form = self.CE:IsAutoInjectForm(sender) and sender or nil
    -- The pipeline converts its own failures into structured errors, but the
    -- callback boundary still needs a net. A raw error here would otherwise
    -- leave State stuck at "Generating" and surface as a CE Lua exception.
    local callOk, ok, cancelled = pcall(function()
        return self.Generator:Generate(template, script, form)
    end)
    self.State = "Idle"
    if not callOk then
        self.Log:ForceError("[Runtime] Generation crashed: " .. tostring(ok))
        self.LastGenerationError = os.date("%H:%M:%S") .. " " .. tostring(template.settings.Caption) .. " (crash)"
        return false
    end
    if not ok and not cancelled then
        self.LastGenerationError = os.date("%H:%M:%S") .. " " .. tostring(template.settings.Caption)
    end
    return ok
end

--
--- Favorites / Recent click path. No TStrings from CE here, so the target
--- editor is the clicked form's Assemblescreen.
--
function Runtime:GenerateById(id, form)
    local template = self.TemplateRegistry:FindById(id)
    if not template then
        self.Log:ForceWarning("[Runtime] No template with id '" .. tostring(id) .. "' is loaded.")
        return false
    end
    local editor = nil
    if self.CE:IsAutoAssemblerForm(form) then
        local ok, lines = pcall(function() return form.Assemblescreen.Lines end)
        if ok and lines then
            editor = {
                addText = function(text)
                    lines.Text = (lines.Text or "") .. text
                end
            }
        end
    end
    if not editor then
        self.Log:ForceWarning("[Runtime] No Auto Assembler editor available for template '" .. tostring(id) .. "'.")
        return false
    end
    return self:GetTemplateScript(template, editor, form)
end

-- Favorites / Recent ---------------------------------------------------------

function Runtime:GetFavorites() return self.Config.Data.UI.Favorites end
function Runtime:GetRecent() return self.Config.Data.UI.Recent end

function Runtime:ToggleFavorite(id, enabled)
    local favorites = self.Config.Data.UI.Favorites
    for index = #favorites, 1, -1 do
        if favorites[index] == id then table.remove(favorites, index) end
    end
    if enabled then favorites[#favorites + 1] = id end
    self.Config:Save()
end

function Runtime:NoteRecent(template)
    local recent = self.Config.Data.UI.Recent
    for index = #recent, 1, -1 do
        if recent[index] == template.id then table.remove(recent, index) end
    end
    table.insert(recent, 1, template.id)
    while #recent > self.Config.Data.UI.RecentLimit do table.remove(recent) end
    self.Config:Save()
end

-- Reload level 1: templates --------------------------------------------------

--
--- Discover -> parse -> validate -> plan -> commit. The active set is only
--- unregistered after every candidate template compiled and the plan is
--- valid, so a broken template can never take the working set down.
--
function Runtime:RefreshTemplates()
    self.State = "Discovering"
    self:LogReload("Template registry reload started.")
    local previousDefinitions = self:GetTemplateDefinitions()
    local newDefinitions = self.TemplateRegistry:Discover()
    if #newDefinitions == 0 then
        self.Log:ForceWarning("[Runtime] Reload canceled: no valid templates were found. Existing templates remain active.")
        return false, "No valid templates found"
    end
    self.State = "Validating"
    for _, template in ipairs(newDefinitions) do
        local compiled, err = self.Engine:GetCompiledFile(template.scriptPath)
        if not compiled then
            return false, string.format("'%s' failed validation: %s%s",
                template.settings.Caption, tostring(err.Message),
                err.Line and (" (line " .. err.Line .. ")") or "")
        end
    end
    local plan, planErr = self.TemplateRegistry:CreateRegistrationPlan(newDefinitions)
    if not plan then return false, planErr end
    self:LogReload(string.format("Discovered and validated %d template(s).", #plan))
    self.State = "Committing"
    -- Hand CE's template items back to the template root before
    -- unregistering, otherwise removeTemplate cannot find (and free) them.
    self:FlattenTemplateMenus()
    self:UnloadTemplates()
    self.TemplateRegistry:Adopt(newDefinitions)
    local loaded, loadErr = self:LoadTemplates(newDefinitions)
    if not loaded then
        self.Log:ForceError("[Runtime] New template registration failed, restoring the previous set: " .. tostring(loadErr))
        self.State = "RollingBack"
        self.TemplateRegistry:Adopt(previousDefinitions)
        local restored, restoreErr = self:LoadTemplates(previousDefinitions)
        self:RecategorizeOpenWindows()
        return false, restored and loadErr or (tostring(loadErr) .. " | rollback failed: " .. tostring(restoreErr))
    end
    self.Engine:InvalidateCache()
    self.TemplateGeneration = self.TemplateGeneration + 1
    -- registerAutoAssemblerTemplate appended fresh flat items to every open
    -- window, so those windows are re-categorized here rather than being
    -- left inconsistent until they are reopened.
    self:RecategorizeOpenWindows()
    self:LogReload(string.format("Reloaded %d template(s) (generation %d).",
        #newDefinitions, self.TemplateGeneration))
    return true
end

function Runtime:FlattenTemplateMenus()
    for _, form in ipairs(self:GetTrackedForms()) do
        local root = self.UI:FindMenuItem(form, "emplate1")
        if root then pcall(function() self.UI:FlattenTemplateItems(root) end) end
    end
end

--
--- Rebuilds the template and options menus of every open window against the
--- current registration set, and marks those windows as belonging to the
--- current generation.
--
function Runtime:RecategorizeOpenWindows()
    for _, form in ipairs(self:GetTrackedForms()) do
        local state = self:_FormStateFor(form)
        if state then state.Generation = self.TemplateGeneration end
        local root = self.UI:FindMenuItem(form, "emplate1")
        if root then
            local ok, err = pcall(function() return self:BuildMenu(root, form) end)
            if not ok then self.Log:Warning("[Runtime] Menu rebuild failed: " .. tostring(err)) end
        end
        pcall(function() self:RebuildOptionsMenu(form) end)
    end
end

function Runtime:ReloadTemplates()
    if self.ReloadInProgress then
        self.Log:ForceWarning("[Runtime] Template reload request ignored because another reload is still running.")
        return false
    end
    self.ReloadInProgress = true
    local callOk, ok, err = pcall(function() return self:RefreshTemplates() end)
    self.ReloadInProgress = false
    self.State = "Idle"
    if not callOk then
        self.State = "Failed"
        self.LastReloadStatus = "Template reload crashed: " .. tostring(ok)
        self.Log:ForceError("[Runtime] Template reload aborted by an internal error: " .. tostring(ok))
        return false
    end
    if not ok then
        self.LastReloadStatus = "Template reload failed: " .. tostring(err)
        self.Log:ForceWarning("[Runtime] Template reload failed: " .. tostring(err))
        return false
    end
    self.LastReloadStatus = os.date("%H:%M:%S") .. " Templates reloaded (generation " .. self.TemplateGeneration .. ")"
    return true
end

-- Reload level 2: providers and extensions ------------------------------------

--
--- Rebuilds the context registry from freshly loaded provider modules and
--- replays registered extensions, then reloads templates. The old registry
--- stays active until the candidate validated.
--
function Runtime:ReloadProviders()
    if self.ReloadInProgress or self.ProviderReloadInProgress then
        self.Log:ForceWarning("[Runtime] A reload is already in progress.")
        return false
    end
    self.ProviderReloadInProgress = true
    self.State = "Reloading"
    local previousRegistry = self.ContextRegistry
    local previousExtensions = self.Extensions
    local previousGenerator = self.Generator
    local previousCache = {}
    for _, moduleName in ipairs(PROVIDER_MODULES) do
        previousCache[moduleName] = package.loaded[moduleName]
        package.loaded[moduleName] = nil
    end
    local callOk, err = pcall(function() self:_BuildContextServices() end)
    self.ProviderReloadInProgress = false
    self.State = "Idle"
    if not callOk then
        for _, moduleName in ipairs(PROVIDER_MODULES) do
            package.loaded[moduleName] = previousCache[moduleName]
        end
        self.ContextRegistry = previousRegistry
        self.Extensions = previousExtensions
        self.Generator = previousGenerator
        self.LastReloadStatus = "Provider reload failed: " .. tostring(err)
        self.Log:ForceError("[Runtime] Provider reload failed. The previous providers remain active: " .. tostring(err))
        return false
    end
    self.LastReloadStatus = os.date("%H:%M:%S") .. " Providers and extensions reloaded"
    self.Log:ForceInfo("[Runtime] Providers and extensions reloaded.")
    return self:ReloadTemplates()
end

-- Form tracking ---------------------------------------------------------------
--
-- Identity is the window HANDLE, never the Lua userdata. Cheat Engine frees an
-- Auto Assembler window on close (TfrmAutoInject.FormClose sets caFree) without
-- invalidating the userdata, so a retained reference becomes a dangling pointer
-- that still "reads back" plausible values. Every form object therefore comes
-- fresh from getForm(), and per-window state lives in FormState[handleKey].

function Runtime:_FormKey(form)
    local handle = self.CE:GetFormHandle(form)
    return handle and tostring(handle) or nil
end

function Runtime:_FormStateFor(form)
    local key = self:_FormKey(form)
    if not key then return nil end
    self.FormState[key] = self.FormState[key] or {}
    return self.FormState[key], key
end

--
--- The live Auto Assembler window with this handle, or nil when it is gone.
--- Used by deferred work so a timer never touches a closed window.
--
function Runtime:FindFormByHandle(handle)
    for _, form in ipairs(self.CE:EnumerateAutoAssemblerForms()) do
        if self.CE:GetFormHandle(form) == handle then return form end
    end
    return nil
end

function Runtime:AdoptRuntimeState(previous)
    self.FormState = previous.FormState or {}
    self.TemplateGeneration = previous.TemplateGeneration or 0
    -- Extensions registered against the previous generation are replayed so
    -- they survive a full reload without the extension author doing anything.
    for _, definition in ipairs(previous.ExtensionDefinitions or {}) do
        local ok, err = self:RegisterExtension(definition)
        if not ok then
            self.Log:ForceError("[Runtime] Extension '" .. tostring(definition.Name)
                .. "' failed to re-register after the reload: " .. tostring(err))
        end
    end
end

function Runtime:AdvanceTemplateGeneration()
    self.TemplateGeneration = (self.TemplateGeneration or 0) + 1
    for _, form in ipairs(self:GetTrackedForms()) do
        local state = self:_FormStateFor(form)
        if state then state.Generation = self.TemplateGeneration end
    end
end

--
--- Live Auto Assembler windows. Rebuilt from Cheat Engine's enumeration on
--- every call so closed windows disappear on their own. Per-window state for
--- handles that no longer exist is dropped here too.
--
function Runtime:GetTrackedForms()
    local forms = self.CE:EnumerateAutoAssemblerForms()
    local live = {}
    for _, form in ipairs(forms) do
        local key = self:_FormKey(form)
        if key then live[key] = true end
    end
    for key in pairs(self.FormState) do
        if not live[key] then self.FormState[key] = nil end
    end
    return forms
end

function Runtime:DestroyAutoInjectForms()
    local forms = self:GetTrackedForms()
    self:LogReload(string.format("Closing %d tracked Auto Assembler window(s) before reload.", #forms))
    local closed = 0
    for _, form in ipairs(forms) do
        -- Close lets Cheat Engine tear down the form and its menu items in
        -- the normal lifecycle. Calling destroy directly can leave CE with
        -- stale menu references while template callbacks are swapped.
        local ok, err = pcall(function() form:Close() end)
        if ok then
            closed = closed + 1
        else
            self:LogReload("Failed to close Auto Assembler form: " .. tostring(err), true)
        end
    end
    self.FormState = {}
    return closed, #forms
end

function Runtime:TrackAutoInjectForm(form)
    if not self.CE:IsAutoAssemblerForm(form) then return end
    local handle = self.CE:GetFormHandle(form)
    if not handle then return end
    local state = self:_FormStateFor(form)
    if state then state.Generation = self.TemplateGeneration end
    self.Log:DebugF("[Runtime] Tracking Auto Assembler form %s (generation=%d).",
        tostring(handle), self.TemplateGeneration)
    -- SetupMenu must wait one tick: CE is still adding the registered
    -- template entries to the new window when the notification fires. The
    -- handle, not the form object, is captured, so a window closed in the
    -- meantime is simply not found instead of being dereferenced.
    self.CE:CreateTimer(50, function(timer)
        timer.destroy()
        local live = self:FindFormByHandle(handle)
        if not live then return end
        local ok, err = pcall(function() self:SetupMenu(live) end)
        if not ok then
            self.Log:ForceError("[Runtime] Auto Assembler setup failed for "
                .. tostring(handle) .. ": " .. tostring(err))
        end
    end)
end

-- Menus ----------------------------------------------------------------------

local function safeMenuImage(imageList, bitmap)
    if not imageList or not bitmap then return -1 end
    local ok, index = pcall(function() return imageList.add(bitmap) end)
    return ok and index or -1
end

function Runtime:GetMenuIndices(form)
    local state = self:_FormStateFor(form)
    if state and type(state.Indices) == "table" then return state.Indices end
    local imageList = form and form.aaImageList
    local memoryView = self.CE:Call("getMemoryViewForm")
    local indices = {
        Eye = safeMenuImage(imageList, memoryView and memoryView.Watchmemoryallocations1 and memoryView.Watchmemoryallocations1.Bitmap),
        Template = safeMenuImage(imageList, memoryView and memoryView.AutoInject1 and memoryView.AutoInject1.Bitmap),
        Toggle = safeMenuImage(imageList, memoryView and memoryView.CreateThread1 and memoryView.CreateThread1.Bitmap),
        Log = safeMenuImage(imageList, memoryView and memoryView.miDebugSetAddress and memoryView.miDebugSetAddress.Bitmap),
        Inject = safeMenuImage(imageList, memoryView and memoryView.InjectDLL1 and memoryView.InjectDLL1.Bitmap),
        Level = safeMenuImage(imageList, memoryView and memoryView.MenuItem14 and memoryView.MenuItem14.Bitmap)
    }
    if state then state.Indices = indices end
    return indices
end

function Runtime:BuildMenu(rootMenu, form)
    if not rootMenu then return false, "Template root menu not found" end
    local indices = form and self:GetMenuIndices(form) or { Template = -1, Inject = -1, Eye = -1 }
    local runtime = self
    return self.UI:CategorizeMenuItems(self:GetTemplateDefinitions(), rootMenu, indices, {
        getFavorites = function() return runtime:GetFavorites() end,
        getRecent = function() return runtime:GetRecent() end,
        onGenerateById = function(id) runtime:GenerateById(id, form) end
    })
end

function Runtime:SetupMenu(form)
    if not self.CE:IsAutoAssemblerForm(form) then return end
    local root = self.UI:FindMenuItem(form, "emplate1")
    local generation = self.TemplateGeneration or 0
    local state = self:_FormStateFor(form)
    local formGeneration = state and state.Generation
    if root and formGeneration == generation then
        self.UI:AddSeparatorAfter(root, "CheatTablecompliantcodee1")
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

function Runtime:RebuildOptionsMenu(form)
    if not form or not form.MainMenu1 then return end
    self.UI:RemoveManagedItems(form.MainMenu1)
    self.UI:BuildTree(form.MainMenu1,
        self.UI:GetMainMenuTree(self.Config.Data, self:GetMenuIndices(form), self:BuildUICallbacks()))
end

function Runtime:RebuildOptionsMenus()
    for _, form in ipairs(self:GetTrackedForms()) do self:RebuildOptionsMenu(form) end
end

--
--- Releases everything this runtime owns except the tracked forms (those
--- are adopted by the successor). Called by the Host after a swap.
--
function Runtime:Shutdown()
    self.UI:DestroyOwnedForms()
    pcall(function()
        local icons = self.UI.Icons
        if icons and icons.List then
            icons.List.destroy()
            icons.List, icons.Loaded, icons.Index = nil, false, {}
        end
    end)
    self.Log:ClearListeners()
end

-- 2.x compatibility surface --------------------------------------------------
-- Thin delegates for the loader methods other autorun snippets and table
-- scripts reached through _G.ManifoldTemplateLoader / loader in 2.x.

function Runtime:DiscoverTemplates()
    local definitions = self.TemplateRegistry:Discover()
    self.TemplateRegistry:Adopt(definitions)
    return definitions
end

--
--- 2.x semantics. With a host attached this was a FULL module reload, not a
--- provider-only one.
--
function Runtime:ReloadDependencies()
    local host = rawget(_G, "ManifoldTemplateLoaderHost")
    if host and host.Loader == self and type(host.HotReload) == "function" then
        return host:HotReload()
    end
    return self:ReloadProviders()
end

function Runtime:LoadConfig()
    local data = self.Config:Load()
    self:ApplyConfig()
    return data
end

function Runtime:SaveConfig()
    return self.Config:Save()
end

function Runtime:ResetConfig()
    self.Config:Reset()
    self:ApplyConfig()
end

Runtime.CreateConfig = Runtime.ResetConfig

function Runtime:AttachMenuToForm()
    local host = rawget(_G, "ManifoldTemplateLoaderHost")
    if host and type(host.Attach) == "function" then host:Attach(self) end
end

function Runtime:RebuildTemplateMenus()
    for _, form in ipairs(self:GetTrackedForms()) do
        local root = self.UI:FindMenuItem(form, "emplate1")
        if root then
            local ok, err = self:BuildMenu(root, form)
            if not ok then self.Log:Warning("[Runtime] Menu rebuild failed: " .. tostring(err)) end
        end
    end
end

function Runtime:CleanupTemplateMenus()
    for _, form in ipairs(self:GetTrackedForms()) do
        local root = self.UI:FindMenuItem(form, "emplate1")
        if root then self.UI:RemoveManagedItems(root) end
    end
end

--
--- Deferred menu rebuild. CE adds registered template entries to a window
--- asynchronously, so the rebuild waits one tick and skips windows that
--- belong to a superseded generation.
--
function Runtime:ScheduleTemplateMenuRebuild()
    local generation = self.TemplateGeneration or 0
    self.CE:CreateTimer(75, function(timer)
        timer.destroy()
        if self.TemplateGeneration ~= generation then return end
        pcall(function()
            self:RebuildOptionsMenus()
            self:RebuildTemplateMenus()
        end)
    end)
end

-- UI callbacks ----------------------------------------------------------------

--- Field validators for the toggle callback. Anything not listed is a plain
--- boolean flip.
function Runtime:BuildUICallbacks()
    local runtime = self
    local ce = self.CE
    local config = self.Config

    local function saveAndLog(section, key, value)
        config:Save()
        runtime.Log:DebugF("[Runtime] Saved configuration change: %s.%s=%s", section, key, tostring(value))
    end
    return {
        onLevelChange = function(level, sender)
            if not runtime.Log.LogLevel[level] then return end
            config.Data.Logger.Level = level
            runtime.Log:SetLogLevel(level)
            if sender and sender.Parent then
                for index = 0, sender.Parent.Count - 1 do
                    local item = sender.Parent:getItem(index)
                    item.Checked = item.Caption == level
                end
                pcall(function() sender.Parent.Caption = "Log level (" .. level .. ")" end)
            end
            config:Save()
        end,
        onLogToFile = function(sender)
            config.Data.Logger.LogToFile = not (config.Data.Logger.LogToFile == true)
            runtime.Log.LogToFile = config.Data.Logger.LogToFile
            if runtime.Log.LogToFile then runtime.File:EnsureFolder(runtime.Paths.LogDir) end
            if sender then sender.Checked = config.Data.Logger.LogToFile end
            config:Save()
        end,
        onViewLogs = function() runtime.UI:ShowLogViewer(runtime.Log) end,
        onOpenLogFile = function()
            if runtime.File:Exists(runtime.Paths.LogFile) then ce:ShellExecute(runtime.Paths.LogFile) end
        end,
        onOpenLogFolder = function()
            if runtime.File:FolderExists(runtime.Paths.LogDir) then ce:ShellExecute(runtime.Paths.LogDir) end
        end,
        onSetLineCount = function()
            local value = ce:InputQuery("Injection Information", "Number of surrounding instructions:",
                tostring(config.Data.InjectionInfo.LineCount))
            local number = tonumber(value)
            if number and number > 0 and number == math.floor(number) then
                config.Data.InjectionInfo.LineCount = number
                saveAndLog("InjectionInfo", "LineCount", number)
            end
        end,
        onSetAppend = function()
            local value = ce:InputQuery("Hook-Name Suffix",
                "Suffix added to generated hook symbols (empty is allowed):",
                config.Data.InjectionInfo.AppendToHookName)
            if value ~= nil then
                config.Data.InjectionInfo.AppendToHookName = value:match("^%s*(.-)%s*$")
                saveAndLog("InjectionInfo", "AppendToHookName", value)
            end
        end,
        onSetAllocationSize = function()
            local value = ce:InputQuery("Allocation Size", "Positive decimal or $HEX size:",
                config.Data.Memory.AllocationSize)
            local normalized = value and ConfigClass.NormalizeAllocationSize(value)
            if normalized then
                config.Data.Memory.AllocationSize = normalized
                saveAndLog("Memory", "AllocationSize", normalized)
            elseif value ~= nil then
                runtime.Log:ForceWarning("[Runtime] Allocation size must be a positive decimal or $HEX value.")
            end
        end,
        onSetDefaultHookName = function()
            local value = ce:InputQuery("Default Hook Name", "Used when asking for a hook name is disabled:",
                config.Data.Memory.DefaultHookName)
            local trimmed = value and value:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                config.Data.Memory.DefaultHookName = trimmed
                saveAndLog("Memory", "DefaultHookName", trimmed)
            end
        end,
        onToggle = function(section, key)
            return function(sender)
                local sectionData = config.Data[section]
                if type(sectionData) ~= "table" then return end
                local value = not (sectionData[key] == true)
                sectionData[key] = value
                if sender then sender.Checked = value end
                saveAndLog(section, key, value)
            end
        end,
        onReloadTemplates = function() runtime:ReloadTemplates() end,
        onReloadProviders = function() runtime:ReloadProviders() end,
        onFullReload = function()
            local host = rawget(_G, "ManifoldTemplateLoaderHost")
            if host and host.Loader == runtime and type(host.HotReload) == "function" then
                host:HotReload()
            else
                runtime.Log:ForceError("[Runtime] No host is attached. A full runtime reload is unavailable.")
            end
        end,
        onValidateTemplates = function()
            local candidates = runtime.TemplateRegistry:Discover()
            local report = runtime.TemplateRegistry:ValidateAll(candidates, runtime.Engine, runtime.ContextRegistry)
            local lines = { string.format("Validated %d template(s):", #report), "" }
            local problems = 0
            for _, entry in ipairs(report) do
                local state = #entry.Errors > 0 and "ERROR" or (#entry.Warnings > 0 and "WARN" or "OK")
                if state ~= "OK" then problems = problems + 1 end
                lines[#lines + 1] = string.format("[%s] %s (%s)", state, entry.Template, entry.Id)
                for _, message in ipairs(entry.Errors) do lines[#lines + 1] = "    error: " .. message end
                for _, message in ipairs(entry.Warnings) do lines[#lines + 1] = "    warning: " .. message end
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = problems == 0 and "No problems found." or tostring(problems) .. " template(s) need attention."
            runtime.UI:ShowTextWindow("Template Validation", table.concat(lines, "\n"), "Validation Report")
        end,
        onTemplateStatus = function()
            local lines = { string.format("Active templates (generation %d):", runtime.TemplateGeneration), "" }
            for _, template in ipairs(runtime:GetTemplateDefinitions()) do
                lines[#lines + 1] = string.format("%-40s %s  [schema %d]  %s",
                    template.settings.Caption, template.id, template.settings.SchemaVersion,
                    template.settings.Category or "")
            end
            runtime.UI:ShowTextWindow("Template Status", table.concat(lines, "\n"), "Active Templates")
        end,
        onOpenFolder = function()
            local folder = runtime.Paths.TemplateFolder
            if runtime.File:FolderExists(folder) then ce:ShellExecute(folder) end
        end,
        onResetConfig = function()
            ce:RunInMain(function()
                if ce:MessageDialog("Reset Template Loader configuration?",
                    rawget(_G, "mtConfirmation") or 3, rawget(_G, "mbYes") or 0, rawget(_G, "mbNo") or 1)
                    == (rawget(_G, "mrYes") or 6) then
                    runtime.Config:Reset()
                    runtime:ApplyConfig()
                    runtime:RebuildOptionsMenus()
                end
            end)
        end,
        onRuntimeStatus = function()
            runtime.UI:ShowTextWindow("Runtime Status", runtime.Diagnostics:BuildReport(runtime), "Diagnostic Report")
        end,
        onSelfCheck = function()
            local allOk, checks = runtime.Diagnostics:SelfCheck(runtime)
            runtime.UI:ShowTextWindow("Self-Check", runtime.Diagnostics:FormatSelfCheck(allOk, checks), "Self-Check Results")
        end,
        onCopyDiagnostics = function()
            if ce:WriteToClipboard(runtime.Diagnostics:BuildReport(runtime)) then
                ce:ShowMessage("Diagnostic report copied to clipboard.")
            end
        end,
        onAbout = function()
            ce:ShowMessage(Version.Full() .. "\n\nAuto Assembler template generation pipeline for Cheat Engine."
                .. "\n\nhttps://github.com/Leunsel/CheatEngineLua")
        end,
        onAddFavorite = function()
            local list = createStringlist()
            local ids = {}
            local favorites = {}
            for _, id in ipairs(runtime:GetFavorites()) do favorites[id] = true end
            for _, template in ipairs(runtime:GetTemplateDefinitions()) do
                if not favorites[template.id] then
                    list.add(template.settings.Caption)
                    ids[#ids + 1] = template.id
                end
            end
            local index = ce:Call("showSelectionList", "Favorites", "Add which template?", list)
            list.destroy()
            if index and index >= 0 and ids[index + 1] then
                runtime:ToggleFavorite(ids[index + 1], true)
                runtime.Log:ForceInfo("[Runtime] Favorite added. New Auto Assembler windows show the updated list.")
            end
        end,
        onRemoveFavorite = function()
            local list = createStringlist()
            local ids = {}
            for _, id in ipairs(runtime:GetFavorites()) do
                local template = runtime.TemplateRegistry:FindById(id)
                list.add(template and template.settings.Caption or id)
                ids[#ids + 1] = id
            end
            local index = ce:Call("showSelectionList", "Favorites", "Remove which favorite?", list)
            list.destroy()
            if index and index >= 0 and ids[index + 1] then
                runtime:ToggleFavorite(ids[index + 1], false)
                runtime.Log:ForceInfo("[Runtime] Favorite removed. New Auto Assembler windows show the updated list.")
            end
        end
    }
end

return Runtime