local NAME = "TemplateLoader.Memory"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Engine Template Framework (Memory)"

--[[
    -- To debug the module, use the following setup to load modules from the autorun folder:
    local sep = package.config:sub(1, 1)
    package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
    local Memory = require("Memory")
]]

--[[
    Memory Module Documentation
    ----------------------------

    -- Version:
    --   Description: The hardcoded version number of the script or module.
    --   Example: "1.0.0"

    -- HookName:
    --   Description: The hook's name, possibly parsed or formatted in a certain way.
    --   Example: hookName.hookName
    --   (e.g., "Test")

    -- HookNameParsed:
    --   Description: The parsed or formatted version of the hook's name, typically used for easier handling.
    --   Example: hookName.hookNameParsed
    --   (e.g., "TestHook")

    -- Process:
    --   Description: The name of the process currently attached (game executable).
    --   Example: Memory.Address.getAttachedProcessName()
    --   (e.g., "game.exe")

    -- ProcessBase:
    --   Description: The base address of the process.
    --   Example: processBase
    --   (e.g., "0000000000000000")

    -- Module:
    --   Description: The name of the module (DLL or EXE) in the process.
    --   Example: Memory.Address.getModuleName(address)
    --   (e.g., "game.dll")

    -- ModuleBase:
    --   Description: The base address of the module within the process.
    --   Example: moduleBase
    --   (e.g., "0000000000000000")

    -- Address:
    --   Description: The address in the format of the module name and the offset. This points to the target memory location.
    --   Example: address
    --   (e.g., "isaac-ng.exe+84D337")

    -- AoBStr:
    --   Description: The string of bytes (Array of Bytes) representing the AoB (Array of Bytes) for scanning.
    --   Example: aobStr
    --   (e.g., "90 90 90 90 90 90")

    -- AobOffset:
    --   Description: The offset within the AoB. Represents how far the address is from the beginning of the AoB.
    --   Example: aobOffset
    --   (e.g., 0, 1, 2)

    -- PointerType:
    --   Description: The type of pointer used (e.g., double word `dq` or word `dd`).
    --   Example: pointerType
    --   (e.g., "dq", "dd")

    -- PointerSize:
    --   Description: The size of the pointer. The value could be 4 for a 32-bit pointer or 8 for a 64-bit pointer.
    --   Example: pointerSize
    --   (e.g., 8, 4)

    -- BaseAddressRegister:
    --   Description: The register used for holding the base address for memory manipulation (e.g., rax, rbx).
    --   Example: baseAddressRegister
    --   (e.g., "rax", "rbx")

    -- BaseAddressOffset:
    --   Description: The offset applied to the base address stored in the register.
    --   Example: baseAddressOffset
    --   (e.g., "A0", "B0", "28")

    -- InjectionInfo:
    --   Description: Information about the injection, including a string representation of
    --                the memory region and other relevant details.
    --   Example: Memory.Address.getInjectionInfoStr(getAddressSafe(address), infoStrRegion, removeSpaces, addTabs)

    -- JumpType:
    --   Description: The type of jump instruction used (e.g., near jump `jmp` or far jump `jmp far`).
    --   Example: jumpType
    --   (e.g., "jmp", "jmp far")

    -- OriginalBytes:
    --   Description: The original bytes before any modifications (e.g., for nops or patching).
    --   Example: originalBytes
    --   (e.g., "00 00 00 00 00 00 00 00")

    -- OriginalOpcodes:
    --   Description: The original opcodes or instructions before modification.
    --   Example: originalOpcodes
    --   (e.g., "movss xmm1,xmm0")

    -- NopPadding:
    --   Description: The padding bytes used for nop operations, typically
    --                used when replacing instructions.
    --   Example: nopPadding
    --   (e.g., "db 90 90 90")

    -- Date:
    --   Description: The current date formatted as YY-MM-DD.
    --   Example: Memory.Hook.getDate()
    --   (e.g., "24-12-02")

    -- DateTime:
    --   Description: The current date and time formatted as YY-MM-DD HH:MM:SS.
    --   Example: Memory.Hook.getDateTime()
    --   (e.g., "24-12-02 14:45:30")

    -- DateTimeZone:
    --   Description: The current date and time with the time zone, formatted
    --                as YY-MM-DD HH:MM:SS Z.
    --   Example: Memory.Hook.getDateTimeZone()
    --   (e.g., "24-12-02 14:45:30 Z")

    -- Alloc:
    --   Description: A string representing the allocation statement for new memory,
    --                with the hook name parsed and specific memory size.
    --   Example: Memory.Hook.generateAllocStatement(hookName.hookNameParsed, is14ByteJump)
    --   (e.g., "alloc(newmem,$1000); alloc(newmem,$1000,TestHook)")
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
local Logger = require("Logger")

local Memory = {}

local function checkValidSize(size, address)
    if not size or size <= 0 then
        error("Failed to retrieve instruction size at address: " .. string.format("0x%X", address))
    end
end

function Memory.isTarget64Bit()
    return targetIs64Bit()
end

function Memory.getDefaultPointerType()
    if Memory.isTarget64Bit() then
        return "dq", 8
    else
        return "dd", 4
    end
end

Memory.Hook = {}

function Memory.Hook.promptHookName()
    return inputQuery("Hook Name", "Enter the hook name", "ExampleName")
end

function Memory.Hook.formatHookName(inputName, appendToHookName)
    local hookName = inputName
    local hookNameParsed = nil

    if appendToHookName then
        hookNameParsed = hookName .. appendToHookName
    end

    return {hookName = hookName, hookNameParsed = hookNameParsed}
end

function Memory.Hook.getHookNames(Settings)
    local askForHookName = Settings.AskForHookName
    local appendToHookName = Settings.AppendToHookName

    if askForHookName then
        local inputName = Memory.Hook.promptHookName()

        -- print("Input Name: " .. tostring(inputName))

        if not inputName or inputName == "" then
            Logger.warn("Memory: Hook name not provided.")
            return "", ""
        end

        local hookNames = Memory.Hook.formatHookName(inputName, appendToHookName)

        -- print("Hook Names: " .. tostring(hookNames))

        return hookNames
    end

    return "", ""
end

function Memory.Hook.generateAllocStatement(hookName, hookNameParsed, is14ByteJump)
    if is14ByteJump then
        Logger.info("Memory: Generating 14-byte jump alloc statement.")
        return string.format("alloc(n_%s,$1000)", hookName)
    else
        Logger.info("Memory: Generating 5-byte jump alloc statement.")
        return string.format("alloc(n_%s,$1000,%s)", hookName, hookNameParsed)
    end
end

function Memory.Hook.getDate()
    local dateFormat = format or "%A, %B %d %Y"
    return os.date(dateFormat)
end

function Memory.Hook.getDateTime()
    local dateTimeFormat = format or "%A, %B %d %Y %H:%M:%S"
    return os.date(dateTimeFormat)
end

function Memory.Hook.getDateTimeZone()
    local dateTimeZoneFormat = format or "%A, %B %d %Y %H:%M:%S"
    return os.date(dateTimeZoneFormat) .. " " .. os.date("%z")
end

Memory.Address = {}

-- getNameFromAddress(address,ModuleNames OPTIONAL=true, Symbols OPTIONAL=true, Sections OPTIONAL=false):
--- Returns the given address as a string. Registered symbolname, modulename+offset,
--- or just a hexadecimal string depending on what address

function Memory.Address.getFirstSelectedAddress()
    return getNameFromAddress(Memory.Address.getSelectedAddressRange(), true, false) -- , getNameFromAddress(Memory.Address.getSelectedAddressRange(), true, true)
end

function Memory.Address.extractRegisterAndOffset(instruction)
    local register, offset = instruction:match("%[([%w]+)[-+]?([%x]+)%]")
    if register and offset then
        Logger.info("Memory: Extracted Register and Offset: ".. register.. " - ".. offset)
        return register, offset
    end

    register = instruction:match("%[([%w]+)%]")
    if register then
        Logger.info("Memory: Extracted Register: ".. register)
        return register, "0"
    end

    Logger.info("Memory: No register or offset found. Checked: " .. instruction)
    return "", "Pattern not matched"
end

function Memory.Address.getSelectedAddressRange()
    local disassemblerView = getMemoryViewForm().DisassemblerView
    return math.min(disassemblerView.SelectedAddress, disassemblerView.SelectedAddress2),
           math.max(disassemblerView.SelectedAddress, disassemblerView.SelectedAddress2)
end

function Memory.Address.getAttachedProcessName()
    return process
end

function Memory.Address.getBaseAddress()
    local processName = Memory.Address.getAttachedProcessName()
    if not processName then
        Logger.critical("Memory: No attached process found.")
        error("No attached process found.")
    end

    local processBase = getAddressSafe(processName)
    if not processBase then
        Logger.critical("Memory: Failed to resolve base address for process: ".. processName)
        error("Failed to resolve base address for process: ".. processName)
    end

    local moduleName = Memory.Address.getModuleName(Memory.Address.getFirstSelectedAddress())
    if not moduleName then
        Logger.critical("Memory: No module found.")
        error("No module found.")
    end

    local moduleBase = getAddressSafe(moduleName)
    if not moduleBase then
        Logger.critical("Memory: Failed to resolve base address for module: ".. moduleName)
        error("Failed to resolve base address for module: ".. moduleName)
    end

    return processBase, moduleBase
end

function Memory.Address.getBaseAddressStr()
    local processBase, moduleBase = Memory.Address.getBaseAddress()

    local processBaseStr = string.format("%016X", processBase)
    local moduleBaseStr = string.format("%016X", moduleBase)
    Logger.info("Memory: Process Base - Module Base: ".. processBaseStr.. " - ".. moduleBaseStr)
    return processBaseStr, moduleBaseStr
end

function Memory.Address.getAttachedProcessVersion()
    -- TODO
end

function Memory.Address.getModuleName(address)
    local startAddress, endAddress = Memory.Address.getSelectedAddressRange()
    if inModule(address) and inModule(startAddress) and inModule(endAddress) then
        local moduleName = getNameFromAddress(address, true, false)
        return moduleName:match('^(.*)[+-]%x*$')
    end
    return nil
end

function Memory.Address.getModuleVersion()
    -- TODO
end

function Memory.Address.getInjectionInfo(address, injectionInfoLinesCount, removeSpaces)
    injectionInfoLinesCount = injectionInfoLinesCount or 20

    local function getLine(lineAddr)
        if not lineAddr then return "" end

        local disassembler = getVisibleDisassembler()
        local disassembledStr = disassembler.disassemble(lineAddr):gsub('{.-}', '')

        local extraField, opcode, bytes, addr = splitDisassembledString(disassembledStr)

        if not addr or addr == "" then
            Logger.error("Error: Invalid address returned after splitting disassembly.")
            return ""
        end

        addr = getNameFromAddress(addr)
                
        bytes = bytes:gsub("%s+", "")
        bytes = bytes:gsub("..", "%1 "):sub(1, -2)
        
        local line

        if removeSpaces then
            line = string.format("%s - %s - %s", addr, bytes, opcode)
        else
            line = string.format("%s - %-24s - %s", addr, bytes, opcode)
        end

        return line
    end

    local code = { getLine(address) }

    local addr = getPreviousOpcode(address)
    for i = 1, math.floor(injectionInfoLinesCount / 2) do
        local str = getLine(addr)
        table.insert(code, 1, str)
        addr = getPreviousOpcode(addr)
    end    

    addr = address + getInstructionSize(address)
    for i = 1, math.floor(injectionInfoLinesCount / 2) do
        local str = getLine(addr)
        table.insert(code, str)
        addr = addr + getInstructionSize(addr)
    end

    return code
end

function Memory.Address.getInjectionInfoStr(address, injectionInfoLinesCount, removeSpaces, addTabs)
    local code = Memory.Address.getInjectionInfo(address, injectionInfoLinesCount, removeSpaces)
    if addTabs then
        for i, line in ipairs(code) do
            code[i] = "\t ".. line
        end
    end
    return table.concat(code, "\n")
end

function Memory.Address.getUniqueAobStr()
    local base = getAddressSafe(Memory.Address.getFirstSelectedAddress())

    if not base then
        Logger.error("Memory: Failed to resolve base address.")
        return "Failed to resolve address: " .. tostring(baseStr)
    end

    local currentModule = Memory.Address.getModuleName(base)
    if not currentModule then
        Logger.error("Memory: Failed to retrieve module name for address " .. tostring(base))
        return "Failed to retrieve the module name."
    end

    local aobString, offset = getUniqueAOB(base)

    if aobString then
        -- "I assume it only checks backwards."
        
        if offset == 0 then
            Logger.success("Memory: Unique AOB:  " .. aobString)
            
            offset = ""
        else
            Logger.success("Memory: Unique AOB:  " .. aobString.. " with offset ".. offset)
            offset = string.format("+%X", offset)
        end
        return aobString, offset
    else
        Logger.warn("Memory: No unique AOB found for address " .. tostring(base))
        return "'No Unique AoB Found'", ""
    end
end

Memory.Code = {}

function Memory.Code.getInstructionSize(address)
    local size = getInstructionSize(address)
    checkValidSize(size, address)
    return size
end

function Memory.Code.getSelectedInstructionSize()
    return Memory.Code.getInstructionSize(Memory.Address.getFirstSelectedAddress())
end

function Memory.Code.getOriginalBytes(address, length)
    length = length or Memory.Code.getInstructionSize(address)
    checkValidSize(length, address)

    Logger.info(string.format("Memory.Code.getOriginalBytes: Attempting to read memory at address 0x%X with length %d.", address, length))

    local buffer = readBytes(address, length, true)
    if not buffer then
        Logger.error("Memory: Failed to read memory at address " .. string.format("0x%X", address))
        error("Failed to read memory at address: " .. string.format("0x%X", address))
    end
    local hexBytes = {}
    for i = 1, #buffer do
        table.insert(hexBytes, string.format("%02X", buffer[i]))
    end

    Logger.success(string.format("Memory: Successfully read %d bytes from address 0x%X.", length, address))
    return table.concat(hexBytes, " ")
end

function Memory.Code.getBytesInRange(startAddress, endAddress)
    if not startAddress or not endAddress then
        Logger.error("Memory: Invalid address range: startAddress or endAddress is nil.")
        error("Invalid address range: startAddress or endAddress is nil.")
    end
    if startAddress == 0 or endAddress == 0 then
        Logger.error("Memory: Invalid address range: startAddress or endAddress is 0.")
        error("Invalid address range: startAddress or endAddress is 0.")
    end
    if startAddress > endAddress then
        Logger.error("Memory: Invalid address range: startAddress cannot be greater than endAddress.")
        error("Invalid address range: startAddress cannot be greater than endAddress.")
    end

    local length = endAddress - startAddress + 1
    Logger.info(string.format("Memory: Attempting to read memory from address range 0x%X to 0x%X.", startAddress, endAddress))

    local buffer = readBytes(startAddress, length, true)
    if not buffer then
        Logger.error(string.format("Memory: Failed to read memory at address range 0x%X-0x%X.", startAddress, endAddress))
        error("Failed to read memory at address range: " .. string.format("0x%X-0x%X", startAddress, endAddress))
    end

    local hexBytes = {}
    for i = 1, #buffer do
        table.insert(hexBytes, string.format("%02X", buffer[i]))
    end

    Logger.success(string.format("Memory: Successfully read %d bytes from address range 0x%X to 0x%X.", length, startAddress, endAddress))
    return table.concat(hexBytes, " ")
end

function Memory.Code.getOriginalBytesInHex(startAddress, size)
    local byteTable = readBytes(getAddressSafe(startAddress), size, true)
    local originalBytes = {}

    for _, byte in ipairs(byteTable) do
        table.insert(originalBytes, string.format("%02X", byte))
    end

    return table.concat(originalBytes, " ")
end

function Memory.Code.calculateJumpSize(startAddress, minSize)
    local address = getAddressSafe(startAddress)
    local totalSize = 0

    while totalSize < minSize do
        local instructionSize = Memory.Code.getInstructionSize(address)
        totalSize = totalSize + instructionSize
        address = address + instructionSize
    end

    return totalSize
end

function Memory.Code.createNopPadding(size, minSize)
    return size > minSize and string.format("db %s", string.rep("90 ", size - minSize)) .. "\n" or ""
end

function Memory.Code.getOriginalOpcodes(startAddress, size)
    local address = getAddressSafe(startAddress)
    local bytesRead = 0
    local originalOpcodes = {}
    local disassembler = getVisibleDisassembler()

    while bytesRead < size do
        local instructionSize = Memory.Code.getInstructionSize(address)
        local disassembledStr = disassembler.disassemble(address)
        local _, opcode = splitDisassembledString(disassembledStr)

        opcode = opcode:gsub("%{.-%}", "")
        table.insert(originalOpcodes, "  " .. opcode)

        bytesRead = bytesRead + instructionSize
        address = address + instructionSize
    end

    return table.concat(originalOpcodes, "\n")
end

function Memory.Code.getJumpSizeBasedOnType(startAddress, is14ByteJump)
    return Memory.Code.calculateJumpSize(startAddress, is14ByteJump and 14 or 5)
end

function Memory.Code.shouldUse14ByteJumpFromUI()
    for i = 0, getFormCount() - 1 do
        local f = getForm(i)
        if f.ClassName == "TfrmAutoInject" then
            local isChecked = f.mi14ByteJMP.Checked
            Logger.info(string.format("Memory: Found TfrmAutoInject form. 14-byte jump checked: %s", tostring(isChecked)))
            return isChecked
        end
    end

    Logger.warn("Memory: TfrmAutoInject form not found. Returning false.")
    return false
end

function Memory.Code.processJumpInstruction(startAddress, is14ByteJump)
    local jumpSize = Memory.Code.getJumpSizeBasedOnType(startAddress, is14ByteJump)
    local nopPadding = Memory.Code.createNopPadding(jumpSize, is14ByteJump and 14 or 5)

    local replacedInstructionsSize = jumpSize
    local replacedInstructionsSizeHex = string.format("%X", replacedInstructionsSize)
    local jumpType = is14ByteJump and "jmp far" or "jmp"

    local originalOpcodes = Memory.Code.getOriginalOpcodes(startAddress, replacedInstructionsSize)
    local originalBytes = Memory.Code.getOriginalBytesInHex(startAddress, replacedInstructionsSize)
    Logger.info("Memory: Jump size: ".. replacedInstructionsSizeHex.. " bytes. Jump type: ".. jumpType)
    Logger.info("Memory: Original bytes: ".. originalBytes)
    Logger.info("Memory: Required Nop padding: ".. nopPadding)

    return {
        replacedInstructionsSize = replacedInstructionsSize,
        replacedInstructionsSizeHex = replacedInstructionsSizeHex,
        jumpType = jumpType,
        originalOpcodes = originalOpcodes,
        originalBytes = originalBytes,
        nopPadding = nopPadding
    }
end

Memory.Script = {}

function Memory.Script.gatherMemoryInfo(Settings)
    if not process then
        error("Not attached to a process. Exit early...")
    end
    local hookName, hookNameParsed = Memory.Hook.getHookNames(Settings)
    local address = Memory.Address.getFirstSelectedAddress()            
    local pointerType, pointerSize = Memory.getDefaultPointerType()
    local is14ByteJump = Memory.Code.shouldUse14ByteJumpFromUI()
    local jumpInfo = Memory.Code.processJumpInstruction(address, is14ByteJump)
    local jumpType = jumpInfo.jumpType
    local originalBytes = jumpInfo.originalBytes
    local originalOpcodes = jumpInfo.originalOpcodes
    local replacedInstructionsSize = jumpInfo.replacedInstructionsSize
    local nopPadding = jumpInfo.nopPadding

    local aobStr, aobOffset = Memory.Address.getUniqueAobStr()

    local baseAddressRegister, baseAddressOffset = Memory.Address.extractRegisterAndOffset(originalOpcodes)

    local processBase, moduleBase = Memory.Address.getBaseAddressStr()

    -- Settings for:
    --      Memory.Address.getInjectionInfoStr
    local infoStrRegion = 3     -- Param 2
    local removeSpaces  = true  -- Param 3
    local addTabs       = true  -- Param 4

    local memoryInfo = {
        Version = "1.0.0", -- Hardcoded... No idea how to do that.
        HookName = hookName.hookName, -- Test
        HookNameParsed = hookName.hookNameParsed, -- TestHook
        Process = Memory.Address.getAttachedProcessName(), -- game.exe
        ProcessBase = processBase, -- 0000000000000000
        Module = Memory.Address.getModuleName(address), -- game.dll; game.exe...
        ModuleBase = moduleBase, -- 0000000000000000
        Address = address, -- isaac-ng.exe+84D337
        AoBStr = aobStr, -- 90 90 90 90 90 90
        AoBOffset = aobOffset, -- Integer... 0, 1, 2
        PointerType = pointerType, -- dq; dd
        PointerSize = pointerSize, -- 8; 4
        BaseAddressRegister = baseAddressRegister, -- rax; rbx
        BaseAddressOffset = baseAddressOffset, -- A0, B0; 28
        InjectionInfo = Memory.Address.getInjectionInfoStr(getAddressSafe(address), infoStrRegion, removeSpaces, addTabs),
        JumpType = jumpType, -- jmp; jmp far
        OriginalBytes = originalBytes, -- 00 00 00 00 00 00 00 00
        OriginalOpcodes = originalOpcodes, -- movss xmm1,xmm0
        NopPadding = nopPadding, -- db 90 90 90
        Date = Memory.Hook.getDate(), -- YY-MM-DD
        DateTime = Memory.Hook.getDateTime(), -- YY-MM-DD HH:MM:SS
        DateTimeZone = Memory.Hook.getDateTimeZone(), -- YY-MM-DD HH:MM:SS Z
        Alloc = Memory.Hook.generateAllocStatement(hookName.hookName, hookName.hookNameParsed, is14ByteJump) -- alloc(newmem,$1000); alloc(newmem,$1000,TestHook)
    }

    return memoryInfo
end

return Memory
