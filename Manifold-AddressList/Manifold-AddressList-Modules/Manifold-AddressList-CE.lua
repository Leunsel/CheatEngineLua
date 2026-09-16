--[[
    Defensive wrappers around the Cheat Engine Lua API.

    This is the only file in the segment that touches a Cheat Engine global,
    so it carries the guards for all of it. Every call maps a function that can
    realistically fail onto nil or false plus a reason. Realistically means no
    process attached, no Cheat Table loaded, a form that was never opened, or a
    Cheat Engine build that never had the function. Nothing here turns a
    failure into a fake success. A missing confirmation dialog blocks the
    action, it never reads as consent.

    Every global is looked up at call time and never captured at load time. A
    test can therefore stub the API, and a Cheat Engine that lacks a function
    degrades to a reason instead of raising an error while autorun is still
    loading.

    The Cheat Engine facts this file exists to respect.

    1. Methods are dot called. A colon call hands the object in as the first
       argument, every argument after it lands one place too far along, and
       nothing says so.
    2. Reading an event type Cheat Engine never registered raises, and the
       address list owns every event it has. No event name is ever read from
       here, on any object. An event is an On followed by a capital, so a
       hotkey's OnlyWhileDown is still a property and still readable.
    3. getAddressList().refresh() does not repaint the record tree. Refresh is
       not virtual, so it reaches the panel and never the tree inside it. Only
       List.repaint() shows a change.
    4. getMemoryRecord wants an integer from zero to Count minus one. A
       negative index dereferences nil inside Pascal, and that is an access
       violation rather than a Lua error, so pcall would not catch it. The
       bounds are checked in Lua before the call.
    5. getMemoryRecord is only cheap when the index is next to the last one
       asked for, because the tree caches one node. That is why Walk exists and
       why the walk goes in order.
    6. getSelectedRecords answers nothing at all at zero and a table with holes
       in it otherwise, so it is read with pairs and never with ipairs.
    7. setSelectedRecord given a record that is gone clears the whole selection
       instead of raising, so an id is resolved before it is handed over.
    8. createMemoryRecord appends a four byte record described Plugin Address
       at the end of the root, and it is the one Lua edit that marks the Cheat
       Table as edited. Nothing else exposed can.
    9. A memory record wrapper is built fresh on every access and a wrapper of
       a deleted record raises on any read, so nothing here keeps one past the
       call that asked for it.
]]

local CE = {}
CE.__index = CE

--- What an event member is named. Reading one of the unregistered types
--- raises inside Cheat Engine, and there is no way to ask which are which, so
--- none of them is read at all. The capital after the On is what keeps a
--- hotkey's OnlyWhileDown out of this, because that one is a plain property
--- and the Hotkeys page has to read it.
local EVENT_NAME = "^On%u"

--- Names for the virtual keys a hotkey realistically carries, for the build
--- where convertKeyComboToString is missing. Letters, digits, the function
--- keys and the numeric pad are filled in below rather than written out.
local KEY_NAMES = {
    [8] = "BACKSPACE", [9] = "TAB", [13] = "ENTER", [16] = "SHIFT", [17] = "CTRL",
    [18] = "ALT", [19] = "PAUSE", [20] = "CAPSLOCK", [27] = "ESC", [32] = "SPACE",
    [33] = "PAGEUP", [34] = "PAGEDOWN", [35] = "END", [36] = "HOME",
    [37] = "LEFT", [38] = "UP", [39] = "RIGHT", [40] = "DOWN",
    [45] = "INSERT", [46] = "DELETE",
    [91] = "LWIN", [92] = "RWIN", [93] = "MENU",
    [106] = "NUMPAD *", [107] = "NUMPAD +", [109] = "NUMPAD -",
    [110] = "NUMPAD .", [111] = "NUMPAD /",
    [144] = "NUMLOCK", [145] = "SCROLLLOCK",
    [160] = "LSHIFT", [161] = "RSHIFT", [162] = "LCTRL", [163] = "RCTRL",
    [164] = "LALT", [165] = "RALT"
}
for index = 0, 9 do KEY_NAMES[48 + index] = tostring(index) end
for index = 0, 25 do KEY_NAMES[65 + index] = string.char(65 + index) end
for index = 0, 9 do KEY_NAMES[96 + index] = "NUMPAD " .. index end
for index = 1, 24 do KEY_NAMES[111 + index] = "F" .. index end

