--[[
    Generation pipeline.

    One generation runs:
        resolve template -> validate template -> collect inputs
        -> build isolated context -> resolve required variables
        -> render into a buffer -> validate output -> commit to editor

    The Auto Assembler editor is only touched in the very last step. Any
    failure before that leaves the editor exactly as it was, that rule is
    not optional. A cancelled prompt (address, hook name, inputs) aborts
    silently. A real failure produces one structured error dialog.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Generator = {}
Generator.__index = Generator

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

--- Standard library subset available to restricted (schema 2) templates.
--- The library tables are copied per generation so template code assigning
--- into string/math/table cannot pollute the shared Lua state.
local function safeStdlib()
    return {
        string = shallowCopy(string), math = shallowCopy(math), table = shallowCopy(table),
        ipairs = ipairs, pairs = pairs, tonumber = tonumber,
        tostring = tostring, select = select
    }
end

function Generator:New(services)
    return setmetatable({
        CE = services.CE,
        Log = services.Log,
        Config = services.Config,
        Engine = services.Engine,
        ContextRegistry = services.ContextRegistry,
        Extensions = services.Extensions,
        Inputs = services.Inputs,
        UI = nil,          -- attached by the runtime after UI exists
        OnGenerated = nil, -- runtime callback (recent list)
        GenerationCounter = 0
    }, Generator)
end

-- Support --------------------------------------------------------------------

function Generator:_BuildTemplateSettingsView(settings)
    -- Templates read << TemplateSettings >> fields by their 2.x names, so the
    -- view carries the author's custom fields, the normalized fields and the
    -- legacy spellings.
    local view = {}
    for key, value in pairs(settings.Custom or {}) do view[key] = value end
    for key, value in pairs(settings) do
        if key ~= "Custom" then view[key] = value end
    end
    view.SubMenuName = settings.Category
    view.MenuOrder = settings.Order
    for key, value in pairs(settings.MemoryOverrides or {}) do view[key] = value end
    return view
end

function Generator:_ReportError(template, err)
    if Errors.Is(err) and err.Code == Errors.Codes.INPUT_CANCELLED then
        self.Log:Info("[Generator] Generation cancelled by the user.")
        return
    end
    local caption = template and template.settings and template.settings.Caption or "Template"
    if Errors.Is(err) and err.Template == nil then err.Template = caption end
    local text = Errors.Format(err)
    self.Log:Error("[Generator] " .. tostring(err))
    local ce = self.CE
    ce:RunInMain(function()
        ce:MessageDialog(text, rawget(_G, "mtError") or 1, rawget(_G, "mbOK") or 2)
    end)
end

function Generator:_ApplyToEditor(text, script)
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
    if not ok then return false, err end
    return true
end

function Generator:_CheckArchitecture(settings)
    if not settings.Architectures then return true end
    local target = self.CE:IsTarget64Bit() and "x64" or "x86"
    if settings.Architectures[target] then return true end
    local supported = {}
    for arch in pairs(settings.Architectures) do supported[#supported + 1] = arch end
    table.sort(supported)
    return nil, Errors.New{
        Code = Errors.Codes.ARCHITECTURE_MISMATCH, Stage = Errors.Stages.Validation,
        Template = settings.Caption,
        Message = string.format("This template supports %s, but the attached process is %s.",
            table.concat(supported, "/"), target)
    }
end

function Generator:_CheckCapabilities(settings)
    for _, capability in ipairs(settings.Capabilities or {}) do
        local available = self.Extensions:CheckCapability(capability)
        if available == false then
            self.Log:ForceWarningF(
                "[Generator] Template '%s' declares capability '%s', which is not available. The generated script may not assemble.",
                settings.Caption, capability)
        elseif available == nil then
            self.Log:InfoF("[Generator] Template '%s' declares capability '%s' (availability unknown).",
                settings.Caption, capability)
        end
    end
end

function Generator:_ValidateOutput(template, text)
    if text == "" then
        return nil, Errors.New{
            Code = Errors.Codes.OUTPUT_INVALID, Stage = Errors.Stages.Output,
            Template = template.settings.Caption, Source = template.scriptPath,
            Message = "The template rendered no text"
        }
    end
    if not text:find("%[ENABLE%]") then
        self.Log:Debug("[Generator] Rendered script has no [ENABLE] section (fine for fragments).")
    end
    if self.Config.Data.Generation.ValidateOutput then
        local ok, message = self.CE:AutoAssembleCheck(text, true)
        if ok == false then
            return nil, Errors.New{
                Code = Errors.Codes.OUTPUT_INVALID, Stage = Errors.Stages.Output,
                Template = template.settings.Caption, Source = template.scriptPath,
                Message = "Cheat Engine's syntax check rejected the generated script",
                Cause = message,
                Hint = "Output validation runs custom Auto Assembler commands. Disable it under Template Loader > Settings > Generation if that is unwanted."
            }
        end
    end
    return true
end

local function hookVeto(reason)
    return Errors.New{
        Code = Errors.Codes.INTERNAL, Stage = Errors.Stages.Render,
        Message = tostring(reason)
    }
end

-- Pipeline -------------------------------------------------------------------

function Generator:_RunPipeline(template, script, form)
    local settings = template.settings
    local stages = {}
    local function timed(name, fn, ...)
        local started = os.clock()
        local a, b = fn(...)
        stages[#stages + 1] = { Name = name, Ms = (os.clock() - started) * 1000 }
        return a, b
    end
    -- 1) Architecture and capability gates. Cheapest checks first.
    local ok, err = self:_CheckArchitecture(settings)
    if not ok then return nil, err end
    self:_CheckCapabilities(settings)
    -- 2) Validate the template BEFORE any prompt or process access.
    local hookOk, hookReason = self.Extensions:RunHook("BeforeTemplateValidation", { Template = template })
    if not hookOk then return nil, hookVeto(hookReason) end
    local compiled
    compiled, err = timed("Template validation", function()
        return self.Engine:GetCompiledFile(template.scriptPath)
    end)
    if not compiled then return nil, err end
    self.Extensions:RunHook("AfterTemplateValidation", { Template = template, Compiled = compiled })
    -- 3) User inputs, then the classic prompts (via the context prelude).
    local inputValues
    inputValues, err = timed("Inputs", function()
        return self.Inputs:Collect(settings.Inputs, settings.Caption)
    end)
    if not inputValues then return nil, err end
    -- 4) Isolated per-generation context.
    self.GenerationCounter = self.GenerationCounter + 1
    local generationId = self.GenerationCounter
    local context = self.ContextRegistry:NewContext{
        Options = self.Config:GetMemoryOptions(settings.MemoryOverrides),
        Settings = settings,
        Form = form,
        GenerationId = generationId,
        Template = settings.Caption
    }
    for name, value in pairs(inputValues) do context:Set(name, value) end
    context:Set("TemplateSettings", self:_BuildTemplateSettingsView(settings))
    context:Set("FinalCompilation", false)
    hookOk, hookReason = self.Extensions:RunHook("BeforeContextResolution", { Template = template, Context = context })
    if not hookOk then return nil, hookVeto(hookReason) end
    -- 5) The render environment exists BEFORE contract resolution so that
    -- render-dependent variables (Header) are legal in Requires/Optional.
    local base = safeStdlib()
    for key, value in pairs(self.Engine.Helpers) do base[key] = value end
    for key, value in pairs(self.Extensions.Helpers) do base[key] = value end
    local env = context:BuildEnvironment(base, settings.AllowUnsafeGlobals)
    self.Engine:PrepareEnvironment(env)
    context.Environment = env
    -- 6) Contract resolution. Schema-2 templates resolve exactly what they
    -- declare. Legacy templates get the classic 2.x prelude, address, then
    -- module validation, then the hook-name prompt, so prompts appear in
    -- the familiar order and fail-fast checks run before any prompt answers
    -- are wasted.
    local resolvedOk
    resolvedOk, err = timed("Context resolution", function()
        if #(settings.Requires or {}) > 0 or settings.SchemaVersion >= 2 then
            local requiredOk, requiredErr = context:ResolveRequired(settings.Requires)
            if not requiredOk then return nil, requiredErr end
        else
            for _, name in ipairs({ "Address", "Module", "HookName" }) do
                local _, resolveErr = context:Resolve(name)
                if resolveErr then return nil, resolveErr end
            end
        end
        for _, name in ipairs(settings.Optional or {}) do
            local _, optionalErr = context:Resolve(name)
            if optionalErr then
                if Errors.Is(optionalErr) and optionalErr.Code == Errors.Codes.INPUT_CANCELLED then
                    return nil, optionalErr
                end
                self.Log:Warning("[Generator] Optional variable '" .. name .. "' failed: " .. tostring(optionalErr))
                -- Optional means the template may read it. Degrade the stored
                -- failure to nil so an access renders "" instead of aborting.
                context:Downgrade(name)
            end
        end
        return true
    end)
    if not resolvedOk then return nil, err end
    self.Extensions:RunHook("AfterContextResolution", { Template = template, Context = context })
    -- 7) Render into a buffer. The editor is untouched during all of this.
    hookOk, hookReason = self.Extensions:RunHook("BeforeRender", { Template = template, Context = context })
    if not hookOk then return nil, hookVeto(hookReason) end
    local text
    text, err = timed("Render", function()
        return self.Engine:Render(compiled, env)
    end)
    if not text then
        if Errors.Is(err) and err.Template == nil then err.Template = settings.Caption end
        return nil, err
    end
    self.Extensions:RunHook("AfterRender", { Template = template, Context = context, Text = text })
    -- 7) Output validation, still buffer-only.
    local outputOk
    outputOk, err = timed("Output validation", function()
        return self:_ValidateOutput(template, text)
    end)
    if not outputOk then return nil, err end
    return { Text = text, Context = context, Stages = stages, GenerationId = generationId }
