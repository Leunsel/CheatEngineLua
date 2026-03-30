local NAME = "Manifold.AssemblerCommands.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.4"
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
]]--

AssemblerCommands = {
    LOG_SIG_MAX_INFO  = 32, -- max chars shown in INFO for signatures
    LOG_SIG_MAX_DEBUG = 64, -- max chars shown in DEBUG for signatures
    DEFAULT_RESOLVE_STATIC_DISP_OFFSET = 3,
    DEFAULT_RESOLVE_STATIC_INSTR_LENGTH = 7
}
AssemblerCommands.__index = AssemblerCommands

--
--- ∑ Creates a new AssemblerCommands instance, checks dependencies, and assigns module metadata.
--- @return table # Returns a new AssemblerCommands instance.
--
function AssemblerCommands:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
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
--- ∑ Ensures required global dependencies are available and loads them if missing.
--- @return nil # Returns nothing.
--
function AssemblerCommands:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end }
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[Commands] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[Commands] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[Commands] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[Commands] Dependency '" .. depName .. "' is already loaded")
        end
    end
end

--
--- ∑ Trims leading and trailing whitespace from a value.
--- @param s any # Value to trim (will be converted to string).
--- @return string # Returns the trimmed string.
--
function AssemblerCommands:_trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--
--- ∑ Returns true if a value is nil or an empty/whitespace-only string.
--- @param v any
--- @return boolean
--
function AssemblerCommands:_isBlank(v)
    return v == nil or self:_trim(v) == ""
end

--
--- ∑ Removes surrounding single or double quotes from a string if present.
--- @param s any # Value to normalize and unquote.
--- @return string # Returns the unquoted string.
--
function AssemblerCommands:_stripQuotes(s)
    s = self:_trim(s or "")
    local first = s:sub(1, 1)
    local last = s:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then return s:sub(2, -2) end
    return s
end

