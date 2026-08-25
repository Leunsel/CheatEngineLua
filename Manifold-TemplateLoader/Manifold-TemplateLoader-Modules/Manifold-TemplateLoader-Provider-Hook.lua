--[[
    Hook provider: hook symbol names, allocation statements, the unique AoB
    signature and the injection-info comment block.

    User prompts live here (hook name) and in the Instruction provider
    (injection address). The generator resolves Address and HookName eagerly
    before rendering, so prompts always appear in the familiar 2.x order no
    matter where a template first references them.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Provider = { Name = "Hook" }

function Provider.Register(registry, services)
    local ce = services.CE
    local log = services.Log
    local config = services.Config
    local function trim(value)
        return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
    end
    local function normalizeSymbolName(value)
        value = trim(value)
        if not value or value == "" then return nil end
        local normalized = value:gsub("[^%w_]", "_")
        if normalized:match("^%d") then normalized = "_" .. normalized end
        return normalized ~= "" and normalized or nil
    end
    local function formatHookName(hookName, append)
        if type(append) ~= "string" or append == "" then return hookName end
        if hookName:sub(-#append) == append then return hookName end
        return hookName .. append
    end
    local function injectionInfoSettings()
        local settings = config.Data.InjectionInfo
        return settings.LineCount, settings.RemoveSpaces == true, settings.AddTabs == true
    end
    return registry:RegisterProvider{
        Name = Provider.Name,
        Variables = {
            _HookNames = {
                Type = "table",
                Hidden = true,
                Description = "Hook symbol name pair (raw + parsed with suffix)",
                Resolve = function(ctx)
                    local options = ctx.Options
                    local requested
                    if options.AskForHookName then
                        requested = ce:InputQuery("Hook Name", "Name for the generated hook:", options.DefaultHookName or "Injection")
                        if requested == nil then
                            error(Errors.New{
                                Code = Errors.Codes.INPUT_CANCELLED, Stage = Errors.Stages.Context,
                                Message = "Hook name prompt was cancelled"
                            }, 0)
                        end
                    else
                        requested = options.DefaultHookName
                    end
                    if not requested or requested == "" then
                        error("No hook name was provided", 0)
                    end
                    local name = normalizeSymbolName(requested)
                    if not name then error("Hook name is invalid", 0) end
                    if name ~= requested then
                        log:Warning("[Hook] Hook name was normalized to a valid Auto Assembler symbol: " .. name)
                    end
                    local parsed = formatHookName(name, options.AppendToHookName)
                    log:Debug(string.format("[Hook] Hook name: input='%s', symbol='%s', scan='%s'",
                        tostring(requested), name, parsed))
                    return { Name = name, Parsed = parsed }
                end
            },
            HookName = {
                Type = "string",
                Description = "Normalized hook symbol name",
                DependsOn = { "_HookNames" },
                Resolve = function(ctx) return ctx:Get("_HookNames").Name end
            },
            HookNameParsed = {
                Type = "string",
                Description = "HookName plus the configured suffix, used for the scan symbol",
                DependsOn = { "_HookNames" },
                Resolve = function(ctx) return ctx:Get("_HookNames").Parsed end
            },
            Alloc = {
                Type = "string",
                Description = "alloc(n_<Hook>, <Size>[, <HookNameParsed>]). Near allocation when enabled and no 14-byte jump",
                DependsOn = { "HookName", "HookNameParsed", "Is14ByteJump" },
                Resolve = function(ctx)
                    local options = ctx.Options
                    if options.AllocationNear and not ctx:Get("Is14ByteJump") then
                        return string.format("alloc(n_%s,%s,%s)",
                            ctx:Get("HookName"), options.AllocationSize, ctx:Get("HookNameParsed"))
                    end
                    return string.format("alloc(n_%s,%s)", ctx:Get("HookName"), options.AllocationSize)
                end
            },
            GlobalAlloc = {
                Type = "string",
                Description = "alloc(n_<Hook>, <Size>), never near",
                DependsOn = { "HookName" },
                Resolve = function(ctx)
                    return string.format("alloc(n_%s,%s)", ctx:Get("HookName"), ctx.Options.AllocationSize)
                end
            },
            _AoB = {
                Type = "table",
                Hidden = true,
                Description = "Unique AoB signature and offset suffix",
                DependsOn = { "AddressValue", "Module" },
                Resolve = function(ctx)
                    local address = ctx:Get("AddressValue")
                    local pattern, offset = ce:GetUniqueAOB(address)
                    if not pattern or pattern == "" then
                        error(Errors.New{
                            Code = Errors.Codes.CONTEXT_RESOLUTION_FAILED, Stage = Errors.Stages.Context,
                            Message = "No unique AoB was found for the injection address",
                            Hint = "Cheat Engine could not build a unique signature at this location. Pick a nearby instruction with a more distinctive byte pattern."
                        }, 0)
                    end
                    local suffix = offset and offset ~= 0 and ("+%X"):format(offset) or ""
                    log:Debug(string.format("[Hook] Unique AoB: '%s' (offset '%s')", pattern, suffix))
                    return { Pattern = pattern, Suffix = suffix }
                end
            },
            AoBStr = {
                Type = "string",
                Description = "Unique AoB signature for the injection address",
                DependsOn = { "_AoB" },
                Resolve = function(ctx) return ctx:Get("_AoB").Pattern end
            },
            AoBOffset = {
                Type = "string",
                Description = "'+3F' offset of the address inside the signature, or ''",
                DependsOn = { "_AoB" },
                Resolve = function(ctx) return ctx:Get("_AoB").Suffix end
            },
            InjectionInfo = {
                Type = "string",
                Description = "Surrounding instructions as a comment block",
                DependsOn = { "AddressValue" },
                Resolve = function(ctx)
                    local lineCount, removeSpaces, addTabs = injectionInfoSettings()
                    local current = ctx:Get("AddressValue")
                    for _ = 1, math.floor(lineCount / 2) do
                        local previous = ce:GetPreviousOpcode(current)
                        if not previous then break end
                        current = previous
                    end
                    local lines = {}
                    for _ = 1, lineCount do
                        local line = ce:Disassemble(current)
                        if not line then break end
                        local cleanLine = line:gsub("{.-}", "")
                        local _, opcode, bytes, addressText = ce:SplitDisassembledString(cleanLine)
                        if not addressText or addressText == "" then break end
                        local name = ce:GetNameFromAddress(addressText) or addressText
                        bytes = type(bytes) == "string"
                            and bytes:gsub("%s+", ""):gsub("(%x%x)", "%1 "):sub(1, -2) or ""
                        if removeSpaces then bytes = bytes:gsub("%s+", "") end
                        lines[#lines + 1] = string.format("%s - %s - %s", name, bytes, opcode or "")
                        local size = ce:GetInstructionSize(current)
                        if not size or size < 1 or size > 15 then break end
                        current = current + size
                    end
                    if addTabs then
                        for index, line in ipairs(lines) do lines[index] = "\t  " .. line end
                    end
                    return table.concat(lines, "\n")
                end
            },
            InjInfoLineCount = {
                Type = "number",
                Description = "Configured injection-info line count",
                Resolve = function() return (injectionInfoSettings()) end
            },
            InjInfoRemoveSpaces = {
                Type = "boolean",
                Description = "Configured space removal for injection info",
                Resolve = function() return select(2, injectionInfoSettings()) end
            },
            InjInfoAddTabs = {
                Type = "boolean",
                Description = "Configured indentation for injection info",
                Resolve = function() return select(3, injectionInfoSettings()) end
            },
            AppendToHookName = {
                Type = "string",
                Description = "Effective hook-name suffix for this generation",
                Resolve = function(ctx) return ctx.Options.AppendToHookName end
            },
            AskForHookName = {
                Type = "boolean",
                Description = "Effective AskForHookName option",
                Resolve = function(ctx) return ctx.Options.AskForHookName == true end
            },
            AskForInjectionAddress = {
                Type = "boolean",
                Description = "Effective AskForInjectionAddress option",
                Resolve = function(ctx) return ctx.Options.AskForInjectionAddress == true end
            },
            AllocationSize = {
                Type = "string",
                Description = "Effective allocation size",
                Resolve = function(ctx) return ctx.Options.AllocationSize end
            },
            AllocationNear = {
                Type = "boolean",
                Description = "Effective near-allocation option",
                Resolve = function(ctx) return ctx.Options.AllocationNear == true end
            }
        }
    }
end

return Provider