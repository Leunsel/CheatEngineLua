local NAME = "CTI.Utility"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Cheat Table Interface (Utility)"

if not Helper then
    CETrequire('Module.Helper')
end

if not Logger then
    CETrequire('Module.Logger')
end

if not FormManager then
    CETrequire('Module.FormManager')
end

local helper = Helper:new({})

Utility = {
    Author = "",
    ProcessName = "",
    GameVersion = "",
    GameID = "",
    TableTitle = "",
    TableVersion = "",
    Signature = "",
    Slogan = "",
    DefaultTheme = "",
    IsRelease = false,
    AutoDisableTimerInterval = 100,
    AutoAttachTimerInterval = 100,
    AutoAttachTimerTicks = 0,
    AutoAttachTimerTickMax = 5000
}
Utility.__index = Utility

function Utility:new(properties)
    local obj = setmetatable({}, self)
    for key, value in pairs(properties) do
        if self[key] ~= nil then
            obj[key] = value
        end
    end
    obj.formManager = FormManager:new(properties)
    obj.logger = Logger:new()
    return obj
end

function Utility:autoDisable(id, customInterval)
    if not inMainThread() then
        synchronize(function()
            self:autoDisable(id, customInterval)
        end)
        return
    end
    checkSynchronize()
    local function autoDisableTimer_tick(timer)
        timer.destroy()
        local mr = AddressList.getMemoryRecordByID(id)
        if mr ~= nil and mr.Active then
            while mr.Async and mr.AsyncProcessing do
                sleep(0)
            end
            mr.Active = false
            while mr.Async and mr.AsyncProcessing do
                checkSynchronize()
                MainForm.repaint()
                sleep(0)
            end
        end
    end
    local autoDisableTimer = createTimer(MainForm)
    autoDisableTimer.Interval = customInterval or self.AutoDisableTimerInterval
    autoDisableTimer.OnTimer = autoDisableTimer_tick
end
function Utility:setAllScriptsToAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler and not mr.Async then
            mr.Async = true
        end
    end
end
function Utility:setAllScriptsToNotAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler and mr.Async then
            mr.Async = false
        end
    end
end
function Utility:autoAttach(processName)
    processName = processName or self.ProcessName
    local function autoAttachTimer_tick(timer)
        if self.AutoAttachTimerTickMax > 0 and self.AutoAttachTimerTicks >= self.AutoAttachTimerTickMax then
            timer.destroy()
        end
        local processID = getProcessIDFromProcessName(processName)
        if processID ~= nil then
            timer.destroy()
            openProcess(processID)
            self:setupTable()
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    local autoAttachTimer = createTimer(MainForm)
    autoAttachTimer.Interval = self.AutoAttachTimerInterval
    autoAttachTimer.OnTimer = autoAttachTimer_tick
end
function Utility:startupMessage(str)
    if str then
        messageDialog(str, 2)
    end
end
function Utility:openLink(link)
    local result = messageDialog(
        "Do you really want to open this link?\n" .. link,
        mtConfirmation,
        mbYes, mbNo
    )
    
    if result == mrYes then
        ShellExecute(link)
    end
end
function Utility:autoAttach(processName)
    processName = processName or self.ProcessName
    local function autoAttachTimer_tick(timer)
        if self.AutoAttachTimerTickMax > 0 and self.AutoAttachTimerTicks >= self.AutoAttachTimerTickMax then
            timer.destroy()
        end
        local processID = getProcessIDFromProcessName(processName)
        if processID ~= nil then
            timer.destroy()
            openProcess(processID)
            self:setupTable()
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    local autoAttachTimer = createTimer(MainForm)
    autoAttachTimer.Interval = self.AutoAttachTimerInterval
    autoAttachTimer.OnTimer = autoAttachTimer_tick
end
function Utility:attachToProcess(processName)
    processName = processName or self.ProcessName
    local processID = getProcessIDFromProcessName(processName)
    if processID ~= nil then
        openProcess(processID)
    else
        -- messageDialog("Process not found: " .. processName, mtError, mbOK)
    end
end
function Utility:closeProcess()
    local processID = getOpenedProcessID()
    
    if processID == 0 then
        messageDialog("No process is currently attached.", mtError, mbOK)
        return
    end
    
    local processName = process
    local message = string.format("Do you really want to terminate the process %s (PID: %d)?", processName, processID)
    local result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    
    if result == mrYes then
        local command = string.format("taskkill /PID %d /F", processID)
        os.execute(command)
    end
end
--
---- Message Dialog Presets

function Utility:showInfo(message)
    messageDialog(message, mtInformation, mbOK)
end

function Utility:showWarning(message)
    messageDialog(message, mtWarning, mbOK)
end

function Utility:showError(message)
    title = title or "Error"
    messageDialog(message, mtError, mbOK)
end

