--[[
    The table file layer: everything that touches Cheat Engine's attached
    files, and nothing that draws.

    Kept free of UI on purpose. Every function here is callable headless,
    which is what lets the test run cover reading, writing, renaming and
    importing without building a window.

    Cheat Engine specifics this file relies on, from the CE 7.5 Lua API:
      * findTableFile / createTableFile return a TTableFile whose bytes are
        reachable two ways. getData() hands back the MemoryStream, .Stream is
        the same object; both are written through.
      * MemoryStream has loadFromFileNoError / saveToFileNoError, which report
        a reason instead of raising. Those are the import and export paths:
        the bytes never pass through a Lua string, so nothing can be
        transformed on the way, and a 40 MB attachment costs no Lua memory.
        The byte-level path stays as a fallback for builds without them.
      * copyFrom(stream, count) duplicates exactly, which is what Duplicate
        and the verification half of Rename use.
      * There is no enumeration call for attached files. The Table menu is the
        list, which is why ListNames walks miTable.
      * There is no rename either, so Rename is copy-verify-delete.

    Nothing here rewrites a file it was only asked to read. Line endings are
    never normalised: content goes in and comes out as the same bytes.
]]

local Files = {}
Files.__index = Files

--- Read and written in chunks: string.char(table.unpack(...)) over a whole
--- file blows the argument limit, and these files routinely are large enough.
local CHUNK = 4096

--- How much of a file is examined to decide whether it is text.
local SNIFF = 4096

function Files:New(services)
    services = services or {}
    return setmetatable({
        Log = services.Log,
        Types = services.Types
    }, Files)
end

function Files:Fail(message)
    if type(self.Log) == "function" then self.Log(message, true) end
end

-- Names -----------------------------------------------------------------------

--
--- ∑ Whether a name is attached to the table.
--- @param fileName string # The file name.
--- @return boolean
--
function Files:Exists(fileName)
    if type(findTableFile) ~= "function" or fileName == nil then return false end
    local ok, file = pcall(findTableFile, fileName)
    return ok and file ~= nil
end

--
--- ∑ Whether a name can be used for a table file.
---   Cheat Engine stores these by name in the table's XML, so the characters
---   a path would reject are the ones to keep out.
--- @param fileName string # The candidate.
--- @return boolean, string|nil # Valid, or false plus the reason.
--
function Files:ValidateName(fileName)
    fileName = tostring(fileName or ""):match("^%s*(.-)%s*$")
    if fileName == "" then return false, "The name is empty." end
    if fileName:find('[\\/:%*%?"<>|]') then
        return false, 'A name cannot contain \\ / : * ? " < > or |'
    end
    if fileName:find("^%.+$") then return false, "That name is not usable." end
    if #fileName > 255 then return false, "That name is too long." end
    return true
end

--
--- ∑ A free name near the one asked for: "Hook.CEA" -> "Hook (2).CEA".
--- @param fileName string # The wanted name.
--- @return string # A name no attached file is using.
--
function Files:SuggestName(fileName)
    if not self:Exists(fileName) then return fileName end
    local stem, dot, extension = tostring(fileName):match("^(.-)(%.?)([%w_]*)$")
    if dot ~= "." then stem, extension = tostring(fileName), nil end
    for counter = 2, 9999 do
        local candidate = extension
            and string.format("%s (%d).%s", stem, counter, extension)
            or string.format("%s (%d)", stem, counter)
        if not self:Exists(candidate) then return candidate end
    end
    return fileName
end

-- Metadata --------------------------------------------------------------------

