--[[
    The address list as this window sees it, and the three structure moves
    Cheat Engine allows.

    Everything here works from one snapshot. A snapshot is a plain Lua table of
    nodes keyed by record id, built by walking the address list once, and it is
    the only thing the tree, the inspector and the services ever read. Memory
    record wrappers are never kept. Cheat Engine builds a fresh wrapper on every
    access and never invalidates the old ones, so a wrapper held past a delete
    is a use after free, and two wrappers of one record are not the same table.
    Ids are the only identity there is.

    The walk is split in two on purpose. The structure walk reads an id and a
    child count per record and nothing else, so it stays cheap enough to run on
    a timer over a table with thousands of records. The detail pass reads the
    twenty fields the window actually draws, and it runs in a contiguous window
    that moves through the snapshot, because getMemoryRecord is only fast when
    the index asked for is next to the last one. Jumping around costs a tree
    walk per record.

    Which Cheat Table is loaded is counted, not measured. Two tables can hold
    the same number of records with the same ids and the same shape, so nothing
    read out of the records themselves tells them apart, and anything that
    tries moves when the person renames a record instead. So the module counts
    loads. Cheat Engine calls the onTableLoad global twice around every load
    and that is the signal, with two fallbacks for a Cheat Table script that
    took the global away, a list that shares no record with the last one and a
    list that was emptied or filled. A record read back that no longer matches
    what was carried over says the detail is stale, not that the table changed,
    because a description edited in Cheat Engine's own list looks the same from
    here and losing the undo history over that would be worse than useless.

    Cheat Engine facts this file is built on.
      * getMemoryRecord walks depth first in pre order, and the order does not
        care whether a record is collapsed. Parents and depths are rebuilt from
        that order with a stack of remaining child counts, which costs one pass.
      * Count on the address list counts every record. Count on a record counts
        its direct children.
      * Parent and appendToEntry are the only move there is, and both append the
        record as the LAST child of the target. There is no way to move a record
        to the root, before a sibling or after one.
      * A move into the record itself or into one of its own descendants does
        nothing at all and says nothing, so every move is verified by reading
        the parent back afterwards, and a reorder inside one group is verified
        by reading the whole child order back because the parent never changes
        there.
      * Parent equals nil dereferences a nil pointer inside Cheat Engine, and no
        pcall can save that, so the target is checked in Lua before the call.
      * createMemoryRecord appends a four byte record described Plugin Address
        at the end of the root and marks the table as edited. It is the one Lua
        edit that does mark it.
      * A new wrapper per access means the detail of a record is read through
        exactly one wrapper, resolved once, rather than through a chain of
        property reads on different ones.

    Nothing here deletes a record. Deleting stays in Cheat Engine, because the
    Lua path frees the record immediately, skips the being edited checks and
    leaves raw pointers behind in an open editor.
]]

local Types = require("Manifold-AddressList-Types")

local Records = {}
Records.__index = Records

--- The type integer of an Auto Assembler script. The query language asks about
--- scripts on every keystroke, so this is compared straight rather than
--- resolved through the type list each time.
local SCRIPT_TYPE = 11

--- Cheat Engine's own value for a record with no colour of its own. It is a
--- system colour, so a record colour is never compared against black.
local DEFAULT_COLOR = 0x80000008

--- The other value Cheat Engine treats as no colour. The setter stores it as
--- clWindowText, so a table written by an older build can still hold it.
local DEFAULT_COLOR_ALT = 0x20000000

--- How many nodes a detail sweep reads when the caller names no budget. Large
--- enough to finish a small table in one tick and small enough to stay well
--- inside a frame on a large one.
local DEFAULT_BUDGET = 64

--- The starting value and the multiplier of the rolling hash. A number, not a
--- string, because the signature is rebuilt on a timer and a string would
--- allocate once per record.
local HASH_SEED, HASH_PRIME = 2166136261, 16777619

--- How deep a parent walk goes before it decides the tree lies to it. A record
--- tree is never this deep, so reaching it means a cycle.
local MAX_DEPTH = 512

--------------------------------------------------------
--             Which Cheat Table this is              --
--------------------------------------------------------

--
--- ∑ How many Cheat Tables have been loaded since Cheat Engine started, as far
---   as this module can tell.
---
---   This is the identity everything keyed by a record id hangs off, so it has
---   one rule. It moves when Cheat Engine loads a table and it never moves
---   when the person edits one. Anything read out of the records themselves
---   breaks that rule, because renaming a record or deleting a group would
---   look like a new table and throw away the undo history for the very edit
---   the person wants back.
---
---   It lives in the module and not in a service, because Cheat Engine has one
---   address list and a window rebuilt three times is still looking at the
---   same table.
--
local generation = 1

--- The last structure any service walked. A walk that shares no record with it
--- was read from another table, which is the fallback for a load this module
--- was never told about.
local lastSeen = nil

--- The function this module put in the onTableLoad global. Kept per module so
--- a second service chains nothing and a window rebuilt ten times does not
--- leave ten handlers behind.
local ownHook = nil

--- Counts one Cheat Table load. Nothing else is allowed to move this.
local function loaded()
    generation = generation + 1
    return generation
end

--
--- ∑ Whether two structures were read from the same address list, judged by
---   the records they hold.
---
---   Ids start again in every table, so sharing one is weak evidence, but a
---   table that shares none of them is certainly another one. An empty list on
---   exactly one side is a table that was cleared or filled.
--- @param before table|nil
--- @param after table|nil
--- @return boolean
--
local function sharesRecords(before, after)
    if before == nil or after == nil then return false end
    if before.Count == 0 and after.Count == 0 then return true end
    if before.Count == 0 or after.Count == 0 then return false end
    for _, node in ipairs(after.Order) do
        if before.ByID[node.ID] ~= nil then return true end
    end
    return false