function Utility:showConfirmation(message)
    local result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    return result == mrYes
end

--
---- Data Handling

function Utility:safeReadByte(address)
    local value = readBytes(address, 1)
    if value == nil then
        logger:error("Unable to read byte value at address " .. address, {address = address})
        return nil
    end
    return value
end

function Utility:safeReadInteger(address)
    local value = readInteger(address)
    if value == nil then
        logger:error("Unable to read integer value at address " .. address, {address = address})
        return nil
    end
    return value
end

function Utility:safeReadFloat(address)
    local value = readFloat(address)
    if value == nil then
        logger:error("Unable to read float value at address " .. address, {address = address})
        return nil
    end
    return value
end

function Utility:safeReadDouble(address)
    local value = readDouble(address)
    if value == nil then
        logger:error("Unable to read double value at address " .. address, {address = address})
        return nil
    end
    return value
end

-- Safe Write Methods
function Utility:safeWriteInteger(address, value)
    local success = writeInteger(address, value)
    if not success then
        logger:error("Unable to write integer value to address " .. address, {address = address, value = value})
    end
    return success
end

function Utility:safeWriteByte(address, value)
    local success = writeBytes(address, value)
    if not success then
        logger:error("Unable to write byte value to address " .. address, {address = address, value = value})
    end
    return success
end

function Utility:safeWriteFloat(address, value)
    local success = writeFloat(address, value)
    if not success then
        logger:error("Unable to write float value to address " .. address, {address = address, value = value})
    end
    return success
end

function Utility:safeWriteDouble(address, value)
    local success = writeDouble(address, value)
    if not success then
        logger:error("Unable to write double value to address " .. address, {address = address, value = value})
    end
    return success
end

--
---- Conversion Tables

---- Dying Light
function Utility:registerTimeTypes()
    local TypeName = 'Military Hours'
    local ByteCount = 4
    local IsFloat = true
    local function BytesToValue(...)
        local bytes = { ... }
        return ((byteTableToFloat({ bytes[1], bytes[2], bytes[3], bytes[4] }) * 24) * 100)
    end
    local function ValueToBytes(value)
        local bytes = floatToByteTable((value / 24) / 100)
        return bytes[1], bytes[2], bytes[3], bytes[4]
    end
    registerCustomTypeLua(TypeName, ByteCount, BytesToValue, ValueToBytes, IsFloat)
end

--
---- Conversion Tables

function Utility:resolvePointerPath(baseAddress, offsets)
    local address = getAddress(baseAddress)
    if not address then
        logger:error("Base address or symbol '" .. baseAddress .. "' not found.")
        return nil
    end
    logger:debug("Starting base address: " .. string.format("0x%X", address))
    for i, offset in ipairs(offsets) do
        if type(offset) ~= "number" then
            logger:error("Offset must be a number. Offset " .. i .. " is not a number.", {offset = offset, index = i})
            return nil
        end
        logger:debug("Applying offset " .. i .. ": " .. string.format("0x%X", offset))
        local value = readPointer(address)
        if not value then
            logger:error("Unable to read memory at address " .. string.format("0x%X", address))
            return nil
        end
        logger:debug("Value read from address " .. string.format("0x%X", address) .. ": " .. string.format("0x%X", value))
        address = value + offset
        logger:debug("New address after applying offset " .. i .. ": " .. string.format("0x%X", address))
    end
    logger:debug("Final resolved address: " .. string.format("0x%X", address))
    return address
end

--
---- Table Setup Utility

function Utility:setTitle()
    if not inMainThread() then
        synchronize(function()
            self:setTitle()
        end)
        return
    end
    local tableTitle = self.TableTitle or "TableTitle"
    local tableVersion = self.TableVersion or "TableVersion"
    local gameVersion = self.GameVersion or Helper:getFileVersionStr(Helper:getGameModulePathToFile()) or "GameVersion"
    local registrySizeStr = Helper:getRegistrySizeStr() or ""
    local ceRegistrySizeStr = (cheatEngineIs64Bit() and "(x64)") or "(x32)"
    local titleStr = string.format(
        "%s %s V:%s — CET V:%s — CE %s V:%s",
        tableTitle,
        registrySizeStr,
        gameVersion,
        tableVersion,
        ceRegistrySizeStr,
        getCEVersion()
    )
    getMainForm().Caption = titleStr
    -- return titleStr
end

function Utility:setupTable()
    if not formManager then
        formManager = FormManager:new({ Signature = self.Signature, Slogan = self.Slogan })
    end
    getMainForm().Show()
    formManager:disableHeaderSorting()
    formManager:hideSignatureControls()
    formManager:enableCompactMode()
    formManager:createSloganStr(self.Slogan)
    formManager:createSignatureStr(self.Signature)
    formManager:loadThemes()
    formManager:applyTheme(self.DefaultTheme)
    self:setTitle()
end

return Utility
