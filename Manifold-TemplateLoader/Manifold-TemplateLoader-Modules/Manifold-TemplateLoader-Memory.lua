--[[
    Memory context collection for templates.

    Every public function avoids raising errors for an invalid selection. A failed
    memory read must result in a useful template error, never in a half-generated
    Auto Assembler script.
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Log = require("Manifold-TemplateLoader-Log")
local log = Log:New()

local Memory = {}
Memory.__index = Memory

local instance = nil

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function callSafely(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function isPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

function Memory:New()
    if not instance then
        instance = setmetatable({}, Memory)
        instance.InjInfoLineCount = 3
        instance.InjInfoRemoveSpaces = true
        instance.InjInfoAddTabs = true
        instance.AppendToHookName = "Hook"
        instance.AskForHookName = true
        instance.AskForInjectionAddress = false
        instance.AllocationSize = "$1000"
        instance.AllocationNear = true
        instance.DefaultHookName = "Injection"
    end
    return instance
end

-- Configuration -------------------------------------------------------------

function Memory:SetInjInfoLineCount(count)
    if not isPositiveInteger(count) then
        log:Warning("[Memory] Injection info line count must be a positive integer.")
        return false
    end
    self.InjInfoLineCount = count
    log:Debug("[Memory] Injection info line count set to " .. tostring(count))
    return true
end

function Memory:SetInjInfoRemoveSpaces(value)
    if type(value) ~= "boolean" then return false end
    self.InjInfoRemoveSpaces = value
    log:Debug("[Memory] Injection info remove spaces: " .. tostring(value))
    return true
end

function Memory:SetInjInfoAddTabs(value)
    if type(value) ~= "boolean" then return false end
    self.InjInfoAddTabs = value
    log:Debug("[Memory] Injection info indentation: " .. tostring(value))
    return true
end

function Memory:SetAppendToHookName(value)
    if type(value) ~= "string" then return false end
    self.AppendToHookName = trim(value) or ""
    log:Debug("[Memory] Hook-name suffix set to '" .. self.AppendToHookName .. "'")
    return true
end

function Memory:SetAskForHookName(value)
    if type(value) ~= "boolean" then return false end
    self.AskForHookName = value
    log:Debug("[Memory] AskForHookName: " .. tostring(value))
    return true
end

function Memory:SetAskForInjectionAddress(value)
    if type(value) ~= "boolean" then return false end
    self.AskForInjectionAddress = value
    log:Debug("[Memory] AskForInjectionAddress: " .. tostring(value))
    return true
end

function Memory:SetAllocationNear(value)
    if type(value) ~= "boolean" then return false end
    self.AllocationNear = value
    log:Debug("[Memory] AllocationNear: " .. tostring(value))
    return true
end

function Memory:SetDefaultHookName(value)
    value = trim(value)
    if not value or value == "" then return false end
    self.DefaultHookName = value
    log:Debug("[Memory] Default hook name set to '" .. value .. "'")
    return true
end

function Memory:NormalizeAllocationSize(value)
    if type(value) == "number" and isPositiveInteger(value) then
        return string.format("$%X", value)
    end
    value = trim(value)
    if not value or value == "" then return nil end
    local hexValue = value:match("^%$[%x]+$") and tonumber(value:sub(2), 16)
    if hexValue and hexValue > 0 then return value:upper() end
    if value:match("^%d+$") and tonumber(value) > 0 then return value end
    return nil
end

function Memory:SetAllocationSize(value)
    local normalized = self:NormalizeAllocationSize(value)
    if not normalized then
        log:Warning("[Memory] Allocation size must be a positive decimal or $HEX value.")
        return false
    end
    self.AllocationSize = normalized
    log:Debug("[Memory] Allocation size set to " .. normalized)
    return true
end

function Memory:GetConfig()
    return self.InjInfoLineCount, self.InjInfoRemoveSpaces, self.InjInfoAddTabs, self.AppendToHookName
end

function Memory:GetOptions(overrides)
    overrides = type(overrides) == "table" and overrides or {}
    local options = {
        AskForHookName = self.AskForHookName,
        AskForInjectionAddress = self.AskForInjectionAddress,
        AppendToHookName = self.AppendToHookName,
        AllocationSize = self.AllocationSize,
        AllocationNear = self.AllocationNear,
        DefaultHookName = self.DefaultHookName
    }
    for key, value in pairs(overrides) do
        if value ~= nil then options[key] = value end
    end
    options.AllocationSize = self:NormalizeAllocationSize(options.AllocationSize) or self.AllocationSize
    options.AppendToHookName = type(options.AppendToHookName) == "string" and options.AppendToHookName or self.AppendToHookName
    return options
end

-- Runtime and metadata ------------------------------------------------------

function Memory:GetCurrentDate() return os.date("%Y-%m-%d") end
function Memory:GetCurrentTime() return os.date("%H:%M:%S") end
function Memory:GetCurrentDateTime() return os.date("%Y-%m-%d %H:%M:%S") end

function Memory:IsTarget64Bit()
    return callSafely(targetIs64Bit) == true
end

function Memory:GetDefaultPointerSize()
    if self:IsTarget64Bit() then return "dq", 8 end
    return "dd", 4
end

function Memory:Is14ByteJump()
    for index = 0, (callSafely(getFormCount) or 0) - 1 do
        local form = callSafely(getForm, index)
        if form and form.ClassName == "TfrmAutoInject" and form.mi14ByteJMP then
            return form.mi14ByteJMP.Checked == true
        end
    end
    return false
end

function Memory:GetMinJumpSize()
    return self:Is14ByteJump() and 14 or 5
end

function Memory:GetJumpType()
    return self:Is14ByteJump() and "jmp far" or "jmp"
end

function Memory:GetProcessName()
    return type(process) == "string" and process ~= "" and process or nil
end

function Memory:FormatAddress(address)
    if type(address) ~= "number" then return nil end
    return self:IsTarget64Bit() and string.format("%016X", address) or string.format("%08X", address)
end

function Memory:GetProcessBase()
    local name = self:GetProcessName()
    return name and callSafely(getAddressSafe, name) or nil
end

function Memory:GetProcessBaseStr()
    return self:FormatAddress(self:GetProcessBase()) or "No process base found."
end

function Memory:GetSelectionAddress()
    local memoryView = callSafely(getMemoryViewForm)
    local disassembler = memoryView and memoryView.DisassemblerView
    local selected = disassembler and disassembler.SelectedAddress
    if not selected then return nil end
    return callSafely(getAddressSafe, selected) or selected
end

function Memory:GetSelection()
    local address = self:GetSelectionAddress()
    if not address then return nil end
    local selection = callSafely(getNameFromAddress, address, true, true, true) or self:FormatAddress(address)
    log:Debug("[Memory] Selected address: " .. tostring(selection))
    return selection
end

function Memory:GetModuleName(address)
    address = address and (callSafely(getAddressSafe, address) or address) or self:GetSelectionAddress()
    if not address or callSafely(inModule, address) ~= true then return nil end
    local value = callSafely(getNameFromAddress, address, true, false)
    if type(value) ~= "string" then return nil end
    return value:match("^(.*)[+-]%x+$") or value
end

function Memory:GetModuleBase(address)
    local name = self:GetModuleName(address)
    return name and callSafely(getAddressSafe, name) or nil
end

function Memory:GetModuleBaseStr(address)
    return self:FormatAddress(self:GetModuleBase(address)) or "No module base found."
end

-- Selection and instruction data -------------------------------------------

function Memory:IsValidInstructionSize(size)
    return isPositiveInteger(size) and size <= 15
end

function Memory:GetInstructionSize(address)
    address = callSafely(getAddressSafe, address) or address
    local size = address and callSafely(getInstructionSize, address)
    return self:IsValidInstructionSize(size) and size or nil
end

function Memory:GetInstructionSpan(address, minimumSize)
    address = callSafely(getAddressSafe, address) or address
    if not address or not isPositiveInteger(minimumSize) then return nil, "Invalid injection address or jump size" end

    local current, total = address, 0
    for _ = 1, 64 do
        if total >= minimumSize then
            log:Debug(string.format("[Memory] Overwrite span: %d byte(s) at $%X (minimum jump: %d).", total, address, minimumSize))
            return total
        end
        local size = self:GetInstructionSize(current)
        if not size then return nil, "Unable to determine instruction size at " .. tostring(current) end
        total = total + size
        current = current + size
    end
    return nil, "Too many instructions while calculating jump span"
end

function Memory:GetJumpSize(address, minimumSize)
    return self:GetInstructionSpan(address, minimumSize or self:GetMinJumpSize())
end

function Memory:GetSelectionSize(address)
    return self:GetInstructionSize(address or self:GetSelectionAddress()) or 0
end

function Memory:GetDisassembledOpcode(address)
    local disassembler = callSafely(getVisibleDisassembler)
    if not disassembler or not address then return nil end
    local line = callSafely(function() return disassembler.disassemble(address) end)
    if type(line) ~= "string" then return nil end
    local _, opcode = callSafely(splitDisassembledString, line)
    return type(opcode) == "string" and opcode:gsub("%{.-%}", "") or line:gsub("%{.-%}", "")
end

function Memory:GetOpcodes(startAddress, requiredSize)
    startAddress = callSafely(getAddressSafe, startAddress) or startAddress
    if not startAddress or not isPositiveInteger(requiredSize) then return nil, "Invalid opcode range" end

    local result, current, total = {}, startAddress, 0
    while total < requiredSize do
        local size = self:GetInstructionSize(current)
        if not size then return nil, "Unable to disassemble instruction at " .. tostring(current) end
        local opcode = self:GetDisassembledOpcode(current)
        if not opcode or opcode == "" then return nil, "Unable to disassemble instruction at " .. tostring(current) end
        result[#result + 1] = "  " .. opcode
        total = total + size
        current = current + size
    end
    local opcodes = table.concat(result, "\n")
    log:Debug(string.format("[Memory] Original instructions (%d byte(s)):\n%s", total, opcodes))
    return opcodes
end

function Memory:GetBytes(startAddress, requiredSize)
    startAddress = callSafely(getAddressSafe, startAddress) or startAddress
    if not startAddress or not isPositiveInteger(requiredSize) then return nil, "Invalid byte range" end

    local bytes, current, total = {}, startAddress, 0
    while total < requiredSize do
        local size = self:GetInstructionSize(current)
        if not size then return nil, "Unable to read instruction at " .. tostring(current) end
        local values = callSafely(readBytes, current, size, true)
        if type(values) ~= "table" or #values ~= size then
            return nil, "Unable to read bytes at " .. tostring(current)
        end
        for _, value in ipairs(values) do bytes[#bytes + 1] = string.format("%02X", value) end
        total = total + size
        current = current + size
    end
    local result = table.concat(bytes, " ")
    log:Debug(string.format("[Memory] Original bytes (%d): %s", total, result))
    return result
end

function Memory:GetNopPadding(actualSize, minimumSize)
    local padding = (actualSize or 0) - (minimumSize or 0)
    return padding > 0 and ("db " .. ("90 "):rep(padding):sub(1, -2) .. "\n") or ""
end

function Memory:GetRegisterData(instruction)
    if type(instruction) ~= "string" then return nil, nil end
    local register, offset = instruction:match("%[([%a][%w]*)%s*([+-]%s*[%x]+)?%]")
    if not register then return nil, nil end
    offset = (offset or "0"):gsub("%s+", "")
    if offset:sub(1, 1) == "+" then offset = offset:sub(2) end
    return register, offset
end

-- Template-specific values --------------------------------------------------

function Memory:NormalizeSymbolName(value)
    value = trim(value)
    if not value or value == "" then return nil end
    local normalized = value:gsub("[^%w_]", "_")
    if normalized:match("^%d") then normalized = "_" .. normalized end
    return normalized ~= "" and normalized or nil
end

function Memory:PromptForHookName(defaultName)
    return callSafely(inputQuery, "Hook Name", "Name for the generated hook:", defaultName or self.DefaultHookName)
end

function Memory:FormatHookName(hookName, append)
    append = type(append) == "string" and append or self.AppendToHookName
    if append == "" or hookName:sub(-#append) == append then return hookName end
    return hookName .. append
end

function Memory:GetHookNames(options)
    options = self:GetOptions(options)
    local requested = options.AskForHookName and self:PromptForHookName(options.DefaultHookName) or options.DefaultHookName
    if not requested or requested == "" then return nil, nil, "No hook name was provided" end

    local name = self:NormalizeSymbolName(requested)
    if not name then return nil, nil, "Hook name is invalid" end
    if name ~= requested then
        log:Warning("[Memory] Hook name was normalized to a valid Auto Assembler symbol: " .. name)
    end
    local parsed = self:FormatHookName(name, options.AppendToHookName)
    log:Debug(string.format("[Memory] Hook name: input='%s', symbol='%s', scan='%s'", tostring(requested), name, parsed))
    return name, parsed
end

function Memory:GetInjectionAddress(options)
    options = self:GetOptions(options)
    local selected = self:GetSelection()
    local requested = selected
    if options.AskForInjectionAddress then
        requested = callSafely(inputQuery, "Injection Address", "Address to use for the injection:", selected or "")
    end
    if not requested or requested == "" then return nil, nil, "No injection address was provided" end

    local address = callSafely(getAddressSafe, requested)
    if not address then return nil, nil, "Unable to resolve injection address '" .. tostring(requested) .. "'" end
    local resolved = callSafely(getNameFromAddress, address, true, true, true) or tostring(requested)
    log:Debug(string.format("[Memory] Injection address: %s ($%X)", resolved, address))
    return resolved, address
end

function Memory:GetAllocStatement(hookName, hookNameParsed, options)
    options = self:GetOptions(options)
    local size = options.AllocationSize
    if options.AllocationNear and not self:Is14ByteJump() then
        local statement = string.format("alloc(n_%s,%s,%s)", hookName, size, hookNameParsed)
        log:Debug("[Memory] Allocation statement: " .. statement)
        return statement
    end
    local statement = string.format("alloc(n_%s,%s)", hookName, size)
    log:Debug("[Memory] Allocation statement: " .. statement)
    return statement
end

function Memory:GetGlobalAllocStatement(hookName, options)
    options = self:GetOptions(options)
    local size = options.AllocationSize
    local statement = string.format("alloc(n_%s,%s)", hookName, size)
    log:Debug("[Memory] Global allocation statement: " .. statement)
    return statement
end

function Memory:GetAoB(address)
    address = callSafely(getAddressSafe, address) or address
    if not address then return nil, nil, "Unable to resolve injection address" end
    if not self:GetModuleName(address) then return nil, nil, "Injection address is not in a module" end

    local pattern, offset = callSafely(getUniqueAOB, address)
    if not pattern or pattern == "" then return nil, nil, "No unique AoB was found" end
    local suffix = offset and offset ~= 0 and ("+%X"):format(offset) or ""
    log:Debug(string.format("[Memory] Unique AoB: '%s' (offset '%s')", pattern, suffix))
    return pattern, suffix
end

function Memory:GetInjectionInfo(address, lineCount, removeSpaces)
    lineCount = lineCount == nil and self.InjInfoLineCount or lineCount
    removeSpaces = removeSpaces == nil and self.InjInfoRemoveSpaces or removeSpaces
    if not isPositiveInteger(lineCount) then return {} end

    local disassembler = callSafely(getVisibleDisassembler)
    if not disassembler then return {} end

    local current = callSafely(getAddressSafe, address) or address
    if not current then return {} end
    for _ = 1, math.floor(lineCount / 2) do
        local previous = callSafely(getPreviousOpcode, current)
        if not previous then break end
        current = previous
    end

    local lines = {}
    for _ = 1, lineCount do
        local line = callSafely(function() return disassembler.disassemble(current) end)
        if type(line) ~= "string" then break end
        local cleanLine = line:gsub("{.-}", "")
        local _, opcode, bytes, addressText = callSafely(splitDisassembledString, cleanLine)
        if not addressText or addressText == "" then break end
        local name = callSafely(getNameFromAddress, addressText) or addressText
        bytes = type(bytes) == "string" and bytes:gsub("%s+", ""):gsub("(%x%x)", "%1 "):sub(1, -2) or ""
        if removeSpaces then
            lines[#lines + 1] = string.format("%s - %s - %s", name, bytes:gsub("%s+", ""), opcode or "")
        else
            lines[#lines + 1] = string.format("%s - %s - %s", name, bytes, opcode or "")
        end
        local size = self:GetInstructionSize(current)
        if not size then break end
        current = current + size
    end
    log:Debug(string.format("[Memory] Injection info generated with %d line(s).", #lines))
    return lines
end

function Memory:GetInjectionInfoStr(address, lineCount, removeSpaces, addTabs)
    addTabs = addTabs == nil and self.InjInfoAddTabs or addTabs
    local lines = self:GetInjectionInfo(address, lineCount, removeSpaces)
    if addTabs then
        for index, line in ipairs(lines) do lines[index] = "\t  " .. line end
    end
    return table.concat(lines, "\n")
end

-- Mono / managed runtime support -------------------------------------------
-- TODO: Add an opt-in Mono context provider here. It should resolve a managed
-- method to its JIT address, class and field offsets without changing the native
-- memory workflow above. Until then templates receive only native x86/x64 data.

function Memory:GetMonoSupportStatus()
    return "TODO: managed Mono metadata and JIT-address resolution are not implemented yet."
end

-- Context assembly ----------------------------------------------------------

function Memory:GetMemoryInfo(overrides)
    local options = self:GetOptions(overrides)
    log:Debug(string.format(
        "[Memory] Building context (askAddress=%s, askHook=%s, allocation=%s, near=%s).",
        tostring(options.AskForInjectionAddress), tostring(options.AskForHookName),
        tostring(options.AllocationSize), tostring(options.AllocationNear)))
    local processName = self:GetProcessName()
    if not processName then return nil, "No target process is attached" end

    local addressText, address, addressErr = self:GetInjectionAddress(options)
    if not address then return nil, addressErr end
    local module = self:GetModuleName(address)
    if not module then return nil, "Injection address is not inside a loaded module" end

    local hookName, hookNameParsed, hookErr = self:GetHookNames(options)
    if not hookName then return nil, hookErr end

    local minimumJumpSize = self:GetMinJumpSize()
    local jumpSize, jumpErr = self:GetJumpSize(address, minimumJumpSize)
    if not jumpSize then return nil, jumpErr end

    local originalOpcodes, opcodeErr = self:GetOpcodes(address, jumpSize)
    local originalBytes, bytesErr = self:GetBytes(address, jumpSize)
    if not originalOpcodes or not originalBytes then return nil, opcodeErr or bytesErr end

    local aob, aobOffset, aobErr = self:GetAoB(address)
    if not aob then return nil, aobErr end

    local pointerType, pointerSize = self:GetDefaultPointerSize()
    local originalInstruction = self:GetDisassembledOpcode(address)
    local baseAddressRegister, baseAddressOffset = self:GetRegisterData(originalInstruction)

    local context = {
        Version = "2.1.0",
        Date = self:GetCurrentDate(),
        Time = self:GetCurrentTime(),
        DateTime = self:GetCurrentDateTime(),
        Process = processName,
        ProcessBase = self:GetProcessBaseStr(),
        Module = module,
        ModuleBase = self:GetModuleBaseStr(address),
        Address = addressText,
        AddressValue = address,
        PointerType = pointerType,
        PointerSize = pointerSize,
        DefaultPointerBytes = pointerSize,
        IsTarget64Bit = self:IsTarget64Bit(),
        Is14ByteJump = self:Is14ByteJump(),
        MinJumpSize = minimumJumpSize,
        JumpType = self:GetJumpType(),
        JumpSize = jumpSize,
        SelectionSize = self:GetSelectionSize(address),
        OriginalInstruction = originalInstruction,
        OriginalOpcodes = originalOpcodes,
        OriginalBytes = originalBytes,
        NopPadding = self:GetNopPadding(jumpSize, minimumJumpSize),
        BaseAddressRegister = baseAddressRegister or "",
        BaseAddressOffset = baseAddressOffset or "0",
        AoBStr = aob,
        AoBOffset = aobOffset,
        HookName = hookName,
        HookNameParsed = hookNameParsed,
        Alloc = self:GetAllocStatement(hookName, hookNameParsed, options),
        GlobalAlloc = self:GetGlobalAllocStatement(hookName, options),
        InjectionInfo = self:GetInjectionInfoStr(address),
        InjInfoLineCount = self.InjInfoLineCount,
        InjInfoRemoveSpaces = self.InjInfoRemoveSpaces,
        InjInfoAddTabs = self.InjInfoAddTabs,
        AppendToHookName = options.AppendToHookName,
        AskForHookName = options.AskForHookName,
        AskForInjectionAddress = options.AskForInjectionAddress,
        AllocationSize = options.AllocationSize,
        AllocationNear = options.AllocationNear,
        MonoSupportStatus = self:GetMonoSupportStatus()
    }
    log:Debug(string.format(
        "[Memory] Context ready: %s | %s | %s | x%s | jump=%d | hook=%s.",
        context.Process, context.Module, context.Address,
        context.IsTarget64Bit and "64" or "86", context.JumpSize, context.HookName))
    return context
end

return Memory