--
--- ∑ Builds the wrapper. It holds no Cheat Engine object of its own, because
---   every one of them is resolved again on the next call.
--- @param services table|nil # Log, which is only used to report a refusal.
--- @return table
--
function CE:New(services)
    services = services or {}
    return setmetatable({
        Log = services.Log
    }, CE)
end

--- Says something through the log when there is one. The segment has to
--- behave without a Log, so one is never assumed.
local function report(self, message)
    local log = self.Log
    if type(log) ~= "table" or type(log.Warning) ~= "function" then return false end
    return (pcall(log.Warning, log, message)) == true
end

--------------------------------------------------------
--                      The basics                    --
--------------------------------------------------------

--
--- ∑ Whether a global Cheat Engine function exists on this build.
--- @param name string
--- @return boolean
--
function CE:Has(name)
    return type(rawget(_G, name)) == "function"
end

--
--- ∑ A numeric Cheat Engine constant, with a fallback for a build that does
---   not define it. The vt and mrh families are fixed in defines.lua, so the
---   fallback is the documented value and not a guess.
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
--- ∑ Calls a global Cheat Engine function by name inside pcall. It answers
---   what the function answered, so a caller tests the value and never an ok
---   flag in front of it.
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
--- ∑ Reads one property off a Cheat Engine object. A property reached through
---   the RTTI fallback raises on an object that has been freed, and a memory
---   record wrapper raises on every member once its record is gone, so every
---   read from Cheat Engine goes through here.
---
---   An event name is refused without touching the object, because reading an
---   event type Cheat Engine never registered raises. A hotkey's OnlyWhileDown
---   is not one, which is why the capital after the On is what decides.
--- @param object userdata|table|nil
--- @param key string
--- @return any # The value, or nil when there was none or the read raised.
--
function CE:Get(object, key)
    if object == nil then return nil end
    if type(key) == "string" and key:match(EVENT_NAME) then
        return nil
    end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

--
--- ∑ Dot calls one method off a Cheat Engine object.
--- @param object userdata|table|nil
--- @param name string
--- @param ... any
--- @return any ... # The method's results, or nil and a reason.
--
local function invoke(self, object, name, ...)
    local method = self:Get(object, name)
    if type(method) ~= "function" then return nil, name .. " is not available" end
    local results = table.pack(pcall(method, ...))
    if not results[1] then return nil, tostring(results[2]) end
    return table.unpack(results, 2, results.n)
end

--
--- ∑ True on the main thread, and true when the question cannot be asked.
---   Assuming the main thread on an unknown build means a direct call, which
---   is what every Cheat Engine before inMainThread existed did.
--- @return boolean
--
function CE:InMainThread()
    local fn = rawget(_G, "inMainThread")
    if type(fn) ~= "function" then return true end
    local ok, result = pcall(fn)
    return (not ok) or result == true
end

--
--- ∑ Runs fn on the main thread and answers what pcall would. Touching the
---   LCL from anywhere else is what makes Cheat Engine fall over.
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

--- The monotonic clock the timers measure themselves against. Seconds, as a
--- float, so a sync tick can tell eight milliseconds from eighty.
function CE:Now()
    return os.clock()
end

--------------------------------------------------------
--                    The address list                --
--------------------------------------------------------

--- The address list, or nil when no Cheat Table is loaded and on a build that
--- has no getAddressList at all.
function CE:AddressList()
    return (self:Call("getAddressList"))
end

--
--- ∑ How many records the Cheat Table holds, children included. Zero stands
---   for both an empty table and no table at all, because neither has a
---   record in it.
--- @return number
--
function CE:Count()
    local count = self:Get(self:AddressList(), "Count")
    if type(count) ~= "number" then return 0 end
    return count
end

--- The shared bounds check. A negative index is an access violation rather
--- than a Lua error, so it never reaches Cheat Engine.
local function recordAt(self, al, index, count)
    local number = math.tointeger(tonumber(index))
    if number == nil or number < 0 then return nil end
    if count == nil then count = self:Get(al, "Count") end
    if type(count) ~= "number" or number >= count then return nil end
    return (invoke(self, al, "getMemoryRecord", number))
end

