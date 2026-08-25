--[[
    Mono provider: facts about the managed method the injection address falls
    into.

    Mono breaks the assumption the native providers rest on. A native hook is
    anchored by a byte signature that is computed once, written into the
    script and scanned again on every enable. Managed code is JIT compiled, so
    the bytes at a method are produced fresh on every run and a signature over
    them is worthless the moment the process restarts. The anchor for a
    managed hook is the method NAME, and Cheat Engine resolves it inside the
    target at assemble time through its own Auto Assembler commands, which
    monoscript.lua registers:

        USEMONO()
        FINDMONOMETHOD(name, Namespace:Class:Method)
        GETMONOSTRUCT(name, Namespace:Class)

    FINDMONOMETHOD runs mono_findMethod plus mono_compile_method and emits
    define(name, address). That is why this provider never puts a JIT address
    into a script. MonoMethodEntry exists for inspection and for the loader's
    own decisions, not for the generated text.

    Two Cheat Engine details this file works around, both read out of
    monoscript.lua rather than assumed.

    LaunchMonoDataCollector refuses and pops a message dialog while the
    debugger is paused, even when the collector is already attached, because
    the debug_isBroken check sits above its early return. Breaking on a method
    is the normal way to find a hook site, so the provider only launches the
    collector when it is not already attached to this process.

    The address lookup callback that getNameFromAddress goes through carries
    the same debug_isBroken guard and bails for IL2CPP. mono_getJitInfo has
    neither, so the descriptor here is built from the raw calls instead of
    from a formatted name string. That also gives access to code_start and
    code_size, which a name string does not carry.

    IL2CPP is detected and reported but not supported. There is no Mono
    runtime to ask, so name based resolution cannot work. Support for it
    belongs in a separate provider that reads a metadata dump.
]]

local Provider = { Name = "Mono" }

local function api(name)
    local fn = rawget(_G, name)
    return type(fn) == "function" and fn or nil
end

local function call(name, ...)
    local fn = api(name)
    if not fn then return nil, "Cheat Engine has no '" .. name .. "'" end
    local ok, result = pcall(fn, ...)
    -- Seven of the mono getters index the monopipe global with no nil check
    -- of their own, so a pipe that died on Cheat Engine's timeout raises here
    -- rather than returning nothing. Without the reason the next failure
    -- would look exactly like a clean miss.
    if not ok then return nil, name .. " raised: " .. tostring(result) end
    return result
end

--
--- Cheat Engine's mono getters hand back raw qwords. Zero means "none", and
--- they never return nil for it. Zero is true in Lua, so a handle has to be
--- compared and never merely tested. Cheat Engine does the same normalization
--- itself in dotnetinfo.lua before it trusts a nesting type.
--
local function isHandle(value)
    return type(value) == "number" and value ~= 0
end

--
--- The same problem with names. An invalid class answers with an empty string
--- instead of nil, and an empty segment would still leave the descriptor with
--- two colons, so it would slip past every later check.
--
local function isName(value)
    return type(value) == "string" and value ~= ""
end

--
--- True while Cheat Engine's debugger holds the target. Several Mono entry
--- points refuse in that state, so it is worth reporting rather than running
--- into their dialogs.
--
local function debuggerIsBroken()
    local fn = api("debug_isBroken")
    if not fn then return false end
    local ok, broken = pcall(fn)
    return ok and broken == true
end

--
--- Attaches the Mono data collector, but only when it is not already
--- attached to the process that is open now. LaunchMonoDataCollector checks
--- debug_isBroken before its own "already attached" early return, so calling
--- it unconditionally turns a paused debugger into a failure and a dialog.
--- @return boolean, string|nil
--
local function ensureCollector()
    if not api("mono_getJitInfo") then
        return false, "Cheat Engine's Mono support is not loaded (monoscript.lua)"
    end
    local pipe = rawget(_G, "monopipe")
    local attached = rawget(_G, "mono_AttachedProcess")
    local opened = call("getOpenedProcessID")
    if pipe ~= nil and attached ~= nil and opened ~= nil and attached == opened then
        return true
    end
    if debuggerIsBroken() then
        return false, "The Mono data collector cannot attach while the debugger is paused"
    end
    local launch = api("LaunchMonoDataCollector")
    if not launch then
        return false, "LaunchMonoDataCollector is not available"
    end
    local ok, result = pcall(launch)
    if not ok or result == nil or result == 0 then
        return false, "The Mono data collector failed to attach to this process"
    end
    if rawget(_G, "monopipe") == nil then
        return false, "The Mono data collector did not open a pipe"
    end
    return true
end

