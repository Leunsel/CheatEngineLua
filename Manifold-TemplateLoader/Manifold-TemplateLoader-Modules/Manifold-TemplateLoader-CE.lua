--[[
    Defensive wrappers around the Cheat Engine Lua API.

    Every function here maps a CE call that can realistically fail (no process
    attached, address unreadable, form already destroyed) onto a nil-on-failure
    result. Callers decide whether a nil is an expected condition or a
    structured error. Nothing in this module swallows a failure into a fake
    success.

    Only APIs documented in celua.txt are used.
]]

local CE = {}
CE.__index = CE

function CE:New()
    return setmetatable({}, CE)
end

--
--- Calls a global CE function by name inside pcall. Returns up to four
--- results, or nil when the function does not exist or raised.
--
function CE:Call(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d
end

function CE:Has(name)
    return type(rawget(_G, name)) == "function"
end

function CE:InMainThread()
    local ok, result = pcall(inMainThread)
    return ok and result == true
end

--
--- Runs fn on the main thread. Already-on-main runs directly. No pointless
--- synchronization hop.
--
function CE:RunInMain(fn)
    if self:InMainThread() then
        return fn()
    end
    local result, resultB
    synchronize(function() result, resultB = fn() end)
    return result, resultB
end

-- Process / target ----------------------------------------------------------

function CE:GetProcessName()
    local name = rawget(_G, "process")
    return type(name) == "string" and name ~= "" and name or nil
end

function CE:IsTarget64Bit()
    return self:Call("targetIs64Bit") == true
end

function CE:GetAddressSafe(value)
    return self:Call("getAddressSafe", value)
end

function CE:GetNameFromAddress(address, moduleNames, symbols, sections)
    return self:Call("getNameFromAddress", address, moduleNames, symbols, sections)
end

function CE:InModule(address)
    return self:Call("inModule", address) == true
end

function CE:ReadBytesTable(address, size)
    local values = self:Call("readBytes", address, size, true)
    if type(values) ~= "table" or #values ~= size then return nil end
    return values
end

-- Disassembler --------------------------------------------------------------

function CE:GetInstructionSize(address)
    return self:Call("getInstructionSize", address)
end

function CE:GetPreviousOpcode(address)
    return self:Call("getPreviousOpcode", address)
end

function CE:GetUniqueAOB(address)
    return self:Call("getUniqueAOB", address)
end

function CE:Disassemble(address)
    local disassembler = self:Call("getVisibleDisassembler")
    if not disassembler then return nil end
    local ok, line = pcall(function() return disassembler.disassemble(address) end)
    return ok and type(line) == "string" and line or nil
end

function CE:SplitDisassembledString(line)
    return self:Call("splitDisassembledString", line)
end

function CE:GetSelectedDisassemblerAddress()
    local memoryView = self:Call("getMemoryViewForm")
    local ok, selected = pcall(function()
        return memoryView and memoryView.DisassemblerView and memoryView.DisassemblerView.SelectedAddress
    end)
    if not ok or not selected then return nil end
    return self:GetAddressSafe(selected) or selected
end

-- Forms ---------------------------------------------------------------------

function CE:GetFormCount()
    return self:Call("getFormCount") or 0
end

function CE:GetForm(index)
    return self:Call("getForm", index)
end

function CE:IsAutoInjectForm(form)
    if not form then return false end
    local ok, className = pcall(function() return form.ClassName end)
    return ok and className == "TfrmAutoInject"
end

--
--- Distinguishes a real Auto Assembler window from the other TfrmAutoInject
--- instances Cheat Engine creates. Above all MainForm.frmLuaTableScript,
--- the always-present hidden "Cheat Table Lua Script" window.
--- TfrmAutoInject publishes ScriptMode, and CE's own TfrmAutoInject.addTemplate
--- only creates template menu items when ScriptMode = smAutoAssembler. Using
--- the same condition means the loader manages exactly the windows Cheat
--- Engine itself considers template targets.
--- The property is read through CE's RTTI fallback, so it can surface as the
--- enum name or its ordinal. If it cannot be read at all (an older or patched
--- build), fall back to accepting the window rather than tracking nothing.
--
function CE:IsAutoAssemblerForm(form)
    if not self:IsAutoInjectForm(form) then return false end
    local ok, mode = pcall(function() return form.ScriptMode end)
    if not ok or mode == nil then return true end
    if type(mode) == "string" then return mode == "smAutoAssembler" end
    if type(mode) == "number" then return mode == 0 end
    return true
end

--
--- Window handle of a LIVE form. Never call this on a stored reference. CE
--- frees an Auto Assembler window on close (FormClose sets caFree) without
--- invalidating the Lua userdata, so reading from a stale reference is a
--- use-after-free. Identity is therefore tracked by handle, and handles are
--- only ever read from forms the getForm enumeration just returned.
--
function CE:GetFormHandle(form)
    local ok, handle = pcall(function() return form.Handle end)
    if not ok or handle == nil or handle == 0 then return nil end
    return handle
end

--
--- Live Auto Assembler windows, straight from Cheat Engine's enumeration.
--
function CE:EnumerateAutoAssemblerForms()
    local forms = {}
    for index = 0, self:GetFormCount() - 1 do
        local form = self:GetForm(index)
        if self:IsAutoAssemblerForm(form) then forms[#forms + 1] = form end
    end
    return forms
end

-- Dialogs and shell ----------------------------------------------------------

function CE:InputQuery(caption, prompt, default)
    return self:Call("inputQuery", caption, prompt, default)
end

function CE:MessageDialog(text, dialogType, ...)
    if type(messageDialog) ~= "function" then return nil end
    local ok, result = pcall(messageDialog, text, dialogType, ...)
    return ok and result or nil
end

function CE:ShowMessage(text)
    self:Call("showMessage", tostring(text))
end

function CE:ShellExecute(target)
    self:Call("shellExecute", target)
end

function CE:WriteToClipboard(text)
    return select(1, pcall(writeToClipboard, tostring(text))) == true
end

--
--- autoAssembleCheck performs Cheat Engine's own syntax check without
--- executing the script. Custom Auto Assembler commands (for example the
--- Manifold Framework's ManifoldScanModule) DO run their Lua transformations
--- during that check, so this is opt-in for generation output validation.
--- Returns nil when the API is unavailable, otherwise ok, errorMessage.
--
function CE:AutoAssembleCheck(text, enable)
    if not self:Has("autoAssembleCheck") then return nil end
    local ok, success, message = pcall(autoAssembleCheck, text, enable == true)
    if not ok then return nil end
    return success == true, message
end

function CE:CreateTimer(interval, onTimer)
    local ok, timer = pcall(createTimer)
    if not ok or not timer then return nil end
    if interval then timer.Interval = interval end
    if onTimer then timer.OnTimer = onTimer end
    return timer
end

return CE