--
--- ∑ Splits parameters by commas while preserving quoted segments.
--- @param parameters any # Raw parameter string (comma-separated).
--- @return table # Returns an array-table of parsed argument strings.
--
function AssemblerCommands:_splitArgs(parameters)
    local s = tostring(parameters or "")
    local args, buf = {}, {}
    local quote = nil
    local function push()
        args[#args + 1] = self:_trim(table.concat(buf))
        buf = {}
    end
    for i = 1, #s do
        local c = s:sub(i, i)
        if quote then
            buf[#buf + 1] = c
            if c == quote then
                quote = nil
            end
        else
            if c == '"' or c == "'" then
                quote = c
                buf[#buf + 1] = c
            elseif c == "," then
                push()
            else
                buf[#buf + 1] = c
            end
        end
    end
    push()
    return args
end

--
--- ∑ Parses a number from string input supporting decimal and common hex formats.
--- @param s any # Value to parse (e.g. "123", "0x7B", "$7B", "7B").
--- @return number|nil # Returns the parsed number or nil if parsing fails.
--
function AssemblerCommands:_parseNumber(s)
    if s == nil then return nil end
    s = self:_trim(s)
    if s == "" then return nil end
    local n = tonumber(s)
    if n ~= nil then return n end
    if s:match("^[%x]+$") then return tonumber(s, 16) end
    local up = s:upper()
    if up:sub(1, 1) == "$"  then return tonumber(up:sub(2), 16) end
    if up:sub(1, 2) == "0X" then return tonumber(up:sub(3), 16) end
    if up:sub(1, 1) == "#"  then return tonumber(up:sub(2))     end
    return nil
end

--
--- ∑ Collapses whitespace and shortens a string to a maximum length with ellipsis.
--- @param s any # Value to stringify and shorten.
--- @param maxLen number|nil # Maximum length before truncation (default: 50).
--- @return string # Returns the shortened string.
--
function AssemblerCommands:_shorten(s, maxLen)
    s = tostring(s or ""):gsub("%s+", " ")
    maxLen = maxLen or 50
    if #s <= maxLen then return s end
    return s:sub(1, maxLen) .. "..."
end

--
--- ∑ Generates a stable 32-bit FNV-1a hash ID for a signature string.
--- @param sig any # Signature string to hash.
--- @return string # Returns the hash as an 8-character uppercase hex string.
--
function AssemblerCommands:_sigId(sig)
    sig = tostring(sig or "")
    local h = 2166136261
    for i = 1, #sig do
        h = h ~ sig:byte(i)
        h = (h * 16777619) % 4294967296
    end
    return string.format("%08X", h)
end

--
--- ∑ Creates a compact signature summary for logs (id + len + preview).
--- @param sig any # Signature string.
--- @param maxLen number|nil # Preview max length.
--- @return string
--
function AssemblerCommands:_sigSummary(sig, maxLen)
    sig = self:_stripQuotes(sig or "")
    local id = self:_sigId(sig)
    local len = #sig
    local preview = self:_shorten(sig, maxLen or self.LOG_SIG_MAX_INFO)
    return string.format("%s (len=%d) %s", id, len, preview)
end

--
--- ∑ Formats a debug dump of parsed arguments for logging and diagnostics.
--- @param args table # Parsed argument array.
--- @return string # Returns a formatted multi-line argument dump string.
--
function AssemblerCommands:_fmtArgDump(args)
    return string.format(
        "args(count=%d)\n\t1=%s\n\t2=%s\n\t3=%s\n\t4=%s\n\t5=%s\n\t6=%s",
        #args,
        tostring(args[1]),
        tostring(args[2]),
        self:_shorten(args[3], 140),
        tostring(args[4]),
        tostring(args[5]),
        tostring(args[6]))
end

--
--- ∑ Reads a required argument and returns a command-style error if missing.
--- @param args table
--- @param index number
--- @param commandName string
--- @param fieldName string
--- @return string|nil
--- @return string|nil
--
function AssemblerCommands:_requireArg(args, index, commandName, fieldName)
    local value = args[index]
    if self:_isBlank(value) then return nil, string.format("%s: missing %s (Argument %d)", commandName, fieldName, index) end
    return value, nil
end

--
--- ∑ Validates a define symbol name for Auto Assembler.
--- @param symbol any
--- @return boolean
--- @return string|nil
--
function AssemblerCommands:_isValidSymbolName(symbol)
    symbol = self:_stripQuotes(symbol or "")
    if symbol == "" then return false, "symbol is empty" end
    if not symbol:match("^[A-Za-z_][A-Za-z0-9_]*$") then return false, "symbol contains invalid characters" end
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
    if not okSymbol then return nil, string.format("%s: invalid %s (Argument %d): %s", commandName, fieldName, index, tostring(symbolErr)) end
    return self:_stripQuotes(symbol), nil
end

--
--- ∑ Parses an optional numeric argument.
---     If omitted -> returns defaultValue.
---     If present but invalid -> returns nil + error.
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
    if parsed == nil then return nil, string.format("%s: invalid %s (Argument %d): '%s'", commandName, fieldName, index, tostring(raw)) end
    return parsed, nil
end

--
--- ∑ Logs and returns a uniform command error.
--- @param commandName string
--- @param message string
--- @return nil
--- @return string
--
function AssemblerCommands:_commandError(commandName, message)
    logger:Error(string.format("[Commands] %s Error", commandName))
    logger:ErrorF("[Commands]   Reason: %s", tostring(message))
    return nil, message
end

--
--- ∑ Parses a byte pattern with wildcard support.
--- @param pattern any
--- @return table|nil
--- @return string|nil
--
function AssemblerCommands:_parseBytesPattern(pattern)
    pattern = self:_stripQuotes(pattern or "")
    pattern = self:_trim(pattern)
    if pattern == "" then return nil, "empty bytes pattern" end
    local out = {}
    for tok in pattern:gmatch("%S+") do
        tok = tok:upper()
        if tok == "??" or tok == "**" or tok == "?*" or tok == "*?" then
            out[#out + 1] = nil
        elseif tok:match("^[0-9A-F][0-9A-F]$") then
            out[#out + 1] = tonumber(tok, 16)
        else
            return nil, "invalid byte token: " .. tok
        end
    end
    if #out == 0 then return nil, "empty bytes pattern" end
    return out, nil
end

--
--- ∑ Reads bytes from memory.
--- @param addr number
--- @param count number
--- @return table|nil
--- @return string|nil
--
function AssemblerCommands:_readBytes(addr, count)
    local rb = rawget(_G, "readBytes")
    if type(rb) ~= "function" then return nil, "readBytes not available" end
    local ok, t = pcall(function() return rb(addr, count, true) end)
    if not ok then return nil, tostring(t) end
    if type(t) ~= "table" then return nil, "readBytes returned non-table" end
    return t, nil
end

--
--- ∑ Resolves an address expression.
--- @param expr any
--- @return number|nil
--- @return string|nil
--
function AssemblerCommands:_resolveAddress(expr)
    expr = self:_stripQuotes(expr or "")
    expr = self:_trim(expr)
    if expr == "" then return nil, "empty address expr" end
    local gas = rawget(_G, "getAddressSafe")
    if type(gas) == "function" then
        local ok, a = pcall(function() return gas(expr) end)
        if ok and a then return a, nil end
    end
    local ga = rawget(_G, "getAddress")
    if type(ga) == "function" then
        local ok, a = pcall(function() return ga(expr) end)
        if ok and a then return a, nil end
        if not ok then return nil, tostring(a) end
    end
    local n = self:_parseNumber(expr)
    if n ~= nil then return n, nil end
    return nil, "could not resolve address: " .. expr
end

--
--- ∑ Formats bytes for logs.
--- @param t table
--- @return string
--
function AssemblerCommands:_fmtBytes(t)
    local parts = {}
    for i = 1, #t do
        local v = t[i]
        if v == nil then
            parts[#parts + 1] = "??"
        else
            parts[#parts + 1] = string.format("%02X", v)
        end
    end
    return table.concat(parts, " ")
end

--
--- ∑ Performs a unique AOB scan within a module and returns the resolved address (or an error).
--- @param moduleName string # Target module name (quotes allowed).
--- @param signature string # AOB signature/pattern (quotes allowed).
--- @param protectionFlags number|nil # CE protection flags passed to the scan API.
--- @param alignmentType number|nil # CE alignment type passed to the scan API.
--- @param alignmentParam number|nil # CE alignment parameter passed to the scan API.
--- @return number|nil # Returns the found address or nil on failure.
--- @return string|nil # Returns an error message if the scan fails.
--
function AssemblerCommands:_aobScanModuleUnique(moduleName, signature, protectionFlags, alignmentType, alignmentParam)
    local rawModule = moduleName
    local rawSig = signature
    moduleName = self:_stripQuotes(moduleName)
    signature = self:_stripQuotes(signature)
    local sigId = self:_sigId(signature)
    logger:Info("[Commands] Scan")
    logger:InfoF("[Commands]   Module: %s", tostring(moduleName))
    logger:InfoF("[Commands]   Signature: %s", self:_sigSummary(signature, self.LOG_SIG_MAX_INFO))
    logger:Debug("[Commands] Scan Request")
    logger:DebugF("[Commands]   Module (Raw): %s", tostring(rawModule))
    logger:DebugF("[Commands]   Signature (Raw): %s", self:_shorten(rawSig, self.LOG_SIG_MAX_DEBUG))
    logger:DebugF("[Commands]   Signature ID: %s", tostring(sigId))
    logger:DebugF("[Commands]   Protection: %s", tostring(protectionFlags))
    logger:DebugF("[Commands]   Alignment Type: %s", tostring(alignmentType))
    logger:DebugF("[Commands]   Alignment Param: %s", tostring(alignmentParam))
    if moduleName == "" then return nil, "moduleName empty" end
    if signature == "" then return nil, "signature empty" end
    local fn = rawget(_G, "AOBScanModuleUnique")
    if type(fn) ~= "function" then return nil, "AOBScanModuleUnique not available" end
    local ok, addrOrErr = pcall(function() return fn(moduleName, signature, protectionFlags, alignmentType, alignmentParam) end)
    if not ok then return nil, "AOBScanModuleUnique exception: " .. tostring(addrOrErr) end
    if not addrOrErr then return nil, "AOB not found or not unique" end
    logger:Info("[Commands] Scan Result")
    logger:Info("[Commands]   Status: OK")
    logger:InfoF("[Commands]   Signature ID: %s", tostring(sigId))
    logger:InfoF("[Commands]   Address: %s", getNameFromAddress(addrOrErr))
    return addrOrErr, nil
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldScanModule (parses args and emits define()).
--- @return function # Returns a handler function(parameters, syntaxcheck) used by registerAutoAssemblerCommand.
--
function AssemblerCommands:_cmd_aobScanModule()
    return function(parameters, syntaxcheck)
        local commandName = "ManifoldScanModule"
        local phase = syntaxcheck and "SYNTAXCHECK" or "EXECUTE"
        logger:Info("[Commands] ManifoldScanModule")
        logger:InfoF("[Commands]   Phase: %s", phase)
        local args = self:_splitArgs(parameters)
        local syntaxSymbol = self:_stripQuotes(args[1] or "ManifoldScanModule_Symbol")
        if syntaxcheck then
            return string.format("define(%s, %016X)", syntaxSymbol, 0)
        end
        local symbol, symbolErr = self:_requireSymbolArg(args, 1, commandName, "symbol")
        if not symbol then
            return self:_commandError(commandName, symbolErr)
        end
        local moduleName, moduleErr = self:_requireArg(args, 2, commandName, "module")
        if not moduleName then
            return self:_commandError(commandName, moduleErr)
        end
        local signature, signatureErr = self:_requireArg(args, 3, commandName, "signature")
        if not signature then
            return self:_commandError(commandName, signatureErr)
        end
        local prot, protErr = self:_parseOptionalNumberArg(args, 4, commandName, "protection", nil)
        if protErr then
            return self:_commandError(commandName, protErr)
        end
        local alignType, alignTypeErr = self:_parseOptionalNumberArg(args, 5, commandName, "align type", nil)
        if alignTypeErr then
            return self:_commandError(commandName, alignTypeErr)
        end
        local alignParam, alignParamErr = self:_parseOptionalNumberArg(args, 6, commandName, "align param", nil)
        if alignParamErr then
            return self:_commandError(commandName, alignParamErr)
        end
        logger:DebugF("[Commands]   Parameters: %s", tostring(parameters))
        logger:DebugF("[Commands]   Parsed Args:\n%s", self:_fmtArgDump(args))
        local addr, scanErr = self:_aobScanModuleUnique(moduleName, signature, prot, alignType, alignParam)
        if not addr then
            return self:_commandError(commandName, tostring(scanErr))
        end
        local replace = string.format("define(%s, %s)", symbol, getNameFromAddress(addr))
        logger:InfoF("[Commands]   Replace Line: %s", replace)
        return replace
    end
end

--
--- ∑ Performs a runtime assertion that bytes at a resolved address match an expected pattern, with detailed logging on mismatch.
--- @return function # Returns a handler function(parameters, syntaxcheck) used by registerAutoAssemblerCommand.
--
function AssemblerCommands:_cmd_manifoldAssert()
    return function(parameters, syntaxcheck)
        local commandName = "ManifoldAssert"
        local phase = syntaxcheck and "SYNTAXCHECK" or "EXECUTE"
        logger:Info("[Commands] ManifoldAssert")
        logger:InfoF("[Commands]   Phase: %s", phase)
        if syntaxcheck then return "" end
        local args = self:_splitArgs(parameters)
        local addrExpr, addrErr = self:_requireArg(args, 1, commandName, "address")
        if not addrExpr then
            return self:_commandError(commandName, addrErr)
        end
        local bytesPat, bytesErr = self:_requireArg(args, 2, commandName, "bytes pattern")
        if not bytesPat then
            return self:_commandError(commandName, bytesErr)
        end
        local addr, resolveErr = self:_resolveAddress(addrExpr)
        if not addr then
            return self:_commandError(commandName, string.format("%s: cannot resolve address '%s': %s", commandName, tostring(addrExpr), tostring(resolveErr)))
        end
        local expected, patternErr = self:_parseBytesPattern(bytesPat)
        if not expected then
            return self:_commandError(commandName, string.format("%s: invalid bytes pattern: %s", commandName, tostring(patternErr)))
        end
        local actual, readErr = self:_readBytes(addr, #expected)
        if not actual then
            return self:_commandError(commandName, string.format("%s: readBytes failed at %s: %s", commandName, getNameFromAddress(addr), tostring(readErr)))
        end
        local mismatchAt = nil
        for i = 1, #expected do
            local e = expected[i]
            if e ~= nil and actual[i] ~= e then
                mismatchAt = i
                break
            end
        end
        if mismatchAt then
            local actualFmt = {}
            for i = 1, #expected do
                actualFmt[i] = actual[i]
            end
            logger:ForceWarning("[Commands] ManifoldAssert mismatch")
            logger:ForceWarningF("[Commands]   Address: %s", getNameFromAddress(addr))
            logger:ForceWarningF("[Commands]   Expected: %s", self:_fmtBytes(expected))
            logger:ForceWarningF("[Commands]   Actual  : %s", self:_fmtBytes(actualFmt))
            logger:ForceWarningF("[Commands]   First mismatch at +%X (index %d)", mismatchAt - 1, mismatchAt)
            return ""
        end
        logger:Info("[Commands] ManifoldAssert OK")
        logger:InfoF("[Commands]   Address: %s", getNameFromAddress(addr))
        logger:InfoF("[Commands]   Bytes   : %s", self:_fmtBytes(expected))
        return ""
    end
end

--
--- ∑ Resolves a RIP-relative static target from an instruction and emits a define() for Auto Assembler.
--- @return function # Returns a handler function(parameters, syntaxcheck) used by registerAutoAssemblerCommand.
--
function AssemblerCommands:_cmd_resolveStatic()
    return function(parameters, syntaxcheck)
        local commandName = "ManifoldResolveStatic"
        local phase = syntaxcheck and "SYNTAXCHECK" or "EXECUTE"
        logger:Info("[Commands] ManifoldResolveStatic")
        logger:InfoF("[Commands]   Phase: %s", phase)
        local args = self:_splitArgs(parameters)
        local syntaxSymbol = self:_stripQuotes(args[1] or "ManifoldResolveStatic_Symbol")
        if syntaxcheck then
            return string.format("define(%s, %016X)", syntaxSymbol, 0)
        end
        local symbol, symbolErr = self:_requireSymbolArg(args, 1, commandName, "output symbol")
        if not symbol then
            return self:_commandError(commandName, symbolErr)
        end
        local addrExpr, addrExprErr = self:_requireArg(args, 2, commandName, "address expression")
        if not addrExpr then
            return self:_commandError(commandName, addrExprErr)
        end
        local dispOff, dispErr = self:_parseOptionalNumberArg(args, 3, commandName, "disp offset", self.DEFAULT_RESOLVE_STATIC_DISP_OFFSET)
        if dispErr then return self:_commandError(commandName, dispErr) end
        local instrLen, instrErr = self:_parseOptionalNumberArg(args, 4, commandName, "instruction length", self.DEFAULT_RESOLVE_STATIC_INSTR_LENGTH)
        if instrErr then
            return self:_commandError(commandName, instrErr)
        end
        if dispOff < 0 then
            return self:_commandError(commandName, "ManifoldResolveStatic: disp offset must be >= 0")
        end
        if instrLen <= 0 then
            return self:_commandError(commandName, "ManifoldResolveStatic: instruction length must be > 0")
        end
        local baseAddr, baseAddrErr = self:_resolveAddress(addrExpr)
        if not baseAddr then
            return self:_commandError(commandName, "ManifoldResolveStatic: " .. tostring(baseAddrErr))
        end
        local ri = rawget(_G, "readInteger")
        if type(ri) ~= "function" then
            return self:_commandError(commandName, "ManifoldResolveStatic: readInteger not available")
        end
        local ok, disp = pcall(function() return ri(baseAddr + dispOff, true) end)
        if not ok or disp == nil then
            return self:_commandError(commandName, "ManifoldResolveStatic: failed to read disp32")
        end
        local target = baseAddr + instrLen + disp
        local targetName = getNameFromAddress(target)
        local replace = string.format("define(%s, %s)", symbol, targetName)
        logger:Info("[Commands] ManifoldResolveStatic OK")
        logger:InfoF("[Commands]   Base Address: %s", getNameFromAddress(baseAddr))
        logger:InfoF("[Commands]   Disp32      : %d", disp)
        logger:InfoF("[Commands]   Target      : %s", targetName)
        logger:InfoF("[Commands]   Replace Line: %s", replace)
        return replace
    end
end

--
--- ∑ Registers core Auto Assembler commands provided by this module.
--- @return boolean # Returns true if registration succeeded, otherwise false.
--
function AssemblerCommands:RegisterCoreCommands()
    local reg = rawget(_G, "registerAutoAssemblerCommand")
    if type(reg) ~= "function" then
        logger:ForceCritical("[Commands] registerAutoAssemblerCommand not available")
        return false
    end
    local commands = {
        { name = "ManifoldScanModule",    handler = self:_cmd_aobScanModule() },
        { name = "ManifoldAssert",        handler = self:_cmd_manifoldAssert() },
        { name = "ManifoldResolveStatic", handler = self:_cmd_resolveStatic() }
    }
    for _, cmd in ipairs(commands) do
        reg(cmd.name, cmd.handler)
        logger:InfoF("[Commands] Registered Assembler Command: %s", cmd.name)
    end
    return true
end
registerLuaFunctionHighlight("RegisterCoreCommands")

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return AssemblerCommands