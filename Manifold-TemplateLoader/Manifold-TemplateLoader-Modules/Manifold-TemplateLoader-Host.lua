--[[
    Stable runtime owner for the Template Loader hot-reload lifecycle.

    This module is deliberately not part of the reload set. It owns the single
    form notification and swaps Loader implementations only after a complete
    candidate module set has loaded successfully.
]]

local Host = {}
Host.__index = Host

local instance = nil

local function isAutoInjectForm(form)
    if not form then return false end
    local ok, className = pcall(function() return form.ClassName end)
    return ok and className == "TfrmAutoInject"
end

function Host:New()
    if not instance then
        instance = setmetatable({
            Loader = nil,
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

function Host:TrackOpenForms()
    if not self.Loader then return end
    local tracked = 0
    for index = 0, getFormCount() - 1 do
        local form = getForm(index)
        if isAutoInjectForm(form) then
            tracked = tracked + 1
            self.Loader:TrackAutoInjectForm(form)
        end
    end
    self:Log(string.format("Initial form scan completed: %d Auto Assembler form(s) observed.", tracked))
end

function Host:Attach(loader)
    self.Loader = loader
    _G.ManifoldTemplateLoader = loader
    _G.loader = loader
    if not self.FormNotificationRegistered then
        registerFormAddNotification(function(form)
            if self.Loader and isAutoInjectForm(form) then
                self:Log("Received Auto Assembler form notification; forwarding it to the active Loader.")
                local ok, err = pcall(function() self.Loader:TrackAutoInjectForm(form) end)
                if not ok then self:Log("Form notification handler failed: " .. tostring(err), true) end
            end
        end)
        self.FormNotificationRegistered = true
        self:Log("Registered the persistent Auto Assembler form notification.")
    end
    self:Log("Attached Loader instance and refreshed global Loader references.")
    self:TrackOpenForms()
end

function Host:LoadCandidate()
    local moduleNames = {
        "Manifold-TemplateLoader-Log",
        "Manifold-TemplateLoader-Json",
        "Manifold-TemplateLoader-File",
        "Manifold-TemplateLoader-Memory",
        "Manifold-TemplateLoader-Manager",
        "Manifold-TemplateLoader-UI",
        "Manifold-TemplateLoader-Loader"
    }
    local oldCache, loaded = {}, {}
    for _, name in ipairs(moduleNames) do
        oldCache[name] = package.loaded[name]
        package.loaded[name] = nil
    end

    for _, name in ipairs(moduleNames) do
        local ok, module = pcall(require, name)
        if not ok then
            for _, restoreName in ipairs(moduleNames) do package.loaded[restoreName] = oldCache[restoreName] end
            return nil, "Could not load " .. name .. ": " .. tostring(module)
        end
        loaded[name] = module
    end
    return {
        LoaderModule = loaded["Manifold-TemplateLoader-Loader"],
        ModuleNames = moduleNames,
        PreviousCache = oldCache
    }
end

function Host:RestoreModuleCache(candidateSet)
    for _, name in ipairs(candidateSet.ModuleNames) do
        package.loaded[name] = candidateSet.PreviousCache[name]
    end
end

function Host:HotReload()
    if self.ReloadInProgress then
        self:Log("Hot reload ignored because another reload is running.")
        return false
    end
    if not self.Loader then
        self:Log("Hot reload aborted: no active Loader instance.")
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
        self:Log("Hot reload failed: " .. tostring(err), true)
        return false
    end
    self:Log("Candidate staged. Existing Auto Assembler windows will close after this menu command returns.")
    return true
end

function Host:StageHotReload()
    local previousLoader = self.Loader
    local previousDefinitions = previousLoader:GetTemplateDefinitions()
    self:Log("Hot reload started; loading candidate modules.")

    -- Candidate loading and validation never touch the active loader state.
    local candidateSet, candidateErr = self:LoadCandidate()
    if not candidateSet then return false, candidateErr end
    self:Log("Candidate modules loaded; initializing candidate Loader.")
    local candidateOk, candidate = pcall(function() return candidateSet.LoaderModule:New() end)
    if not candidateOk then
        self:RestoreModuleCache(candidateSet)
        return false, "Candidate initialization failed: " .. tostring(candidate)
    end
    local plan, planErr = candidate:CreateRegistrationPlan(candidate:GetTemplateDefinitions())
    if not plan or #plan == 0 then
        self:RestoreModuleCache(candidateSet)
        return false, planErr or "No valid templates were discovered"
    end
    self:Log(string.format("Candidate validated with %d template(s).", #plan))

    local created, timer = pcall(createTimer)
    if not created or not timer then
        self:RestoreModuleCache(candidateSet)
        return false, "Could not schedule deferred reload commit: " .. tostring(timer)
    end
    timer.Interval = 50
    timer.OnTimer = function()
        timer.destroy()
        local commitOk, committed, commitErr = pcall(function()
            return self:CommitHotReload(previousLoader, previousDefinitions, candidateSet, candidate)
        end)
        if not commitOk then
            self.ReloadInProgress = false
            self:Log("Hot reload commit crashed: " .. tostring(committed), true)
        elseif not committed then
            self.ReloadInProgress = false
            self:Log("Hot reload commit failed: " .. tostring(commitErr), true)
        else
            self:Log("Existing Auto Assembler windows are closing; the registration swap will finish after teardown.")
        end
    end
    return true
end

function Host:CommitHotReload(previousLoader, previousDefinitions, candidateSet, candidate)
    self:Log(string.format("Committing candidate (previous templates=%d, candidate templates=%d).",
        #(previousDefinitions or {}), #(candidate:GetTemplateDefinitions() or {})))
    self:Log("Closing all tracked Auto Assembler windows for a clean reload.")
    local closed, total = previousLoader:DestroyAutoInjectForms()
    self:Log(string.format("Auto Assembler cleanup completed: %d/%d window(s) closed.", closed, total))

    -- TForm.Close may queue destruction until CE returns to its message loop.
    -- Wait one more tick before replacing template callbacks, otherwise CE can
    -- still hold menu entries from an old form generation.
    local created, timer = pcall(createTimer)
    if not created or not timer then
        return false, "Could not schedule Auto Assembler teardown wait: " .. tostring(timer)
    end
    timer.Interval = 50
    timer.OnTimer = function()
        timer.destroy()
        local finishOk, finished, finishErr = pcall(function()
            return self:FinishHotReload(previousLoader, previousDefinitions, candidateSet, candidate)
        end)
        self.ReloadInProgress = false
        if not finishOk then
            self:Log("Hot reload finalization crashed: " .. tostring(finished), true)
        elseif not finished then
            self:Log("Hot reload finalization failed: " .. tostring(finishErr), true)
        else
            self:Log("Hot reload completed. Open a new Auto Assembler window for the updated settings and categorized templates.")
        end
    end
    return true
end

function Host:FinishHotReload(previousLoader, previousDefinitions, candidateSet, candidate)
    self:Log("Unregistering current template callbacks.")
    previousLoader:UnloadTemplates()
    candidate:AdoptRuntimeState(previousLoader)
    self:Log("Registering candidate template callbacks.")
    local loaded, loadErr = candidate:LoadTemplates(candidate:GetTemplateDefinitions())
    if not loaded then
        self:RestoreModuleCache(candidateSet)
        local restored, restoreErr = previousLoader:LoadTemplates(previousDefinitions)
        if restored then
            return false, "New registrations failed; previous set restored: " .. tostring(loadErr)
        end
        return false, "New registrations failed and rollback failed: " .. tostring(loadErr) .. " | " .. tostring(restoreErr)
    end

    self.Loader = candidate
    _G.ManifoldTemplateLoader = candidate
    _G.loader = candidate
    candidate:AdvanceTemplateGeneration()
    self:Log(string.format("Candidate activation complete (generation=%d, active templates=%d).",
        candidate.TemplateGeneration or -1, #(candidate.RegisteredTemplates or {})))
    self:Log("Candidate committed. No open Auto Assembler window remains; the next window will build the new settings and template menu.")
    return true
end

return Host
