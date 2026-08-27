local NAME = "Manifold.Trampolines.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.2.0"
local DESCRIPTION = "Manifold Framework Trampolines"

--[[
    ∂ v1.2.0 (2026-08-27)
        The module that owns an address is read from the module list instead of
        being parsed out of getNameFromAddress. That function is a display
        formatter: it returns whichever label reads best, and both a
        user-defined symbol and an exported or PDB symbol outrank
        "module+offset". Any DLL that ships symbols - a RelWithDebInfo game
        build exports thousands - therefore named an inject site
        "SomeFunction+1F", the old parse took "SomeFunction" for the module
        name, and the PE reader was handed a function entry point. It then
        reported "module header does not start with MZ" about a module whose
        header was perfectly intact, and which of two neighbouring hooks
        tripped it came down to nothing but whether that particular address
        happened to sit near a symbol.
        Generated Auto Assembler no longer embeds getNameFromAddress output.
        Install, destroy, byte-restore and relocated control flow each wrote
        whatever label CE handed back straight into the script, so a decorated
        C++ export reached the AA parser verbatim; and because every install
        registers its own symbols, a later script could name an address after a
        symbol the first one owns, which stops pointing there the moment the
        first script is disabled. Those sites emit module+offset now, or bare
        hex for an address inside no module.
        A failed header read is no longer reported as a bad signature.
        _readLittleEndian returning nil took the same branch as a mismatch, so
        an unreadable page and a wrong magic produced one identical message.
        Both now say what was read and where.
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

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not, so
---   this module stays loadable on its own. Identical in every module - this
---   is the one duplication the design costs, and it is irreducible: something
---   has to reach the loader before the loader exists.
--
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

--
--- ∑ This module's identity and its dependency contract, in one place.
---     required = true -> New() refuses rather than pretending to be ready
---     runtime  = true -> documented only; never loaded here, never ordered on
--
local MODULE = BOOTSTRAP.Declare({
    class = "Trampolines", global = "trampolines",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger" },
    },
})


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
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- Ensures a dependency exists globally, and attempts to load it if missing.
--- @param dep table
--- @return boolean

--
--- Ensures all required global dependencies for this module are loaded.
--- @return nil
--
--- ∑ The single dependency lookup, shared by every Manifold module.
---   The name is kept so external callers and the docs keep working, and so a
---   module can still be checked without being constructed.
---   Behaviour is refuse-and-report: Bootstrap.Resolve never loads anything.
---   A missing `required` dependency raises out of New() with one legible
---   message instead of this module pretending to be ready.
--- @return boolean, table # resolved, list of missing dependency names
--
function Trampolines:CheckDependencies()
    return BOOTSTRAP.Resolve(MODULE)
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
        "fullAccess(" .. self:_formatCodeAddress(addr) .. "," .. tostring(#bytes) .. ")",
        self:_formatCodeAddress(addr) .. ":",
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

--
--- ∑ An address literal that is safe to paste into generated Auto Assembler.
---   _formatAddressLiteral is for humans, and may hand back a symbol name: a
---   decorated C++ export the AA parser chokes on, or a symbol another detour
---   registered, which stops pointing here the moment that detour is disabled.
---   Generated code gets module+offset instead, and bare hex for an address
---   that belongs to no module.
--- @param addr number
--- @return string
--
function Trampolines:_formatCodeAddress(addr)
    if type(addr) ~= "number" then return tostring(addr) end
    local owner = self:_findModuleContaining(addr)
    if owner then return string.format("%s+%X", owner.Name, addr - owner.Base) end
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

--
--- ∑ Every spelling of each candidate scratch register.
---   _textUsesRegister matches on a word frontier, so "r11" does NOT match
---   inside "r11d" - the character after it is a word character. Testing only
---   the 64-bit name therefore declared r11 free for an instruction reading
---   `mov r11d,[...]`, and the emitted `pop r11` then destroyed the value that
---   instruction had just loaded. Silently.
--
local TEMP_REGISTER_ALIASES = {
    { "r11", "r11d", "r11w", "r11b" },
    { "r10", "r10d", "r10w", "r10b" },
    { "r9",  "r9d",  "r9w",  "r9b"  },
    { "r8",  "r8d",  "r8w",  "r8b"  },
    { "rax", "eax",  "ax",   "al",  "ah" },
    { "rcx", "ecx",  "cx",   "cl",  "ch" },
    { "rdx", "edx",  "dx",   "dl",  "dh" },
    { "rbx", "ebx",  "bx",   "bl",  "bh" },
}

function Trampolines:_selectTempRegister(instruction)
    for _, family in ipairs(TEMP_REGISTER_ALIASES) do
        local used = false
        for _, spelling in ipairs(family) do
            if self:_textUsesRegister(instruction, spelling) then
                used = true
                break
            end
        end
        if not used then return family[1] end
    end
    -- Guess nothing. The caller falls back to copying the instruction verbatim.
    return nil
end

--
--- ∑ Mnemonics the push/pop temp wrapper must never be applied to.
---   The wrapper is `push temp / <instruction> / pop temp`, which assumes the
---   instruction falls through and leaves RSP alone. Three ways that breaks:
---     jmp/ret  - control leaves at the instruction, so `pop temp` never runs
---                and the stack is permanently 8 bytes deep. The next `ret`
---                takes the saved register as its return address.
---     call     - the extra push shifts RSP from %16==8 to %16==0 at the
---                callee, so any callee spilling XMM with movaps to a stack
---                local faults. `call qword ptr [rip+X]` is the most common
---                rip-relative control transfer in x64 code.
---     push/pop - the wrapper's `pop` consumes the instruction's own operand.
---   All of them are safe to copy verbatim instead: their memory operand is an
---   absolute address, so the instruction is already position independent.
--
local NON_REWRITABLE_MNEMONICS = {
    jmp = true, call = true, push = true, pop = true, ret = true, retn = true,
    retf = true, enter = true, leave = true, int = true, into = true,
    iret = true, iretd = true, iretq = true, loop = true, loope = true,
    loopne = true, loopz = true, loopnz = true, jecxz = true, jrcxz = true,
}

function Trampolines:_rewriteAbsoluteMemoryInstruction(instruction)
    if not self:_isTarget64Bit() then return nil end
    local mnemonic = tostring(instruction or ""):match("^%s*([%a][%w]*)")
    if mnemonic and NON_REWRITABLE_MNEMONICS[mnemonic:lower()] then return nil end
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

--
--- ∑ Appends an absolute jump to `target` and returns its exact byte length.
---
---   Written as raw bytes on purpose. The previous code emitted `jmp far X` and
---   then hand-encoded a 2-byte conditional that skipped a hard-coded 0x0E over
---   it - 14 bytes being the x64 `FF 25 <rel32> <8-byte pointer>` form. Nothing
---   verified that, and on a 32-bit target the pointer is 4 bytes, so the skip
---   overshot the jump and landed in the middle of the next relocated
---   instruction. Silently: the trampoline assembled and installed, and only
---   the not-taken path of the displaced branch executed garbage.
---
---   Emitting the encoding ourselves means the length is a fact rather than an
---   assumption, and neither form needs a label - CE's command-injected labels
---   are not reliably visible to branch operands, which is why the original
---   avoided them too.
--- @param lines table # script lines, appended to
--- @param target string # address literal or symbol
--- @return integer # bytes the emitted jump occupies
--
function Trampolines:_emitAbsoluteJump(lines, target)
    if self:_isTarget64Bit() then
        -- jmp qword ptr [rip+0]; the 8-byte destination follows inline.
        lines[#lines + 1] = self:_formatDbDirective({ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 })
        lines[#lines + 1] = "  dq " .. target
        return 14
    end
    -- push imm32 / ret. Self-contained, reaches the whole 32-bit space, needs
    -- no label and no scratch register, and leaves the flags untouched.
    lines[#lines + 1] = self:_formatDbDirective({ 0x68 })
    lines[#lines + 1] = "  dd " .. target
    lines[#lines + 1] = self:_formatDbDirective({ 0xC3 })
    return 6
end

--
--- ∑ Appends an absolute call to `target`, preserving every register.
---   The previous code emitted `mov r11,<target>` / `call r11`, which clobbers
---   r11 and does not even assemble on a 32-bit target, where r11 does not
---   exist. On x64 this uses a rip-relative indirect call over an inline
---   pointer instead, so no register is touched at all; the return address
---   lands on the 2-byte jump that steps over the pointer.
--- @param lines table
--- @param target string
--
function Trampolines:_emitAbsoluteCall(lines, target)
    if self:_isTarget64Bit() then
        lines[#lines + 1] = self:_formatDbDirective({ 0xFF, 0x15, 0x02, 0x00, 0x00, 0x00 })  -- call [rip+2]
        lines[#lines + 1] = self:_formatDbDirective({ 0xEB, 0x08 })                          -- jmp over the pointer
        lines[#lines + 1] = "  dq " .. target
        return
    end
    -- 32-bit: a direct call reaches the whole address space as E8 rel32, and
    -- nothing skips over it, so its encoded length does not matter here.
    lines[#lines + 1] = "  call " .. target
end

function Trampolines:_buildRelocatedInstruction(entry, index, lines)
    local bytes, offset, size = self:_getInstructionBytes(entry, index)
    local source = entry.InjectAddress + offset
    local relative = self:_analyzeRelativeControlFlow(source, bytes, size)
    if relative then
        local target = self:_formatCodeAddress(relative.Target)
        if relative.Kind == "jcc" then
            local inverse = self:_conditionMnemonic(relative.Inverse)
            if not inverse then
                logger:Warning(MODULE_PREFIX .. " Unknown conditional jump at " .. self:_formatAddressLiteral(source) .. "; falling back to original bytes.")
                lines[#lines + 1] = self:_formatDbDirective(bytes)
                return
            end
            -- Reserve the skip slot, emit the jump, then fill the skip in with
            -- the jump's ACTUAL length. Avoids generated labels, which CE does
            -- not reliably expose to branch operands, without hard-coding a
            -- length this code does not control.
            local skipIndex = #lines + 1
            lines[skipIndex] = ""
            local jumpSize = self:_emitAbsoluteJump(lines, target)
            lines[skipIndex] = self:_formatDbDirective({ 0x70 + relative.Inverse, jumpSize })
            logger:Debug(MODULE_PREFIX .. " Relocated conditional jump from " .. self:_formatAddressLiteral(source) .. " to " .. target)
            return false
        end
        if relative.Kind == "jmp" then
            self:_emitAbsoluteJump(lines, target)
            logger:Debug(MODULE_PREFIX .. " Relocated jump from " .. self:_formatAddressLiteral(source) .. " to " .. target)
            return true
        end
        if relative.Kind == "call" then
            self:_emitAbsoluteCall(lines, target)
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

--
--- ∑ The loaded module list, guarded so this module stays loadable outside CE.
--- @return table|nil, string|nil
--
function Trampolines:_enumModules()
    local fn = rawget(_G, "enumModules")
    if type(fn) ~= "function" then return nil, "enumModules not available" end
    local ok, modules = pcall(fn)
    if not ok then return nil, tostring(modules) end
    if type(modules) ~= "table" then return nil, "enumModules returned non-table" end
    return modules, nil
end

--
--- ∑ A module's mapped span. enumModules reports Size on current builds;
---   getModuleSize covers the ones that do not.
--- @param module table
--- @return number|nil
--
function Trampolines:_moduleSize(module)
    local size = tonumber(module and module.Size)
    if size and size > 0 then return size end
    local fn = rawget(_G, "getModuleSize")
    if type(fn) ~= "function" or type(module and module.Name) ~= "string" then return nil end
    local ok, result = pcall(fn, module.Name)
    if not ok then return nil end
    result = tonumber(result)
    if result and result > 0 then return result end
    return nil
end

--
--- ∑ The module whose mapped span contains `addr`.
---   The highest base at or below the address is the only candidate worth
---   sizing: where spans nest - a manually mapped image inside another
---   module's reserve - the innermost one starts last and is the real owner.
--- @param addr number
--- @return table|nil, string|nil # { Name, Base, Size }, error
--
function Trampolines:_findModuleContaining(addr)
    if type(addr) ~= "number" then return nil, "address must be numeric" end
    local modules, enumErr = self:_enumModules()
    if not modules then return nil, enumErr end
    local candidate, candidateBase = nil, nil
    for _, module in ipairs(modules) do
        local base = tonumber(module and module.Address)
        if base and base <= addr and (candidateBase == nil or base > candidateBase) then
            candidate, candidateBase = module, base
        end
    end
    if not candidate then
        return nil, string.format("no loaded module starts at or below %X", addr)
    end
    local size = self:_moduleSize(candidate)
    if not size then
        return nil, "could not determine the size of module '" .. tostring(candidate.Name) .. "'"
    end
    if addr >= candidateBase + size then
        return nil, string.format("%X lies past the end of '%s' and inside no loaded module", addr, tostring(candidate.Name))
    end
    return { Name = candidate.Name, Base = candidateBase, Size = size }, nil
end

--
--- ∑ Finds the module that owns `addr`.
---
---   This used to parse getNameFromAddress()'s output and take everything left
---   of the '+' as a module name. getNameFromAddress is a DISPLAY function: it
---   returns whichever label reads best, and a user-defined symbol or an
---   exported/PDB symbol both outrank "module+offset". A DLL that ships
---   symbols names its inject site "SomeFunction+1F", so the parse yielded
---   "SomeFunction", the PE reader was handed a function entry point, and the
---   MZ check failed on a module whose header was intact. Two hooks a few
---   instructions apart could disagree about it for no reason other than which
---   of them sat near a symbol.
---
---   The module list is the authority, so ask it. The name parse survives only
---   for an environment without enumModules, and even there the parsed name
---   must resolve to something that really is a module base.
--- @param addr number
--- @return table|nil, string|nil # { Name, Base, Size, AddressName }, error
--
function Trampolines:_resolveModuleForAddress(addr)
    local addressName = getNameFromAddress(addr)
    local owner, ownerErr = self:_findModuleContaining(addr)
    if owner then
        return { Name = owner.Name, Base = owner.Base, Size = owner.Size, AddressName = addressName }, nil
    end
    local moduleName = type(addressName) == "string" and addressName:match("^([^+]+)%+") or nil
    if not moduleName then
        return nil, "could not determine module from address " .. tostring(addressName) .. ": " .. tostring(ownerErr)
    end
    local moduleBase, err = self:_resolveAddress(moduleName)
    if not moduleBase then return nil, "could not resolve module base '" .. tostring(moduleName) .. "': " .. tostring(err) end
    if self:_readLittleEndian(moduleBase, 2) ~= 0x5A4D then
        return nil, string.format(
            "'%s', parsed from %s, resolves to %X, which is not a module base - that label is a symbol, not a module",
            tostring(moduleName), tostring(addressName), moduleBase)
    end
    return { Name = moduleName, Base = moduleBase, AddressName = addressName }, nil
end

function Trampolines:_getPeHeaderInfo(addr)
    local moduleInfo, moduleErr = self:_resolveModuleForAddress(addr)
    if not moduleInfo then return nil, moduleErr end
    local mz, mzErr = self:_readLittleEndian(moduleInfo.Base, 2)
    if not mz then
        return nil, string.format("failed to read the header of '%s' at %X: %s",
            tostring(moduleInfo.Name), moduleInfo.Base, tostring(mzErr))
    end
    if mz ~= 0x5A4D then
        return nil, string.format("header of '%s' at %X does not start with MZ (read %04X)",
            tostring(moduleInfo.Name), moduleInfo.Base, mz)
    end
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
    -- The lowest VirtualAddress of any section. Everything below it is header
    -- slack the loader zero-fills and nothing maps - the only region where a
    -- relay may safely live. Without this the search was bounded only by
    -- max(SizeOfHeaders, 0x1000), which reaches into .text whenever
    -- SectionAlignment is smaller than 0x1000 (packers, some system DLLs), and
    -- _isHeaderCaveFree accepts 0xCC - exactly MSVC's inter-function padding.
    local sectionTable = optionalHeader + optionalSize
    local firstSectionRva = nil
    for index = 0, sectionCount - 1 do
        local rva = self:_readLittleEndian(sectionTable + (index * 0x28) + 0x0C, 4)
        if rva and rva > 0 and (firstSectionRva == nil or rva < firstSectionRva) then
            firstSectionRva = rva
        end
    end
    return {
        ModuleName = moduleInfo.Name,
        ModuleBase = moduleInfo.Base,
        SectionHeadersEnd = sectionTable + (sectionCount * 0x28),
        SizeOfHeaders = sizeOfHeaders,
        FirstSectionRva = firstSectionRva
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
    -- max(), not min(), on purpose: SizeOfHeaders is commonly 0x400 while the
    -- usable slack runs to the first section at RVA 0x1000, and that slack is
    -- the whole point of a header relay. But it must then be CLAMPED to where
    -- the sections actually begin - that clamp is what was missing, and it is
    -- what kept the search out of live code only by luck.
    local searchLimitOffset = math.max(header.SizeOfHeaders, self.HEADER_RELAY_MAX_OFFSET)
    if header.FirstSectionRva and header.FirstSectionRva < searchLimitOffset then
        searchLimitOffset = header.FirstSectionRva
    end
    local searchEnd = header.ModuleBase + searchLimitOffset - slotSize
    if searchEnd < searchStart then
        return nil, "PE header relay range is empty from "
            .. getNameFromAddress(searchStart)
            .. " to "
            .. getNameFromAddress(searchEnd)
            .. " (SizeOfHeaders="
            .. string.format("0x%X", header.SizeOfHeaders)
            .. ", first section RVA="
            .. (header.FirstSectionRva and string.format("0x%X", header.FirstSectionRva) or "unknown")
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

--
--- ∑ Finds a detour whose inject range intersects [addr, stopAddr].
---   Relay slots were already protected against collision; the inject range was
---   not, and that is the more dangerous of the two.
--- @return table|nil # the colliding entry
--
function Trampolines:_injectRangeOverlapsStore(store, addr, stopAddr)
    for _, entry in pairs(store or {}) do
        local injectAddr = entry.InjectAddress
        local size = entry.OverwriteSize
        if injectAddr and size then
            local injectStop = injectAddr + size - 1
            if addr <= injectStop and stopAddr >= injectAddr then return entry end
        end
    end
    return nil
end

--
--- ∑ Refuses an install whose overwrite window collides with a live detour,
---   or whose "original" bytes are visibly somebody else's patch.
---
---   Without this, two scripts hooking the same instruction produce a
---   deterministic crash from nothing but enable/disable ordering: the second
---   install decodes the first one's E9 as if it were original code and records
---   it as OriginalBytes. Disabling the first restores the true bytes; disabling
---   the second then writes the stale E9 back, re-arming a jump into a relay
---   slot that has since been zeroed.
--- @return boolean, string|nil # ok, reason
--
function Trampolines:_checkInjectRangeFree(injectAddr, size, originalBytes)
    local stopAddr = injectAddr + size - 1
    local clash = self:_injectRangeOverlapsStore(self.ActiveDetours, injectAddr, stopAddr)
              or self:_injectRangeOverlapsStore(self.PendingDetours, injectAddr, stopAddr)
    if clash then
        return false, string.format(
            "inject range %s..%s overlaps detour '%s' at %s (%d bytes). Destroy it first.",
            self:_formatAddressLiteral(injectAddr), self:_formatAddressLiteral(stopAddr),
            tostring(clash.Name), self:_formatAddressLiteral(clash.InjectAddress),
            clash.OverwriteSize or 0)
    end
    -- Second line of defence: the range may be patched by something this module
    -- does not know about, or by a previous session whose bookkeeping is gone.
    local first = originalBytes and originalBytes[1]
    if first == 0xE9 or first == 0xEB then
        return false, string.format(
            "refusing to hook %s: it already begins with a %s jump, so the bytes here are somebody else's patch, not original code.",
            self:_formatAddressLiteral(injectAddr), first == 0xE9 and "rel32" or "rel8")
    end
    if first == 0xFF and originalBytes[2] == 0x25 then
        return false, string.format(
            "refusing to hook %s: it already begins with an indirect jump (FF 25), so the bytes here are somebody else's patch.",
            self:_formatAddressLiteral(injectAddr))
    end
    return true, nil
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
        "define(" .. block .. "," .. self:_formatCodeAddress(entry.RelayAddress) .. ")",
        "define(" .. relay .. "," .. self:_formatCodeAddress(entry.RelayAddress) .. ")",
        "define(" .. destination .. "," .. self:_formatCodeAddress(destinationAddress) .. ")",
        "define(" .. returnLabel .. "," .. self:_formatCodeAddress(entry.ReturnAddress) .. ")",
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

function Trampolines:_buildOriginalScript(entry, includeReturn)
    local original = entry.Name .. "_Original"
    local lines = { "label(" .. original .. ")", "", original .. ":" }
    local terminal = self:_buildOriginalRelocatedScript(entry, lines)
    if includeReturn ~= false and not terminal then
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
        self:_formatCodeAddress(entry.InjectAddress) .. ":",
        self:_formatDbDirective(entry.OriginalBytes),
        "",
        self:_formatCodeAddress(entry.RelayAddress) .. ":",
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
    logger:InfoBlock(MODULE_PREFIX .. " InstallDetour OK", {
        { "Name",         entry.Name },
        { "Inject",       getNameFromAddress(entry.InjectAddress) },
        { "Destination",  entry.DestinationExpression },
        -- `or false`, never a bare nil: a nil hole would end the ipairs walk early.
        entry.DestinationAddress and { "Dest Address", getNameFromAddress(entry.DestinationAddress) } or false,
        { "Relay",        getNameFromAddress(entry.RelayAddress) },
        { "Relay Offset", string.format("%s+%X", tostring(entry.RelayModuleName), entry.RelayOffset or 0) },
        { "Relay Size",   string.format("%d bytes", entry.RelaySize or 0) },
        { "Overwrite",    string.format("%d bytes", entry.OverwriteSize) },
        { "Return",       getNameFromAddress(entry.ReturnAddress) },
        { "Instructions", entry.InstructionCount },
        { "Offsets",      self:_fmtNumberArray(entry.InstructionOffsets) },
        { "Sizes",        self:_fmtNumberArray(entry.InstructionSizes) },
        { "Original",     self:_fmtBytes(entry.OriginalBytes) },
        { "Relay Backup", self:_fmtBytes(entry.RelayOriginalBytes) },
    })
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
    local rangeFree, rangeClashErr = self:_checkInjectRangeFree(injectAddr, range.OverwriteSize, originalBytes)
    if not rangeFree then return nil, nil, rangeClashErr end
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
    logger:DebugBlock(MODULE_PREFIX .. " InstallDetour script", { { "Generated AA", entry.InstallScript } })
    return entry, entry.InstallScript, nil
end
registerLuaFunctionHighlight('InstallDetour')

function Trampolines:EmitOriginal(name)
    local entry = self:_getDetour(name)
    if not entry then return nil, nil, "no active detour found for '" .. tostring(name) .. "'" end
    entry.OriginalEmitted = true
    local script = self:_buildOriginalScript(entry, true)
    logger:InfoBlock(MODULE_PREFIX .. " EmitOriginal OK", {
        { "Name",     entry.Name },
        { "Mode",     "relocated" },
        { "Original", self:_fmtBytes(entry.OriginalBytes) },
    })
    logger:DebugBlock(MODULE_PREFIX .. " EmitOriginal script", { { "Generated AA", script } })
    return entry, script, nil
end
registerLuaFunctionHighlight('EmitOriginal')

function Trampolines:EmitOriginalNoReturn(name)
    local entry = self:_getDetour(name)
    if not entry then return nil, nil, "no active detour found for '" .. tostring(name) .. "'" end
    entry.OriginalEmitted = true
    local script = self:_buildOriginalScript(entry, false)
    logger:InfoBlock(MODULE_PREFIX .. " EmitOriginalNoReturn OK", {
        { "Name",     entry.Name },
        { "Mode",     "relocated without automatic return" },
        { "Original", self:_fmtBytes(entry.OriginalBytes) },
    })
    logger:DebugBlock(MODULE_PREFIX .. " EmitOriginalNoReturn script", { { "Generated AA", script } })
    return entry, script, nil
end
registerLuaFunctionHighlight('EmitOriginalNoReturn')

function Trampolines:EmitReturn(name)
    local entry = self:_getDetour(name)
    if not entry then return nil, nil, "no active detour found for '" .. tostring(name) .. "'" end
    local script = self:_buildReturnScript(entry)
    logger:InfoBlock(MODULE_PREFIX .. " EmitReturn OK", { { "Name", entry.Name } })
    logger:DebugBlock(MODULE_PREFIX .. " EmitReturn script", { { "Generated AA", script } })
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
    logger:InfoBlock(MODULE_PREFIX .. " DestroyDetour OK", {
        { "Name",   entry.Name },
        { "Inject", getNameFromAddress(entry.InjectAddress) },
        { "Relay",  getNameFromAddress(entry.RelayAddress) },
    })
    logger:DebugBlock(MODULE_PREFIX .. " DestroyDetour script", { { "Generated AA", script } })
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
