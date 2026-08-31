--[[
    File system layer, plus the rotating log writer built on top of it.

    File wraps io and lfs. Nothing else here calls either directly, so path
    normalization and pcall discipline live in one place. A Cheat Engine build
    without LuaFileSystem degrades to "nothing exists" instead of raising.

    File.Writer is an append-only, size-rotating writer.

      * It NEVER logs. Every failure path here is reachable from inside a log
        call, so logging a write failure would recurse through the sink that
        just failed. Failures land on the writer as Reason, and the console
        status bar reads them.

      * On failure it disables itself instead of retrying. A path that is not
        writable on the first line is not writable on the ten-thousandth.

      * Rotation counts bytes written. lfs.attributes per line would be a
        syscall per line. Disk is consulted only on Open.

      * It does not flush every line. The C runtime buffer already holds them,
        and Close, Rotate and Clear all flush. Lines the caller marks
        important flush at once. The file sink marks WARNING and above, so the
        tail survives a process that is about to stop existing.

    Logs go to %LOCALAPPDATA%\Manifold\Logs, shared with the framework's
    Manifold.Logger. Names do not collide. The framework writes
    Manifold.Runtime.<table>.log, this writes Manifold.Console.log plus its
    numbered generations.
]]

local File = {}
File.__index = File

-- Cheat Engine preloads LuaFileSystem as a global, but load order against
-- other autorun scripts is not guaranteed. Resolve it once, degrade if it is
-- missing.
local lfs = rawget(_G, "lfs")
if not lfs then
    local ok, module = pcall(require, "lfs")
    lfs = ok and module or nil
end

local function attributesOf(path)
    if not lfs then return nil end
    local ok, attr = pcall(lfs.attributes, path)
    return ok and attr or nil
end

--
--- ∑ Forward slashes, no duplicates, no trailing separator. Parenthesized
---   because gsub also returns a match count, which must not leak into a
---   caller's table constructor or argument list.
--- @param path string|nil
--- @return string|nil
--
function File.Normalize(path)
    if type(path) ~= "string" or path == "" then return nil end
    return (path:gsub("\\", "/"):gsub("//+", "/"):gsub("/+$", ""))
end

function File:New()
    return setmetatable({}, File)
end

function File:Exists(path)
    path = File.Normalize(path)
    if not path then return false end
    local attr = attributesOf(path)
    return attr ~= nil and attr.mode == "file"
end

function File:FolderExists(path)
    path = File.Normalize(path)
    if not path then return false end
    local attr = attributesOf(path)
    return attr ~= nil and attr.mode == "directory"
end

--
--- ∑ Creates a folder and every missing parent above it.
--- @param path string
--- @return boolean, string|nil
--
function File:EnsureFolder(path)
    path = File.Normalize(path)
    if not path then return false, "Invalid directory path" end
    if self:FolderExists(path) then return true end
    if not lfs then return false, "LuaFileSystem (lfs) is unavailable" end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and not self:FolderExists(parent) then
        local parentOk, parentErr = self:EnsureFolder(parent)
        if not parentOk then return false, parentErr end
    end
    local ok, created, err = pcall(lfs.mkdir, path)
    if ok and created then return true end
    -- Something else may have created it first. That still counts.
    if self:FolderExists(path) then return true end
    return false, tostring(err or created)
end

function File:Size(path)
    path = File.Normalize(path)
    if not path then return 0 end
    local attr = attributesOf(path)
    return attr and tonumber(attr.size) or 0
end

function File:Read(path)
    path = File.Normalize(path)
    if not path then return nil, "Invalid file path" end
    local handle, err = io.open(path, "rb")
    if not handle then return nil, tostring(err) end
    local content = handle:read("*a")
    handle:close()
    return content
end

function File:Write(path, content)
    path = File.Normalize(path)
    if not path then return false, "Invalid file path" end
    local handle, err = io.open(path, "wb")
    if not handle then return false, tostring(err) end
    local ok, writeErr = handle:write(tostring(content))
    handle:close()
    if not ok then return false, tostring(writeErr) end
    return true
end

--
--- ∑ The Manifold data directory. Honours LOCALAPPDATA, falls back to
---   USERPROFILE, which a stripped environment still has.
--- @return string|nil
--
function File.DataDirectory()
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then
        local profile = os.getenv("USERPROFILE")
        if profile and profile ~= "" then base = profile .. "\\AppData\\Local" end
    end
    if not base or base == "" then return nil end
    return File.Normalize(base .. "/Manifold")
end

