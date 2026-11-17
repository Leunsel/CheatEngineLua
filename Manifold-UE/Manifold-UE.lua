--[[
    Manifold-UE.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 1.0.0
    LICENSE : MIT
    CREATED : 2026-11-14
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

    Unreal Engine 4 and 5 reflection for Cheat Engine, without an SDK, without
    game-specific offsets and without signatures. It is the runtime half of
    Manifold-UE (the internal overlay DLL) moved into an autorun script: the
    name table, the object array and the reflection layout are found in the
    running game, and everything else is asked of the engine's own metadata.

    What it adds to Cheat Engine:
        - Structure Dissect knows Unreal objects. "Define new structure" names
          the structure after the object's class and moves to the object's
          start; the fields are the class's reflected properties with their
          real names, nested structs inline, bitfield bools as one-bit binary
          fields (with their masks where the host has no bit fields) and the
          native gaps in between. Expanding a pointer to another
          object fills that one the same way, expanding a TArray its entries.
        - Custom types "UE FName", "UE FString" and "UE Object Index" that show
          names, strings and weak object references as text.
        - Symbols: GObjects, FNamePool (or GNames), GameEngine, and offsets as
          <Type>_<Property> that resolve again in every session, so address
          list entries survive game updates.
        - An "Unreal Engine" menu with an inspector (types, properties,
          functions, instances), "who owns this address" and quick dissects
          of the engine, the world, the player controller and the pawn.
        - ManifoldUE, a Lua API for tables and the Lua console.

    Everything here only reads the game. Nothing is injected, hooked or called
    inside the target; writes happen only where the user edits a value.

    Supported: x64 games on UE 4.11 to 5.6, FNamePool (4.23+) and the older
    TNameEntryArray, FField (4.25+) and UProperty reflection, chunked and
    fixed object arrays, monolithic and modular builds.
]]

----------------------------------------
-- CONFIG
----------------------------------------
local RUNTIME_STATE_KEY = "__MANIFOLD_UE_RUNTIME__"
local LOG_PREFIX        = "Manifold-UE"
local VERSION           = "1.0.0"
local MENU_CAPTION      = "Unreal Engine"

local POINTER_MIN, POINTER_MAX = 0x10000, 0x7FFFFFFFFFFF

-- FNamePool: FRWLock, CurrentBlock, CurrentByteCursor, Blocks[8192].
local NAME_BLOCKS_OFFSET = 0x10
local NAME_MAX_BLOCKS    = 8192
local NAME_MAX_LENGTH    = 1024
local LEGACY_PER_CHUNK   = 0x4000

-- FChunkedFixedUObjectArray::NumElementsPerChunk, identical in every UE4/UE5.
local OBJECTS_PER_CHUNK = 0x10000
local MIN_OBJECTS       = 0x800
local MAX_OBJECTS       = 0x10000000

local MAX_SUPER_DEPTH = 64
local MAX_FIELDS      = 8192

-- ∑ An address inside an object finds its object by walking back to the
-- closest address that is an object start. Objects are 8-byte aligned, so
-- this many bytes cost OWNER_WINDOW / 8 cheap checks; a full pass over the
-- object array is the fallback for objects larger than that.
local OWNER_WINDOW = 0x10000

local INLINE_DEPTH           = 6
local STATIC_ARRAY_LIMIT     = 64
local GAP_LIMIT              = 0x1000
local ELEMENT_LIMIT          = 6000
local ARRAY_PREVIEW          = 64
local ARRAY_PREVIEW_ELEMENTS = 1024
local SECTION_STEP           = 0x10000
local RAW_BLOCK_OBJECTS      = 0x1000

local CUSTOM_FNAME   = "UE FName"
local CUSTOM_FSTRING = "UE FString"
local CUSTOM_WEAK    = "UE Object Index"

-- Variable types as defines.lua publishes them; the literals are the fallback.
local VT = {
    Byte    = rawget(_G, "vtByte") or 0,
    Word    = rawget(_G, "vtWord") or 1,
    Dword   = rawget(_G, "vtDword") or 2,
    Qword   = rawget(_G, "vtQword") or 3,
    Single  = rawget(_G, "vtSingle") or 4,
    Double  = rawget(_G, "vtDouble") or 5,
    String  = rawget(_G, "vtString") or 6,
    Wide    = rawget(_G, "vtUnicodeString") or 7,
    Bytes   = rawget(_G, "vtByteArray") or 8,
    Binary  = rawget(_G, "vtBinary") or 9,
    Pointer = rawget(_G, "vtPointer") or 12,
    Custom  = rawget(_G, "vtCustom") or 13,
}
local SL_FAILURE = rawget(_G, "slFailure") or 5

-- ∑ Runtime handles live outside this chunk, so executing the file again
-- (from the Lua engine, or a second autorun copy) releases what the previous
-- run registered instead of stacking menus and callbacks.
local State = rawget(_G, RUNTIME_STATE_KEY)
if type(State) ~= "table" then
    State = {}
    _G[RUNTIME_STATE_KEY] = State
end

ManifoldUE = {}
local UE = ManifoldUE

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

local function IsPtr(value)
    return math.type(value) == "integer" and value >= POINTER_MIN and value <= POINTER_MAX and value & 7 == 0
end

local function RP(address)
    if not address or address == 0 then return nil end
    return readPointer(address)
end

-- A pointer field that must hold an object or heap address; null is nil.
local function RPtr(address)
    local value = RP(address)
    return IsPtr(value) and value or nil
end

local function RI(address)
    if not address or address == 0 then return nil end
    local value = readInteger(address)
    if value and value >= 0x80000000 then value = value - 0x100000000 end
    return value
end

local function RU(address)
    if not address or address == 0 then return nil end
    return readInteger(address)
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

