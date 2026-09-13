--[[
    Defensive wrappers around the Cheat Engine Lua API.

    Every call maps a Cheat Engine function that can realistically fail onto a
    result of nil plus a reason. Realistically means no process attached, or an
    address that cannot be read, or a memory view that was never opened.
    Nothing here turns a failure into a fake success.

    Globals are looked up at call time and never captured at load time. A test
    can therefore stub the API, and an older Cheat Engine degrades to a logged
    reason instead of raising an error while autorun is still loading.

    Only functions documented in celua.txt are used. Four of them do not do
    what the documentation says they do. Each one cost a live Cheat Engine to
    find out.

    1. getVisibleDisassembler
       The docs mark it deprecated and say it returns a stub. That stub has a
       nil PopupMenu, so nothing reached through it works. Use
       getMemoryViewForm().DisassemblerView for the control instead. The
       context menu belongs to the memory view form itself and is its own
       published TPopupMenu named "debuggerpopup". See celua.txt:3073.

    2. enumModules
       The docs list Name, Address, Is64Bit and PathToFile on every entry.
       There is no size on an entry, so a module range cannot be built from
       the enumeration alone. Ask getModuleSize(name) for the size. See
       celua.txt:153.

    3. splitDisassembledString
       The docs say it returns the address, the bytes, the opcode and the
       extra field, in that order. Cheat Engine 7.5 returns those four values
       in the reverse of that order, extra first and address last:

            print(splitDisassembledString("00403E5E - 5D - pop rbp"))
              -->        pop rbp    5D    00403E5E

       Nothing here calls it. SplitDisassembly parses the line itself.
       Measured on 7.5. See celua.txt:596.

    4. disassembleBytes
       The docs say it takes "hexadecimalbytestring or {bytetable}". On Cheat
       Engine 7.5 only the table form works. The string form reads the first
       byte and then zeroes, whatever the spacing or the case:

            disassembleBytes("488B4C2408", 0x140000000)
              -> 140000000 - 48 00 00  - add [rax],al
            disassembleBytes({0x48,0x8B,0x4C,0x24,0x08}, 0x140000000)
              -> 140000000 - 48 8B 4C 24 08  - mov rcx,[rsp+08]

       Always hand it a table. Never pass a string. Measured on 7.5. See
       celua.txt:601.
]]

local CE = {}
CE.__index = CE

function CE:New()
    return setmetatable({}, CE)
end

function CE:Has(name)
    return type(rawget(_G, name)) == "function"
end

