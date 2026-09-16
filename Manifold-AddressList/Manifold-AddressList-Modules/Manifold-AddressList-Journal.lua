--[[
    Undo and redo, kept by this window because Cheat Engine keeps none.

    Cheat Engine has no structural undo at all, and the per record value undo it
    does have is not reachable from Lua. So every edit this window makes is
    written down as a transaction of changes, each change holding the old value
    and the new one, and undo writes the old values back in reverse.

    The journal never touches Cheat Engine. It is handed one Apply function and
    calls that, which is what keeps it pure enough to test with no Cheat Engine
    anywhere and stops a second place from learning how to write a record.

    Two rules come out of how Cheat Engine numbers records. Ids start again from
    one in every Cheat Table, so a transaction carries the stamp of the table it
    was made against and a stamp that no longer matches means every change in it
    is skipped rather than written into an unrelated record. And a change is
    keyed by id and never by a record, because a wrapper held past a delete is a
    use after free.

    A transaction whose changes were all skipped still moves the cursor. It
    happened, the records it named are gone or refused, and pretending it never
    happened would leave the history describing a state that never existed.
]]

local Journal = {}
Journal.__index = Journal

--- How many transactions are kept by default. Two hundred bulk edits is far
--- more than a session needs and still nothing in memory.
local DEFAULT_LIMIT = 200

--- The kinds of change the appliers know. The journal itself only carries
--- them, but a kind it has never heard of is almost always a typo.
Journal.Kinds = {
    property = true, pointer = true, script = true,
    dropdown = true, order = true, hotkey = true
}

--- Sends one line to the log channel when there is one.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--
--- ∑ One journal per host, so the history survives the window closing.
--- @param services table # Limit, Apply, Log and Stamp.
--- @return table
--
function Journal:New(services)
    services = services or {}
    return setmetatable({
        Limit = tonumber(services.Limit) or DEFAULT_LIMIT,
        Apply = services.Apply,
        Log = services.Log,
        -- The Cheat Table the history belongs to. A transaction made against
        -- another one can never be applied.
        Stamp = services.Stamp,
        Items = {},      -- transactions, oldest first
        Cursor = 0       -- how many of them are applied right now
    }, Journal)
end

--
--- ∑ Points the journal at a Cheat Table and throws the history away when it
---   is a different one.
---
---   Every id in the old history would name a record in the new table, and
---   undoing into those records is the one mistake this window must never
---   make.
---   The window calls this after every walk of the address list and not only
---   after the first one, so the stamp follows the table that is really in
---   front of it. It says how many transactions went, because the caller has
---   to tell an undo that was refused from an undo there was never anything to
---   do.
--- @param stamp number|nil
--- @return boolean # Whether the table changed.
--- @return number # How many transactions were thrown away.
--
function Journal:SetStamp(stamp)
    if self.Stamp == stamp then return false, 0 end
    local had = #self.Items
    self.Stamp = stamp
    self:Clear()
    if had > 0 then
        say(self, "Info", "A different Cheat Table is loaded. The undo history was dropped.")
    end
    return true, had
end

--- How many transactions the history holds right now, undone ones included.
--- Entries builds a list, and a caller that only wants the number should not
--- pay for one.
function Journal:Count()
    return #self.Items
end

