--[[
    Bulk operations on the address list: deactivating the scripts or
    everything, and renumbering the IDs.

    Cheat Engine's address list indexes every record, children included, in
    tree order. The walk below also follows Child[] with a seen-set keyed by
    ID, so it is right whether a build's Count means the flat list or only
    the top level, and it does not depend on two userdata for the same
    record comparing equal, which they do not.

    Deactivation goes backwards, children before parents, and sets Active =
    false, which runs each record's [DISABLE] section. That is the point:
    "Deactivate Everything" is the button for bringing a table to a known
    state with its hooks removed. The framework's ProcessHandler uses
    disableAllWithoutExecute for the opposite case, a process that is gone.

    ID normalization is transactional. Every record first moves into a
    temporary range no current ID occupies, then into 1..N. Cheat Engine
    keeps IDs unique, so writing 1..N straight over the old IDs would
    collide with any original that happens to be a small number and has not
    been overwritten yet. A failure in either phase puts back exactly the
    records that changed, parking the ones holding a final ID in the
    temporary range first for the same reason.
]]

local Records = {}
Records.__index = Records

Records.TemporaryBase = 1000000000
Records.MaxId = 2147483647

function Records:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Settings = deps.Settings
    }, Records)
end

local function integer(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.tointeger(number) or math.floor(number)
end

--
--- ∑ Every record in the table, children included, in tree order, once.
--- @param addressList userdata
--- @return table
--
function Records:Collect(addressList)
    local ce = self.CE
    local found, seen = {}, {}
    local function visit(record)
        if record == nil then return end
        local key = ce:Get(record, "ID")
        if key == nil then key = record end
        if seen[key] then return end
        seen[key] = true
        found[#found + 1] = record
        local count = integer(ce:Get(record, "Count")) or 0
        for index = 0, count - 1 do
            local ok, child = pcall(function() return record.Child[index] end)
            if ok and child ~= nil then visit(child) end
        end
    end
    local count = integer(ce:Get(addressList, "Count")) or 0
    for index = 0, count - 1 do
        local ok, record = pcall(function() return addressList[index] end)
        if ok and record ~= nil then visit(record) end
    end
    return found
end

--
--- ∑ The active records, optionally only the Auto Assembler scripts.
--- @param records table
--- @param scriptsOnly boolean
--- @return table
--
function Records:Active(records, scriptsOnly)
    local scriptType = self.CE:Constant("vtAutoAssembler", 11)
    local found = {}
    for _, record in ipairs(records) do
        if self.CE:Get(record, "Active") == true
            and (not scriptsOnly or self.CE:Get(record, "Type") == scriptType) then
            found[#found + 1] = record
        end
    end
    return found
end

--
--- ∑ Deactivates the active scripts, or every active record.
--- @param scriptsOnly boolean
--- @return boolean
--
function Records:Deactivate(scriptsOnly)
    local log = self.Log
    local label = scriptsOnly and "Deactivate all scripts" or "Deactivate everything"
    local addressList = self.CE:AddressList()
    if not addressList then
        log:Error(label .. ": the address list is not available.")
        return false
    end
    local active = self:Active(self:Collect(addressList), scriptsOnly)
    if #active == 0 then
        log:Info(label .. ": nothing is active.")
        return false
    end
    if self.Settings.ConfirmDestructiveActions then
        local yes, reason = self.CE:Confirm(
            scriptsOnly and "Deactivate all active Auto Assembler scripts?"
                or "Deactivate every active address list entry?",
            #active)
        if not yes then
            log:Info(label .. ": " .. (reason and ("blocked, " .. reason) or "cancelled") .. ".")
            return false
        end
    end
    local done, failed = 0, 0
    local ok, err = self.CE:RunInMain(function()
        for index = #active, 1, -1 do
            local wrote = pcall(function() active[index].Active = false end)
            if wrote then done = done + 1 else failed = failed + 1 end
        end
    end)
    self.CE:Repaint()
    if not ok then
        log:Error(label .. " failed: " .. tostring(err))
        return false
    end
    if failed > 0 then
        log:Warning(string.format("%s: %d deactivated, %d refused.", label, done, failed))
    else
        log:Info(string.format("%s: %d deactivated.", label, done))
    end
    return failed == 0
end

--------------------------------------------------------
--                   ID normalization                 --
--------------------------------------------------------

--
--- ∑ A block of `count` consecutive IDs none of the originals use, starting
---   the search high above anything a table normally has.
--- @param original table
--- @param count number
--- @return number|nil
--
function Records:FreeRange(original, count)
    local used = {}
    for _, id in ipairs(original) do used[id] = true end
    local candidate = Records.TemporaryBase
    local limit = Records.MaxId - count - 1
    while candidate <= limit do
        local free = true
        for offset = 1, count do
            if used[candidate + offset] then
                free = false
                break
            end
        end
        if free then return candidate end
        candidate = candidate + count + 1
    end
    return nil
end

--
--- ∑ Writes one ID per record, stopping at the first refusal.
--- @param records table
--- @param ids table
--- @param from number|nil # First index to write, 1 by default.
--- @param to number|nil # Last index to write, #records by default.
--- @return number|nil, string|nil # The index that failed and why.
--
function Records:Assign(records, ids, from, to)
    for index = from or 1, to or #records do
        local ok, err = pcall(function() records[index].ID = ids[index] end)
        if not ok then return index, tostring(err) end
    end
    return nil
end

--
--- ∑ Puts the original IDs back on the records that changed. After a
---   failure in the temporary phase, records before `failedAt` hold
---   temporaries and the rest never changed. After a failure in the final
---   phase, records before `failedAt` hold final IDs, which can collide with
---   an original still to be restored, so they are parked in the temporary
---   range first; the rest hold temporaries.
--- @param records table
--- @param original table
--- @param temporary table
--- @param failedAt number
--- @param afterFinal boolean
--- @return boolean, number # Whether every record is back, and how many are not.
--
function Records:Restore(records, original, temporary, failedAt, afterFinal)
    local stuck = {}
    local function put(ids, from, to)
        for index = from, to do
            local ok = pcall(function() records[index].ID = ids[index] end)
            if not ok then stuck[index] = true end
        end
    end
    if afterFinal then
        put(temporary, 1, failedAt - 1)
        put(original, 1, #records)
    else
        put(original, 1, failedAt - 1)
    end
    local count = 0
    for _ in pairs(stuck) do count = count + 1 end
    return count == 0, count
end

--
--- ∑ Renumbers every record 1..N in tree order.
--- @return boolean
--
function Records:NormalizeIDs()
    local log = self.Log
    local addressList = self.CE:AddressList()
    if not addressList then
        log:Error("Normalize IDs: the address list is not available.")
        return false
    end
    local records = self:Collect(addressList)
    if #records == 0 then
        log:Info("Normalize IDs: the table is empty.")
        return false
    end
    local original = {}
    for index, record in ipairs(records) do
        local id = integer(self.CE:Get(record, "ID"))
        if id == nil then
            log:Error(string.format("Normalize IDs: record #%d has no readable ID. Nothing was changed.", index))
            return false
        end
        original[index] = id
    end
    if self.Settings.ConfirmDestructiveActions then
        local yes, reason = self.CE:Confirm(
            string.format("Normalize Cheat Table IDs to 1..%d?", #records), #records,
            "Anything that refers to records by ID stops matching afterwards: " ..
            "Manifold state files, table Lua using getMemoryRecordByID, and " ..
            "hotkeys or scripts that were given an ID.")
        if not yes then
            log:Info("Normalize IDs: " .. (reason and ("blocked, " .. reason) or "cancelled") .. ".")
            return false
        end
    end
    local base = self:FreeRange(original, #records)
    if not base then
        log:Error("Normalize IDs: could not reserve a temporary ID range. Nothing was changed.")
        return false
    end
    local temporary, final = {}, {}
    for index = 1, #records do
        temporary[index] = base + index
        final[index] = index
    end

    local restored, stuck = nil, 0
    local ok, err = self.CE:RunInMain(function()
        local at, why = self:Assign(records, temporary)
        if at then
            restored, stuck = self:Restore(records, original, temporary, at, false)
            error(string.format("temporary ID on record #%d: %s", at, why), 0)
        end
        at, why = self:Assign(records, final)
        if at then
            restored, stuck = self:Restore(records, original, temporary, at, true)
            error(string.format("final ID on record #%d: %s", at, why), 0)
        end
    end)
    self.CE:Repaint()
    if not ok then
        log:Error(string.format("Normalize IDs failed (%s). %s", tostring(err),
            restored and "The original IDs were restored."
                or string.format("%d record(s) could not be restored; check the table.", stuck)))
        return false
    end
    log:Info(string.format("Normalized %d Cheat Table IDs to 1..%d.", #records, #records))
    return true
end

return Records