--
--- ∑ Whether a blob should be treated as text.
---   A NUL byte settles it; Cheat Engine attachments that are not source are
---   usually images, sounds or dumps, and all of those carry one early. The
---   control character ratio catches the rest. An empty file is text: it has
---   to stay editable, or a new file could never be filled in.
--- @param blob string # The bytes, or a prefix of them.
--- @return boolean # True when the blob looks like text.
--
function Files.LooksBinary(blob)
    if type(blob) ~= "string" or blob == "" then return false end
    local sample = blob:sub(1, SNIFF)
    if sample:find("%z") then return true end
    local suspicious = 0
    for index = 1, #sample do
        local byte = sample:byte(index)
        -- Tab, line feed, carriage return and form feed are text.
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 and byte ~= 12 then
            suspicious = suspicious + 1
        end
    end
    return (suspicious / #sample) > 0.10
end

--
--- ∑ The size of an attached file, without reading its contents.
--- @param fileName string # The file name.
--- @return number|nil # Bytes, or nil when the file is not there.
--
function Files:SizeOf(fileName)
    if type(findTableFile) ~= "function" then return nil end
    local ok, file = pcall(findTableFile, fileName)
    if not ok or not file then return nil end
    local sized, size = pcall(function() return file.getData().Size end)
    if not sized then return nil end
    return tonumber(size) or 0
end

--
--- ∑ Everything the viewer wants to know about a file without opening it.
---   Deliberately cheap: the list refreshes through this, so it must not read
---   file bodies. IsText here is the type's opinion; the bytes only get a
---   vote once the file is actually opened.
--- @param fileName string # The file name.
--- @return table # Name, Extension, Type, Size, HighlighterMode, IsText, Exists.
--
function Files:GetInfo(fileName)
    local typeRecord = self.Types.For(fileName)
    local size = self:SizeOf(fileName)
    return {
        Name = fileName,
        Extension = self.Types.ExtensionOf(fileName),
        Type = typeRecord,
        Size = size or 0,
        HighlighterMode = typeRecord.Mode,
        IsText = typeRecord.IsText,
        Exists = size ~= nil
    }
end

--
--- ∑ A human size. Zero is a real size and must read as one.
--- @param bytes number # Byte count.
--- @return string
--
function Files.FormatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

-- Reading and writing ---------------------------------------------------------

--
--- ∑ Reads a table file into a string.
--- @param fileName string # The file name.
--- @return string|nil, string|nil # Contents, or nil plus a reason.
--
function Files:Read(fileName)
    if type(findTableFile) ~= "function" then return nil, "findTableFile is unavailable" end
    local file = findTableFile(fileName)
    if not file then return nil, "'" .. tostring(fileName) .. "' is not attached to this table" end
    local ok, text = pcall(function()
        local stream = file.getData()
        local size = stream.Size or 0
        if size == 0 then return "" end
        stream.Position = 0
        local bytes = stream.read(size)
        local pieces = {}
        for start = 1, #bytes, CHUNK do
            local stop = math.min(start + CHUNK - 1, #bytes)
            pieces[#pieces + 1] = string.char(table.unpack(bytes, start, stop))
        end
        return table.concat(pieces)
    end)
    if not ok then
        self:Fail("Read failed for '" .. tostring(fileName) .. "': " .. tostring(text))
        return nil, "Could not read the file"
    end
    return text
end

--
--- ∑ Replaces a table file's contents, creating the file when it is new.
--- @param fileName string # The file name.
--- @param text string # The new contents.
--- @return boolean # True on success.
--
function Files:Write(fileName, text)
    if type(findTableFile) ~= "function" or type(createTableFile) ~= "function" then
        self:Fail("Table file API is unavailable.")
        return false
    end
    local file = findTableFile(fileName) or createTableFile(fileName)
    if not file then
        self:Fail("Could not create '" .. tostring(fileName) .. "'.")
        return false
    end
    local ok, err = pcall(function()
        local stream = file.Stream
        stream.Position = 0
        stream.Size = 0
        for start = 1, #text, CHUNK do
            local stop = math.min(start + CHUNK - 1, #text)
            stream.write({ string.byte(text, start, stop) })
        end
        stream.Position = 0
    end)
    if not ok then
        self:Fail("Write failed for '" .. tostring(fileName) .. "': " .. tostring(err))
        return false
    end
    return true
end

--
--- ∑ Names of every file attached to the cheat table.
---   Cheat Engine has no enumeration call for these, so the Table menu is the
---   list. It fills itself the first time it is opened, which is why the menu
---   is clicked when it looks empty; doing that on every refresh would pop it
---   open.
--- @return table # File names, in menu order.
--
function Files:MainForm()
    -- getMainForm() is the documented accessor and the one the rest of the
    -- Manifold tools use. The globals are only a fallback: "mf" in particular
    -- is a local inside Manifold-CE-Utility, not something Cheat Engine
    -- publishes, and reaching for it here is why a fresh instance showed an
    -- empty list.
    if type(getMainForm) == "function" then
        local ok, form = pcall(getMainForm)
        if ok and form then return form end
    end
    return rawget(_G, "MainForm") or rawget(_G, "mf")
end

function Files:ListNames()
    local mainForm = self:MainForm()
    if not mainForm then
        self:Fail("The Cheat Engine main form is not reachable.")
        return {}
    end
    local ok, menu = pcall(function() return mainForm.findComponentByName("miTable") end)
    if not ok or not menu then
        self:Fail("Menu item 'miTable' not found.")
        return {}
    end

    local function walk()
        local names = {}
        local count = tonumber(menu.Count) or 0
        for index = 0, count - 1 do
            local item = menu.Item[index]
            local caption = item and item.Caption and item.Caption:match("^%s*(.-)%s*$")
            -- The menu also holds the commands that manage the list; only
            -- entries that resolve to a file are files.
            if caption and caption ~= "" and caption ~= "-" and findTableFile(caption) then
                names[#names + 1] = caption
            end
        end
        return names
    end

    local names = walk()
    -- Cheat Engine fills the file entries into this menu when it is opened.
    -- Until then it still has its own commands, so counting the children says
    -- nothing about whether the files are listed yet: a fresh instance with
    -- files attached but the menu never opened looks exactly like a table
    -- with no files. Finding none is the signal to make it populate, and
    -- doing it only then keeps the click off the common path.
    if #names == 0 then
        pcall(function() menu.doClick() end)
        names = walk()
    end
    return names
end

--
--- ∑ Metadata for every attached file. This is what a list refresh reads,
---   so it stays at metadata: no file body is touched.
--- @return table # Array of info records.
--
function Files:List()
    local infos = {}
    for _, name in ipairs(self:ListNames()) do
        infos[#infos + 1] = self:GetInfo(name)
    end
    return infos
end

-- Operations ------------------------------------------------------------------

--
--- ∑ Deletes table files.
--- @param fileNames table # List of names.
--- @return number, table # How many went, and the names that did not.
--
function Files:Delete(fileNames)
    local removed, failed = 0, {}
    for _, name in ipairs(fileNames or {}) do
        local file = findTableFile(name)
        if file and pcall(function() file.delete() end) and not self:Exists(name) then
            removed = removed + 1
        else
            failed[#failed + 1] = name
        end
    end
    return removed, failed
end

--
--- ∑ Copies one attached file to another name, bytes exactly.
---   copyFrom moves the bytes inside Cheat Engine, so nothing passes through
---   a Lua string and a binary attachment cannot be transformed on the way.
---   Falls back to read-and-write where copyFrom is unavailable.
--- @param fromName string # Source.
--- @param toName string # Target, which must be free.
--- @return boolean, string|nil
--
function Files:Copy(fromName, toName)
    local source = findTableFile(fromName)
    if not source then return false, "'" .. tostring(fromName) .. "' is not attached to this table" end
    if self:Exists(toName) then return false, "'" .. tostring(toName) .. "' already exists." end
    local target = createTableFile(toName)
    if not target then return false, "Could not create '" .. tostring(toName) .. "'." end
    local copied = pcall(function()
        local from, to = source.getData(), target.Stream
        from.Position = 0
        to.Position = 0
        to.Size = 0
        to.copyFrom(from, from.Size)
        to.Position = 0
    end)
    if copied and self:SizeOf(toName) == self:SizeOf(fromName) then return true end
    -- Fallback: through Lua. Correct for every file, just less direct.
    local text, err = self:Read(fromName)
    if not text then
        self:Delete({ toName })
        return false, err
    end
    if not self:Write(toName, text) then
        self:Delete({ toName })
        return false, "Could not write '" .. tostring(toName) .. "'."
    end
    return true
end

--
--- ∑ Renames a table file.
---   Cheat Engine has no rename, so this is a copy followed by a delete. The
---   delete only happens once the copy is verified, so a failure leaves the
---   original where it was.
--- @param oldName string # Current name.
--- @param newName string # Wanted name.
--- @return boolean, string|nil # Success, or false plus a reason.
--
function Files:Rename(oldName, newName)
    oldName, newName = tostring(oldName or ""), tostring(newName or "")
    if oldName == newName then return true end
    local valid, reason = self:ValidateName(newName)
    if not valid then return false, reason end
    if self:Exists(newName) then return false, "'" .. newName .. "' already exists." end
    local copied, err = self:Copy(oldName, newName)
    if not copied then return false, err end
    -- Verify before anything is destroyed. Sizes match by construction, so
    -- this compares the bytes that will survive against the ones that will not.
    if self:Read(newName) ~= self:Read(oldName) then
        self:Delete({ newName })
        return false, "The copy did not read back intact. Nothing was changed."
    end
    local removed = self:Delete({ oldName })
    if removed == 0 then
        return false, "The copy was made but '" .. oldName .. "' could not be removed."
    end
    return true
end

--
--- ∑ Duplicates a file under a free name.
--- @param fileName string # The file to duplicate.
--- @param newName string|nil # Target, or nil to pick one.
--- @return boolean, string # Success plus the name used, or false plus a reason.
--
function Files:Duplicate(fileName, newName)
    newName = newName or self:SuggestName(fileName)
    local valid, reason = self:ValidateName(newName)
    if not valid then return false, reason end
    local ok, err = self:Copy(fileName, newName)
    if not ok then return false, err end
    return true, newName
end

--
--- ∑ Creates an empty (or templated) file.
--- @param fileName string # The name.
--- @param content string|nil # Starter content; an empty file is valid.
--- @return boolean, string|nil
--
function Files:Create(fileName, content)
    local valid, reason = self:ValidateName(fileName)
    if not valid then return false, reason end
    if self:Exists(fileName) then return false, "'" .. fileName .. "' already exists." end
    if type(createTableFile) ~= "function" then return false, "createTableFile is unavailable" end
    local file = createTableFile(fileName)
    if not file then return false, "Could not create '" .. fileName .. "'." end
    if content and content ~= "" then
        if not self:Write(fileName, content) then
            self:Delete({ fileName })
            return false, "Could not write '" .. fileName .. "'."
        end
    end
    return true
end

-- Disk ------------------------------------------------------------------------

--
--- ∑ Reads a file from disk into the table under an explicit name.
---   The stream loads the file itself, so the bytes never become a Lua
---   string. This never decides what to do about a name that is taken: the
---   caller resolves that first, which is what keeps import from silently
---   destroying an attachment.
--- @param path string # Full path on disk.
--- @param fileName string # The name to attach it as, which must be free.
--- @return boolean, string|nil
--
function Files:ImportOne(path, fileName)
    if self:Exists(fileName) then
        return false, "'" .. tostring(fileName) .. "' already exists."
    end
    local valid, reason = self:ValidateName(fileName)
    if not valid then return false, reason end
    if type(createTableFile) ~= "function" then return false, "createTableFile is unavailable" end

    local file = createTableFile(fileName)
    if not file then return false, "Could not create '" .. tostring(fileName) .. "'." end

    local loaded, message = false, nil
    pcall(function()
        local stream = file.Stream
        if type(stream.loadFromFileNoError) == "function" then
            local ok, err = stream.loadFromFileNoError(path)
            loaded, message = ok == true, err
        elseif type(stream.loadFromFile) == "function" then
            loaded = pcall(function() stream.loadFromFile(path) end)
        end
    end)
    if loaded then return true end

    -- Fallback: read it here and write it through. Same result, more copying.
    local handle = io.open(path, "rb")
    if not handle then
        self:Delete({ fileName })
        return false, message or "Could not open the file on disk."
    end
    local text = handle:read("*a")
    handle:close()
    if not self:Write(fileName, text) then
        self:Delete({ fileName })
        return false, "Could not store '" .. tostring(fileName) .. "'."
    end
    return true
end

--
--- ∑ The basename of a path.
--- @param path string # Full path.
--- @return string
--
function Files.BaseName(path)
    return tostring(path):match("([^\\/]+)$") or tostring(path)
end

--
--- ∑ Writes an attached file out to disk, bytes exactly.
--- @param fileName string # The table file.
--- @param path string # Destination path.
--- @return boolean, string|nil
--
function Files:Export(fileName, path)
    local file = findTableFile(fileName)
    if not file then return false, "'" .. tostring(fileName) .. "' is not attached to this table" end
    local saved, message = false, nil
    pcall(function()
        local stream = file.getData()
        if type(stream.saveToFileNoError) == "function" then
            local ok, err = stream.saveToFileNoError(path)
            saved, message = ok == true, err
        elseif type(file.saveToFile) == "function" then
            saved = pcall(function() file.saveToFile(path) end)
        end
    end)
    if saved then return true end
    -- Fallback through Lua.
    local text, err = self:Read(fileName)
    if not text then return false, message or err end
    return self:ExportText(text, path)
end

--
--- ∑ Writes a string to disk. This is how an edited but unsaved buffer is
---   exported, so that what lands on disk is what the editor shows.
--- @param text string # The contents.
--- @param path string # Destination path.
--- @return boolean, string|nil
--
function Files:ExportText(text, path)
    local handle, openErr = io.open(path, "wb")
    if not handle then return false, tostring(openErr) end
    local ok, writeErr = pcall(function() handle:write(text) end)
    handle:close()
    if not ok then return false, tostring(writeErr) end
    return true
end

return Files
