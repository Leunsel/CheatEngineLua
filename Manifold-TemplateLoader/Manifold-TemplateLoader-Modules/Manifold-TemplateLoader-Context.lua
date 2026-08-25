--[[
    Context registry and per-generation context resolution.

    Providers register variables here. Templates read them by plain name
    (<< OriginalBytes >>). Resolution is lazy. A variable is computed the
    first time something asks for it, its declared dependencies are resolved
    first, and every result is memoized for the lifetime of one generation.
    Cycles are detected at registration time (declared dependencies) and again
    at resolution time (actual call chains). Registering a variable makes it
    available to every template immediately! No loader, compiler or UI change
    needed. That is the core promise of the provider system.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Registry = {}
Registry.__index = Registry

local Context = {}
Context.__index = Context

-- Registry -------------------------------------------------------------------

function Registry:New(services)
    return setmetatable({
        Log = services.Log,
        Providers = {}, -- name -> { Name, Variables = { name -> def } }
        Variables = {}, -- canonical name -> def (def.Provider set)
        Aliases = {},   -- alias -> { Target, Deprecated }
        Order = {}      -- registration order of variable names, for docs
    }, Registry)
end

local function validateVariableDef(name, def)
    if type(name) ~= "string" or name == "" then
        return "Variable name must be a non-empty string"
    end
    if not name:match("^[%a_][%w_]*$") then
        return "Variable name '" .. name .. "' is not a valid identifier"
    end
    if type(def) ~= "table" then
        return "Variable '" .. name .. "' definition must be a table"
    end
    if type(def.Resolve) ~= "function" then
        return "Variable '" .. name .. "' has no Resolve function"
    end
    if def.DependsOn ~= nil and type(def.DependsOn) ~= "table" then
        return "Variable '" .. name .. "' DependsOn must be a list"
    end
    return nil
end

--
--- Registers one variable. def fields:
---   Provider (string), Type, Description, DependsOn = {names},
---   Resolve = function(context) -> value, Hint = string|function(context),
---   Hidden (internal helper variables, kept out of documentation listings)
--
function Registry:RegisterVariable(name, def)
    local problem = validateVariableDef(name, def)
    if problem then return false, problem end
    local existing = self.Variables[name]
    if existing then
        return false, string.format("Variable '%s' from provider '%s' collides with provider '%s'",
            name, tostring(def.Provider), tostring(existing.Provider))
    end
    if self.Aliases[name] then
        return false, string.format("Variable '%s' collides with an alias of '%s'",
            name, tostring(self.Aliases[name].Target))
    end
    def.Provider = def.Provider or "Unknown"
    self.Variables[name] = def
    self.Order[#self.Order + 1] = name
    return true
end

--
--- Registers a provider with a batch of variables:
---   registry:RegisterProvider{ Name = "Memory", Variables = { X = {...} } }
--- Fails atomically: either every variable registers or none does.
--
function Registry:RegisterProvider(provider)
    if type(provider) ~= "table" or type(provider.Name) ~= "string" or provider.Name == "" then
        return false, "Provider must have a Name"
    end
    if self.Providers[provider.Name] then
        return false, "Provider '" .. provider.Name .. "' is already registered"
    end
    local staged = {}
    for name, def in pairs(provider.Variables or {}) do
        def.Provider = provider.Name
        local problem = validateVariableDef(name, def)
        if problem then return false, problem end
        if self.Variables[name] or self.Aliases[name] then
            local owner = self.Variables[name] and self.Variables[name].Provider
                or ("alias of " .. tostring(self.Aliases[name].Target))
            return false, string.format("Variable '%s' from provider '%s' collides with %s",
                name, provider.Name, tostring(owner))
        end
        staged[#staged + 1] = { Name = name, Def = def }
    end
    table.sort(staged, function(a, b) return a.Name < b.Name end)
    for _, entry in ipairs(staged) do
        self.Variables[entry.Name] = entry.Def
        self.Order[#self.Order + 1] = entry.Name
    end
    self.Providers[provider.Name] = provider
    for alias, target in pairs(provider.Aliases or {}) do
        local ok, err = self:RegisterAlias(alias, target, true)
        if not ok then self.Log:Warning("[Context] " .. tostring(err)) end
    end
    return true
end

--
--- An alias resolves like its target. Deprecated aliases warn once per
--- generation but keep working, old templates must not break.
--
function Registry:RegisterAlias(alias, target, deprecated)
    if type(alias) ~= "string" or alias == "" then return false, "Alias name must be a string" end
    if self.Variables[alias] or self.Aliases[alias] then
        return false, "Alias '" .. alias .. "' collides with an existing name"
    end
    self.Aliases[alias] = { Target = target, Deprecated = deprecated == true }
    return true
end

function Registry:Lookup(name)
    local def = self.Variables[name]
    if def then return name, def, nil end
    local alias = self.Aliases[name]
    if alias then
        local canonical = alias.Target
        return canonical, self.Variables[canonical], alias
    end
    return nil, nil, nil
end

function Registry:IsKnown(name)
    return self.Variables[name] ~= nil or self.Aliases[name] ~= nil
end

--
--- Static validation: every declared dependency must exist and the declared
--- dependency graph must be acyclic. Returns ok, issues (list of strings).
--
function Registry:Validate()
    local issues = {}
    for name, def in pairs(self.Variables) do
        for _, dep in ipairs(def.DependsOn or {}) do
            if not self:IsKnown(dep) then
                issues[#issues + 1] = string.format(
                    "Variable '%s' (provider '%s') depends on unknown variable '%s'",
                    name, tostring(def.Provider), tostring(dep))
            end
        end
    end
    for alias, entry in pairs(self.Aliases) do
        if not self.Variables[entry.Target] then
            issues[#issues + 1] = string.format("Alias '%s' points at unknown variable '%s'",
                alias, tostring(entry.Target))
        end
    end
    local WHITE, GRAY, BLACK = 0, 1, 2
    local state = {}
    local function visit(name, chain)
        local canonical = select(1, self:Lookup(name)) or name
        local mark = state[canonical] or WHITE
        if mark == BLACK then return true end
        if mark == GRAY then
            issues[#issues + 1] = "Circular dependency: " .. table.concat(chain, " -> ") .. " -> " .. canonical
            return false
        end
        state[canonical] = GRAY
        local def = self.Variables[canonical]
        chain[#chain + 1] = canonical
        for _, dep in ipairs(def and def.DependsOn or {}) do
            if self:IsKnown(dep) then visit(dep, chain) end
        end
        chain[#chain] = nil
        state[canonical] = BLACK
        return true
    end
    for name in pairs(self.Variables) do visit(name, {}) end
    return #issues == 0, issues
end

--
--- Metadata for diagnostics, validation and documentation. One source of
--- truth instead of four hand-maintained lists.
--
function Registry:ListVariables(includeHidden)
    local list = {}
    for _, name in ipairs(self.Order) do
        local def = self.Variables[name]
        if def and (includeHidden or not def.Hidden) then
            list[#list + 1] = {
                Name = name,
                Type = def.Type,
                Provider = def.Provider,
                Description = def.Description,
                Dependencies = def.DependsOn or {}
            }
        end
    end
    table.sort(list, function(a, b)
        if a.Provider ~= b.Provider then return tostring(a.Provider) < tostring(b.Provider) end
        return a.Name < b.Name
    end)
    return list
end

function Registry:ListProviders()
    local names = {}
    for name in pairs(self.Providers) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--
--- A fresh, fully isolated context for one generation. Nothing is shared
--- with previous generations: values, inputs and warnings all start empty.
--
function Registry:NewContext(setup)
    setup = setup or {}
    local ctx = setmetatable({
        Registry = self,
        Log = self.Log,
        Values = {},    -- canonical name -> { Value = ... } (memo, nil-safe)
        Stack = {},     -- canonical name -> true (resolution in flight)
        StackList = {}, -- ordered chain for cycle error messages
        Options = setup.Options or {},
        Settings = setup.Settings or {},
        Form = setup.Form,
        GenerationId = setup.GenerationId or 0,
        Template = setup.Template,
        Timings = {},
        WarnedDeprecated = {},
        WarnedUnknown = {}
    }, Context)
    return ctx
end

-- Context --------------------------------------------------------------------

--
--- Seeds a value (template inputs, TemplateSettings, Header). Pre-set values
--- win over providers for this one generation.
--
function Context:Set(name, value)
    self.Values[name] = { Value = value }
end

--
--- Turns a memoized resolution failure into a plain nil for the rest of this
--- generation. Declaring a variable Optional promises the template it can
--- read the name safely, so a resolver that raised must degrade to nil
--- instead of re-raising on every later access.
--
function Context:Downgrade(name)
    local canonical = self.Registry:Lookup(name) or name
    local entry = { Value = nil }
    self.Values[canonical] = entry
    if name ~= canonical then self.Values[name] = entry end
end

function Context:Has(name)
    return self.Values[name] ~= nil or self.Registry:IsKnown(name)
end

--
--- Resolves one variable.
--- Returns value, err, known:
---   known == false          the name is not registered and not pre-set
---   err ~= nil              a resolver failed (structured error)
---   value (possibly nil)    resolved. nil means "genuinely unresolvable",
---                           e.g. no base register in the instruction
--
function Context:Resolve(name)
    local memo = self.Values[name]
    if memo then
        if memo.Error then return nil, memo.Error, true end
        return memo.Value, nil, true
    end
    local canonical, def, alias = self.Registry:Lookup(name)
    if not def then return nil, nil, false end
    if alias and alias.Deprecated and not self.WarnedDeprecated[name] then
        self.WarnedDeprecated[name] = true
        self.Log:Warning(string.format(
            "[Context] Template uses deprecated context variable '%s'. Use '%s' instead.",
            name, canonical))
    end
    memo = self.Values[canonical]
    if memo then
        self.Values[name] = memo
        if memo.Error then return nil, memo.Error, true end
        return memo.Value, nil, true
    end
    if self.Stack[canonical] then
        local chain = table.concat(self.StackList, " -> ") .. " -> " .. canonical
        return nil, Errors.New{
            Code = Errors.Codes.CONTEXT_CYCLE, Stage = Errors.Stages.Context,
            Variable = canonical, Provider = def.Provider,
            Message = "Circular context dependency: " .. chain
        }, true
    end
    self.Stack[canonical] = true
    self.StackList[#self.StackList + 1] = canonical
    local failure
    for _, dep in ipairs(def.DependsOn or {}) do
        local _, depErr = self:Resolve(dep)
        if depErr then failure = depErr; break end
    end
    local value
    if not failure then
        local started = os.clock()
        local ok, result = pcall(def.Resolve, self)
        local duration = (os.clock() - started) * 1000
        self.Timings[canonical] = duration
        if ok then
            value = result
            self.Log:Trace(string.format("[Context] %s resolved by %s in %.2f ms",
                canonical, tostring(def.Provider), duration),
                { generation = self.GenerationId, provider = def.Provider })
        else
            failure = Errors.Wrap(result, {
                Code = Errors.Codes.CONTEXT_RESOLUTION_FAILED,
                Stage = Errors.Stages.Context,
                Variable = canonical,
                Provider = def.Provider
            })
        end
    end
    self.Stack[canonical] = nil
    self.StackList[#self.StackList] = nil
    if failure then
        -- Failures memoize too: a resolver with side effects (an address or
        -- hook-name prompt) must not run again for the same generation just
        -- because a second part of the template references the variable.
        local entry = { Error = failure }
        self.Values[canonical] = entry
        if name ~= canonical then self.Values[name] = entry end
        return nil, failure, true
    end
    local entry = { Value = value }
    self.Values[canonical] = entry
    if name ~= canonical then self.Values[name] = entry end
    return value, nil, true
end

--
--- Resolve for use inside resolvers and templates.
--- A resolver failure is raised as a structured error so it propagates out
--- of the render.
--
function Context:Get(name)
    local value, err = self:Resolve(name)
    if err then error(err, 0) end
    return value
end

--
--- Checks a template's Requires contract before anything renders. A required
--- variable that fails OR resolves to nil/"" aborts with the variable's own
--- hint, so the user learns what to do instead of what went wrong internally.
--
function Context:ResolveRequired(names)
    for _, name in ipairs(names or {}) do
        local value, err, known = self:Resolve(name)
        if err then return nil, err end
        if not known then
            return nil, Errors.New{
                Code = Errors.Codes.REQUIREMENT_MISSING, Stage = Errors.Stages.Context,
                Variable = name,
                Message = string.format("Required context variable '%s' is not provided by any registered provider.", name)
            }
        end
        if value == nil or value == "" then
            local _, def = self.Registry:Lookup(name)
            local hint = def and def.Hint
            if type(hint) == "function" then
                local ok, hintText = pcall(hint, self)
                hint = ok and hintText or nil
            end
            return nil, Errors.New{
                Code = Errors.Codes.REQUIREMENT_MISSING, Stage = Errors.Stages.Context,
                Variable = name, Provider = def and def.Provider,
                Message = string.format("Required context variable '%s' could not be resolved.", name),
                Hint = hint
            }
        end
    end
    return true
end

--
--- Builds the render environment for this context. Pre-set values, helpers
--- and stdlib live directly in the table. Everything else resolves lazily
--- through the registry. allowGlobals keeps 2.x templates working. Unknown
--- names fall back to _G there. Restricted (schema 2) templates get nil plus
--- a one-time warning instead.
--
function Context:BuildEnvironment(base, allowGlobals)
    local env = {}
    for key, value in pairs(base or {}) do env[key] = value end
    local ctx = self
    setmetatable(env, {
        __index = function(_, key)
            local value, err, known = ctx:Resolve(key)
            if err then error(err, 0) end
            if known then return value end
            if allowGlobals then
                return rawget(_G, key)
            end
            if type(key) == "string" and not ctx.WarnedUnknown[key] then
                ctx.WarnedUnknown[key] = true
                ctx.Log:Warning(string.format(
                    "[Context] Unknown context variable '%s' in template '%s' evaluated to nil.",
                    key, tostring(ctx.Template or "?")))
            end
            return nil
        end
    })
    return env
end

return { Registry = Registry, Context = Context }