--
--- ∑ Where the log files go. Shared with the framework's Manifold.Logger. See
---   the file header.
--- @return string|nil
--
function File.LogDirectory()
    local data = File.DataDirectory()
    return data and (data .. "/Logs") or nil
end

--------------------------------------------------------
--                   Rotating writer                  --
--------------------------------------------------------

local Writer = {}
Writer.__index = Writer
File.Writer = Writer

Writer.Defaults = {
    FileName    = "Manifold.Console.log",
    MaxBytes    = 2 * 1024 * 1024,  -- rotate at 2 MB
    Generations = 3,                -- .1 .. .3 kept beside the active file
    FlushAlways = false,            -- flush after every write
    FlushEvery  = 64                -- otherwise, after this many
}

--
--- ∑ Builds a writer. Nothing touches the disk until the first Write, so
---   constructing one on a machine with no writable profile is harmless.
--- @param options table|nil # { Directory, FileName, MaxBytes, Generations,
---        FlushAlways, FlushEvery, Header (string|function) }
--- @return table
--
function File.NewWriter(options)
    options = options or {}
    return setmetatable({
        Fs          = File:New(),
        Directory   = File.Normalize(options.Directory) or File.LogDirectory(),
        FileName    = options.FileName or Writer.Defaults.FileName,
        MaxBytes    = tonumber(options.MaxBytes) or Writer.Defaults.MaxBytes,
        Generations = tonumber(options.Generations) or Writer.Defaults.Generations,
        FlushAlways = options.FlushAlways == true,
        FlushEvery  = tonumber(options.FlushEvery) or Writer.Defaults.FlushEvery,
        Header      = options.Header,
        Handle      = nil,
        Bytes       = 0,     -- size of the OPEN file, tracked rather than stat'd
        Written     = 0,     -- lines this session
        Unflushed   = 0,     -- lines since the last flush
        Enabled     = true,
        Reason      = nil,
        Busy        = false  -- reentrancy latch, see :Write
    }, Writer)
end

--
--- ∑ Absolute path of the active log file, or nil when there is no usable
---   directory at all.
--- @return string|nil
--
function Writer:Path()
    if not self.Directory then return nil end
    return self.Directory .. "/" .. self.FileName
end

--- Path of rotated generation index. 1 is the most recent.
function Writer:GenerationPath(index)
    local path = self:Path()
    return path and (path .. "." .. tostring(index)) or nil
end

--
--- ∑ Records why the writer stopped and switches it off. Never logs, since
---   this is reachable from inside a log call.
--- @param reason string
--- @return boolean # Always false, so callers can return self:Fail(...).
--
function Writer:Fail(reason)
    self.Reason = tostring(reason)
    self.Enabled = false
    self:Close()
    return false
end

--
--- ∑ Opens the file for appending, creating the directory if needed and
---   writing the session header. Idempotent.
--- @return boolean
--
function Writer:Open()
    if self.Handle then return true end
    if not self.Enabled then return false end
    local path = self:Path()
    if not path then return self:Fail("no writable data directory (LOCALAPPDATA is unset)") end
    local ok, err = self.Fs:EnsureFolder(self.Directory)
    if not ok then return self:Fail("cannot create '" .. tostring(self.Directory) .. "': " .. tostring(err)) end
    -- The size is read from disk exactly here. Everything after this tracks it
    -- by counting bytes written.
    self.Bytes = self.Fs:Size(path)
    local handle, openErr = io.open(path, "a")
    if not handle then return self:Fail("cannot open '" .. path .. "': " .. tostring(openErr)) end
    self.Handle = handle
    local header = self.Header
    if type(header) == "function" then
        local built, value = pcall(header)
        header = built and value or nil
    end
    if type(header) == "string" and header ~= "" then
        self:_Raw(header .. "\n", true)
    end
    return true
end

--- Writes without any of the guards. Only called from Open and Write, both of
--- which already hold the latch.
function Writer:_Raw(text, flush)
    local handle = self.Handle
    local ok, err = pcall(function()
        handle:write(text)
        if flush then handle:flush() end
    end)
    if not ok then return self:Fail("write failed: " .. tostring(err)) end
    self.Bytes = self.Bytes + #text
    if flush then self.Unflushed = 0 end
    return true
end

--
--- ∑ Pushes whatever the C runtime is still holding out to disk.
--- @return boolean
--
function Writer:Flush()
    if not self.Handle then return false end
    local ok = pcall(function() self.Handle:flush() end)
    if ok then self.Unflushed = 0 end
    return ok
end

