# Manifold Framework

**Manifold** is a modular Lua framework designed specifically for Cheat Engine. It provides utilities for memory manipulation, UI customization, process handling, logging, and more. Manifold aims to simplify and speed up Cheat Table development.

[![Languages](https://skillicons.dev/icons?i=lua)](https://skillicons.dev)

## 🚀 Features

- Plug-and-play modular architecture
- Structured logging and error handling
- AutoAssembler integration and memory utilities
- Persistent, process-aware state management
- Fully themeable UI with JSON support
- Abstraction for file I/O with safe directory management
- Trainer-friendly Teleporter system for 3D games

## 📁 Data Directory Structure

Manifold organizes runtime and user data in a dedicated `DataDirectory`, resolved by default to:

```lua
os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
```

### Directory Layout

```
Manifold/
├── CEA/
│   └── <ProcessName>/
│       └── *.CEA                      → AutoAssembler files for each process
├── Themes/
│   └── *.json                         → UI theme configuration files
├── Teleporter/
│   └── Teleporter.<Process>.Saves.txt → Teleport save data
├── Logs/
│   └── Manifold.Runtime.<Process>.log → Execution logs
└── ... (other runtime files)
```

Directories are automatically created at runtime by `Manifold.CustomIO`. You can manually retrieve or configure the data path:

```lua
local dataDir = Manifold.CustomIO.GetDataDir()
```

## 📦 Modules

Manifold is divided into several modules that provide core functionality, runtime utilities, and in-game features.

### Core Utilities
These modules provide fundamental services like file I/O, logging, and setup utilities.

- `Manifold.Json` → JSON parser and encoder
- `Manifold.Helper` → Shared utility helpers
- `Manifold.Logger` → Structured logging system
- `Manifold.CustomIO` → Data directory and file operations

### Runtime Setup
Modules for runtime configuration and diagnostics.

- `Manifold.Utils` → Displays information and initializes Cheat Tables
- `Manifold.ProcessHandler` → Sets and manages the target process

### Functional Modules
These modules provide the primary functionality for runtime operations.

- `Manifold.Memory` → Memory read/write utilities
- `Manifold.State` → Persistent table state manager
- `Manifold.AutoAssembler` → AutoAssembler script management
- `Manifold.Teleporter` → Save and restore 3D positions

### UI and Themes
Modules responsible for UI customization and theme management.

- `Manifold.UI` → Theme system and GUI abstraction

## 📥 Loading Manifold Modules

Manifold modules are loaded using the `CETrequire` function, which first attempts to load from disk and then from embedded Cheat Engine `TableFiles`.

### CETrequire Function

```lua
local tableLuaFilesDirectory = "luaFiles"
local luaFileExt = ".lua"

function CETrequire(moduleStr)
    if not moduleStr then return end
    local sep = package.config:sub(1, 1)
    local localTableLuaFilePath = tableLuaFilesDirectory ~= "" and (tableLuaFilesDirectory .. sep .. moduleStr) or moduleStr
    local fullPath = localTableLuaFilePath .. luaFileExt

    local f = io.open(fullPath)
    if f then
        f:close()
        return dofile(fullPath)
    end

    local tableFile = findTableFile(moduleStr .. luaFileExt)
    if not tableFile then return end

    local stream = tableFile.stream
    local fn, err = load(readStringLocal(stream.memory, stream.size))
    if not fn then
        error("Error loading module '" .. moduleStr .. "': " .. err)
    end

    return fn()
end
```

### Example Usage

```lua
CETrequire("Manifold.State")
local state = State:New()
--- Module and its functions are now available:
state:SaveTableState("Profile-Easy")
```

Some modules (like Teleporter) may require additional setup after loading.

## 🤝 Contributing

Contributions, bug reports, and feature requests are welcome! Please follow the existing coding style and modular structure when submitting pull requests or suggestions.

## 📜 License

This project is licensed under the terms of the **MIT License**.
