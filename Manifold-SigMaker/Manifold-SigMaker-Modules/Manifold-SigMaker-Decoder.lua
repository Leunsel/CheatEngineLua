--[[
    Which bytes of an instruction are operands.

    The tool this was modelled on, GH SigMaker v2.0, carries a length
    disassembler of its own, driven by opcode tables, and derives the mask
    from it with

        keep = immSize ~= 0 and (len - immSize) or (1 + hasModRM)

    where keep counts from byte zero, so prefixes eat the budget. Three
    consequences follow from that, and all three are worth avoiding. The first
    is that 48 8B 05 disp32 and 8B 05 disp32 mask differently, because one of
    them carries a REX prefix and that prefix spends a byte of the budget. The
    second is that F3 0F 1E FA masks its own opcode, for the same reason. The
    third is that C7 45 F8 imm32 keeps the displacement and masks the
    immediate, which is backwards for a signature. That decoder also predates
    VEX and mishandles the 0F 38 opcode map.

    This module asks Cheat Engine's disassembler instead, and finds the
    operand bytes by PROBING. It takes the instruction one byte at a time. It
    flips that byte, disassembles the result, and compares the result against
    the original on two things. The first is the length. The second is the
    shape, meaning the mnemonic, the registers and the operand layout. If both
    of those survived the flip and only a number came out different, then that
    byte is part of a numeric operand and may be masked. If the length changed,
    or the shape changed, the byte is structural and is kept literal. That is
    the whole decision, and every other rule here exists to keep those two
    comparisons honest.

    Shape is compared on a skeleton, which is the instruction text with the
    numbers taken out of it. Three things have to collapse into that skeleton
    or the comparison lies.

      * Hexadecimal literals. They are what the probe is trying to move, so
        they all become the same placeholder. No x86 register name is made
        only of hex digits, so the substitution never eats one. The name eax
        survives because of the x, rsp because of the s and the p, dh because
        of the h.
      * The SIGN in front of a literal. Cheat Engine prints a displacement
        signed, so it writes lea rax,[rbp-20] and never [rbp+E0]. A probe that
        pushes a small displacement across zero therefore changes a character
        and not only digits, which is why the sign is eaten along with the
        number. It is also why the probe flips bit 0 rather than complementing
        the byte. Bit 7 of a one byte displacement, or of an immediate that is
        sign extended, IS the sign, and complementing always crossed zero.
        With the complement, and with the sign left in the skeleton, not a
        single one byte displacement was ever recognised as an operand at all.
      * SYMBOLS. A resolved target prints as a module name and an offset, as
        in mov rax,[game.exe+2F000] or call game.exe+215F0. Move that target
        far enough and it leaves the module and reverts to a bare address,
        which is a different shape for the same kind of operand. The top byte
        of every rip relative displacement and every rel32 runs into this,
        because one bit up there moves the target by megabytes.

    A masked byte is then classified so the settings can be selective. A byte
    inside brackets is a displacement. A byte that is the operand of a branch
    is a branch target. Anything else is an immediate.

    This costs one disassembly per byte, which for a signature of a few
    instructions is a few dozen calls. It needs no opcode tables of its own,
    it inherits every extension Cheat Engine's disassembler knows, and it
    cannot disagree with the disassembler the user is looking at.
]]

local Decoder = {}
Decoder.__index = Decoder

function Decoder:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Settings = deps.Settings
    }, Decoder)
end

--- Mnemonics that end a function. Bytes after one of these belong to whatever
--- the linker put next, and that moves independently of the code being signed.
--- A signature reaching past one is fragile in a way its length hides.
Decoder.Terminators = {
    ret = true, retn = true, retf = true, iret = true, iretd = true, iretq = true,
    jmp = true, int3 = true, ud2 = true, hlt = true
}

