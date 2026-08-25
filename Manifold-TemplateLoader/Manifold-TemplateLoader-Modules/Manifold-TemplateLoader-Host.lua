--[[
    Persistent host for the Template Loader runtime.

    This module is deliberately NOT part of the reload set and holds no
    business logic. It exists because registerFormAddNotification cannot be
    unregistered in Cheat Engine. The host registers it exactly once and
    forwards to whichever Runtime is currently active. That is what makes a
    full runtime reload possible without restarting Cheat Engine.

        Persistent Host
            -> current Runtime generation
                -> registries / services / providers

    A full reload builds a complete candidate Runtime first. Only after the
    candidate loaded, initialized, validated and produced a registration plan
    does the host swap it in. On any failure the current generation simply
    remains active, a failed reload is never a reason to restart CE.
]]

local Host = {}
Host.__index = Host

local instance = nil

--- Every module a full reload replaces. Host itself is excluded on purpose.
local RELOADABLE_MODULES = {
    "Manifold-TemplateLoader-Version",
    "Manifold-TemplateLoader-Errors",
    "Manifold-TemplateLoader-Log",
    "Manifold-TemplateLoader-Json",
    "Manifold-TemplateLoader-File",
    "Manifold-TemplateLoader-CE",
    "Manifold-TemplateLoader-Config",
    "Manifold-TemplateLoader-Engine",
    "Manifold-TemplateLoader-Context",
    "Manifold-TemplateLoader-Inputs",
    "Manifold-TemplateLoader-Registry",
    "Manifold-TemplateLoader-Extensions",
    "Manifold-TemplateLoader-Generator",
    "Manifold-TemplateLoader-Icons",
    "Manifold-TemplateLoader-Theme",
    "Manifold-TemplateLoader-UI",
    "Manifold-TemplateLoader-Diagnostics",
    "Manifold-TemplateLoader-Provider-Runtime",
    "Manifold-TemplateLoader-Provider-Process",
    "Manifold-TemplateLoader-Provider-Instruction",
    "Manifold-TemplateLoader-Provider-Hook",
    "Manifold-TemplateLoader-Provider-Framework",
    "Manifold-TemplateLoader-Runtime"
}

--
--- Only real Auto Assembler windows are forwarded. Several other Cheat
--- Engine windows are TfrmAutoInject too, above all the always-present
--- "Cheat Table Lua Script" form, and CE itself only puts template menu
--- items into windows whose ScriptMode is smAutoAssembler.
--
local function isAutoAssemblerForm(form)
    if not form then return false end
    local ok, className = pcall(function() return form.ClassName end)
    if not ok or className ~= "TfrmAutoInject" then return false end
    local modeOk, mode = pcall(function() return form.ScriptMode end)
    if not modeOk or mode == nil then return true end
    if type(mode) == "string" then return mode == "smAutoAssembler" end
    if type(mode) == "number" then return mode == 0 end
    return true
end

function Host:New()
    if not instance then
        instance = setmetatable({
            Loader = nil,
            Generation = 0,
            ReloadInProgress = false,
            FormNotificationRegistered = false
        }, Host)
    end
    return instance
end

function Host:Log(message, isError)
    if self.Loader and type(self.Loader.LogReload) == "function" then
        self.Loader:LogReload("Host: " .. tostring(message), isError)
    else
        print("[TemplateLoader.Host] " .. tostring(message))
    end
end

function Host:Attach(runtime)
    self.Loader = runtime
    self.Generation = self.Generation + 1
    _G.ManifoldTemplateLoader = runtime
    _G.loader = runtime
    if not self.FormNotificationRegistered then
        registerFormAddNotification(function(form)
            if self.Loader and isAutoAssemblerForm(form) then
                local ok, err = pcall(function() self.Loader:TrackAutoInjectForm(form) end)
                if not ok then self:Log("Form notification handler failed: " .. tostring(err), true) end
            end
        end)
        self.FormNotificationRegistered = true
        self:Log("Registered the persistent Auto Assembler form notification.")
    end
    -- No initial getForm() scan: Cheat Engine's "Cheat Table Lua Script"
    -- window is a TfrmAutoInject that exists before autorun runs, and the
    -- ScriptMode filter above is the only thing separating it from a real
    -- Auto Assembler window. Waiting for the add-notification keeps the
    -- loader out of windows it does not own.
    self:Log("Attached Runtime (host generation " .. self.Generation .. ").")
