--[[
    Instruction provider: the injection address, the instruction span the jump
    overwrites, original bytes/opcodes and base-register analysis.

    Everything here reads the target process, so every resolver is lazy and
    memoized: << OriginalBytes >> used three times in a template reads the
    bytes exactly once. No resolver ever guesses. When a value cannot be
    determined reliably it resolves to nil (and Requires turns that into an
    explanation) or raises a structured error.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Provider = { Name = "Instruction" }

--
--- General-purpose registers usable as a pointer base, by name. A whitelist
--- rather than a pattern. Hex digits are letters too, so an absolute operand
--- like [A1B2C3D4] on a 32-bit target matches every "looks like an
--- identifier" test and would silently generate 'mov [Ptr],A1B2C3D4', an
--- immediate store that assembles cleanly and captures a constant.
--- rip/eip are excluded on purpose: [rip+1234] parses like base+offset, but
--- 'mov [Ptr],rip' does not assemble and the address it names is already
--- absolute. Segment and vector registers are not pointer bases either.
--
local BASE_REGISTERS = {}
for _, name in ipairs({
    "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
    "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"
}) do
    BASE_REGISTERS[name] = true
end

function Provider.Register(registry, services)
    local ce = services.CE
    local log = services.Log
    local function isValidInstructionSize(size)
        return type(size) == "number" and size >= 1 and size <= 15 and size == math.floor(size)
    end
    local function instructionSize(address)
        local size = ce:GetInstructionSize(address)
        return isValidInstructionSize(size) and size or nil
    end
    --- Total size of whole instructions covering at least minimumSize bytes.
    --- No instruction is ever partially overwritten.
    local function instructionSpan(address, minimumSize)
        local current, total = address, 0
        for _ = 1, 64 do
            if total >= minimumSize then return total end
            local size = instructionSize(current)
            if not size then
                error(string.format("Unable to determine instruction size at %X", current), 0)
            end
            total = total + size
            current = current + size
        end
        error("Too many instructions while calculating the jump span", 0)
    end
    local function disassembledOpcode(address)
        local line = ce:Disassemble(address)
        if not line then return nil end
        local _, opcode = ce:SplitDisassembledString(line)
        local text = type(opcode) == "string" and opcode or line
        return text:gsub("%{.-%}", "")
    end
    --
    --- Base register and displacement of a memory operand. Deliberately
    --- conservative: anything beyond [reg] or [reg+/-off], a scaled index
    --- like [rax+rcx*4+30], returns nil rather than a partial answer that
    --- would capture the wrong pointer.
    --
    local function registerData(instruction)
        if type(instruction) ~= "string" then return nil, nil end
        local operand = instruction:match("%[([^%]]*)%]")
        if not operand then return nil, nil end
        local register, sign, offset = operand:match("^%s*([%a][%w]*)%s*([+-])%s*(%x+)%s*$")
        if register then
            if not BASE_REGISTERS[register:lower()] then return nil, nil end
            return register, (sign == "-" and "-" or "") .. offset
        end
        register = operand:match("^%s*([%a][%w]*)%s*$")
        if register then
            if not BASE_REGISTERS[register:lower()] then return nil, nil end
            return register, "0"
        end
        return nil, nil
    end
    local baseRegisterHint = function(ctx)
        local instruction = (ctx:Resolve("OriginalInstruction")) or "?"
        return "This template requires a simple memory operand such as:\n\n"
            .. "[rax]\n[rax+30]\n[rbx-10]\n\n"
            .. "The selected instruction uses:\n\n"
            .. tostring(instruction) .. "\n\n"
            .. "Select a compatible instruction or use a template that does not require BaseAddressRegister."
    end
    return registry:RegisterProvider{
        Name = Provider.Name,
        Variables = {
            _InjectionTarget = {
                Type = "table",
                Hidden = true,
                Description = "Resolved injection address (text + numeric value)",
                Resolve = function(ctx)
                    -- Fail before any prompt: with no process attached the
                    -- 2.x loader said so first, and so does 3.x.
                    if not ce:GetProcessName() then
                        error("No target process is attached", 0)
                    end
                    local selected = ce:GetSelectedDisassemblerAddress()
                    local selectedText = selected
                        and (ce:GetNameFromAddress(selected, true, true, true) or string.format("%X", selected))
                        or nil
                    local requested = selectedText
                    if ctx.Options.AskForInjectionAddress then
                        requested = ce:InputQuery("Injection Address", "Address to use for the injection:", selectedText or "")
                        if requested == nil then
                            error(Errors.New{
                                Code = Errors.Codes.INPUT_CANCELLED, Stage = Errors.Stages.Context,
                                Message = "Injection address prompt was cancelled"
                            }, 0)
                        end
                    end
                    if not requested or requested == "" then
                        error("No injection address was provided", 0)
                    end
                    local address = ce:GetAddressSafe(requested)
                    if not address then
                        error("Unable to resolve injection address '" .. tostring(requested) .. "'", 0)
                    end
                    local text = ce:GetNameFromAddress(address, true, true, true) or tostring(requested)
                    log:Debug(string.format("[Instruction] Injection address: %s ($%X)", text, address))
                    return { Text = text, Value = address }
                end
            },
            Address = {
                Type = "string",
                Description = "Injection address as a display name, e.g. Game.exe+1255B5B",
                DependsOn = { "_InjectionTarget" },
                Resolve = function(ctx) return ctx:Get("_InjectionTarget").Text end
            },
            AddressValue = {
                Type = "number",
                Description = "Numeric injection address",
                DependsOn = { "_InjectionTarget" },
                Resolve = function(ctx) return ctx:Get("_InjectionTarget").Value end
            },
            Is14ByteJump = {
                Type = "boolean",
                Description = "State of the 14-byte-JMP toggle of the generating Auto Assembler window",
                Resolve = function(ctx)
                    -- The generating form is authoritative. Scanning all forms is
                    -- only the fallback for a generation without a known form.
                    local form = ctx.Form
                    if form then
                        local ok, checked = pcall(function()
                            return form.mi14ByteJMP and form.mi14ByteJMP.Checked
                        end)
                        if ok and type(checked) == "boolean" then return checked end
                    end
                    for index = 0, ce:GetFormCount() - 1 do
                        local candidate = ce:GetForm(index)
                        if ce:IsAutoInjectForm(candidate) then
                            local ok, checked = pcall(function()
                                return candidate.mi14ByteJMP and candidate.mi14ByteJMP.Checked
                            end)
                            if ok and type(checked) == "boolean" then return checked end
                        end
                    end
                    return false
                end
            },
            MinJumpSize = {
                Type = "number",
                Description = "5, or 14 when the 14-byte jump is enabled",
                DependsOn = { "Is14ByteJump" },
                Resolve = function(ctx) return ctx:Get("Is14ByteJump") and 14 or 5 end
            },
            JumpType = {
                Type = "string",
                Description = "'jmp' or 'jmp far'",
                DependsOn = { "Is14ByteJump" },
                Resolve = function(ctx) return ctx:Get("Is14ByteJump") and "jmp far" or "jmp" end
            },
            JumpSize = {
                Type = "number",
                Description = "Bytes actually overwritten (whole instructions, >= MinJumpSize)",
                DependsOn = { "AddressValue", "MinJumpSize" },
                Resolve = function(ctx)
                    local size = instructionSpan(ctx:Get("AddressValue"), ctx:Get("MinJumpSize"))
                    log:Debug(string.format("[Instruction] Overwrite span: %d byte(s) (minimum %d).",
                        size, ctx:Get("MinJumpSize")))
                    return size
                end
            },
            SelectionSize = {
                Type = "number",
                Description = "Size of the first selected instruction",
                DependsOn = { "AddressValue" },
                Resolve = function(ctx) return instructionSize(ctx:Get("AddressValue")) or 0 end
            },
            OriginalInstruction = {
                Type = "string",
                Description = "Disassembly of the first overwritten instruction",
                DependsOn = { "AddressValue" },
                Resolve = function(ctx) return disassembledOpcode(ctx:Get("AddressValue")) end
            },
            OriginalOpcodes = {
                Type = "string",
                Description = "All overwritten instructions, one per line, two-space indented",
                DependsOn = { "AddressValue", "JumpSize" },
                Resolve = function(ctx)
                    local current, total = ctx:Get("AddressValue"), 0
                    local required, result = ctx:Get("JumpSize"), {}
                    while total < required do
                        local size = instructionSize(current)
                        local opcode = disassembledOpcode(current)
                        if not size or not opcode or opcode == "" then
                            error(string.format("Unable to disassemble instruction at %X", current), 0)
                        end
                        result[#result + 1] = "  " .. opcode
                        total = total + size
                        current = current + size
                    end
                    return table.concat(result, "\n")
                end
            },
            OriginalBytes = {
                Type = "string",
                Description = "Overwritten bytes as hex pairs, e.g. '48 8B 41 34'",
                DependsOn = { "AddressValue", "JumpSize" },
                Resolve = function(ctx)
                    local current, total = ctx:Get("AddressValue"), 0
                    local required, bytes = ctx:Get("JumpSize"), {}
                    while total < required do
                        local size = instructionSize(current)
                        if not size then
                            error(string.format("Unable to read instruction at %X", current), 0)
                        end
                        local values = ce:ReadBytesTable(current, size)
                        if not values then
                            error(string.format("Unable to read bytes at %X", current), 0)
                        end
                        for _, value in ipairs(values) do bytes[#bytes + 1] = string.format("%02X", value) end
                        total = total + size
                        current = current + size
                    end
                    return table.concat(bytes, " ")
                end
            },
            NopPadding = {
                Type = "string",
                Description = "'db 90 ...' line for the overwritten remainder, or ''",
                DependsOn = { "JumpSize", "MinJumpSize" },
                Resolve = function(ctx)
                    local padding = ctx:Get("JumpSize") - ctx:Get("MinJumpSize")
                    return padding > 0 and ("db " .. ("90 "):rep(padding):sub(1, -2) .. "\n") or ""
                end
            },
            NopBytes = {
                Type = "string",
                Description = "'90 90 ...' covering the whole overwritten span",
                DependsOn = { "JumpSize" },
                Resolve = function(ctx)
                    return ("90 "):rep(ctx:Get("JumpSize")):sub(1, -2)
                end
            },
            BaseAddressRegister = {
                Type = "string",
                Description = "Base register of the first instruction's memory operand, or nil",
                DependsOn = { "OriginalInstruction" },
                Hint = baseRegisterHint,
                Resolve = function(ctx)
                    local register = registerData(ctx:Get("OriginalInstruction"))
                    if not register then
                        log:Warning("[Instruction] No usable base register in '"
                            .. tostring(ctx:Get("OriginalInstruction"))
                            .. "'. Templates requiring << BaseAddressRegister >> cannot generate from this instruction.")
                    end
                    return register
                end
            },
            BaseAddressOffset = {
                Type = "string",
                Description = "Displacement of that operand ('0' for [reg]), or nil",
                DependsOn = { "OriginalInstruction" },
                Hint = baseRegisterHint,
                Resolve = function(ctx)
                    local _, offset = registerData(ctx:Get("OriginalInstruction"))
                    return offset
                end
            }
        }
    }
end

return Provider