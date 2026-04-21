local NAME = "Manifold.CustomIO.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.3"
local DESCRIPTION = "Manifold Framework CustomIO"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-03-27)
        Improved error handling, reduced 'string.format' usage.
        Added CSV read/write support and safe file deletion.

    ∂ v1.0.2 (2025-12-05)
        Fixed JSON encoding issues in Table File read/write functions.
            - (CustomIO:WriteToTableFileAsJson)
        Adjusted the write procedure to correctly handle byte streams.
            - (CustomIO:WriteToTableFile and CustomIO:WriteToTableFileAsJson)

    ∂ v1.0.3 (2026-04-21)
        Reduced low-value log noise and focused logging on failures and meaningful state changes.
]]--

CustomIO = {}
CustomIO.__index = CustomIO

local MODULE_PREFIX = "[CustomIO]"

--
--- ∑ Internal helper function to check if a value is a non-empty string.
--- @param value any
--- @return boolean
--
local function _isString(value)
    return type(value) == "string" and value ~= ""
end

--
--- ∑ Internal helper function to read the content of a Cheat Engine table file.
--- @param tableFile tableFileObject
--- @return string|nil
--
local function _readTableFile(tableFile)
    local stream = tableFile.getData()
    local bytes = stream.read(stream.Size)
    return string.char(table.unpack(bytes))
end

--
--- ∑ Internal helper function to write text data to a Cheat Engine table file.
--- @param tableFile tableFileObject
--- @param text string
--- @return boolean
--- Note: This function overwrites the entire content of the table file with the provided text.
--
local function _writeTableFile(tableFile, text)
    local stream = tableFile.Stream
    stream.Position = 0
    stream.Size = 0
    stream.write({string.byte(text, 1, -1)})
    stream.Position = 0
end

