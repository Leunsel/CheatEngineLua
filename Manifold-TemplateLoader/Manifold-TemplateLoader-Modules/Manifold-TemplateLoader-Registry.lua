--[[
    Template registry: discovery, settings loading and validation.

    Settings files run in a minimal data sandbox (no io, no os, no _G, no
    Cheat Engine APIs). They are metadata, not plug-ins. Two settings schemas
    are accepted:

      Schema 1 (legacy, implicit): the 2.x fields. Nothing changes for these
      files. They keep full access to the legacy template environment.

      Schema 2 (SchemaVersion = 2): adds Id, Description, Category/Order,
      Requires/Optional, Inputs, Architectures, Capabilities, Tags and a
      nested Memory block. Schema-2 templates render in a restricted
      environment unless AllowUnsafeGlobals = true.

    Every template gets a stable Id. Declared in schema 2, derived from the
    file name for legacy templates. Favorites, Recent and diagnostics key on
    Ids, never on captions.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Registry = {}
Registry.__index = Registry

Registry.ScriptExtension = ".CEA"
Registry.SettingsExtension = ".Settings.lua"

local BOOLEAN_OVERRIDES = { "AskForInjectionAddress", "AskForHookName", "AllocationNear" }
local STRING_OVERRIDES = { "AppendToHookName", "DefaultHookName" }

--- Fields the schemas define. Anything else an author writes into a settings
--- file is preserved under Custom and reachable via TemplateSettings, 2.x
--- kept every field, and private templates rely on that.
local KNOWN_SETTINGS_FIELDS = {
    SchemaVersion = true, Id = true, Caption = true, Description = true,
    Author = true, Version = true, Tags = true, Shortcut = true,
    InSubMenu = true, SubMenuName = true, Category = true,
    CategoryOrder = true, MenuOrder = true, Order = true,
    Requires = true, Optional = true, Inputs = true, Architectures = true,
    Capabilities = true, AllowUnsafeGlobals = true, Memory = true,
    AskForInjectionAddress = true, AskForHookName = true,
    AppendToHookName = true, AllocationSize = true, AllocationNear = true,
    DefaultHookName = true
}

function Registry:New(services)
    return setmetatable({
        File = services.File,
        Log = services.Log,
        Inputs = services.Inputs,
        TemplateFolder = services.Paths.TemplateFolder,
        Definitions = {},
        ById = {},
        ByCaption = {}
    }, Registry)
end

function Registry:GetTemplateFolder() return self.TemplateFolder end

-- Settings loading -----------------------------------------------------------

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

function Registry:GetSettingsEnvironment()
    -- The library tables are copied so a settings file assigning into
    -- string/math/table cannot pollute the shared Lua state.
    return {
        ipairs = ipairs,
        pairs = pairs,
        tonumber = tonumber,
        tostring = tostring,
        math = shallowCopy(math),
        string = shallowCopy(string),
        table = shallowCopy(table)
    }
end

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function slugify(value)
    local slug = tostring(value):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return slug ~= "" and slug or "template"
end

local function checkType(settings, key, expected)
    local value = settings[key]
    if value ~= nil and type(value) ~= expected then
        return key .. " must be a " .. expected
    end
    return nil
end

local function stringList(value, key)
    if value == nil then return {}, nil end
    if type(value) ~= "table" then return nil, key .. " must be a list of strings" end
    local list = {}
    for _, entry in ipairs(value) do
        if type(entry) ~= "string" then return nil, key .. " must contain only strings" end
        list[#list + 1] = entry
    end
    return list, nil
end

--
--- Normalizes a raw settings table (either schema) into the canonical
--- internal shape. Returns normalized, err.
--
function Registry:ValidateSettings(templateName, settings, settingsPath)
    if type(settings) ~= "table" then
        return nil, "Settings must return a table"
    end
    local schema = tonumber(settings.SchemaVersion) or 1
    if schema ~= 1 and schema ~= 2 then
        return nil, "Unsupported settings SchemaVersion " .. tostring(settings.SchemaVersion)
            .. " (this loader supports 1 and 2)"
    end
    for key, expected in pairs({
        Caption = "string", Shortcut = "string", InSubMenu = "boolean",
        SubMenuName = "string", Category = "string", Description = "string",
        Author = "string", Version = "string", Id = "string",
        AllowUnsafeGlobals = "boolean"
    }) do
        local problem = checkType(settings, key, expected)
        if problem then return nil, problem end
    end
    for _, key in ipairs({ "MenuOrder", "Order", "CategoryOrder" }) do
        local problem = checkType(settings, key, "number")
        if problem then return nil, problem end
    end
    local normalized = {
        SchemaVersion = schema,
        Caption = trim(settings.Caption) or templateName,
        Shortcut = trim(settings.Shortcut or "") or "",
        InSubMenu = settings.InSubMenu ~= false,
        Category = trim(settings.Category or settings.SubMenuName or "Templates") or "Templates",
        CategoryOrder = tonumber(settings.CategoryOrder),
        Order = tonumber(settings.Order) or tonumber(settings.MenuOrder),
        Description = settings.Description,
        Author = settings.Author,
        Version = settings.Version,
        AllowUnsafeGlobals = schema == 1 or settings.AllowUnsafeGlobals == true,
        SourcePath = settingsPath
    }
    if normalized.Caption == "" then return nil, "Caption must not be empty" end
    if settings.Id ~= nil then
        if not settings.Id:match("^[%w%._%-]+$") then
            return nil, "Id may only contain letters, digits, '.', '_' and '-'"
        end
        normalized.Id = settings.Id
    else
        normalized.Id = "legacy." .. slugify(templateName)
    end
    local tags, tagsErr = stringList(settings.Tags, "Tags")
    if not tags then return nil, tagsErr end
    normalized.Tags = tags
    local requires, requiresErr = stringList(settings.Requires, "Requires")
    if not requires then return nil, requiresErr end
    normalized.Requires = requires
    local optional, optionalErr = stringList(settings.Optional, "Optional")
    if not optional then return nil, optionalErr end
    normalized.Optional = optional
    local capabilities, capabilitiesErr = stringList(settings.Capabilities, "Capabilities")
    if not capabilities then return nil, capabilitiesErr end
    normalized.Capabilities = capabilities
    local architectures, architecturesErr = stringList(settings.Architectures, "Architectures")
    if not architectures then return nil, architecturesErr end
    normalized.Architectures = nil
    if #architectures > 0 then
        normalized.Architectures = {}
        for _, arch in ipairs(architectures) do
            if arch ~= "x86" and arch ~= "x64" then
                return nil, "Architectures may only contain 'x86' and 'x64', not '" .. tostring(arch) .. "'"
            end
            normalized.Architectures[arch] = true
        end
    end
    local inputs, inputsErr = self.Inputs:ValidateDefinitions(settings.Inputs)
    if not inputs then return nil, inputsErr end
    normalized.Inputs = inputs
    -- Memory overrides. Schema 2 prefers the nested Memory block. The flat
    -- legacy fields stay accepted in both schemas.
    local memorySource = type(settings.Memory) == "table" and settings.Memory or settings
    local overrides = {}
    for _, key in ipairs(BOOLEAN_OVERRIDES) do
        local value = memorySource[key]
        if value == nil then value = settings[key] end
        if value ~= nil then
            if type(value) ~= "boolean" then return nil, key .. " must be a boolean" end
            overrides[key] = value
        end
    end
    for _, key in ipairs(STRING_OVERRIDES) do
        local value = memorySource[key]
        if value == nil then value = settings[key] end
        if value ~= nil then
            if type(value) ~= "string" then return nil, key .. " must be a string" end
            overrides[key] = value
        end
    end
    local allocationSize = memorySource.AllocationSize
    if allocationSize == nil then allocationSize = settings.AllocationSize end
    if allocationSize ~= nil then
        if type(allocationSize) ~= "string" and type(allocationSize) ~= "number" then
            return nil, "AllocationSize must be a string or number"
        end
        overrides.AllocationSize = allocationSize
    end
    normalized.MemoryOverrides = overrides
    local custom = {}
    for key, value in pairs(settings) do
        if not KNOWN_SETTINGS_FIELDS[key] then custom[key] = value end
    end
    normalized.Custom = custom
    return normalized
end

function Registry:LoadSettings(settingsPath, templateName)
    settingsPath = self.File:NormalizePath(settingsPath)
    if not settingsPath or not self.File:Exists(settingsPath) then
        return nil, "Settings file not found"
    end
    local source, readErr = self.File:ReadFile(settingsPath)
    if not source then return nil, readErr end
    -- load() on a string does no BOM skipping. Editors on Windows commonly
    -- save UTF-8 with one.
    if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
    local chunk, compileErr = load(source, "@" .. settingsPath, "t", self:GetSettingsEnvironment())
    if not chunk then
        return nil, "Settings syntax error: " .. tostring(compileErr)
    end
    local ok, settings = pcall(chunk)
    if not ok then
        return nil, "Settings execution failed: " .. tostring(settings)
    end
    return self:ValidateSettings(templateName, settings, settingsPath)
end

-- Discovery ------------------------------------------------------------------

--
--- Scans the template folder (non-recursively. The Partials subfolder is
--- reserved for includes) and returns validated definitions. Never touches
--- self.Definitions. The caller decides when a discovered set becomes the
--- active one.
--
function Registry:Discover()
    local templates = {}
    local folder = self.File:NormalizePath(self.TemplateFolder)
    if not folder or not self.File:FolderExists(folder) then
        self.Log:Warning("[Registry] Template folder is unavailable: " .. tostring(folder))
        return templates
    end
    local captions, ids = {}, {}
    for _, path in ipairs(self.File:ScanFolder(folder, false)) do
        local baseName = path:match("([^/]+)$")
        -- Case-insensitive: Windows users save 'Foo.cea' as readily as '.CEA'.
        if baseName and baseName:sub(-#Registry.ScriptExtension):upper() == Registry.ScriptExtension:upper() then
            local name = baseName:sub(1, -#Registry.ScriptExtension - 1)
            if name:lower() ~= "header" then
                local settingsPath = self.File:NormalizePath(folder .. "/" .. name .. Registry.SettingsExtension)
                local settings, err = self:LoadSettings(settingsPath, name)
                if not settings then
                    self.Log:Warning(string.format("[Registry] Skipped '%s': %s", name, tostring(err)))
                elseif captions[settings.Caption] then
                    self.Log:Error(string.format(
                        "[Registry] Skipped '%s': Caption '%s' is already used by '%s'.",
                        name, settings.Caption, captions[settings.Caption]))
                elseif ids[settings.Id] then
                    self.Log:Error(string.format(
                        "[Registry] Skipped '%s': Id '%s' is already used by '%s'.",
                        name, settings.Id, ids[settings.Id]))
                else
                    captions[settings.Caption] = name
                    ids[settings.Id] = name
                    templates[#templates + 1] = {
                        id = settings.Id,
                        name = name,
                        fileName = name,
                        scriptPath = self.File:NormalizePath(path),
                        settingsPath = settingsPath,
                        settings = settings
                    }
                end
            end
        end
    end
    table.sort(templates, function(a, b)
        local aOrder = tonumber(a.settings.Order) or math.huge
        local bOrder = tonumber(b.settings.Order) or math.huge
        if aOrder ~= bOrder then return aOrder < bOrder end
        return a.settings.Caption:lower() < b.settings.Caption:lower()
    end)
    self.Log:InfoF("[Registry] Discovered %d valid template(s).", #templates)
    return templates
end

function Registry:Adopt(definitions)
    self.Definitions = definitions or {}
    self.ById, self.ByCaption = {}, {}
    for _, template in ipairs(self.Definitions) do
        self.ById[template.id] = template
        self.ByCaption[template.settings.Caption] = template
    end
end

function Registry:GetDefinitions() return self.Definitions end
function Registry:FindById(id) return self.ById[id] end
function Registry:FindByCaption(caption) return self.ByCaption[caption] end

--
--- Validates captions and shortcuts across a definition set and produces the
--- registration order. Returns plan, err.
--
function Registry:CreateRegistrationPlan(definitions)
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
                self.Log:Warning(string.format(
                    "[Registry] Shortcut '%s' for '%s' conflicts with '%s' and was disabled.",
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

-- Validation report ----------------------------------------------------------

local function findIncludes(nodes)
    local includes = {}
    for _, node in ipairs(nodes or {}) do
        if node.kind == "expr" or node.kind == "code" then
            for name in node.code:gmatch("include%s*%(%s*[\"']([^\"']+)[\"']") do
                includes[#includes + 1] = { Name = name, Line = node.line }
            end
        end
    end
    return includes
end

--
--- Validates every candidate template without touching the active set:
--- settings schema, template syntax, includes, Requires against the context
--- registry, and referenced identifiers (warnings only). Returns a report:
--- { { Template, Id, Errors = {...}, Warnings = {...} }, ... }
--
function Registry:ValidateAll(definitions, engine, contextRegistry)
    local report = {}
    for _, template in ipairs(definitions or {}) do
        local entry = { Template = template.settings.Caption, Id = template.id, Errors = {}, Warnings = {} }
        report[#report + 1] = entry
        local source, readErr = self.File:ReadFile(template.scriptPath)
        if not source then
            entry.Errors[#entry.Errors + 1] = "Template file unreadable: " .. tostring(readErr)
        else
            local nodes, parseErr = engine:Parse(source, template.scriptPath)
            if not nodes then
                entry.Errors[#entry.Errors + 1] = tostring(parseErr.Message)
                    .. (parseErr.Line and (" (line " .. parseErr.Line .. ")") or "")
            else
                local compiled, compileErr = engine:CompileAst(nodes, template.scriptPath)
                if not compiled then
                    entry.Errors[#entry.Errors + 1] = tostring(compileErr.Message)
                        .. (compileErr.Line and (" (line " .. compileErr.Line .. ")") or "")
                end
                for _, include in ipairs(findIncludes(nodes)) do
                    local resolved = engine:ResolveIncludePath(include.Name)
                    if not resolved then
                        entry.Errors[#entry.Errors + 1] = string.format(
                            "Included template '%s' not found (line %d)", include.Name, include.Line)
                    end
                end
                local inputNames = {}
                for _, input in ipairs(template.settings.Inputs or {}) do
                    inputNames[input.Name] = true
                    if contextRegistry:IsKnown(input.Name) then
                        entry.Warnings[#entry.Warnings + 1] = string.format(
                            "Input '%s' shadows a provider variable of the same name", input.Name)
                    end
                end
                local helpers = {}
                for name in pairs(engine.Helpers) do helpers[name] = true end
                for name, line in pairs(engine:AnalyzeIdentifiers(nodes)) do
                    if not contextRegistry:IsKnown(name) and not inputNames[name]
                        and not helpers[name] and name ~= "include" and name ~= "_safe"
                        and name ~= "TemplateSettings" and name ~= "FinalCompilation"
                        and rawget(_G, name) == nil then
                        entry.Warnings[#entry.Warnings + 1] = string.format(
                            "Unknown identifier '%s' on line %d, resolves to nil or empty", name, line)
                    end
                end
            end
        end
        for _, required in ipairs(template.settings.Requires or {}) do
            if not contextRegistry:IsKnown(required) then
                entry.Errors[#entry.Errors + 1] = string.format(
                    "Requires unknown context variable '%s'", required)
            end
        end
        for _, optional in ipairs(template.settings.Optional or {}) do
            if not contextRegistry:IsKnown(optional) then
                entry.Warnings[#entry.Warnings + 1] = string.format(
                    "Optional context variable '%s' is not provided by any provider", optional)
            end
        end
    end
    return report
end

return Registry