--[[
    Defensive file-system layer used by every Template Loader module.

    Templates, config and providers never do their own io/lfs calls. They go
    through this wrapper so path normalization, pcall discipline and atomic
    writes live in exactly one place.
]]

local File = {}
File.__index = File

-- Cheat Engine ships LuaFileSystem as a preloaded global, but nothing
-- guarantees load order against other autorun scripts. Resolve it once and
-- degrade to "nothing exists" instead of indexing a nil global.
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

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    -- Parenthesized: gsub also returns its match count, which must never
    -- leak to callers (a trailing table element would pick it up).
    return (path:gsub("\\", "/"):gsub("/+$", ""))
end

function File:New()
    return setmetatable({}, File)
end

function File:NormalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    return (path:gsub("\\", "/"):gsub("//+", "/"):gsub("/+$", ""))
end

function File:Exists(path)
    path = normalizePath(path)
    if not path then return false end
    local attr = attributesOf(path)
    return attr ~= nil and attr.mode == "file"
end

function File:FolderExists(path)
    path = normalizePath(path)
    if not path then return false end
    local attr = attributesOf(path)
    return attr ~= nil and attr.mode == "directory"
end

function File:EnsureFolder(path)
    path = normalizePath(path)
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
    if self:FolderExists(path) then return true end
    return false, tostring(err or created)
end

function File:Size(path)
    path = normalizePath(path)
    if not path then return 0 end
    local attr = attributesOf(path)
    return attr and attr.size or 0
end

--
--- Modification timestamp, or 0 when unavailable. Used as a cheap cache
--- fingerprint together with the file size.
--
function File:Modified(path)
    path = normalizePath(path)
    if not path then return 0 end
    local attr = attributesOf(path)
    return attr and tonumber(attr.modification) or 0
end

function File:ReadFile(path)
    path = normalizePath(path)
    if not path then return nil, "Invalid file path" end
    local handle, err = io.open(path, "rb")
    if not handle then
        return nil, string.format("Unable to open '%s': %s", path, tostring(err))
    end
    local content = handle:read("*a")
    handle:close()
    if content == nil then
        return nil, "Unable to read '" .. path .. "'"
    end
    return content
end

function File:WriteFile(path, content)
    path = normalizePath(path)
    if not path then return false, "Invalid file path" end
    if type(content) ~= "string" then return false, "File content must be a string" end
    local handle, err = io.open(path, "wb")
    if not handle then
        return false, string.format("Unable to write '%s': %s", path, tostring(err))
    end
    local ok, writeErr = handle:write(content)
    handle:close()
    if not ok then
        return false, tostring(writeErr)
    end
    return true
end

--
--- Writes through a temporary file and only replaces the destination after
--- the temporary was written and read back successfully. A failed save can
--- therefore never destroy the only working copy of a file. os.rename on
--- Windows refuses to overwrite, so the destination is removed first. The
--- window in which neither file exists is unavoidable there, but by that
--- point the replacement is already proven complete on disk.
--
function File:WriteFileAtomic(path, content)
    path = normalizePath(path)
    if not path then return false, "Invalid file path" end
    if type(content) ~= "string" then return false, "File content must be a string" end
    local tempPath = path .. ".tmp"
    local written, writeErr = self:WriteFile(tempPath, content)
    if not written then return false, writeErr end
    local verify = self:ReadFile(tempPath)
    if verify ~= content then
        pcall(os.remove, tempPath)
        return false, "Verification of the temporary file failed"
    end
    -- os.remove/os.rename report failure as nil, message. They do not
    -- raise. So the pcall RESULTS must be checked, not just pcall's ok.
    if self:Exists(path) then
        local callOk, removed, removeErr = pcall(os.remove, path)
        if not callOk or not removed then
            pcall(os.remove, tempPath)
            return false, "Unable to replace '" .. path .. "': " .. tostring(removeErr or removed)
        end
    end
    local callOk, renamed, renameErr = pcall(os.rename, tempPath, path)
    if not callOk or not renamed then
        return false, "Unable to move temporary file into place: " .. tostring(renameErr or renamed)
    end
    return true
end

--
--- Non-recursive by default. Recursive on request. Returns full paths,
--- sorted case-insensitively for deterministic discovery order.
--
function File:ScanFolder(path, recursive)
    path = normalizePath(path)
    local files = {}
    if not path or not self:FolderExists(path) then return files end
    local ok, iterator, directory = pcall(lfs.dir, path)
    if not ok then return files end
    for entry in iterator, directory do
        if entry ~= "." and entry ~= ".." then
            local fullPath = path .. "/" .. entry
            local attrOk, attr = pcall(lfs.attributes, fullPath)
            if attrOk and attr then
                if attr.mode == "directory" and recursive then
                    local nested = self:ScanFolder(fullPath, true)
                    for _, nestedPath in ipairs(nested) do
                        files[#files + 1] = nestedPath
                    end
                elseif attr.mode == "file" then
                    files[#files + 1] = fullPath
                end
            end
        end
    end
    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    return files
end

return File