function CustomIO:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.DataDir = os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function CustomIO:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function CustomIO:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info(MODULE_PREFIX .. " Failed to retrieve module info.")
        return
    end
    logger:Info("Module Info : "  .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local description = type(info.description) == "table" and table.concat(info.description, ", ") or tostring(info.description)
    logger:Info("\tAuthor:      " .. author)
    logger:Info("\tDescription: " .. description .. "\n")
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
--
function CustomIO:CheckDependencies()
    if json ~= nil then
        return
    end
    logger:Warning(MODULE_PREFIX .. " 'json' dependency not found. Attempting to load...")
    local success, result = pcall(CETrequire, "Manifold.Json")
    if success then
        json = JSON:new()
        logger:Info(MODULE_PREFIX .. " Loaded dependency 'json'.")
    else
        logger:Error(MODULE_PREFIX .. " Failed to load dependency 'json': " .. tostring(result))
    end
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- ∑ Checks if a directory exists.
--- @param dir string
--- @return boolean
--
function CustomIO:DirectoryExists(dir)
    local attr = lfs.attributes(dir)
    return attr and attr.mode == "directory"
end
registerLuaFunctionHighlight('DirectoryExists')

--
--- ∑ Ensures that a directory exists, creating it if necessary.
--- @param path string
--- @return boolean
--
function CustomIO:EnsureDirectoryExists(path)
    if not _isString(path) then
        logger:Error(MODULE_PREFIX .. " Invalid directory path.")
        return false
    end
    if self:DirectoryExists(path) then
        return true
    end
    return self:CreateDirectory(path)
end
registerLuaFunctionHighlight('EnsureDirectoryExists')

--
--- ∑ Builds a complete file path from the provided directory and file name.
--- @param dir string
--- @param fileName string
--- @return string|nil
--
function CustomIO:BuildPath(dir, fileName)
    if not _isString(dir) then
        logger:Error(MODULE_PREFIX .. " Invalid directory path.")
        return nil
    end
    if not _isString(fileName) then
        logger:Error(MODULE_PREFIX .. " Invalid file name.")
        return nil
    end
    if not dir:match("[\\/]$") then
        dir = dir .. "\\"
    end
    return dir .. fileName
end
registerLuaFunctionHighlight('BuildPath')

--
--- ∑ Attempts to create a directory if it does not exist.
--- @param dir string
--- @return boolean, string|nil
--
function CustomIO:CreateDirectory(dir)
    if not _isString(dir) then
        logger:Error(MODULE_PREFIX .. " Invalid directory path.")
        return false, "Invalid directory path"
    end
    if self:DirectoryExists(dir) then
        return true
    end
    local success = lfs.mkdir(dir)
    if not success then
        local err = lfs.attributes(dir) and "Unknown error" or "Permission denied or invalid path"
        logger:Error(MODULE_PREFIX .. " Failed to create directory '" .. dir .. "': " .. err)
        return false, err
    end
    logger:Info(MODULE_PREFIX .. " Created directory: " .. dir)
    return true
end
registerLuaFunctionHighlight('CreateDirectory')

--
--- ∑ Opens a directory using the system's default file explorer.
--- @param dir string
--- @return boolean
--
function CustomIO:OpenDirectory(dir)
    if not _isString(dir) then
        logger:Error(MODULE_PREFIX .. " Invalid directory path.")
        return false
    end
    if not self:DirectoryExists(dir) then
        logger:Error(MODULE_PREFIX .. " Directory does not exist: '" .. dir .. "'")
        return false
    end
    local success, result = pcall(os.execute, string.format('start /b "" "%s"', dir))
    if success then
        logger:Info(MODULE_PREFIX .. " Opened directory: " .. dir)
        return true
    end
    logger:Error(MODULE_PREFIX .. " Failed to open directory '" .. dir .. "': " .. tostring(result))
    return false
end
registerLuaFunctionHighlight('OpenDirectory')

--
--- ∑ Strips the extension from a file name.
--- @param fileName string
--- @return string|nil
--
function CustomIO:StripExt(fileName)
    if not _isString(fileName) then
        logger:Error(MODULE_PREFIX .. " Invalid file name provided for StripExt.")
        return nil
    end
    return fileName:match("(.+)%.[^%.]+$") or fileName
end
registerLuaFunctionHighlight('StripExt')

--
--- ∑ Checks if a file exists at the specified path.
--- @param filePath string
--- @return boolean
--
function CustomIO:FileExists(filePath)
    local file = io.open(filePath, "r")
    if file then
        file:close()
        return true
    end
    return false
end
registerLuaFunctionHighlight('FileExists')

--
--- ∑ Attempts to delete a file at the given path.
--- @param filePath string
--- @return boolean, string|nil
--
function CustomIO:DeleteFile(filePath)
    if not _isString(filePath) then
        return false, "File path is missing"
    end
    if not self:FileExists(filePath) then
        logger:Warning(MODULE_PREFIX .. " File not found for deletion: '" .. filePath .. "'")
        return false, "File not found"
    end
    local success, err = pcall(os.remove, filePath)
    if not success then
        logger:Error(MODULE_PREFIX .. " Failed to delete file '" .. filePath .. "': " .. tostring(err))
        return false, err
    end
    logger:Info(MODULE_PREFIX .. " Deleted file: " .. filePath)
    return true
end
registerLuaFunctionHighlight('DeleteFile')

--
--- ∑ Reads the contents of a file and returns it as a string.
--- @param filePath string
--- @returns string|nil, string|nil
--
function CustomIO:ReadFromFile(filePath)
    if not _isString(filePath) then
        return nil, "Invalid parameter: filePath is missing"
    end
    local file, err = io.open(filePath, "r")
    if not file then
        return nil, "File not found or cannot be opened: " .. (err or "Unknown reason")
    end
    local content = file:read("*all")
    file:close()
    if content == nil then
        return nil, "Failed to read content from file"
    end
    return content
end
registerLuaFunctionHighlight('ReadFromFile')

--
--- ∑ Writes raw text data to a specified file, overwriting it.
--- @param filePath string
--- @param data string
--- @return boolean, string|nil
--
function CustomIO:WriteToFile(filePath, data)
    if not _isString(filePath) or data == nil then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local file, err = io.open(filePath, "w")
    if not file then
        logger:Error(MODULE_PREFIX .. " Failed to open file '" .. filePath .. "' for writing: " .. tostring(err))
        return false, err
    end
    local success, writeErr = pcall(function()
        file:write(data)
    end)
    file:close()
    if not success then
        logger:Error(MODULE_PREFIX .. " Failed to write to file '" .. filePath .. "': " .. tostring(writeErr))
        return false, writeErr
    end
    return true
end
registerLuaFunctionHighlight('WriteToFile')

--
--- ∑ Appends raw text data to a specified file.
--- @param filePath string
--- @param data string
--- @return boolean, string|nil
--
function CustomIO:AppendToFile(filePath, data)
    if not _isString(filePath) or data == nil then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local file, err = io.open(filePath, "a")
    if not file then
        logger:Error(MODULE_PREFIX .. " Failed to open file '" .. filePath .. "' for appending: " .. tostring(err))
        return false, err
    end
    local success, writeErr = pcall(function()
        file:write(data .. "\n")
    end)
    file:close()
    if not success then
        logger:Error(MODULE_PREFIX .. " Failed to append to file '" .. filePath .. "': " .. tostring(writeErr))
        return false, writeErr
    end
    return true
end
registerLuaFunctionHighlight('AppendToFile')

--
--- ∑ Attempts to read a CSV file and returns its contents as a table.
--- @param filePath string
--- @return table|nil, string|nil
--
function CustomIO:ReadCSV(filePath)
    local content, err = self:ReadFromFile(filePath)
    if not content then return nil, err end

    local result = {}
    for line in content:gmatch("([^\n]*)\n?") do
        local row = {}
        for value in line:gmatch("([^,]+)") do
            table.insert(row, value)
        end
        table.insert(result, row)
    end
    return result
end
registerLuaFunctionHighlight('ReadCSV')

--
--- ∑ Writes data to a CSV file at the specified path.
--- @param filePath string
--- @param data table
--- @return boolean, string|nil
--
function CustomIO:WriteCSV(filePath, data)
    if not _isString(filePath) or type(data) ~= "table" then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local file, err = io.open(filePath, "w")
    if not file then
        logger:Error(MODULE_PREFIX .. " Failed to open CSV file '" .. filePath .. "' for writing: " .. tostring(err))
        return false, err
    end
    local success, writeErr = pcall(function()
        for _, row in ipairs(data) do
            file:write(table.concat(row, ",") .. "\n")
        end
    end)
    file:close()
    if not success then
        logger:Error(MODULE_PREFIX .. " Failed to write to CSV file '" .. filePath .. "': " .. tostring(writeErr))
        return false, writeErr
    end
    return true
end
registerLuaFunctionHighlight('WriteCSV')

--
--- ∑ Reads the content of a Cheat Engine table file and returns it as a string.
--- @param fileName string
--- @return string|nil, string|nil
--
function CustomIO:ReadFromTableFile(fileName)
    if not _isString(fileName) then
        return nil, "Invalid parameter: fileName is missing"
    end
    logger:Info(MODULE_PREFIX .. " Reading table file '" .. fileName .. "'.")
    local tableFile = findTableFile(fileName)
    if not tableFile then
        logger:Warning(MODULE_PREFIX .. " Table file not found: '" .. fileName .. "'")
        return nil, "File not found"
    end
    local success, content = pcall(_readTableFile, tableFile)
    if not success or not content then
        logger:Error(MODULE_PREFIX .. " Failed to read table file '" .. fileName .. "'.")
        return nil, "Read error"
    end
    logger:Info(MODULE_PREFIX .. " Read table file '" .. fileName .. "'.")
    return content
end
registerLuaFunctionHighlight('ReadFromTableFile')

--
--- ∑ Writes a given text string to a Cheat Engine table file.
--- @param fileName string
--- @param text string
--- @return boolean
--
function CustomIO:WriteToTableFile(fileName, text)
    if not _isString(fileName) or type(text) ~= "string" then
        logger:Error(MODULE_PREFIX .. " Invalid parameters: fileName or text is missing or not a string.")
        return false
    end
    logger:Info(MODULE_PREFIX .. " Writing table file '" .. fileName .. "'.")
    local tableFile = findTableFile(fileName) or createTableFile(fileName)
    if not tableFile then
        logger:Error(MODULE_PREFIX .. " Failed to create/find table file '" .. fileName .. "'.")
        return false
    end
    local success, err = pcall(_writeTableFile, tableFile, text)
    if not success then
        logger:Error(MODULE_PREFIX .. " Failed to write table file '" .. fileName .. "': " .. tostring(err))
        return false
    end
    logger:Info(MODULE_PREFIX .. " Wrote table file '" .. fileName .. "'.")
    return true
end
registerLuaFunctionHighlight('WriteToTableFile')

--
--- ∑ Reads the content of a Cheat Engine table file and returns it as a parsed JSON object.
--- @param fileName string
--- @return table|nil, string|nil
--
function CustomIO:ReadFromTableFileAsJson(fileName)
    local content, err = self:ReadFromTableFile(fileName)
    if not content then
        return nil, err
    end
    local success, jsonData = pcall(function()
        return json:decode(content)
    end)
    if not success or not jsonData then
        logger:Error(MODULE_PREFIX .. " Failed to parse JSON from table file '" .. fileName .. "'.")
        return nil, "JSON parse error"
    end
    return jsonData
end
registerLuaFunctionHighlight('ReadFromTableFileAsJson')

--
--- ∑ Writes a table as JSON to a Cheat Engine table file.
--- @param fileName string
--- @param data table
--- @return boolean
--
function CustomIO:WriteToTableFileAsJson(fileName, data)
    if not _isString(fileName) or type(data) ~= "table" then
        logger:Error(MODULE_PREFIX .. " Invalid parameters: fileName is missing or data is not a table.")
        return false
    end
    local success, jsonText = pcall(function()
        return json:encode(data)
    end)
    if not success or not jsonText then
        logger:Error(MODULE_PREFIX .. " Failed to encode table data as JSON.")
        return false
    end
    return self:WriteToTableFile(fileName, jsonText)
end
registerLuaFunctionHighlight('WriteToTableFileAsJson')

--
--- ∑ Reads a JSON file, decodes it into a Lua table, and returns the data.
--- @param filePath string
--- @returns table|nil, string|nil
--
function CustomIO:ReadFromFileAsJson(filePath)
    local content, err = self:ReadFromFile(filePath)
    if not content then
        return nil, err
    end
    local data, decodeErr = json:decode(content)
    if not data then
        return nil, string.format("Failed to parse JSON: %s", decodeErr or "Unknown error")
    end
    return data
end
registerLuaFunctionHighlight('ReadFromFileAsJson')

--
--- ∑ Serializes Lua data into JSON and writes it to a specified file.
--- @param filePath string
--- @param data table
--- @return boolean, string|nil
--
function CustomIO:WriteToFileAsJson(filePath, data)
    if not _isString(filePath) or type(data) ~= "table" then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local success, jsonText = pcall(function()
        return json:encode_pretty(data)
    end)
    if not success or not jsonText then
        logger:Error(MODULE_PREFIX .. " Failed to encode JSON for file '" .. filePath .. "'.")
        return false, "JSON encode error"
    end
    return self:WriteToFile(filePath, jsonText)
end
registerLuaFunctionHighlight('WriteToFileAsJson')

--
--- ∑ Ensures the Data Directory exists.
--- @return boolean
--
function CustomIO:EnsureDataDirectory()
    local dataDir = self.DataDir
    if self:DirectoryExists(dataDir) then return true end
    logger:Warning(MODULE_PREFIX .. " Data directory missing. Attempting to create it.")
    local success, err = self:CreateDirectory(dataDir)
    if not success then
        logger:Error(MODULE_PREFIX .. " Failed to create Data Directory: " .. (err or "Unknown Error"))
        return false
    end
    return true
end
registerLuaFunctionHighlight('EnsureDataDirectory')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return CustomIO