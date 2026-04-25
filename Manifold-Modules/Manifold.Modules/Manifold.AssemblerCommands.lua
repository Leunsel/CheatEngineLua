local NAME = "Manifold.AssemblerCommands.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.1.1"
local DESCRIPTION = "Manifold Framework Assembler Commands"

--[[
    ∂ v1.0.0 (2026-01-31)
        Initial release with core functions.

    ∂ v1.0.1 (2026-02-01)
        Minor changes to logging logic.

    ∂ v1.0.2 (2026-02-02)
        Added custom Manifold Assert Logic.

    ∂ v1.0.3 (2026-03-29)
        Added Manifold Resolve Static Command.
        Adjusted Resolve Static to read disp32 with readInteger (true) for signed value.

    ∂ v1.0.4 (2026-03-31)
        Added command argument validation and improved error handling with consistent logging.
        Adjusted logger calls to use structured formatting and included more debug info on errors.
        Added a few utility functions for argument parsing and validation to reduce code duplication and improve maintainability.
        Added some usage example comments.

    ∂ v1.0.5 (2026-04-15)
        Adjusted Logging.
        Added ManifoldPatch command for runtime patching with detailed logging of before/after bytes.
        Added ManifoldNop command for applying NOP patches with verification and logging.

    ∂ v1.1.0 (2026-04-20)
        Refactored command lifecycle, validation, and registration into shared helpers.
        Centralized patch/assert logic and reduced command-specific boilerplate for scalability.

    ∂ v1.1.1 (2026-04-25)
        Adjusted ManifoldScanModule module validation to check against loaded modules in attach context, not just main module name.
        There was no real module validation before, so this is a significant improvement to prevent CE from crashing.
]]--

AssemblerCommands = {
    LOG_SIG_MAX_INFO = 32,
    LOG_SIG_MAX_DEBUG = 64,
    DEFAULT_RESOLVE_STATIC_DISP_OFFSET = 3,
    DEFAULT_RESOLVE_STATIC_INSTR_LENGTH = 7,
    ActivePatches = nil
}
AssemblerCommands.__index = AssemblerCommands

local MODULE_PREFIX = "[Commands]"
local EMPTY_RESULT = ""

local COMMAND_SPECS = {
    { name = "ManifoldScanModule", factory = "_cmdManifoldScanModule" },
    { name = "ManifoldAssert", factory = "_cmdManifoldAssert" },
    { name = "ManifoldPatch", factory = "_cmdManifoldPatch" },
    { name = "ManifoldNop", factory = "_cmdManifoldNop" },
    { name = "ManifoldResolveStatic", factory = "_cmdManifoldResolveStatic" }
}

--
--- ∑ Creates a new AssemblerCommands instance, ensures dependencies are available,
---   and assigns module metadata.
--- @return table # Returns a new AssemblerCommands instance.
--
function AssemblerCommands:New()
    local instance = setmetatable({}, self)
    instance:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.Author = AUTHOR
    instance.Version = VERSION
    instance.Description = DESCRIPTION
    return instance
end
registerLuaFunctionHighlight('New')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Ensures a dependency exists globally, and attempts to load it if missing.
---   This helper keeps dependency bootstrapping centralized so other setup code
---   does not need to repeat the same CETrequire and logger guards.
--- @param dep table # {name = string, path = string, init = function|nil}
--- @return boolean # True if the dependency is available after this call.
--
function AssemblerCommands:_ensureDependency(dep)
    local depName = dep.name
    if _G[depName] ~= nil then
        if logger and logger.Debug then
            logger:Debug(string.format("%s Dependency '%s' is already loaded", MODULE_PREFIX, depName))
        end
        return true
    end
    if logger and logger.Warning then
        logger:Warning(string.format("%s '%s' dependency not found. Attempting to load...", MODULE_PREFIX, depName))
    end
    local success, result = pcall(CETrequire, dep.path)
    if not success then
        if logger and logger.Error then
            logger:Error(string.format("%s Failed to load dependency '%s': %s", MODULE_PREFIX, depName, tostring(result)))
        end
        return false
    end
    if dep.init then dep.init() end
    if logger and logger.Info then
        logger:Info(string.format("%s Loaded dependency '%s'.", MODULE_PREFIX, depName))
    end
    return true
end

