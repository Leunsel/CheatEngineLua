# Manifold Framework

Manifold is a modular Lua framework for Cheat Engine. It runs inside a Cheat Table and provides
memory access, Auto Assembler management, process attachment, state persistence, UI theming,
logging and file handling. The point is to keep Cheat Table development short and repeatable
instead of copying the same boilerplate into every table.

[![Languages](https://skillicons.dev/icons?i=lua)](https://skillicons.dev)

The full documentation is in [`docs/Manifold-Framework.md`](../docs/Manifold-Framework.md), and
every public function is listed in
[`docs/Manifold-Framework-API.md`](../docs/Manifold-Framework-API.md).

## Features

- Plug-and-play modular architecture with one dependency loader for every module
- Structured logging and error handling
- Auto Assembler integration, trampoline detours and custom AA commands
- Memory read and write utilities with pointer path resolution
- Persistent, process-aware state management
- Fully themeable UI with JSON theme files
- Abstraction for file I/O with safe directory management
- Trainer-friendly Teleporter system, 2D and 3D

## Data Directory Structure

Manifold keeps runtime and user data under a data directory. The location is hard-coded in
`CustomIO:New()` and `Logger:New()`, and both resolve it the same way:

```lua
os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
```

### Directory Layout

```
Manifold/
├── CEA/
│   └── <ProcessName>/
│       └── *.CEA                      → Auto Assembler files for each process
├── Themes/
│   └── *.json                         → UI theme configuration files
├── Teleporter/
│   └── Teleporter.<Process>.Saves.txt → Teleport save data (JSON)
├── State/
│   └── Manifold.<StateName>.<Process>.State → Saved table states (JSON)
└── Logs/
    └── Manifold.Runtime.<Process>.log → Execution logs
```

The root is created on demand by `CustomIO:EnsureDataDirectory()`. Each subdirectory is created
by the module that owns it, the first time that module needs it.

| Directory | Created by |
|---|---|
| root | `CustomIO:EnsureDataDirectory()` |
| `Logs` | `Logger:_EnsureLogDirectories()` |
| `Themes` | `UI:EnsureThemeDirectory()` |
| `State` | `State:EnsureStateDirectory()` |
| `Teleporter` | `Teleporter:EnsureTeleporterDir()` |
| `CEA/<Process>` | `AutoAssembler:EnsureDirectoriesExist()` |

There is no setter for the location. It is a plain field on the instance, so you read it and
change it directly, and you have to change it in both places:

```lua
local dataDir = customIO.DataDir
customIO.DataDir = "D:\\Manifold"
logger.DataDir   = "D:\\Manifold"
```

Do it before the modules are constructed. Setting the two fields is not enough on its own once
`state` exists, because `State:New()` resolves the state directory through
`State:EnsureStateDirectory()` and caches the result in `state.TableStateDir`, and
`State:GetStateFilePath()` prefers that cached value over a fresh lookup. A table state saved
after a late change therefore still lands in the old folder. If you have to move the directory
after the fact, assign `state.TableStateDir` yourself as well. The other consumers read
`customIO.DataDir` at the moment they need it, so `AutoAssembler:GetFilePath()`, the theme loader
and the Teleporter pick up the new location on their next call.

## Modules

Manifold is divided into modules that provide core services, runtime utilities and in-game
features. Every module assigns a global class table such as `Logger` or `CustomIO`, and its
instance goes into a global with the same name and a lowercase first letter, `logger` and
`customIO`. Those global names are part of the contract, because modules reach for each other
through them rather than through injected references. `Manifold.Bootstrap` is the exception. It
is a namespace rather than a class, so it has no instance and no `bootstrap` global, and it is
published under two globals, `Bootstrap` and `ManifoldBootstrap`, which are the same table. Both
names work everywhere.

### Framework Core

`Manifold.Bootstrap` is the root of the framework. It requires nothing and declares nothing,
and it holds the only place that knows how a Manifold module is found, built and sequenced.
Every other module declares itself once through `Bootstrap.Declare`, gates its constructor
once through `Bootstrap.Resolve` and closes it once through `Bootstrap.Ready`. A module that
does not find the core falls back to an inert stub, so it stays loadable on its own.

- `Manifold.Bootstrap` → Dependency lookup, module registry and collision detection

### Core Utilities

These modules provide fundamental services like file I/O, logging and JSON handling.

- `Manifold.Json` → JSON encoder and decoder, a self-contained rewrite that replaced the
  vendored third-party implementation
- `Manifold.Logger` → Structured logging system, a framework leaf with no dependencies
- `Manifold.CustomIO` → Data directory and file operations
- `Manifold.Helper` → Read-only facts about the target process's main loaded module, its
  record, name, path, base address, bitness and file version

### Runtime Setup

Modules for runtime configuration and diagnostics.

- `Manifold.Utils` → Displays information and initializes Cheat Tables
- `Manifold.ProcessHandler` → Sets and manages the target process, including auto-attach and
  process watching
- `Manifold.Callbacks` → Binds the Cheat Engine address list handlers and can lock individual
  kinds of edit

### Functional Modules

These modules provide the primary functionality for runtime operations.

- `Manifold.Memory` → Memory read and write utilities, including pointer path resolution
- `Manifold.State` → Persistent table state manager
- `Manifold.AutoAssembler` → Auto Assembler script management
- `Manifold.Trampolines` → Detour installation, instruction relocation and relay allocation
- `Manifold.AssemblerCommands` → Registers the Manifold Auto Assembler commands, among them
  `ManifoldScanModule`, `ManifoldAssert`, `ManifoldPatch`, `ManifoldNop`,
  `ManifoldInstallDetour`, `ManifoldEmitOriginal` and `ManifoldResolveStatic`
- `Manifold.Teleporter` → Save and restore positions, in as many dimensions as the game has

### UI and Themes

Modules responsible for UI customization and theme management.

- `Manifold.Forms` → Theme-aware control factory and the registry every themed control
  lives in
- `Manifold.UI` → Theme system and GUI abstraction

The bundled themes live in `Manifold.Themes`. Two further directories hold things that are not
part of the shipped framework: `Manifold.Modules/Manifold.Dev` holds development tools such as
the assembler linter, the patcher and the RTTI reader, and `Manifold.Modules/Manifold.Testing`
holds the unit test runner.

## Loading Manifold Modules

Manifold modules are loaded using the `CETrequire` function, which first attempts to load from
disk and then from embedded Cheat Engine `TableFiles`. The dual path is the central idea. During
development the modules sit as `.lua` files in the `luaFiles` folder that
`tableLuaFilesDirectory` names below, and because that path is relative, the `io.open` probe
resolves it against the working directory of the Cheat Engine process. In a release they are
embedded as table files so the table is one distributable file.

`CETrequire` belongs in the Cheat Table's own Lua script, not in the framework.

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

Note that `CETrequire` returns `nil` silently for a module it cannot find, and it has no cache,
so every call re-executes the file.

### Example Usage

Load a module, build its instance into the global the rest of the framework expects, and use it.
Most modules need `logger` to exist first, and several also need `customIO`, so load those two
before anything else.

```lua
CETrequire("Manifold.State")
state = State:New()
--- Module and its functions are now available:
state:SaveTableState("Profile-Easy")
```

Some modules need additional setup after loading. The Teleporter has to be told which symbols
and offsets describe the game's position data, and `assemblerCommands:RegisterCoreCommands()`
has to run before the first Auto Assembler script that uses a Manifold command.

### Letting Bootstrap Do It

The hand-written sequence above keeps working, and it is still the documented path. If you would
rather not maintain the order yourself, `Bootstrap.Boot()` walks `Bootstrap.ORDER` and acquires
every module for you, producing the same globals and the same log lines.

```lua
CETrequire("Manifold.Bootstrap")
Bootstrap.Boot({
    config = {
        logger         = { Level = "INFO", LogFileName = "Game" },
        processHandler = { ProcessName = "Game.exe" },
    },
})
```

## Contributing

Contributions, bug reports and feature requests are welcome. Please follow the existing coding
style and modular structure when submitting pull requests or suggestions.

## License

This project is licensed under the terms of the MIT License.
