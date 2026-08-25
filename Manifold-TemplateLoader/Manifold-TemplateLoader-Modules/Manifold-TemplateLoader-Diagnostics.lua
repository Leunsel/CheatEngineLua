--[[
    Diagnostics: the copyable report and the self-check.

    The report deliberately contains loader and target facts only. No user
    paths beyond the loader's own directories, no process memory, nothing
    sensitive to a bug report.
]]

local Diagnostics = {}
Diagnostics.__index = Diagnostics

function Diagnostics:New(services)
    return setmetatable({
        CE = services.CE,
        Log = services.Log,
        Version = services.Version,
        Paths = services.Paths
    }, Diagnostics)
end

local function line(list, label, value)
    list[#list + 1] = string.format("%-22s %s", label, tostring(value))
end

function Diagnostics:BuildReport(runtime)
    local ce = self.CE
    local lines = { "=== Manifold TemplateLoader Diagnostic Report ===", "" }
    line(lines, "Loader version:", self.Version.String())
    line(lines, "Cheat Engine:", ce:Call("getCEVersion") or "unknown")
    line(lines, "Target process:", ce:GetProcessName() or "<none>")
    line(lines, "Target architecture:", ce:GetProcessName() and (ce:IsTarget64Bit() and "x64" or "x86") or "n/a")
    lines[#lines + 1] = ""
    line(lines, "Runtime generation:", runtime.TemplateGeneration or 0)
    line(lines, "Loaded templates:", #(runtime.TemplateRegistry:GetDefinitions() or {}))
    line(lines, "Registered callbacks:", #(runtime.RegisteredTemplates or {}))
    line(lines, "Loaded providers:", table.concat(runtime.ContextRegistry:ListProviders(), ", "))
    local extensions = {}
    for _, extension in ipairs(runtime.Extensions:List()) do
        extensions[#extensions + 1] = extension.Name .. (extension.Version and (" " .. extension.Version) or "")
    end
    line(lines, "Loaded extensions:", #extensions > 0 and table.concat(extensions, ", ") or "<none>")
    line(lines, "Tracked AA windows:", #(runtime:GetTrackedForms() or {}))
    lines[#lines + 1] = ""
    line(lines, "Configuration path:", self.Paths.ConfigPath)
    line(lines, "Template path:", self.Paths.TemplateFolder)
    line(lines, "Log file:", self.Paths.LogFile)
    line(lines, "Logging level:", self.Log:GetLogLevelName())
    line(lines, "Config read-only:", runtime.Config.ReadOnly and "yes (newer or invalid file)" or "no")
    lines[#lines + 1] = ""
    line(lines, "Loader state:", runtime.State or "Idle")
    line(lines, "Last reload:", runtime.LastReloadStatus or "<none this session>")
    line(lines, "Last generation error:", runtime.LastGenerationError or "<none this session>")
    -- The variable reference comes straight from the registry metadata, so
    -- this listing can never drift from what providers actually register.
    lines[#lines + 1] = ""
    lines[#lines + 1] = "--- Context variables ---"
    local lastProvider
    for _, variable in ipairs(runtime.ContextRegistry:ListVariables()) do
        if variable.Provider ~= lastProvider then
            lastProvider = variable.Provider
            lines[#lines + 1] = ""
            lines[#lines + 1] = "[" .. tostring(variable.Provider) .. "]"
        end
        local dependencies = #variable.Dependencies > 0
            and ("  <- " .. table.concat(variable.Dependencies, ", ")) or ""
        lines[#lines + 1] = string.format("  %-24s %-8s %s%s",
            variable.Name, tostring(variable.Type or "?"),
            tostring(variable.Description or ""), dependencies)
    end
    return table.concat(lines, "\n")
end

--
--- Runs the in-CE self-check. Every check is independent. The result is a
--- list of { Name, Ok, Detail } plus an overall flag.
--
function Diagnostics:SelfCheck(runtime)
    local checks = {}
    local function check(name, fn)
        local ok, result, detail = pcall(fn)
        if not ok then
            checks[#checks + 1] = { Name = name, Ok = false, Detail = tostring(result) }
        else
            checks[#checks + 1] = { Name = name, Ok = result == true, Detail = detail }
        end
    end
    check("Runtime initialized", function()
        return runtime ~= nil and runtime.Generator ~= nil and runtime.Engine ~= nil
    end)
    check("Template folder exists", function()
        return runtime.File:FolderExists(self.Paths.TemplateFolder), self.Paths.TemplateFolder
    end)
    check("Configuration readable", function()
        return type(runtime.Config.Data) == "table" and not runtime.Config.ReadOnly,
            runtime.Config.ReadOnly and "read-only mode" or nil
    end)
    check("Template registry valid", function()
        local definitions = runtime.TemplateRegistry:GetDefinitions()
        local plan, err = runtime.TemplateRegistry:CreateRegistrationPlan(definitions)
        return plan ~= nil and #definitions > 0,
            err or (#definitions .. " template(s)")
    end)
    check("Providers valid / no circular dependencies", function()
        local ok, issues = runtime.ContextRegistry:Validate()
        return ok, not ok and table.concat(issues, "; ") or nil
    end)
    check("No duplicate template IDs", function()
        local seen = {}
        for _, template in ipairs(runtime.TemplateRegistry:GetDefinitions()) do
            if seen[template.id] then return false, "duplicate: " .. template.id end
            seen[template.id] = true
        end
        return true
    end)
    check("Template callbacks attached", function()
        local registered = #(runtime.RegisteredTemplates or {})
        local definitions = #(runtime.TemplateRegistry:GetDefinitions() or {})
        return registered == definitions,
            string.format("%d of %d registered", registered, definitions)
    end)
    check("Engine compiles a probe template", function()
        local compiled, err = runtime.Engine:Compile(
            "<% local x = 1 %><< x + 1 >>", "selfcheck-probe")
        if not compiled then return false, tostring(err) end
        local env = runtime.Engine:PrepareEnvironment({ table = table })
        local text, renderErr = runtime.Engine:Render(compiled, env)
        return text == "2", renderErr and tostring(renderErr) or nil
    end)
    local allOk = true
    for _, entry in ipairs(checks) do
        if not entry.Ok then allOk = false end
    end
    return allOk, checks
end

function Diagnostics:FormatSelfCheck(allOk, checks)
    local lines = { allOk and "Self-check passed." or "Self-check found problems:", "" }
    for _, entry in ipairs(checks) do
        lines[#lines + 1] = string.format("[%s] %s%s",
            entry.Ok and "OK" or "FAIL", entry.Name,
            entry.Detail and (" - " .. tostring(entry.Detail)) or "")
    end
    return table.concat(lines, "\n")
end

return Diagnostics