--
--- ∑ One record by its pre-order index, or nil when the index is outside the
---   list. The wrapper belongs to the caller's current operation and to
---   nothing after it.
--- @param index number # Zero based, as Cheat Engine counts.
--- @return userdata|table|nil
--
function CE:RecordAt(index)
    local al = self:AddressList()
    if al == nil then return nil end
    return recordAt(self, al, index)
end

--
--- ∑ Walks the address list in pre-order and hands each record to fn. The
---   address list and the count are resolved once for the whole walk, and the
---   indices go up by one, which is the only order the tree answers quickly
---   in. It caches one node, so jumping about costs a tree walk per record.
---
---   fn returning false stops the walk, and so does fn raising, because a
---   half finished walk is better than an error out of a timer.
--- @param first number|nil # Where to start, zero by default.
--- @param count number|nil # How many at most, the rest of the list by default.
--- @param fn function # fn(record, index), record is valid for that call only.
--- @return number # How many records were handed over.
--
function CE:Walk(first, count, fn)
    if type(fn) ~= "function" then return 0 end
    local al = self:AddressList()
    if al == nil then return 0 end
    local total = self:Get(al, "Count")
    if type(total) ~= "number" or total <= 0 then return 0 end
    local start = math.tointeger(tonumber(first)) or 0
    if start < 0 then start = 0 end
    local wanted = math.tointeger(tonumber(count)) or (total - start)
    local last = math.min(total - 1, start + wanted - 1)
    local visited = 0
    for index = start, last do
        local record = recordAt(self, al, index, total)
        if record == nil then break end
        visited = visited + 1
        local ok, keep = pcall(fn, record, index)
        if not ok or keep == false then break end
    end
    return visited
end

--
--- ∑ One record by its id. This is how everything outside this file resolves
---   a record, because an id survives what a wrapper does not.
--- @param id number
--- @return userdata|table|nil
--
function CE:RecordByID(id)
    if id == nil then return nil end
    local al = self:AddressList()
    if al == nil then return nil end
    return (invoke(self, al, "getMemoryRecordByID", id))
end

--
--- ∑ The id of the record Cheat Engine shows as selected, or nil.
--- @return number|nil
--
function CE:SelectedRecordID()
    local record = self:Get(self:AddressList(), "SelectedRecord")
    if record == nil then return nil end
    local id = self:Get(record, "ID")
    if type(id) ~= "number" then return nil end
    return id
end