local function PointerAob(value)
    local parts = {}
    for i = 0, 7 do parts[#parts + 1] = string.format("%02X", (value >> (i * 8)) & 0xFF) end
    return table.concat(parts, " ")
end

--
--- ∑ AOBScan honours the protection flags and the alignment in Cheat Engine;
--- hosts that ignore them still hand back the right hits, so the alignment is
--- checked here as well.
--
local function Aob(pattern, align, limit)
    local ok, list = pcall(AOBScan, pattern, "+W", align and align > 1 and 1 or 0, align and align > 1 and tostring(align) or "")
    local found = {}
    if not ok or not list then return found end
    local count = list.Count or 0
    for i = 0, count - 1 do
        local address = tonumber(list[i], 16)
        if address and (not align or address % align == 0) then
            found[#found + 1] = address
            if limit and #found >= limit then break end
        end
    end
    pcall(function() list.destroy() end)
    return found
end

----------------------------------------
-- SESSION
----------------------------------------

-- ∑ Everything learned about one process. A different process id starts a
-- new session, so attaching to another game never reuses stale addresses,
-- and the symbols registered for the old one are taken back: they would
-- otherwise name addresses of the next game, Manifold-RTTI's and
-- Manifold-Godot's included.
local S

local function OpenedProcess()
    local ok, pid = pcall(getOpenedProcessID)
    return ok and pid or 0
end

local function ForgetSymbols()
    if type(unregisterSymbol) == "function" then
        for name in pairs(State.Symbols or {}) do pcall(unregisterSymbol, name) end
    end
    State.Symbols = {}
end

local function RegisterOwnSymbol(name, value)
    if type(registerSymbol) ~= "function" then return false end
    State.Symbols = State.Symbols or {}
    local ok, result = pcall(registerSymbol, name, value, true)
    if ok and result ~= false then
        State.Symbols[name] = value
        return true
    end
    return false
end

local function Session()
    local pid = OpenedProcess()
    if State.SymbolsPid ~= pid then
        ForgetSymbols()
        State.SymbolsPid = pid
    end
    if not S or S.pid ~= pid then
        S = {
            pid = pid, ready = false, failed = nil,
            images = {}, nameText = {}, blocks = {}, chunks = {},
            types = {}, typeList = {}, kinds = {}, own = {}, merged = {}, cpp = {},
            enums = {}, functions = {}, symbols = {}, arrays = {}, arrayCount = 0,
        }
    end
    return S
end

local function LoadImages()
    local list, main = {}, nil
    local ok, modules = pcall(enumModules)
    for _, m in ipairs(ok and modules or {}) do
        local size = m.Size
        if not size or size == 0 then
            local fine, value = pcall(getModuleSize, m.Name)
            size = fine and value or 0
        end
        local entry = { name = m.Name or "", path = m.PathToFile or "", from = m.Address, to = m.Address + (size or 0) }
        list[#list + 1] = entry
        main = main or entry
    end
    table.sort(list, function(a, b) return a.from < b.from end)
    S.images, S.main = list, main
end

local function InImage(address)
    local list = S.images
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = (lo + hi) // 2
        local image = list[mid]
        if address < image.from then hi = mid - 1
        elseif address >= image.to then lo = mid + 1
        else return true end
    end
    return false
end

local function Sections(image, wantWritable)
    local out = {}
    local peOffset = RU(image.from + 0x3C)
    if not peOffset then return out end
    local pe = image.from + peOffset
    local count, optional = readSmallInteger(pe + 6), readSmallInteger(pe + 0x14)
    if not count or not optional then return out end
    local first = pe + 0x18 + optional
    for i = 0, count - 1 do
        local section = first + i * 0x28
        local size, rva, flags = RU(section + 8), RU(section + 0xC), RU(section + 0x24)
        if size and rva and flags and size > 0 then
            local writable, executable = flags & 0x80000000 ~= 0, flags & 0x20000000 ~= 0
            if not wantWritable or (writable and not executable) then
                out[#out + 1] = { from = image.from + rva, size = size }
            end
        end
    end
    return out
end

-- ∑ Packaged games keep their executable under <Game>\Binaries\Win64
-- whatever they call it; modular builds load a CoreUObject module.
local function LooksUnreal()
    local main = S.main and S.main.name or ""
    local path = (S.main and S.main.path or ""):lower()
    if main:find("%-Win64%-") or main:find("%-WinGDK%-") or main:find("Shipping") or main:find("UE4") then return true end
    if path:find("\\binaries\\win64\\", 1, true) or path:find("\\binaries\\wingdk\\", 1, true) then return true end
    for _, image in ipairs(S.images) do
        if image.name:find("%-CoreUObject", 1) then return true end
    end
    return false
end

-- "/Script/CoreUObject" as UTF-16, the package name every Unreal build
-- registers its core classes under.
local CORE_UOBJECT_UTF16 = "2F 00 53 00 63 00 72 00 69 00 70 00 74 00 2F 00 43 00 6F 00 72 00 65 00 55 00 4F 00 62 00 6A 00 65 00 63 00 74 00"

--
--- ∑ Gates every automatic resolve. Without it the name pool scan ran in any
--- process, and in a Godot game a false pool sent the object array search
--- over the whole process for 19 seconds on the first dissect. A renamed
--- monolithic executable still carries the CoreUObject package name, which
--- no other engine has; one scan of the main module checks it, once per
--- process. "Resolve again" and the ManifoldUE API still try any process.
--
local function UnrealProcess()
    if S.unreal ~= nil then return S.unreal end
    if #S.images == 0 then pcall(LoadImages) end
    local verdict = LooksUnreal()
    if not verdict and S.main and type(AOBScanModuleUnique) == "function" then
        local ok, address = pcall(AOBScanModuleUnique, S.main.name, CORE_UOBJECT_UTF16, "*X*C*W")
        verdict = ok and address ~= nil and address ~= 0
    end
    S.unreal = verdict and true or false
    return S.unreal
end

----------------------------------------
-- NAMES
----------------------------------------

local function PoolEntry(entry)
    local header = readSmallInteger(entry)
    if not header then return nil end
    local length, wide = header >> 6, header & 1 == 1
    if length == 0 or length > NAME_MAX_LENGTH then return nil end
    if wide then
        local bytes = readBytes(entry + 2, length * 2, true)
        return bytes and byteTableToWideString(bytes) or nil
    end
    local raw = ReadRaw(entry + 2, length)
    return raw
end

local function LegacyEntry(entry, layout)
    if not entry or entry == 0 then return nil end
    local index = RU(entry + layout.index)
    if not index then return nil end
    local text = readString(entry + layout.name, NAME_MAX_LENGTH, index & 1 == 1)
    if not text or text == "" then return nil end
    return text
end

local function NameText(index)
    local cached = S.nameText[index]
    if cached then return cached end
    if not index or index < 0 then return nil end
    local text
    if S.nameKind == "pool" then
        local block = index >> 16
        if block >= NAME_MAX_BLOCKS then return nil end
        local base = S.blocks[block]
        if not base then
            base = RP(S.pool + NAME_BLOCKS_OFFSET + block * 8)
            if not base or base < POINTER_MIN or base > POINTER_MAX then return nil end
            S.blocks[block] = base
        end
        text = PoolEntry(base + (index & 0xFFFF) * 2)
    elseif S.nameKind == "legacy" then
        local chunk = S.blocks[index // LEGACY_PER_CHUNK]
        if not chunk then
            chunk = RP(S.pool + (index // LEGACY_PER_CHUNK) * 8)
            if not IsPtr(chunk) then return nil end
            S.blocks[index // LEGACY_PER_CHUNK] = chunk
        end
        text = LegacyEntry(RP(chunk + (index % LEGACY_PER_CHUNK) * 8), S.legacy)
    end
    if text then S.nameText[index] = text end
    return text
end

local function NameFromParts(index, number)
    local text = NameText(index)
    if not text then return nil end
    if number and number > 0 then return text .. "_" .. (number - 1) end
    return text
end

-- An FName at an address: ComparisonIndex, then Number.
local function NameAt(address)
    local value = address and address ~= 0 and readQword(address)
    if not value then return nil end
    return NameFromParts(value & 0xFFFFFFFF, (value >> 32) & 0xFFFFFFFF)
end

local function SameName(a, b)
    return a ~= nil and b ~= nil and a:lower() == b:lower()
end

--
--- ∑ Block 0 of FNamePool starts with "None" and "ByteProperty", each behind
--- a two byte header; the pool's Blocks[0] slot points at it and sits 0x10
--- into the pool, inside an image (the executable, or Core in modular builds).
--
local function FindNamePool()
    -- ∑ The pattern starts at "None" rather than at its header: a fixed first
    -- byte lets the scanner skip ahead instead of testing every address.
    for _, text in ipairs(Aob("4E 6F 6E 65 ?? ?? 42 79 74 65 50 72 6F 70 65 72 74 79", 2, 64)) do
        local block = text - 2
        local header = readSmallInteger(block)
        if header and header >> 6 == 4 then
            for _, slot in ipairs(Aob(PointerAob(block), 8, 64)) do
                local pool = slot - NAME_BLOCKS_OFFSET
                if InImage(slot) then
                    local current, cursor = RU(pool + 8), RU(pool + 0xC)
                    if current and cursor and current < NAME_MAX_BLOCKS and cursor < 0x20000 then
                        return pool
                    end
                end
            end
        end
    end
end

local function IsNameEntryArray(chunks, nameOffset)
    local chunk = RP(chunks)
    if not IsPtr(chunk) then return nil end
    local entries = { RP(chunk), RP(chunk + 8), RP(chunk + 16) }
    for _, entry in ipairs(entries) do
        if not IsPtr(entry) then return nil end
    end
    for indexOffset = 0, nameOffset - 4, 4 do
        local matches = true
        for slot = 0, 2 do
            matches = matches and RU(entries[slot + 1] + indexOffset) == slot << 1
        end
        if matches then
            local layout = { index = indexOffset, name = nameOffset }
            if LegacyEntry(entries[2], layout) == "ByteProperty" and LegacyEntry(entries[3], layout) == "IntProperty" then
                return layout
            end
        end
    end
end

--
--- ∑ Before 4.23 every name is its own FNameEntry: Index (slot << 1 |
--- bIsWide), HashNext, then the text. "None" has index 0. From that entry the
--- way back is two pointer scans: the chunk slot that holds it, and the
--- TNameEntryArray whose Chunks[0] holds the chunk.
--
local function FindNameEntryArray()
    for _, nameOffset in ipairs({ 0x10, 0x0C, 0x08 }) do
        local pattern = "00 00 00 00 " .. string.rep("?? ", nameOffset - 4) .. "4E 6F 6E 65 00"
        for _, entry in ipairs(Aob(pattern, 4, 32)) do
            for _, slot in ipairs(Aob(PointerAob(entry), 8, 8)) do
                for _, chunks in ipairs(Aob(PointerAob(slot), 8, 8)) do
                    local layout = IsNameEntryArray(chunks, nameOffset)
                    if layout then return chunks, layout end
                end
            end
        end
    end
end

----------------------------------------
-- OBJECT ARRAY
----------------------------------------

-- Candidate TUObjectArray layouts. The first is the stock
-- FChunkedFixedUObjectArray (4.20+), the last FFixedUObjectArray (4.11-4.19).
local ARRAY_LAYOUTS = {
    { chunked = true, objects = 0x00, max = 0x10, num = 0x14, maxChunks = 0x18, numChunks = 0x1C },
    { chunked = true, objects = 0x10, max = 0x00, num = 0x04, maxChunks = 0x08, numChunks = 0x0C },
    { chunked = true, objects = 0x18, max = 0x10, num = 0x00, maxChunks = 0x14, numChunks = 0x20 },
    { chunked = true, objects = 0x18, max = 0x00, num = 0x14, maxChunks = 0x10, numChunks = 0x04 },
    { chunked = false, objects = 0x00, max = 0x08, num = 0x0C },
}

local function Plausible(data, pos, layout)
    if pos < 1 or pos + 0x27 > #data then return false end
    local objects = string.unpack("<I8", data, pos + layout.objects)
    if not IsPtr(objects) or InImage(objects) then return false end
    local max = string.unpack("<i4", data, pos + layout.max)
    local num = string.unpack("<i4", data, pos + layout.num)
    if num <= MIN_OBJECTS or max < num or max > MAX_OBJECTS then return false end
    if not layout.chunked then return true end
    local maxChunks = string.unpack("<i4", data, pos + layout.maxChunks)
    local numChunks = string.unpack("<i4", data, pos + layout.numChunks)
    if numChunks < 1 or maxChunks < numChunks or maxChunks > MAX_OBJECTS // OBJECTS_PER_CHUNK + 1 then return false end
    return numChunks * OBJECTS_PER_CHUNK >= num and maxChunks * OBJECTS_PER_CHUNK >= max
end

local function VTableIn(object, cache)
    if not IsPtr(object) then return false end
    local known = cache[object]
    if known == nil then
        local vtable = RP(object)
        known = vtable ~= nil and InImage(vtable)
        cache[object] = known
    end
    return known
end

local ITEM_SIZES = { 0x18, 0x10, 0x20, 0x28, 0x30 }

local function ProbeItems(array, layout)
    local objects = RP(array + layout.objects)
    local base = layout.chunked and RP(objects) or objects
    if not IsPtr(base) then return nil end
    local raw = ReadRaw(base, 64 * 0x30)
    if not raw then return nil end
    local cache = {}
    for _, size in ipairs(ITEM_SIZES) do
        for offset = 0, math.min(28, size - 8), 4 do
            local good, seen = 0, {}
            for i = 0, 63 do
                local object = string.unpack("<I8", raw, 1 + i * size + offset)
                if not seen[object] and VTableIn(object, cache) then
                    good, seen[object] = good + 1, true
                end
            end
            if good >= 56 then return size, offset end
        end
    end
end

local function FirstObjects(array, layout, size, offset)
    local objects = RP(array + layout.objects)
    local base = layout.chunked and RP(objects) or objects
    local raw = base and ReadRaw(base, 64 * size)
    if not raw then return nil end
    local list = {}
    for i = 0, 63 do
        local object = string.unpack("<I8", raw, 1 + i * size + offset)
        local header = IsPtr(object) and ReadRaw(object, 0x48)
        list[i] = { address = object, header = header }
    end
    return list
end

local function HeaderInt(entry, offset)
    if not entry.header then return nil end
    return string.unpack("<i4", entry.header, offset + 1)
end

local function HeaderName(entry, offset)
    if not entry.header then return nil end
    local index, number = string.unpack("<I4I4", entry.header, offset + 1)
    return NameFromParts(index, number)
end

local function FindIndexOffset(first)
    for _, offset in ipairs({ 0x0C, 0x08, 0x10, 0x14, 0x04, 0x18, 0x1C, 0x20 }) do
        local hits = 0
        for i = 0, 63 do
            if HeaderInt(first[i], offset) == i then hits = hits + 1 end
        end
        if hits >= 58 then return offset end
    end
end

--
--- ∑ The first objects are the CoreUObject package and its classes. At the
--- right offset their names decode, are mostly distinct, and include
--- "/Script/CoreUObject" or "Object". Garbage occasionally decodes as well,
--- so the anchor and the distinctness are both required.
--
local function Overlaps(a, aWidth, b, bWidth)
    return a < b + bWidth and b < a + aWidth
end

local function FindNameOffset(first, skip)
    local candidates = { 0x18 }
    for offset = 0x08, 0x40, 4 do candidates[#candidates + 1] = offset end
    for _, offset in ipairs(candidates) do
        if not Overlaps(offset, 8, skip, 4) then
            local decoded, anchor, distinct, seen = 0, false, 0, {}
            for i = 0, 63 do
                local name = HeaderName(first[i], offset)
                if name then
                    decoded = decoded + 1
                    anchor = anchor or name == "/Script/CoreUObject" or name == "Object"
                    if not seen[name] then seen[name], distinct = true, distinct + 1 end
                end
            end
            if anchor and decoded >= 58 and distinct * 4 >= decoded * 3 then return offset end
        end
    end
end

local function LiveLayout(array, layout)
    local size, offset = ProbeItems(array, layout)
    if not size then return nil end
    local first = FirstObjects(array, layout, size, offset)
    if not first then return nil end
    local index = FindIndexOffset(first)
    if not index then return nil end
    local name = FindNameOffset(first, index)
    if not name then return nil end
    return { array = array, layout = layout, itemSize = size, itemOffset = offset, index = index, name = name, first = first }
end

-- ∑ Lua pattern for the stock layout's counters at +0x10: MaxElements and
-- NumElements below 2^29, MaxChunks below 0x1100, NumChunks 1-255. It lets
-- string.find, running in C, skip everything that cannot be the array.
local STOCK_COUNTERS = "...[\0-\16]...[\0-\16].[\0-\16]\0\0[\1-\255]\0\0\0"

local function ScanSection(section, generic)
    local stop = section.from + section.size
    for at = section.from, stop - 0x28, SECTION_STEP do
        local length = math.min(SECTION_STEP + 0x40, stop - at)
        local data = ReadRaw(at, length)
        if data then
            if generic then
                for pos = 1, math.min(SECTION_STEP, #data - 0x27), 8 do
                    for _, layout in ipairs(ARRAY_LAYOUTS) do
                        if Plausible(data, pos, layout) then
                            local live = LiveLayout(at + pos - 1, layout)
                            if live then return live end
                        end
                    end
                end
            else
                local pos = 1
                while true do
                    local hit = data:find(STOCK_COUNTERS, pos)
                    if not hit then break end
                    local header = hit - 0x10
                    if header >= 1 and header <= SECTION_STEP and (at + header - 1) % 8 == 0 and Plausible(data, header, ARRAY_LAYOUTS[1]) then
                        local live = LiveLayout(at + header - 1, ARRAY_LAYOUTS[1])
                        if live then return live end
                    end
                    pos = hit + 1
                end
            end
        end
    end
end

local function ExportedObjectArray()
    for _, image in ipairs(S.images) do
        if image.name:find("%-CoreUObject") then
            for _, symbol in ipairs({ "?GUObjectArray@@3VFUObjectArray@@A", "GUObjectArray" }) do
                local ok, address = pcall(getAddressSafe, '"' .. image.name .. '"!' .. symbol)
                if ok and address and address ~= 0 then
                    for offset = 0, 0x50, 8 do
                        for _, layout in ipairs(ARRAY_LAYOUTS) do
                            local data = ReadRaw(address + offset, 0x28)
                            if data and Plausible(data, 1, layout) then
                                local live = LiveLayout(address + offset, layout)
                                if live then return live end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function FindObjectArray()
    local live = ExportedObjectArray()
    if live then return live, "export" end
    local images = {}
    for _, image in ipairs(S.images) do
        if image == S.main or image.name:find("%-CoreUObject") or image.name:find("%-Core%-") then
            images[#images + 1] = image
        end
    end
    for _, generic in ipairs({ false, true }) do
        for _, image in ipairs(images) do
            for _, section in ipairs(Sections(image, true)) do
                live = ScanSection(section, generic)
                if live then return live, generic and "data scan (generic)" or "data scan" end
            end
        end
    end
end

local L = {}

local function Count()
    local count = RI(S.array + L.layout.num)
    if not count or count < 0 or count > MAX_OBJECTS then return 0 end
    return count
end

local function ChunkTable()
    return RP(S.array + L.layout.objects)
end

local function Chunk(index)
    local chunk = S.chunks[index]
    if chunk then return chunk end
    local table = ChunkTable()
    chunk = table and RP(table + index * 8)
    if IsPtr(chunk) then S.chunks[index] = chunk end
    return chunk
end

local function ItemAddress(index)
    if L.layout.chunked then
        local chunk = Chunk(index // OBJECTS_PER_CHUNK)
        return chunk and chunk + (index % OBJECTS_PER_CHUNK) * L.itemSize
    end
    local items = ChunkTable()
    return items and items + index * L.itemSize
end

local function ObjectAt(index)
    if not index or index < 0 then return nil end
    local item = ItemAddress(index)
    local object = item and RP(item + L.itemOffset)
    return IsPtr(object) and object or nil
end

--
--- ∑ Calls fn(object, index) for every live object and stops when fn
--- returns true. Items are read 0x1000 at a time as raw blocks; a block
--- never crosses a chunk because 0x1000 divides the chunk size.
--
local function Each(fn)
    local count = Count()
    for first = 0, count - 1, RAW_BLOCK_OBJECTS do
        local n = math.min(RAW_BLOCK_OBJECTS, count - first)
        local base = ItemAddress(first)
        local raw = base and ReadRaw(base, n * L.itemSize)
        if raw then
            for i = 0, n - 1 do
                local object = string.unpack("<I8", raw, 1 + i * L.itemSize + L.itemOffset)
                if IsPtr(object) and fn(object, first + i) then return object end
            end
        end
    end
end

local function IsObject(address, count)
    if not IsPtr(address) then return false end
    local index = RI(address + L.index)
    if not index or index < 0 or index >= (count or Count()) then return false end
    return ObjectAt(index) == address
end

local function ClassOf(object) return RP(object + L.class) end
local function OuterOf(object) return RP(object + L.outer) end
local function NameOf(object) return object and NameAt(object + L.name) end

----------------------------------------
-- LAYOUT
----------------------------------------

local function ResolveClassAndOuter(first)
    local objectClass, package
    for i = 0, 63 do
        local name = HeaderName(first[i], L.name)
        if name == "Object" and not objectClass then objectClass = first[i].address end
        if name == "/Script/CoreUObject" and not package then package = first[i].address end
    end
    if not objectClass or not package then return false end
    for _, offset in ipairs({ 0x10, 0x08, 0x18, 0x20, 0x28, 0x30, 0x38 }) do
        if not Overlaps(offset, 8, L.name, 8) and not Overlaps(offset, 8, L.index, 4) then
            local meta, packageMeta = RP(objectClass + offset), RP(package + offset)
            if IsPtr(meta) and IsPtr(packageMeta) and NameAt(meta + L.name) == "Class" and NameAt(packageMeta + L.name) == "Package" then
                L.class = offset
                break
            end
        end
    end
    if not L.class then return false end
    for _, offset in ipairs({ 0x20, 0x28, 0x18, 0x10, 0x30, 0x38, 0x40 }) do
        if not Overlaps(offset, 8, L.name, 8) and offset ~= L.class and RP(objectClass + offset) == package then
            L.outer = offset
            break
        end
    end
    return L.outer ~= nil
end

local META_CLASS = { ["class"] = true, dynamicclass = true }
local META_STRUCT = { scriptstruct = true, userdefinedstruct = true }
local META_ENUM = { enum = true, userdefinedenum = true }

local function MetaKind(meta)
    local kind = S.kinds[meta]
    if kind ~= nil then return kind end
    local name = (NameOf(meta) or ""):lower()
    if META_CLASS[name] or name:sub(-14) == "generatedclass" then kind = "class"
    elseif META_STRUCT[name] then kind = "struct"
    elseif META_ENUM[name] then kind = "enum"
    elseif name == "function" or name == "delegatefunction" or name == "sparsedelegatefunction" then kind = "function"
    else kind = false end
    S.kinds[meta] = kind
    return kind
end

local function IndexTypes()
    S.types, S.typeList, S.enumsByName = {}, {}, {}
    Each(function(object)
        local meta = ClassOf(object)
        local kind = IsPtr(meta) and MetaKind(meta)
        if kind == "class" or kind == "struct" or kind == "enum" then
            local name = NameOf(object)
            if name then
                local key = name:lower()
                if kind == "enum" then
                    S.enumsByName[key] = S.enumsByName[key] or object
                else
                    S.types[key] = S.types[key] or object
                end
                S.typeList[#S.typeList + 1] = { name = name, object = object, kind = kind }
            end
        end
    end)
    table.sort(S.typeList, function(a, b) return a.name:lower() < b.name:lower() end)
end

local function Type(name)
    return name and S.types[name:lower()]
end

local function ProbeSuper()
    local struct, field, object, class = Type("Struct"), Type("Field"), Type("Object"), Type("Class")
    if not struct or not field or not object or not class then return false end
    for offset = L.outer + 8, 0x80, 8 do
        if RP(struct + offset) == field and RP(field + offset) == object and RP(class + offset) == struct then
            L.super = offset
            return true
        end
    end
    return false
end

local function FieldClassName(field)
    local class = RP(field + L.fieldClass)
    return class and NameAt(class) or nil
end

local function ProbePropertyFields(x, y, z)
    for offset = 0x20, 0x90, 4 do
        local a, b, c = RI(x + offset), RI(y + offset), RI(z + offset)
        if a == 0 and (b == 4 or b == 8) and c == b * 2 then
            L.offset, L.component = offset, b
            for size = 0x24, offset - 4, 4 do
                if RI(x + size) == b and RI(y + size) == b and RI(z + size) == b and RI(x + size - 4) == 1 then
                    L.size = size
                    break
                end
            end
            return L.size ~= nil
        end
    end
    return false
end

--
--- ∑ ScriptStruct "Vector" always holds exactly X, Y and Z. Finding that
--- chain pins the property list offset, the field name and next offsets and,
--- through the member offsets 0/4/8 or 0/8/16, Offset_Internal and whether
--- the engine uses double math types (UE5).
--
local function ProbeChain()
    local vector = Type("Vector")
    if not vector then return false end
    for list = L.super + 8, L.super + 0x48, 8 do
        local x = RP(vector + list)
        if IsPtr(x) then
            for name = 8, 0x40, 4 do
                if NameAt(x + name) == "X" then
                    for nxt = 8, 0x48, 8 do
                        if not (nxt + 8 > name and nxt < name + 8) then
                            local y = RP(x + nxt)
                            local z = IsPtr(y) and NameAt(y + name) == "Y" and RP(y + nxt)
                            if IsPtr(z) and NameAt(z + name) == "Z" then
                                L.list, L.fieldName, L.next = list, name, nxt
                                local meta = ClassOf(x)
                                L.fField = not (name == L.name and IsPtr(meta) and (NameOf(meta) or ""):find("Property$"))
                                if L.fField then
                                    for class = 8, name - 8, 8 do
                                        local fieldClass = RP(x + class)
                                        if IsPtr(fieldClass) and (NameAt(fieldClass) or ""):find("Property$") then
                                            L.fieldClass = class
                                            break
                                        end
                                    end
                                    if not L.fieldClass then return false end
                                end
                                return ProbePropertyFields(x, y, z)
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

local function TypeOf(field)
    if L.fField then return FieldClassName(field) end
    local meta = ClassOf(field)
    return meta and NameOf(meta) or nil
end

local function ProbeStructSize()
    local c = L.component
    local known = { Vector = 3 * c, Vector2D = 2 * c, LinearColor = 16, IntPoint = 8 }
    for offset = L.list + 8, L.list + 0x40, 4 do
        local ok = true
        for name, size in pairs(known) do
            local struct = Type(name)
            ok = ok and struct ~= nil and RI(struct + offset) == size
        end
        if ok then
            L.structSize = offset
            return
        end
    end
end

local function StructSize(struct)
    if not struct or not L.structSize then return nil end
    local size = RI(struct + L.structSize)
    return size and size > 0 and size < 0x1000000 and size or nil
end

local function FindRawField(struct, wanted)
    local field, guard = RP(struct + L.list), 0
    while IsPtr(field) and guard < MAX_FIELDS do
        if SameName(NameAt(field + L.fieldName), wanted) then return field end
        field, guard = RP(field + L.next), guard + 1
    end
end

local function FieldIn(class, wanted)
    for _ = 1, MAX_SUPER_DEPTH do
        if not IsPtr(class) then return nil end
        local field = FindRawField(class, wanted)
        if field then return field end
        class = RP(class + L.super)
    end
end

-- ∑ FObjectProperty::PropertyClass and FStructProperty::Struct share the
-- first slot behind the property base: Actor.RootComponent points at the
-- SceneComponent class there, SceneComponent.RelativeLocation at Vector.
local function ProbeExtra()
    local scene, vector = Type("SceneComponent"), Type("Vector")
    local root = FieldIn(Type("Actor"), "RootComponent")
    local location = FieldIn(scene, "RelativeLocation")
    if not root or not location then return end
    for offset = (L.offset + 4 + 7) & ~7, 0x100, 8 do
        if RP(root + offset) == scene and RP(location + offset) == vector then
            L.extra = offset
            return
        end
    end
end

local function IsChildOf(struct, base)
    for _ = 1, MAX_SUPER_DEPTH do
        if not IsPtr(struct) then return false end
        if struct == base then return true end
        struct = RP(struct + L.super)
    end
    return false
end

local function IsFunction(object)
    local meta = IsPtr(object) and ClassOf(object)
    return meta and MetaKind(meta) == "function" or false
end

local FUNC_EXEC, FUNC_NATIVE, FUNC_EVENT, FUNC_STATIC, FUNC_BLUEPRINT_EVENT = 0x200, 0x400, 0x800, 0x2000, 0x08000000

--
--- ∑ UStruct::Children holds the UFunctions (and, before 4.25, the
--- properties too). Its offset and UField::Next are pinned by classes that
--- declare functions in every engine version; FunctionFlags by functions
--- whose declarations imply their flags.
--
local function ProbeFunctions()
    local samples = {}
    for _, name in ipairs({ "Actor", "Pawn", "PlayerController", "GameplayStatics", "KismetSystemLibrary" }) do
        local class = Type(name)
        if class then samples[#samples + 1] = class end
    end
    local function countFunctions(owner, head, nxt)
        local functions, guard, field = 0, 0, head
        while IsPtr(field) and guard < MAX_FIELDS do
            if OuterOf(field) ~= owner then return -1 end
            if IsFunction(field) then functions = functions + 1
            elseif L.fField then return -1 end
            field, guard = RP(field + nxt), guard + 1
        end
        return guard < MAX_FIELDS and functions or -1
    end
    if not L.fField then
        L.children, L.childNext = L.list, L.next
    else
        for children = 0x28, 0x100, 8 do
            if children ~= L.list and children ~= L.super then
                for nxt = 0x28, 0x40, 8 do
                    local chains, foreign = 0, false
                    for _, class in ipairs(samples) do
                        local n = countFunctions(class, RP(class + children), nxt)
                        foreign = foreign or n < 0
                        if n >= 2 then chains = chains + 1 end
                    end
                    if not foreign and chains >= 2 then
                        L.children, L.childNext = children, nxt
                        break
                    end
                end
            end
            if L.children then break end
        end
    end
    if not L.children then return end

    local function findFunction(owner, name)
        local class = Type(owner)
        local field, guard = class and RP(class + L.children), 0
        while IsPtr(field) and guard < MAX_FIELDS do
            if SameName(NameOf(field), name) and IsFunction(field) then return field end
            field, guard = RP(field + L.childNext), guard + 1
        end
    end
    local expectations = {}
    local function expect(owner, name, set, clear)
        local fn = findFunction(owner, name)
        if fn then expectations[#expectations + 1] = { fn = fn, set = set, clear = clear } end
        return fn ~= nil
    end
    if not expect("PlayerController", "EnableCheats", FUNC_EXEC | FUNC_NATIVE, FUNC_STATIC) then
        expect("PlayerController", "FOV", FUNC_EXEC | FUNC_NATIVE, FUNC_STATIC)
    end
    expect("KismetSystemLibrary", "ExecuteConsoleCommand", FUNC_STATIC | FUNC_NATIVE, FUNC_EXEC)
    expect("GameplayStatics", "SpawnObject", FUNC_STATIC | FUNC_NATIVE, FUNC_EXEC)
    expect("Actor", "ReceiveBeginPlay", FUNC_EVENT | FUNC_BLUEPRINT_EVENT, FUNC_NATIVE)
    if #expectations < 3 then return end
    local first = L.structSize and L.structSize + 4 or 0x40
    for offset = first, 0x200, 4 do
        local all = true
        for _, e in ipairs(expectations) do
            local flags = RU(e.fn + offset)
            all = all and flags ~= nil and flags & e.set == e.set and flags & e.clear == 0
        end
        if all then
            L.functionFlags = offset
            break
        end
    end
end

----------------------------------------
-- TYPES AND FIELDS
----------------------------------------

local OBJECT_KINDS = {
    ObjectProperty = true, ObjectPtrProperty = true, ClassProperty = true, ClassPtrProperty = true,
}
local INNER_AT_EXTRA = {
    ObjectProperty = true, ObjectPtrProperty = true, ClassProperty = true, ClassPtrProperty = true,
    WeakObjectProperty = true, LazyObjectProperty = true, SoftObjectProperty = true, SoftClassProperty = true,
    StructProperty = true, ByteProperty = true, InterfaceProperty = true,
    DelegateProperty = true, MulticastDelegateProperty = true, MulticastInlineDelegateProperty = true,
    MulticastSparseDelegateProperty = true,
}

local Describe

local function InnerProperty(field, slot)
    local inner = RP(field + slot)
    if IsPtr(inner) then
        local kind = TypeOf(inner)
        if kind and kind:find("Property$") then return inner, kind end
    end
end

function Describe(field, kind, owner)
    local info = {
        address = field, type = kind, owner = owner,
        name = NameAt(field + L.fieldName) or "?",
        offset = RI(field + L.offset) or 0,
        size = RI(field + L.size) or 0,
        dim = RI(field + L.size - 4) or 1,
    }
    info.flags = readQword(field + L.size + 4) or 0
    if info.dim < 1 or info.dim > 0x10000 then info.dim = 1 end
    local extra = L.extra
    if not extra then return info end
    if kind == "BoolProperty" then
        local bits = ReadRaw(field + extra, 4)
        if bits then
            local fieldSize, byteOffset, byteMask, fieldMask = bits:byte(1, 4)
            if (fieldSize == 1 or fieldSize == 2 or fieldSize == 4 or fieldSize == 8) and byteOffset < fieldSize and byteMask ~= 0 then
                info.byteOffset, info.mask, info.fieldMask = byteOffset, byteMask, fieldMask
            end
        end
    elseif kind == "EnumProperty" then
        info.inner = RPtr(field + extra + 8)
        info.underlying = InnerProperty(field, extra)
    elseif kind == "ArrayProperty" or kind == "SetProperty" then
        info.innerProp, info.innerType = InnerProperty(field, extra)
        if not info.innerProp then info.innerProp, info.innerType = InnerProperty(field, extra + 8) end
    elseif kind == "MapProperty" then
        local slot = extra
        info.innerProp, info.innerType = InnerProperty(field, slot)
        if not info.innerProp then
            slot = extra + 8
            info.innerProp, info.innerType = InnerProperty(field, slot)
        end
        if info.innerProp then info.valueProp, info.valueType = InnerProperty(field, slot + 8) end
    elseif INNER_AT_EXTRA[kind] then
        info.inner = RPtr(field + extra)
        if kind == "ClassProperty" or kind == "ClassPtrProperty" or kind == "SoftClassProperty" then
            info.metaClass = RPtr(field + extra + 8)
        end
    end
    return info
end

local function OwnFields(struct)
    local cached = S.own[struct]
    if cached then return cached end
    local out, field, guard = {}, RP(struct + L.list), 0
    local owner = NameOf(struct) or "?"
    while IsPtr(field) and guard < MAX_FIELDS do
        local kind = TypeOf(field)
        if kind and kind:find("Property$") then out[#out + 1] = Describe(field, kind, owner) end
        field, guard = RP(field + L.next), guard + 1
    end
    S.own[struct] = out
    return out
end

local function SortFields(list)
    table.sort(list, function(a, b)
        local ao, bo = a.offset + (a.byteOffset or 0), b.offset + (b.byteOffset or 0)
        if ao ~= bo then return ao < bo end
        return (a.mask or 0) < (b.mask or 0)
    end)
    return list
end

-- Own and inherited properties of a class or struct, sorted by offset.
local function Fields(struct, ownOnly)
    if not IsPtr(struct) then return {} end
    if ownOnly then return SortFields({ table.unpack(OwnFields(struct)) }) end
    local cached = S.merged[struct]
    if cached then return cached end
    local out, current = {}, struct
    for _ = 1, MAX_SUPER_DEPTH do
        if not IsPtr(current) then break end
        for _, f in ipairs(OwnFields(current)) do out[#out + 1] = f end
        current = RP(current + L.super)
    end
    S.merged[struct] = SortFields(out)
    return S.merged[struct]
end

local function FindField(struct, name)
    for _, f in ipairs(Fields(struct)) do
        if SameName(f.name, name) then return f end
    end
end

local function SuperOf(struct) return IsPtr(struct) and RPtr(struct + L.super) or nil end

-- C++ spelling of a type: F for structs, A for actors, U for other classes.
local function CppName(type)
    if not IsPtr(type) then return "?" end
    local cached = S.cpp[type]
    if cached then return cached end
    local name = NameOf(type) or "?"
    local kind = MetaKind(ClassOf(type) or 0)
    local text
    if kind == "struct" then text = "F" .. name
    elseif kind == "enum" then text = name
    elseif kind == "class" then text = (IsChildOf(type, Type("Actor") or 0) and "A" or "U") .. name
    else text = name end
    S.cpp[type] = text
    return text
end

local SCALAR_TEXT = {
    FloatProperty = "float", DoubleProperty = "double", IntProperty = "int32", Int8Property = "int8",
    Int16Property = "int16", Int64Property = "int64", UInt16Property = "uint16", UInt32Property = "uint32",
    UInt64Property = "uint64", NameProperty = "FName", StrProperty = "FString", TextProperty = "FText",
    BoolProperty = "bool", FieldPathProperty = "TFieldPath", Utf8StrProperty = "FUtf8String",
    AnsiStrProperty = "FAnsiString",
}

local TypeText

local function PropertyTypeText(field, kind)
    if not field then return "?" end
    return TypeText(Describe(field, kind or TypeOf(field), nil))
end

function TypeText(info)
    local kind = info.type
    if SCALAR_TEXT[kind] then return SCALAR_TEXT[kind] end
    if kind == "ByteProperty" then return info.inner and CppName(info.inner) or "uint8" end
    if kind == "EnumProperty" then return info.inner and CppName(info.inner) or "enum" end
    if OBJECT_KINDS[kind] then
        if (kind == "ClassProperty" or kind == "ClassPtrProperty") and info.metaClass then
            return "TSubclassOf<" .. CppName(info.metaClass) .. ">"
        end
        return (info.inner and CppName(info.inner) or "UObject") .. "*"
    end
    if kind == "WeakObjectProperty" then return "TWeakObjectPtr<" .. (info.inner and CppName(info.inner) or "UObject") .. ">" end
    if kind == "LazyObjectProperty" then return "TLazyObjectPtr<" .. (info.inner and CppName(info.inner) or "UObject") .. ">" end
    if kind == "SoftObjectProperty" then return "TSoftObjectPtr<" .. (info.inner and CppName(info.inner) or "UObject") .. ">" end
    if kind == "SoftClassProperty" then return "TSoftClassPtr<" .. (info.metaClass and CppName(info.metaClass) or "UObject") .. ">" end
    if kind == "InterfaceProperty" then return "TScriptInterface<" .. (info.inner and CppName(info.inner) or "IInterface") .. ">" end
    if kind == "StructProperty" then return info.inner and CppName(info.inner) or "struct" end
    if kind == "ArrayProperty" then return "TArray<" .. PropertyTypeText(info.innerProp, info.innerType) .. ">" end
    if kind == "SetProperty" then return "TSet<" .. PropertyTypeText(info.innerProp, info.innerType) .. ">" end
    if kind == "MapProperty" then
        return "TMap<" .. PropertyTypeText(info.innerProp, info.innerType) .. ", " .. PropertyTypeText(info.valueProp, info.valueType) .. ">"
    end
    if kind == "DelegateProperty" then return "FScriptDelegate" end
    if kind and kind:find("MulticastDelegate") then return "FMulticastDelegate" end
    return (kind or "?"):gsub("Property$", "")
end

--
--- ∑ UEnum::Names (TArray<TPair<FName, int64>>) follows the UField header;
--- UHT ends almost every enum with a generated "..._MAX" entry, which tells
--- the array apart from the fields around it.
--
local function EnumEntries(enum)
    if not IsPtr(enum) then return {} end
    local cached = S.enums[enum]
    if cached then return cached end
    local entries = {}
    for offset = 0x28, 0x80, 8 do
        local data, count, max = RP(enum + offset), RI(enum + offset + 8), RI(enum + offset + 0xC)
        if IsPtr(data) and count and max and count > 0 and count <= 4096 and max >= count then
            local last = NameAt(data + (count - 1) * 16) or ""
            if last:upper():sub(-3) == "MAX" then
                for i = 0, count - 1 do
                    local entry = data + i * 16
                    entries[#entries + 1] = { name = NameAt(entry) or "?", value = readQword(entry + 8) or 0 }
                end
                break
            end
        end
    end
    S.enums[enum] = entries
    return entries
end

local function Functions(class, inherited)
    local out = {}
    if not L.children then return out end
    local current = class
    for _ = 1, MAX_SUPER_DEPTH do
        if not IsPtr(current) then break end
        local owner = NameOf(current) or "?"
        local field, guard = RP(current + L.children), 0
        while IsPtr(field) and guard < MAX_FIELDS do
            if IsFunction(field) then
                out[#out + 1] = {
                    name = NameOf(field) or "?", owner = owner, address = field,
                    flags = L.functionFlags and RU(field + L.functionFlags) or 0,
                    params = OwnFields(field),
                }
            end
            field, guard = RP(field + L.childNext), guard + 1
        end
        if not inherited then break end
        current = RP(current + L.super)
    end
    return out
end

----------------------------------------
-- RESOLVE
----------------------------------------

local function RegisterCoreSymbols()
    RegisterOwnSymbol("GObjects", S.array)
    RegisterOwnSymbol(S.nameKind == "pool" and "FNamePool" or "GNames", S.pool)
    if S.engine then RegisterOwnSymbol("GameEngine", S.engine) end
end

local FindEngine

--
--- ∑ The whole resolution, in the order the DLL does it: name table, object
--- array, UObject layout, type index, reflection layout. Every stage that
--- fails says which one, so a broken game is a one-line report, not a
--- silent "nothing found".
--
local function Resolve(full)
    local started = os.clock()
    local timings, mark = {}, started
    local function stage(name)
        local now = os.clock()
        timings[#timings + 1] = string.format("%s %.2f s", name, now - mark)
        mark = now
    end
    LoadImages()
    if not S.main then error("no process is opened") end
    if not targetIs64Bit() then error("only 64-bit games are supported") end
    if not full and not UnrealProcess() then error("not an Unreal Engine process (no CoreUObject in " .. S.main.name .. ")") end

    S.pool, S.nameKind = FindNamePool(), "pool"
    if not S.pool then
        if not full and not UnrealProcess() then error("not an Unreal Engine process (no FNamePool)") end
        local chunks, layout = FindNameEntryArray()
        if not chunks then error("name table not found: neither FNamePool (UE 4.23+) nor TNameEntryArray (UE 4.22 and older)") end
        S.pool, S.nameKind, S.legacy = chunks, "legacy", layout
    end
    stage("names")

    local live, source = FindObjectArray()
    if not live then error("object array (GObjects) not found") end
    S.array, S.arraySource = live.array, source
    L = { layout = live.layout, itemSize = live.itemSize, itemOffset = live.itemOffset, index = live.index, name = live.name }
    if not ResolveClassAndOuter(live.first) then error("UObject class and outer offsets not found") end
    stage("objects")

    IndexTypes()
    stage("types")
    for _, required in ipairs({ "Object", "Field", "Struct", "Class" }) do
        if not Type(required) then error("core class '" .. required .. "' not found among " .. #S.typeList .. " types") end
    end
    if not ProbeSuper() then error("UStruct::SuperStruct offset not found") end
    if not ProbeChain() then error("property chain of ScriptStruct 'Vector' not found") end
    ProbeStructSize()
    ProbeExtra()
    ProbeFunctions()
    stage("layout")

    S.ready, S.failed = true, nil
    S.engine = FindEngine and FindEngine() or nil
    RegisterCoreSymbols()
    stage("engine")
    S.seconds = os.clock() - started
    Log("Resolve", string.format("%s at %X (%s) | GObjects at %X (%s) | %d objects, %d types | %.1f s (%s)",
        S.nameKind == "pool" and "FNamePool" or "GNames", S.pool, S.nameKind == "pool" and "4.23+" or "pre-4.23",
        S.array, source, Count(), #S.typeList, S.seconds, table.concat(timings, ", ")))
    Log("Resolve", string.format("UObject index %X class %X name %X outer %X | Super %X Properties %X Name %X Next %X Offset %X Size %X Extra %s | %s fields, %s vectors",
        L.index, L.class, L.name, L.outer, L.super, L.list, L.fieldName, L.next, L.offset, L.size, L.extra and Hex(L.extra) or "-",
        L.fField and "FField" or "UProperty", L.component == 8 and "double" or "float"))
end

local function Ready(auto, full)
    Session()
    if S.ready then return true end
    if S.pid == 0 then return false end
    if S.failed and not full then return false end
    if not auto and not full then return false end
    local ok, err = pcall(Resolve, full)
    if not ok then
        S.ready, S.failed = false, tostring(err):gsub("^.-:%d+: ", "")
        Log("Resolve", "Unreal Engine not resolved: " .. S.failed)
        return false
    end
    return true
end

local function Require()
    if not Ready(true, true) then error("Unreal Engine is not resolved: " .. tostring(S and S.failed or "no process"), 2) end
end

----------------------------------------
-- OBJECTS
----------------------------------------

local function IsDefaultObject(object)
    return (NameOf(object) or ""):sub(1, 9) == "Default__"
end

local function FullName(object)
    local parts, current = {}, object
    for _ = 1, 32 do
        if not IsPtr(current) then break end
        table.insert(parts, 1, NameOf(current) or "?")
        current = OuterOf(current)
    end
    return table.concat(parts, ".")
end

local function Instances(class, limit)
    local seen, out = {}, {}
    if not IsPtr(class) then return out end
    Each(function(object)
        local meta = ClassOf(object)
        if meta then
            local match = seen[meta]
            if match == nil then
                match = IsChildOf(meta, class)
                seen[meta] = match
            end
            if match and not IsDefaultObject(object) then
                out[#out + 1] = object
                return limit and #out >= limit
            end
        end
    end)
    return out
end

--
--- ∑ The object an address belongs to. Objects carry their own index, so an
--- object start is confirmed with two reads: its index, and the array slot
--- of that index pointing back at it. Walking back from the address finds the
--- closest start; it contains the address if the class is large enough.
--
local function OwnerOf(address)
    if not IsPtr(address - address % 8) then return nil end
    local start = address - address % 8
    local stop = math.max(start - OWNER_WINDOW, POINTER_MIN)
    local count = Count()
    for candidate = start, stop, -8 do
        if IsObject(candidate, count) then
            local class = ClassOf(candidate)
            local size = StructSize(class)
            if size and address < candidate + size then return candidate, class end
            return nil
        end
    end
    local best = 0
    Each(function(object)
        if object <= address and object > best then best = object end
    end)
    if best ~= 0 then
        local class = ClassOf(best)
        local size = StructSize(class)
        if size and address < best + size then return best, class end
    end
end

-- The innermost reflected field at base + offset of a struct, as a path.
-- `found.struct` is the outermost struct property that starts right there.
local function Descend(struct, offset, path, depth, found)
    for _, f in ipairs(Fields(struct)) do
        local elementSize = math.max(1, f.size)
        local total = elementSize * math.max(1, f.dim)
        local start = f.offset + (f.byteOffset or 0)
        local width = f.mask and 1 or total
        if offset >= start and offset < start + width then
            local index = f.mask and 0 or (offset - f.offset) // elementSize
            local within = f.mask and 0 or offset - f.offset - index * elementSize
            local segment = f.name .. (f.dim > 1 and "[" .. index .. "]" or "")
            if f.mask and f.fieldMask ~= 0xFF then segment = segment .. string.format(" (bit mask %02X)", f.mask) end
            path[#path + 1] = segment
            if f.type == "StructProperty" and f.inner and depth < 12 then
                if within == 0 and found and not found.struct then found.struct = f.inner end
                return Descend(f.inner, within, path, depth + 1, found)
            end
            return f, within, struct
        end
    end
    path[#path + 1] = string.format("+%X (not reflected)", offset)
    return nil, offset, struct
end

local function HeaderField(offset)
    local fields = { { 0, 8, "VTable" }, { L.index, 4, "InternalIndex" }, { L.class, 8, "ClassPrivate" }, { L.name, 8, "NamePrivate" }, { L.outer, 8, "OuterPrivate" } }
    if L.index == 0x0C then fields[#fields + 1] = { 0x08, 4, "ObjectFlags" } end
    for _, f in ipairs(fields) do
        if offset >= f[1] and offset < f[1] + f[2] then return f[3], offset - f[1] end
    end
end

local function Locate(address)
    local object, class = OwnerOf(address)
    if not object then return nil end
    local path, found = {}, {}
    local field, within = nil, 0
    local header, inside = HeaderField(address - object)
    if header then
        path[1] = header .. (inside > 0 and string.format(" +%X", inside) or "")
    elseif address ~= object then
        field, within = Descend(class, address - object, path, 0, found)
    end
    return { object = object, class = class, path = path, field = field, within = within, struct = found.struct }
end

local function Whois(address)
    local hit = Locate(address)
    if not hit then return nil end
    local text = string.format("%s (%s) +%X", NameOf(hit.object) or "?", CppName(hit.class), address - hit.object)
    if #hit.path > 0 then text = text .. ": " .. table.concat(hit.path, ".") end
    if hit.field then text = text .. "  " .. TypeText(hit.field) .. (hit.within > 0 and string.format(" +%X", hit.within) or "") end
    return text, hit
end

----------------------------------------
-- WORLD
----------------------------------------

function FindEngine()
    for _, name in ipairs({ "GameEngine", "Engine" }) do
        local found = Instances(Type(name), 1)[1]
        if found then return found end
    end
end

local function Engine()
    Require()
    if not IsObject(S.engine or 0) then
        S.engine = FindEngine()
        if S.engine then RegisterOwnSymbol("GameEngine", S.engine) end
    end
    return S.engine
end

local function Follow(object, ...)
    local current = object
    for _, step in ipairs({ ... }) do
        if not IsPtr(current) then return nil end
        local name, index = step:match("^(.-)%[(%d+)%]$")
        local f = FindField(ClassOf(current), name or step)
        if not f then return nil end
        local slot = current + f.offset
        if f.type == "ArrayProperty" and index then
            local data = RP(slot)
            slot = data and data + tonumber(index) * 8
        end
        current = slot and RP(slot)
    end
    return IsPtr(current) and current or nil
end

local PAWN_PATH = { "GameViewport", "World", "OwningGameInstance", "LocalPlayers[0]", "PlayerController", "AcknowledgedPawn" }

local function World() return Follow(Engine(), "GameViewport", "World") end
local function Controller() return Follow(Engine(), "GameViewport", "World", "OwningGameInstance", "LocalPlayers[0]", "PlayerController") end
local function Pawn()
    local controller = Controller()
    return controller and (Follow(controller, "AcknowledgedPawn") or Follow(controller, "Pawn"))
end

----------------------------------------
-- CUSTOM TYPES
----------------------------------------

local function BytesToInteger(bytes, first, count)
    local value = 0
    for i = count - 1, 0, -1 do value = (value << 8) | (bytes[first + i] or 0) end
    return value
end

-- ∑ The custom types are registered once per Cheat Engine run and call into
-- State, so a reload replaces their behaviour without a second registration.
-- They never start a resolve themselves: they run for every visible value.
local function Resolved()
    Session()
    return S.ready
end

State.CustomFName = function(bytes)
    if not Resolved() then return "(Unreal Engine not resolved)" end
    return NameFromParts(BytesToInteger(bytes, 1, 4), BytesToInteger(bytes, 5, 4)) or "(no name)"
end

State.CustomFString = function(bytes)
    if not Resolved() then return "(Unreal Engine not resolved)" end
    local data, num = BytesToInteger(bytes, 1, 8), BytesToInteger(bytes, 9, 4)
    if num == 0 or data == 0 then return "" end
    if not IsPtr(data) or num > 0x10000 then return "(not a string)" end
    local length = math.min(num - 1, 512)
    if length <= 0 then return "" end
    local raw = readBytes(data, length * 2, true)
    return raw and byteTableToWideString(raw) or "??"
end

State.CustomWeak = function(bytes)
    if not Resolved() then return "(Unreal Engine not resolved)" end
    local index = BytesToInteger(bytes, 1, 4)
    if index == 0xFFFFFFFF or index == 0 then return "None" end
    local object = ObjectAt(index)
    if not object then return string.format("#%d (empty)", index) end
    return string.format("%s (%s)", NameOf(object) or "?", NameOf(ClassOf(object) or 0) or "?")
end

State.CustomFNameBack = function(text)
    if not Resolved() or type(text) ~= "string" then return nil end
    local base, number = text:match("^(.-)_(%d+)$")
    for index, name in pairs(S.nameText) do
        if name == text or (base and name == base) then
            local n = name == text and 0 or tonumber(number) + 1
            local out = {}
            for i = 0, 3 do out[#out + 1] = (index >> (i * 8)) & 0xFF end
            for i = 0, 3 do out[#out + 1] = (n >> (i * 8)) & 0xFF end
            return out
        end
    end
    return nil
end

local function CustomCaller(count, key)
    return function(...)
        local bytes = { ... }
        local ok, text = pcall(State[key], { table.unpack(bytes, 1, count) })
        return ok and text or "??"
    end
end

local function RegisterCustomTypes()
    if type(registerCustomTypeLua) ~= "function" then
        Log("CustomTypes", "registerCustomTypeLua is not available, names and strings show as numbers.")
        return
    end
    local function register(name, count, key, back)
        if type(getCustomType) == "function" and getCustomType(name) then return end
        local ok, err = pcall(registerCustomTypeLua, name, count, CustomCaller(count, key), function(value)
            if back and State[back] then
                local bytes = State[back](value)
                if bytes then return table.unpack(bytes) end
            end
            error("this value is read only")
        end, false, true)
        if not ok then Log("CustomTypes", "Could not register " .. name .. ": " .. tostring(err)) end
    end
    register(CUSTOM_FNAME, 8, "CustomFName", "CustomFNameBack")
    register(CUSTOM_FSTRING, 16, "CustomFString")
    register(CUSTOM_WEAK, 8, "CustomWeak")
end

local function Custom(name)
    if type(getCustomType) ~= "function" then return nil end
    local ok, ct = pcall(getCustomType, name)
    return ok and ct or nil
end

----------------------------------------
-- STRUCTURE DISSECT
----------------------------------------

local function FindGlobalStructure(name)
    if type(getStructureCount) ~= "function" then return nil end
    for i = 0, getStructureCount() - 1 do
        local structure = getStructure(i)
        if structure and structure.Name == name then return structure end
    end
end

local Filler = {}
Filler.__index = Filler

-- ∑ Elements are collected first and added in offset order at the end, so
-- the gaps between reflected fields land where they belong and hosts that
-- show elements in insertion order still show them sorted.
local function NewFiller(structure, base)
    return setmetatable({ structure = structure, base = base, count = 0, specs = {} }, Filler)
end

function Filler:Add(offset, name, vartype, options)
    if self.count >= ELEMENT_LIMIT then return nil end
    options = options or {}
    self.count = self.count + 1
    local spec = { offset = offset, name = name, vartype = vartype, options = options, order = self.count,
        width = options.width or options.bytesize or 8 }
    self.specs[#self.specs + 1] = spec
    return spec
end

-- ∑ Bitfield bools become one-bit binary elements where the host's
-- structure elements know BitStart and BitLength (Manifold Engine). Cheat
-- Engine's elements have no bit position, so there the byte stays, shown in
-- hex with the bit mask in its name. The first bitfield decides for the run.
local binaryElements

local function BinaryElements(e)
    if binaryElements == nil then
        local ok, value = pcall(function() return e.BitStart end)
        binaryElements = ok and math.type(value) == "integer" and rawget(_G, "vtBinary") ~= nil
    end
    return binaryElements
end

local function MaskBit(mask)
    if not mask or mask <= 0 or mask & (mask - 1) ~= 0 then return nil end
    local bit = 0
    while mask > 1 do mask, bit = mask >> 1, bit + 1 end
    return bit
end

function Filler:Flush()
    table.sort(self.specs, function(a, b)
        if a.offset ~= b.offset then return a.offset < b.offset end
        return a.order < b.order
    end)
    local customs = {}
    for _, spec in ipairs(self.specs) do
        local options = spec.options
        local e = self.structure.addElement()
        e.Offset = spec.offset
        e.Name = spec.name
        local custom = options.custom and customs[options.custom]
        if options.custom and custom == nil then
            custom = Custom(options.custom) or false
            customs[options.custom] = custom
        end
        local binary = false
        if custom then
            e.Vartype = VT.Custom
            e.CustomType = custom
        elseif options.bit and BinaryElements(e) then
            binary = true
            e.Vartype = VT.Binary
            e.BitStart = options.bit
            e.BitLength = 1
            e.Name = options.bitName or spec.name
        else
            e.Vartype = spec.vartype
            if options.bytesize then e.Bytesize = options.bytesize end
        end
        if not binary then
            if options.hex then e.DisplayMethod = "dtHexadecimal" elseif options.signed then e.DisplayMethod = "dtSignedInteger" end
        end
        if options.child then e.ChildStruct = options.child end
    end
    self.specs = {}
end

local SCALARS = {
    FloatProperty = { VT.Single }, DoubleProperty = { VT.Double },
    Int8Property = { VT.Byte, signed = true }, ByteProperty = { VT.Byte },
    Int16Property = { VT.Word, signed = true }, UInt16Property = { VT.Word },
    IntProperty = { VT.Dword, signed = true }, UInt32Property = { VT.Dword },
    Int64Property = { VT.Qword, signed = true }, UInt64Property = { VT.Qword },
}

local BY_SIZE = { [1] = VT.Byte, [2] = VT.Word, [4] = VT.Dword, [8] = VT.Qword }

local function Annotated(name, text)
    return text and text ~= "" and name .. "  (" .. text .. ")" or name
end

--
--- ∑ TArray data is a heap block nothing describes. While an object is
--- filled, the data pointer of each of its arrays is remembered with the
--- array's element type; expanding that pointer then asks the dissect
--- callbacks about exactly that address, and they fill the block from the
--- element type. A shared child structure per element type would have to be
--- created up front for every array of every class and would flood the
--- structure list and the saved table.
--
local ARRAY_MEMORY = 20000

local function RememberArray(f, header)
    if not header or not f.innerProp then return end
    local data = RPtr(header)
    if not data then return end
    if (S.arrayCount or 0) >= ARRAY_MEMORY then S.arrays, S.arrayCount = {}, 0 end
    S.arrays = S.arrays or {}
    if not S.arrays[data] then S.arrayCount = (S.arrayCount or 0) + 1 end
    S.arrays[data] = { field = f, header = header }
end

local function RememberedArray(address)
    local entry = S.arrays and S.arrays[address]
    if not entry or RP(entry.header) ~= address then return nil end
    return entry
end

function Filler:Value(f, offset, name, depth)
    local kind = f.type
    local scalar = SCALARS[kind]
    if scalar then
        local text = kind == "ByteProperty" and f.inner and CppName(f.inner) or nil
        return self:Add(offset, Annotated(name, text), scalar[1], { signed = scalar.signed, width = math.max(1, f.size) })
    end
    if kind == "BoolProperty" then
        if f.mask and f.fieldMask ~= 0xFF then
            return self:Add(offset + (f.byteOffset or 0), Annotated(name, string.format("bit mask %02X", f.mask)), VT.Byte,
                { hex = true, width = 1, bit = MaskBit(f.mask), bitName = name })
        end
        return self:Add(offset, name, BY_SIZE[f.size] or VT.Byte, { width = math.max(1, f.size) })
    end
    if kind == "EnumProperty" then
        return self:Add(offset, Annotated(name, f.inner and CppName(f.inner)), BY_SIZE[f.size] or VT.Byte, { width = math.max(1, f.size) })
    end
    if kind == "NameProperty" then
        return self:Add(offset, name, VT.Qword, { custom = CUSTOM_FNAME, hex = true, width = 8 })
    end
    if kind == "StrProperty" then
        local e = self:Add(offset, name, VT.Pointer, { custom = CUSTOM_FSTRING, width = 16 })
        if not Custom(CUSTOM_FSTRING) then self:Add(offset + 8, name .. ".Num", VT.Dword, { width = 4 }) end
        return e
    end
    if OBJECT_KINDS[kind] or kind == "InterfaceProperty" then
        return self:Add(offset, Annotated(name, TypeText(f)), VT.Pointer, { width = 8 })
    end
    if kind == "WeakObjectProperty" or kind == "LazyObjectProperty" or kind == "SoftObjectProperty" or kind == "SoftClassProperty" then
        return self:Add(offset, Annotated(name, TypeText(f)), VT.Dword, { custom = CUSTOM_WEAK, width = math.max(8, f.size) })
    end
    if kind == "DelegateProperty" then
        self:Add(offset, Annotated(name .. ".Object", "FScriptDelegate"), VT.Dword, { custom = CUSTOM_WEAK, width = 8 })
        return self:Add(offset + 8, name .. ".FunctionName", VT.Qword, { custom = CUSTOM_FNAME, hex = true, width = 8 })
    end
    if kind == "ArrayProperty" or kind == "MulticastInlineDelegateProperty" or kind == "MulticastDelegateProperty" then
        if kind == "ArrayProperty" then RememberArray(f, self.base and self.base + offset) end
        self:Add(offset, Annotated(name, TypeText(f)), VT.Pointer, { width = 8 })
        self:Add(offset + 8, name .. ".Num", VT.Dword, { signed = true, width = 4 })
        return self:Add(offset + 12, name .. ".Max", VT.Dword, { signed = true, width = 4 })
    end
    if kind == "SetProperty" or kind == "MapProperty" then
        self:Add(offset, Annotated(name .. ".Elements", TypeText(f)), VT.Pointer, { width = 8 })
        return self:Add(offset + 8, name .. ".Num", VT.Dword, { signed = true, width = 4 })
    end
    if kind == "TextProperty" then
        return self:Add(offset, Annotated(name, "FText"), VT.Pointer, { width = 8 })
    end
    if kind == "StructProperty" and f.inner then
        if depth < INLINE_DEPTH then
            return self:Struct(f.inner, offset, name .. ".", depth + 1)
        end
        return self:Add(offset, Annotated(name, CppName(f.inner)), VT.Bytes, { bytesize = math.max(1, math.min(f.size, 256)) })
    end
    local size = math.max(1, f.size)
    if BY_SIZE[size] then return self:Add(offset, Annotated(name, TypeText(f)), BY_SIZE[size], { hex = true, width = size }) end
    return self:Add(offset, Annotated(name, TypeText(f)), VT.Bytes, { bytesize = math.min(size, 256) })
end

function Filler:Field(f, base, prefix, depth)
    local dim = math.min(f.dim, STATIC_ARRAY_LIMIT)
    for i = 0, dim - 1 do
        local name = prefix .. f.name .. (f.dim > 1 and "[" .. i .. "]" or "")
        self:Value(f, base + f.offset + i * math.max(1, f.size), name, depth)
    end
end

function Filler:Struct(struct, base, prefix, depth)
    for _, f in ipairs(Fields(struct)) do
        if self.count >= ELEMENT_LIMIT then return end
        self:Field(f, base, prefix, depth)
    end
end

--
--- ∑ Bytes no reflected property covers are native members (ComponentToWorld,
--- the level's actor array, ...). They get 8-byte slots, as a pointer when
--- the live value at the base address looks like one, so they stay
--- expandable instead of disappearing from the dissect.
--
function Filler:Gaps(size)
    local ranges = {}
    for _, spec in ipairs(self.specs) do ranges[#ranges + 1] = { from = spec.offset, to = spec.offset + spec.width } end
    table.sort(ranges, function(a, b) return a.from < b.from end)
    local gaps, cursor = {}, 0
    for _, range in ipairs(ranges) do
        if range.from > cursor then gaps[#gaps + 1] = { from = cursor, to = range.from } end
        if range.to > cursor then cursor = range.to end
    end
    if size and size > cursor then gaps[#gaps + 1] = { from = cursor, to = size } end
    for _, gap in ipairs(gaps) do
        local at, stop = gap.from, math.min(gap.to, gap.from + GAP_LIMIT)
        while at < stop and self.count < ELEMENT_LIMIT do
            if at % 8 == 0 and at + 8 <= gap.to then
                local value = self.base and RP(self.base + at)
                local pointer = value and IsPtr(value)
                self:Add(at, "(not reflected)", pointer and VT.Pointer or VT.Qword, { hex = not pointer, width = 8 })
                at = at + 8
            else
                local step = at % 4 == 0 and at + 4 <= gap.to and 4 or 1
                self:Add(at, "(not reflected)", step == 4 and VT.Dword or VT.Byte, { hex = true, width = step })
                at = at + step
            end
        end
    end
end

function Filler:Header()
    self:Add(0, "VTable", VT.Pointer, { width = 8 })
    if L.index == 0x0C then self:Add(0x08, "ObjectFlags", VT.Dword, { hex = true, width = 4 }) end
    self:Add(L.index, "InternalIndex", VT.Dword, { signed = true, width = 4 })
    self:Add(L.class, "ClassPrivate", VT.Pointer, { width = 8 })
    self:Add(L.name, "NamePrivate", VT.Qword, { custom = CUSTOM_FNAME, hex = true, width = 8 })
    self:Add(L.outer, "OuterPrivate", VT.Pointer, { width = 8 })
end

local function FillStructure(structure, struct, base, isObject)
    local filler = NewFiller(structure, base)
    pcall(function() structure.beginUpdate() end)
    local ok, err = pcall(function()
        if isObject then filler:Header() end
        filler:Struct(struct, 0, "", 0)
        filler:Gaps(StructSize(struct))
        filler:Flush()
    end)
    pcall(function() structure.endUpdate() end)
    if not ok then Log("Dissect", "Filling " .. tostring(NameOf(struct)) .. " stopped: " .. tostring(err)) end
    return filler.count
end

-- The entries of a remembered TArray: pointers for object arrays (expanding
-- one dissects that object), the struct's fields per entry, or plain values.
local function FillArray(structure, entry)
    local f = entry.field
    local info = Describe(f.innerProp, f.innerType, nil)
    local size = math.max(1, info.size)
    local perEntry = 1
    if info.type == "StructProperty" and info.inner then perEntry = math.max(1, #Fields(info.inner)) end
    local count = math.max(1, RI(entry.header + 8) or 1)
    local entries = math.min(count, math.max(4, math.min(ARRAY_PREVIEW, ARRAY_PREVIEW_ELEMENTS // perEntry)))
    local filler = NewFiller(structure, RP(entry.header))
    pcall(function() structure.beginUpdate() end)
    local ok, err = pcall(function()
        for i = 0, entries - 1 do
            filler:Value(info, i * size, "[" .. i .. "]", 0)
        end
        filler:Flush()
    end)
    pcall(function() structure.endUpdate() end)
    if not ok then Log("Dissect", "Filling " .. TypeText(f) .. " stopped: " .. tostring(err)) end
    return filler.count
end

local function FillObject(structure, object)
    local class = ClassOf(object)
    if not class then return 0 end
    return FillStructure(structure, class, object, true)
end

local function DissectName(object)
    return NameOf(ClassOf(object) or 0) or "UObject"
end

-- ∑ registerStructureNameLookup: the class names the structure, and the
-- object's real start replaces an address that points into its middle.
State.NameLookup = function(address)
    if not Ready(true) then return nil end
    local array = RememberedArray(address)
    if array then return string.format("%s[%d]", TypeText(array.field), math.max(0, RI(array.header + 8) or 0)), address end
    local object = OwnerOf(address)
    if not object then return nil end
    return DissectName(object), object
end

-- ∑ registerStructureDissectOverride: an object start gets its class, an
-- address that starts a struct property inside an object gets that struct.
-- Anything else is left to Cheat Engine's own guess.
State.DissectOverride = function(structure, base)
    if not Ready(true) then return nil end
    if IsObject(base) then
        return FillObject(structure, base) > 0
    end
    local array = RememberedArray(base)
    if array then return FillArray(structure, array) > 0 end
    local hit = Locate(base)
    if hit and hit.struct then
        return FillStructure(structure, hit.struct, base, false) > 0
    end
    return nil
end

local function Dissect(address)
    Require()
    local object = OwnerOf(address)
    if not object then error(string.format("no UObject contains %X", address), 2) end
    local name = DissectName(object)
    local structure = FindGlobalStructure(name)
    if not structure then
        structure = createStructure(name)
        FillObject(structure, object)
        structure.addToGlobalStructureList()
    end
    local form = createStructureForm(string.format("%X", object), "Group 1", name)
    if form and type(form) == "userdata" then pcall(function() form.Caption = "Structure dissect: " .. name .. " " .. (NameOf(object) or "") end) end
    return form, structure
end

----------------------------------------
-- SYMBOLS AND RECORDS
----------------------------------------

local function OffsetSymbol(owner, field)
    return (owner .. "_" .. field):gsub("[^%w_]", "_")
end

local function RegisterOffset(f)
    local symbol = OffsetSymbol(f.owner or "?", f.name)
    if not S.symbols[symbol] then
        RegisterOwnSymbol(symbol, f.offset)
        S.symbols[symbol] = f.offset
    end
    return symbol
end

local function LooksUnrealSafe()
    Session()
    return UnrealProcess()
end

--
--- ∑ <Type>_<Property> offsets resolve on demand, so a table saved with them
--- works again in the next session (and after a game update) without anyone
--- registering the symbols first. Underscores are legal in both halves; every
--- split is tried until a type and one of its properties match.
--
State.SymbolLookup = function(token)
    if type(token) ~= "string" or #token > 256 or not token:find("^[%a_][%w_]*$") then return nil end
    if token == "GObjects" or token == "FNamePool" or token == "GNames" or token == "GameEngine" then
        if not Ready(LooksUnrealSafe()) then return nil end
        if token == "GObjects" then return S.array end
        if token == "GameEngine" then return S.engine end
        return S.pool
    end
    if not token:find("_", 2, true) then return nil end
    if not Ready(LooksUnrealSafe()) then return nil end
    local at = 1
    while true do
        local cut = token:find("_", at + 1, true)
        if not cut then return nil end
        local struct = Type(token:sub(1, cut - 1))
        if struct then
            local f = FindField(struct, token:sub(cut + 1))
            if f then
                RegisterOwnSymbol(token, f.offset)
                S.symbols[token] = f.offset
                return f.offset ~= 0 and f.offset or nil
            end
        end
        at = cut
    end
end

local FIELD_VARTYPES = {
    FloatProperty = VT.Single, DoubleProperty = VT.Double, BoolProperty = VT.Byte,
    ByteProperty = VT.Byte, Int8Property = VT.Byte, EnumProperty = VT.Byte,
    Int16Property = VT.Word, UInt16Property = VT.Word,
    IntProperty = VT.Dword, UInt32Property = VT.Dword,
    Int64Property = VT.Qword, UInt64Property = VT.Qword,
}

--
--- ∑ Follows properties by name from a live object. Returns the address of
--- the last step and an address expression built from offset symbols, so a
--- record made from it says what it reads instead of carrying numbers.
--
local function Walk(object, root, ...)
    local address, struct, text = object, ClassOf(object), root
    local steps, last = { ... }, nil
    for i, step in ipairs(steps) do
        local name, index = step:match("^(.-)%[(%d+)%]$")
        local f = FindField(struct, name or step)
        if not f then error(string.format("%s has no property %s", NameOf(struct) or "?", step), 2) end
        last = f
        address, text = address + f.offset, text .. "+" .. RegisterOffset(f)
        local isObject = OBJECT_KINDS[f.type] or false
        if f.type == "StructProperty" then
            struct = f.inner
        elseif f.type == "ArrayProperty" and index then
            local data = RP(address)
            if not data then return nil end
            address, text = data + tonumber(index) * 8, string.format("[%s]+%X", text, tonumber(index) * 8)
            isObject = true
        end
        if isObject and i < #steps then
            address, text = RP(address), "[" .. text .. "]"
            if not IsPtr(address) then return nil end
            struct = ClassOf(address)
        end
    end
    return address, text, last
end

local function MakeRecord(description, vartype, address, text, f)
    local record = getAddressList().createMemoryRecord()
    record.Description, record.Address = description, text
    if vartype then
        record.Type = vartype
    elseif f and f.type == "NameProperty" and Custom(CUSTOM_FNAME) then
        record.Type = VT.Custom
        record.CustomTypeName = CUSTOM_FNAME
    elseif f and f.type == "StrProperty" and Custom(CUSTOM_FSTRING) then
        record.Type = VT.Custom
        record.CustomTypeName = CUSTOM_FSTRING
    elseif f and f.type == "BoolProperty" and f.mask and f.fieldMask ~= 0xFF then
        record.Type = VT.Byte
        record.ShowAsHex = true
    else
        record.Type = (f and FIELD_VARTYPES[f.type]) or (f and OBJECT_KINDS[f.type] and VT.Pointer) or VT.Dword
    end
    return record
end

----------------------------------------
-- SESSION CHECK
----------------------------------------

-- true = offline, false = connected or hosting remote players, nil = cannot tell.
local function IsOffline()
    local world = World()
    local netDriver = world and FindField(ClassOf(world), "NetDriver")
    if not netDriver then return nil end
    local driver = RP(world + netDriver.offset)
    if driver == nil then return nil end
    if driver == 0 then return true end
    local server = FindField(ClassOf(driver), "ServerConnection")
    local clients = FindField(ClassOf(driver), "ClientConnections")
    if not server or not clients then return nil end
    return RP(driver + server.offset) == 0 and (RI(driver + clients.offset + 8) or 0) == 0
end

----------------------------------------
-- PUBLIC API
----------------------------------------

local function ToAddress(value)
    if math.type(value) == "integer" then return value end
    if type(value) == "number" then return math.tointeger(value) end
    if type(value) == "string" then
        local ok, address = pcall(getAddressSafe, value)
        if ok and address then return address end
        return tonumber(value, 16)
    end
end

local function TypeArg(value)
    if type(value) == "string" then
        local found = Type(value)
        if not found then error("no class or struct named " .. value, 3) end
        return found
    end
    return ToAddress(value)
end

UE.VERSION = VERSION

function UE.init(force)
    if force then S = nil end
    Session()
    if not Ready(true, true) then error(S.failed or "Unreal Engine not resolved", 2) end
    return true
end

function UE.status()
    Session()
    if S.ready then
        return string.format("%s · %d objects · %d types · %s", S.nameKind == "pool" and "UE 4.23+" or "UE 4.22 or older",
            Count(), #S.typeList, L.component == 8 and "double vectors (UE5)" or "float vectors")
    end
    return S.failed and ("not resolved: " .. S.failed) or "not resolved yet"
end

function UE.layout() Require(); local copy = {}; for k, v in pairs(L) do copy[k] = v end; return copy end
function UE.objects() Require(); return S.array end
function UE.names() Require(); return S.pool end
function UE.count() Require(); return Count() end
function UE.objectAt(index) Require(); return ObjectAt(index) end
function UE.isObject(address) Require(); return IsObject(ToAddress(address)) end
function UE.name(address) Require(); return NameAt(ToAddress(address)) end
function UE.nameOf(object) Require(); return NameOf(ToAddress(object)) end
function UE.fullName(object) Require(); return FullName(ToAddress(object)) end
function UE.classOf(object) Require(); return ClassOf(ToAddress(object)) end
function UE.className(object) Require(); return NameOf(ClassOf(ToAddress(object)) or 0) end
function UE.super(struct) Require(); return SuperOf(TypeArg(struct)) end
function UE.size(struct) Require(); return StructSize(TypeArg(struct)) end
function UE.type(name) Require(); return Type(name) end
function UE.enum(name) Require(); return EnumEntries(type(name) == "string" and S.enumsByName[name:lower()] or ToAddress(name)) end
function UE.fields(struct, ownOnly) Require(); return Fields(TypeArg(struct), ownOnly) end
function UE.field(struct, name) Require(); return FindField(TypeArg(struct), name) end
function UE.functions(class, inherited) Require(); return Functions(TypeArg(class), inherited) end
function UE.instances(class, limit) Require(); return Instances(TypeArg(class), limit) end
function UE.owner(address) Require(); return OwnerOf(ToAddress(address)) end

-- ∑ For other dissect scripts (Manifold-RTTI): true for every address this
-- script names itself, so they can step aside whichever callback runs
-- first. Unlike owner it resolves the way a dissect does, never with the
-- full search, so a process that is not Unreal costs one module scan and
-- answers false from then on.
function UE.claims(address)
    if not Ready(true) then return false end
    address = ToAddress(address)
    if not address then return false end
    return RememberedArray(address) ~= nil or OwnerOf(address) ~= nil
end
function UE.whois(address) Require(); return Whois(ToAddress(address)) end
function UE.engine() return Engine() end
function UE.world() return World() end
function UE.controller() return Controller() end
function UE.pawn() return Pawn() end
function UE.isOffline() Require(); return IsOffline() end
function UE.typeText(field) Require(); return TypeText(field) end

function UE.offset(typeName, name)
    Require()
    local f = FindField(TypeArg(typeName), name)
    return f and f.offset
end

function UE.find(nameOrPath)
    Require()
    return Each(function(object)
        local name = NameOf(object)
        return name == nameOrPath or (nameOrPath:find(".", 1, true) and FullName(object) == nameOrPath)
    end)
end

function UE.walk(object, root, ...)
    Require()
    return Walk(ToAddress(object), root or string.format("%X", ToAddress(object)), ...)
end

function UE.pawnField(...)
    local steps = { table.unpack(PAWN_PATH) }
    for _, step in ipairs({ ... }) do steps[#steps + 1] = step end
    return Walk(Engine(), "GameEngine", table.unpack(steps))
end

function UE.record(description, vartype, ...)
    local address, text, f = UE.pawnField(...)
    if not address then return nil end
    return MakeRecord(description, vartype, address, text, f)
end

function UE.recordFrom(object, root, description, vartype, ...)
    local address, text, f = UE.walk(object, root, ...)
    if not address then return nil end
    return MakeRecord(description, vartype, address, text, f)
end

function UE.dissect(address)
    return Dissect(ToAddress(address))
end

function UE.search(text)
    Require()
    text = text:lower()
    local out = {}
    for _, entry in ipairs(S.typeList) do
        if entry.kind ~= "enum" then
            for _, f in ipairs(Fields(entry.object, true)) do
                if f.name:lower():find(text, 1, true) then
                    out[#out + 1] = string.format("%s.%s  +%X  %s", entry.name, f.name, f.offset, TypeText(f))
                end
            end
        end
    end
    for _, line in ipairs(out) do print(line) end
    return out
end

function UE.dump(typeName)
    Require()
    local struct = TypeArg(typeName)
    local lines = {}
    local super = SuperOf(struct)
    lines[#lines + 1] = string.format("%s%s  // size 0x%X", CppName(struct), super and (" : " .. CppName(super)) or "", StructSize(struct) or 0)
    for _, f in ipairs(Fields(struct)) do
        local mask = f.mask and f.fieldMask ~= 0xFF and string.format(" : 1 (mask %02X)", f.mask) or ""
        lines[#lines + 1] = string.format("  +%04X  %-32s %s%s%s  (%s)", f.offset + (f.byteOffset or 0), TypeText(f), f.name,
            f.dim > 1 and "[" .. f.dim .. "]" or "", mask, f.owner)
    end
    for _, line in ipairs(lines) do print(line) end
    return lines
end

----------------------------------------
-- INSPECTOR
----------------------------------------

local Inspector = {}

local function InspectorTypes(filter)
    local out = {}
    filter = (filter or ""):lower()
    for _, entry in ipairs(S.typeList) do
        if entry.kind ~= "enum" and (filter == "" or entry.name:lower():find(filter, 1, true)) then
            out[#out + 1] = entry
            if #out >= 3000 then break end
        end
    end
    return out
end

function Inspector:ShowType(entry)
    local view = self.properties
    view.Items.clear()
    self.current = entry
    if not entry then return end
    local function row(offset, name, typeText, owner)
        local item = view.Items.add()
        item.Caption = offset
        item.SubItems.add(name)
        item.SubItems.add(typeText)
        item.SubItems.add(owner)
    end
    if self.showFunctions then
        for _, fn in ipairs(Functions(entry.object, true)) do
            local params = {}
            for _, p in ipairs(fn.params) do params[#params + 1] = TypeText(p) .. " " .. p.name end
            row(string.format("%08X", fn.flags or 0), fn.name, "(" .. table.concat(params, ", ") .. ")", fn.owner)
        end
    else
        for _, f in ipairs(Fields(entry.object)) do
            local mask = f.mask and f.fieldMask ~= 0xFF and string.format(" (mask %02X)", f.mask) or ""
            row(string.format("%04X", f.offset + (f.byteOffset or 0)), f.name .. (f.dim > 1 and "[" .. f.dim .. "]" or "") .. mask, TypeText(f), f.owner)
        end
    end
    self.label.Caption = string.format("%s  ·  size 0x%X  ·  %s", CppName(entry.object), StructSize(entry.object) or 0, FullName(entry.object))
end

function Inspector:Filter(text)
    self.list.Items.clear()
    self.entries = {}
    if text:sub(1, 1) == "." and #text > 2 then
        local needle = text:sub(2):lower()
        for _, entry in ipairs(S.typeList) do
            if entry.kind ~= "enum" then
                for _, f in ipairs(Fields(entry.object, true)) do
                    if f.name:lower():find(needle, 1, true) then
                        self.entries[#self.entries + 1] = entry
                        self.list.Items.add(entry.name .. "." .. f.name)
                        break
                    end
                end
            end
            if #self.entries >= 1000 then break end
        end
        return
    end
    for _, entry in ipairs(InspectorTypes(text)) do
        self.entries[#self.entries + 1] = entry
        self.list.Items.add(entry.name .. (entry.kind == "struct" and "  (struct)" or ""))
    end
end

function Inspector:Selected()
    local index = self.list.ItemIndex
    return index and index >= 0 and self.entries[index + 1] or nil
end

function Inspector:Instances()
    local entry = self.current
    if not entry or entry.kind ~= "class" then return end
    local found = Instances(entry.object, 500)
    if #found == 0 then
        messageDialog("No live instance of " .. entry.name .. ".", mtInformation, mbOK)
        return
    end
    local list = createStringlist()
    for _, object in ipairs(found) do list.add(string.format("%X  %s", object, FullName(object))) end
    local index = showSelectionList("Instances of " .. entry.name, "Pick an instance to dissect", list)
    list.destroy()
    if index and index >= 0 then Dissect(found[index + 1]) end
end

function Inspector:Build()
    local form = createForm(false)
    form.Caption = "Unreal Engine Inspector"
    form.Width, form.Height = 1000, 640
    form.Position = "poScreenCenter"
    form.OnClose = function() return caHide end

    local top = createPanel(form)
    top.Align, top.Height, top.BevelOuter = alTop, 34, "bvNone"
    local search = createEdit(top)
    search.Align, search.Width = alLeft, 320
    search.BorderSpacing.Around = 4
    search.TextHint = "Type name, or .property to search properties"
    local label = createLabel(top)
    label.Align = alClient
    label.BorderSpacing.Around = 8

    local bottom = createPanel(form)
    bottom.Align, bottom.Height, bottom.BevelOuter = alBottom, 36, "bvNone"
    local function button(caption, width, onClick)
        local b = createButton(bottom)
        b.Caption, b.Align, b.Width = caption, alLeft, width
        b.BorderSpacing.Around = 4
        b.OnClick = function() local ok, err = pcall(onClick); if not ok then Log("Inspector", err) end end
        return b
    end

    local list = createListBox(form)
    list.Align, list.Width = alLeft, 320

    local splitter = createSplitter(form)
    splitter.Align = alLeft

    local view = createListView(form)
    view.Align, view.ViewStyle, view.RowSelect, view.ReadOnly, view.HideSelection = alClient, "vsReport", true, true, false
    for _, column in ipairs({ { "Offset", 70 }, { "Name", 260 }, { "Type", 260 }, { "Declared in", 160 } }) do
        local c = view.Columns.add()
        c.Caption, c.Width = column[1], column[2]
    end

    self.form, self.search, self.list, self.properties, self.label = form, search, list, view, label

    button("Dissect an instance", 150, function()
        local entry = self.current
        local object = entry and Instances(entry.object, 1)[1]
        if object then Dissect(object) else messageDialog("No live instance.", mtInformation, mbOK) end
    end)
    button("Instances...", 100, function() self:Instances() end)
    self.functionsButton = button("Functions", 100, function()
        self.showFunctions = not self.showFunctions
        self.functionsButton.Caption = self.showFunctions and "Properties" or "Functions"
        self:ShowType(self.current)
    end)
    button("Copy offset symbol", 140, function()
        local item = view.Selected
        local entry = self.current
        if item and entry and not self.showFunctions then
            local name = item.SubItems[0]:gsub("%[.*$", ""):gsub(" .*$", "")
            local f = FindField(entry.object, name)
            if f then
                local symbol = RegisterOffset(f)
                writeToClipboard(symbol)
                Log("Inspector", string.format("%s = +%X copied", symbol, f.offset))
            end
        end
    end)
    button("Dump to console", 120, function() if self.current then UE.dump(self.current.object) end end)

    search.OnChange = function() local ok, err = pcall(function() self:Filter(search.Text) end); if not ok then Log("Inspector", err) end end
    list.OnSelectionChange = function()
        local ok, err = pcall(function() self:ShowType(self:Selected()) end)
        if not ok then Log("Inspector", err) end
    end
    list.OnClick = list.OnSelectionChange
end

function Inspector:Open()
    Require()
    if not self.form or self.pid ~= S.pid then
        if self.form then pcall(function() self.form.destroy() end) end
        self.form = nil
        self:Build()
        self.pid = S.pid
        self:Filter("")
    end
    self.form.show()
    self.form.BringToFront()
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

local function DissectOr(label, object)
    if not object then error(label .. " was not found (is a level loaded?)") end
    Dissect(object)
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
        local status
        local function item(caption, onClick)
            local entry = createMenuItem(menu)
            entry.Caption = caption
            if onClick then entry.OnClick = Guarded(caption, onClick) end
            root.add(entry)
            return entry
        end
        status = item("Status: not resolved yet")
        status.Enabled = false
        root.OnClick = function() pcall(function() status.Caption = "Status: " .. UE.status() end) end
        item("Resolve again", function()
            S = nil
            UE.init()
            status.Caption = "Status: " .. UE.status()
        end)
        item("-")
        item("Dissect GameEngine", function() DissectOr("The engine object", Engine()) end)
        item("Dissect World", function() DissectOr("The world", World()) end)
        item("Dissect local PlayerController", function() DissectOr("The player controller", Controller()) end)
        item("Dissect local Pawn", function() DissectOr("The local pawn", Pawn()) end)
        item("Dissect object at address...", function()
            local address = AskAddress("Dissect Unreal object")
            if address then Dissect(address) end
        end)
        item("-")
        item("Inspector...", function() Inspector:Open() end)
        item("Who owns an address...", function()
            local address = AskAddress("Who owns this address?")
            if not address then return end
            Require()
            local text, hit = Whois(address)
            if not text then
                messageDialog(string.format("No UObject contains %X.", address), mtInformation, mbOK)
                return
            end
            print(text)
            if messageDialog(text .. "\n\nDissect the owner?", mtConfirmation, mbYes, mbNo) == mrYes then Dissect(hit.object) end
        end)
        item("-")
        local hooks = item("Structure Dissect uses Unreal names", function() end)
        hooks.Checked = State.HooksEnabled ~= false
        hooks.OnClick = Guarded("Hooks", function()
            hooks.Checked = not hooks.Checked
            SetDissectHooks(hooks.Checked)
        end)
    end)
    if not ok then Log("Menu", "Could not build the menu: " .. tostring(err)) end
end

local function InstallSymbolLookup()
    if State.SymbolLookupId and type(unregisterSymbolLookupCallback) == "function" then pcall(unregisterSymbolLookupCallback, State.SymbolLookupId) end
    State.SymbolLookupId = nil
    if type(registerSymbolLookupCallback) ~= "function" then return end
    local ok, id = pcall(registerSymbolLookupCallback, function(token)
        local fine, value = pcall(State.SymbolLookup, token)
        if fine then return value end
    end, SL_FAILURE)
    if ok then State.SymbolLookupId = id end
end

----------------------------------------
-- MAIN
----------------------------------------

local function Main()
    if type(readPointer) ~= "function" or type(AOBScan) ~= "function" then
        Log("Main", "This host has no memory API, nothing was installed.")
        return
    end
    RegisterCustomTypes()
    SetDissectHooks(State.HooksEnabled ~= false)
    InstallSymbolLookup()
    InstallMenu()
    Log("Main", "Version " .. VERSION .. " ready. Open an Unreal Engine game and use Structure Dissect or the " .. MENU_CAPTION .. " menu.")
end

Main()

return UE