--
--- ∑ Appends one line.
---
---   The latch matters. A sink calls this from Core:Emit, so a failure that
---   logged would re-enter through the same sink. It does not log, and the
---   latch also covers a caller that writes from a callback during rotation.
--- @param text string # Without a trailing newline.
--- @param important boolean|nil # Flush this line out immediately.
--- @return boolean
--
function Writer:Write(text, important)
    if not self.Enabled or self.Busy then return false end
    self.Busy = true
    local ok = self:_WriteLocked(text, important)
    self.Busy = false
    return ok
end

function Writer:_WriteLocked(text, important)
    if not self:Open() then return false end
    self.Unflushed = self.Unflushed + 1
    local flush = important == true or self.FlushAlways
        or (self.FlushEvery > 0 and self.Unflushed >= self.FlushEvery)
    if not self:_Raw(tostring(text) .. "\n", flush) then return false end
    self.Written = self.Written + 1
    if self.MaxBytes > 0 and self.Bytes >= self.MaxBytes then self:Rotate() end
    return true
end

--
--- ∑ Closes the handle. The writer stays usable, the next Write reopens.
--- @return nil
--
function Writer:Close()
    if not self.Handle then return end
    pcall(function() self.Handle:close() end)
    self.Handle = nil
    self.Unflushed = 0
end

--
--- ∑ Moves the active file to .1, shifting the older generations down and
---   dropping the oldest.
---
---   os.remove and os.rename report failure by returning nil plus a message.
---   They do not raise, so the pcall RESULTS have to be checked, not just
---   pcall's own ok flag. Windows os.rename also refuses to overwrite, so
---   each destination is removed first.
--- @return boolean
--
function Writer:Rotate()
    local path = self:Path()
    if not path then return false end
    self:Close()
    if self.Generations <= 0 then
        -- No generations wanted. Truncate instead of accumulating files.
        local ok = self.Fs:Write(path, "")
        self.Bytes = 0
        return ok
    end
    local oldest = self:GenerationPath(self.Generations)
    if oldest and self.Fs:Exists(oldest) then pcall(os.remove, oldest) end
    for index = self.Generations - 1, 1, -1 do
        local from, to = self:GenerationPath(index), self:GenerationPath(index + 1)
        if self.Fs:Exists(from) then
            if self.Fs:Exists(to) then pcall(os.remove, to) end
            pcall(os.rename, from, to)
        end
    end
    if self.Fs:Exists(path) then
        local target = self:GenerationPath(1)
        if self.Fs:Exists(target) then pcall(os.remove, target) end
        local ok, renamed = pcall(os.rename, path, target)
        if not ok or not renamed then
            -- Rotation failed, most likely because something holds the file
            -- open. Truncating still keeps the log bounded.
            self.Fs:Write(path, "")
        end
    end
    self.Bytes = 0
    return true
end

--
--- ∑ Empties the active file without touching the rotated generations.
--- @return boolean
--
function Writer:Clear()
    local path = self:Path()
    if not path then return false end
    self:Close()
    local ok = self.Fs:Write(path, "")
    self.Bytes = 0
    self.Written = 0
    self.Unflushed = 0
    return ok
end

--
--- ∑ Turns the writer back on after a failure, so a user who fixed the
---   permission problem does not have to reload Cheat Engine.
--- @return boolean
--
function Writer:Retry()
    self.Enabled = true
    self.Reason = nil
    return self:Open()
end

--
--- ∑ What the console's status bar and the About block report.
--- @return table
--
function Writer:Status()
    return {
        Path = self:Path(),
        Directory = self.Directory,
        Enabled = self.Enabled,
        Open = self.Handle ~= nil,
        Bytes = self.Bytes,
        Written = self.Written,
        Unflushed = self.Unflushed,
        Reason = self.Reason
    }
end

--------------------------------------------------------
--                        Sink                        --
--------------------------------------------------------

--
--- ∑ Wraps a writer as a log sink.
--- @param writer table
--- @param options table|nil # { Level, Render (record to string), Mode,
---        FlushRank }
---        Mode "jsonl" writes one JSON object per record instead of a line of
---        text, so the log can be parsed afterwards.
---        FlushRank is the rank at and above which a line goes to disk
---        immediately. It defaults to WARNING.
--- @return table
--
function File.NewSink(writer, options)
    options = options or {}
    local render = options.Render
    local flushRank = tonumber(options.FlushRank) or 40
    return {
        Level = options.Level,
        Writer = writer,
        Mode = options.Mode or "text",
        FlushRank = flushRank,
        Write = function(sink, record)
            local text = render and render(record, sink.Mode) or tostring(record.Message)
            sink.Writer:Write(text, (record.Rank or 0) >= sink.FlushRank)
        end,
        Close = function(sink) sink.Writer:Close() end
    }
end

return File