--- Mnemonics whose numeric operand is a code target rather than a value.
Decoder.Branches = {
    call = true, jmp = true, loop = true, loope = true, loopne = true,
    ja = true, jae = true, jb = true, jbe = true, jc = true, je = true,
    jg = true, jge = true, jl = true, jle = true, jna = true, jnae = true,
    jnb = true, jnbe = true, jnc = true, jne = true, jng = true, jnge = true,
    jnl = true, jnle = true, jno = true, jnp = true, jns = true, jnz = true,
    jo = true, jp = true, jpe = true, jpo = true, js = true, jz = true,
    jcxz = true, jecxz = true, jrcxz = true
}

--
--- ∑ The instruction text with every hexadecimal literal replaced by "#".
---   Two encodings with the same skeleton differ only in their numbers.
--- @param text string
--- @return string
--
function Decoder.Skeleton(text)
    local skeleton = tostring(text or ""):lower()
    -- A symbolised target goes first, because it swallows the "+offset" as
    -- well and would otherwise be half eaten by the literal rule below. Only
    -- a name carrying a dot qualifies, so no register or mnemonic can match.
    skeleton = skeleton:gsub("[%w_@%$]+%.[%w_@%$]+%+?%x*", "#")
    -- Then a literal, with its sign.
    skeleton = skeleton:gsub("[%+%-]?%f[%w]%x+%f[%W]", "#")
    return skeleton
end

--- The mnemonic of an opcode string.
function Decoder.Mnemonic(opcode)
    return (tostring(opcode or ""):lower():match("^%s*([%a][%w]*)")) or ""
end

