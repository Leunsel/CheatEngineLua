--[[
    Defensive wrappers around the Cheat Engine Lua API.

    Every call here maps a Cheat Engine function that can realistically fail
    (no process attached, a form not built yet, an API missing on an older
    build) onto a nil-on-failure result with a reason. Nothing in this module
    turns a failure into a fake success: a missing confirmation dialog blocks
    the action, it does not approve it.

    Every global is looked up at call time, never captured at load time, so a
    test can stub the API and a Cheat Engine build that lacks a function
    degrades to a logged reason rather than an error while autorun loads.

    Only functions documented in celua.txt are used.
]]

local CE = {}
CE.__index = CE

function CE:New()
    return setmetatable({}, CE)
end

--
--- ∑ Whether a global Cheat Engine function exists.
--- @param name string
--- @return boolean
--
function CE:Has(name)
    return type(rawget(_G, name)) == "function"
end

--
--- ∑ A numeric Cheat Engine constant, with a fallback for a build that does
---   not define it. The vt* and mr* families are fixed in defines.lua, so the
---   fallback is the documented value, not a guess.
--- @param name string
--- @param fallback number
--- @return number
--
function CE:Constant(name, fallback)
    local value = rawget(_G, name)
    if type(value) == "number" then return value end
    return fallback
end

--
--- ∑ Calls a global Cheat Engine function by name inside pcall.
--- @param name string
--- @param ... any
--- @return any ... # The function's own results, or nil and a reason.
--
function CE:Call(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return nil, name .. " is not available" end
    local results = table.pack(pcall(fn, ...))
    if not results[1] then return nil, tostring(results[2]) end
    return table.unpack(results, 2, results.n)
end

--
--- ∑ Reads one property off a Cheat Engine object. Properties reached through
---   the RTTI fallback raise on an object that has been freed, so every read
---   from a userdata goes through here.
--- @param object userdata|table
--- @param key string
--- @return any # The value, or nil when the read raised.
--
function CE:Get(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

--
--- ∑ True on the main thread, and true when the question cannot be asked.
---   Assuming the main thread on an unknown build means a direct call, which
---   is what every Cheat Engine build before inMainThread existed did.
--- @return boolean
--
function CE:InMainThread()
    local fn = rawget(_G, "inMainThread")
    if type(fn) ~= "function" then return true end
    local ok, result = pcall(fn)
    return (not ok) or result == true
end

--
--- ∑ Runs fn on the main thread and returns what pcall would. Touching the
---   LCL from a timer or a worker thread is what makes Cheat Engine fall
---   over, so every window and menu operation goes through here.
--- @param fn function
--- @return boolean, any # ok, then the result or the error.
--
function CE:RunInMain(fn)
    if type(fn) ~= "function" then return false, "expected a function" end
    local sync = rawget(_G, "synchronize")
    if self:InMainThread() or type(sync) ~= "function" then
        return pcall(fn)
    end
    local ok, result = false, "synchronize did not run the function"
    local synced, err = pcall(sync, function() ok, result = pcall(fn) end)
    if not synced then return false, tostring(err) end
    return ok, result
end

--------------------------------------------------------
--                   Cheat Engine objects             --
--------------------------------------------------------

function CE:MainForm()
    return (self:Call("getMainForm"))
end

function CE:MainMenu()
    local form = self:MainForm()
    if not form then return nil end
    return self:Get(form, "Menu")
end

function CE:AddressList()
    return (self:Call("getAddressList"))
end

function CE:MemoryView()
    return (self:Call("getMemoryViewForm"))
end

function CE:LuaEngine()
    return (self:Call("getLuaEngine"))
end

--- Whether a process is attached. getOpenedProcessID is 0 without one.
function CE:ProcessOpen()
    local pid = self:Call("getOpenedProcessID")
    return type(pid) == "number" and pid ~= 0
end

function CE:Repaint()
    local form = self:MainForm()
    if not form then return false end
    return (pcall(function() form.repaint() end))
end

--------------------------------------------------------
--                        Dialogs                     --
--------------------------------------------------------

--
--- ∑ Asks before something irreversible. Without a usable dialog API the
---   answer is no: a missing confirmation must never read as consent.
--- @param action string # What is about to happen.
--- @param affectedCount number|nil # How many entries it touches.
--- @param note string|nil # A consequence worth spelling out under the count.
--- @return boolean, string|nil # True when the user agreed; otherwise false
---         and, when it was not the user's decision, the reason.
--
function CE:Confirm(action, affectedCount, note)
    local dialog = rawget(_G, "messageDialog")
    local mtConfirmation = rawget(_G, "mtConfirmation")
    local mbYes, mbNo, mrYes = rawget(_G, "mbYes"), rawget(_G, "mbNo"), rawget(_G, "mrYes")
    if type(dialog) ~= "function"
        or type(mtConfirmation) ~= "number"
        or type(mbYes) ~= "number"
        or type(mbNo) ~= "number"
        or type(mrYes) ~= "number" then
        return false, "the confirmation dialog is not available"
    end
    local text = tostring(action)
    if affectedCount ~= nil then
        text = text .. "\n\nAffected entries: " .. tostring(affectedCount)
    end
    if note and note ~= "" then
        text = text .. "\n\n" .. tostring(note)
    end
    text = text .. "\n\nDo you want to continue?"
    local ok, result = self:RunInMain(function()
        return dialog(text, mtConfirmation, mbYes, mbNo)
    end)
    if not ok then return false, "the confirmation dialog failed: " .. tostring(result) end
    return result == mrYes
end

--
--- ∑ Asks for one line of text.
--- @param caption string
--- @param prompt string
--- @param default string|nil
--- @return string|nil, string|nil # The text, or nil on cancel; a reason when
---         the dialog itself was unavailable.
--
function CE:Input(caption, prompt, default)
    local fn = rawget(_G, "inputQuery")
    if type(fn) ~= "function" then return nil, "inputQuery is not available" end
    local ok, result = self:RunInMain(function()
        return fn(caption, prompt, default or "")
    end)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "string" then return nil end
    return result
end

--
--- ∑ Opens a file, folder or URL with the shell. celua.txt documents
---   shellExecute; the capitalised spelling is kept as a fallback because
---   the 1.x utility ran on it.
--- @param command string
--- @param parameters string|nil
--- @param folder string|nil
--- @return boolean, string|nil
--
function CE:Shell(command, parameters, folder)
    local fn = rawget(_G, "shellExecute")
    if type(fn) ~= "function" then fn = rawget(_G, "ShellExecute") end
    if type(fn) ~= "function" then return false, "shellExecute is not available" end
    local ok, err = pcall(fn, command, parameters, folder)
    if not ok then return false, tostring(err) end
    return true
end

return CE
