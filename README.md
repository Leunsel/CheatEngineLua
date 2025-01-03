# Cheat Engine Lua Modules

This repository contains a collection of Lua modules tailored for Cheat Engine to streamline and enhance the process of customizing Cheat Tables. These modules offer tools for automating tasks, managing memory records, interacting with game processes, and more. By leveraging these modules, you can accelerate table creation *(and hopefully improve the efficiency and robustness of your Cheat Tables)*.

Whether you're handling memory records, automating the auto-assembly process, or managing UI components, these modules provide the functionality to create more dynamic and feature-rich Cheat Tables.

![Preview](https://lowlevel.me/uploads/default/original/1X/b0d626ddea072d9171fb7f79588d5a71e4b91110.png)

---

## Credits
Acknowledgments and thanks to the following contributors and resources:

- **LeFiXER**: For invaluable guidance and extensive support throughout the development of this project.
- **rxi**: For sharing the `json.lua`, which made my life a lot easier.
- **TheyCallMeTim13**: For providing inspiration through his meticulously crafted Cheat Tables and for creating the `Module.Helper.lua` Module.

---

## Features
This repository includes the following modules:

### 1. `State.lua`
The `State.lua` module provides a simple and efficient interface for saving and loading the state of memory records in Cheat Engine tables. It leverages the JSON format for serializing and deserializing state data, enabling seamless storage and restoration of memory record states.

### 2. `Helper.lua` *(Standalone)*
The `Helper.lua` module simplifies retrieving data from the game (module). Key features are:

- Retrieving detailed information about the game process.
- Determining process version, architecture (`64-bit` or `32-bit`), and module details.

### 3. `Utility.lua`
The `Utility.lua` module enhances user experience by providing:

- Automatic process attachment.
- Memory record management.
- Safe data reading and writing.
- User-friendly message prompts and dialogs.

### 4. `Logger.lua` *(Standalone)*
The `Logger.lua` module is a powerful logging utility for Cheat Engine, offering:

- Structured logging functionality.
- Customizable output formats and logging levels.
- Support for plain text and JSON formats for seamless integration with external systems or scripts.

### 5. `Teleporter.lua`
The `Teleporter.lua` module introduces teleportation functionalities, including:

- Reading and writing memory positions.
- Saving and loading teleportation data.
  - Saves can be preserved as a Table-File.
- Optional smooth teleportation over a defined duration *(currently unused in existing tables)*.

### 6. `FormManager.lua`
The `FormManager.lua` module allows for UI customization in Cheat Engine, featuring:

- Dynamic theme loading from JSON files at runtime.
- Enhanced aesthetics for Cheat Tables.
- Additional UI components for personalizing Cheat Engine’s main form.

### 7. `AutoAssembler.lua`
The `AutoAssembler.lua` module automates Cheat Engine's auto-assembly process by:

- Dynamically loading and assembling cheat scripts from tables or local `.CEA` files.
  - Simplifies script development and updating by allowing changes to be tested without being part of the (a) table.

---

## Usage
Each module requires specific dependencies to function correctly. Below is a list of dependencies for each module:

- **Module.Logger.lua**
  - `json.lua`

- **Module.State.lua**
  - `json.lua`
  - `Module.Logger.lua`

- **Module.Helper.lua**
  - *(Standalone)*

- **Module.AutoAssembler.lua**
  - `Module.Logger.lua`

- **Module.FormManager.lua**
  - `Module.Logger.lua`

- **Module.Teleporter.lua**
  - `json.lua`
  - `Module.Logger.lua`

- **Module.Utility.lua**
  - `json.lua`
  - `Module.Logger.lua`
  - `Module.FormManager.lua`

To use a module, ensure all its dependencies are included in your Cheat Table script. Import the modules using the `require` function and call their respective functions as documented in their code or guides.

If used or shipped as Table-Files, the normal `require` method won't work.
```lua
local tableLuaFilesDirectory = "luaFiles"
local luaFileExt = ".lua"

function CETrequire(moduleStr)
    if moduleStr ~= nil then
        local localTableLuaFilePath = moduleStr
        if tableLuaFilesDirectory ~= nil and tableLuaFilesDirectory ~= "" then
            local sep = package.config:sub(1, 1)
            localTableLuaFilePath = tableLuaFilesDirectory .. sep .. moduleStr
        end
        local f, err = io.open(localTableLuaFilePath .. luaFileExt)
        if f and not err then
            f:close()
            return dofile(localTableLuaFilePath .. luaFileExt)
        else
            local tableFile = findTableFile(moduleStr .. luaFileExt)
            if tableFile == nil then
                return
            end
            local stream = tableFile.stream
            local fn, err = load(readStringLocal(stream.memory, stream.size))
            if not fn then
                 error('Error loading code: ' .. err)
            end
         return fn()
        end
    end
end

-- ...

CETrequire('json')
CETrequire('Module.State')
CETrequire('Module.Helper')
CETrequire('Module.Utility')
CETrequire('Module.Logger')
CETrequire('Module.Teleporter')
CETrequire('Module.FormManager')
CETrequire('Module.AutoAssembler')
```

---

## Contribution
Contributions are welcome! If you have ideas for improvements or new features or themes, feel free to open an issue or submit a pull request.