--
--- ∑ Writes one transaction down and drops whatever was undone before it.
---
---   Redo only means anything while nothing new has happened since, so a push
---   after an undo cuts the tail off. That is what every editor does and what
---   a person expects.
--- @param tx table # Label, Changes and an optional Stamp.
--- @return table # The transaction, as it was stored.
--
function Journal:Push(tx)
    if type(tx) ~= "table" then return nil end
    tx.Changes = tx.Changes or {}
    tx.Label = tx.Label or "Edit"
    tx.Stamp = tx.Stamp or os.time()
    tx.TableStamp = self.Stamp
    for index = #self.Items, self.Cursor + 1, -1 do self.Items[index] = nil end
    self.Items[#self.Items + 1] = tx
    while #self.Items > self.Limit do table.remove(self.Items, 1) end
    self.Cursor = #self.Items
    return tx
end

function Journal:CanUndo() return self.Cursor >= 1 end

function Journal:CanRedo() return self.Cursor < #self.Items end

function Journal:UndoLabel()
    local tx = self.Items[self.Cursor]
    return tx and tx.Label or nil
end

function Journal:RedoLabel()
    local tx = self.Items[self.Cursor + 1]
    return tx and tx.Label or nil
end

--
--- ∑ Hands one change to the applier and turns whatever comes back into an ok
---   and a reason.
---
---   The applier touches Cheat Engine, so it is called in pcall. An applier
---   that raises is a defect in the caller and not a reason to lose the rest of
---   the transaction.
--- @param change table
--- @param value any
--- @return boolean
--- @return string|nil
--
function Journal:Run(change, value)
    if type(self.Apply) ~= "function" then
        return false, "There is nothing to apply the change with."
    end
    local ok, result, reason = pcall(self.Apply, change, value)
    if not ok then return false, tostring(result) end
    if result ~= true then return false, reason or "Cheat Engine did not take the change." end
    return true
end

--- Whether a transaction belongs to the Cheat Table that is loaded now.
local function belongs(self, tx)
    return self.Stamp == nil or tx.TableStamp == nil or tx.TableStamp == self.Stamp
end

--
--- ∑ Puts the last transaction back the way it was.
---
---   The changes go in reverse, because two changes of one field in one
---   transaction have to unwind in the order they were made.
--- @return number # How many changes were written back.
--- @return table # One entry of ID, Key and Reason per change that was not.
--
function Journal:Undo()
    local skipped = {}
    local tx = self.Items[self.Cursor]
    if tx == nil then return 0, skipped end
    local applied = 0
    if not belongs(self, tx) then
        for _, change in ipairs(tx.Changes) do
            skipped[#skipped + 1] = { ID = change.ID, Key = change.Key,
                Reason = "The change belongs to a different Cheat Table." }
        end
    else
        for index = #tx.Changes, 1, -1 do
            local change = tx.Changes[index]
            local ok, reason = self:Run(change, change.Old)
            if ok then applied = applied + 1
            else skipped[#skipped + 1] = { ID = change.ID, Key = change.Key, Reason = reason } end
        end
    end
    -- The transaction happened whatever the records did with it, so the cursor
    -- moves even when every change was skipped.
    self.Cursor = self.Cursor - 1
    return applied, skipped
end

--
--- ∑ Does the last undone transaction again, in the order it was made.
--- @return number
--- @return table
--
function Journal:Redo()
    local skipped = {}
    local tx = self.Items[self.Cursor + 1]
    if tx == nil then return 0, skipped end
    local applied = 0
    if not belongs(self, tx) then
        for _, change in ipairs(tx.Changes) do
            skipped[#skipped + 1] = { ID = change.ID, Key = change.Key,
                Reason = "The change belongs to a different Cheat Table." }
        end
    else
        for _, change in ipairs(tx.Changes) do
            local ok, reason = self:Run(change, change.New)
            if ok then applied = applied + 1
            else skipped[#skipped + 1] = { ID = change.ID, Key = change.Key, Reason = reason } end
        end
    end
    self.Cursor = self.Cursor + 1
    return applied, skipped
end

--
--- ∑ The history, newest first, for the changes this session view.
--- @return table # Label, Count, Stamp and Undone per transaction.
--
function Journal:Entries()
    local out = {}
    for index = #self.Items, 1, -1 do
        local tx = self.Items[index]
        out[#out + 1] = {
            Label = tx.Label, Count = #tx.Changes, Stamp = tx.Stamp,
            Undone = index > self.Cursor
        }
    end
    return out
end

--- Throws the whole history away. The window calls this when another Cheat
--- Table is loaded.
function Journal:Clear()
    self.Items, self.Cursor = {}, 0
end

return Journal
