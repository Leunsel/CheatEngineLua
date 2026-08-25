--[[
    Structured error model for the Template Loader.

    Every pipeline failure is described by one table instead of a free-form
    string, so logs, dialogs and diagnostics can all render the same facts.
    Errors.Format produces the human-readable multi-line message shown to the
    user. tostring(err) yields a compact single line for logs.
]]

local Errors = {}

Errors.Codes = {
    TEMPLATE_NOT_FOUND        = "TEMPLATE_NOT_FOUND",
    TEMPLATE_READ_FAILED      = "TEMPLATE_READ_FAILED",
    TEMPLATE_SYNTAX           = "TEMPLATE_SYNTAX",
    TEMPLATE_RUNTIME          = "TEMPLATE_RUNTIME",
    INCLUDE_NOT_FOUND         = "INCLUDE_NOT_FOUND",
    INCLUDE_CYCLE             = "INCLUDE_CYCLE",
    SETTINGS_INVALID          = "SETTINGS_INVALID",
    INPUT_INVALID             = "INPUT_INVALID",
    INPUT_CANCELLED           = "INPUT_CANCELLED",
    CONTEXT_RESOLUTION_FAILED = "CONTEXT_RESOLUTION_FAILED",
    CONTEXT_CYCLE             = "CONTEXT_CYCLE",
    REQUIREMENT_MISSING       = "REQUIREMENT_MISSING",
    ARCHITECTURE_MISMATCH     = "ARCHITECTURE_MISMATCH",
    OUTPUT_INVALID            = "OUTPUT_INVALID",
    APPLY_FAILED              = "APPLY_FAILED",
    REGISTRATION_FAILED       = "REGISTRATION_FAILED",
    RELOAD_FAILED             = "RELOAD_FAILED",
    CONFIG_INVALID            = "CONFIG_INVALID",
    INTERNAL                  = "INTERNAL"
}

Errors.Stages = {
    Discovery  = "Discovery",
    Settings   = "Settings",
    Validation = "Validation",
    Inputs     = "Inputs",
    Context    = "Context",
    Render     = "Render",
    Output     = "Output",
    Apply      = "Apply",
    Reload     = "Reload",
    Config     = "Config"
}

local errorMeta = {
    __tostring = function(err)
        local parts = { "[" .. tostring(err.Code or Errors.Codes.INTERNAL) .. "]" }
        if err.Stage then parts[#parts + 1] = "(" .. tostring(err.Stage) .. ")" end
        if err.Template then parts[#parts + 1] = "'" .. tostring(err.Template) .. "'" end
        parts[#parts + 1] = tostring(err.Message or "unknown error")
        if err.Variable then parts[#parts + 1] = "variable=" .. tostring(err.Variable) end
        if err.Line then parts[#parts + 1] = "line=" .. tostring(err.Line) end
        if err.Cause then parts[#parts + 1] = "cause=" .. tostring(err.Cause) end
        return table.concat(parts, " ")
    end
}

--
--- Creates a structured error. Accepted fields:
--- Code, Stage, Template, Source, Line, Expression, Variable, Provider,
--- Message, Cause, Hint, Instruction
--
function Errors.New(fields)
    local err = {}
    for key, value in pairs(fields or {}) do err[key] = value end
    err.Code = err.Code or Errors.Codes.INTERNAL
    err.Message = err.Message or "Unknown error"
    err.IsTemplateLoaderError = true
    return setmetatable(err, errorMeta)
end

function Errors.Is(value)
    return type(value) == "table" and value.IsTemplateLoaderError == true
end

--
--- Wraps an arbitrary pcall result into a structured error. Existing
--- structured errors pass through unchanged so context is never lost.
--
function Errors.Wrap(value, defaults)
    if Errors.Is(value) then
        for key, defaultValue in pairs(defaults or {}) do
            if value[key] == nil then value[key] = defaultValue end
        end
        return value
    end
    local fields = {}
    for key, defaultValue in pairs(defaults or {}) do fields[key] = defaultValue end
    fields.Message = fields.Message or tostring(value)
    if fields.Message ~= tostring(value) then fields.Cause = tostring(value) end
    return Errors.New(fields)
end

local function appendField(lines, label, value)
    if value ~= nil and value ~= "" then
        lines[#lines + 1] = label .. ":"
        lines[#lines + 1] = tostring(value)
        lines[#lines + 1] = ""
    end
end

--
--- The full multi-line report used in error dialogs. Only fields that are
--- actually set appear, so a simple failure stays a simple message.
--
function Errors.Format(err)
    if not Errors.Is(err) then return tostring(err) end
    local lines = { "Template generation failed", "" }
    if err.Stage == Errors.Stages.Reload then lines[1] = "Template reload failed" end
    if err.Stage == Errors.Stages.Config then lines[1] = "Configuration error" end
    appendField(lines, "Template", err.Template)
    appendField(lines, "Source", err.Source)
    appendField(lines, "Line", err.Line)
    appendField(lines, "Expression", err.Expression)
    appendField(lines, "Variable", err.Variable)
    appendField(lines, "Provider", err.Provider)
    appendField(lines, "Instruction", err.Instruction)
    appendField(lines, "Reason", err.Message)
    if err.Cause and tostring(err.Cause) ~= tostring(err.Message) then
        appendField(lines, "Cause", err.Cause)
    end
    if err.Hint then
        lines[#lines + 1] = tostring(err.Hint)
        lines[#lines + 1] = ""
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    return table.concat(lines, "\n")
end

return Errors