end

--
--- Runs a full generation and commits the result to the editor. "script" is
--- the TStrings Cheat Engine hands to a template callback. "form" is the
--- generating Auto Assembler window (may be nil for legacy callers).
--- Returns applied, cancelled: a user who cancels a prompt, an input dialog
--- or the preview is not a failure and must not surface as one in the logs
--- or the diagnostic report.
--
function Generator:Generate(template, script, form)
    local started = os.clock()
    local result, err = self:_RunPipeline(template, script, form)
    if not result then
        self:_ReportError(template, err)
        local cancelled = Errors.Is(err) and err.Code == Errors.Codes.INPUT_CANCELLED
        return false, cancelled
    end
    -- Optional preview: show the text and let the user decide. Closing the
    -- preview aborts with the editor untouched.
    if self.Config.Data.Generation.PreviewBeforeApply and self.UI then
        local accepted = self.UI:ShowPreview(template.settings.Caption, result.Text)
        if not accepted then
            self.Log:Info("[Generator] Preview dismissed. Nothing was applied.")
            return false, true
        end
    end
    local hookOk, hookReason = self.Extensions:RunHook("BeforeApply",
        { Template = template, Context = result.Context, Text = result.Text })
    if not hookOk then
        self:_ReportError(template, hookVeto(hookReason))
        return false
    end
    local applied, applyErr = self.CE:RunInMain(function()
        return self:_ApplyToEditor(result.Text, script)
    end)
    if not applied then
        self:_ReportError(template, Errors.New{
            Code = Errors.Codes.APPLY_FAILED, Stage = Errors.Stages.Apply,
            Template = template.settings.Caption,
            Message = "Could not write the generated script into the editor",
            Cause = applyErr
        })
        return false
    end
    self.Extensions:RunHook("AfterApply", { Template = template, Context = result.Context, Text = result.Text })
    local total = (os.clock() - started) * 1000
    if self.Log:GetLogLevel() <= self.Log.LogLevel.DEBUG then
        local lines = {}
        for _, stage in ipairs(result.Stages) do
            lines[#lines + 1] = string.format("  %s: %.1f ms", stage.Name, stage.Ms)
        end
        self.Log:Debug(string.format("[Generator] '%s' generated in %.1f ms (generation %d)\n%s",
            template.settings.Caption, total, result.GenerationId, table.concat(lines, "\n")),
            { generation = result.GenerationId, template = template.settings.Caption })
    end
    if self.OnGenerated then pcall(self.OnGenerated, template) end
    return true
end

--
--- Renders without applying, the "Generate preview" path and the
--- self-check both use this. Returns text, err.
--
function Generator:RenderOnly(template, form)
    local result, err = self:_RunPipeline(template, nil, form)
    if not result then return nil, err end
    return result.Text
end

return Generator