--
--- ∑ The ids of every record selected in Cheat Engine, in pre-order. The
---   table Cheat Engine answers with is nothing at all when the selection is
---   empty and is keyed by the pre-order index otherwise, with holes in it, so
---   it is read with pairs and sorted by that key afterwards.
--- @return table # A list of ids, empty when nothing is selected.
--
function CE:SelectedRecordIDs()
    local al = self:AddressList()
    if al == nil then return {} end
    local selected = (invoke(self, al, "getSelectedRecords"))
    if type(selected) ~= "table" then return {} end
    local rows = {}
    for key, record in pairs(selected) do
        local id = self:Get(record, "ID")
        if type(id) == "number" then
            rows[#rows + 1] = { Order = tonumber(key) or 0, ID = id }
        end
    end
    table.sort(rows, function(a, b) return a.Order < b.Order end)
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = row.ID end
    return ids
end

--
--- ∑ Selects exactly that one record in Cheat Engine. An id that no longer
---   resolves is refused, because handing Cheat Engine a record that is gone
---   clears the whole selection instead of raising.
--- @param id number
--- @return boolean
--
function CE:SelectRecord(id)
    local record = self:RecordByID(id)
    if record == nil then return false end
    local al = self:AddressList()
    if al == nil then return false end
    local method = self:Get(al, "setSelectedRecord")
    if type(method) ~= "function" then return false end
    return (pcall(method, record)) == true
end

--
--- ∑ Appends a record at the end of the root. Cheat Engine makes it a four
---   byte record described Plugin Address, and this is the one edit from Lua
---   that marks the Cheat Table as edited. The caller moves it where it
---   belongs and renames it.
--- @return userdata|table|nil
--
function CE:CreateRecord()
    local al = self:AddressList()
    if al == nil then return nil end
    return (invoke(self, al, "createMemoryRecord"))
end

--
--- ∑ Repaints Cheat Engine's own record tree after an edit made from here.
---   The address list has a refresh of its own and it does not reach the tree,
---   so the tree child is asked directly.
--- @return boolean
--
function CE:RepaintList()
    local al = self:AddressList()
    if al == nil then return false end
    local list = self:Get(al, "List")
    if list == nil then return false end
    local repaint = self:Get(list, "repaint")
    if type(repaint) ~= "function" then return false end
    return (pcall(repaint)) == true
end

--
--- ∑ Rebuilds Cheat Engine's description lookup. A bulk rename leaves it
---   holding names nobody has any more, and drop-down links, the value maths
---   that names a record in brackets and getMemoryRecordByDescription all read
---   from it. Called once per commit, never per record.
--- @return boolean
--
function CE:RebuildDescriptionCache()
    local al = self:AddressList()
    if al == nil then return false end
    local method = self:Get(al, "rebuildDescriptionCache")
    if type(method) ~= "function" then return false end
    return (pcall(method)) == true
end

--------------------------------------------------------
--                    The process                     --
--------------------------------------------------------

--- Whether a process is attached. getOpenedProcessID answers zero without one.
function CE:ProcessOpen()
    local pid = self:Call("getOpenedProcessID")
    return type(pid) == "number" and pid ~= 0
end

--
--- ∑ Reads a pointer sized value out of the attached process.
--- @param address number
--- @return number|nil # nil when there is nothing readable there.
--
function CE:ReadPointer(address)
    if type(address) ~= "number" then return nil end
    local value = self:Call("readPointer", address)
    if type(value) ~= "number" then return nil end
    return value
end

--
--- ∑ Turns address text into a number the way Cheat Engine itself does, so a
---   module name, a symbol and an expression all resolve. The safe spelling
---   answers nil rather than raising when nothing resolves.
--- @param text string
--- @return number|nil
--
function CE:AddressOf(text)
    if text == nil or text == "" then return nil end
    local value = self:Call("getAddressSafe", text)
    if type(value) ~= "number" then return nil end
    return value
end

--
--- ∑ Shows an address in the memory view and brings it forward.
--- @param address number
--- @return boolean, string|nil
--
function CE:ShowInMemoryView(address)
    if type(address) ~= "number" then return false, "no address was given" end
    local form = self:Call("getMemoryViewForm")
    if form == nil then return false, "the memory view is not available" end
    local ok, result = self:RunInMain(function()
        local hex = self:Get(form, "HexadecimalView")
        if hex == nil then return false end
        if not pcall(function() hex.Address = address end) then return false end
        pcall(function() form.show() end)
        pcall(function() form.bringToFront() end)
        return true
    end)
    if not ok then return false, tostring(result) end
    if result ~= true then return false, "the memory view has no hexadecimal view" end
    return true
end

--
--- ∑ Checks one section of an Auto Assembler script without running it.
---   Three answers, because not checked and failed are different things and
---   the problems list must not report the first as the second.
--- @param script string
--- @param enable boolean # True checks the ENABLE section.
--- @return boolean|nil, string|nil # True when it assembled, false and Cheat
---         Engine's message when it did not, nil and a reason when the check
---         could not run at all.
--
function CE:AssembleCheck(script, enable)
    if type(script) ~= "string" or script == "" then
        return nil, "there is no script to check"
    end
    local fn = rawget(_G, "autoAssembleCheck")
    if type(fn) ~= "function" then return nil, "autoAssembleCheck is not available" end
    local ok, result, message = pcall(fn, script, enable == true)
    if not ok then return nil, tostring(result) end
    if result == true then return true end
    if type(message) == "string" and message ~= "" then return false, message end
    return false, "Cheat Engine did not say what was wrong."
end

--------------------------------------------------------
--                 Input and dialogs                  --
--------------------------------------------------------

--
--- ∑ Whether a virtual key is held down right now. Mouse handlers arrive
---   without a modifier state, so this is how Ctrl and Shift are read.
--- @param key number
--- @return boolean
--
function CE:IsKeyDown(key)
    if type(key) ~= "number" then return false end
    local fn = rawget(_G, "isKeyPressed")
    if type(fn) ~= "function" then return false end
    local ok, down = pcall(fn, key)
    return ok and down == true
end

function CE:ToClipboard(text)
    local fn = rawget(_G, "writeToClipboard")
    if type(fn) ~= "function" then return false, "writeToClipboard is not available" end
    local ok, err = pcall(fn, tostring(text))
    if not ok then return false, tostring(err) end
    return true
end

--- What is on the clipboard, or nil. An empty clipboard and a missing API are
--- the same answer here, which is that there is nothing to offer.
function CE:FromClipboard()
    local fn = rawget(_G, "readFromClipboard")
    if type(fn) ~= "function" then return nil end
    local ok, text = pcall(fn)
    if not ok or type(text) ~= "string" or text == "" then return nil end
    return text
end

--
--- ∑ Asks before something that cannot be taken back. Without a usable dialog
---   the answer is no, because a missing confirmation must never read as
---   consent, and the refusal is logged so it does not look like a silent
---   button.
--- @param action string # What is about to happen.
--- @param affectedCount number|nil # How many records it touches.
--- @param note string|nil # A consequence worth spelling out under the count.
--- @return boolean, string|nil # True when the user agreed. Otherwise false
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
        report(self, "Refused '" .. tostring(action)
            .. "' because Cheat Engine offers no confirmation dialog here.")
        return false, "the confirmation dialog is not available"
    end
    local text = tostring(action)
    if affectedCount ~= nil then
        text = text .. "\n\nAffected records: " .. tostring(affectedCount)
    end
    if note and note ~= "" then
        text = text .. "\n\n" .. tostring(note)
    end
    text = text .. "\n\nDo you want to continue?"
    local ok, result = self:RunInMain(function()
        return dialog(text, mtConfirmation, mbYes, mbNo)
    end)
    if not ok then return false, "the confirmation dialog failed, " .. tostring(result) end
    return result == mrYes
end

--
--- ∑ Opens Cheat Engine's colour picker on a colour and answers the one the
---   user chose. Colours are BGR on both sides of this call.
--- @param color number|nil # What the dialog opens on.
--- @return number|nil # The chosen colour, or nil on cancel.
--
function CE:PickColor(color)
    local dialog = self:Call("createColorDialog")
    if dialog == nil then return nil end
    local picked = nil
    self:RunInMain(function()
        if type(color) == "number" then
            pcall(function() dialog.Color = color end)
        end
        local execute = self:Get(dialog, "execute")
        if type(execute) ~= "function" then return end
        local ok, chosen = pcall(execute)
        if ok and chosen == true then
            local value = self:Get(dialog, "Color")
            if type(value) == "number" then picked = value end
        end
    end)
    local destroy = self:Get(dialog, "destroy")
    if type(destroy) == "function" then pcall(destroy) end
    return picked
end

--- The fields a save dialog takes, in the order they are set. FileName last,
--- because a dialog that has a default extension applies it to what is
--- already in the name field.
local SAVE_FIELDS = { "Title", "Filter", "DefaultExt", "FileName" }

--
--- ∑ Asks where to write a file.
--- @param options table|nil # Title, Filter, DefaultExt and FileName.
--- @return string|nil # The path, or nil on cancel and without the dialog.
--
function CE:SaveFile(options)
    options = options or {}
    local dialog = self:Call("createSaveDialog")
    if dialog == nil then return nil end
    local path = nil
    self:RunInMain(function()
        for _, key in ipairs(SAVE_FIELDS) do
            local value = options[key]
            if value ~= nil then
                pcall(function() dialog[key] = value end)
            end
        end
        local execute = self:Get(dialog, "execute")
        if type(execute) ~= "function" then return end
        local ok, chosen = pcall(execute)
        if ok and chosen == true then
            local name = self:Get(dialog, "FileName")
            if type(name) == "string" and name ~= "" then path = name end
        end
    end)
    local destroy = self:Get(dialog, "destroy")
    if type(destroy) == "function" then pcall(destroy) end
    return path
end

--
--- ∑ A key combination as text. Cheat Engine spells one the way its own
---   hotkey editor does, and the local names are only there for a build that
---   does not offer that.
--- @param keys table # Virtual key codes, in press order.
--- @return string
--
function CE:KeyComboText(keys)
    if type(keys) ~= "table" then return "" end
    local fn = rawget(_G, "convertKeyComboToString")
    if type(fn) == "function" then
        local ok, text = pcall(fn, keys)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    local parts = {}
    for _, key in ipairs(keys) do
        local number = math.tointeger(tonumber(key))
        if number ~= nil and number ~= 0 then
            parts[#parts + 1] = KEY_NAMES[number] or ("Key " .. number)
        end
    end
    return table.concat(parts, "+")
end

return CE