--
--- ∑ Whether the number that changed sits inside brackets, which is to say
---   whether it is part of a memory operand. The two texts are walked
---   together until they differ, and the answer is the bracket depth
---   reached at that point.
--- @param before string
--- @param after string
--- @return boolean
--
function Decoder.ChangedInsideBrackets(before, after)
    local depth, index = 0, 1
    local b, a = tostring(before or ""), tostring(after or "")
    local limit = math.min(#b, #a)
    -- Walk both until they diverge, tracking bracket depth in the original.
    while index <= limit and b:sub(index, index) == a:sub(index, index) do
        local c = b:sub(index, index)
        if c == "[" then depth = depth + 1 elseif c == "]" then depth = depth - 1 end
        index = index + 1
    end
    if index > limit then return false end
    return depth > 0
end

--
--- ∑ The numeric value of the literal that differs between two texts, so that
---   a large immediate can be told apart from a small one.
--- @param before string
--- @param after string
--- @return number|nil # The magnitude, read as a signed value first.
--
function Decoder.ChangedValue(before, after)
    local index, limit = 1, math.min(#before, #after)
    while index <= limit and before:sub(index, index) == after:sub(index, index) do
        index = index + 1
    end
    -- Walk back to the start of the literal, then read it out of before.
    local start = index
    while start > 1 and before:sub(start - 1, start - 1):match("%x") do start = start - 1 end
    local literal = before:match("^(%x+)", start)
    if not literal then return nil end
    local value = tonumber(literal, 16)
    if not value then return nil end
    -- Read it the way the instruction means it. Cheat Engine prints an
    -- immediate unsigned and at its encoded width, so FFFFFFFF is minus one
    -- and not four billion. Without this step every or eax,FFFFFF00 looked
    -- like an address and got wildcarded by the "large" policy.
    local width = #literal
    if width == 2 or width == 4 or width == 8 or width == 16 then
        local top = 1 << (width * 4 - 1)
        if value >= top then value = value - (top << 1) end
    end
    if value < 0 then value = -value end
    return value
end

--
--- ∑ Classifies every byte of one instruction.
--- @param address number # Where the instruction really lives, so that rip
---        relative operands resolve the way the user sees them.
--- @param bytes table # The instruction's bytes, indexed from 1, exactly as
---        many of them as the instruction is long.
--- @return table, string|nil # One entry per byte, shaped
---         { Byte, Masked, Kind }, where Kind is one of "structure",
---         "displacement", "branch" and "immediate". The table is never nil.
---         An instruction Cheat Engine will not disassemble degrades to every
---         byte kept literal, and the reason comes back as a second result. A
---         signature that is longer than it had to be still works. Refusing
---         to make one at all does not.
--
function Decoder:Classify(address, bytes)
    local ce = self.CE
    -- The base reading comes from the live address. That is the line the user
    -- is looking at in the disassembler, so it is the one to compare against,
    -- and it cannot fail for an address Cheat Engine has just rendered. Only
    -- the probes need the byte form, and a probe that fails to decode is
    -- simply a byte that is not an operand.
    --- Every byte kept, which is always a correct if unhelpful answer.
    local function literal()
        local kept = {}
        for index = 1, #bytes do
            kept[index] = { Byte = bytes[index], Kind = "structure", Masked = false }
        end
        return kept
    end

    local base = ce:Disassemble(address) or ce:DisassembleBytes(bytes, address)
    if not base then
        return literal(), string.format(
            "%X could not be disassembled, so its %d byte(s) are kept literal",
            address, #bytes)
    end
    local baseText = base.Opcode
    local baseSkeleton = Decoder.Skeleton(baseText)
    local mnemonic = Decoder.Mnemonic(baseText)
    local isBranch = Decoder.Branches[mnemonic] == true
    local length = #bytes

    local result = {}
    for index = 1, length do
        local kind = "structure"
        local probe = {}
        for i = 1, length do probe[i] = bytes[i] end
        -- Only the lowest bit is flipped. That always changes the byte, and it
        -- never touches bit 7, which is where the sign of a one byte
        -- displacement or a sign extended immediate lives. It also moves a rip
        -- relative or rel32 target the shortest distance it can, so the target
        -- usually stays inside its module and keeps its symbol. Complementing
        -- the byte broke all three of those.
        probe[index] = bytes[index] ~ 0x01

        local other = ce:DisassembleBytes(probe, address)
        if other and other.Size == base.Size
            and Decoder.Skeleton(other.Opcode) == baseSkeleton then
            -- The shape held and only a number moved, so this byte carries an
            -- operand. Brackets are tested before the mnemonic. An indirect
            -- branch such as call qword ptr [rip+X] or jmp [rax+18] carries a
            -- memory displacement and not a code target, and the two are
            -- governed by different settings. Testing isBranch first put every
            -- import thunk and vtable dispatch in the wrong bucket.
            if Decoder.ChangedInsideBrackets(baseText, other.Opcode) then
                kind = "displacement"
            elseif isBranch then
                kind = "branch"
            else
                kind = "immediate"
            end
        end
        result[index] = { Byte = bytes[index], Kind = kind, Masked = false,
                          Value = (kind == "immediate")
                              and Decoder.ChangedValue(baseText, other and other.Opcode or "") or nil }
    end

    self:ApplyPolicy(result)
    return result, nil, base
end

--
--- ∑ Whether an instruction ends a function. An indirect jump through a
---   register or memory is a tail call or a table dispatch and ends one too.
--- @param opcodeText string
--- @return boolean
--
function Decoder.IsTerminator(opcodeText)
    return Decoder.Terminators[Decoder.Mnemonic(opcodeText)] == true
end

--
--- ∑ Turns the classification into a mask, following the settings.
--- @param classified table
--
function Decoder:ApplyPolicy(classified)
    local mask = self.Settings.Mask
    for _, entry in ipairs(classified) do
        if entry.Kind == "displacement" then
            entry.Masked = mask.Displacement == true
        elseif entry.Kind == "branch" then
            entry.Masked = mask.BranchTarget == true
        elseif entry.Kind == "immediate" then
            if mask.Immediate == true then
                entry.Masked = true
            elseif mask.Immediate == "large" then
                entry.Masked = (entry.Value ~= nil)
                    and (entry.Value >= (mask.ImmediateThreshold or 0x10000))
            else
                entry.Masked = false
            end
        end
    end
end

return Decoder