--
--- ∑ Calls a global Cheat Engine function by name inside pcall.
--- @param name string
--- @return any ... # The function's results, or nil and a reason.
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
---   the RTTI fallback raises an error on an object that has been freed, so
---   the read happens inside pcall.
--- @param object userdata|table
--- @param key string
--- @return any
--
function CE:Get(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

--
--- ∑ Writes one property on a Cheat Engine object. Every property in the
---   binding also has a published setter, and which of the two a given build
---   actually accepts is not something a caller can know, so the assignment
---   is tried first and the setter after it. Neither raising is the only
---   thing that can be reported: a binding that quietly ignores a write looks
---   the same from here as one that took it.
--- @param object userdata|table
--- @param key string
--- @param value any
--- @return boolean
--
function CE:Write(object, key, value)
    if object == nil then return false end
    if pcall(function() object[key] = value end) then return true end
    local setter = self:Get(object, "set" .. key)
    if type(setter) == "function" then return (pcall(setter, value)) end
    return false
end

function CE:InMainThread()
    local fn = rawget(_G, "inMainThread")
    if type(fn) ~= "function" then return true end
    local ok, result = pcall(fn)
    return (not ok) or result == true
end

--
--- ∑ Runs fn on the main thread and returns what pcall would.
--- @param fn function
--- @return boolean, any
--
function CE:RunInMain(fn)
    if type(fn) ~= "function" then return false, "expected a function" end
    local sync = rawget(_G, "synchronize")
    if self:InMainThread() or type(sync) ~= "function" then return pcall(fn) end
    local ok, result = false, "synchronize did not run the function"
    local synced, err = pcall(sync, function() ok, result = pcall(fn) end)
    if not synced then return false, tostring(err) end
    return ok, result
end

--------------------------------------------------------
--                    Process and forms               --
--------------------------------------------------------

--- Whether a process is attached. Without one, getOpenedProcessID answers 0.
function CE:ProcessOpen()
    local pid = self:Call("getOpenedProcessID")
    return type(pid) == "number" and pid ~= 0
end

function CE:MemoryView()
    return (self:Call("getMemoryViewForm"))
end

--- The real disassembler control, not the deprecated stub.
function CE:DisassemblerView()
    local form = self:MemoryView()
    if not form then return nil, "the memory view is not available" end
    local view = self:Get(form, "DisassemblerView")
    if not view then return nil, "the memory view has no DisassemblerView" end
    return view
end

--
--- ∑ The address selected in the disassembler.
--- @return number|nil, string|nil
--
function CE:SelectedAddress()
    local view, reason = self:DisassemblerView()
    if not view then return nil, reason end
    local address = self:Get(view, "SelectedAddress")
    if type(address) ~= "number" or address == 0 then
        return nil, "no address is selected in the disassembler"
    end
    return address
end

--
--- ∑ The disassembler's context menu. It belongs to the memory view form and
---   not to the disassembler control, and it is reached by its published name.
--- @return userdata|nil, string|nil
--
function CE:DisassemblerPopup()
    local form = self:MemoryView()
    if not form then return nil, "the memory view is not available" end
    local menu = self:Get(form, "debuggerpopup")
    if menu == nil then
        local ok, found = pcall(function() return form.findComponentByName("debuggerpopup") end)
        if ok then menu = found end
    end
    if menu == nil then return nil, "the memory view has no 'debuggerpopup' component" end
    return menu
end

--------------------------------------------------------
--                       Disassembly                  --
--------------------------------------------------------

--
--- ∑ Splits a Cheat Engine disassembly line into its parts and counts the
---   bytes it consumed, which is the instruction length.
--- @param text string # "address - bytes - opcode : extra"
--- @return table|nil # { Size, Opcode, Extra, Bytes }
--
local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function CE:SplitDisassembly(text)
    if type(text) ~= "string" or text == "" then return nil end
    -- Handed several instructions' worth of bytes, Cheat Engine answers with
    -- one line each. Only the first one is ours.
    text = text:match("^[^\r\n]*") or text

    -- The line is parsed here rather than through splitDisassembledString.
    -- That function returns its four values in the reverse of the documented
    -- order. celua.txt:596 says "the address, bytes, opcode and extra field".
    -- Cheat Engine 7.5 actually returns extra, opcode, bytes, address:
    --
    --     print(splitDisassembledString("00403E5E - 5D - pop rbp"))
    --       -->        pop rbp    5D    00403E5E
    --
    -- Reading it as documented put the opcode text where the bytes belong. On
    -- a long instruction that went unnoticed, because the opcode text happens
    -- to contain hex pairs of its own, "ea" in lea and "08" in [rsp+08], so
    -- the count of bytes still came out above zero. On "pop rbp" there are no
    -- such pairs. The count was zero and the whole line was rejected as
    -- undisassemblable.
    --
    -- The format is "address - bytes - opcode : extra", and the extra field is
    -- optional. The two " - " separators are structural. A displacement is
    -- written "[rbp-20]" with no spaces around the sign, so the two cannot be
    -- confused.
    local address, byteText, rest = text:match("^(.-)%s+%-%s+(.-)%s+%-%s+(.*)$")
    if not byteText then return nil end
    local opcode, extra = rest:match("^(.-)%s+:%s+(.*)$")
    if not opcode then opcode, extra = rest, "" end

    local size = 0
    for _ in byteText:gmatch("%x%x") do size = size + 1 end
    if size == 0 then return nil end
    return { Size = size, Opcode = trim(opcode), Extra = trim(extra),
             Bytes = trim(byteText), Address = trim(address) }
end

--
--- ∑ Disassembles a live address.
--- @param address number
--- @return table|nil, string|nil
--
function CE:Disassemble(address)
    local text = self:Call("disassemble", address)
    local parsed = self:SplitDisassembly(text)
    if not parsed then return nil, "could not disassemble " .. string.format("%X", address) end
    return parsed
end

--
--- ∑ Disassembles a byte table as if it sat at the given address. This is the
---   probe the mask policy is built on. The same bytes with one byte changed
---   tell us whether that byte carries an operand or the shape of the
---   instruction.
---
---   The buffer is padded, because a disassembler needs room to look ahead. A
---   one byte instruction handed over on its own, "5D" for pop rbp, is not
---   enough for Cheat Engine to answer at all. The padding is nop. It sits
---   after a complete instruction, so it cannot change how that instruction
---   decodes, and it is identical for the base and for every probe.
--- @param bytes table
--- @param address number
--- @param pad number|nil # Minimum buffer length, 16 by default.
--- @return table|nil
--
function CE:DisassembleBytes(bytes, address, pad)
    local buffer = {}
    for index = 1, #bytes do buffer[index] = bytes[index] end
    for index = #buffer + 1, (pad or 16) do buffer[index] = 0x90 end
    -- The table form, never the string form. See the header.
    local text = self:Call("disassembleBytes", buffer, address)
    return self:SplitDisassembly(text)
end

--
--- ∑ The instruction length at an address. Cheat Engine's own answer is
---   preferred, and the disassembly it came from is the fallback.
--- @param address number
--- @return number|nil
--
function CE:InstructionSize(address)
    local size = self:Call("getInstructionSize", address)
    if type(size) == "number" and size > 0 then return size end
    local parsed = self:Disassemble(address)
    return parsed and parsed.Size or nil
end

--
--- ∑ Reads bytes as a table.
--- @param address number
--- @param count number
--- @return table|nil, string|nil
--
function CE:ReadBytes(address, count)
    local bytes = self:Call("readBytes", address, count, true)
    if type(bytes) ~= "table" or #bytes < count then
        return nil, string.format("could not read %d byte(s) at %X", count, address)
    end
    return bytes
end

--------------------------------------------------------
--                        Modules                     --
--------------------------------------------------------

--
--- ∑ The module containing an address, with its base and its size. The size
---   comes from getModuleSize, because an enumModules entry does not carry
---   one.
--- @param address number
--- @return table|nil # { Name, Base, Size }
--
function CE:ModuleAt(address)
    local modules = self:Call("enumModules")
    if type(modules) ~= "table" then return nil end
    local best = nil
    for _, entry in ipairs(modules) do
        local base = self:Get(entry, "Address")
        local name = self:Get(entry, "Name")
        if type(base) == "number" and type(name) == "string" and address >= base then
            local size = self:Call("getModuleSize", name)
            if type(size) == "number" and size > 0 and address < base + size then
                -- Keep the highest base that still contains the address, so a
                -- module mapped inside another one's range wins.
                if not best or base > best.Base then
                    best = { Name = name, Base = base, Size = size }
                end
            end
        end
    end
    return best
end

--------------------------------------------------------
--                        Scanning                    --
--------------------------------------------------------

--
--- ∑ Runs an array of bytes scan and hands back the addresses that matched.
---   AOBScan returns a StringList of every result (celua.txt:543), which is
---   the only documented way to see more than one hit. AOBScanUnique returns
---   the first one "at random" and verifies nothing. The list has to be
---   destroyed afterwards.
---
---   Both halves of this tool scan. Making a signature only ever asks whether
---   there is more than one hit, and finding one wants the hits themselves,
---   so the limit is what separates the two.
--- @param pattern string # "48 8B ?? ?? ??"
--- @param options table|nil # { Protection = "+X", Range = { Base, Size },
---        Limit = how many addresses to collect at most }
--- @return table|nil, string|nil # { Addresses, Count, Total, Truncated },
---         where Total is what the scanner found before the range and the
---         limit were applied.
--
function CE:ScanMatches(pattern, options)
    options = options or {}
    if not self:Has("AOBScan") then return nil, "AOBScan is not available" end
    local list = self:Call("AOBScan", pattern, options.Protection)
    -- Cheat Engine hands back nil, not an empty list, when nothing matched.
    -- Reporting that as a missing API told the user the scanner was broken
    -- when it had simply found nothing.
    if not list then return { Addresses = {}, Count = 0, Total = 0, Truncated = false } end
    local range, limit = options.Range, options.Limit
    local addresses, truncated, found = {}, false, 0
    local ok, err = pcall(function()
        local total = tonumber(list.Count) or 0
        found = total
        for index = 0, total - 1 do
            local address = tonumber(list[index], 16)
            if address and (not range
                or (address >= range.Base and address < range.Base + range.Size)) then
                if limit and #addresses >= limit then
                    truncated = true
                    return
                end
                addresses[#addresses + 1] = address
            end
        end
    end)
    pcall(function() list.destroy() end)
    if not ok then return nil, tostring(err) end
    return { Addresses = addresses, Count = #addresses, Total = found, Truncated = truncated }
end

--
--- ∑ Counts matches, stopping once stopAt of them have been seen. The
---   signature loop asks this thousands of times, so it never asks for more
---   than the two hits it needs to tell unique from not unique apart.
--- @param pattern string # "48 8B ? ? ?"
--- @param range table|nil # { Base, Size } to count only hits inside a module.
--- @param stopAt number|nil # Stop counting once this many are found.
--- @param protection string|nil # "+X" for executable memory only.
--- @return number|nil, string|nil
--
function CE:CountMatches(pattern, range, stopAt, protection)
    local result, reason = self:ScanMatches(pattern,
        { Protection = protection, Range = range, Limit = stopAt })
    if not result then return nil, reason end
    return result.Count
end

--------------------------------------------------------
--                    Going somewhere                 --
--------------------------------------------------------

--
--- ∑ How Cheat Engine writes an address: a symbol, a module plus an offset,
---   or the bare hexadecimal when it is neither.
--- @param address number
--- @return string
--
function CE:AddressName(address)
    local name = self:Call("getNameFromAddress", address)
    if type(name) == "string" and name ~= "" then return name end
    return string.format("%X", address)
end

--
--- ∑ An address out of whatever was given: a number, "14D762ED9",
---   "0x14D762ED9" or "game.exe+1A2B". getAddressSafe is the documented
---   resolver that answers nil instead of raising (celua.txt:180), and plain
---   hexadecimal is read here, because a string of digits is not a symbol and
---   asking the symbol handler about it is a slower way to the same answer.
--- @param value number|string
--- @return number|nil, string|nil
--
function CE:Resolve(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" or value == "" then return nil, "no address was given" end
    local text = (value:gsub("^%s+", ""):gsub("%s+$", ""))
    local plain = tonumber((text:gsub("^0[xX]", "")), 16)
    if plain then return plain end
    local resolved = self:Call("getAddressSafe", text)
    if type(resolved) == "number" and resolved ~= 0 then return resolved end
    return nil, string.format("'%s' is not an address", tostring(value))
end

--
--- ∑ Brings the memory view up on an address. The disassembler is scrolled
---   and its selection moved, and the hex view is pointed at the same place,
---   so the bytes are readable whether the address holds code or data.
---
---   Every step past the form itself is optional. A build whose hex view will
---   not take a selection still gets the jump; it just does not get the
---   highlight.
--- @param address number
--- @param length number|nil # How many bytes to select in the hex view.
--- @return boolean, string|nil
--
function CE:ShowAddress(address, length)
    if type(address) ~= "number" then return false, "no address was given" end
    local form = self:MemoryView()
    if not form then return false, "the memory view is not available" end
    local ok, result = self:RunInMain(function()
        pcall(function() form.show() end)
        pcall(function() form.bringToFront() end)
        local view = self:Get(form, "DisassemblerView")
        if view then
            -- TopAddress first. It decides what is on screen, and setting it
            -- afterwards would scroll the selection back out of sight.
            self:Write(view, "TopAddress", address)
            self:Write(view, "SelectedAddress", address)
        end
        local hex = self:Get(form, "HexadecimalView")
        if hex then
            self:Write(hex, "Address", address)
            if type(length) == "number" and length > 0 then
                self:Write(hex, "SelectionStart", address)
                self:Write(hex, "SelectionStop", address + length - 1)
            end
        end
        return view ~= nil or hex ~= nil
    end)
    if not ok then return false, tostring(result) end
    if result ~= true then
        return false, "the memory view has neither a disassembler nor a hex view"
    end
    return true
end

--
--- ∑ The memory view's own menu bar. It is where a menu item can carry a
---   keyboard shortcut: a shortcut is dispatched by the focused form through
---   its main menu, and an item sitting in a popup menu never sees the key.
--- @return userdata|nil, string|nil
--
function CE:MemoryViewMenu()
    local form = self:MemoryView()
    if not form then return nil, "the memory view is not available" end
    local menu = self:Get(form, "Menu")
    if menu == nil then
        local getter = self:Get(form, "getMenu")
        if type(getter) == "function" then
            local ok, found = pcall(getter)
            if ok then menu = found end
        end
    end
    if menu == nil then return nil, "the memory view has no menu bar" end
    return menu
end

--------------------------------------------------------
--                        Dialogs                     --
--------------------------------------------------------

--
--- ∑ Asks for one line of text.
--- @param caption string
--- @param prompt string
--- @param default string|nil
--- @return string|nil, string|nil # The text, nil when the user cancelled,
---         and a reason when the dialog itself was not there.
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
--- ∑ Shows a list and answers which line was picked.
---
---   celua.txt:347 documents showSelectionList(title, caption, stringlist,
---   allowCustomInput, formname) as returning the line number, counted from
---   zero, and the string. The line number is -1 when the user typed
---   something of their own instead of picking, which cannot happen here
---   because custom input is not offered, and a cancel answers nothing at
---   all. Both are read as "no choice was made".
--- @param title string
--- @param caption string
--- @param lines table # The lines, in the order they are to be shown.
--- @return number|nil, string|nil # The 1 based index, or nil and a reason
---         when the dialog was not available.
--
function CE:Select(title, caption, lines)
    local show = rawget(_G, "showSelectionList")
    if type(show) ~= "function" then return nil, "showSelectionList is not available" end
    local make = rawget(_G, "createStringlist")
    if type(make) ~= "function" then return nil, "createStringlist is not available" end
    local ok, result = self:RunInMain(function()
        local list = make()
        if list == nil then return nil end
        for _, line in ipairs(lines or {}) do
            pcall(function() list.add(tostring(line)) end)
        end
        local index = show(title, caption, list, false)
        pcall(function() list.destroy() end)
        return index
    end)
    if not ok then return nil, tostring(result) end
    local index = tonumber(result)
    if index == nil or index < 0 then return nil end
    return index + 1
end

--------------------------------------------------------
--                       Clipboard                    --
--------------------------------------------------------

function CE:Clipboard(text)
    local fn = rawget(_G, "writeToClipboard")
    if type(fn) ~= "function" then return false, "writeToClipboard is not available" end
    local ok, err = pcall(fn, text)
    if not ok then return false, tostring(err) end
    return true
end

--- What is on the clipboard, or nil. An empty clipboard and a missing API
--- are the same answer here: there is nothing to offer.
function CE:ClipboardText()
    local fn = rawget(_G, "readFromClipboard")
    if type(fn) ~= "function" then return nil end
    local ok, text = pcall(fn)
    if not ok or type(text) ~= "string" or text == "" then return nil end
    return text
end

return CE