end

--
--- ∑ Asks Cheat Engine to say when a Cheat Table is loaded.
---
---   onTableLoad is a plain global that Cheat Engine calls twice around every
---   load, once before it and once after. Anything else in the autorun folder
---   may already own it, so whatever was there is kept and called first and
---   nobody loses a notification they were relying on. A Cheat Table's own
---   script can still take the global away from us, which is why it is put
---   back on every structure walk and why nothing depends on it alone.
--- @return boolean # Whether the notification is in place.
--
local function watchTableLoads()
    local current = rawget(_G, "onTableLoad")
    if current ~= nil and current == ownHook then return true end
    -- Held by this one handler and not by the module, because a handler put
    -- back over somebody else's would otherwise end up calling the handler
    -- before it, which calls this one again, forever.
    local previous = current
    local hook = function(before)
        if previous ~= nil then pcall(previous, before) end
        -- Only the second call counts. The list still holds the old table
        -- during the first one, so counting there would hand the new identity
        -- to records that are about to be freed.
        if before ~= true then loaded() end
    end
    local ok = pcall(function() _G.onTableLoad = hook end)
    if ok then ownHook = hook end
    return ok
end

--------------------------------------------------------
--                   Small helpers                    --
--------------------------------------------------------

local function integer(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.tointeger(number) or math.floor(number)
end

--- Folds one number into a rolling 32 bit hash.
local function mix(hash, value)
    local number = integer(value) or 0
    hash = (hash ~ (number & 0xFFFFFFFF)) & 0xFFFFFFFF
    return (hash * HASH_PRIME) & 0xFFFFFFFF
end

--- The colour Cheat Engine gives a record that has none of its own. The global
--- is read at call time, so a build that names it differently still works.
local function defaultColor()
    local value = rawget(_G, "clWindowText")
    if type(value) == "number" then return value end
    return DEFAULT_COLOR
end

--- Sends one line to the log channel when there is one. A data module that
--- cannot log still has to work.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--
--- ∑ Hands every record of one window to fn, in index order.
---
---   The wrapper module walks the list once when it offers a walk, which
---   resolves the address list and the count one time instead of once per
---   record. The fallback is there for a wrapper that does not, and it does the
---   same thing more expensively.
--- @param ce table
--- @param first number # The zero based index to start at.
--- @param count number|nil # How many at most, the rest of the list by default.
--- @param fn function # fn(record, index).
--- @return number # How many records were handed over.
--
local function walk(ce, first, count, fn)
    if type(ce.Walk) == "function" then return ce:Walk(first, count, fn) end
    local total = integer(ce:Count()) or 0
    local last = total - 1
    if count ~= nil then last = math.min(last, first + count - 1) end
    local visited = 0
    for index = first, last do
        local mr = ce:RecordAt(index)
        if mr == nil then break end
        visited = visited + 1
        local ok, keep = pcall(fn, mr, index)
        if not ok or keep == false then break end
    end
    return visited
end

--- Seconds, from the Cheat Engine wrapper when it offers a clock and from Lua
--- otherwise. Only differences of two readings are ever used.
local function now(self)
    local ce = self and self.CE
    if ce ~= nil and type(ce.Now) == "function" then
        local ok, value = pcall(ce.Now, ce)
        if ok and type(value) == "number" then return value end
    end
    return os.clock()
end

--------------------------------------------------------
--                 The detail fields                  --
--------------------------------------------------------

--
--- ∑ Every field the detail pass fills, in the order it reads them.
---
---   The order matters. Type is read before the fields that depend on it, so a
---   reader can ask the node it is filling what kind of record this is instead
---   of reading the type off Cheat Engine a second time.
--
local DETAIL_READERS = {
    { Key = "Description", Read = function(ce, mr) return ce:Get(mr, "Description") or "" end },
    { Key = "Type", Read = function(ce, mr) return integer(ce:Get(mr, "Type")) end },
    { Key = "VarType", Read = function(ce, mr) return ce:Get(mr, "VarType") end },
    { Key = "IsGroupHeader", Read = function(ce, mr) return ce:Get(mr, "IsGroupHeader") == true end },
    { Key = "IsAddressGroupHeader", Read = function(ce, mr) return ce:Get(mr, "IsAddressGroupHeader") == true end },
    { Key = "Active", Read = function(ce, mr) return ce:Get(mr, "Active") == true end },
    { Key = "Color", Read = function(ce, mr) return integer(ce:Get(mr, "Color")) or defaultColor() end },
    { Key = "AddressString", Read = function(ce, mr) return ce:Get(mr, "AddressString") or "" end },
    { Key = "OffsetCount", Read = function(ce, mr) return integer(ce:Get(mr, "OffsetCount")) or 0 end },
    { Key = "HotkeyCount", Read = function(ce, mr) return integer(ce:Get(mr, "HotkeyCount")) or 0 end },
    { Key = "Options", Read = function(ce, mr) return ce:Get(mr, "Options") or "[]" end },
    { Key = "DropDownCount", Read = function(ce, mr) return integer(ce:Get(mr, "DropDownCount")) or 0 end },
    { Key = "DropDownLinked", Read = function(ce, mr) return ce:Get(mr, "DropDownLinked") == true end },
    { Key = "DropDownLinkedMemrec", Read = function(ce, mr) return ce:Get(mr, "DropDownLinkedMemrec") or "" end },
    { Key = "DontSave", Read = function(ce, mr) return ce:Get(mr, "DontSave") == true end },
    { Key = "Async", Read = function(ce, mr) return ce:Get(mr, "Async") == true end },
    -- Script reads nothing at all on a record that is not an Auto Assembler
    -- script, so the type decides whether it is worth asking.
    { Key = "ScriptLength", Read = function(ce, mr, node)
        if node.Type ~= SCRIPT_TYPE then return 0 end
        local script = ce:Get(mr, "Script")
        if type(script) ~= "string" then return 0 end
        return #script
    end },
    { Key = "LastFailed", Read = function(ce, mr, node)
        if node.Type ~= SCRIPT_TYPE then return false end
        return ce:Get(mr, "LastAAExecutionFailed") == true
    end },
    { Key = "LastFailedReason", Read = function(ce, mr, node)
        if node.Type ~= SCRIPT_TYPE then return "" end
        return ce:Get(mr, "LastAAExecutionFailedReason") or ""
    end },
    -- A unicode string is a string with a flag on the String sub object, so the
    -- flag is the only thing that tells the two apart.
    { Key = "Unicode", Read = function(ce, mr, node)
        if node.Type ~= 6 then return false end
        local settings = ce:Get(mr, "String")
        if settings == nil then return false end
        return ce:Get(settings, "Unicode") == true
    end }
}

local DETAIL_INDEX = {}
for index, entry in ipairs(DETAIL_READERS) do DETAIL_INDEX[entry.Key] = index end

--- The detail keys copied onto a new snapshot when the table did not change,
--- so a structure walk does not blank the tree for a frame.
local DETAIL_KEYS = {}
for _, entry in ipairs(DETAIL_READERS) do DETAIL_KEYS[#DETAIL_KEYS + 1] = entry.Key end
DETAIL_KEYS[#DETAIL_KEYS + 1] = "Loaded"

--- Walks an id argument. A list carries the id as the value and a set carries
--- it as the key, and both shapes arrive here from different callers.
local function eachID(ids, visit)
    if type(ids) ~= "table" then return end
    for key, value in pairs(ids) do
        if type(value) == "number" then visit(value)
        elseif value == true then visit(key) end
    end
end

--- Turns the fields argument into a set. A list of names, a set of names and
--- nil for everything all arrive here.
local function fieldSet(fields)
    if fields == nil then return nil end
    if type(fields) ~= "table" then return nil end
    local wanted = {}
    for key, value in pairs(fields) do
        if type(key) == "number" then wanted[value] = true
        elseif value then wanted[key] = true end
    end
    if next(wanted) == nil then return nil end
    return wanted
end

--------------------------------------------------------
--                     The class                      --
--------------------------------------------------------

--
--- ∑ One Records service per window. It keeps the last snapshot so the next
---   walk can carry the detail over instead of reading it all again.
--- @param services table # CE, Types and Log.
--- @return table
--
function Records:New(services)
    -- Installed here and not on the first walk, because a Cheat Table can be
    -- loaded long before anything asks this service to read anything.
    watchTableLoads()
    return setmetatable({
        CE = services and services.CE,
        Types = (services and services.Types) or Types,
        Log = services and services.Log,
        Previous = nil,        -- the snapshot the last Structure returned
        Walks = 0,             -- how many structure walks this service ran
        Reads = 0,             -- how many records the detail pass has read
        Probed = 0,            -- where the carry over check looked last
        Stale = 0              -- how often it found the carry over was wrong
    }, Records)
end

--- Which Cheat Table is loaded, as a number that moves on a load and on
--- nothing else. The window hands this to the journal.
function Records.Generation()
    return generation
end

--------------------------------------------------------
--                 The structure walk                 --
--------------------------------------------------------

--
--- ∑ One pass over the whole address list, reading an id and a child count per
---   record and nothing else.
---
---   Parents and depths come out of the pre order with a stack of remaining
---   child counts, which is why no record is ever asked for its parent. The
---   signature is a rolling hash of every id and child count, so the window can
---   tell a changed tree from an unchanged one by comparing two numbers.
---
---   Detail is carried over from the previous snapshot when the two were read
---   from the same Cheat Table, because a walk that blanked every description
---   would blank the tree with it. One record is checked against what was
---   carried over, so a table replaced by one of the same shape cannot leave
---   the old table's text on screen forever.
--- @return table|nil # The snapshot, or nil and a reason.
--- @return string|nil
--
function Records:Structure()
    local ce = self.CE
    if ce == nil then return nil, "Cheat Engine is not available." end
    -- A Cheat Table's own script may have taken the global, so the
    -- notification is put back before it is relied on.
    watchTableLoads()
    local started = now(self)
    if ce:AddressList() == nil then return nil, "The address list is not available." end
    local count = integer(ce:Count()) or 0

    local snapshot = {
        Count = 0, Signature = HASH_SEED, TableStamp = HASH_SEED, Took = 0,
        Cursor = 1, Stamp = started, Swept = false,
        Order = {}, ByID = {}, Roots = {}
    }
    local stack, failure = {}, nil
    walk(ce, 0, count, function(mr, index)
        local id = integer(ce:Get(mr, "ID"))
        if id == nil then
            failure = "Cheat Engine did not return the id of a record."
            return false
        end
        local children = integer(ce:Get(mr, "Count")) or 0
        -- Every frame whose children are all accounted for is closed before the
        -- next record, so what is left on the stack is this record's ancestry.
        while #stack > 0 and stack[#stack].Remaining <= 0 do stack[#stack] = nil end
        local parent = stack[#stack]
        local node = {
            ID = id, Index = index, ParentID = parent and parent.ID or nil,
            Depth = #stack, Children = {}, Loaded = false
        }
        if parent ~= nil then
            parent.Remaining = parent.Remaining - 1
            local holder = snapshot.ByID[parent.ID]
            if holder ~= nil then holder.Children[#holder.Children + 1] = id end
        else
            snapshot.Roots[#snapshot.Roots + 1] = id
        end
        snapshot.Order[#snapshot.Order + 1] = node
        snapshot.ByID[id] = node
        snapshot.Signature = mix(mix(snapshot.Signature, id), children)
        if children > 0 then stack[#stack + 1] = { ID = id, Remaining = children } end
    end)
    if failure ~= nil then return nil, failure end

    snapshot.Count = #snapshot.Order
    -- A list that shares no record with the last one anybody walked was read
    -- from another table, and so was a list that was emptied or filled. Both
    -- are loads this module was never told about, which is what a Cheat Table
    -- that took the onTableLoad global looks like from here.
    if lastSeen ~= nil and not sharesRecords(lastSeen, snapshot) then loaded() end
    lastSeen = snapshot
    snapshot.Generation = generation
    snapshot.TableStamp = mix(HASH_SEED, generation)

    local previous = self.Previous
    if previous ~= nil and Records.SameTable(previous, snapshot) then
        for _, node in ipairs(snapshot.Order) do
            local old = previous.ByID[node.ID]
            if old ~= nil and old.Loaded then
                for _, key in ipairs(DETAIL_KEYS) do node[key] = old[key] end
            end
        end
        -- Nothing moved, so whatever the re-read window already covered still
        -- holds and an idle window costs nothing.
        if previous.Signature == snapshot.Signature then
            snapshot.Cursor, snapshot.Swept = previous.Cursor or 1, previous.Swept == true
            -- Nothing would ever be read again either, so one record is
            -- checked against what was carried over before that is believed.
            if snapshot.Swept and not self:Probe(snapshot) then
                for _, node in ipairs(snapshot.Order) do node.Loaded = false end
                snapshot.Cursor, snapshot.Swept = 1, false
                self.Stale = self.Stale + 1
            end
        end
    end

    snapshot.Took = (now(self) - started) * 1000
    self.Previous = snapshot
    self.Walks = self.Walks + 1
    return snapshot
end

--
--- ∑ Whether two snapshots were read from the same Cheat Table.
---
---   Ids start again from one in every table, so an undo from the table before
---   would write into unrelated records. The answer is the load counter and
---   nothing else, because two tables of the same shape share every id and
---   every count and the only difference between them is that Cheat Engine
---   loaded one of them.
--- @param before table|nil
--- @param after table|nil
--- @return boolean
--
function Records.SameTable(before, after)
    if before == nil or after == nil then return false end
    if before.TableStamp == nil or after.TableStamp == nil then return false end
    return before.TableStamp == after.TableStamp
end

--
--- ∑ Checks one carried over node against the record behind it.
---
---   The carry over is what stops a structure walk blanking the tree, and it
---   is also what would hold another table's text forever once the re-read
---   window has finished. One record is read per walk, rotating through the
---   list, and a description that no longer matches means every field carried
---   over is suspect. It catches a description edited in Cheat Engine's own
---   list as well, which is the same staleness from the other side.
---
---   The address is compared only on a record that is not a pointer, because
---   AddressString resolves a pointer chain through process memory and moves
---   on its own while the game runs.
--- @param snapshot table
--- @return boolean # Whether what was carried over still holds.
--
function Records:Probe(snapshot)
    local ce = self.CE
    if ce == nil or snapshot == nil then return true end
    local total = #snapshot.Order
    if total == 0 then return true end
    local at = ((integer(self.Probed) or 0) % total) + 1
    self.Probed = at
    local node = snapshot.Order[at]
    if node == nil or node.Loaded ~= true then return true end
    local mr = self:Resolve(node.ID, snapshot)
    if mr == nil then return true end
    if (ce:Get(mr, "Description") or "") ~= (node.Description or "") then return false end
    if (integer(node.OffsetCount) or 0) > 0 then return true end
    return (ce:Get(mr, "AddressString") or "") == (node.AddressString or "")
end

--------------------------------------------------------
--                  The detail pass                   --
--------------------------------------------------------

--
--- ∑ Fills the detail fields of one node from the record behind it.
--- @param snapshot table
--- @param node table
--- @param fields table|nil # Only these keys, or nil for all of them.
--- @return boolean # Whether the record was there to read.
--
function Records:DetailNode(snapshot, node, fields)
    if node == nil then return false end
    local ce = self.CE
    if ce == nil then return false end
    local mr = self:Resolve(node.ID, snapshot)
    if mr == nil then return false end
    self:Fill(node, mr, fieldSet(fields))
    return true
end

--
--- ∑ Fills one node from a record that is already in hand.
---
---   Every field is read through this one wrapper. Reading them through a
---   chain of fresh wrappers would cost one lookup per field for nothing.
--- @param node table
--- @param mr userdata
--- @param wanted table|nil # A set of field names, or nil for all of them.
--- @return nil
--
function Records:Fill(node, mr, wanted)
    local ce = self.CE
    for _, entry in ipairs(DETAIL_READERS) do
        if wanted == nil or wanted[entry.Key] then
            local ok, value = pcall(entry.Read, ce, mr, node)
            if ok then node[entry.Key] = value end
        end
    end
    if wanted == nil then node.Loaded = true end
    self.Reads = self.Reads + 1
end

--
--- ∑ Reads a run of nodes in one walk of the address list.
---
---   The id of every record is checked against the node that sits at that
---   index, because a record added or moved in Cheat Engine since the walk
---   shifts everything after it. A node that does not line up is resolved by
---   id instead, which costs one lookup and keeps the run right.
--- @param snapshot table
--- @param first number # The position in Order to start at, one based.
--- @param size number # How many nodes at most.
--- @param fields table|nil
--- @param skipLoaded boolean # Leave the nodes that were read already alone.
--- @return number # How many nodes were read.
--
function Records:Sweep(snapshot, first, size, fields, skipLoaded)
    local ce = self.CE
    if ce == nil or snapshot == nil then return 0 end
    local order = snapshot.Order
    local start = order[first]
    if start == nil then return 0 end
    local wanted = fieldSet(fields)
    local done = 0
    walk(ce, start.Index or (first - 1), size, function(mr, index)
        local node = order[index + 1]
        if node == nil then return end
        if skipLoaded and node.Loaded then return end
        if integer(ce:Get(mr, "ID")) == node.ID then
            self:Fill(node, mr, wanted)
            done = done + 1
        elseif self:DetailNode(snapshot, node, fields) then
            done = done + 1
        end
    end)
    return done
end

--
--- ∑ Fills the detail of one node, or of every node when none is named.
--- @param snapshot table
--- @param node table|nil
--- @param fields table|nil
--- @return number # How many nodes were read.
--
function Records:Detail(snapshot, node, fields)
    if snapshot == nil then return 0 end
    if node ~= nil then
        return self:DetailNode(snapshot, node, fields) and 1 or 0
    end
    local done = self:Sweep(snapshot, 1, #snapshot.Order, fields, false)
    if fields == nil then snapshot.Cursor, snapshot.Swept = 1, true end
    return done
end

--
--- ∑ Re-reads the next few nodes and moves the cursor on.
---
---   The window is contiguous rather than spread over the snapshot, because
---   getMemoryRecord is only fast when the index asked for sits next to the
---   last one. Once the whole snapshot has been re-read since the last
---   structure change the sweep stops, so an idle window costs nothing.
--- @param snapshot table
--- @param budget number|nil
--- @return number # How many nodes were read.
--- @return boolean # Whether the sweep is finished.
--
function Records:DetailSome(snapshot, budget)
    if snapshot == nil then return 0, true end
    if snapshot.Swept == true then return 0, true end
    local total = #snapshot.Order
    if total == 0 then
        snapshot.Cursor, snapshot.Swept = 1, true
        return 0, true
    end
    local size = math.max(1, integer(budget) or DEFAULT_BUDGET)
    local first = math.max(1, integer(snapshot.Cursor) or 1)
    local last = math.min(total, first + size - 1)
    local done = self:Sweep(snapshot, first, last - first + 1, nil, false)
    snapshot.Cursor = last + 1
    if snapshot.Cursor > total then
        snapshot.Cursor, snapshot.Swept = 1, true
    end
    return done, snapshot.Swept == true
end

--
--- ∑ Makes sure the nodes a caller is about to read have their detail, and
---   says how long that took.
---
---   The filter, the problem check, the search and the export all read fields
---   the re-read window may not have reached yet. Every one of them calls this
---   first, so none of them has to know how the window works.
--- @param snapshot table
--- @param ids table|nil # A list or a set of ids, or nil for the whole table.
--- @return number # How many nodes were read.
--- @return number # Milliseconds.
--
function Records:EnsureDetail(snapshot, ids)
    if snapshot == nil then return 0, 0 end
    local started = now(self)
    local done = 0
    if ids == nil then
        -- A window that is already loaded pays nothing here, because looking
        -- for an unloaded node costs no Cheat Engine call at all.
        local pending = false
        for _, node in ipairs(snapshot.Order) do
            if not node.Loaded then
                pending = true
                break
            end
        end
        if pending then done = self:Sweep(snapshot, 1, #snapshot.Order, nil, true) end
    else
        eachID(ids, function(id)
            local node = snapshot.ByID[id]
            if node ~= nil and not node.Loaded and self:DetailNode(snapshot, node) then
                done = done + 1
            end
        end)
    end
    return done, (now(self) - started) * 1000
end

--
--- ∑ The display value of the rows that are on screen.
---
---   Reading a value reads process memory and can fire the record's own value
---   handler, so this is asked for visible rows only. Group headers and scripts
---   have no value to show and are skipped rather than read.
--- @param snapshot table
--- @param ids table # A list of ids or a set of them.
--- @return table # id to a table of Text and Readable.
--
function Records:Values(snapshot, ids)
    local out = {}
    if snapshot == nil or ids == nil then return out end
    local ce = self.CE
    if ce == nil then return out end
    eachID(ids, function(id)
        local node = snapshot.ByID[id]
        if node ~= nil and not node.IsGroupHeader and node.Type ~= SCRIPT_TYPE then
            local mr = self:Resolve(id, snapshot)
            if mr ~= nil then
                local text = ce:Get(mr, "DisplayValue")
                if type(text) ~= "string" then text = "??" end
                out[id] = { Text = text, Readable = text ~= "??" }
            end
        end
    end)
    return out
end

--------------------------------------------------------
--                  Finding a record                  --
--------------------------------------------------------

--
--- ∑ The memory record behind an id, by the snapshot's index first.
---
---   The index is right almost always and costs one call. It is verified by
---   reading the id back, because a record added or moved in Cheat Engine since
---   the walk would shift every index after it.
--- @param id number
--- @param snapshot table|nil
--- @return userdata|nil
--
function Records:Resolve(id, snapshot)
    local ce = self.CE
    if ce == nil or id == nil then return nil end
    local node = snapshot ~= nil and snapshot.ByID[id] or nil
    if node ~= nil and node.Index ~= nil then
        local mr = ce:RecordAt(node.Index)
        if mr ~= nil and integer(ce:Get(mr, "ID")) == id then return mr end
    end
    return ce:RecordByID(id)
end

--
--- ∑ The record's place in the tree, as a person would read it out.
--- @param snapshot table
--- @param id number
--- @return string
--
function Records:Path(snapshot, id)
    if snapshot == nil then return "" end
    local parts, node, guard = {}, snapshot.ByID[id], 0
    while node ~= nil and guard < MAX_DEPTH do
        local name = node.Description
        if name == nil or name == "" then name = "#" .. tostring(node.ID) end
        table.insert(parts, 1, name)
        node = node.ParentID ~= nil and snapshot.ByID[node.ParentID] or nil
        guard = guard + 1
    end
    return table.concat(parts, " > ")
end

--------------------------------------------------------
--                 The query language                 --
--------------------------------------------------------

--- The prefixes that make a predicate. Anything else before a colon is part of
--- the text the person is looking for.
local PREFIXES = { type = true, is = true, has = true, id = true }

--- Splits a filter into tokens, keeping what a pair of quotes holds together.
--- A token that starts with a quote is text even when it carries a colon.
local function splitTokens(text)
    local out, buffer = {}, {}
    local inQuote, lead = false, false
    local function flush()
        if #buffer == 0 then return end
        out[#out + 1] = { Text = table.concat(buffer), Lead = lead }
        buffer, lead = {}, false
    end
    for index = 1, #text do
        local char = text:sub(index, index)
        if char == '"' then
            if #buffer == 0 and not inQuote then lead = true end
            inQuote = not inQuote
        elseif (char == " " or char == "\t") and not inQuote then
            flush()
        else
            buffer[#buffer + 1] = char
        end
    end
    flush()
    return out
end

--
--- ∑ Turns what a person typed into the tokens the matcher runs.
---
---   Every token is an and. Text is a plain substring and never a Lua pattern,
---   because a description full of brackets and percent signs is normal and a
---   pattern would either raise or match the wrong rows.
--- @param text string|nil
--- @return table # Text, Predicates, Raw and Empty.
--
function Records.ParseQuery(text)
    local query = { Text = {}, Predicates = {}, Raw = text or "", Empty = true }
    if type(text) ~= "string" then return query end
    for _, token in ipairs(splitTokens(text)) do
        local prefix, value = nil, nil
        if not token.Lead then prefix, value = token.Text:match("^(%a+):(.*)$") end
        prefix = prefix and prefix:lower() or nil
        if prefix ~= nil and PREFIXES[prefix] and value ~= "" then
            if prefix == "id" then
                local id = integer(value)
                if id ~= nil then
                    query.Predicates[#query.Predicates + 1] = { Kind = "id", Value = id }
                else
                    query.Text[#query.Text + 1] = token.Text:lower()
                end
            elseif prefix == "type" then
                local lowered = value:lower()
                query.Predicates[#query.Predicates + 1] = {
                    Kind = "type", Value = lowered, Entry = Types.Parse(value),
                    Group = lowered == "grp" or lowered == "group",
                    Pointer = lowered == "ptr" or lowered == "pointer"
                }
            else
                query.Predicates[#query.Predicates + 1] =
                    { Kind = prefix, Value = value:lower() }
            end
        else
            query.Text[#query.Text + 1] = token.Text:lower()
        end
    end
    query.Empty = #query.Text == 0 and #query.Predicates == 0
    return query
end

--- The is tests, one per word the filter understands.
local IS_TESTS = {
    active = function(node) return node.Active == true end,
    inactive = function(node) return node.Active ~= true end,
    group = function(node) return node.IsGroupHeader == true end,
    pointer = function(node) return (node.OffsetCount or 0) > 0 end,
    script = function(node) return node.Type == SCRIPT_TYPE end,
    dontsave = function(node) return node.DontSave == true end,
    linked = function(node) return node.DropDownLinked == true end,
    problem = function(node, query)
        return query.Problems ~= nil and query.Problems[node.ID] ~= nil
            and query.Problems[node.ID] ~= false
    end
}

--- The has tests. A colour counts as one only when it is not the colour every
--- record starts with.
local HAS_TESTS = {
    hotkey = function(node) return (node.HotkeyCount or 0) > 0 end,
    hotkeys = function(node) return (node.HotkeyCount or 0) > 0 end,
    dropdown = function(node) return (node.DropDownCount or 0) > 0 end,
    children = function(node) return #node.Children > 0 end,
    color = function(node)
        local color = node.Color
        if color == nil then return false end
        return color ~= defaultColor() and color ~= DEFAULT_COLOR
            and color ~= DEFAULT_COLOR_ALT
    end,
    colour = function(node) return HAS_TESTS.color(node) end,
    offsets = function(node) return (node.OffsetCount or 0) > 0 end
}

local function matchPredicate(node, predicate, query)
    local kind = predicate.Kind
    if kind == "id" then return node.ID == predicate.Value end
    if kind == "is" then
        local test = IS_TESTS[predicate.Value]
        return test ~= nil and test(node, query) == true
    end
    if kind == "has" then
        local test = HAS_TESTS[predicate.Value]
        return test ~= nil and test(node) == true
    end
    if kind == "type" then
        if predicate.Group then return node.IsGroupHeader == true end
        if predicate.Pointer then return (node.OffsetCount or 0) > 0 end
        if predicate.Entry == nil then return false end
        local entry = Types.For(node)
        return entry ~= nil and entry.Key == predicate.Entry.Key
    end
    return false
end

local function matchNode(node, query)
    for _, predicate in ipairs(query.Predicates) do
        if not matchPredicate(node, predicate, query) then return false end
    end
    if #query.Text == 0 then return true end
    local haystack = ((node.Description or "") .. "\n" .. (node.AddressString or "")):lower()
    for _, needle in ipairs(query.Text) do
        if haystack:find(needle, 1, true) == nil then return false end
    end
    return true
end

--
--- ∑ Runs a query over a snapshot.
---
---   A record is visible when it matches or when one of its descendants does,
---   so the ancestors of every match come back in the visible set as well. The
---   tree passes that same set as the one to force open, which is how a filter
---   shows a match inside a collapsed group without touching what the person
---   collapsed by hand.
--- @param snapshot table
--- @param query table
--- @return table|nil # The visible ids, or nil when nothing is filtered.
--- @return table # The ids that matched.
--- @return number # How many matched.
--
function Records.Match(snapshot, query)
    if snapshot == nil or query == nil or query.Empty then return nil, {}, 0 end
    local matches, count = {}, 0
    for _, node in ipairs(snapshot.Order) do
        if matchNode(node, query) then
            matches[node.ID] = true
            count = count + 1
        end
    end
    local visible = {}
    for id in pairs(matches) do
        visible[id] = true
        local node = snapshot.ByID[id]
        local guard = 0
        while node ~= nil and node.ParentID ~= nil and guard < MAX_DEPTH do
            visible[node.ParentID] = true
            node = snapshot.ByID[node.ParentID]
            guard = guard + 1
        end
    end
    return visible, matches, count
end

--------------------------------------------------------
--                        Rows                        --
--------------------------------------------------------

--
--- ∑ The rows the tree draws, in the order it draws them.
---
---   A node that is not visible takes its whole branch with it, which is right
---   because the visible set already carries the ancestor of every match.
--- @param snapshot table
--- @param collapsed table|nil # Ids the person collapsed.
--- @param visible table|nil # Ids a filter allows, or nil for all of them.
--- @param forceOpen table|nil # Ids shown open while a filter is on.
--- @param matches table|nil # Ids that matched, for the highlight.
--- @return table # Rows of ID, Depth, HasChildren, Expanded, Match and Node.
--
function Records.Flatten(snapshot, collapsed, visible, forceOpen, matches)
    local rows = {}
    if snapshot == nil then return rows end
    collapsed = collapsed or {}
    local function walk(id)
        local node = snapshot.ByID[id]
        if node == nil then return end
        if visible ~= nil and not visible[id] then return end
        local hasChildren = #node.Children > 0
        local expanded = hasChildren
            and (collapsed[id] ~= true or (forceOpen ~= nil and forceOpen[id] == true))
        rows[#rows + 1] = {
            ID = id, Depth = node.Depth, HasChildren = hasChildren,
            Expanded = expanded == true,
            Match = matches ~= nil and matches[id] == true,
            Node = node
        }
        if expanded then
            for _, child in ipairs(node.Children) do walk(child) end
        end
    end
    for _, id in ipairs(snapshot.Roots) do walk(id) end
    return rows
end

--- Every id under a record, in pre order, without the record itself.
function Records.Descendants(snapshot, id)
    local out = {}
    if snapshot == nil then return out end
    local function walk(current)
        local node = snapshot.ByID[current]
        if node == nil then return end
        for _, child in ipairs(node.Children) do
            out[#out + 1] = child
            walk(child)
        end
    end
    walk(id)
    return out
end

--- True when the first id sits above the second one in the tree.
function Records.IsAncestor(snapshot, a, b)
    if snapshot == nil or a == nil or b == nil then return false end
    local node, guard = snapshot.ByID[b], 0
    while node ~= nil and node.ParentID ~= nil and guard < MAX_DEPTH do
        if node.ParentID == a then return true end
        node = snapshot.ByID[node.ParentID]
        guard = guard + 1
    end
    return false
end

--------------------------------------------------------
--                   Moving records                   --
--------------------------------------------------------

--
--- ∑ The ids a group holds right now, read straight off the record.
---
---   Reorder needs these. Appending a child to the parent it already has leaves
---   the parent alone, so reading the parent back proves nothing there and only
---   the order says whether anything happened at all.
--- @param self table
--- @param targetMr userdata
--- @return table|nil # The child ids in order, or nil when they cannot be read.
--
local function childIDs(self, targetMr)
    local ce = self.CE
    if ce == nil or targetMr == nil then return nil end
    local count = integer(ce:Get(targetMr, "Count")) or 0
    local out = {}
    for index = 0, count - 1 do
        local child = nil
        local ok, value = pcall(function() return targetMr.getChild(index) end)
        if ok then child = value end
        if child == nil then
            local holder = ce:Get(targetMr, "Child")
            if holder ~= nil then child = ce:Get(holder, index) end
        end
        local id = integer(ce:Get(child, "ID"))
        if id == nil then return nil end
        out[#out + 1] = id
    end
    return out
end

--- Appends one record to a group and reads the parent back, because a move into
--- a record's own branch does nothing and says nothing.
local function appendVerified(self, id, targetMr, targetId, snapshot)
    local mr = self:Resolve(id, snapshot)
    if mr == nil then return false, "The record is gone." end
    local ok = pcall(function() mr.appendToEntry(targetMr) end)
    if not ok then return false, "Cheat Engine refused the move." end
    local after = self:Resolve(id, snapshot)
    if after == nil then return false, "The record is gone." end
    local parent = self.CE:Get(after, "Parent")
    if parent == nil then return false, "Cheat Engine did not move the record." end
    if integer(self.CE:Get(parent, "ID")) ~= targetId then
        return false, "Cheat Engine did not move the record."
    end
    return true
end

--
--- ∑ Puts the children of one group back in the order given.
---
---   Appending a record to its own parent moves it to the end, so appending
---   every child in the wanted order leaves them in that order. It only works
---   inside a group. Cheat Engine offers nothing that reorders the root.
---
---   The group is read back afterwards. A child is already inside the parent,
---   so a parent that still reads right says nothing, and only the order the
---   children came out in proves the appends happened.
--- @param snapshot table
--- @param parentId number
--- @param orderedIds table # Every child of the group, in the wanted order.
--- @return boolean
--- @return string|nil # The reason when it did not happen.
--
function Records:Reorder(snapshot, parentId, orderedIds)
    if snapshot == nil then return false, "There is no snapshot to work from." end
    if parentId == nil then
        return false, "Cheat Engine offers no way to reorder records at the root."
    end
    local parent = snapshot.ByID[parentId]
    if parent == nil then return false, "The group is gone." end
    if type(orderedIds) ~= "table" or #orderedIds == 0 then
        return false, "No order was given."
    end
    if #orderedIds ~= #parent.Children then
        return false, "The order does not list every child of the group."
    end
    local seen = {}
    for _, id in ipairs(orderedIds) do
        -- A record appended into itself or into its own branch moves nowhere
        -- and Cheat Engine says nothing about it, so the order is checked here
        -- before a single call goes out.
        if id == parentId then
            return false, "A record cannot be moved into itself."
        end
        if Records.IsAncestor(snapshot, id, parentId) then
            return false, "The group is inside one of the records."
        end
        seen[id] = true
    end
    for _, id in ipairs(parent.Children) do
        if not seen[id] then return false, "The order does not list every child of the group." end
    end
    local targetMr = self:Resolve(parentId, snapshot)
    if targetMr == nil then return false, "The group is gone." end
    local failed = nil
    for _, id in ipairs(orderedIds) do
        local ok, reason = appendVerified(self, id, targetMr, parentId, snapshot)
        if not ok and failed == nil then failed = reason end
    end
    if failed == nil then
        -- The children were already in the group, so the only proof the appends
        -- did anything is the order they sit in now.
        local after = childIDs(self, self:Resolve(parentId, snapshot))
        if after == nil then
            failed = "Cheat Engine did not say what the group holds now."
        elseif table.concat(after, ",") ~= table.concat(orderedIds, ",") then
            failed = "Cheat Engine did not reorder the group."
        end
    end
    if failed ~= nil then
        say(self, "Warning", "Reorder in '" .. self:Path(snapshot, parentId) .. "' failed. " .. failed)
        return false, failed
    end
    say(self, "Info", "Reordered " .. #orderedIds .. " records in '"
        .. self:Path(snapshot, parentId) .. "'.")
    return true
end

--
--- ∑ Moves records into a group, keeping the order they had.
---
---   Appending puts a record last, so the records are taken in pre order and
---   arrive in that same order. A target inside one of the moved records is
---   refused here, because Cheat Engine would do nothing and say nothing.
--- @param snapshot table
--- @param ids table # The ids to move.
--- @param targetId number
--- @return table # The ids that moved.
--- @return table # One entry of ID and Reason per record that did not.
--
function Records:MoveInto(snapshot, ids, targetId)
    local moved, failures = {}, {}
    if snapshot == nil or type(ids) ~= "table" then
        failures[#failures + 1] = { ID = nil, Reason = "There is nothing to move." }
        return moved, failures
    end
    local target = snapshot.ByID[targetId]
    if target == nil then
        failures[#failures + 1] = { ID = targetId, Reason = "The group is gone." }
        return moved, failures
    end
    local targetMr = self:Resolve(targetId, snapshot)
    if targetMr == nil then
        failures[#failures + 1] = { ID = targetId, Reason = "The group is gone." }
        return moved, failures
    end
    local ordered = {}
    for _, id in ipairs(ids) do
        local node = snapshot.ByID[id]
        if node ~= nil then ordered[#ordered + 1] = node end
    end
    table.sort(ordered, function(a, b) return a.Index < b.Index end)
    for _, node in ipairs(ordered) do
        local id = node.ID
        if id == targetId then
            failures[#failures + 1] = { ID = id, Reason = "A record cannot be moved into itself." }
        elseif Records.IsAncestor(snapshot, id, targetId) then
            failures[#failures + 1] = { ID = id, Reason = "The group is inside the record." }
        else
            local ok, reason = appendVerified(self, id, targetMr, targetId, snapshot)
            if ok then moved[#moved + 1] = id
            else failures[#failures + 1] = { ID = id, Reason = reason } end
        end
    end
    say(self, "Info", "Moved " .. #moved .. " records into '"
        .. self:Path(snapshot, targetId) .. "'"
        .. (#failures > 0 and (", " .. #failures .. " failed.") or "."))
    return moved, failures
end

--
--- ∑ Makes one record, and puts it in a group when one is named.
---
---   Cheat Engine appends a four byte record described Plugin Address at the
---   end of the root, and this is the one Lua edit that marks the table as
---   edited. It cannot be undone, because undoing it would mean deleting a
---   record and this window never deletes one.
--- @param parentId number|nil
--- @param options table|nil # Description, IsGroupHeader and Type.
--- @return number|nil # The new id, or nil and a reason.
--- @return string|nil
--
function Records:Create(parentId, options)
    local ce = self.CE
    if ce == nil then return nil, "Cheat Engine is not available." end
    options = options or {}
    local mr = ce:CreateRecord()
    if mr == nil then return nil, "Cheat Engine did not create the record." end
    local id = integer(ce:Get(mr, "ID"))
    if id == nil then return nil, "Cheat Engine did not give the record an id." end

    if options.Description ~= nil then
        pcall(function() mr.Description = tostring(options.Description) end)
    end
    if options.IsGroupHeader == true then
        pcall(function() mr.IsGroupHeader = true end)
    end
    local entry = options.Type
    if type(entry) == "string" then entry = Types.Parse(entry) end
    if type(entry) == "number" then entry = Types.ByType[entry] end
    if entry ~= nil then
        -- Cheat Engine range checks nothing here, so the integer only ever
        -- comes out of the type list.
        pcall(function() mr.Type = entry.Type end)
    end

    local note = nil
    if parentId ~= nil then
        local snapshot = self.Previous
        local targetMr = self:Resolve(parentId, snapshot)
        if targetMr == nil then
            note = "The group is gone, so the record was made at the root."
        else
            local ok = pcall(function() mr.appendToEntry(targetMr) end)
            local parent = ce:Get(mr, "Parent")
            if not ok or parent == nil or integer(ce:Get(parent, "ID")) ~= parentId then
                note = "The record was made at the root, Cheat Engine did not move it into the group."
            end
        end
    end
    say(self, "Info", "Created record " .. id .. " '"
        .. tostring(options.Description or "Plugin Address") .. "'."
        .. (note and (" " .. note) or ""))
    return id, note
end

return Records