end

-- Full runtime reload ---------------------------------------------------------

function Host:LoadCandidateModules()
    local previousCache = {}
    for _, name in ipairs(RELOADABLE_MODULES) do
        previousCache[name] = package.loaded[name]
        package.loaded[name] = nil
    end
    for _, name in ipairs(RELOADABLE_MODULES) do
        local ok, module = pcall(require, name)
        if not ok then
            self:RestoreModuleCache(previousCache)
            return nil, "Could not load " .. name .. ": " .. tostring(module)
        end
    end
    return {
        RuntimeModule = package.loaded["Manifold-TemplateLoader-Runtime"],
        PreviousCache = previousCache
    }
end

function Host:RestoreModuleCache(previousCache)
    for name, module in pairs(previousCache) do
        package.loaded[name] = module
    end
end

--
--- No silent loss of Auto Assembler scripts. When open windows must close
--- for the registration swap, the user confirms first. Returns true to
--- proceed.
--
function Host:ConfirmFormClose(formCount)
    if formCount == 0 then return true end
    if type(messageDialog) ~= "function" then return true end
    local text = string.format(
        "Full reload requires closing %d Auto Assembler window(s).\n\n"
        .. "Their editor contents may contain unsaved changes.\n\nReload anyway?",
        formCount)
    local ok, result = pcall(messageDialog, text,
        rawget(_G, "mtConfirmation") or 3, rawget(_G, "mbYes") or 0, rawget(_G, "mbNo") or 1)
    return ok and result == (rawget(_G, "mrYes") or 6)
end

function Host:HotReload()
    if self.ReloadInProgress then
        self:Log("Hot reload ignored because another reload is running.")
        return false
    end
    if not self.Loader then
        self:Log("Hot reload aborted: no active Runtime.")
        return false
    end
    self.ReloadInProgress = true
    local callOk, staged, err = pcall(function() return self:StageHotReload() end)
    if not callOk then
        self.ReloadInProgress = false
        self:Log("Hot reload aborted by an internal error: " .. tostring(staged), true)
        return false
    end
    if not staged then
        self.ReloadInProgress = false
        if err then self:Log("Hot reload failed: " .. tostring(err), true) end
        return false
    end
    return true
end

