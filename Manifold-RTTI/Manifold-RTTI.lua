--[[
    Manifold-RTTI.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 1.0.0
    LICENSE : MIT
    CREATED : 2026-11-15
    UPDATED : 2026-11-17

    MIT License:
        Copyright (c) 2026 Leunsel

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

    This file is part of the Manifold CE system.

    C++ class names for Cheat Engine, read from the game's own run-time type
    information. Every object of a C++ class with virtual functions starts
    with a pointer to its class's virtual function table. In programs built
    with MSVC or clang-cl, with RTTI switched on (the compiler's default), the
    slot in front of that table leads to the class's name and to the list of
    its base classes. This script reads that information in the running game.

    What it adds to Cheat Engine:
        - Structure Dissect names a new structure after the object's class,
          and an address that points at a base class part of an object moves
          to the object's start. Expanding a pointer names the child
          structure the same way.
        - After Cheat Engine's own guess, the object's virtual function table
          pointers are labelled, and pointer fields are named after the class
          they point to (Game::Weapon*).
        - Symbols <Class>::vftable. They resolve on demand in every session,
          so a table can find a class's objects again after a game update.
        - An "RTTI" menu: who owns an address, find every object of a class,
          dissect an object.
        - getRTTIClassName(address) where the host does not have it, and
          ManifoldRTTI, a Lua API for tables and the Lua console.

    Everything here only reads the game. Nothing is injected, hooked or called
    inside the target.

    Supported: 64-bit and 32-bit programs built with MSVC or clang-cl. Unreal
    Engine builds switch RTTI off by default and GCC builds use another
    format; in those games the script finds nothing and stays out of the way.
]]

----------------------------------------
-- CONFIG
----------------------------------------
local RUNTIME_STATE_KEY = "__MANIFOLD_RTTI_RUNTIME__"
local LOG_PREFIX        = "Manifold-RTTI"
local VERSION           = "1.0.0"
local MENU_CAPTION      = "RTTI"

-- ∑ "Who owns this address" walks back from the address to the closest
-- virtual function table pointer. Objects are pointer aligned and almost
-- every value on the way is rejected by one binary search over the module
-- list, so the window can be generous.
local OWNER_WINDOW = 0x4000

-- ∑ How much the dissect override lets Cheat Engine guess before it labels
-- the result. It is Cheat Engine's default structure size.
local GUESS_SIZE = 0x1000

local INSTANCE_LIMIT  = 100000
local NAME_LIMIT      = 2048
local MAX_BASES       = 512
local MAX_VIRTUALS    = 2048
local IMAGE_RELOAD_MS = 2000
local CACHE_LIMIT     = 250000

-- ∑ Every class the script meets gets a <Class>::vftable symbol, so the
-- disassembler, the memory view and pointer values show the class name.
local REGISTER_SYMBOLS = true

local VT = {
    Byte    = rawget(_G, "vtByte") or 0,
    Dword   = rawget(_G, "vtDword") or 2,
    Qword   = rawget(_G, "vtQword") or 3,
    Bytes   = rawget(_G, "vtByteArray") or 8,
    Pointer = rawget(_G, "vtPointer") or 12,
}
local SL_FAILURE      = rawget(_G, "slFailure") or 5
local SO_EXACT        = rawget(_G, "soExactValue") or 1
local RT_ROUNDED      = rawget(_G, "rtRounded") or 0
local FSM_ALIGNED     = rawget(_G, "fsmAligned") or 1
local FSM_NOT_ALIGNED = rawget(_G, "fsmNotAligned") or 0

-- ∑ Runtime handles live outside this chunk, so executing the file again
-- (from the Lua engine, or a second autorun copy) releases what the previous
-- run registered instead of stacking menus, callbacks and symbols.
local State = rawget(_G, RUNTIME_STATE_KEY)
if type(State) ~= "table" then
    State = {}
    _G[RUNTIME_STATE_KEY] = State
end
State.Symbols = State.Symbols or {}

ManifoldRTTI = {}
local RTTI = ManifoldRTTI

----------------------------------------
-- LOGGING
----------------------------------------

local function Log(tag, msg)
    local t = os.date("%H:%M:%S") or "??:??:??"
    print(string.format("[%s] [%s] [%s] %s", t, LOG_PREFIX, tostring(tag), tostring(msg)))
end

local function Hex(value)
    return value and string.format("%X", value) or "nil"
end

----------------------------------------
-- MEMORY
----------------------------------------

local S

-- ∑ readInteger is unsigned in Cheat Engine and signed in some hosts; the
-- RTTI fields are unsigned offsets and image-relative addresses.
local function RU(address)
    if not address or address <= 0 then return nil end
    local value = readInteger(address)
    if value and value < 0 then value = value + 0x100000000 end
    return value
end

local function RI(address)
    local value = RU(address)
    if value and value >= 0x80000000 then value = value - 0x100000000 end
    return value
end

local function RP(address)
    if not address or address <= 0 then return nil end
    local value = readPointer(address)
    if not value or value == 0 then return nil end
    return value
end

--
--- ∑ Raw bytes as a Lua string. readBytes hands out a table; turning it
--- into a string once and decoding with string.unpack is far cheaper than a
--- readPointer call per value, which costs a ReadProcessMemory each.
--
local function ReadRaw(address, size)
    if not address or size <= 0 then return nil end
    local bytes = readBytes(address, size, true)
    if type(bytes) ~= "table" or #bytes < size then return nil end
    local parts = {}
    for i = 1, size, 4096 do
        parts[#parts + 1] = string.char(table.unpack(bytes, i, math.min(i + 4095, size)))
    end
    return table.concat(parts)
end

local function LittleEndian(value, size)
    local parts = {}
    for i = 0, size - 1 do parts[#parts + 1] = string.format("%02X", (value >> (i * 8)) & 0xFF) end
    return table.concat(parts, " ")
end

local function TextBytes(text)
    local parts = {}
    for i = 1, #text do parts[i] = string.format("%02X", text:byte(i)) end
    return table.concat(parts, " ")
end

local function ToAddress(value)
    if math.type(value) == "integer" then return value end
    if type(value) == "number" then return math.floor(value) end
    if type(value) ~= "string" or value == "" then return nil end
    local ok, address = pcall(getAddressSafe, value)
    if ok and type(address) == "number" and address ~= 0 then return math.floor(address) end
    return nil
end

--
--- ∑ A byte pattern search inside one address range. createMemScan takes a
--- start and a stop address in every host, AOBScan does not, and the class
--- lookups only ever need the range of one module.
--
local function ScanBytes(pattern, from, to, align, protection, limit)
    local found = {}
    if type(createMemScan) ~= "function" or type(createFoundList) ~= "function" then return found end
    local ok, err = pcall(function()
        local scan = createMemScan()
        local aligned = align and align > 1
        scan.firstScan(SO_EXACT, VT.Bytes, RT_ROUNDED, pattern, "", from, to, protection or "*W*X*C",
            aligned and FSM_ALIGNED or FSM_NOT_ALIGNED, aligned and string.format("%X", align) or "1",
            true, true, false, false)
        scan.waitTillDone()
        local list = createFoundList(scan)
        list.initialize()
        local count = list.Count or 0
        for i = 0, count - 1 do
            local address = tonumber(list.Address[i], 16)
            if address and (not aligned or address % align == 0) then
                found[#found + 1] = address
                if limit and #found >= limit then break end
            end
        end
        pcall(function() list.deinitialize() end)
        pcall(function() list.destroy() end)
        pcall(function() scan.destroy() end)
    end)
    if not ok then Log("Scan", err) end
    return found
end

----------------------------------------
-- SESSION
----------------------------------------

-- ∑ Everything learned about one process. A different process id starts a
-- new session, so attaching to another game never reuses stale addresses,
-- and the symbols registered for the old one are taken back.
local function OpenedProcess()
    local ok, pid = pcall(getOpenedProcessID)
    return ok and pid or 0
end

local function ForgetSymbols()
    if type(unregisterSymbol) == "function" then
        for name in pairs(State.Symbols) do pcall(unregisterSymbol, name) end
    end
    State.Symbols = {}
end

local function LoadImages()
    local list, main = {}, nil
    local windows = (os.getenv("SystemRoot") or "C:\\Windows"):lower()
    local ok, modules = pcall(enumModules)
    for _, m in ipairs(ok and type(modules) == "table" and modules or {}) do
        local size = m.Size
        if not size or size == 0 then
            local fine, value = pcall(getModuleSize, m.Name)
            size = fine and value or 0
        end
        if m.Address and size and size > 0 then
            local path = m.PathToFile or ""
            local entry = {
                name = m.Name or "", path = path, from = m.Address, to = m.Address + size,
                system = path:lower():sub(1, #windows) == windows,
            }
            list[#list + 1] = entry
            main = main or entry
        end
    end
    table.sort(list, function(a, b) return a.from < b.from end)
    S.images, S.main, S.imagesAt = list, main, getTickCount()
    -- ∑ A module that loaded since may hold a class that was missing, and a
    -- value that pointed nowhere may point into it now.
    S.vts, S.cached, S.classMiss = {}, 0, {}
end

local function Session()
    local pid = OpenedProcess()
    if not S or S.pid ~= pid then
        if S then ForgetSymbols() end
        local fine, is64 = pcall(targetIs64Bit)
        local x64 = not fine or is64 ~= false
        S = {
            pid = pid, x64 = x64, ptr = x64 and 8 or 4, fmt = x64 and "<I8" or "<I4",
            images = {}, imagesAt = 0, cols = {}, tds = {}, vts = {}, cached = 0,
            classes = {}, classMiss = {},
        }
        if pid ~= 0 then LoadImages() end
    end
    return S
end

local function FindImage(address)
    local list = S.images
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = (lo + hi) // 2
        local image = list[mid]
        if address < image.from then hi = mid - 1
        elseif address >= image.to then lo = mid + 1
        else return image end
    end
    return nil
end

--
--- ∑ The module list is loaded once per session. A miss on a direct lookup
--- reloads it, at most every IMAGE_RELOAD_MS, so a DLL that loaded later is
--- found; the walks pass quick and never reload.
--
local function ImageOf(address, quick)
    if not address then return nil end
    local image = FindImage(address)
    if image or quick then return image end
    if getTickCount() - S.imagesAt < IMAGE_RELOAD_MS then return nil end
    LoadImages()
    return FindImage(address)
end

local function ModuleOffset(address)
    local image = address and FindImage(address)
    if not image then return Hex(address) end
    return string.format("%s+%X", image.name, address - image.from)
end

----------------------------------------
-- NAMES
----------------------------------------

-- ∑ MSVC stores a class's name decorated: ".?AVPlayer@Game@@" is the class
-- Game::Player. This is the part of the Microsoft name decoding that type
-- names use: nested scopes, templates with their arguments, back
-- references, anonymous namespaces, lambdas inside functions, pointers,
-- references and function types. A name it cannot read keeps its decorated
-- form, which is still unique and still searchable.

local PRIMITIVES = {
    C = "signed char", D = "char", E = "unsigned char", F = "short", G = "unsigned short",
    H = "int", I = "unsigned int", J = "long", K = "unsigned long", M = "float",
    N = "double", O = "long double", X = "void",
}
local EXTENDED = {
    N = "bool", J = "__int64", K = "unsigned __int64", W = "wchar_t", S = "char16_t",
    U = "char32_t", Q = "char8_t", D = "__int8", E = "unsigned __int8", F = "__int16",
    G = "unsigned __int16", H = "__int32", I = "unsigned __int32", L = "__int128",
    M = "unsigned __int128",
}
local QUALIFIERS = { A = "", B = "const", C = "volatile", D = "const volatile" }
local CONVENTIONS = {
    A = true, B = true, C = true, D = true, E = true, F = true, G = true, H = true,
    I = true, J = true, M = true, N = true, Q = true, S = true, U = true, W = true,
}

local function Fail(why) error("demangle: " .. why, 0) end

local function Peek(p, n) return p.s:sub(p.i, p.i + (n or 1) - 1) end

local function Take(p, n)
    n = n or 1
    local text = p.s:sub(p.i, p.i + n - 1)
    if #text < n then Fail("unexpected end") end
    p.i = p.i + n
    return text
end

local function Skip(p, text)
    if p.s:sub(p.i, p.i + #text - 1) == text then
        p.i = p.i + #text
        return true
    end
    return false
end

-- ∑ The ten name back references. An anonymous namespace is remembered by
-- its key, so two different ones keep different slots, and shown as what it is.
local function Memorize(p, key, text)
    local names = p.names
    if #names >= 10 then return end
    for _, entry in ipairs(names) do
        if entry.key == key then return end
    end
    names[#names + 1] = { key = key, text = text }
end

local function Identifier(p)
    local stop = p.s:find("@", p.i, true)
    if not stop or stop == p.i then Fail("identifier") end
    local text = p.s:sub(p.i, stop - 1)
    p.i = stop + 1
    return text
end

-- 0-9 stand for 1-10; anything else is hex written with A-P and ends with @.
local function EncodedNumber(p)
    local negative = Skip(p, "?")
    local c = Take(p)
    local value
    if c:find("^%d$") then
        value = tonumber(c) + 1
    else
        value = 0
        while c ~= "@" do
            local digit = c:byte() - 65
            if digit < 0 or digit > 15 then Fail("number") end
            value = value * 16 + digit
            c = Take(p)
        end
    end
    return negative and -value or value
end

local QualifiedName, Type, FunctionType, TemplateArguments

local function IsLocalScope(p)
    if Peek(p) ~= "?" then return false end
    local rest = p.s:sub(p.i + 1, p.i + 24)
    return rest:find("^%d%?") ~= nil or rest:find("^@%?") ~= nil or rest:find("^[B-P][A-P]*@%?") ~= nil
end

-- A function inside a decorated name: the scope of a local class or lambda.
local function FunctionSymbol(p)
    if not Skip(p, "?") then Fail("symbol") end
    local name = QualifiedName(p)
    local code = Take(p)
    if code == "Y" or code == "Z" then
        FunctionType(p)
    elseif code:find("^[ABEFIJMNQRUV]$") then
        Skip(p, "E")
        if not QUALIFIERS[Take(p)] then Fail("this qualifier") end
        FunctionType(p)
    elseif code:find("^[CDKLST]$") then
        FunctionType(p)
    else
        Fail("symbol kind " .. code)
    end
    return name .. "()"
end

local function Fragment(p)
    local c = Peek(p)
    if c:find("^%d$") then
        p.i = p.i + 1
        local entry = p.names[tonumber(c) + 1]
        if not entry then Fail("name back reference") end
        return entry.text
    end
    if Skip(p, "?$") then
        -- ∑ A template's arguments have back references of their own; the
        -- finished instantiation is remembered in the outer list.
        local outerNames, outerParams = p.names, p.params
        p.names, p.params = {}, {}
        local name = Identifier(p)
        Memorize(p, name, name)
        local arguments = TemplateArguments(p)
        p.names, p.params = outerNames, outerParams
        local text = name .. "<" .. arguments .. ">"
        Memorize(p, text, text)
        return text
    end
    if Peek(p, 2) == "?A" then
        p.i = p.i + 1
        local key = Identifier(p)
        Memorize(p, key, "`anonymous namespace'")
        return "`anonymous namespace'"
    end
    if IsLocalScope(p) then
        p.i = p.i + 1
        EncodedNumber(p)
        if not Skip(p, "?") then Fail("local scope") end
        return FunctionSymbol(p)
    end
    if c == "?" then Fail("special name") end
    local name = Identifier(p)
    Memorize(p, name, name)
    return name
end

function QualifiedName(p)
    local parts = {}
    while not Skip(p, "@") do
        if p.i > #p.s then Fail("unterminated name") end
        parts[#parts + 1] = Fragment(p)
        if #parts > 64 then Fail("name depth") end
    end
    if #parts == 0 then Fail("empty name") end
    local ordered = {}
    for i = #parts, 1, -1 do ordered[#ordered + 1] = parts[i] end
    return table.concat(ordered, "::")
end

function TemplateArguments(p)
    local list = {}
    while not Skip(p, "@") do
        if p.i > #p.s then Fail("unterminated template") end
        if Skip(p, "$$V") or Skip(p, "$$Z") then
            -- An empty parameter pack, or the end of one.
        elseif Skip(p, "$0") then
            list[#list + 1] = tostring(EncodedNumber(p))
        elseif Peek(p) == "$" and Peek(p, 2) ~= "$$" then
            Fail("template argument " .. Peek(p, 2))
        else
            list[#list + 1] = Type(p)
        end
        if #list > 64 then Fail("template size") end
    end
    return table.concat(list, ", ")
end

local function Qualified(cv, text)
    if cv == "" then return text end
    return cv .. " " .. text
end

local function Indirection(p, kind, sigil)
    if Skip(p, "6") then return FunctionType(p, sigil) end
    if Peek(p) == "8" then Fail("member pointer") end
    while Skip(p, "E") or Skip(p, "I") or Skip(p, "F") do end
    local cv = QUALIFIERS[Take(p)]
    if not cv then Fail("qualifier") end
    local text = Qualified(cv, Type(p)) .. sigil
    if kind == "Q" then text = text .. " const"
    elseif kind == "R" then text = text .. " volatile"
    elseif kind == "S" then text = text .. " const volatile" end
    return text
end

function Type(p)
    local c = Take(p)
    local primitive = PRIMITIVES[c]
    if primitive then return primitive end
    if c == "_" then
        local extended = EXTENDED[Take(p)]
        if not extended then Fail("extended type") end
        return extended
    end
    if c == "V" or c == "U" or c == "T" then return QualifiedName(p) end
    if c == "W" then
        Take(p)
        return QualifiedName(p)
    end
    if c == "P" or c == "Q" or c == "R" or c == "S" then return Indirection(p, c, "*") end
    if c == "A" or c == "B" then return Indirection(p, c, "&") end
    if c == "$" then
        if Skip(p, "$Q") or Skip(p, "$R") then return Indirection(p, "A", "&&") end
        if Skip(p, "$C") then
            local cv = QUALIFIERS[Take(p)]
            if not cv then Fail("qualifier") end
            return Qualified(cv, Type(p))
        end
        if Skip(p, "$T") then return "std::nullptr_t" end
        if Skip(p, "$A6") then return FunctionType(p) end
        Fail("type $" .. Peek(p, 2))
    end
    if c:find("^%d$") then
        local text = p.params[tonumber(c) + 1]
        if not text then Fail("type back reference") end
        return text
    end
    Fail("type " .. c)
end

function FunctionType(p, sigil)
    if not CONVENTIONS[Take(p)] then Fail("calling convention") end
    if Skip(p, "?") then Take(p) end
    local result = Skip(p, "@") and "" or Type(p)
    local parameters = {}
    if not Skip(p, "X") then
        while true do
            if Skip(p, "@") then break end
            if Skip(p, "Z") then
                parameters[#parameters + 1] = "..."
                break
            end
            if p.i > #p.s then Fail("unterminated parameters") end
            local from = p.i
            local text = Type(p)
            if p.i - from > 1 and #p.params < 10 then p.params[#p.params + 1] = text end
            parameters[#parameters + 1] = text
        end
    end
    Skip(p, "_E")
    if not Skip(p, "Z") then Fail("exception specification") end
    local list = table.concat(parameters, ", ")
    if sigil then return result .. " (" .. sigil .. ")(" .. list .. ")" end
    return result .. " (" .. list .. ")"
end

local Demangled = {}

local function Demangle(decorated)
    if type(decorated) ~= "string" then return nil end
    local cached = Demangled[decorated]
    if cached then return cached end
    local text = decorated
    if decorated:sub(1, 3) == ".?A" then
        local p = { s = decorated, i = 4, names = {}, params = {} }
        local ok, result = pcall(function()
            local kind = Take(p)
            if kind == "W" then
                Take(p)
            elseif kind ~= "V" and kind ~= "U" and kind ~= "T" then
                Fail("kind " .. kind)
            end
            local name = QualifiedName(p)
            if p.i <= #p.s then Fail("trailing text") end
            return name
        end)
        if ok then
            text = result
        elseif not tostring(result):find("^demangle: ") then
            Log("Names", decorated .. ": " .. tostring(result))
        end
    end
    Demangled[decorated] = text
    return text
end

-- Game::Player -> .?AVPlayer@Game@@ and .?AUPlayer@Game@@ (class or struct).
local function Mangle(name)
    if name:sub(1, 3) == ".?A" then return { name } end
    if name:find("[^%w_:]") or name:find(":::") then return nil end
    local parts = {}
    for part in name:gmatch("[^:]+") do table.insert(parts, 1, part) end
    if #parts == 0 then return nil end
    local seen, out, count = {}, {}, 0
    for _, part in ipairs(parts) do
        if seen[part] then
            out[#out + 1] = tostring(seen[part])
        else
            if count < 10 then seen[part] = count end
            count = count + 1
            out[#out + 1] = part .. "@"
        end
    end
    local body = table.concat(out) .. "@"
    return { ".?AV" .. body, ".?AU" .. body }
end

----------------------------------------
-- CLASSES
----------------------------------------

local function TypeName(td)
    local cached = S.tds[td]
    if cached ~= nil then return cached or nil end
    local name = readString(td + 2 * S.ptr, NAME_LIMIT)
    if type(name) ~= "string" or name:sub(1, 3) ~= ".?A" or name:find("[%c ]") then name = false end
    S.tds[td] = name
    return name or nil
end

-- ∑ 64-bit RTTI stores image-relative addresses, 32-bit RTTI absolute ones.
local function Absolute(image, ref)
    if S.x64 then return image.from + ref end
    return ref
end

local function ClassRecord(name)
    local record = S.classes[name]
    if not record then
        record = { name = name, vtables = {} }
        S.classes[name] = record
    end
    return record
end

--
--- ∑ The complete object locator in front of a virtual function table. Its
--- checks are what keeps random data from becoming a class: the signature,
--- on 64-bit the locator's own image-relative address, a type descriptor
--- whose name is a decorated class name, and a hierarchy descriptor with a
--- sane base count. A value that passes all of them is RTTI.
--
local function ReadCOL(col)
    local cached = S.cols[col]
    if cached ~= nil then return cached or nil end
    S.cols[col] = false
    local image = FindImage(col)
    if not image or col % 4 ~= 0 then return nil end
    if RU(col) ~= (S.x64 and 1 or 0) then return nil end
    local offset, cdOffset, tdRef, chdRef = RU(col + 4), RU(col + 8), RU(col + 12), RU(col + 16)
    if not offset or offset >= 0x1000000 or not tdRef or not chdRef then return nil end
    if S.x64 and RU(col + 20) ~= col - image.from then return nil end
    local td, chd = Absolute(image, tdRef), Absolute(image, chdRef)
    local tdImage, chdImage = FindImage(td), FindImage(chd)
    if not tdImage or not chdImage then return nil end
    local count = RU(chd + 8)
    if RU(chd) ~= 0 or not count or count < 1 or count > MAX_BASES then return nil end
    local decorated = TypeName(td)
    if not decorated then return nil end
    local info = {
        col = col, offset = offset, cdOffset = cdOffset, td = td, chd = chd, image = image,
        decorated = decorated, name = Demangle(decorated), attributes = RU(chd + 4) or 0,
    }
    S.cols[col] = info
    local record = ClassRecord(info.name)
    record.decorated = record.decorated or decorated
    record.td = record.td or td
    record.image = record.image or tdImage
    return info
end

local function Bases(info)
    if info.bases then return info.bases end
    local list = {}
    local count = math.min(RU(info.chd + 8) or 0, MAX_BASES)
    local array = Absolute(info.image, RU(info.chd + 12) or 0)
    -- ∑ The base array is the hierarchy in pre-order; each entry says how
    -- many entries below it are its own bases, which gives the depth.
    local open = {}
    for i = 0, count - 1 do
        local bcd = Absolute(info.image, RU(array + 4 * i) or 0)
        local decorated = TypeName(Absolute(info.image, RU(bcd) or 0))
        local entry = {
            decorated = decorated, name = decorated and Demangle(decorated) or "?",
            contained = RU(bcd + 4) or 0, offset = RI(bcd + 8) or 0, pdisp = RI(bcd + 12) or -1,
            vdisp = RI(bcd + 16) or 0, attributes = RU(bcd + 20) or 0,
        }
        entry.virtual = entry.pdisp ~= -1
        while #open > 0 and open[#open] <= 0 do open[#open] = nil end
        entry.depth = #open
        for k = 1, #open do open[k] = open[k] - 1 end
        if entry.contained > 0 then open[#open + 1] = entry.contained end
        list[#list + 1] = entry
    end
    info.bases = list
    return list
end

local function VirtualBaseOffset(start, base)
    if not base.virtual then return base.offset end
    if not start then return nil end
    local vbtable = RP(start + base.pdisp)
    local delta = vbtable and RI(vbtable + base.vdisp)
    if not delta then return nil end
    return base.pdisp + delta + base.offset
end

-- The base class whose part of the object starts at offset.
local function BaseAt(info, offset, start)
    for index, base in ipairs(Bases(info)) do
        if index > 1 and (not base.virtual or start) and VirtualBaseOffset(start, base) == offset then
            return base.name
        end
    end
    return nil
end

local function SymbolFor(info)
    if info.offset == 0 then return info.name .. "::vftable" end
    return info.name .. "::vftable@" .. (BaseAt(info, info.offset) or string.format("%X", info.offset))
end

local function RegisterVTable(info, vt)
    if not REGISTER_SYMBOLS or type(registerSymbol) ~= "function" then return end
    local name = SymbolFor(info)
    if State.Symbols[name] == vt then return end
    if pcall(registerSymbol, name, vt, true) then State.Symbols[name] = vt end
end

local function VTableClass(vt, quick)
    if not vt then return nil end
    local cached = S.vts[vt]
    if cached ~= nil then return cached or nil end
    if S.cached >= CACHE_LIMIT then S.vts, S.cached = {}, 0 end
    local info = false
    if vt % S.ptr == 0 and ImageOf(vt, quick) then
        local col = RP(vt - S.ptr)
        if col and FindImage(col) then info = ReadCOL(col) or false end
    end
    S.vts[vt] = info
    S.cached = S.cached + 1
    if info then
        ClassRecord(info.name).vtables[vt] = info
        RegisterVTable(info, vt)
    end
    return info or nil
end

local function IsVBTable(value)
    if not value or not FindImage(value) then return false end
    local top, first = RI(value), RI(value + 4)
    return top ~= nil and first ~= nil and top <= 0 and top >= -0x1000 and first > 0 and first < 0x100000
end

--
--- ∑ The object whose virtual function table pointer is stored at address.
--- An address that holds a base class's table pointer belongs to a larger
--- object; the locator's offset leads to its start. A class whose only
--- virtual functions come from a virtual base starts with a pointer to its
--- virtual base table instead, and the base's table pointer is found
--- through it.
--
local function ObjectAt(address, quick)
    if not address or address % S.ptr ~= 0 then return nil end
    local vt = RP(address)
    local info = VTableClass(vt, quick)
    if info then
        return { address = address, start = address - info.offset, vtable = vt, class = info }
    end
    if not IsVBTable(vt) then return nil end
    local vbase = address + RI(vt + 4)
    local vvt = RP(vbase)
    local vinfo = VTableClass(vvt, true)
    if not vinfo or vinfo.attributes & 2 == 0 then return nil end
    local start = vbase - vinfo.offset
    if start > address then return nil end
    return { address = address, start = start, vtable = vvt, class = vinfo, via = vbase }
end

----------------------------------------
-- LOOKUPS
----------------------------------------

local function Primary(record, which)
    local best, bestInfo
    for vt, info in pairs(record.vtables) do
        local match
        if which then
            match = string.format("%X", info.offset) == which:upper() or BaseAt(info, info.offset) == which
        else
            match = not bestInfo or info.offset < bestInfo.offset or (info.offset == bestInfo.offset and vt < best)
        end
        if match then best, bestInfo = vt, info end
    end
    return best, bestInfo
end

local function SearchImages(record)
    if record and record.image then return { record.image } end
    local list = {}
    if S.main then list[1] = S.main end
    for _, image in ipairs(S.images) do
        if image ~= S.main and not image.system then list[#list + 1] = image end
    end
    return list
end

--
--- ∑ A class by name, without an index of the whole game: the decorated
--- name leads to its type descriptor, the descriptor's address to the
--- locators that name it, and each locator's address to the table it
--- precedes. Three scans of one module; misses are remembered until the
--- module list changes.
--
local function FindClass(name)
    Session()
    if S.pid == 0 or type(name) ~= "string" or name == "" then return nil end
    local record = S.classes[name]
    if record and record.scanned and next(record.vtables) then return record end
    if S.classMiss[name] then return nil end
    local candidates = record and record.decorated and { record.decorated } or Mangle(name)
    if not candidates then
        S.classMiss[name] = true
        return nil
    end
    local key = name
    -- ∑ class and struct differ in one letter; one scan with that letter
    -- left open finds both and halves the cost of a miss.
    local wanted, pattern = {}, nil
    for _, decorated in ipairs(candidates) do wanted[decorated] = true end
    if #candidates == 2 then
        pattern = "2E 3F 41 ?? " .. TextBytes(candidates[1]:sub(5) .. "\0")
    else
        pattern = TextBytes(candidates[1] .. "\0")
    end
    for _, image in ipairs(SearchImages(record)) do
        do
            local tds = {}
            if record and record.td and FindImage(record.td) == image then
                tds[1] = record.td
            else
                for _, hit in ipairs(ScanBytes(pattern, image.from, image.to, nil, nil, 16)) do
                    local td = hit - 2 * S.ptr
                    if wanted[TypeName(td) or ""] then tds[#tds + 1] = td end
                end
            end
            for _, td in ipairs(tds) do
                local ref = S.x64 and td - image.from or td
                for _, hit in ipairs(ScanBytes(LittleEndian(ref, 4), image.from, image.to, 4, nil, 4096)) do
                    local info = ReadCOL(hit - 12)
                    if info and info.td == td then
                        key = info.name
                        for _, at in ipairs(ScanBytes(LittleEndian(info.col, S.ptr), image.from, image.to, S.ptr, nil, 64)) do
                            VTableClass(at + S.ptr, true)
                        end
                    end
                end
            end
            local found = S.classes[key]
            if found and next(found.vtables) then
                found.scanned = true
                if key ~= name then S.classes[name] = found end
                return found
            end
        end
    end
    S.classMiss[name] = true
    return nil
end

--
--- ∑ The nearest object at or before address. The walk reads whole pages
--- and stops at the first unreadable one, because no object spans a hole.
--- A member object with virtual functions of its own counts as an object:
--- RTTI does not say how large a class is, so an address behind such a
--- member is reported inside the member.
--
local function Owner(address, window)
    window = window or OWNER_WINDOW
    local ptr = S.ptr
    local top = address - address % ptr
    local floor = math.max(top - window, 0x10000)
    local page = top - top % 0x1000
    local position = top
    while position >= floor do
        local raw = ReadRaw(page, 0x1000)
        if not raw then return nil end
        while position >= page and position >= floor do
            local value = string.unpack(S.fmt, raw, position - page + 1)
            if FindImage(value) then
                local hit = ObjectAt(position, true)
                if hit and hit.start <= address then
                    hit.offset = address - hit.start
                    return hit
                end
            end
            position = position - ptr
        end
        page = page - 0x1000
    end
    return nil
end

local function Locate(address)
    local hit = ObjectAt(address)
    if hit then
        hit.offset = address - hit.start
        return hit
    end
    return Owner(address)
end

local function Instances(name, limit)
    local record = FindClass(name)
    if not record then return nil end
    local vt, info = Primary(record)
    if not vt then return nil end
    local stop = S.x64 and 0x7FFFFFFFFFFF or 0xFFFFFFFF
    local list = {}
    for _, hit in ipairs(ScanBytes(LittleEndian(vt, S.ptr), 0x10000, stop, S.ptr, "+W*X*C", limit or INSTANCE_LIMIT)) do
        list[#list + 1] = hit - info.offset
    end
    return list, info
end

local function BaseLines(info, start, lines)
    for _, base in ipairs(Bases(info)) do
        local offset = VirtualBaseOffset(start, base)
        lines[#lines + 1] = string.format("  %s%s%s  +%s", string.rep("  ", base.depth), base.name,
            base.virtual and " (virtual)" or "", offset and string.format("%X", offset) or "?")
    end
end

local function Whois(address)
    local hit = Locate(address)
    if not hit then return nil end
    local info = hit.class
    local lines = {}
    if address == hit.start then
        lines[#lines + 1] = string.format("%X is a %s", address, info.name)
    else
        lines[#lines + 1] = string.format("%X is %s+%X", address, info.name, address - hit.start)
        lines[#lines + 1] = string.format("Object start: %X", hit.start)
    end
    lines[#lines + 1] = "Decorated name: " .. info.decorated
    lines[#lines + 1] = string.format("Virtual function table: %X (%s)", hit.vtable, ModuleOffset(hit.vtable))
    lines[#lines + 1] = "Defined in: " .. info.image.name
    lines[#lines + 1] = "Class and base classes:"
    BaseLines(info, hit.start, lines)
    return table.concat(lines, "\n"), hit
end

----------------------------------------
-- STRUCTURE DISSECT
----------------------------------------

--
--- ∑ Unreal and Godot objects belong to Manifold-UE and Manifold-Godot,
--- which know their real property names and engine members; a game with
--- either gives the address to that script first. Only their claims are
--- asked, never ManifoldUE.owner: owner resolves with the full search and
--- does not remember a failure, so in a game that is not Unreal it would
--- search the whole process again on every name RTTI looks up.
--
local ENGINE_SCRIPTS = { "ManifoldUE", "ManifoldGodot" }

local function EngineOwns(address)
    for _, name in ipairs(ENGINE_SCRIPTS) do
        local engine = rawget(_G, name)
        if type(engine) == "table" and type(engine.claims) == "function" then
            local ok, claimed = pcall(engine.claims, address)
            if ok and claimed then return true end
        end
    end
    return false
end

-- ∑ What a guess leaves on a pointer field: nothing, or "Pointer" with the
-- field's offset behind it in hosts that number their guessed fields.
local function Generic(name)
    if name == nil or name == "" then return true end
    local lowered = name:lower()
    return lowered == "pointer" or lowered:find("^pointer %x+$") ~= nil
end

local function PointerLabel(hit, value)
    if not value then return nil end
    local info = VTableClass(value, true)
    if info then
        if info.td == hit.class.td then
            if info.offset == 0 then return "vftable" end
            local base = BaseAt(info, info.offset, hit.start)
            return base and ("vftable (" .. base .. ")") or "vftable"
        end
        return info.name .. " vftable"
    end
    if hit.class.attributes & 2 ~= 0 and IsVBTable(value) then return "vbtable" end
    local target = ObjectAt(value, true)
    if not target then return nil end
    if target.start == value then return target.class.name .. "*" end
    return (BaseAt(target.class, value - target.start, target.start) or target.class.name) .. "*"
end

local function Elements(structure)
    local list = {}
    local ok, count = pcall(function() return structure.Count end)
    for i = 0, (ok and count or 0) - 1 do
        local fine, element = pcall(function() return structure.getElement(i) end)
        if fine and element then list[#list + 1] = element end
    end
    return list
end

local function AnnotateObject(structure, hit)
    local labelled = 0
    for _, element in ipairs(Elements(structure)) do
        if element.Vartype == VT.Pointer and Generic(element.Name) then
            local label = PointerLabel(hit, RP(hit.start + element.Offset))
            if label then
                element.Name = label
                labelled = labelled + 1
            end
        end
    end
    return labelled
end

local function AnnotateTable(structure, vt)
    local labelled = 0
    for _, element in ipairs(Elements(structure)) do
        local offset = element.Offset
        if offset % S.ptr ~= 0 or offset // S.ptr >= MAX_VIRTUALS then break end
        local value = RP(vt + offset)
        if not value or not FindImage(value) or (offset > 0 and ReadCOL(value)) then break end
        if element.Vartype == VT.Pointer and Generic(element.Name) then
            element.Name = string.format("virtual %d", offset // S.ptr)
            labelled = labelled + 1
        end
    end
    return labelled
end

local function TableName(info)
    return SymbolFor(info)
end

-- ∑ registerStructureNameLookup: the class names the structure, and an
-- address inside a base class part moves to the object's start. An address
-- that is a virtual function table itself is named after its class.
State.NameLookup = function(address)
    Session()
    if S.pid == 0 then return nil end
    local hit = ObjectAt(address)
    if hit then
        if EngineOwns(address) then return nil end
        if hit.start ~= address then return hit.class.name, hit.start end
        return hit.class.name
    end
    local info = VTableClass(address)
    if info then return TableName(info) end
    return nil
end

-- ∑ registerStructureDissectOverride: Cheat Engine guesses first, then the
-- table pointers and the pointer fields get names. A host whose
-- structure:autoGuess does nothing leaves the structure empty, and then the
-- override declines so the host's own guess still runs.
State.DissectOverride = function(structure, base)
    if State.InOverride then return nil end
    Session()
    if S.pid == 0 then return nil end
    local hit = ObjectAt(base)
    local vtable = not hit and VTableClass(base)
    if not hit and not vtable then return nil end
    if hit and (hit.start ~= base or EngineOwns(base)) then return nil end
    State.InOverride = true
    local ok, err = pcall(function() structure.autoGuess(base, 0, GUESS_SIZE) end)
    State.InOverride = false
    if not ok then
        Log("Dissect", err)
        return nil
    end
    if #Elements(structure) == 0 then return nil end
    if hit then AnnotateObject(structure, hit) else AnnotateTable(structure, base) end
    return true
end

local function FindGlobalStructure(name)
    local ok, count = pcall(getStructureCount)
    for i = 0, (ok and count or 0) - 1 do
        local fine, structure = pcall(getStructure, i)
        if fine and structure and structure.Name == name then return structure end
    end
    return nil
end

local function Dissect(address)
    Session()
    local hit = Locate(address)
    if not hit then error(string.format("no object with run-time type information at %X", address), 2) end
    local name = hit.class.name
    if not FindGlobalStructure(name) and type(createStructure) == "function" then
        local structure = createStructure(name)
        State.InOverride = true
        pcall(function() structure.autoGuess(hit.start, 0, GUESS_SIZE) end)
        State.InOverride = false
        if #Elements(structure) > 0 then
            AnnotateObject(structure, hit)
            structure.addToGlobalStructureList()
        else
            pcall(function() structure.destroy() end)
        end
    end
    local text = string.format("%X", hit.start)
    if FindGlobalStructure(name) then return createStructureForm(text, "Group 1", name) end
    return createStructureForm(text)
end

----------------------------------------
-- SYMBOLS
----------------------------------------

--
--- ∑ <Class>::vftable and <Class>::vftable@<Base> resolve on demand, so a
--- table saved with them works again in the next session and after a game
--- update, when every table address has moved. Only names that end in
--- ::vftable are looked at; everything else returns at once.
--
State.SymbolLookup = function(token)
    if type(token) ~= "string" or #token > 512 or not token:find("::vftable", 1, true) then return nil end
    local name, which = token:match("^(.-)::vftable@(.+)$")
    if not name then name = token:match("^(.-)::vftable$") end
    if not name or name == "" then return nil end
    Session()
    local record = FindClass(name)
    if not record then return nil end
    local vt = Primary(record, which)
    return vt
end

local function InstallSymbolLookup()
    if State.SymbolLookupId and type(unregisterSymbolLookupCallback) == "function" then
        pcall(unregisterSymbolLookupCallback, State.SymbolLookupId)
    end
    State.SymbolLookupId = nil
    if type(registerSymbolLookupCallback) ~= "function" then return end
    local ok, id = pcall(registerSymbolLookupCallback, function(token)
        local fine, value = pcall(State.SymbolLookup, token)
        if fine then return value end
    end, SL_FAILURE)
    if ok then State.SymbolLookupId = id end
end

-- ∑ Cheat Engine has getRTTIClassName; a host without it gets this one, and
-- a reload replaces the previous run's copy instead of keeping a stale one.
local function InstallClassNameFunction()
    if rawget(_G, "getRTTIClassName") ~= nil and not State.ProvidesClassName then return end
    getRTTIClassName = function(address)
        Session()
        if S.pid == 0 then return nil end
        local hit = ObjectAt(ToAddress(address))
        return hit and hit.class.name or nil
    end
    State.ProvidesClassName = true
end

----------------------------------------
-- PUBLIC API
----------------------------------------

local function Public(hit)
    if not hit then return nil end
    return {
        address = hit.address, start = hit.start, offset = hit.offset or (hit.address - hit.start),
        class = hit.class.name, decorated = hit.class.decorated, vtable = hit.vtable,
        module = hit.class.image.name, viaVirtualBase = hit.via ~= nil,
    }
end

local function Ready()
    Session()
    if S.pid == 0 then error("no process is opened", 3) end
end

RTTI.VERSION = VERSION

function RTTI.demangle(decorated) return Demangle(decorated) end
function RTTI.mangle(name) return Mangle(name) end

function RTTI.className(address)
    Ready()
    local hit = ObjectAt(ToAddress(address))
    return hit and hit.class.name or nil
end

function RTTI.object(address)
    Ready()
    local target = ToAddress(address)
    local hit = ObjectAt(target)
    if hit then hit.offset = target - hit.start end
    return Public(hit)
end

function RTTI.owner(address, window)
    Ready()
    return Public(Owner(ToAddress(address), window))
end

function RTTI.whois(address)
    Ready()
    return (Whois(ToAddress(address)))
end

function RTTI.bases(what)
    Ready()
    local info, start
    -- ∑ A string is a class name: names such as "Face" would also read as hex.
    if type(what) == "string" then
        local record = FindClass(what)
        if not record then return nil end
        local _, primary = Primary(record)
        info = primary
    else
        local hit = Locate(ToAddress(what))
        if not hit then return nil end
        info, start = hit.class, hit.start
    end
    local list = {}
    for _, base in ipairs(Bases(info)) do
        list[#list + 1] = {
            name = base.name, decorated = base.decorated, depth = base.depth,
            offset = VirtualBaseOffset(start, base), virtual = base.virtual,
        }
    end
    return list
end

function RTTI.vtable(name, base)
    Ready()
    local record = FindClass(name)
    if not record then return nil end
    return (Primary(record, base))
end

function RTTI.vtables(name)
    Ready()
    local record = FindClass(name)
    if not record then return nil end
    local list = {}
    for vt, info in pairs(record.vtables) do
        list[#list + 1] = { address = vt, offset = info.offset, symbol = SymbolFor(info), module = info.image.name }
    end
    table.sort(list, function(a, b) return a.offset < b.offset or (a.offset == b.offset and a.address < b.address) end)
    return list
end

function RTTI.instances(name, limit)
    Ready()
    return (Instances(name, limit))
end

function RTTI.dissect(address)
    Ready()
    return Dissect(ToAddress(address))
end

-- ∑ The labelling the dissect override does, for a structure that already
-- exists: unnamed pointer fields get the class they point to.
function RTTI.label(structure, address)
    Ready()
    local base = ToAddress(address)
    local hit = ObjectAt(base)
    if hit and hit.start == base then return AnnotateObject(structure, hit) end
    if VTableClass(base) then return AnnotateTable(structure, base) end
    return 0
end

function RTTI.classes()
    Ready()
    local list = {}
    for name, record in pairs(S.classes) do
        if record.name == name and next(record.vtables) then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

function RTTI.status()
    Session()
    if S.pid == 0 then return "no process" end
    local classes, tables = 0, 0
    for name, record in pairs(S.classes) do
        if record.name == name and next(record.vtables) then
            classes = classes + 1
            for _ in pairs(record.vtables) do tables = tables + 1 end
        end
    end
    return string.format("%d-bit process %d: %d modules, %d classes and %d virtual function tables seen",
        S.x64 and 64 or 32, S.pid, #S.images, classes, tables)
end

function RTTI.reset()
    ForgetSymbols()
    S = nil
    Session()
end

----------------------------------------
-- MENU
----------------------------------------

local function Guarded(tag, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            Log(tag, err)
            pcall(messageDialog, tostring(err):gsub("^.-:%d+: ", ""), mtError, mbOK)
        end
    end
end

local function AskAddress(title)
    local text = inputQuery(title, "Address (number, symbol or expression):", "")
    if not text or text == "" then return nil end
    local address = ToAddress(text)
    if not address then error("not an address: " .. text) end
    return address
end

local function SetDissectHooks(enabled)
    if State.NameLookupId and type(unregisterStructureNameLookup) == "function" then pcall(unregisterStructureNameLookup, State.NameLookupId) end
    if State.DissectOverrideId and type(unregisterStructureDissectOverride) == "function" then pcall(unregisterStructureDissectOverride, State.DissectOverrideId) end
    State.NameLookupId, State.DissectOverrideId = nil, nil
    State.HooksEnabled = enabled
    if not enabled then return end
    if type(registerStructureNameLookup) ~= "function" or type(registerStructureDissectOverride) ~= "function" then
        Log("Dissect", "This Cheat Engine has no structure dissect callbacks; Structure Dissect keeps guessing on its own.")
        return
    end
    State.NameLookupId = registerStructureNameLookup(function(address)
        local ok, name, start = pcall(State.NameLookup, address)
        if ok then return name, start end
        Log("Dissect", name)
    end)
    State.DissectOverrideId = registerStructureDissectOverride(function(structure, base)
        local ok, handled = pcall(State.DissectOverride, structure, base)
        if ok then return handled end
        Log("Dissect", handled)
    end)
end

local function ShowInstances(name)
    local list = Instances(name)
    if not list then
        messageDialog(string.format("No class %s with a virtual function table was found.", name), mtInformation, mbOK)
        return
    end
    print(string.format("%d objects of %s:", #list, name))
    for i = 1, math.min(#list, 500) do print(string.format("  %X", list[i])) end
    if #list > 500 then print(string.format("  ... and %d more", #list - 500)) end
    local text = string.format("%d objects of %s. Their addresses are in the Lua console.", #list, name)
    if #list > 0 and messageDialog(text .. "\n\nDissect the first one?", mtConfirmation, mbYes, mbNo) == mrYes then
        Dissect(list[1])
    elseif #list == 0 then
        messageDialog(text, mtInformation, mbOK)
    end
end

local function InstallMenu()
    if State.MenuRoot then
        pcall(function() State.MenuRoot.destroy() end)
        State.MenuRoot = nil
    end
    local mainForm = rawget(_G, "MainForm") or (type(getMainForm) == "function" and getMainForm())
    if type(createMenuItem) ~= "function" or not mainForm then return end
    local ok, err = pcall(function()
        local menu = mainForm.Menu
        local root = createMenuItem(menu)
        root.Caption = MENU_CAPTION
        menu.Items.add(root)
        State.MenuRoot = root
        local function item(caption, onClick)
            local entry = createMenuItem(menu)
            entry.Caption = caption
            if onClick then entry.OnClick = Guarded(caption, onClick) end
            root.add(entry)
            return entry
        end
        local status = item("Status: no process")
        status.Enabled = false
        root.OnClick = function() pcall(function() status.Caption = "Status: " .. RTTI.status() end) end
        item("Who owns an address...", function()
            local address = AskAddress("Who owns this address?")
            if not address then return end
            Ready()
            local text, hit = Whois(address)
            if not text then
                messageDialog(string.format("No object with run-time type information was found at or before %X.", address), mtInformation, mbOK)
                return
            end
            print(text)
            if messageDialog(text .. "\n\nDissect the object?", mtConfirmation, mbYes, mbNo) == mrYes then Dissect(hit.start) end
        end)
        item("Dissect object at address...", function()
            local address = AskAddress("Dissect C++ object")
            if address then
                Ready()
                Dissect(address)
            end
        end)
        item("Find objects of a class...", function()
            local name = inputQuery("Find objects of a class", "Class name (for example Game::Player):", "")
            if not name or name == "" then return end
            Ready()
            ShowInstances(name)
        end)
        item("-")
        item("Forget what was learned", function() RTTI.reset() end)
        local hooks = item("Structure Dissect uses RTTI", function() end)
        hooks.Checked = State.HooksEnabled ~= false
        hooks.OnClick = Guarded("Hooks", function()
            hooks.Checked = not hooks.Checked
            SetDissectHooks(hooks.Checked)
        end)
    end)
    if not ok then Log("Menu", "Could not build the menu: " .. tostring(err)) end
end

----------------------------------------
-- MAIN
----------------------------------------

local function Main()
    if type(readPointer) ~= "function" or type(readInteger) ~= "function" then
        Log("Main", "This host has no memory API, nothing was installed.")
        return
    end
    ForgetSymbols()
    InstallClassNameFunction()
    SetDissectHooks(State.HooksEnabled ~= false)
    InstallSymbolLookup()
    InstallMenu()
    Log("Main", "Version " .. VERSION .. " ready. Structure Dissect names C++ objects; the " .. MENU_CAPTION .. " menu finds them.")
end

Main()

return RTTI