--
--- Namespace:Class:Method, in the exact shape FINDMONOMETHOD parses.
--- It splits on the first two colons, so a class in the global namespace
--- needs a leading colon rather than no namespace segment at all. A nested
--- type has no representation here, because its full name already contains
--- the separator and the command would mis-split it.
--- @return string|nil descriptor, boolean nested
--
local function buildDescriptor(method)
    local class = call("mono_method_getClass", method)
    if not isHandle(class) then return nil, false end
    -- Ask about nesting first. A nested type has no descriptor worth building,
    -- so the two name lookups below would be wasted pipe traffic.
    if isHandle(call("mono_class_getNestingType", class)) then
        return nil, true
    end
    local className = call("mono_class_getName", class)
    local methodName = call("mono_method_getName", method)
    if not isName(className) or not isName(methodName) then
        return nil, false
    end
    -- An empty namespace is not a failure. A class in the global namespace
    -- needs the leading colon, because FINDMONOMETHOD reads everything before
    -- the first colon as the namespace.
    local namespace = call("mono_class_getNamespace", class)
    if type(namespace) ~= "string" then namespace = "" end
    return namespace .. ":" .. className .. ":" .. methodName, false
end

local function sanitizeSymbol(value)
    if type(value) ~= "string" or value == "" then return nil end
    local normalized = value:gsub("[^%w_]", "_")
    if normalized:match("^%d") then normalized = "_" .. normalized end
    return normalized ~= "" and normalized or nil
end