function Host:StageHotReload()
    local previousRuntime = self.Loader
    local previousDefinitions = previousRuntime:GetTemplateDefinitions()
    self:Log("Hot reload started. Loading candidate modules.")
    -- Candidate loading and validation never touch the active runtime state.
    local candidateSet, candidateErr = self:LoadCandidateModules()
    if not candidateSet then return false, candidateErr end
    self:Log("Candidate modules loaded. Initializing candidate Runtime.")
    local candidateOk, candidate = pcall(function() return candidateSet.RuntimeModule:New() end)
    if not candidateOk then
        self:RestoreModuleCache(candidateSet.PreviousCache)
        return false, "Candidate initialization failed: " .. tostring(candidate)
    end
    local plan, planErr = candidate:CreateRegistrationPlan(candidate:GetTemplateDefinitions())
    if not plan or #plan == 0 then
        self:RestoreModuleCache(candidateSet.PreviousCache)
        return false, planErr or "No valid templates were discovered"
    end
    self:Log(string.format("Candidate validated with %d template(s).", #plan))
    -- Only ask the user once the reload is actually going to work.
    local openForms = previousRuntime:GetTrackedForms()
    if not self:ConfirmFormClose(#openForms) then
        self:RestoreModuleCache(candidateSet.PreviousCache)
        self:Log("Hot reload cancelled by the user. The current runtime remains active.")
        return false, nil
    end
    local created, timer = pcall(createTimer)
    if not created or not timer then
        self:RestoreModuleCache(candidateSet.PreviousCache)
        return false, "Could not schedule deferred reload commit: " .. tostring(timer)
    end
    timer.Interval = 50
    timer.OnTimer = function()
        timer.destroy()
        local commitOk, committed, commitErr = pcall(function()
            return self:CommitHotReload(previousRuntime, previousDefinitions, candidateSet, candidate)
        end)
        if not commitOk then
            self.ReloadInProgress = false
            self:RestoreModuleCache(candidateSet.PreviousCache)
            self:Log("Hot reload commit crashed: " .. tostring(committed), true)
        elseif not committed then
            self.ReloadInProgress = false
            self:RestoreModuleCache(candidateSet.PreviousCache)
            self:Log("Hot reload commit failed: " .. tostring(commitErr), true)
        end
    end
    return true
end

function Host:CommitHotReload(previousRuntime, previousDefinitions, candidateSet, candidate)
    self:Log("Closing all tracked Auto Assembler windows for a clean reload.")
    local closed, total = previousRuntime:DestroyAutoInjectForms()
    self:Log(string.format("Auto Assembler cleanup completed: %d/%d window(s) closed.", closed, total))
    -- TForm.Close may queue destruction until CE returns to its message loop.
    -- Wait one more tick before replacing template callbacks, otherwise CE
    -- can still hold menu entries from an old form generation.
    local created, timer = pcall(createTimer)
    if not created or not timer then
        return false, "Could not schedule Auto Assembler teardown wait: " .. tostring(timer)
    end
    timer.Interval = 50
    timer.OnTimer = function()
        timer.destroy()
        local finishOk, finished, finishErr = pcall(function()
            return self:FinishHotReload(previousRuntime, previousDefinitions, candidateSet, candidate)
        end)
        self.ReloadInProgress = false
        if not finishOk then
            -- FinishHotReload restores the cache itself on its handled
            -- failure path. A crash bypassed that, so restore here.
            self:RestoreModuleCache(candidateSet.PreviousCache)
            self:Log("Hot reload finalization crashed: " .. tostring(finished), true)
        elseif not finished then
            self:Log("Hot reload finalization failed: " .. tostring(finishErr), true)
        else
            self:Log("Hot reload completed. Open a new Auto Assembler window for the updated templates.")
        end
    end
    return true
end

function Host:FinishHotReload(previousRuntime, previousDefinitions, candidateSet, candidate)
    self:Log("Unregistering current template callbacks.")
    previousRuntime:UnloadTemplates()
    candidate:AdoptRuntimeState(previousRuntime)
    self:Log("Registering candidate template callbacks.")
    local loaded, loadErr = candidate:LoadTemplates(candidate:GetTemplateDefinitions())
    if not loaded then
        self:RestoreModuleCache(candidateSet.PreviousCache)
        local restored, restoreErr = previousRuntime:LoadTemplates(previousDefinitions)
        if restored then
            return false, "New registrations failed, previous set restored: " .. tostring(loadErr)
        end
        return false, "New registrations failed and rollback failed: " .. tostring(loadErr) .. " | " .. tostring(restoreErr)
    end
    -- Swap. The old runtime releases its owned resources (viewer forms,
    -- listeners). Its tracked-form state was adopted above.
    pcall(function() previousRuntime:Shutdown() end)
    self:Attach(candidate)
    candidate:AdvanceTemplateGeneration()
    candidate.LastReloadStatus = os.date("%H:%M:%S") .. " Full runtime reload (host generation " .. self.Generation .. ")"
    self:Log(string.format("Candidate activation complete (template generation=%d, active templates=%d).",
        candidate.TemplateGeneration or -1, #(candidate.RegisteredTemplates or {})))
    return true
end

return Host