--
--- ∑ Ensures all required global dependencies for this module are loaded.
---   This module currently only requires the logger, but keeping this as a table-
---   driven loader makes later growth predictable and avoids duplicated bootstrap code.
--- @return nil
--
function AssemblerCommands:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger", init = function() logger = Logger:New() end }
    }
    for _, dep in ipairs(dependencies) do
        self:_ensureDependency(dep)
    end
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- ∑ Trims leading and trailing whitespace from a value.
--- @param value any
--- @return string
--
function AssemblerCommands:_trim(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

--
--- ∑ Returns true if a value is nil or only contains whitespace.
--- @param value any
--- @return boolean
--
function AssemblerCommands:_isBlank(value)
    return value == nil or self:_trim(value) == ""
end

--
--- ∑ Removes surrounding single or double quotes from a value if present.
--- @param value any
--- @return string
--
function AssemblerCommands:_stripQuotes(value)
    local text = self:_trim(value or "")
    local first = text:sub(1, 1)
    local last = text:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        return text:sub(2, -2)
    end
    return text
end

--
--- ∑ Splits command parameters by commas while preserving quoted segments.
---   Auto Assembler command parameters are string-like, so this parser keeps
---   command handlers small and prevents each handler from reimplementing its own splitter.
--- @param parameters any
--- @return table # Parsed argument array.
--
function AssemblerCommands:_splitArgs(parameters)
    local source = tostring(parameters or "")
    local args, buffer = {}, {}
    local quote = nil
    local function push()
        args[#args + 1] = self:_trim(table.concat(buffer))
        buffer = {}
    end
    for i = 1, #source do
        local char = source:sub(i, i)
        if quote then
            buffer[#buffer + 1] = char
            if char == quote then
                quote = nil
            end
        else
            if char == '"' or char == "'" then
                quote = char
                buffer[#buffer + 1] = char
            elseif char == "," then
                push()
            else
                buffer[#buffer + 1] = char
            end
        end
    end
    push()
    return args
end

--
--- ∑ Parses decimal and common hex formats into a Lua number.
---   Supported examples: "123", "7B", "0x7B", "$7B", "#123".
--- @param value any
--- @return number|nil
--
function AssemblerCommands:_parseNumber(value)
    if value == nil then return nil end
    local text = self:_trim(value)
    if text == "" then return nil end
    local parsed = tonumber(text)
    if parsed ~= nil then return parsed end
    if text:match("^[%x]+$") then return tonumber(text, 16) end
    local upper = text:upper()
    if upper:sub(1, 1) == "$" then return tonumber(upper:sub(2), 16) end
    if upper:sub(1, 2) == "0X" then return tonumber(upper:sub(3), 16) end
    if upper:sub(1, 1) == "#" then return tonumber(upper:sub(2)) end
    return nil
end

--
--- ∑ Collapses whitespace and shortens a string for compact logs.
--- @param value any
--- @param maxLen number|nil
--- @return string
--
function AssemblerCommands:_shorten(value, maxLen)
    local text = tostring(value or ""):gsub("%s+", " ")
    local limit = maxLen or 50
    if #text <= limit then return text end
    return text:sub(1, limit) .. "..."
end

--
--- ∑ Creates a stable FNV-1a style identifier for a signature string.
---   The hash is used only for log readability, so repeated scan requests can
---   be correlated even when the full signature preview is truncated.
--- @param signature any
--- @return string
--
function AssemblerCommands:_sigId(signature)
    local text = tostring(signature or "")
    local hash = 2166136261
    for i = 1, #text do
        hash = hash ~ text:byte(i)
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08X", hash)
end

--
--- ∑ Builds a compact signature summary for log output.
--- @param signature any
--- @param maxLen number|nil
--- @return string
--
function AssemblerCommands:_sigSummary(signature, maxLen)
    local normalized = self:_stripQuotes(signature or "")
    local preview = self:_shorten(normalized, maxLen or self.LOG_SIG_MAX_INFO)
    return string.format("%s (len=%d) %s", self:_sigId(normalized), #normalized, preview)
end

--
--- ∑ Formats a debug dump of parsed arguments.
---   Keeping this centralized makes all command debug output look the same.
--- @param args table
--- @return string
--
function AssemblerCommands:_fmtArgDump(args)
    return string.format("args(count=%d)\n\t1=%s\n\t2=%s\n\t3=%s\n\t4=%s\n\t5=%s\n\t6=%s", #args, tostring(args[1]), tostring(args[2]), self:_shorten(args[3], 140), tostring(args[4]), tostring(args[5]), tostring(args[6]))
end

--
--- ∑ Logs and returns a consistent command error payload.
--- @param commandName string
--- @param message string
--- @return nil
--- @return string
--
function AssemblerCommands:_commandError(commandName, message)
    logger:Error(string.format("%s %s Error", MODULE_PREFIX, commandName))
    logger:ErrorF("%s   Reason: %s", MODULE_PREFIX, tostring(message))
    return nil, message
end

--
--- ∑ Creates a shared command context with phase logging and parsed arguments.
---   The main reason this exists is scalability: every command follows the same
---   lifecycle (name, args, syntaxcheck, logging), so the common start is centralized here.
--- @param commandName string
--- @param parameters any
--- @param syntaxcheck boolean
--- @return table
--
function AssemblerCommands:_beginCommand(commandName, parameters, syntaxcheck)
    local phase = syntaxcheck and "SYNTAXCHECK" or "EXECUTE"
    local args = self:_splitArgs(parameters)
    logger:Info(string.format("%s %s", MODULE_PREFIX, commandName))
    logger:InfoF("   Phase: %s", phase)
    if not syntaxcheck then
        logger:DebugF("   Parameters: %s", tostring(parameters))
        logger:DebugF("   Parsed Args:\n%s", self:_fmtArgDump(args))
    end
    return {
        Name = commandName,
        Parameters = parameters,
        Syntaxcheck = syntaxcheck == true,
        Phase = phase,
        Args = args
    }
end

--
--- ∑ Builds a default define() replacement for syntaxcheck mode.
---   Commands that emit a symbol during execution should still provide a harmless
---   placeholder in syntaxcheck so CE can parse the script without a real scan/resolve run.
--- @param symbol any
--- @return string
--
function AssemblerCommands:_syntaxDefine(symbol)
    return string.format("define(%s, %016X)", self:_stripQuotes(symbol), 0)
end

--
--- ∑ Reads a required argument or returns a consistent command-style error string.
--- @param args table
--- @param index number
--- @param commandName string
--- @param fieldName string
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_requireArg(args, index, commandName, fieldName)
    local value = args[index]
    if self:_isBlank(value) then
        return nil, string.format("%s: missing %s (Argument %d)", commandName, fieldName, index)
    end
    return value, nil
end

--
--- ∑ Validates an Auto Assembler define symbol name.
--- @param symbol any
--- @return boolean
--- @return string|nil
--
function AssemblerCommands:_isValidSymbolName(symbol)
    local normalized = self:_stripQuotes(symbol or "")
    if normalized == "" then return false, "symbol is empty" end
    if not normalized:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        return false, "symbol contains invalid characters"
    end
    return true, nil
end

--
--- ∑ Reads and validates a required symbol argument.
--- @param args table
--- @param index number
--- @param commandName string
--- @param fieldName string
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_requireSymbolArg(args, index, commandName, fieldName)
    local symbol, err = self:_requireArg(args, index, commandName, fieldName)
    if not symbol then return nil, err end
    local okSymbol, symbolErr = self:_isValidSymbolName(symbol)
    if not okSymbol then
        return nil, string.format("%s: invalid %s (Argument %d): %s", commandName, fieldName, index, tostring(symbolErr))
    end
    return self:_stripQuotes(symbol), nil
end

--
--- ∑ Parses an optional numeric command argument with a default fallback.
--- @param args table
--- @param index number
--- @param commandName string
--- @param fieldName string
--- @param defaultValue number|nil
--- @return number|nil
--- @return string|nil
--
function AssemblerCommands:_parseOptionalNumberArg(args, index, commandName, fieldName, defaultValue)
    local raw = args[index]
    if self:_isBlank(raw) then return defaultValue, nil end
    local parsed = self:_parseNumber(raw)
    if parsed == nil then
        return nil, string.format("%s: invalid %s (Argument %d): '%s'", commandName, fieldName, index, tostring(raw))
    end
    return parsed, nil
end

--
--- ∑ Parses a byte pattern with wildcard support.
---   Supported examples:
---     - Exact byte tokens: "7B", "0x7B", "$7B"
---     - Wildcards: "?", "??", "**", "?*", "*?"
--- @param pattern any
--- @return table|nil
--- @return string|nil
--
function AssemblerCommands:_parseBytesPattern(pattern)
    local text = self:_trim(self:_stripQuotes(pattern or ""))
    if text == "" then return nil, "empty bytes pattern" end
    local bytes = {}
    for token in text:gmatch("%S+") do
        local upper = token:upper()
        if upper == "?" or upper == "??" or upper == "**" or upper == "?*" or upper == "*?" then
            bytes[#bytes + 1] = nil
        elseif upper:match("^[0-9A-F][0-9A-F]$") then
            bytes[#bytes + 1] = tonumber(upper, 16)
        else
            return nil, "invalid byte token: " .. upper
        end
    end
    if #bytes == 0 then return nil, "empty bytes pattern" end
    return bytes, nil
end

--
--- ∑ Reads and validates a required bytes-pattern argument.
--- @param args table
--- @param index number
--- @param commandName string
--- @param fieldName string
--- @return table|nil
--- @return string|nil
--
function AssemblerCommands:_requireBytesPatternArg(args, index, commandName, fieldName)
    local pattern, err = self:_requireArg(args, index, commandName, fieldName)
    if not pattern then return nil, err end
    local bytes, patternErr = self:_parseBytesPattern(pattern)
    if not bytes then
        return nil, string.format("%s: invalid %s: %s", commandName, fieldName, tostring(patternErr))
    end
    return bytes, nil
end

--
--- ∑ Reads a byte range from memory using Cheat Engine's readBytes API.
--- @param addr number
--- @param count number
--- @return table|nil
--- @return string|nil
--
function AssemblerCommands:_readBytes(addr, count)
    local rb = rawget(_G, "readBytes")
    if type(rb) ~= "function" then return nil, "readBytes not available" end
    local ok, bytes = pcall(function() return rb(addr, count, true) end)
    if not ok then return nil, tostring(bytes) end
    if type(bytes) ~= "table" then return nil, "readBytes returned non-table" end
    return bytes, nil
end

--
--- ∑ Writes a byte array to memory, skipping wildcard entries (nil).
---   Wildcard-aware writing lets patch commands express partial edits without
---   rebuilding the untouched bytes in every command handler.
--- @param addr number
--- @param bytes table
--- @return boolean|nil
--- @return string|nil
--
function AssemblerCommands:_writeBytes(addr, bytes)
    local wb = rawget(_G, "writeBytes")
    if type(wb) ~= "function" then return nil, "writeBytes not available" end

    local ok, err = pcall(function()
        for index = 1, #bytes do
            local byte = bytes[index]
            if byte ~= nil then
                wb(addr + (index - 1), byte)
            end
        end
    end)

    if not ok then return nil, tostring(err) end
    return true
end

--
--- ∑ Creates a shallow sequential copy of an array-table.
--- @param values table
--- @return table
--
function AssemblerCommands:_copyArray(values)
    local out = {}
    for i = 1, #values do
        out[i] = values[i]
    end
    return out
end

--
--- ∑ Builds the effective bytes that will exist after a wildcard-aware patch.
---   This is used for logging, so users can see the real resulting bytes rather
---   than only the sparse patch pattern they provided.
--- @param actual table
--- @param patch table
--- @return table
--
function AssemblerCommands:_buildPatchedBytes(actual, patch)
    local out = {}
    for i = 1, #patch do
        out[i] = patch[i]
        if out[i] == nil then
            out[i] = actual[i]
        end
    end
    return out
end

--
--- ∑ Creates an array of NOP bytes (0x90) for the requested length.
--- @param count number
--- @return table|nil
--- @return string|nil
--
function AssemblerCommands:_buildNopBytes(count)
    if type(count) ~= "number" or count < 1 then
        return nil, "invalid nop byte count"
    end
    local out = {}
    for i = 1, count do
        out[i] = 0x90
    end
    return out, nil
end

--
--- ∑ Writes bytes and immediately verifies the result by reading them back.
---   Patch-oriented commands use this helper so verification and error formatting
---   remain consistent across apply and restore flows.
--- @param commandName string
--- @param addr number
--- @param bytesToWrite table
--- @param verifyLength number
--- @return table|nil # { Before = table, After = table }
--- @return string|nil
--
function AssemblerCommands:_applyBytesAndVerify(commandName, addr, bytesToWrite, verifyLength)
    local beforeBytes, beforeErr = self:_readBytes(addr, verifyLength)
    if not beforeBytes then
        return nil, string.format("%s: readBytes failed at %s: %s", commandName, getNameFromAddress(addr), tostring(beforeErr))
    end
    local okWrite, writeErr = self:_writeBytes(addr, bytesToWrite)
    if not okWrite then
        return nil, string.format("%s: writeBytes failed at %s: %s", commandName, getNameFromAddress(addr), tostring(writeErr))
    end
    local afterBytes, afterErr = self:_readBytes(addr, verifyLength)
    if not afterBytes then
        return nil, string.format("%s: verification read failed at %s: %s", commandName, getNameFromAddress(addr), tostring(afterErr))
    end
    return {
        Before = beforeBytes,
        After = afterBytes
    }, nil
end

--
--- ∑ Ensures the runtime patch store exists and returns it.
--- @return table
--
function AssemblerCommands:_ensurePatchStore()
    if type(self.ActivePatches) ~= "table" then
        self.ActivePatches = {}
    end
    return self.ActivePatches
end

--
--- ∑ Creates a stable patch key for a resolved address.
---   Patches are keyed by resolved address so restore operations stay simple and deterministic.
--- @param addr number
--- @return string
--
function AssemblerCommands:_makePatchKey(addr)
    if type(addr) ~= "number" then return "nil" end
    return string.format("0x%X", addr)
end

--
--- ∑ Stores a patch entry if one is not already present for the address.
--- @param addr number
--- @param originalBytes table
--- @param patchBytes table
--- @return string # Patch key
--
function AssemblerCommands:_storePatch(addr, originalBytes, patchBytes)
    local store = self:_ensurePatchStore()
    local key = self:_makePatchKey(addr)
    if store[key] == nil then
        store[key] = {
            Address = addr,
            Name = getNameFromAddress(addr),
            Key = key,
            OriginalBytes = originalBytes,
            PatchBytes = patchBytes,
            Length = #originalBytes
        }
    end
    return key
end

--
--- ∑ Resolves an address expression through CE helpers or numeric parsing.
--- @param expr any
--- @return number|nil
--- @return string|nil
--
function AssemblerCommands:_resolveAddress(expr)
    local text = self:_trim(self:_stripQuotes(expr or ""))
    if text == "" then return nil, "empty address expr" end

    local getAddressSafeFn = rawget(_G, "getAddressSafe")
    if type(getAddressSafeFn) == "function" then
        local ok, address = pcall(function() return getAddressSafeFn(text) end)
        if ok and address then return address, nil end
    end
    local getAddressFn = rawget(_G, "getAddress")
    if type(getAddressFn) == "function" then
        local ok, address = pcall(function() return getAddressFn(text) end)
        if ok and address then return address, nil end
        if not ok then return nil, tostring(address) end
    end
    local parsed = self:_parseNumber(text)
    if parsed ~= nil then return parsed, nil end
    return nil, "could not resolve address: " .. text
end

--
--- ∑ Checks whether a module argument can belong to the current attach context.
---   The main process module is valid, but loaded DLL modules are valid targets too.
--- @param moduleName any
--- @return boolean
--- @return string|nil
--
function AssemblerCommands:_isModuleSuitableForAttachContext(moduleName)
    local normalizedModule = self:_stripQuotes(moduleName)
    if normalizedModule == "" then return false, "moduleName empty" end
    if type(process) == "string" and process ~= "" and normalizedModule:lower() == process:lower() then
        return true, nil
    end
    local enumModulesFn = rawget(_G, "enumModules")
    if type(enumModulesFn) == "function" then
        local ok, modules = pcall(enumModulesFn)
        if not ok then return false, "module list could not be read: " .. tostring(modules) end
        local expected = normalizedModule:lower()
        for _, module in ipairs(modules or {}) do
            local moduleNameText = module and module.Name
            if type(moduleNameText) == "string" and moduleNameText:lower() == expected then
                return true, nil
            end
        end
        return false, "module ('" .. moduleName .. "') is not loaded in the current attach context"
    end
    local getAddressSafeFn = rawget(_G, "getAddressSafe")
    if type(getAddressSafeFn) == "function" then
        local ok, address = pcall(function() return getAddressSafeFn(normalizedModule) end)
        if ok and address then return true, nil end
        if not ok then return false, "module could not be resolved: " .. tostring(address) end
        return false, "module ('" .. moduleName .. "') is not loaded in the current attach context"
    end
    return true, nil
end

--
--- ∑ Reads and resolves a required address argument in one step.
---   This helper exists because almost every runtime command starts with the same
---   "read arg -> resolve address -> format error" flow.
--- @param args table
--- @param index number
--- @param commandName string
--- @param fieldName string
--- @return number|nil
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_requireResolvedAddressArg(args, index, commandName, fieldName)
    local expr, exprErr = self:_requireArg(args, index, commandName, fieldName)
    if not expr then return nil, nil, exprErr end
    local addr, resolveErr = self:_resolveAddress(expr)
    if not addr then
        return nil, expr, string.format("%s: cannot resolve %s '%s': %s", commandName, fieldName, tostring(expr), tostring(resolveErr))
    end
    return addr, expr, nil
end

--
--- ∑ Formats a byte array for log output, using ?? for wildcard entries.
--- @param bytes table
--- @return string
--
function AssemblerCommands:_fmtBytes(bytes)
    local parts = {}
    for i = 1, #bytes do
        local value = bytes[i]
        if value == nil then
            parts[#parts + 1] = "??"
        else
            parts[#parts + 1] = string.format("%02X", value)
        end
    end
    return table.concat(parts, " ")
end

--
--- ∑ Returns the first mismatch index between expected and actual bytes.
---   Expected nil entries are treated as wildcards and therefore ignored.
--- @param expected table
--- @param actual table
--- @return number|nil
--
function AssemblerCommands:_findPatternMismatch(expected, actual)
    for i = 1, #expected do
        local wanted = expected[i]
        if wanted ~= nil and actual[i] ~= wanted then
            return i
        end
    end
    return nil
end

--
--- ∑ Builds a visual pointer marker for mismatch logs.
--- @param index number|nil
--- @return string
--
function AssemblerCommands:_buildMismatchMarker(index)
    if type(index) ~= "number" or index < 1 then return "^" end
    return string.rep("---", index - 1) .. "^"
end

--
--- ∑ Logs the final result of an apply/restore patch operation.
--- @param commandName string
--- @param actionLabel string
--- @param key string
--- @param addr number
--- @param beforeBytes table
--- @param writeBytes table
--- @param afterBytes table
--- @param extraLogLines table|nil
--- @return nil
--
function AssemblerCommands:_logStoredPatchResult(commandName, actionLabel, key, addr, beforeBytes, writeBytes, afterBytes, extraLogLines)
    logger:Info(string.format("%s %s %s OK", MODULE_PREFIX, commandName, actionLabel))
    logger:InfoF("   Patch Key: %s", tostring(key))
    logger:InfoF("   Address  : %s", getNameFromAddress(addr))
    if type(extraLogLines) == "table" then
        for _, line in ipairs(extraLogLines) do
            logger:InfoF("   %s", tostring(line))
        end
    end
    logger:InfoF("   Before   : %s", self:_fmtBytes(beforeBytes))
    logger:InfoF("   %-8s : %s", tostring(actionLabel), self:_fmtBytes(writeBytes))
    logger:InfoF("   After    : %s", self:_fmtBytes(afterBytes))
end

--
--- ∑ Restores a previously stored patch for an address.
--- @param commandName string
--- @param addr number
--- @param key string
--- @param extraLogLines table|nil
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_restoreStoredPatch(commandName, addr, key, extraLogLines)
    local store = self:_ensurePatchStore()
    local entry = store[key]
    if not entry then
        return self:_commandError(commandName, string.format("%s: no stored patch found for %s", commandName, tostring(key)))
    end
    local result, restoreErr = self:_applyBytesAndVerify(commandName, addr, entry.OriginalBytes, entry.Length)
    if not result then
        return self:_commandError(commandName, restoreErr)
    end
    self:_logStoredPatchResult(commandName, "Restore", key, addr, result.Before, entry.OriginalBytes, result.After, extraLogLines)
    store[key] = nil
    return EMPTY_RESULT
end

--
--- ∑ Applies a stored patch workflow for an address and persists the original bytes.
--- @param commandName string
--- @param addr number
--- @param patchBytes table
--- @param extraLogLines table|nil
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_applyStoredPatch(commandName, addr, patchBytes, extraLogLines)
    local actualBefore, readErr = self:_readBytes(addr, #patchBytes)
    if not actualBefore then
        return self:_commandError(commandName, string.format("%s: readBytes failed at %s: %s", commandName, getNameFromAddress(addr), tostring(readErr)))
    end
    local patchKey = self:_storePatch(addr, self:_copyArray(actualBefore), self:_copyArray(patchBytes))
    local writeBytes = self:_buildPatchedBytes(actualBefore, patchBytes)
    local result, patchErr = self:_applyBytesAndVerify(commandName, addr, patchBytes, #patchBytes)
    if not result then
        return self:_commandError(commandName, patchErr)
    end
    self:_logStoredPatchResult(commandName, "Apply", patchKey, addr, result.Before, writeBytes, result.After, extraLogLines)
    return EMPTY_RESULT
end

--
--- ∑ Resolves a patch target, then applies or restores bytes depending on the input.
--- @param commandName string
--- @param addrExpr string
--- @param patchBytes table|nil
--- @param extraLogLines table|nil
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_executeStoredPatch(commandName, addrExpr, patchBytes, extraLogLines)
    local addr, resolveErr = self:_resolveAddress(addrExpr)
    if not addr then
        return self:_commandError(commandName, string.format("%s: cannot resolve address '%s': %s", commandName, tostring(addrExpr), tostring(resolveErr)))
    end
    local key = self:_makePatchKey(addr)
    if patchBytes == nil then
        return self:_restoreStoredPatch(commandName, addr, key, extraLogLines)
    end
    return self:_applyStoredPatch(commandName, addr, patchBytes, extraLogLines)
end

--
--- ∑ Performs a unique AOB scan within a module and logs both request and result.
---   This exists as a wrapper around the native scan call so users get consistent
---   diagnostics, signature summaries, and failure reasons without duplicating that logic.
--- @param moduleName string
--- @param signature string
--- @param protectionFlags number|nil
--- @param alignmentType number|nil
--- @param alignmentParam number|nil
--- @return number|nil
--- @return string|nil
--
function AssemblerCommands:_aobScanModuleUnique(moduleName, signature, protectionFlags, alignmentType, alignmentParam)
    local rawModule = moduleName
    local rawSignature = signature
    local normalizedModule = self:_stripQuotes(moduleName)
    local normalizedSignature = self:_stripQuotes(signature)
    local signatureId = self:_sigId(normalizedSignature)
    logger:Info(MODULE_PREFIX .. " Scan")
    logger:InfoF("    Module   : %s", tostring(normalizedModule))
    logger:InfoF("    Signature: %s", self:_sigSummary(normalizedSignature, self.LOG_SIG_MAX_INFO))
    logger:Debug(MODULE_PREFIX .. " Scan Request")
    logger:DebugF("   Module (Raw)   : %s", tostring(rawModule))
    logger:DebugF("   Signature (Raw): %s", self:_shorten(rawSignature, self.LOG_SIG_MAX_DEBUG))
    logger:DebugF("   Signature ID   : %s", tostring(signatureId))
    logger:DebugF("   Protection     : %s", tostring(protectionFlags))
    logger:DebugF("   Alignment Type : %s", tostring(alignmentType))
    logger:DebugF("   Alignment Param: %s", tostring(alignmentParam))
    if normalizedModule == "" then return nil, "moduleName empty" end
    if normalizedSignature == "" then return nil, "signature empty" end
    local moduleOk, moduleErr = self:_isModuleSuitableForAttachContext(normalizedModule)
    if not moduleOk then return nil, moduleErr end
    local fn = rawget(_G, "AOBScanModuleUnique")
    if type(fn) ~= "function" then return nil, "AOBScanModuleUnique not available" end
    local ok, addrOrErr = pcall(function()
        return fn(normalizedModule, normalizedSignature, protectionFlags, alignmentType, alignmentParam)
    end)
    if not ok then return nil, "AOBScanModuleUnique exception: " .. tostring(addrOrErr) end
    if not addrOrErr then return nil, "AOB not found or not unique" end
    logger:Info(MODULE_PREFIX .. " Scan Result")
    logger:Info("   Status      : OK")
    logger:InfoF("   Signature ID: %s", tostring(signatureId))
    logger:InfoF("   Address     : %s", getNameFromAddress(addrOrErr))
    return addrOrErr, nil
end

--
--- ∑ Registers one Auto Assembler command handler.
--- @param commandName string
--- @param handler function
--- @return boolean
--
function AssemblerCommands:_registerCommand(commandName, handler)
    local reg = rawget(_G, "registerAutoAssemblerCommand")
    if type(reg) ~= "function" then
        logger:ForceCritical(MODULE_PREFIX .. " registerAutoAssemblerCommand not available")
        return false
    end
    reg(commandName, handler)
    logger:InfoF("%s Registered Assembler Command: %s", MODULE_PREFIX, commandName)
    return true
end

--
--- ∑ Builds all command handlers declared in COMMAND_SPECS.
---   The table-driven approach is intentional: adding a new command should mostly
---   mean implementing one factory and listing it once here.
--- @return table
--
function AssemblerCommands:_buildCommandHandlers()
    local handlers = {}
    for _, spec in ipairs(COMMAND_SPECS) do
        handlers[#handlers + 1] = {
            name = spec.name,
            handler = self[spec.factory](self)
        }
    end
    return handlers
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldScanModule.
---   Why this command exists:
---     It wraps native module scanning with stricter validation and much better logs,
---     so signature-based hooks are easier to debug and maintain in larger tables.
---   Usage example:
---     ManifoldScanModule(ExampleHook, SomeGame.exe, E8 E0 01 02 00)
---   Result:
---     define(ExampleHook, SomeGame.exe+1255B5B)
--- @return function
--
function AssemblerCommands:_cmdManifoldScanModule()
    return function(parameters, syntaxcheck)
        local ctx = self:_beginCommand("ManifoldScanModule", parameters, syntaxcheck)
        if ctx.Syntaxcheck then
            return self:_syntaxDefine(ctx.Args[1] or "ManifoldScanModule_Symbol")
        end
        local symbol, symbolErr = self:_requireSymbolArg(ctx.Args, 1, ctx.Name, "symbol")
        if not symbol then return self:_commandError(ctx.Name, symbolErr) end
        local moduleName, moduleErr = self:_requireArg(ctx.Args, 2, ctx.Name, "module")
        if not moduleName then return self:_commandError(ctx.Name, moduleErr) end
        local signature, signatureErr = self:_requireArg(ctx.Args, 3, ctx.Name, "signature")
        if not signature then return self:_commandError(ctx.Name, signatureErr) end
        local protection, protectionErr = self:_parseOptionalNumberArg(ctx.Args, 4, ctx.Name, "protection", nil)
        if protectionErr then return self:_commandError(ctx.Name, protectionErr) end
        local alignType, alignTypeErr = self:_parseOptionalNumberArg(ctx.Args, 5, ctx.Name, "align type", nil)
        if alignTypeErr then return self:_commandError(ctx.Name, alignTypeErr) end
        local alignParam, alignParamErr = self:_parseOptionalNumberArg(ctx.Args, 6, ctx.Name, "align param", nil)
        if alignParamErr then return self:_commandError(ctx.Name, alignParamErr) end
        local addr, scanErr = self:_aobScanModuleUnique(moduleName, signature, protection, alignType, alignParam)
        if not addr then return self:_commandError(ctx.Name, scanErr) end
        local replace = string.format("define(%s, %s)", symbol, getNameFromAddress(addr))
        logger:InfoF("   Replace Line: %s", replace)
        return replace
    end
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldAssert.
---   Why this command exists:
---     Patch scripts often need a lightweight safety check before overwriting bytes.
---     This command verifies the current instruction bytes and reports detailed mismatches,
---     but intentionally does not hard-stop execution by itself.
---   Usage examples:
---     ManifoldAssert(ExampleHook, E8 E0 01 02 00)
---     ManifoldAssert(ExampleHook, E8 ?? ?? ?? ??)
---   Typical flow:
---     ManifoldScanModule(ExampleHook, SomeGame.exe, E8 E0 01 02 00)
---     ManifoldAssert(ExampleHook, E8 E0 01 02 00)
--- @return function
--
function AssemblerCommands:_cmdManifoldAssert()
    return function(parameters, syntaxcheck)
        local ctx = self:_beginCommand("ManifoldAssert", parameters, syntaxcheck)
        if ctx.Syntaxcheck then return EMPTY_RESULT end
        local addr, _, addrErr = self:_requireResolvedAddressArg(ctx.Args, 1, ctx.Name, "address")
        if not addr then return self:_commandError(ctx.Name, addrErr) end
        local expected, patternErr = self:_requireBytesPatternArg(ctx.Args, 2, ctx.Name, "bytes pattern")
        if not expected then return self:_commandError(ctx.Name, patternErr) end
        local actual, readErr = self:_readBytes(addr, #expected)
        if not actual then
            return self:_commandError(ctx.Name, string.format("%s: readBytes failed at %s: %s", ctx.Name, getNameFromAddress(addr), tostring(readErr)))
        end
        local mismatchAt = self:_findPatternMismatch(expected, actual)
        if mismatchAt then
            logger:ForceWarning(MODULE_PREFIX .. " ManifoldAssert mismatch")
            logger:ForceWarningF("   Address : %s", getNameFromAddress(addr))
            logger:ForceWarningF("   Expected: %s", self:_fmtBytes(expected))
            logger:ForceWarningF("   Actual  : %s", self:_fmtBytes(actual))
            logger:ForceWarningF("   %s%s", string.rep(" ", #"Actual  : "), self:_buildMismatchMarker(mismatchAt))
            logger:ForceWarningF("   First mismatch at +%X (index %d)", mismatchAt - 1, mismatchAt)
            return EMPTY_RESULT
        end
        logger:Info(MODULE_PREFIX .. " ManifoldAssert OK")
        logger:InfoF("   Address: %s", getNameFromAddress(addr))
        logger:InfoF("   Bytes  : %s", self:_fmtBytes(expected))
        return EMPTY_RESULT
    end
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldPatch.
---   Why this command exists:
---     Runtime patching is common, but manual patch/restore bookkeeping is repetitive.
---     This command stores original bytes automatically, supports wildcard-aware partial patches,
---     and provides consistent before/after verification logs.
---   Usage examples:
---     ManifoldPatch(ExampleHook, 90 90 90 90 90 90)
---     ManifoldPatch(SomeFunction, C3)
---     ManifoldPatch(ExampleHook, 48 8B ?? ?? 90 90)
---     ManifoldPatch(ExampleHook)
---   Notes:
---     Calling it without a second argument restores the stored original bytes.
--- @return function
--
function AssemblerCommands:_cmdManifoldPatch()
    return function(parameters, syntaxcheck)
        local ctx = self:_beginCommand("ManifoldPatch", parameters, syntaxcheck)
        if ctx.Syntaxcheck then return EMPTY_RESULT end
        local addrExpr, addrErr = self:_requireArg(ctx.Args, 1, ctx.Name, "address")
        if not addrExpr then return self:_commandError(ctx.Name, addrErr) end
        if self:_isBlank(ctx.Args[2]) then
            return self:_executeStoredPatch(ctx.Name, addrExpr, nil, nil)
        end
        local patchBytes, patternErr = self:_requireBytesPatternArg(ctx.Args, 2, ctx.Name, "bytes pattern")
        if not patchBytes then return self:_commandError(ctx.Name, patternErr) end
        return self:_executeStoredPatch(ctx.Name, addrExpr, patchBytes, nil)
    end
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldNop.
---   Why this command exists:
---     NOP patches are extremely common, so this command keeps the common case shorter
---     than manually writing repeated 90 bytes while still reusing the same patch store/restore flow.
---   Usage examples:
---     ManifoldNop(ExampleHook, 6)
---     ManifoldNop(ExampleHook)
---   Notes:
---     Calling it without a byte count restores the previously stored original bytes.
--- @return function
--
function AssemblerCommands:_cmdManifoldNop()
    return function(parameters, syntaxcheck)
        local ctx = self:_beginCommand("ManifoldNop", parameters, syntaxcheck)
        if ctx.Syntaxcheck then return EMPTY_RESULT end
        local addrExpr, addrErr = self:_requireArg(ctx.Args, 1, ctx.Name, "address")
        if not addrExpr then return self:_commandError(ctx.Name, addrErr) end
        if self:_isBlank(ctx.Args[2]) then
            return self:_executeStoredPatch(ctx.Name, addrExpr, nil, nil)
        end
        local byteCount, countErr = self:_parseOptionalNumberArg(ctx.Args, 2, ctx.Name, "byte count", nil)
        if countErr then return self:_commandError(ctx.Name, countErr) end
        if type(byteCount) ~= "number" or byteCount < 1 then
            return self:_commandError(ctx.Name, string.format("%s: byte count must be >= 1", ctx.Name))
        end
        local nopBytes, nopErr = self:_buildNopBytes(byteCount)
        if not nopBytes then
            return self:_commandError(ctx.Name, string.format("%s: %s", ctx.Name, tostring(nopErr)))
        end
        return self:_executeStoredPatch(ctx.Name, addrExpr, nopBytes, { string.format("ByteCount: %d", byteCount) })
    end
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldResolveStatic.
---   Why this command exists:
---     x64 scripts often start from a scanned instruction, but what we really need is
---     the final RIP-relative target. This command resolves that target and emits a define(),
---     so later script sections can stay readable and avoid repeating disp32 math.
---   Usage example:
---     ManifoldScanModule(GlobalLoadInsn, SomeGame.exe, 48 8B 05 ?? ?? ?? ??)
---     ManifoldResolveStatic(GlobalPtr, GlobalLoadInsn, 3, 7)
---   Formula:
---     target = instructionAddress + instructionLength + disp32
---   Why the defaults are 3 and 7:
---     Many common x64 RIP-relative instructions store the displacement after 3 bytes
---     and have a total instruction length of 7 bytes.
--- @return function
--
function AssemblerCommands:_cmdManifoldResolveStatic()
    return function(parameters, syntaxcheck)
        local ctx = self:_beginCommand("ManifoldResolveStatic", parameters, syntaxcheck)
        if ctx.Syntaxcheck then
            return self:_syntaxDefine(ctx.Args[1] or "ManifoldResolveStatic_Symbol")
        end
        local symbol, symbolErr = self:_requireSymbolArg(ctx.Args, 1, ctx.Name, "output symbol")
        if not symbol then return self:_commandError(ctx.Name, symbolErr) end
        local baseAddr, _, addrErr = self:_requireResolvedAddressArg(ctx.Args, 2, ctx.Name, "address expression")
        if not baseAddr then return self:_commandError(ctx.Name, addrErr) end
        local dispOffset, dispErr = self:_parseOptionalNumberArg(ctx.Args, 3, ctx.Name, "disp offset", self.DEFAULT_RESOLVE_STATIC_DISP_OFFSET)
        if dispErr then return self:_commandError(ctx.Name, dispErr) end
        local instructionLength, instructionErr = self:_parseOptionalNumberArg(ctx.Args, 4, ctx.Name, "instruction length", self.DEFAULT_RESOLVE_STATIC_INSTR_LENGTH)
        if instructionErr then return self:_commandError(ctx.Name, instructionErr) end
        if dispOffset < 0 then
            return self:_commandError(ctx.Name, ctx.Name .. ": disp offset must be >= 0")
        end
        if instructionLength <= 0 then
            return self:_commandError(ctx.Name, ctx.Name .. ": instruction length must be > 0")
        end
        local readIntegerFn = rawget(_G, "readInteger")
        if type(readIntegerFn) ~= "function" then
            return self:_commandError(ctx.Name, ctx.Name .. ": readInteger not available")
        end
        local ok, disp = pcall(function() return readIntegerFn(baseAddr + dispOffset, true) end)
        if not ok or disp == nil then
            return self:_commandError(ctx.Name, ctx.Name .. ": failed to read disp32")
        end
        local target = baseAddr + instructionLength + disp
        local targetName = getNameFromAddress(target)
        local replace = string.format("define(%s, %s)", symbol, targetName)
        logger:Info(MODULE_PREFIX .. " ManifoldResolveStatic OK")
        logger:InfoF("   Base Address: %s", getNameFromAddress(baseAddr))
        logger:InfoF("   Disp32      : %X", disp)
        logger:InfoF("   Target      : %s", targetName)
        logger:InfoF("   Replace Line: %s", replace)
        return replace
    end
end

--
--- ∑ Registers all core Auto Assembler commands exposed by this module.
---   The commands are registered from COMMAND_SPECS so the public command set stays
---   declarative and easier to extend without editing multiple code paths.
--- @return boolean
--
function AssemblerCommands:RegisterCoreCommands()
    local reg = rawget(_G, "registerAutoAssemblerCommand")
    if type(reg) ~= "function" then
        logger:ForceCritical(MODULE_PREFIX .. " registerAutoAssemblerCommand not available")
        return false
    end
    for _, command in ipairs(self:_buildCommandHandlers()) do
        self:_registerCommand(command.name, command.handler)
    end
    return true
end
registerLuaFunctionHighlight("RegisterCoreCommands")

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return AssemblerCommands
