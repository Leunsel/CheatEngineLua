--[[
    Manifold.TemplateLoader.Memory.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 2.0.0
    LICENSE : MIT
    CREATED : 2025-06-21
    UPDATED : 2025-06-22

    MIT License:
        Copyright (c) 2025 Leunsel

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    This file is part of the Manifold TemplateLoader system.
]]

Memory = {}
Memory.__index = Memory

local instance = nil

function Memory:New()
    if not instance then
        instance = setmetatable({}, Memory)
    end
    instance.InjInfoLineCount = 3
    instance.InjInfoRemoveSpaces = true
    instance.InjInfoAddTabs = true
    instance.AppendToHookName = "Hook"
    instance.AskForHookName = true
    return instance
end

-- ...........................................
-- Configuration Data
-- ...........................................

function Memory:SetInjInfoLineCount(count)
    if type(count) == "number" and count > 0 then
        self.InjInfoLineCount = count
    else
        -- ...
        return
    end
end

function Memory:SetInjInfoRemoveSpaces(remove)
    if type(remove) == "boolean" then
        self.InjInfoRemoveSpaces = remove
    else
        -- ...
        return
    end
end

function Memory:SetInjInfoAddTabs(addTabs)
    if type(addTabs) == "boolean" then
        self.InjInfoAddTabs = addTabs
    else
        -- ...
        return
    end
end

function Memory:SetAppendToHookName(appendToHookName)
    if type(appendToHookName) == "string" then
        self.AppendToHookName = appendToHookName
    else
        -- ...
        return
    end
end

function Memory:GetConfig()
    return self.InjInfoLineCount,
           self.InjInfoRemoveSpaces,
           self.InjInfoAddTabs,
           self.AppendToHookName
end

-- ...........................................
-- For "Template Metadata"...
-- ...........................................

function Memory:GetCurrentDate()
    local dateFormat = "%Y-%m-%d"
    return os.date(dateFormat)
end

function Memory:GetCurrentDateTime()
    local dateTimeFormat = "%Y-%m-%d %H:%M:%S"
    return os.date(dateTimeFormat)
end

function Memory:GetCurrentTime()
    local timeFormat = "%H:%M:%S"
    return os.date(timeFormat)
end

-- ...........................................
-- Neccessities
-- ...........................................

function Memory:GetDefaultPointerSize()
    if self:IsTarget64Bit() then
        return "dq", 8
    else
        return "dd", 4
    end
end

function Memory:IsTarget64Bit()
    return targetIs64Bit()
end

function Memory:Is14ByteJump()
    for i = 0, getFormCount() - 1 do
        local f = getForm(i)
        if f.ClassName == "TfrmAutoInject" then
            local isChecked = f.mi14ByteJMP.Checked
            return isChecked
        end
    end
    return false
end

-- ...........................................
-- Hook Data
-- ...........................................

function Memory:PromptForHookName()
    local name = inputQuery("Hook Name", "Enter the hook name", "ExampleName")
    if not name or name == "" then
        return
    end
    return name
end

function Memory:FormatHookName(hookName)
    if not hookName:match(self.AppendToHookName .. "$") then
        hookNameParsed = hookName .. self.AppendToHookName
    else
        hookNameParsed = hookName
    end
    return hookNameParsed
end

function Memory:GetHookNames()
    local hookName = self:PromptForHookName()
    if not hookName or hookName == "" then
        return nil, nil
    end
    local hookNameParsed = self:FormatHookName(hookName)
    return hookName, hookNameParsed
end

function Memory:GetAllocStatement(hookName, hookNameParsed)
    if self:Is14ByteJump() then
        return string.format("alloc(n_%s,$1000)", hookName)
    else
        return string.format("alloc(n_%s,$1000,%s)", hookName, hookNameParsed)
    end
end

-- ...........................................
-- Selection Data
-- ...........................................

function Memory:IsValidInstructionSize(size, addr)
    if not size or size <= 0 then
        return false
    end
    return true
end

function Memory:GetInstructionSize(addr)
    local size = getInstructionSize(addr)
    if not self:IsValidInstructionSize(size, addr) then
        return nil
    end
    return size
end

function Memory:GetSelection()
    return getNameFromAddress(getMemoryViewForm().DisassemblerView.SelectedAddress, true, true, true)
end

function Memory:GetSelectionSize(addr)
    return self:GetInstructionSize(addr) or 0
