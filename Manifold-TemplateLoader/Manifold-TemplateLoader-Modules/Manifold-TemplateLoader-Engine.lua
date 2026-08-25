--[[
    Template engine: tokenizer, parser, compiler and renderer for .CEA
    templates.

    Syntax (unchanged from 2.x):
        << expression >>   evaluate a Lua expression, insert the result
        <% lua code %>     execute Lua statements, insert nothing

    New over 2.x:
      * a real parse step with per-node line numbers,
      * compiled chunks are cached per file (mtime+size fingerprint) and
        re-bound to a fresh environment per render instead of being
        recompiled on every menu click,
      * include("Name") renders a partial with the same context (cycle-safe),
      * runtime errors are mapped back to the template line that caused them.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Engine = {}
Engine.__index = Engine

Engine.MaxIncludeDepth = 16

local LUA_KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true
}

--- Safe helper functions exposed to every template.
Engine.Helpers = {
    hex = function(value)
        local number = tonumber(value)
        if number then
            -- %X raises on non-integer floats in Lua 5.3. A helper must
            -- degrade, not blow up the render.
            return string.format("%X", math.floor(number))
        end
        return tostring(value or "")
    end,
    join = function(separator, ...)
        local parts = {}
        for index = 1, select("#", ...) do
            local value = select(index, ...)
            if value ~= nil and value ~= "" then parts[#parts + 1] = tostring(value) end
        end
        return table.concat(parts, tostring(separator or ""))
    end,
    default = function(value, fallback)
        if value == nil or value == "" then return fallback end
        return value
    end,
    isEmpty = function(value)
        return value == nil or value == ""
    end,
    trim = function(value)
        return type(value) == "string" and value:match("^%s*(.-)%s*$") or value
    end
}

function Engine:New(services)
    return setmetatable({
        File = services.File,
        Log = services.Log,
        TemplateFolder = services.TemplateFolder,
        ScriptExtension = services.ScriptExtension or ".CEA",
        Cache = {}
    }, Engine)
end

function Engine:SetTemplateFolder(folder)
    self.TemplateFolder = folder
end

function Engine:InvalidateCache()
    self.Cache = {}
end

-- Parsing --------------------------------------------------------------------

local function countLines(text)
    local _, count = text:gsub("\n", "")
    return count
end

--
--- Parses template source into a node list. Each node carries the template
--- line it starts on:
---   { kind = "text"|"expr"|"code", text|code = ..., line = n }
--
function Engine:Parse(source, sourceName)
    if type(source) ~= "string" then
        return nil, Errors.New{
            Code = Errors.Codes.TEMPLATE_SYNTAX, Stage = Errors.Stages.Validation,
            Source = sourceName, Message = "Template source must be a string"
        }
    end
    if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
    local nodes, position, line, length = {}, 1, 1, #source
    while position <= length do
        local expressionStart = source:find("<<", position, true)
        local codeStart = source:find("<%", position, true)
        local start = expressionStart
        if codeStart and (not start or codeStart < start) then start = codeStart end
        if not start then
            local text = source:sub(position)
            if text ~= "" then nodes[#nodes + 1] = { kind = "text", text = text, line = line } end
            break
        end
        local leading = source:sub(position, start - 1)
        if leading ~= "" then
            nodes[#nodes + 1] = { kind = "text", text = leading, line = line }
            line = line + countLines(leading)
        end
        local tag = source:sub(start, start + 1)
        local closeTag = tag == "<<" and ">>" or "%>"
        local contentStart = start + 2
        local closeStart = source:find(closeTag, contentStart, true)
        if not closeStart then
            return nil, Errors.New{
                Code = Errors.Codes.TEMPLATE_SYNTAX, Stage = Errors.Stages.Validation,
                Source = sourceName, Line = line,
                Message = string.format("Unclosed %s block (expected %s)", tag, closeTag)
            }
        end
        local content = source:sub(contentStart, closeStart - 1)
        if tag == "<<" then
            local trimmed = content:match("^%s*(.-)%s*$")
            if trimmed == "" then
                return nil, Errors.New{
                    Code = Errors.Codes.TEMPLATE_SYNTAX, Stage = Errors.Stages.Validation,
                    Source = sourceName, Line = line,
                    Message = "Empty << >> expression block"
                }
            end
            nodes[#nodes + 1] = { kind = "expr", code = trimmed, line = line }
        else
            nodes[#nodes + 1] = { kind = "code", code = content, line = line }
        end
        line = line + countLines(source:sub(start, closeStart + 1))
        position = closeStart + 2
    end
    return nodes
end

-- Compilation ----------------------------------------------------------------

--
--- %q escapes a newline as backslash-newline, which would make one text node
--- span several generated lines and break the line map. Rewrite those to \n.
--
local function quoteSingleLine(text)
    return string.format("%q", text):gsub("\\\n", "\\n"):gsub("\r", "\\r")
end

--
--- Compiles a node list into a reusable render function. The chunk is
--- compiled once. Every render passes a fresh environment table as its
--- argument (the "local _ENV = ..." line rebinds all global accesses).
--- Returns { Render = fn(env), Map = {generatedLine -> templateLine},
--- Source = sourceName, Ast = nodes }.
--
function Engine:CompileAst(nodes, sourceName)
    local lines = { "local _ENV = ...", "local _ret = {}" }
    local map = {}
    local function emit(codeLine, templateLine)
        lines[#lines + 1] = codeLine
        map[#lines] = templateLine
    end
    for _, node in ipairs(nodes) do
        if node.kind == "text" then
            emit("_ret[#_ret + 1] = " .. quoteSingleLine(node.text), node.line)
        elseif node.kind == "expr" then
            local pieces = {}
            for piece in (node.code .. "\n"):gmatch("(.-)\n") do pieces[#pieces + 1] = piece end
            if #pieces <= 1 then
                emit(string.format("_ret[#_ret + 1] = _safe((%s), %d, %s)",
                    node.code, node.line, quoteSingleLine(node.code)), node.line)
            else
                emit(string.format("_ret[#_ret + 1] = _safe((%s", pieces[1]), node.line)
                for index = 2, #pieces - 1 do
                    emit(pieces[index], node.line + index - 1)
                end
                emit(string.format("%s), %d, %s)",
                    pieces[#pieces], node.line, quoteSingleLine(node.code:gsub("%s+", " "))),
                    node.line + #pieces - 1)
            end
        else -- code
            local offset = 0
            for piece in (node.code .. "\n"):gmatch("(.-)\n") do
                emit(piece, node.line + offset)
                offset = offset + 1
            end
        end
    end
    emit("return table.concat(_ret)", nodes[#nodes] and nodes[#nodes].line or 1)
    local chunkSource = table.concat(lines, "\n")
    local chunk, compileErr = load(chunkSource, "@" .. (sourceName or "template"), "t")
    if not chunk then
        -- load reports "sourceName:NN:", so map NN back to the template line.
        local generatedLine, message = tostring(compileErr):match(":(%d+):%s*(.*)$")
        local templateLine = generatedLine and map[tonumber(generatedLine)]
        return nil, Errors.New{
            Code = Errors.Codes.TEMPLATE_SYNTAX, Stage = Errors.Stages.Validation,
            Source = sourceName, Line = templateLine,
            Message = "Template syntax error: " .. tostring(message or compileErr)
        }
    end
    return { Render = chunk, Map = map, Source = sourceName, Ast = nodes }
end

function Engine:Compile(source, sourceName)
    local nodes, parseErr = self:Parse(source, sourceName)
    if not nodes then return nil, parseErr end
    return self:CompileAst(nodes, sourceName)
end

--
--- Compiled chunk for a file, cached against mtime+size. The cache survives
--- across generations. ReloadTemplates calls InvalidateCache so a reload can
--- never serve stale bytecode.
--
function Engine:GetCompiledFile(path)
    path = self.File:NormalizePath(path)
    if not path or not self.File:Exists(path) then
        return nil, Errors.New{
            Code = Errors.Codes.TEMPLATE_NOT_FOUND, Stage = Errors.Stages.Validation,
            Source = path, Message = "Template file was not found: " .. tostring(path)
        }
    end
    local mtime, size = self.File:Modified(path), self.File:Size(path)
    local cached = self.Cache[path]
    if cached and cached.Mtime == mtime and cached.Size == size then
        return cached.Compiled
    end
    local source, readErr = self.File:ReadFile(path)
    if not source then
        return nil, Errors.New{
            Code = Errors.Codes.TEMPLATE_READ_FAILED, Stage = Errors.Stages.Validation,
            Source = path, Message = tostring(readErr)
        }
    end
    local compiled, compileErr = self:Compile(source, path)
    if not compiled then return nil, compileErr end
    self.Cache[path] = { Mtime = mtime, Size = size, Compiled = compiled }
    return compiled
end

-- Rendering ------------------------------------------------------------------

function Engine:_TranslateRuntimeError(compiled, rawMessage)
    local text = tostring(rawMessage)
    local generatedLine, message = text:match(":(%d+):%s*(.*)$")
    local templateLine = generatedLine and compiled.Map[tonumber(generatedLine)]
    return Errors.New{
        Code = Errors.Codes.TEMPLATE_RUNTIME, Stage = Errors.Stages.Render,
        Source = compiled.Source, Line = templateLine,
        Message = "Template execution error: " .. tostring(message or text)
    }
end

--
--- Renders one compiled template with the given environment. The
--- environment must already carry _safe and (optionally) include. See
--- PrepareEnvironment. Structured errors raised inside resolvers pass
--- through untouched, plain Lua errors get their line mapped.
--
function Engine:Render(compiled, env)
    local ok, result = pcall(compiled.Render, env)
    if not ok then
        if Errors.Is(result) then
            if result.Source == nil then result.Source = compiled.Source end
            return nil, result
        end
        return nil, self:_TranslateRuntimeError(compiled, result)
    end
    if type(result) ~= "string" then
        return nil, Errors.New{
            Code = Errors.Codes.TEMPLATE_RUNTIME, Stage = Errors.Stages.Render,
            Source = compiled.Source, Message = "Template did not produce text"
        }
    end
    return result
end

function Engine:RenderFile(path, env)
    local compiled, err = self:GetCompiledFile(path)
    if not compiled then return nil, err end
    return self:Render(compiled, env)
end

--
--- Resolves an include name to a file path. Bare names get the script
--- extension appended. The Partials subfolder wins over the template root so
--- shared fragments can live apart from registered templates.
--
function Engine:ResolveIncludePath(name)
    if type(name) ~= "string" or name == "" then return nil, {} end
    local fileName = name
    if not fileName:lower():match("%.cea$") then fileName = fileName .. self.ScriptExtension end
    local candidates = {
        self.File:NormalizePath(self.TemplateFolder .. "/Partials/" .. fileName),
        self.File:NormalizePath(self.TemplateFolder .. "/" .. fileName)
    }
    for _, candidate in ipairs(candidates) do
        if candidate and self.File:Exists(candidate) then return candidate, candidates end
    end
    return nil, candidates
end

--
--- Installs _safe and include into an environment. "state" is shared across
--- nested includes of one render so cycles and depth are tracked per
--- generation, and diagnostics (empty expression values) reach the log.
--
function Engine:PrepareEnvironment(env, state)
    state = state or { Stack = {}, Depth = 0 }
    local log = self.Log
    rawset(env, "_safe", function(value, line, expression)
        if value == nil or value == "" then
            log:Debug(string.format("[Engine] << %s >> produced no text%s.",
                tostring(expression or "?"), line and (" (line " .. line .. ")") or ""))
        end
        return value == nil and "" or tostring(value)
    end)
    rawset(env, "include", function(name)
        local path, candidates = self:ResolveIncludePath(name)
        if not path then
            error(Errors.New{
                Code = Errors.Codes.INCLUDE_NOT_FOUND, Stage = Errors.Stages.Render,
                Message = string.format("Included template '%s' was not found. Looked in: %s",
                    tostring(name), table.concat(candidates, ", "))
            }, 0)
        end
        if state.Stack[path] then
            error(Errors.New{
                Code = Errors.Codes.INCLUDE_CYCLE, Stage = Errors.Stages.Render,
                Source = path,
                Message = "Include cycle detected: '" .. tostring(name) .. "' is already being rendered"
            }, 0)
        end
        if state.Depth >= Engine.MaxIncludeDepth then
            error(Errors.New{
                Code = Errors.Codes.INCLUDE_CYCLE, Stage = Errors.Stages.Render,
                Message = "Include depth limit (" .. Engine.MaxIncludeDepth .. ") exceeded"
            }, 0)
        end
        state.Stack[path] = true
        state.Depth = state.Depth + 1
        local text, err = self:RenderFile(path, env)
        state.Stack[path] = nil
        state.Depth = state.Depth - 1
        if not text then error(err, 0) end
        return text
    end)
    return env, state
end

-- Static analysis ------------------------------------------------------------

--
--- Best-effort set of identifiers a template references, used by "Validate
--- all templates" to flag names no provider, input or helper defines. Only
--- the first identifier of a dotted chain counts. String literals are
--- stripped first. Warnings only! Expressions are arbitrary Lua.
--
function Engine:AnalyzeIdentifiers(nodes)
    local seen, declared = {}, {}
    local cleaned = {}
    for _, node in ipairs(nodes or {}) do
        if node.kind == "expr" or node.kind == "code" then
            cleaned[#cleaned + 1] = {
                line = node.line,
                code = node.code
                    :gsub("%-%-[^\n]*", " ")
                    :gsub('"[^"]*"', " ")
                    :gsub("'[^']*'", " ")
            }
        end
    end
    -- Template code blocks share one chunk, so a "local" or a for-loop
    -- variable declared in one block is in scope for the expressions after
    -- it. Collect those declarations first and never report them.
    for _, entry in ipairs(cleaned) do
        for names in entry.code:gmatch("local%s+([%a_][%w_,%s]*)") do
            for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
        end
        for name in entry.code:gmatch("for%s+([%a_][%w_]*)%s*=") do
            declared[name] = true
        end
        for names in entry.code:gmatch("for%s+([%a_][%w_,%s]-)%s+in%s") do
            for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
        end
        for params in entry.code:gmatch("function%s*%(([^%)]*)%)") do
            for name in params:gmatch("[%a_][%w_]*") do declared[name] = true end
        end
    end
    for _, entry in ipairs(cleaned) do
        for prefix, name in entry.code:gmatch("([%.:]?)([%a_][%w_]*)") do
            if prefix == "" and not LUA_KEYWORDS[name] and not declared[name]
                and seen[name] == nil then
                seen[name] = entry.line
            end
        end
    end
    return seen
end

return Engine