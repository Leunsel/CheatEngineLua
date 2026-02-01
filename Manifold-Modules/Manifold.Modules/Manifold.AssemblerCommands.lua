local NAME = "Manifold.AssemblerCommands.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Assembler Commands"

--[[
    ∂ v1.0.0 (2026-01-31)
        Initial release with core functions.
]]--

AssemblerCommands = {
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
            logger:Warning("[AssemblerCommands] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[AssemblerCommands] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[AssemblerCommands] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[AssemblerCommands] Dependency '" .. depName .. "' is already loaded")
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
--- ∑ Removes surrounding single or double quotes from a string if present.
--- @param s any # Value to normalize and unquote.
--- @return string # Returns the unquoted string.
--
function AssemblerCommands:_stripQuotes(s)
    s = (s or ""):match("^%s*(.-)%s*$")  -- trim
    return s:gsub("[\"']", "")
end

--
--- ∑ Splits a parameter string into arguments separated by commas while preserving quoted segments.
--- @param paramString any # Raw parameter string (e.g. "a,'b,c',d").
--- @return table # Returns an array-table of parsed argument strings.
--
function AssemblerCommands:_splitArgs(paramString)
    local s = tostring(paramString or "")
    local args, buf = {}, {}
    local quote = nil
    local function push()
        table.insert(args, self:_trim(table.concat(buf)))
        buf = {}
    end
    for i = 1, #s do
        local c = s:sub(i,i)
        if quote then
            table.insert(buf, c)
            if c == quote then quote = nil end
        else
            if c == "'" or c == '"' then
                quote = c
                table.insert(buf, c)
            elseif c == "," then
                push()
            else
                table.insert(buf, c)
            end
        end
    end
    if #buf > 0 then push() end
    return args
end

--
--- ∑ Splits parameters by commas while preserving quoted segments (always pushes the last token).
--- @param parameters any # Raw parameter string (comma-separated).
--- @return table # Returns an array-table of parsed argument strings.
--
function AssemblerCommands:_splitArgsComma(parameters)
    local s = tostring(parameters or "")
    local args, buf = {}, {}
    local quote = nil
    local function push()
        table.insert(args, self:_trim(table.concat(buf)))
        buf = {}
    end
    for i = 1, #s do
        local c = s:sub(i,i)
        if quote then
            table.insert(buf, c)
            if c == quote then quote = nil end
        else
            if c == '"' or c == "'" then
                quote = c
                table.insert(buf, c)
            elseif c == "," then
                push()
            else
                table.insert(buf, c)
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
    if n then return n end
    if s:match("^[%x]+$") then
        return tonumber(s, 16)
    end
    local up = s:upper()
    if up:sub(1,1) == "$" then return tonumber(up:sub(2), 16) end
    if up:sub(1,2) == "0X" then return tonumber(up:sub(3), 16) end
    if up:sub(1,1) == "#" then return tonumber(up:sub(2)) end
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
    local h = 2166136261 -- FNV-1a 32-bit
    for i = 1, #sig do
        h = h ~ sig:byte(i)
        h = (h * 16777619) % 4294967296
    end
    return string.format("%08X", h)
end

--
--- ∑ Formats a debug dump of parsed arguments for logging and diagnostics.
--- @param args table # Parsed argument array.
--- @param maxSigLen number|nil # Max signature length to display (default: 140).
--- @return string # Returns a formatted multi-line argument dump string.
--
function AssemblerCommands:_fmtArgDump(args, maxSigLen)
    maxSigLen = maxSigLen or 140
    return string.format(
        "args(count=%d)\n\t1(symbol)=%s\n\t2(module)=%s\n\t3(sig)=%s\n\t4(prot)=%s\n\t5(alignType)=%s\n\t6(alignParam)=%s",
        #args,
        tostring(args[1]),
        tostring(args[2]),
        self:_shorten(args[3], maxSigLen),
        tostring(args[4]),
        tostring(args[5]),
        tostring(args[6])
    )
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
    local rawSig    = signature
    moduleName = self:_stripQuotes(moduleName)
    signature  = self:_stripQuotes(signature)
    local sigShort = self:_shorten(signature, 140)
    local sigId    = self:_sigId(signature)
    logger:Debug("[AssemblerCommands] Scan Request")
    logger:DebugF("[AssemblerCommands]   Module (Raw): %s", tostring(rawModule))
    logger:DebugF("[AssemblerCommands]   Module: %s", tostring(moduleName))
    logger:DebugF("[AssemblerCommands]   Signature ID: %s", tostring(sigId))
    logger:DebugF("[AssemblerCommands]   Signature (Raw): %s", self:_shorten(rawSig, 140))
    logger:DebugF("[AssemblerCommands]   Signature: %s", sigShort)
    logger:DebugF("[AssemblerCommands]   Protection: %s", tostring(protectionFlags))
    logger:DebugF("[AssemblerCommands]   Alignment Type : %s", tostring(alignmentType))
    logger:DebugF("[AssemblerCommands]   Alignment Param: %s", tostring(alignmentParam))
    if moduleName == "" then
        logger:Error("[AssemblerCommands] Scan Error")
        logger:Error("[AssemblerCommands]   Reason: Module name is empty")
        return nil, "moduleName empty"
    end
    if signature == "" then
        logger:Error("[AssemblerCommands] Scan Error")
        logger:Error("[AssemblerCommands]   Reason: Signature is empty")
        return nil, "signature empty"
    end
    local fn = rawget(_G, "AOBScanModuleUnique")
    if type(fn) ~= "function" then
        logger:Critical("[AssemblerCommands] Scan Error")
        logger:Critical("[AssemblerCommands]   Reason: CE API missing (AOBScanModuleUnique)")
        return nil, "AOBScanModuleUnique not available"
    end
    logger:Debug("[AssemblerCommands] Scan Execution")
    logger:Debug("[AssemblerCommands]   API: AOBScanModuleUnique")
    local ok, addrOrErr = pcall(function()
        return fn(moduleName, signature, protectionFlags, alignmentType, alignmentParam)
    end)
    if not ok then
        logger:Error("[AssemblerCommands] Scan Exception")
        logger:ErrorF("[AssemblerCommands]   Signature ID: %s", sigId)
        logger:ErrorF("[AssemblerCommands]   Error: %s", tostring(addrOrErr))
        return nil, "AOBScanModuleUnique exception: " .. tostring(addrOrErr)
    end
    if not addrOrErr then
        logger:Warning("[AssemblerCommands] Scan Result")
        logger:Warning("[AssemblerCommands]   Status: Not Found / Not Unique")
        logger:WarningF("[AssemblerCommands]   Signature ID: %s", sigId)
        logger:WarningF("[AssemblerCommands]   Module: %s", tostring(moduleName))
        logger:DebugF("[AssemblerCommands]   Signature: %s", sigShort)
        return nil, "AOB not found or not unique"
    end
    logger:Info("[AssemblerCommands] Scan Result")
    logger:Info("[AssemblerCommands]   Status: OK")
    logger:InfoF("[AssemblerCommands]   Signature ID: %s", sigId)
    logger:InfoF("[AssemblerCommands]   Address: %016X", addrOrErr)
    return addrOrErr, nil
end

--
--- ∑ Creates the Auto Assembler command handler for ManifoldScanModule (parses args and emits define()).
--- @return function # Returns a handler function(parameters, syntaxcheck) used by registerAutoAssemblerCommand.
--
function AssemblerCommands:_cmd_aobScanModule()
    return function(parameters, syntaxcheck)
        local args = self:_splitArgsComma(parameters)
        local symbol     = args[1]
        local moduleName = args[2]
        local signature  = args[3]
        local prot       = self:_parseNumber(args[4])
        local alignType  = self:_parseNumber(args[5])
        local alignParam = self:_parseNumber(args[6])
        local phase = (syntaxcheck and "SYNTAXCHECK" or "EXECUTE")
        if syntaxcheck then
            logger:Info("[AssemblerCommands] ManifoldScanModule")
            logger:InfoF("[AssemblerCommands]   Phase: %s", phase)
            logger:InfoF("[AssemblerCommands]   Parameters: %s", tostring(parameters))
        else
            logger:Info("[AssemblerCommands] ManifoldScanModule")
            logger:InfoF("[AssemblerCommands]   Phase: %s", phase)
            logger:InfoF("[AssemblerCommands]   Parameters: %s", tostring(parameters))
        end
        logger:Info("[AssemblerCommands] Parsed Arguments")
        logger:InfoF("[AssemblerCommands]   Symbol: %s", tostring(symbol))
        logger:InfoF("[AssemblerCommands]   Module: %s", tostring(moduleName))
        logger:InfoF("[AssemblerCommands]   Signature: %s", self:_shorten(signature, 140))
        logger:InfoF("[AssemblerCommands]   Protection: %s", tostring(args[4]))
        logger:InfoF("[AssemblerCommands]   Align Type: %s", tostring(args[5]))
        logger:InfoF("[AssemblerCommands]   Align Param: %s", tostring(args[6]))
        if not symbol or symbol == "" then
            logger:Error("[AssemblerCommands] ManifoldScanModule Error")
            logger:Error("[AssemblerCommands]   Reason: Missing symbol (Argument 1)")
            return nil, "ManifoldScanModule: missing symbol"
        end
        if not moduleName or moduleName == "" then
            logger:Error("[AssemblerCommands] ManifoldScanModule Error")
            logger:Error("[AssemblerCommands]   Reason: Missing module (Argument 2)")
            return nil, "ManifoldScanModule: missing module"
        end
        if not signature or signature == "" then
            logger:ForceError("[AssemblerCommands] ManifoldScanModule Error")
            logger:ForceError("[AssemblerCommands]   Reason: Missing signature (Argument 3)")
            return nil, "ManifoldScanModule: missing signature"
        end
        local symbolN = self:_stripQuotes(symbol)
        local moduleN = self:_stripQuotes(moduleName)
        local sigN    = self:_stripQuotes(signature)
        local sigId   = self:_sigId(sigN)
        logger:Info("[AssemblerCommands] Normalized Values")
        logger:InfoF("[AssemblerCommands]   Symbol: %s", symbolN)
        logger:InfoF("[AssemblerCommands]   Module: %s", moduleN)
        logger:InfoF("[AssemblerCommands]   Signature ID: %s", sigId)
        logger:InfoF("[AssemblerCommands]   Signature: %s", self:_shorten(sigN, 140))
        logger:InfoF("[AssemblerCommands]   Protection: %s", tostring(prot))
        logger:InfoF("[AssemblerCommands]   Align Type: %s", tostring(alignType))
        logger:InfoF("[AssemblerCommands]   Align Param: %s", tostring(alignParam))
        if syntaxcheck then
            logger:Info("[AssemblerCommands] Result")
            logger:Info("[AssemblerCommands]   Action: Returning define(symbol, 0)")
            logger:InfoF("[AssemblerCommands]   Symbol: %s", symbolN)
            return string.format("define(%s, %016X)", symbolN, 0)
        end
        logger:Info("[AssemblerCommands] Resolve")
        logger:InfoF("[AssemblerCommands]   Symbol: %s", symbolN)
        logger:InfoF("[AssemblerCommands]   Module: %s", moduleN)
        logger:InfoF("[AssemblerCommands]   Signature ID: %s", sigId)
        local addr, err = self:_aobScanModuleUnique(moduleN, sigN, prot, alignType, alignParam)
        if not addr then
            logger:Error("[AssemblerCommands] Resolve Failed")
            logger:ErrorF("[AssemblerCommands]   Symbol: %s", symbolN)
            logger:ErrorF("[AssemblerCommands]   Module: %s", moduleN)
            logger:ErrorF("[AssemblerCommands]   Signature ID: %s", sigId)
            logger:ErrorF("[AssemblerCommands]   Error: %s", tostring(err))
            return nil, err
        end
        local replace = string.format("define(%s, %016X)", symbolN, addr)
        logger:Info("[AssemblerCommands] Resolve OK")
        logger:InfoF("[AssemblerCommands]   Symbol: %s", symbolN)
        logger:InfoF("[AssemblerCommands]   Address: %016X", addr)
        logger:InfoF("[AssemblerCommands]   Signature ID: %s", sigId)
        logger:InfoF("[AssemblerCommands]   Replace Line: %s", replace)
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
        logger:ForceCritical("[AssemblerCommands] registerAutoAssemblerCommand not available")
        return false
    end
    reg("ManifoldScanModule", self:_cmd_aobScanModule())
    logger:InfoF("[AssemblerCommands] Registered Assembler Command: %s", "ManifoldScanModule")
    return true
end
registerLuaFunctionHighlight('RegisterCoreCommands')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return AssemblerCommands