end

-- ...........................................
-- Original Data
-- ...........................................

function Memory:GetOpcodes(startAddr, requiredSize)
    local opcodes = {}
    local address = getAddressSafe(startAddr)
    local totalSize = 0
    local disassembler = getVisibleDisassembler()
    while totalSize < requiredSize do
        local instructionSize = self:GetInstructionSize(address)
        if not instructionSize or instructionSize <= 0 then break end
        local _, opcode = splitDisassembledString(disassembler.disassemble(address))
        opcode = opcode:gsub("%{.-%}", "")
        opcodes[#opcodes + 1] = "  " .. opcode
        totalSize = totalSize + instructionSize
        address = address + instructionSize
    end
    return table.concat(opcodes, "\n")
end

function Memory:GetBytes(startAddr, size)
    local bytes = {}
    local address = getAddressSafe(startAddr)
    local bytesRead = 0
    while bytesRead < size do
        local instructionSize = self:GetInstructionSize(address)
        if not instructionSize or instructionSize <= 0 then break end
        local byteTable = readBytes(address, instructionSize, true)
        if type(byteTable) == "table" then
            for _, b in ipairs(byteTable) do
                table.insert(bytes, string.format("%02X", b))
            end
        else
            table.insert(bytes, string.format("%02X", byteTable))
        end
        bytesRead = bytesRead + instructionSize
        address = address + instructionSize
    end
    return table.concat(bytes, " ")
end

function Memory:GetNopPadding(size, minSize)
    local pad = size - minSize
    if pad > 0 then
        return ("db " .. ("90 "):rep(pad):sub(1, -2)) .. "\n"
    end
    return ""
end

-- ...........................................
-- Jump Data
-- ...........................................

function Memory:GetMinJumpSize()
    return self:Is14ByteJump() and 14 or 5
end

function Memory:GetJumpType()
    return self:Is14ByteJump() and "jmp far" or "jmp"
end

function Memory:GetJumpSize(addr, minSize)
    local address = getAddressSafe(addr)
    local totalSize = 0
    while totalSize < minSize do
        local instructionSize = self:GetInstructionSize(address)
        if not instructionSize or instructionSize <= 0 then
            break
        end
        totalSize = totalSize + instructionSize
        address = address + instructionSize
    end
    return totalSize
end

-- ...........................................
-- Module and Process Data
-- ...........................................

function Memory:GetProcessName()
    return process
end

function Memory:GetProcessBase()
    local processName = self:GetProcessName()
    if processName and processName ~= "" then
        return getAddressSafe(processName)
    end
end

function Memory:GetProcessBaseStr()
    local base = self:GetProcessBase()
    return base and string.format("%016X", base) or "No process base found."
end

function Memory:GetModuleName(addr)
    local address = addr or self:GetSelection()
    if inModule(address) then
        local moduleName = getNameFromAddress(address, true, false)
        return moduleName:match("^(.*)[+-]%x*$") or moduleName
    end
end

function Memory:GetModuleBase(addr)
    local moduleName = self:GetModuleName(addr)
    return moduleName and getAddressSafe(moduleName) or nil
end

function Memory:GetModuleBaseStr()
    local base = self:GetModuleBase()
    return base and string.format("%016X", base) or "No module base found."
end

-- ...........................................
-- Processed Data
-- ...........................................

function Memory:GetAoB()
    local base = getAddressSafe(self:GetSelection())
    if not base then
        return "Failed to resolve address: " .. tostring(base)
    end
    local currentModule = self:GetModuleName(base)
    if not currentModule then
        return "Failed to retrieve the module name."
    end
    local aobString, offset = getUniqueAOB(base)
    if not aobString then
        return "'No Unique AoB Found'", ""
    end
    if offset and offset ~= 0 then
        return aobString, ("+%X"):format(offset)
    else
        return aobString, ""
    end
end

function Memory:GetRegisterData(instr)
    local register, offset = instr:match("%[([%w]+)[-+]?([%x]*)%]")
    if register then
        if offset == "" then offset = "0" end
        return register, offset
    end
    register = instr:match("%[([%w]+)%]")
    if register then
        return register, "0"
    end
    return nil, nil
end

function Memory:GetJumpData(addr, jmpSize)
    local jumpData = {}
    jumpData.opcodes = self:GetOpcodes(addr, jmpSize)
    jumpData.bytes = self:GetBytes(addr, jmpSize)
    jumpData.nopPadding = self:GetNopPadding(jmpSize, self:GetMinJumpSize())
    jumpData.jumpType = self:GetJumpType()
    return jumpData
end

function Memory:GetInjectionInfo(addr, injectionInfoLinesCount, removeSpaces)
    injectionInfoLinesCount = injectionInfoLinesCount or self.InjInfoLineCount
    removeSpaces = removeSpaces or self.InjInfoRemoveSpaces
    local disassembler = getVisibleDisassembler()
    local function getLine(lineAddr)
        if not lineAddr then return "" end
        local disassembledStr = disassembler.disassemble(lineAddr):gsub('{.-}', '')
        local _, opcode, bytes, addrStr = splitDisassembledString(disassembledStr)
        if not addrStr or addrStr == "" then
            return ""
        end
        local name = getNameFromAddress(addrStr)
        bytes = bytes:gsub("%s+", ""):gsub("..", "%1 "):sub(1, -2)
        if removeSpaces then
            return string.format("%s - %s - %s", name, bytes, opcode)
        else
            return string.format("%s - %-24s - %s", name, bytes, opcode)
        end
    end
    local code = {}
    local currAddr = addr
    for i = math.floor(injectionInfoLinesCount / 2), 1, -1 do
        currAddr = getPreviousOpcode(currAddr)
    end
    for i = 1, injectionInfoLinesCount do
        table.insert(code, getLine(currAddr))
        currAddr = currAddr + (getInstructionSize(currAddr) or 1)
    end
    return code
end

function Memory:GetInjectionInfoStr(addr)
    local injectionInfoLinesCount = self.InjInfoLineCount
    local removeSpaces = self.InjInfoRemoveSpaces
    local addTabs = self.InjInfoAddTabs
    local code = self:GetInjectionInfo(addr, injectionInfoLinesCount, removeSpaces)
    if addTabs then
        for i, line in ipairs(code) do
            code[i] = "\t  " .. line
        end
    end
    return table.concat(code, "\n")
end

-- ...........................................
-- Finalize
-- ...........................................

function Memory:GetMemoryInfo()
    local info = {
        Version = "1.0.0",
        Date = self:GetCurrentDate(),
        Time = self:GetCurrentTime(),
        DateTime = self:GetCurrentDateTime(),
        InjInfoLineCount = self.InjInfoLineCount,
        InjInfoRemoveSpaces = self.InjInfoRemoveSpaces,
        InjInfoAddTabs = self.InjInfoAddTabs,
        AppendToHookName = self.AppendToHookName,
        AskForHookName = self.AskForHookName,
        Process = self:GetProcessName(),
        ProcessBase = self:GetProcessBaseStr(),
        Module = self:GetModuleName(),
        ModuleBase = self:GetModuleBaseStr(),
        Address = self:GetSelection()
    }
    if not info.Process then return nil end
    info.PointerType, info.DefaultPointerBytes = self:GetDefaultPointerSize()
    info.IsTarget64Bit = self:IsTarget64Bit()
    info.Is14ByteJump = self:Is14ByteJump()
    info.MinJumpSize = self:GetMinJumpSize()
    info.JumpType = self:GetJumpType()
    info.SelectionSize = self:GetSelectionSize(info.Address)
    local aob, aobOffset = self:GetAoB()
    info.AoBStr, info.AoBOffset = aob, aobOffset
    local hookName, hookNameParsed = self:GetHookNames()
    if not hookName then return nil end
    info.HookName, info.HookNameParsed = hookName, hookNameParsed
    info.Alloc = self:GetAllocStatement(hookName, hookNameParsed)
    if info.Address then
        local minJumpSize = info.MinJumpSize
        local jumpSize = self:GetJumpSize(info.Address, minJumpSize)
        info.JumpSize = jumpSize
        info.OriginalOpcodes = self:GetOpcodes(info.Address, minJumpSize)
        info.OriginalBytes = self:GetBytes(info.Address, minJumpSize)
        info.NopPadding = self:GetNopPadding(jumpSize, minJumpSize)
        info.InjectionInfo = self:GetInjectionInfoStr(info.Address, info.InjInfoLineCount, info.InjInfoRemoveSpaces, info.InjInfoAddTabs)
        info.BaseAddressRegister = self:GetRegisterData(info.OriginalOpcodes)
    end
    return info
end

return Memory