--[[
    Manifold.TemplateLoader.Memory.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 2.0.0
    LICENSE : MIT
    CREATED : 2025-06-21
    UPDATED : 2025-06-23

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

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Log = require("Manifold-TemplateLoader-Log")

local log = Log:New()

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
        log:Debug(string.format("[Memory] SetInjInfoLineCount: %d", count))
        self.InjInfoLineCount = count
    else
        log:Warning("[Memory] Invalid InjInfoLineCount value: " .. tostring(count))
        return
    end
end

function Memory:SetInjInfoRemoveSpaces(remove)
    if type(remove) == "boolean" then
        log:Debug(string.format("[Memory] SetInjInfoRemoveSpaces: %s", tostring(remove)))
        self.InjInfoRemoveSpaces = remove
    else
        log:Warning("[Memory] Invalid InjInfoRemoveSpaces value: " .. tostring(remove))
        return
    end
end

function Memory:SetInjInfoAddTabs(addTabs)
    if type(addTabs) == "boolean" then
        log:Debug(string.format("[Memory] SetInjInfoAddTabs: %s", tostring(addTabs)))
        self.InjInfoAddTabs = addTabs
    else
        log:Warning("[Memory] Invalid InjInfoAddTabs value: " .. tostring(addTabs))
        return
    end
end

function Memory:SetAppendToHookName(appendToHookName)
    if type(appendToHookName) == "string" then
        log:Debug(string.format("[Memory] SetAppendToHookName: %s", appendToHookName))
        self.AppendToHookName = appendToHookName
    else
        log:Warning("[Memory] Invalid AppendToHookName value: " .. tostring(appendToHookName))
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
    local date = os.date(dateFormat)
    log:Debug("[Memory] GetCurrentDate: " .. date)
    return date
end

function Memory:GetCurrentDateTime()
    local dateTimeFormat = "%Y-%m-%d %H:%M:%S"
    local dateTime = os.date(dateTimeFormat)
    log:Debug("[Memory] GetCurrentDateTime: " .. dateTime)
    return dateTime
end

function Memory:GetCurrentTime()
    local timeFormat = "%H:%M:%S"
    local time = os.date(timeFormat)
    log:Debug("[Memory] GetCurrentTime: " .. time)
    return time
end

-- ...........................................
-- Neccessities
-- ...........................................

function Memory:GetDefaultPointerSize()
    local ptrType, size
    if self:IsTarget64Bit() then
        ptrType, size = "dq", 8
    else
        ptrType, size = "dd", 4
    end
    log:Debug(string.format("[Memory] GetDefaultPointerSize: %s, %d", ptrType, size))
    return ptrType, size
end

function Memory:IsTarget64Bit()
    local result = targetIs64Bit()
    log:Debug("[Memory] IsTarget64Bit: " .. tostring(result))
    return result
end

function Memory:Is14ByteJump()
    for i = 0, getFormCount() - 1 do
        local f = getForm(i)
        if f.ClassName == "TfrmAutoInject" then
            local isChecked = f.mi14ByteJMP.Checked
            log:Debug("[Memory] Is14ByteJump: " .. tostring(isChecked))
            return isChecked
        end
    end
    log:Debug("[Memory] Is14ByteJump: false (form not found)")
    return false
end

-- ...........................................
-- Hook Data
-- ...........................................

function Memory:PromptForHookName()
    local name = inputQuery("Hook Name", "Enter the hook name", "ExampleName")
    log:Debug("[Memory] PromptForHookName: " .. tostring(name))
    if not name or name == "" then
        log:Warning("[Memory] PromptForHookName: No name entered")
        return
    end
    return name
end

function Memory:FormatHookName(hookName)
    local hookNameParsed
    if not hookName:match(self.AppendToHookName .. "$") then
        hookNameParsed = hookName .. self.AppendToHookName
    else
        hookNameParsed = hookName
    end
    log:Debug(string.format("[Memory] FormatHookName: input='%s', output='%s'", hookName, hookNameParsed))
    return hookNameParsed
end

function Memory:GetHookNames()
    local hookName = self:PromptForHookName()
    if not hookName or hookName == "" then
        log:Warning("[Memory] GetHookNames: No hook name provided")
        return nil, nil
    end
    local hookNameParsed = self:FormatHookName(hookName)
    log:Debug(string.format("[Memory] GetHookNames: hookName='%s', hookNameParsed='%s'", hookName, hookNameParsed))
    return hookName, hookNameParsed
end

function Memory:GetAllocStatement(hookName, hookNameParsed)
    local statement
    if self:Is14ByteJump() then
        statement = string.format("alloc(n_%s,$1000)", hookName)
    else
        statement = string.format("alloc(n_%s,$1000,%s)", hookName, hookNameParsed)
    end
    log:Debug(string.format("[Memory] GetAllocStatement: %s", statement))
    return statement
end

-- ...........................................
-- Selection Data
-- ...........................................

function Memory:IsValidInstructionSize(size, addr)
    local valid = size and size > 0
    log:Debug(string.format("[Memory] IsValidInstructionSize: addr=%s, size=%s, valid=%s", tostring(addr), tostring(size), tostring(valid)))
    return valid
end

function Memory:GetInstructionSize(addr)
    local size = getInstructionSize(addr)
    if not self:IsValidInstructionSize(size, addr) then
        log:Warning(string.format("[Memory] GetInstructionSize: Invalid size at addr=%s", tostring(addr)))
        return nil
    end
    log:Debug(string.format("[Memory] GetInstructionSize: addr=%s, size=%d", tostring(addr), size))
    return size
end

function Memory:GetSelection()
    local sel = getNameFromAddress(getMemoryViewForm().DisassemblerView.SelectedAddress, true, true, true)
    log:Debug("[Memory] GetSelection: " .. tostring(sel))
    return sel
end

function Memory:GetSelectionSize(addr)
    local size = self:GetInstructionSize(addr) or 0
    log:Debug(string.format("[Memory] GetSelectionSize: addr=%s, size=%d", tostring(addr), size))
    return size
end

-- ...........................................
-- Original Data
-- ...........................................

function Memory:GetOpcodes(startAddr, requiredSize)
    local opcodes = {}
    local address = getAddressSafe(startAddr)
    local totalSize = 0
    local disassembler = getVisibleDisassembler()
    log:Debug(string.format("[Memory] GetOpcodes: startAddr=%s, requiredSize=%d", tostring(startAddr), requiredSize))
    while totalSize < requiredSize do
        local instructionSize = self:GetInstructionSize(address)
        if not instructionSize or instructionSize <= 0 then break end
        local _, opcode = splitDisassembledString(disassembler.disassemble(address))
        opcode = opcode:gsub("%{.-%}", "")
        opcodes[#opcodes + 1] = "  " .. opcode
        totalSize = totalSize + instructionSize
        address = address + instructionSize
    end
    local result = table.concat(opcodes, "\n")
    log:Debug("[Memory] GetOpcodes result:\n" .. result)
    return result
end

function Memory:GetBytes(startAddr, size)
    local bytes = {}
    local address = getAddressSafe(startAddr)
    local bytesRead = 0
    log:Debug(string.format("[Memory] GetBytes: startAddr=%s, size=%d", tostring(startAddr), size))
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
    local result = table.concat(bytes, " ")
    log:Debug("[Memory] GetBytes result: " .. result)
    return result
end

function Memory:GetNopPadding(size, minSize)
    local pad = size - minSize
    local result = ""
    if pad > 0 then
        result = ("db " .. ("90 "):rep(pad):sub(1, -2)) .. "\n"
    end
    log:Debug(string.format("[Memory] GetNopPadding: size=%d, minSize=%d, result='%s'", size, minSize, result))
    return result
end

-- ...........................................
-- Jump Data
-- ...........................................

function Memory:GetMinJumpSize()
    local minSize = self:Is14ByteJump() and 14 or 5
    log:Debug("[Memory] GetMinJumpSize: " .. tostring(minSize))
    return minSize
end

function Memory:GetJumpType()
    local jumpType = self:Is14ByteJump() and "jmp far" or "jmp"
    log:Debug("[Memory] GetJumpType: " .. jumpType)
    return jumpType
end

function Memory:GetJumpSize(addr, minSize)
    local address = getAddressSafe(addr)
    local totalSize = 0
    log:Debug(string.format("[Memory] GetJumpSize: addr=%s, minSize=%d", tostring(addr), minSize))
    while totalSize < minSize do
        local instructionSize = self:GetInstructionSize(address)
        if not instructionSize or instructionSize <= 0 then
            break
        end
        totalSize = totalSize + instructionSize
        address = address + instructionSize
    end
    log:Debug("[Memory] GetJumpSize result: " .. tostring(totalSize))
    return totalSize
end

-- ...........................................
-- Module and Process Data
-- ...........................................

function Memory:GetProcessName()
    log:Debug("[Memory] GetProcessName: " .. tostring(process))
    return process
end

function Memory:GetProcessBase()
    local processName = self:GetProcessName()
    if processName and processName ~= "" then
        local base = getAddressSafe(processName)
        log:Debug("[Memory] GetProcessBase: " .. tostring(base))
        return base
    end
    log:Warning("[Memory] GetProcessBase: No process name found")
end

function Memory:GetProcessBaseStr()
    local base = self:GetProcessBase()
    local result = base and string.format("%016X", base) or "No process base found."
    log:Debug("[Memory] GetProcessBaseStr: " .. result)
    return result
end

function Memory:GetModuleName(addr)
    local address = addr or self:GetSelection()
    if inModule(address) then
        local moduleName = getNameFromAddress(address, true, false)
        local result = moduleName:match("^(.*)[+-]%x*$") or moduleName
        log:Debug("[Memory] GetModuleName: " .. tostring(result))
        return result
    end
    log:Warning("[Memory] GetModuleName: Not in module for address " .. tostring(address))
end

function Memory:GetModuleBase(addr)
    local moduleName = self:GetModuleName(addr)
    if moduleName then
        local base = getAddressSafe(moduleName)
        log:Debug("[Memory] GetModuleBase: " .. tostring(base))
        return base
    end
    log:Warning("[Memory] GetModuleBase: No module name found")
    return nil
end

function Memory:GetModuleBaseStr()
    local base = self:GetModuleBase()
    local result = base and string.format("%016X", base) or "No module base found."
    log:Debug("[Memory] GetModuleBaseStr: " .. result)
    return result
end

-- ...........................................
-- Processed Data
-- ...........................................

function Memory:GetAoB()
    local base = getAddressSafe(self:GetSelection())
    if not base then
        log:Warning("[Memory] GetAoB: Failed to resolve address")
        return "Failed to resolve address: " .. tostring(base)
    end
    local currentModule = self:GetModuleName(base)
    if not currentModule then
        log:Warning("[Memory] GetAoB: Failed to retrieve the module name")
        return "Failed to retrieve the module name."
    end
    local aobString, offset = getUniqueAOB(base)
    if not aobString then
        log:Warning("[Memory] GetAoB: No Unique AoB Found")
        return "'No Unique AoB Found'", ""
    end
    log:Debug(string.format("[Memory] GetAoB: aobString='%s', offset='%s'", tostring(aobString), tostring(offset)))
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
        log:Debug(string.format("[Memory] GetRegisterData: register='%s', offset='%s'", register, offset))
        return register, offset
    end
    register = instr:match("%[([%w]+)%]")
    if register then
        log:Debug(string.format("[Memory] GetRegisterData: register='%s', offset='0'", register))
        return register, "0"
    end
    log:Warning("[Memory] GetRegisterData: No register data found in instruction: " .. tostring(instr))
    return nil, nil
end

function Memory:GetJumpData(addr, jmpSize)
    log:Debug(string.format("[Memory] GetJumpData: addr=%s, jmpSize=%d", tostring(addr), jmpSize))
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
    log:Debug(string.format("[Memory] GetInjectionInfo: addr=%s, lines=%s, removeSpaces=%s", tostring(addr), tostring(injectionInfoLinesCount), tostring(removeSpaces)))
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
    log:Debug("[Memory] GetInjectionInfo result:\n" .. table.concat(code, "\n"))
    return code
end

function Memory:GetInjectionInfoStr(addr)
    local injectionInfoLinesCount = self.InjInfoLineCount
    local removeSpaces = self.InjInfoRemoveSpaces
    local addTabs = self.InjInfoAddTabs
    log:Debug(string.format("[Memory] GetInjectionInfoStr: addr=%s, lines=%s, removeSpaces=%s, addTabs=%s", tostring(addr), tostring(injectionInfoLinesCount), tostring(removeSpaces), tostring(addTabs)))
    local code = self:GetInjectionInfo(addr, injectionInfoLinesCount, removeSpaces)
    if addTabs then
        for i, line in ipairs(code) do
            code[i] = "\t  " .. line
        end
    end
    local result = table.concat(code, "\n")
    log:Debug("[Memory] GetInjectionInfoStr result:\n" .. result)
    return result
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