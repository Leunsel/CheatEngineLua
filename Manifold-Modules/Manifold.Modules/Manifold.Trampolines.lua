local NAME = "Manifold.Trampolines.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Trampolines"

--[[
    v1.0.0 (2026-06-19)
        Added PE-header relay trampoline management for Auto Assembler detours.
        Provides install, inline original emission, destroy, and runtime reset helpers.
]]--

Trampolines = {
    HEADER_RELAY_MIN_OFFSET = 0x500,
    HEADER_RELAY_MAX_OFFSET = 0x1000,
    HEADER_RELAY_ALIGNMENT = 0x10,
    ActiveDetours = nil,
    PendingDetours = nil,
    PendingDestroys = nil,
    _txDepth = 0
}
Trampolines.__index = Trampolines

local MODULE_PREFIX = "[Trampolines]"

function Trampolines:New()
    local instance = setmetatable({}, self)
    instance:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.Author = AUTHOR
    instance.Version = VERSION
    instance.Description = DESCRIPTION
    instance.ActiveDetours = {}
    instance.PendingDetours = {}
    instance.PendingDestroys = {}
    instance._txDepth = 0
    return instance
end
registerLuaFunctionHighlight('New')

--
--- Ensures a dependency exists globally, and attempts to load it if missing.
--- @param dep table
--- @return boolean
--
function Trampolines:_ensureDependency(dep)
    local depName = dep.name
    if _G[depName] ~= nil then return true end
    if logger and logger.Warning then
        logger:Warning(MODULE_PREFIX .. " '" .. depName .. "' dependency not found. Attempting to load...")
    end
    local success, result = pcall(CETrequire, dep.path)
    if not success then
        if logger and logger.Error then
            logger:Error(MODULE_PREFIX .. " Failed to load dependency '" .. depName .. "': " .. tostring(result))
        end
        return false
    end
    if dep.init then dep.init() end
    return true
end

--
--- Ensures all required global dependencies for this module are loaded.
--- @return nil
--
function Trampolines:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger", init = function() logger = Logger:New() end }
    }
    for _, dep in ipairs(dependencies) do
        self:_ensureDependency(dep)
    end
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- Retrieves module metadata as a structured table.
--- @return table
--
function Trampolines:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

function Trampolines:_trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Trampolines:_stripQuotes(value)
    local text = self:_trim(value or "")
    local first = text:sub(1, 1)
    local last = text:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        return text:sub(2, -2)
    end
    return text
end

function Trampolines:_isBlank(value)
    return value == nil or self:_trim(value) == ""
end

function Trampolines:_parseNumber(value)
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
--- Resolves an address expression through CE helpers or numeric parsing.
--- @param expr any
--- @return number|nil
--- @return string|nil
--
function Trampolines:_resolveAddress(expr)
    local text = self:_stripQuotes(expr or "")
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
    if parsed then return parsed, nil end
    return nil, "could not resolve address: " .. text
end

function Trampolines:_readBytes(addr, count)
    local rb = rawget(_G, "readBytes")
    if type(rb) ~= "function" then return nil, "readBytes not available" end
    local ok, bytes = pcall(function() return rb(addr, count, true) end)
    if not ok then return nil, tostring(bytes) end
    if type(bytes) ~= "table" then return nil, "readBytes returned non-table" end
    return bytes, nil
end

function Trampolines:_writeBytes(addr, bytes)
    local wb = rawget(_G, "writeBytes")
    if type(wb) ~= "function" then return nil, "writeBytes not available" end
    local ok, result = pcall(function() return wb(addr, bytes) end)
    if not ok then return nil, tostring(result) end
    if result == false then return nil, "writeBytes returned false" end
    return true, nil
end

function Trampolines:_copyArray(values)
    local out = {}
    for i = 1, #(values or {}) do out[i] = values[i] end
    return out
end