function Provider.Register(registry, services)
    local log = services.Log

    local jitHint = "The selected address is not inside a JIT compiled managed method. "
        .. "Either the target does not use Mono, or the method has not been called yet "
        .. "and therefore has not been compiled. Run the code once and select it again."

    -- A required variable that resolves to nil is reported with its Hint, and
    -- the context calls a function Hint with itself. Without this every cause
    -- reads as "not JIT compiled", which is what sent the first field report
    -- looking in the wrong place.
    local function descriptorHint(ctx)
        local ok, names = pcall(function() return ctx:Get("_MonoNames") end)
        if ok and type(names) == "table" then
            if names.Nested then
                return "The selected address is inside '"
                    .. tostring(names.FullClass or names.Class or "a nested type")
                    .. "', which is a nested managed type. FINDMONOMETHOD splits a descriptor "
                    .. "on the first two colons, so a nested type cannot be named. Hook a "
                    .. "method on a type that is not nested."
            end
            return "The managed method was found, but its class or method name could not be "
                .. "read, so no Namespace:Class:Method descriptor could be built. The log has "
                .. "the lookup that failed."
        end
        return jitHint
    end

    return registry:RegisterProvider{
        Name = Provider.Name,
        Variables = {
            MonoAvailable = {
                Type = "boolean",
                Description = "True when Cheat Engine's Mono data collector is attached to the target",
                Resolve = function()
                    local ok, reason = ensureCollector()
                    if not ok then
                        log:Debug("[Mono] " .. tostring(reason))
                    end
                    return ok
                end
            },
            MonoIsIl2Cpp = {
                Type = "boolean",
                Description = "True when the target is an IL2CPP build, where name based resolution does not work",
                DependsOn = { "MonoAvailable" },
                Resolve = function(ctx)
                    if not ctx:Get("MonoAvailable") then return false end
                    local pipe = rawget(_G, "monopipe")
                    local ok, flag = pcall(function() return pipe.IL2CPP end)
                    return ok and flag == true
                end
            },
            _MonoJit = {
                Type = "table",
                Hidden = true,
                Description = "Raw mono_getJitInfo result for the injection address",
                DependsOn = { "MonoAvailable", "AddressValue" },
                Resolve = function(ctx)
                    if not ctx:Get("MonoAvailable") then return nil end
                    local info = call("mono_getJitInfo", ctx:Get("AddressValue"))
                    if type(info) ~= "table" or not info.method or info.method == 0 then
                        return nil
                    end
                    log:Debug(string.format(
                        "[Mono] JIT info: method=%s code_start=%X code_size=%s",
                        tostring(info.method), info.code_start or 0, tostring(info.code_size)))
                    return info
                end
            },
            MonoIsJitted = {
                Type = "boolean",
                Description = "True when the injection address lies inside a JIT compiled managed method",
                DependsOn = { "_MonoJit" },
                Resolve = function(ctx) return ctx:Get("_MonoJit") ~= nil end
            },
            _MonoNames = {
                Type = "table",
                Hidden = true,
                Description = "Namespace, class and method names of the surrounding method",
                DependsOn = { "_MonoJit" },
                Resolve = function(ctx)
                    local info = ctx:Get("_MonoJit")
                    if not info then return nil end
                    -- Cheat Engine drops the pipe after its own timeout and
                    -- sets the global to nil. Every getter below would then
                    -- raise, and the reason would be lost in the pcall.
                    if rawget(_G, "monopipe") == nil then
                        log:Warning("[Mono] The data collector pipe was torn down during the "
                            .. "lookup. Resume the target and select the instruction again.")
                        return nil
                    end
                    local class, err = call("mono_method_getClass", info.method)
                    if err then log:Debug("[Mono] " .. err) end
                    if not isHandle(class) then
                        log:Warning("[Mono] The class of the surrounding method could not be "
                            .. "read, so no descriptor can be built.")
                        return nil
                    end
                    local descriptor, nested = buildDescriptor(info.method)
                    if nested then
                        log:Warning("[Mono] The method belongs to a nested type. "
                            .. "FINDMONOMETHOD cannot address it, so MonoDescriptor stays empty.")
                    end
                    local namespace = call("mono_class_getNamespace", class)
                    local className = call("mono_class_getName", class)
                    local fullName = call("mono_class_getFullName", class)
                    local methodName = call("mono_method_getName", info.method)
                    local image = call("mono_class_getImage", class)
                    local imageName
                    if isHandle(image) then
                        imageName = call("mono_image_get_name", image)
                    end
                    return {
                        Namespace = type(namespace) == "string" and namespace or "",
                        Class = isName(className) and className or nil,
                        FullClass = isName(fullName) and fullName or nil,
                        Method = isName(methodName) and methodName or nil,
                        Image = isName(imageName) and imageName or nil,
                        Descriptor = descriptor,
                        Nested = nested
                    }
                end
            },
            MonoNamespace = {
                Type = "string",
                Description = "Namespace of the surrounding managed class, empty for the global namespace. "
                    .. "Never list this in a template's Requires, because an empty string counts as missing there",
                DependsOn = { "_MonoNames" },
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    return names and names.Namespace or nil
                end
            },
            MonoClass = {
                Type = "string",
                Description = "Name of the surrounding managed class",
                DependsOn = { "_MonoNames" },
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    return names and names.Class or nil
                end
            },
            MonoClassFullName = {
                Type = "string",
                Description = "Full class name including any nesting",
                DependsOn = { "_MonoNames" },
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    return names and names.FullClass or nil
                end
            },
            MonoMethod = {
                Type = "string",
                Description = "Name of the managed method the injection address falls into",
                DependsOn = { "_MonoNames" },
                Hint = jitHint,
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    return names and names.Method or nil
                end
            },
            MonoImage = {
                Type = "string",
                Description = "Image the class was loaded from, for example Assembly-CSharp",
                DependsOn = { "_MonoNames" },
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    return names and names.Image or nil
                end
            },
            MonoDescriptor = {
                Type = "string",
                Description = "Namespace:Class:Method, the form FINDMONOMETHOD expects",
                DependsOn = { "_MonoNames" },
                Hint = descriptorHint,
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    return names and names.Descriptor or nil
                end
            },
            MonoMethodEntry = {
                Type = "number",
                Description = "Address the JIT compiled method starts at. Valid for this run only, never write it into a script",
                DependsOn = { "_MonoJit" },
                Resolve = function(ctx)
                    local info = ctx:Get("_MonoJit")
                    return info and info.code_start or nil
                end
            },
            MonoMethodSize = {
                Type = "number",
                Description = "Size in bytes of the JIT compiled method body",
                DependsOn = { "_MonoJit" },
                Resolve = function(ctx)
                    local info = ctx:Get("_MonoJit")
                    return info and info.code_size or nil
                end
            },
            MonoMethodOffset = {
                Type = "number",
                Description = "Distance from the method entry to the injection address. Zero means the prologue",
                DependsOn = { "_MonoJit", "AddressValue" },
                Resolve = function(ctx)
                    local info = ctx:Get("_MonoJit")
                    if not info or not info.code_start then return nil end
                    return ctx:Get("AddressValue") - info.code_start
                end
            },
            MonoOffsetSuffix = {
                Type = "string",
                Description = "'+2F' when the injection address sits inside the method, empty at the entry",
                DependsOn = { "MonoMethodOffset" },
                Resolve = function(ctx)
                    -- The counterpart of AoBOffset. FINDMONOMETHOD defines the
                    -- symbol at the method entry, so a hook further in has to
                    -- carry the distance, exactly like a signature hook does.
                    local offset = ctx:Get("MonoMethodOffset")
                    if not offset or offset == 0 then return "" end
                    return string.format("+%X", offset)
                end
            },
            MonoHookName = {
                Type = "string",
                Description = "Class_Method as a valid Auto Assembler symbol, a usable default hook name",
                DependsOn = { "_MonoNames" },
                Resolve = function(ctx)
                    local names = ctx:Get("_MonoNames")
                    if not names or not names.Class or not names.Method then return nil end
                    return sanitizeSymbol(names.Class .. "_" .. names.Method)
                end
            },
            MonoResolve = {
                Type = "string",
                Description = "USEMONO and FINDMONOMETHOD statements that define the hook symbol at assemble time",
                DependsOn = { "MonoDescriptor", "HookNameParsed" },
                Hint = descriptorHint,
                Resolve = function(ctx)
                    local descriptor = ctx:Get("MonoDescriptor")
                    if not descriptor then return nil end
                    -- FINDMONOMETHOD splits on the first two colons. Anything
                    -- else would silently address the wrong method, so refuse.
                    local _, colons = descriptor:gsub(":", "")
                    if colons ~= 2 then
                        error("The method descriptor '" .. descriptor
                            .. "' is not in Namespace:Class:Method form", 0)
                    end
                    return "USEMONO()\nFINDMONOMETHOD(" .. ctx:Get("HookNameParsed")
                        .. "," .. descriptor .. ")"
                end
            }
        }
    }
end

return Provider
