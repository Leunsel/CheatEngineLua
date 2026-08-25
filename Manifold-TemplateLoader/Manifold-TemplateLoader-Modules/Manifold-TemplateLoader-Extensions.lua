--[[
    Extension registry and pipeline hooks.

    An extension can register context providers, single variables, template
    helpers, capability checkers and pipeline hooks without touching any core
    module. The API is deliberately small:

        runtime.Extensions:Register{
            Name         = "Mono", Version = "1.0.0",
            Providers    = { providerTable, ... },    -- RegisterProvider payloads
            Variables    = { Name = def, ... },       -- individual variables
            Helpers      = { helperName = fn, ... },  -- extra template helpers
            Capabilities = { ["X.Y"] = checkFn },     -- capability availability
            Hooks        = { BeforeRender = fn, ... }
        }

    Hooks run isolated. A broken optional hook is logged and skipped, never
    allowed to corrupt the loader. Only Before* hooks may veto by returning
    false plus a reason. After* results are ignored.
]]

local Extensions = {}
Extensions.__index = Extensions

Extensions.HookPoints = {
    BeforeTemplateValidation = true,
    AfterTemplateValidation = true,
    BeforeContextResolution = true,
    AfterContextResolution = true,
    BeforeRender = true,
    AfterRender = true,
    BeforeApply = true,
    AfterApply = true
}

function Extensions:New(services)
    return setmetatable({
        Log = services.Log,
        ContextRegistry = services.ContextRegistry,
        Registered = {},  -- name -> extension def
        Hooks = {},       -- hookPoint -> { {Extension=, Fn=}, ... }
        Helpers = {},     -- helperName -> fn
        Capabilities = {} -- capabilityName -> checkFn
    }, Extensions)
end

function Extensions:Register(extension)
    if type(extension) ~= "table" or type(extension.Name) ~= "string" or extension.Name == "" then
        return false, "Extension must have a Name"
    end
    if self.Registered[extension.Name] then
        return false, "Extension '" .. extension.Name .. "' is already registered"
    end
    -- Two-phase: check every name for collisions first, then apply. The
    -- registry has no unregister, so a partial registration must never
    -- happen. It would poison later replays with collision errors.
    local claimed = {}
    for _, provider in ipairs(extension.Providers or {}) do
        if type(provider) ~= "table" or type(provider.Name) ~= "string" then
            return false, string.format("Extension '%s' has an invalid provider entry", extension.Name)
        end
        if self.ContextRegistry.Providers[provider.Name] then
            return false, string.format("Extension '%s': provider '%s' already exists", extension.Name, provider.Name)
        end
        for name in pairs(provider.Variables or {}) do
            if self.ContextRegistry:IsKnown(name) or claimed[name] then
                return false, string.format("Extension '%s': variable '%s' collides with an existing name",
                    extension.Name, name)
            end
            claimed[name] = true
        end
    end
    for name in pairs(extension.Variables or {}) do
        if self.ContextRegistry:IsKnown(name) or claimed[name] then
            return false, string.format("Extension '%s': variable '%s' collides with an existing name",
                extension.Name, name)
        end
        claimed[name] = true
    end
    for _, provider in ipairs(extension.Providers or {}) do
        local ok, err = self.ContextRegistry:RegisterProvider(provider)
        if not ok then
            return false, string.format("Extension '%s' provider failed: %s", extension.Name, tostring(err))
        end
    end
    for name, def in pairs(extension.Variables or {}) do
        def.Provider = def.Provider or extension.Name
        local ok, err = self.ContextRegistry:RegisterVariable(name, def)
        if not ok then
            return false, string.format("Extension '%s' variable failed: %s", extension.Name, tostring(err))
        end
    end
    for name, fn in pairs(extension.Helpers or {}) do
        if type(fn) == "function" and self.Helpers[name] == nil then
            self.Helpers[name] = fn
        else
            self.Log:Warning(string.format("[Extensions] Helper '%s' from '%s' was skipped (duplicate or not a function).",
                tostring(name), extension.Name))
        end
    end
    for name, check in pairs(extension.Capabilities or {}) do
        if type(check) == "function" then self.Capabilities[name] = check end
    end
    for point, fn in pairs(extension.Hooks or {}) do
        if Extensions.HookPoints[point] and type(fn) == "function" then
            self.Hooks[point] = self.Hooks[point] or {}
            self.Hooks[point][#self.Hooks[point] + 1] = { Extension = extension.Name, Fn = fn }
        else
            self.Log:Warning(string.format("[Extensions] Unknown hook point '%s' in extension '%s'.",
                tostring(point), extension.Name))
        end
    end
    self.Registered[extension.Name] = extension
    self.Log:InfoF("[Extensions] Registered extension '%s' (%s).",
        extension.Name, tostring(extension.Version or "no version"))
    return true
end

--
--- Runs a hook point. Returns true, or false plus a reason when a Before*
--- hook vetoed. Hook errors never propagate. They are logged and the hook
--- is skipped.
--
function Extensions:RunHook(point, payload)
    local canVeto = point:sub(1, 6) == "Before"
    for _, entry in ipairs(self.Hooks[point] or {}) do
        local ok, result, reason = pcall(entry.Fn, payload)
        if not ok then
            self.Log:Error(string.format("[Extensions] Hook %s of '%s' failed: %s",
                point, entry.Extension, tostring(result)))
        elseif canVeto and result == false then
            return false, string.format("Extension '%s' vetoed %s: %s",
                entry.Extension, point, tostring(reason or "no reason given"))
        end
    end
    return true
end

--
--- Registers a capability checker. The loader registers the built-in
--- Manifold ones. Extensions can add their own.
--
function Extensions:RegisterCapability(name, check)
    if type(name) ~= "string" or name == "" or type(check) ~= "function" then
        return false, "A capability needs a name and a check function"
    end
    self.Capabilities[name] = check
    return true
end

--
--- Availability of one declared capability. Unknown capabilities return nil
--- (not false): the loader cannot prove absence, so it only informs.
--
function Extensions:CheckCapability(name)
    local check = self.Capabilities[name]
    if not check then return nil end
    local ok, available = pcall(check)
    return ok and available == true
end

function Extensions:List()
    local list = {}
    for name, extension in pairs(self.Registered) do
        list[#list + 1] = { Name = name, Version = extension.Version }
    end
    table.sort(list, function(a, b) return a.Name < b.Name end)
    return list
end

return Extensions