function Trampolines:_fmtBytes(bytes)
    local parts = {}
    for i = 1, #(bytes or {}) do
        parts[#parts + 1] = string.format("%02X", bytes[i] or 0)
    end
    return table.concat(parts, " ")
end

function Trampolines:_fmtNumberArray(values)
    local parts = {}
    for i = 1, #(values or {}) do parts[#parts + 1] = tostring(values[i]) end
    return table.concat(parts, ", ")
end

function Trampolines:_formatDbDirective(bytes)
    local parts = {}
    for i = 1, #(bytes or {}) do
        parts[#parts + 1] = string.format("%02X", bytes[i] or 0)
    end
    return "  db " .. table.concat(parts, ",")
end

function Trampolines:_autoAssembleRestoreBytes(addr, bytes)
    local aa = rawget(_G, "autoAssemble")
    if type(aa) ~= "function" then return nil, "autoAssemble not available" end
    local script = table.concat({
        "fullAccess(" .. getNameFromAddress(addr) .. "," .. tostring(#bytes) .. ")",
        getNameFromAddress(addr) .. ":",
        self:_formatDbDirective(bytes)
    }, "\n")
    local ok, result = pcall(function() return aa(script) end)
    if not ok then return nil, tostring(result) end
    if not result then return nil, "autoAssemble returned false" end
    return true, nil
end

function Trampolines:_restoreBytes(addr, bytes, label)
    if not addr or not bytes or #bytes == 0 then return true, nil end
    local ok, err = self:_writeBytes(addr, bytes)
    if ok then return true, nil end
    logger:Warning(MODULE_PREFIX .. " Direct rollback write failed for " .. tostring(label) .. ": " .. tostring(err))
    local aaOk, aaErr = self:_autoAssembleRestoreBytes(addr, bytes)
    if aaOk then return true, nil end
    return nil, tostring(err) .. " | fallback: " .. tostring(aaErr)
end

function Trampolines:_unregisterSymbolSafe(symbol)
    local fn = rawget(_G, "unregisterSymbol") or rawget(_G, "unregistersymbol")
    if type(fn) ~= "function" then return end
    pcall(fn, symbol)
end

function Trampolines:_cleanupDetourSymbols(entry)
    local name = entry and entry.Name
    if not name or name == "" then return end
    self:_unregisterSymbolSafe(name .. "_Original")
    self:_unregisterSymbolSafe(name .. "_Return")
    self:_unregisterSymbolSafe(name .. "_Destination")
    self:_unregisterSymbolSafe(name .. "_Relay")
    self:_unregisterSymbolSafe(name .. "_Block")
end

function Trampolines:_signed8(value)
    value = tonumber(value) or 0
    if value >= 0x80 then return value - 0x100 end
    return value
end

function Trampolines:_signed32(bytes, startIndex)
    startIndex = startIndex or 1
    local value = 0
    for i = 0, 3 do
        value = value + ((bytes[startIndex + i] or 0) * (0x100 ^ i))
    end
    if value >= 0x80000000 then return value - 0x100000000 end
    return value
end

function Trampolines:_extractInstructionText(text)
    if type(text) ~= "string" then return nil end
    local instruction = text:match("^.-%s%-%s.-%s%-%s(.+)$") or text
    instruction = self:_trim(instruction)
    if instruction == "" then return nil end
    return instruction
end

function Trampolines:_conditionMnemonic(condition)
    local names = {
        [0x0] = "jo",
        [0x1] = "jno",
        [0x2] = "jb",
        [0x3] = "jae",
        [0x4] = "je",
        [0x5] = "jne",
        [0x6] = "jbe",
        [0x7] = "ja",
        [0x8] = "js",
        [0x9] = "jns",
        [0xA] = "jp",
        [0xB] = "jnp",
        [0xC] = "jl",
        [0xD] = "jge",
        [0xE] = "jle",
        [0xF] = "jg"
    }
    return names[condition]
end

function Trampolines:_analyzeRelativeControlFlow(addr, bytes, size)
    local b1 = bytes[1] or 0
    if b1 >= 0x70 and b1 <= 0x7F and size >= 2 then
        local condition = b1 - 0x70
        return {
            Kind = "jcc",
            Condition = condition,
            Inverse = condition ~ 1,
            Target = addr + size + self:_signed8(bytes[2])
        }
    end
    if b1 == 0x0F then
        local b2 = bytes[2] or 0
        if b2 >= 0x80 and b2 <= 0x8F and size >= 6 then
            local condition = b2 - 0x80
            return {
                Kind = "jcc",
                Condition = condition,
                Inverse = condition ~ 1,
                Target = addr + size + self:_signed32(bytes, 3)
            }
        end
    end
    if b1 == 0xE8 and size >= 5 then
        return { Kind = "call", Target = addr + size + self:_signed32(bytes, 2) }
    end
    if b1 == 0xE9 and size >= 5 then
        return { Kind = "jmp", Target = addr + size + self:_signed32(bytes, 2) }
    end
    if b1 == 0xEB and size >= 2 then
        return { Kind = "jmp", Target = addr + size + self:_signed8(bytes[2]) }
    end
    return nil
end

function Trampolines:_formatAddressLiteral(addr)
    if type(addr) ~= "number" then return tostring(addr) end
    local getNameFn = rawget(_G, "getNameFromAddress")
    if type(getNameFn) == "function" then
        local ok, name = pcall(function() return getNameFn(addr) end)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return string.format("%X", addr)
end

function Trampolines:_getInstructionBytes(entry, index)
    local offset = entry.InstructionOffsets[index] or 0
    local size = entry.InstructionSizes[index] or 0
    local bytes = {}
    for byteIndex = 1, size do bytes[byteIndex] = entry.OriginalBytes[offset + byteIndex] end
    return bytes, offset, size
end

function Trampolines:_textUsesRegister(text, registerName)
    local lower = tostring(text or ""):lower()
    return lower:match("%f[%w_]" .. registerName:lower() .. "%f[^%w_]") ~= nil
end

function Trampolines:_containsAnyRegister(text)
    local registers = {
        "rax", "eax", "ax", "al", "rbx", "ebx", "bx", "bl",
        "rcx", "ecx", "cx", "cl", "rdx", "edx", "dx", "dl",
        "rsi", "esi", "si", "sil", "rdi", "edi", "di", "dil",
        "rbp", "ebp", "bp", "bpl", "rsp", "esp", "sp", "spl",
        "r8", "r8d", "r8w", "r8b", "r9", "r9d", "r9w", "r9b",
        "r10", "r10d", "r10w", "r10b", "r11", "r11d", "r11w", "r11b",
        "r12", "r12d", "r12w", "r12b", "r13", "r13d", "r13w", "r13b",
        "r14", "r14d", "r14w", "r14b", "r15", "r15d", "r15w", "r15b"
    }
    for _, registerName in ipairs(registers) do
        if self:_textUsesRegister(text, registerName) then return true end
    end
    return false
end

function Trampolines:_selectTempRegister(instruction)
    local candidates = { "r11", "r10", "r9", "r8", "rax", "rcx", "rdx", "rbx" }
    for _, registerName in ipairs(candidates) do
        if not self:_textUsesRegister(instruction, registerName) then return registerName end
    end
    return nil
end

function Trampolines:_rewriteAbsoluteMemoryInstruction(instruction)
    if not self:_isTarget64Bit() then return nil end
    if self:_textUsesRegister(instruction, "rsp") or self:_textUsesRegister(instruction, "esp") then return nil end
    local inner = instruction:match("%[([^%]]+)%]")
    if not inner or inner == "" then return nil end
    if self:_containsAnyRegister(inner) then return nil end
    local address = self:_stripQuotes(inner)
    if address == "" then return nil end
    local resolved = self:_resolveAddress(address)
    if not resolved then return nil end
    local temp = self:_selectTempRegister(instruction)
    if not temp then return nil end
    local rewritten = instruction:gsub("%[" .. inner:gsub("([^%w])", "%%%1") .. "%]", "[" .. temp .. "]", 1)
    return {
        "  push " .. temp,
        "  mov " .. temp .. "," .. address,
        "  " .. rewritten,
        "  pop " .. temp
    }
end

function Trampolines:_buildRelocatedInstruction(entry, index, lines)
    local bytes, offset, size = self:_getInstructionBytes(entry, index)
    local source = entry.InjectAddress + offset
    local relative = self:_analyzeRelativeControlFlow(source, bytes, size)
    if relative then
        local target = self:_formatAddressLiteral(relative.Target)
        if relative.Kind == "jcc" then
            local inverse = self:_conditionMnemonic(relative.Inverse)
            if not inverse then
                logger:Warning(MODULE_PREFIX .. " Unknown conditional jump at " .. self:_formatAddressLiteral(source) .. "; falling back to original bytes.")
                lines[#lines + 1] = self:_formatDbDirective(bytes)
                return
            end
            -- Avoid generated labels here. CE command-injected labels are not always visible to branch operands.
            lines[#lines + 1] = self:_formatDbDirective({ 0x70 + relative.Inverse, 0x0E })
            lines[#lines + 1] = "  jmp far " .. target
            logger:Debug(MODULE_PREFIX .. " Relocated conditional jump from " .. self:_formatAddressLiteral(source) .. " to " .. target)
            return false
        end
        if relative.Kind == "jmp" then
            lines[#lines + 1] = "  jmp far " .. target
            logger:Debug(MODULE_PREFIX .. " Relocated jump from " .. self:_formatAddressLiteral(source) .. " to " .. target)
            return true
        end
        if relative.Kind == "call" then
            lines[#lines + 1] = "  mov r11," .. target
            lines[#lines + 1] = "  call r11"
            logger:Debug(MODULE_PREFIX .. " Relocated call from " .. self:_formatAddressLiteral(source) .. " to " .. target)
            return false
        end
    end

    local text = self:_extractInstructionText(self:_getInstructionText(source))
    if text then
        local rewritten = self:_rewriteAbsoluteMemoryInstruction(text)
        if rewritten then
            for _, line in ipairs(rewritten) do lines[#lines + 1] = line end
        else
            lines[#lines + 1] = "  " .. text
        end
        return text:lower():match("^ret%f[^%w_]") ~= nil
    end
    logger:Warning(MODULE_PREFIX .. " Could not disassemble original instruction at " .. self:_formatAddressLiteral(source) .. "; falling back to original bytes.")
    lines[#lines + 1] = self:_formatDbDirective(bytes)
    return false
end

function Trampolines:_isTarget64Bit()
    local targetIs64BitFn = rawget(_G, "targetIs64Bit")
    if type(targetIs64BitFn) == "function" then
        local ok, result = pcall(targetIs64BitFn)
        if ok then return result == true end
    end
    return false
end

function Trampolines:_alignUp(value, alignment)
    alignment = alignment or self.HEADER_RELAY_ALIGNMENT
    return math.floor((value + alignment - 1) / alignment) * alignment
end

function Trampolines:_readLittleEndian(addr, count)
    local bytes, err = self:_readBytes(addr, count)
    if not bytes then return nil, err end
    local value = 0
    for i = 1, count do
        value = value + ((bytes[i] or 0) * (0x100 ^ (i - 1)))
    end
    return value, nil
end

function Trampolines:_getInstructionSize(addr)
    local fn = rawget(_G, "getInstructionSize")
    if type(fn) ~= "function" then return nil, "getInstructionSize not available" end
    local ok, size = pcall(function() return fn(addr) end)
    if not ok then return nil, tostring(size) end
    size = tonumber(size)
    if not size or size <= 0 then
        return nil, "invalid instruction size at " .. getNameFromAddress(addr) .. ": " .. tostring(size)
    end
    return size, nil
end

function Trampolines:_getInstructionText(addr)
    local fn = rawget(_G, "disassemble")
    if type(fn) ~= "function" then return nil end
    local ok, text = pcall(function() return fn(addr) end)
    if ok and type(text) == "string" then return text end
    return nil
end

function Trampolines:_looksLikeControlFlowInstruction(text)
    if type(text) ~= "string" then return false end
    local lower = text:lower()
    return lower:match("%f[%a]j[a-z]+%f[%A]") ~= nil
        or lower:match("%f[%a]call%f[%A]") ~= nil
        or lower:match("%f[%a]ret%f[%A]") ~= nil
        or lower:match("%f[%a]loop[a-z]*%f[%A]") ~= nil
end

function Trampolines:_collectInstructionRange(addr, minSize)
    if type(addr) ~= "number" then return nil, "invalid instruction address" end
    local needed = math.max(5, tonumber(minSize) or 5)
    local offsets, sizes = {}, {}
    local offset = 0
    while offset < needed do
        local current = addr + offset
        local size, sizeErr = self:_getInstructionSize(current)
        if not size then return nil, sizeErr end
        if offset == 0 then
            local instructionText = self:_getInstructionText(current)
            if self:_looksLikeControlFlowInstruction(instructionText) then
                logger:Warning(MODULE_PREFIX .. " Detour starts on a control-flow instruction: " .. tostring(instructionText))
                logger:Warning(MODULE_PREFIX .. " ManifoldEmitOriginal will relocate the original instruction block.")
            end
        end
        offsets[#offsets + 1] = offset
        sizes[#sizes + 1] = size
        offset = offset + size
    end
    return { OverwriteSize = offset, Offsets = offsets, Sizes = sizes, InstructionCount = #offsets }, nil
end

function Trampolines:_buildRel32Jump(source, target)
    if type(source) ~= "number" or type(target) ~= "number" then
        return nil, "source and target must be numeric addresses"
    end
    local rel = target - (source + 5)
    if rel < -0x80000000 or rel > 0x7FFFFFFF then
        return nil, "target is outside rel32 range"
    end
    if rel < 0 then rel = rel + 0x100000000 end
    return {
        0xE9,
        rel % 0x100,
        math.floor(rel / 0x100) % 0x100,
        math.floor(rel / 0x10000) % 0x100,
        math.floor(rel / 0x1000000) % 0x100
    }, nil
end

function Trampolines:_resolveModuleForAddress(addr)
    local addressName = getNameFromAddress(addr)
    local moduleName = type(addressName) == "string" and addressName:match("^([^+]+)%+") or nil
    if not moduleName then return nil, "could not determine module from address " .. tostring(addressName) end
    local moduleBase, err = self:_resolveAddress(moduleName)
    if not moduleBase then return nil, "could not resolve module base '" .. tostring(moduleName) .. "': " .. tostring(err) end
    return { Name = moduleName, Base = moduleBase, AddressName = addressName }, nil
end

function Trampolines:_getPeHeaderInfo(addr)
    local moduleInfo, moduleErr = self:_resolveModuleForAddress(addr)
    if not moduleInfo then return nil, moduleErr end
    local mz = self:_readLittleEndian(moduleInfo.Base, 2)
    if mz ~= 0x5A4D then return nil, "module header does not start with MZ" end
    local peOffset, peOffsetErr = self:_readLittleEndian(moduleInfo.Base + 0x3C, 4)
    if not peOffset then return nil, "failed to read PE header offset: " .. tostring(peOffsetErr) end
    local ntHeader = moduleInfo.Base + peOffset
    local peSig = self:_readLittleEndian(ntHeader, 4)
    if peSig ~= 0x00004550 then return nil, "invalid PE signature" end
    local sectionCount, sectionErr = self:_readLittleEndian(ntHeader + 0x06, 2)
    if not sectionCount then return nil, "failed to read section count: " .. tostring(sectionErr) end
    local optionalSize, optionalErr = self:_readLittleEndian(ntHeader + 0x14, 2)
    if not optionalSize then return nil, "failed to read optional header size: " .. tostring(optionalErr) end
    local optionalHeader = ntHeader + 0x18
    local sizeOfHeaders, headersErr = self:_readLittleEndian(optionalHeader + 0x3C, 4)
    if not sizeOfHeaders then return nil, "failed to read SizeOfHeaders: " .. tostring(headersErr) end
    return {
        ModuleName = moduleInfo.Name,
        ModuleBase = moduleInfo.Base,
        SectionHeadersEnd = optionalHeader + optionalSize + (sectionCount * 0x28),
        SizeOfHeaders = sizeOfHeaders
    }, nil
end

function Trampolines:_isHeaderCaveFree(addr, size)
    local bytes = self:_readBytes(addr, size)
    if not bytes then return false end
    for i = 1, #bytes do
        local byte = bytes[i]
        if byte ~= 0x00 and byte ~= 0xCC then return false end
    end
    return true
end

function Trampolines:_isHeaderRelaySlotReserved(addr, size)
    local stopAddr = addr + size - 1
    if self:_relaySlotOverlapsStore(self.ActiveDetours, addr, stopAddr) then return true end
    if self:_relaySlotOverlapsStore(self.PendingDetours, addr, stopAddr) then return true end
    return false
end

function Trampolines:_findHeaderRelaySlot(injectAddr, slotSize)
    local header, headerErr = self:_getPeHeaderInfo(injectAddr)
    if not header then return nil, headerErr end
    local minStart = header.ModuleBase + self.HEADER_RELAY_MIN_OFFSET
    local sectionSafeStart = self:_alignUp(header.SectionHeadersEnd, self.HEADER_RELAY_ALIGNMENT)
    local searchStart = math.max(minStart, sectionSafeStart)
    local searchLimitOffset = math.max(header.SizeOfHeaders, self.HEADER_RELAY_MAX_OFFSET)
    local searchEnd = header.ModuleBase + searchLimitOffset - slotSize
    if searchEnd < searchStart then
        return nil, "PE header relay range is empty from "
            .. getNameFromAddress(searchStart)
            .. " to "
            .. getNameFromAddress(searchEnd)
            .. " (SizeOfHeaders="
            .. string.format("0x%X", header.SizeOfHeaders)
            .. ")"
    end
    for addr = searchStart, searchEnd, self.HEADER_RELAY_ALIGNMENT do
        if not self:_isHeaderRelaySlotReserved(addr, slotSize)
            and self:_isHeaderCaveFree(addr, slotSize)
            and self:_buildRel32Jump(injectAddr, addr) then
            return {
                Address = addr,
                Size = slotSize,
                ModuleName = header.ModuleName,
                ModuleBase = header.ModuleBase,
                Offset = addr - header.ModuleBase
            }, nil
        end
    end
    return nil, "no free PE-header relay slot found from " .. getNameFromAddress(searchStart) .. " to " .. getNameFromAddress(searchEnd)
end

function Trampolines:_makeDetourKey(name)
    return self:_stripQuotes(name or ""):lower()
end

function Trampolines:_relaySlotOverlapsStore(store, addr, stopAddr)
    for _, entry in pairs(store or {}) do
        local relayAddr = entry.RelayAddress
        local relaySize = entry.RelaySize
        if relayAddr and relaySize then
            local relayStop = relayAddr + relaySize - 1
            if addr <= relayStop and stopAddr >= relayAddr then return true end
        end
    end
    return false
end

function Trampolines:_isTransactionActive()
    return (self._txDepth or 0) > 0
end

function Trampolines:_tableKeys(store)
    local keys = {}
    for key in pairs(store or {}) do keys[#keys + 1] = key end
    return keys
end

function Trampolines:_getDetour(name)
    local key = self:_makeDetourKey(name)
    return (self.ActiveDetours or {})[key] or (self.PendingDetours or {})[key]
end

function Trampolines:_storeDetour(entry, pending)
    self.ActiveDetours = self.ActiveDetours or {}
    self.PendingDetours = self.PendingDetours or {}
    local key = self:_makeDetourKey(entry.Name)
    if self.ActiveDetours[key] or self.PendingDetours[key] then return nil, "detour '" .. tostring(entry.Name) .. "' is already active" end
    entry.Key = key
    if pending then
        entry.Active = false
        entry.Pending = true
        self.PendingDetours[key] = entry
    else
        entry.Active = true
        entry.Pending = false
        self.ActiveDetours[key] = entry
    end
    return entry, nil
end

function Trampolines:_removeDetour(name)
    self.ActiveDetours = self.ActiveDetours or {}
    self.PendingDetours = self.PendingDetours or {}
    self.PendingDestroys = self.PendingDestroys or {}
    local key = self:_makeDetourKey(name)
    local entry = self.ActiveDetours[key] or self.PendingDetours[key]
    self.ActiveDetours[key] = nil
    self.PendingDetours[key] = nil
    self.PendingDestroys[key] = nil
    return entry
end

function Trampolines:_markDestroyPending(entry)
    self.PendingDestroys = self.PendingDestroys or {}
    local key = entry.Key or self:_makeDetourKey(entry.Name)
    entry.PendingDestroy = true
    self.PendingDestroys[key] = entry
end

function Trampolines:BeginTransaction()
    self._txDepth = (self._txDepth or 0) + 1
    if self._txDepth == 1 then
        self.PendingDetours = self.PendingDetours or {}
        self.PendingDestroys = self.PendingDestroys or {}
        logger:Debug(MODULE_PREFIX .. " Started detour transaction.")
    end
end
registerLuaFunctionHighlight('BeginTransaction')

function Trampolines:_rollbackPendingInstall(key, entry, reason)
    logger:Warning(MODULE_PREFIX .. " Rolling back pending detour '" .. tostring(entry.Name) .. "'." .. (reason and " Reason: " .. tostring(reason) or ""))
    local injectOk, injectErr = self:_restoreBytes(entry.InjectAddress, entry.OriginalBytes, entry.Name .. " inject")
    local relayOk, relayErr = self:_restoreBytes(entry.RelayAddress, entry.RelayOriginalBytes, entry.Name .. " relay")
    if not injectOk or not relayOk then
        logger:Error(MODULE_PREFIX .. " Rollback restore failed for '" .. tostring(entry.Name) .. "': inject=" .. tostring(injectErr) .. " relay=" .. tostring(relayErr))
    end
    self:_cleanupDetourSymbols(entry)
    entry.Active = false
    entry.Pending = false
    self.PendingDetours[key] = nil
    self.ActiveDetours[key] = nil
end

function Trampolines:CommitTransaction()
    if (self._txDepth or 0) <= 0 then return end
    if self._txDepth > 1 then
        self._txDepth = self._txDepth - 1
        return
    end
    self.ActiveDetours = self.ActiveDetours or {}
    self.PendingDetours = self.PendingDetours or {}
    self.PendingDestroys = self.PendingDestroys or {}
    for _, key in ipairs(self:_tableKeys(self.PendingDetours)) do
        local entry = self.PendingDetours[key]
        entry.Active = true
        entry.Pending = false
        self.ActiveDetours[key] = entry
        self.PendingDetours[key] = nil
        logger:Debug(MODULE_PREFIX .. " Committed detour '" .. tostring(entry.Name) .. "'.")
    end
    for _, key in ipairs(self:_tableKeys(self.PendingDestroys)) do
        local entry = self.PendingDestroys[key]
        entry.Active = false
        entry.PendingDestroy = false
        self.ActiveDetours[key] = nil
        self.PendingDetours[key] = nil
        self.PendingDestroys[key] = nil
        logger:Debug(MODULE_PREFIX .. " Committed detour destroy '" .. tostring(entry.Name) .. "'.")
    end
    self._txDepth = 0
    logger:Debug(MODULE_PREFIX .. " Completed detour transaction.")
end
registerLuaFunctionHighlight('CommitTransaction')

function Trampolines:RollbackTransaction(reason)
    if (self._txDepth or 0) <= 0 then return end
    self.ActiveDetours = self.ActiveDetours or {}
    self.PendingDetours = self.PendingDetours or {}
    self.PendingDestroys = self.PendingDestroys or {}
    for _, key in ipairs(self:_tableKeys(self.PendingDetours)) do
        local entry = self.PendingDetours[key]
        self:_rollbackPendingInstall(key, entry, reason)
    end
    for _, key in ipairs(self:_tableKeys(self.PendingDestroys)) do
        local entry = self.PendingDestroys[key]
        entry.PendingDestroy = false
        self.PendingDestroys[key] = nil
        logger:Debug(MODULE_PREFIX .. " Cancelled pending detour destroy '" .. tostring(entry.Name) .. "'.")
    end
    self._txDepth = 0
    logger:Debug(MODULE_PREFIX .. " Rolled back detour transaction.")
end
registerLuaFunctionHighlight('RollbackTransaction')

function Trampolines:_resolveDestination(name, expr)
    if not self:_isBlank(expr) then
        local addr, err = self:_resolveAddress(expr)
        local normalized = self:_stripQuotes(expr)
        if not addr then logger:Debug(MODULE_PREFIX .. " Destination '" .. normalized .. "' is not resolvable from Lua yet: " .. tostring(err)) end
        return addr, normalized, nil
    end
    local inferred = name .. "Code"
    logger:Info(MODULE_PREFIX .. " Inferred detour destination '" .. inferred .. "' for '" .. name .. "'.")
    return self:_resolveAddress(inferred), inferred, nil
end

function Trampolines:BuildSyntaxScript(name)
    local symbols = { name .. "_Block", name .. "_Relay", name .. "_Destination", name .. "_Return" }
    local lines = {}
    for _, symbol in ipairs(symbols) do lines[#lines + 1] = "label(" .. symbol .. ")" end
    for _, symbol in ipairs(symbols) do lines[#lines + 1] = symbol .. ":" end
    return table.concat(lines, "\n")
end
registerLuaFunctionHighlight('BuildSyntaxScript')

function Trampolines:BuildOriginalSyntaxScript(name)
    return "label(" .. name .. "_Original)\n\n" .. name .. "_Original:"
end
registerLuaFunctionHighlight('BuildOriginalSyntaxScript')

function Trampolines:BuildReturnSyntaxScript(name)
    return "label(" .. name .. "_Return)"
end
registerLuaFunctionHighlight('BuildReturnSyntaxScript')

function Trampolines:_buildInstallScript(entry)
    local name = entry.Name
    local block = name .. "_Block"
    local relay = name .. "_Relay"
    local destination = name .. "_Destination"
    local returnLabel = name .. "_Return"
    local is64Bit = self:_isTarget64Bit()
    local pointerSize = is64Bit and "qword" or "dword"
    local dataDirective = is64Bit and "dq" or "dd"
    local destinationAddress = entry.RelayAddress + 6
    local lines = {
        "define(" .. block .. "," .. getNameFromAddress(entry.RelayAddress) .. ")",
        "define(" .. relay .. "," .. getNameFromAddress(entry.RelayAddress) .. ")",
        "define(" .. destination .. "," .. getNameFromAddress(destinationAddress) .. ")",
        "define(" .. returnLabel .. "," .. getNameFromAddress(entry.ReturnAddress) .. ")",
        "",
        "fullAccess(" .. relay .. "," .. tostring(entry.RelaySize) .. ")",
        "",
        "registersymbol(" .. block .. ")",
        "registersymbol(" .. relay .. ")",
        "registersymbol(" .. destination .. ")",
        "registersymbol(" .. returnLabel .. ")",
        "",
        block .. ":",
        "",
        relay .. ":",
        "  jmp " .. pointerSize .. " ptr [" .. destination .. "]",
        "",
        destination .. ":",
        "  " .. dataDirective .. " " .. entry.DestinationExpression,
        "",
        entry.InjectExpression .. ":",
        "  jmp " .. relay
    }
    for _ = 1, entry.OverwriteSize - 5 do lines[#lines + 1] = "  nop" end
    return table.concat(lines, "\n")
end

function Trampolines:_buildOriginalRelocatedScript(entry, lines)
    for index in ipairs(entry.InstructionOffsets) do
        local terminal = self:_buildRelocatedInstruction(entry, index, lines)
        if terminal then return true end
    end
    return false
end

function Trampolines:_buildOriginalScript(entry)
    local original = entry.Name .. "_Original"
    local lines = { "label(" .. original .. ")", "", original .. ":" }
    local terminal = self:_buildOriginalRelocatedScript(entry, lines)
    if not terminal then
        lines[#lines + 1] = "  jmp " .. entry.Name .. "_Return"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "registersymbol(" .. original .. ")"
    return table.concat(lines, "\n")
end

function Trampolines:_buildReturnScript(entry)
    return "  jmp " .. entry.Name .. "_Return"
end

function Trampolines:_buildDestroyScript(entry)
    local name = entry.Name
    local lines = {
        getNameFromAddress(entry.InjectAddress) .. ":",
        self:_formatDbDirective(entry.OriginalBytes),
        "",
        getNameFromAddress(entry.RelayAddress) .. ":",
        self:_formatDbDirective(entry.RelayOriginalBytes),
        ""
    }
    if entry.OriginalEmitted then
        lines[#lines + 1] = "unregistersymbol(" .. name .. "_Original)"
    end
    lines[#lines + 1] = "unregistersymbol(" .. name .. "_Return)"
    lines[#lines + 1] = "unregistersymbol(" .. name .. "_Destination)"
    lines[#lines + 1] = "unregistersymbol(" .. name .. "_Relay)"
    lines[#lines + 1] = "unregistersymbol(" .. name .. "_Block)"
    return table.concat(lines, "\n")
end

function Trampolines:_logInstall(entry)
    logger:Info(MODULE_PREFIX .. " InstallDetour OK")
    logger:InfoF("   Name        : %s", entry.Name)
    logger:InfoF("   Inject      : %s", getNameFromAddress(entry.InjectAddress))
    logger:InfoF("   Destination : %s", entry.DestinationExpression)
    if entry.DestinationAddress then logger:InfoF("   Dest Address: %s", getNameFromAddress(entry.DestinationAddress)) end
    logger:InfoF("   Relay       : %s", getNameFromAddress(entry.RelayAddress))
    logger:InfoF("   Relay Offset: %s+%X", tostring(entry.RelayModuleName), entry.RelayOffset or 0)
    logger:InfoF("   Relay Size  : %d bytes", entry.RelaySize or 0)
    logger:InfoF("   Overwrite   : %d bytes", entry.OverwriteSize)
    logger:InfoF("   Return      : %s", getNameFromAddress(entry.ReturnAddress))
    logger:InfoF("   Instructions: %d", entry.InstructionCount)
    logger:InfoF("   Offsets     : %s", self:_fmtNumberArray(entry.InstructionOffsets))
    logger:InfoF("   Sizes       : %s", self:_fmtNumberArray(entry.InstructionSizes))
    logger:InfoF("   Original    : %s", self:_fmtBytes(entry.OriginalBytes))
    logger:InfoF("   Relay Backup: %s", self:_fmtBytes(entry.RelayOriginalBytes))
end

function Trampolines:InstallDetour(name, injectExpr, destinationExpr, minOverwriteSize)
    local injectAddr, injectErr = self:_resolveAddress(injectExpr)
    if not injectAddr then return nil, nil, "cannot resolve inject address '" .. tostring(injectExpr) .. "': " .. tostring(injectErr) end
    local destinationAddr, normalizedDestination, destinationErr = self:_resolveDestination(name, destinationExpr)
    if not normalizedDestination then return nil, nil, "cannot build destination expression: " .. tostring(destinationErr) end
    local range, rangeErr = self:_collectInstructionRange(injectAddr, minOverwriteSize)
    if not range then return nil, nil, rangeErr end
    local originalBytes, readErr = self:_readBytes(injectAddr, range.OverwriteSize)
    if not originalBytes then return nil, nil, "failed to read original bytes: " .. tostring(readErr) end
    local pointerBytes = self:_isTarget64Bit() and 8 or 4
    local relaySize = self:_alignUp(6 + pointerBytes, self.HEADER_RELAY_ALIGNMENT)
    local relaySlot, relayErr = self:_findHeaderRelaySlot(injectAddr, relaySize)
    if not relaySlot then return nil, nil, "failed to find PE-header relay slot: " .. tostring(relayErr) end
    local relayOriginalBytes, relayReadErr = self:_readBytes(relaySlot.Address, relaySlot.Size)
    if not relayOriginalBytes then return nil, nil, "failed to read relay slot bytes: " .. tostring(relayReadErr) end
    local entry = {
        Name = name,
        InjectExpression = self:_stripQuotes(injectExpr),
        InjectAddress = injectAddr,
        DestinationExpression = normalizedDestination,
        DestinationAddress = destinationAddr,
        OverwriteSize = range.OverwriteSize,
        ReturnAddress = injectAddr + range.OverwriteSize,
        InstructionCount = range.InstructionCount,
        InstructionOffsets = self:_copyArray(range.Offsets),
        InstructionSizes = self:_copyArray(range.Sizes),
        OriginalBytes = self:_copyArray(originalBytes),
        RelayAddress = relaySlot.Address,
        RelaySize = relaySlot.Size,
        RelayModuleName = relaySlot.ModuleName,
        RelayModuleBase = relaySlot.ModuleBase,
        RelayOffset = relaySlot.Offset,
        RelayOriginalBytes = self:_copyArray(relayOriginalBytes),
        InstallMode = "header-relay"
    }
    entry.InstallScript = self:_buildInstallScript(entry)
    local stored, storeErr = self:_storeDetour(entry, self:_isTransactionActive())
    if not stored then return nil, nil, storeErr end
    self:_logInstall(entry)
    logger:Debug("   Generated AA:\n" .. entry.InstallScript)
    return entry, entry.InstallScript, nil
end
registerLuaFunctionHighlight('InstallDetour')

function Trampolines:EmitOriginal(name)
    local entry = self:_getDetour(name)
    if not entry then return nil, nil, "no active detour found for '" .. tostring(name) .. "'" end
    entry.OriginalEmitted = true
    local script = self:_buildOriginalScript(entry)
    logger:Info(MODULE_PREFIX .. " EmitOriginal OK")
    logger:InfoF("   Name    : %s", entry.Name)
    logger:Info("   Mode    : relocated")
    logger:InfoF("   Original: %s", self:_fmtBytes(entry.OriginalBytes))
    logger:Debug("   Generated AA:\n" .. script)
    return entry, script, nil
end
registerLuaFunctionHighlight('EmitOriginal')

function Trampolines:EmitReturn(name)
    local entry = self:_getDetour(name)
    if not entry then return nil, nil, "no active detour found for '" .. tostring(name) .. "'" end
    local script = self:_buildReturnScript(entry)
    logger:Info(MODULE_PREFIX .. " EmitReturn OK")
    logger:InfoF("   Name  : %s", entry.Name)
    logger:Debug("   Generated AA:\n" .. script)
    return entry, script, nil
end
registerLuaFunctionHighlight('EmitReturn')

function Trampolines:DestroyDetour(name)
    local entry = self:_getDetour(name)
    if not entry then return nil, nil, "no active detour found for '" .. tostring(name) .. "'" end
    local script = self:_buildDestroyScript(entry)
    if self:_isTransactionActive() then
        self:_markDestroyPending(entry)
    else
        self:_removeDetour(name)
    end
    logger:Info(MODULE_PREFIX .. " DestroyDetour OK")
    logger:InfoF("   Name    : %s", entry.Name)
    logger:InfoF("   Inject  : %s", getNameFromAddress(entry.InjectAddress))
    logger:InfoF("   Relay   : %s", getNameFromAddress(entry.RelayAddress))
    logger:Debug("   Generated AA:\n" .. script)
    return entry, script, nil
end
registerLuaFunctionHighlight('DestroyDetour')

function Trampolines:Reset()
    self.ActiveDetours = {}
    self.PendingDetours = {}
    self.PendingDestroys = {}
    self._txDepth = 0
    logger:Info(MODULE_PREFIX .. " Cleared active detours.")
end
registerLuaFunctionHighlight('Reset')

return Trampolines
