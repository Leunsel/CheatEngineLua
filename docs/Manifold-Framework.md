# Manifold Framework

> Directory: [`Manifold-Modules/`](../Manifold-Modules/)
> License: MIT · Authors: Leunsel, LeFiXER
> Complete function list: [Manifold-Framework-API.md](Manifold-Framework-API.md)

Manifold is a modular Lua library that runs inside a Cheat Table. It handles process
attachment, memory access, Auto Assembler management, state persistence, UI theming, and
optional features such as the teleporter.

## 1. Core concepts

### 1.1 Module pattern

Most modules follow the same shape:

```lua
local NAME        = "Manifold.Xyz.lua"
local AUTHOR      = {"Leunsel", "LeFiXER"}
local VERSION     = "1.0.0"
local DESCRIPTION = "Manifold Framework Xyz"

Xyz = {}                 -- GLOBAL class table
Xyz.__index = Xyz

local MODULE_PREFIX = "[Xyz]"

-- Bootstrap handshake: the framework core when the Cheat Table has loaded it,
-- an inert stub when it has not.
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

local MODULE = BOOTSTRAP.Declare({
    class = "Xyz", global = "xyz",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger", required = true },
    },
})

function Xyz:New(config) -- constructor
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME
    for k, v in pairs(config or {}) do
        if self[k] ~= nil then instance[k] = v
        else logger:WarningF("Invalid property: '%s'", k) end
    end
    return BOOTSTRAP.Ready(MODULE, instance)
end

function Xyz:CheckDependencies() return BOOTSTRAP.Resolve(MODULE) end

function Xyz:GetModuleInfo()   ... end
function Xyz:PrintModuleInfo() ... end

registerLuaFunctionHighlight('...')   -- CE syntax highlighting

return Xyz
```

Consequences worth knowing:

- Class names are global (`Logger`, `CustomIO`, `UI`, …). There is no namespace encapsulation.
- Instances are global too, lowercase by convention (`logger`, `customIO`, `ui`, …). Modules
  reference these globals directly rather than through injected references. The names are
  therefore part of the contract and cannot be chosen freely.
- `New(config)` drops unknown keys (`if self[key] ~= nil`). A typo in a config key is only logged
  as a warning, never raised as an error.
- `CheckDependencies` is optional. Nine of the fifteen modules define it and call it from `New()`
  (`Json`, `CustomIO`, `ProcessHandler`, `UI`, `State`, `Trampolines`, `AssemblerCommands`,
  `AutoAssembler` and `Teleporter`). `Manifold.Logger`, `Manifold.Helper`, `Manifold.Memory`,
  `Manifold.Forms`, `Manifold.Utils` and `Manifold.Callbacks` have no resolution of their own.
  They reach `Bootstrap.Resolve` through a fallback in `Bootstrap.Ready`, described in 1.3, so
  their declared dependencies are still checked.
- The handshake stub at the top of the file is copied verbatim into every module. That is the one
  duplication the design costs, and it is irreducible. Something has to reach the loader before
  the loader exists. The stub is also what keeps a single module loadable on its own, outside the
  framework and outside Cheat Engine.

### 1.2 Canonical instance names

| Global | Class | Module |
|---|---|---|
| `Bootstrap` / `ManifoldBootstrap` | (namespace) | `Manifold.Bootstrap` |
| `json` | `Json` | `Manifold.Json` |
| `logger` | `Logger` | `Manifold.Logger` |
| `customIO` | `CustomIO` | `Manifold.CustomIO` |
| `helper` | `Helper` | `Manifold.Helper` |
| `memory` | `Memory` | `Manifold.Memory` |
| `forms` | `Forms` | `Manifold.Forms` |
| `processHandler` | `ProcessHandler` | `Manifold.ProcessHandler` |
| `ui` | `UI` | `Manifold.UI` |
| `utils` | `Utils` | `Manifold.Utils` |
| `state` | `State` | `Manifold.State` |
| `trampolines` | `Trampolines` | `Manifold.Trampolines` |
| `assemblerCommands` | `AssemblerCommands` | `Manifold.AssemblerCommands` |
| `autoAssembler` | `AutoAssembler` | `Manifold.AutoAssembler` |
| `teleporter` | `Teleporter` | `Manifold.Teleporter` |
| `teleporterMap` | `TeleporterMap` | `Manifold.TeleporterMap` |
| `callbacks` | `Callbacks` | `Manifold.Callbacks` |

`Manifold.Bootstrap` is a namespace rather than a class, so its functions are dot-called
(`Bootstrap.Ready`) and there is nothing to instantiate. It publishes itself under both
`ManifoldBootstrap` and `Bootstrap`.

`Manifold.Json` was rewritten as a self-contained module in 2026 and its class global is now
`Json`, constructed with `Json:New()`. The old vendored implementation exposed `JSON` and
`JSON:new()`, so the file still assigns `JSON = Json` and keeps lowercase aliases for `new`,
`encode`, `encode_pretty`, `decode`, `newArray`, `newObject` and `null`. Existing table scripts
that call `JSON:new()` keep working unchanged.

The MIT licence in the page header covers the rewrite. It does not cover the file it replaced.
That vendored implementation is JSON.lua by Jeffrey Friedl, released under a Creative Commons
CC-BY licence which asks that the copyright notice, the links and the `AUTHOR_NOTE` string are
kept intact. It survives as `Manifold.Json.Old` in `Manifold.Dev/`, and a table that still ships
that file rather than the rewrite carries the CC-BY terms with it.

### 1.3 Manifold.Bootstrap

`Manifold.Bootstrap` is the framework root. It sits below `Manifold.Json`, requires nothing and
declares nothing. It replaced the six divergent `CheckDependencies` bodies the framework used to
carry, and it is the only place that knows how a Manifold module is found, built and sequenced.

Each module talks to it two or three times:

1. `Bootstrap.Declare(spec)` once at chunk scope, naming the class global, the instance global,
   the version and the dependency list.
2. `Bootstrap.Resolve(MODULE)` once, from the module's own `CheckDependencies`, in the nine
   modules that define one.
3. `Bootstrap.Ready(MODULE, instance)` as the last statement of `New()`.

Step 2 is the optional one. `Manifold.Logger`, `Manifold.Helper`, `Manifold.Memory`,
`Manifold.Forms`, `Manifold.Utils` and `Manifold.Callbacks` never call `Resolve` themselves, so
`Bootstrap.Ready` covers them with a fallback:

```lua
if mod.resolved == nil then Bootstrap.Resolve(mod) end
```

`Bootstrap.Declare` sets `resolved` back to `nil` on every declaration, so the fallback fires once
per module per generation and does nothing when `CheckDependencies` already ran. Resolution
therefore behaves the same either way. A missing optional dependency still marks the module
degraded, and a missing required one still raises before the ready line is emitted. The only
difference is where in `New()` the refusal happens, early on for the nine and at the closing
`Ready` call for the other six.

A dependency comes in one of three kinds:

| Kind | Written as | Effect |
|---|---|---|
| required | `{ "logger", required = true }` | `New()` raises with one legible message when it is absent |
| plain | `{ "json" }` | counted and survivable, the module comes up marked degraded |
| runtime | `{ "ui", runtime = true }` | documentation only, never loaded, never ordered on |

The runtime kind is what makes the framework's apparent cycles harmless. `UI` and `Teleporter`
reference each other, and so do `AutoAssembler` and `ProcessHandler`, but each back edge is
guarded and used only at call time, so neither constrains the load order.

`Bootstrap.Resolve` never loads anything. A missing dependency is reported, and a missing
required dependency refuses. The Cheat Table's own Lua script therefore stays the single source
of truth for what is loaded and in what order. Auto-loading is what used to make
`Manifold.Forms` and `Manifold.Trampolines` appear in tables that never asked for them. Setting
`Bootstrap.Settings.AutoLoad = true` restores the old behaviour, and it gates the implicit path
only. `Bootstrap.Acquire` and `Bootstrap.Get` are explicit lookups and always load, which is
what stops the lazy call sites in `AutoAssembler` and `AssemblerCommands` from minting a second
`Trampolines` whose detour store is empty while the first still holds live hooks.

`Bootstrap.KNOWN` maps every instance name to its `CETrequire` path, its class global, a
constructor and an optional contract predicate. `Bootstrap.ORDER` is the order of execution as
data. `Bootstrap.Verify()` proves that every `ORDER` key exists in `KNOWN`, that every `KNOWN`
key appears in `ORDER` exactly once, and that every load-time dependency sits earlier in the
array. Because each edge is forced to point strictly backwards in a linear list, an order that
verifies cannot contain a load-time cycle.

Two constraints in `ORDER` are hand-injected rather than produced by the topological pass.
`logger` comes before `customIO` because CustomIO's json-miss path indexes the logger unguarded,
and `callbacks` comes last because its chunk binds Cheat Engine handlers at load time.

The core is also the collision detector, because `Declare` runs on every execution of a module
file and nothing else does. It reports four situations at four severities:

| Signal | Meaning |
|---|---|
| `CONFLICT` | a different file or version claimed this class global. Never benign |
| `RELOAD gen N` | the same files were executed again, so gen N-1 instances are orphaned |
| `DUPLICATE` | the same chunk declared itself twice without being re-executed |
| `ORPHAN` | an instance survived a re-execution and is being kept rather than rebuilt |

An orphan is kept on purpose. `Bootstrap.Validate` checks metatable identity and usability,
`Bootstrap.Contract` checks usability alone. An instance orphaned by a re-require still answers
every call its consumers make, and rebuilding it would silently drop live state such as
`Trampolines.ActiveDetours`, ProcessHandler's attachment or UI's theme lock. Re-running a table
script re-executes all fifteen module files at once, so the reload warnings are batched into one
short summary instead of fifteen near-identical lines.

Logging is deliberately narrow. `Bootstrap.Ready` emits exactly one line per module per
generation, carrying name and version, at `Info` when every declared dependency is satisfied and
at `Warning` when the module came up degraded. Never both, and never one line per dependency. A
module that failed a required dependency never reaches `Ready`, so a missing line is a reliable
signal that the module did not come up. Collisions get their own lines at their own severity,
because a collision is not the routine event a ready line describes.

The severities are configurable through `Bootstrap.Settings`, which lives in the registry so a
core reload cannot undo a Cheat Table's choice:

```lua
Bootstrap.Settings.ReadyLevel    = "Info"      -- every declared dependency satisfied
Bootstrap.Settings.DegradedLevel = "Warning"   -- came up without an optional dependency
Bootstrap.Settings.ReloadLevel   = "Warning"   -- the same file was executed again
Bootstrap.Settings.ConflictLevel = "Error"     -- a DIFFERENT file or version claimed a name
Bootstrap.Settings.AutoLoad      = false       -- refuse and report, do not load implicitly
```

`ReadyLevel` deserves a note. `Logger:New()` starts at `Levels.ERROR`, so a plain `Info` ready
line reaches the log file but not the console until the level is raised. The setup below calls
`logger:SetLevel(logger.Levels.INFO)`, which is the intended fix. Keep the level permissive while
the modules are being constructed and clamp it at the end, in the release branch. A table that
deliberately runs at `ERROR` and still wants the banners on screen can set `ReadyLevel` to
`"ForceInfo"`, which bypasses the filter.

Lines produced before a logger exists are queued rather than thrown away, and replayed in order
once one appears. That is how `Manifold.Json`, which is position 1 and constructed before any
logger can exist, still gets its banner. Lines that reached the console before `customIO` existed
are replayed into the log file for the same reason.

The registry survives re-execution. Everything that must outlive a `CETrequire` of the core lives
in one `_G` slot, and the published API table is created once and mutated in place, so a module's
captured `local BOOTSTRAP` stays valid after a core reload.

The rest of the surface is used from the Cheat Table rather than from a module:

| Call | Purpose |
|---|---|
| `Bootstrap.Boot(options)` | walk `ORDER` and acquire every module, so the order of execution runs itself |
| `Bootstrap.Acquire(key, config)` | guarantee that `key` names a live, usable instance in `_G` |
| `Bootstrap.Get(key)` | the same lookup, named for runtime call sites |
| `Bootstrap.Require(path, class)` | a `CETrequire` that skips the call when the class is already present |
| `Bootstrap.Register(key, spec)` | teach the core about a module that is not in `KNOWN` |
| `Bootstrap.Configure(key, config)` | store a constructor config for a later lazy bring-up |
| `Bootstrap.Reload(key)` | drop the globals, re-require and reconstruct one module |
| `Bootstrap.Verify(raise)` | prove the order of execution |
| `Bootstrap.Report()` / `PrintReport()` | everything the registry knows, as rows or as a log block |
| `Bootstrap.WriteManifest()` | re-write the manifest into the log file after `logger:ClearLogFile()` |
| `Bootstrap.Flush()` | replay queued lines once a logger exists |
| `Bootstrap.Once(key, fn)` | run a load-time side effect exactly once per Lua state |

`Bootstrap.Once` exists for load-time side effects that must not stack. `Manifold.Callbacks`
chains `AddressList.OnAutoAssemblerEdit` and `LuaEngine.OnShow` on top of whatever was there, so
without a latch every re-require adds another permanent wrapper layer. No module calls
`Bootstrap.Once` yet, so that chain still grows on a reload.

`Bootstrap.WriteManifest` is a repair for a known truncation, not a general dump. Call it once,
immediately after `logger:ClearLogFile()`, and never anywhere else. Clearing the file happens
after `customIO` exists, which is after `Manifold.Json`, `Manifold.Logger` and `Manifold.CustomIO`
have already recorded themselves, so it erases exactly the three entries a support log most needs.

### 1.4 Order of execution and declared dependencies

`Bootstrap.ORDER` and the dependency lists the modules declare:

```
 1  json               logger runtime
 2  logger             (none, this module is a framework leaf)
 3  customIO           logger required, json required
 4  helper             logger
 5  memory             logger required
 6  forms              logger
 7  processHandler     logger required, utils runtime
 8  ui                 logger required, customIO required, forms required, json,
                       teleporter runtime
 9  utils              logger required, customIO runtime, helper runtime,
                       memory runtime, ui runtime
10  state              logger required, customIO required, processHandler runtime
11  trampolines        logger
12  assemblerCommands  logger required, trampolines required
13  autoAssembler      logger required, customIO, processHandler runtime,
                       trampolines runtime
14  teleporter         logger required, forms required, memory, customIO, ui runtime
15  teleporterMap      logger required, forms required, teleporter required, customIO,
                       json runtime, utils runtime, ui runtime
16  callbacks          logger required, ui runtime
```

`utils` sits after `ui` although nothing forces it to. `utils:InitializeTable()` calls
`ui:InitializeForm()`, which is a runtime edge and constrains nothing at construction, but
putting `utils` here lets a table script keep each module's require, constructor and setup
together. Utils declares only `logger` as required, so it is free to sit anywhere after the
logger.

## 2. Bootstrapping a Cheat Table

### 2.1 The `CETrequire` loader

Manifold modules are not loaded with `require` but through a helper that searches the file system
first and the table files embedded in the `.CT` second. This function belongs in the Cheat
Table's *table Lua script*:

```lua
local tableLuaFilesDirectory = "luaFiles"
local luaFileExt = ".lua"

function CETrequire(moduleStr)
    if not moduleStr then return end
    local sep = package.config:sub(1, 1)
    local localTableLuaFilePath = tableLuaFilesDirectory ~= ""
        and (tableLuaFilesDirectory .. sep .. moduleStr)
        or moduleStr
    local fullPath = localTableLuaFilePath .. luaFileExt

    local f = io.open(fullPath)
    if f then
        f:close()
        return dofile(fullPath)                      -- 1) development: file on disk
    end

    local tableFile = findTableFile(moduleStr .. luaFileExt)
    if not tableFile then return end                 -- 2) release: embedded table file

    local stream = tableFile.stream
    local fn, err = load(readStringLocal(stream.memory, stream.size))
    if not fn then
        error("Error loading module '" .. moduleStr .. "': " .. err)
    end
    return fn()
end
```

The dual path is the central idea. During development the modules sit as files next to the `.CT`
for fast editing with no re-import, and in a release they are embedded as table files so the
whole thing is one distributable file.

`CETrequire` returns `nil` silently for a missing module instead of raising, so a typo in a module
name only surfaces later as "attempt to index a nil value". It also has no module cache and
re-executes the file on every call. `Bootstrap.Require` covers both problems for the requires it
controls, by skipping the call when the class global is already a table and by turning a typo'd
path into a real error. It cannot cover the requires it does not control, so those show up as
`RELOAD` and `ORPHAN` lines instead of corrupting silently.

### 2.2 Minimal setup

The hand-written sequence, in the order `Bootstrap.ORDER` describes:

```lua
-- 0) Framework root
CETrequire("Manifold.Bootstrap")

-- 1) Base
CETrequire("Manifold.Json")
json = Json:New()

CETrequire("Manifold.Logger")
logger = Logger:New()
logger:SetLevel(logger.Levels.INFO)

CETrequire("Manifold.CustomIO")
customIO = CustomIO:New()

CETrequire("Manifold.Helper")
helper = Helper:New()

CETrequire("Manifold.Memory")
memory = Memory:New()

-- 2) Presentation and lifecycle, interleaved because ORDER says so:
--    forms and ui are presentation, processHandler and utils are lifecycle
CETrequire("Manifold.Forms")
forms = Forms:New()

CETrequire("Manifold.ProcessHandler")
processHandler = ProcessHandler:New({ ProcessName = "Game.exe" })

CETrequire("Manifold.UI")
ui = UI:New({
    Theme        = "Manifold.Dark-Aqua.Min",
    SloganStr    = "MANIFOLD",
    SignatureStr = "by YourName",
})

CETrequire("Manifold.Utils")
utils = Utils:New({
    Author     = "YourName",
    Target     = "Game.exe",
    TargetStr  = "Game Title",
    Version    = "1.0.0",
    VerifyMD5  = false,
    IsRelease  = false,
})

-- 3) Runtime
CETrequire("Manifold.State");             state             = State:New()
CETrequire("Manifold.Trampolines");       trampolines       = Trampolines:New()
CETrequire("Manifold.AssemblerCommands"); assemblerCommands = AssemblerCommands:New()
assemblerCommands:RegisterCoreCommands()
CETrequire("Manifold.AutoAssembler");     autoAssembler     = AutoAssembler:GetInstance()
autoAssembler:SetProcessName("Game.exe")

-- 4) Callbacks last: its chunk binds CE handlers at load time
CETrequire("Manifold.Callbacks");         callbacks         = Callbacks:New()

-- 5) Go
processHandler:AutoAttach("Game.exe")
```

`AutoAttach` starts a timer that waits for the process. Once found, the handler opens it, runs
`PerformPostAttachTasks()` (which in turn calls `utils:InitializeTable()` → `ui:InitializeForm()`
+ `utils:SetTitle()` and optionally verifies the MD5 hash) and starts process monitoring.

### 2.3 The same setup through `Bootstrap.Boot`

`Bootstrap.Boot` walks `ORDER` and acquires every module, so it produces the same globals and the
same ready lines as the sequence above. It is entirely optional, and the hand-written version
keeps working unchanged.

```lua
CETrequire("Manifold.Bootstrap")

Bootstrap.Boot({
    config = {
        logger         = { Level = 2, LogFileName = "Game" },   -- 2 = Levels.INFO
        processHandler = { ProcessName = "Game.exe" },
        ui             = { Theme = "Manifold.Dark-Aqua.Min", SloganStr = "MANIFOLD",
                           SignatureStr = "by YourName" },
        utils          = { Author = "YourName", Target = "Game.exe",
                           TargetStr = "Game Title", Version = "1.0.0", VerifyMD5 = false },
        autoAssembler  = { ProcessName = "Game.exe" },
    },
    skip  = { teleporter = true },
    after = {
        assemblerCommands = function(instance) instance:RegisterCoreCommands() end,
    },
})

processHandler:AutoAttach("Game.exe")
```

A `KNOWN` entry may declare what it `needs` and that it is `optional`. `Boot` skips such a module,
with one Info line rather than a failure, when a need was skipped or failed or is otherwise not
there, and when its file is not shipped with the table. `teleporterMap` is the first of these:
it needs `teleporter`, so the `skip = { teleporter = true }` above still boots cleanly, and a table
that does not ship `Manifold.TeleporterMap.lua` is not told its boot is incomplete.

`options.only` restricts the walk to a list of keys, `options.skip` removes keys from it,
`options.after` runs a post-load hook per module, and `options.stopOnError` turns the first
failure into an error instead of a collected report. `options.verify` defaults to true and runs
`Bootstrap.Verify()` after the walk rather than before, because only then has every module
declared itself.

### 2.4 The `Manifold` table-side global

`Manifold.UI` reads `Manifold.Setup.IsRelease` when theming the Lua engine. In release mode the
script panel and its splitter are hidden, leaving only the output pane. That global is not
created by the framework. The Cheat Table's own Lua script is expected to provide it, before
`Manifold.UI` applies a theme:

```lua
Manifold = Manifold or {}
Manifold.Setup = Manifold.Setup or { IsRelease = false }
```

Without it, `UI:ApplyTheme` aborts inside its `pcall` at the Lua-engine step. `ActiveTheme` is
never assigned, and the Forms and Teleporter passes that follow are skipped.

### 2.5 Ordering pitfalls

1. `logger` first. Practically every module logs inside `New()` already, and a `required = true`
   dependency on `logger` now refuses out of `New()` with one legible message rather than raising
   somewhere inside a dependency check. Nothing in `Manifold.Bootstrap` indexes the logger without
   a guard, which is what closed
   [TODO T4](TODO.md#t4-statecheckdependencies-uses-the-logger-before-it-exists) structurally.
2. `forms` before `ui`, `teleporter` and `teleporterMap`. All three declare `forms` as required
   and refuse to construct without it, and the map additionally requires `teleporter`.
3. `Manifold.Callbacks` registers at load time. On `dofile` it replaces four handlers outright,
   `AddressList.OnDescriptionChange`, `OnAddressChange`, `OnTypeChange` and `OnValueChange`,
   and it defines the global `onMemRecPreExecute` and `onMemRecPostExecute`. The two remaining
   hooks, `AddressList.OnAutoAssemblerEdit` and the Lua engine's `OnShow`, capture the previous
   handler and call it, so they chain rather than replace. Load the module after `ui` so the
   `OnShow` hook can apply the theme. It is last in `Bootstrap.ORDER` for this reason.
4. `assemblerCommands:RegisterCoreCommands()` before the first AA script that uses
   `ManifoldScanModule` and friends.

## 3. Data directory

Default root (hard-coded in `CustomIO:New()` and `Logger:New()`):

```
%USERPROFILE%\AppData\Local\Manifold
```

```
Manifold/
├── CEA/
│   └── <ProcessName>/
│       └── *.CEA                      → side-loaded Auto Assembler scripts
├── Themes/
│   └── *.json                         → external themes ("(External)" suffix in the name)
├── Teleporter/
│   ├── Teleporter.<Process>.Saves.txt → teleporter saves (JSON)
│   └── Teleporter.<Process>.Map.txt   → the map's remembered view (JSON)
├── State/
│   └── Manifold.<StateName>.<Process>.State → table states (JSON)
└── Logs/
    └── Manifold.Runtime.<Process>.log → runtime log
```

Directories are created on demand:

| Directory | Created by |
|---|---|
| root | `CustomIO:EnsureDataDirectory()` |
| `Logs` | `Logger:_EnsureLogDirectories()` |
| `Themes` | `UI:EnsureThemeDirectory()` |
| `State` | `State:EnsureStateDirectory()` |
| `Teleporter` | `Teleporter:EnsureTeleporterDir()` |
| `CEA/<Process>` | `AutoAssembler:EnsureDirectoriesExist()` |

There is no setter API for the location. It can only be changed on the field directly, and it has
to be done in both places:

```lua
customIO.DataDir = "D:\\Manifold"
logger.DataDir   = "D:\\Manifold"   -- the logger keeps its own copy!
```

> The segment's `README.md` mentions `Manifold.CustomIO.GetDataDir()`. That function does not
> exist in the code, use `customIO.DataDir`.

## 4. Module overview

### Framework root

| Module | Version | Purpose |
|---|---|---|
| Manifold.Bootstrap | 1.0.3 | Dependency lookup, module registry, order of execution, collision detection |

### Core modules

| Module | Version | Purpose |
|---|---|---|
| Manifold.Json | 1.0.1 | Self-contained JSON encoder and decoder with optional logger integration |
| Manifold.Logger | 1.0.3 | Five-level logging with file and console output |
| Manifold.CustomIO | 1.0.3 * | File, JSON, CSV and table-file I/O, directory management |
| Manifold.Helper | 1.1.0 | Read-only facts about the target's main loaded module |

\* The changelog header already says `v1.0.4` while the `VERSION` constant reads `1.0.3`.

### Lifecycle

| Module | Version | Purpose |
|---|---|---|
| Manifold.Utils | 1.1.0 | Window title, dialogs, hash check, custom types, async switching |
| Manifold.ProcessHandler | 2.0.0 | Auto-attach, process monitoring, cleanup and re-attach |

### Runtime

| Module | Version | Purpose |
|---|---|---|
| Manifold.Memory | 1.1.0 | Type-safe read/write/add wrappers, symbol resolution, pointer paths |
| Manifold.State | 1.1.0 | Saving and restoring activation states and hotkeys |
| Manifold.AutoAssembler | 2.0.7 | Process-aware AA toggling with transactions and rollback |
| Manifold.Callbacks | 1.0.6 | Overrides CE callbacks, locks edits |

### AA language extension

| Module | Version | Purpose |
|---|---|---|
| Manifold.AssemblerCommands | 1.2.7 | Registers 10 custom Auto Assembler commands |
| Manifold.Trampolines | 1.2.0 | 5-byte detours through a relay slot in the PE header |

### Presentation

| Module | Version | Purpose |
|---|---|---|
| Manifold.Forms | 1.4.0 | Role-based, themeable VCL control factory with a registry |
| Manifold.UI | 1.2.2 | Theme system, CE window tweaks, theme creator |

### Feature

| Module | Version | Purpose |
|---|---|---|
| Manifold.Teleporter | 1.6.2 | Save/load positions in any number of dimensions, optional areas, own UI, CE record generation |
| Manifold.TeleporterMap | 1.3.3 | Interactive canvas map over the Teleporter's saves: one area at a time, height in size and shade, readable crowds |

### Developer modules (`Manifold.Dev/`)

Not part of a normal table setup. They are loaded manually during development.

> `Manifold.Dev/` is listed in `.gitignore`, so these files are not published to GitHub. The
> descriptions below document the local working copy.

| Module | Version | Purpose |
|---|---|---|
| Manifold.Json (working copy) | 1.0.1 | Development copy of the shipped module |
| Manifold.Json.Old | 20161109.21 | The vendored Jeffrey Friedl implementation the rewrite replaced, CC-BY |

### Tests (`Manifold.Testing/`)

`Manifold.UnitTest.lua` is a standalone runner executed from the CE Lua console. Per module it
checks loadability, metadata (`GetModuleInfo`), the export contract, and an optional behavior
scenario. `Manifold.UnitTest.Output.txt` contains a recorded run.

## 5. Central flows

### 5.1 Process lifecycle

Four steps, and the module does nothing besides them.

```
processHandler:AutoAttach("Game.exe")
   │  timer every 1000 ms (AutoAttachTimerInterval)
   │  optional timeout via options.maxSecs
   ▼
getProcessIDFromProcessName  →  openProcess  →  readInteger(process)
   │                                                   │
   │  a PID and an open are not proof; only the read is │
   ▼                                                   ▼
stale entry: say so once, keep waiting        confirmed: attached
                                                       │
                                                       ├─ PerformPostAttachTasks()
                                                       │    ├─ utils:InitializeTable()
                                                       │    └─ utils:VerifyFileHash()  (when utils.VerifyMD5)
                                                       ├─ options.onAttached(self, name, pid)
                                                       └─ watch
                                                            ├─ timer every 1000 ms → readInteger(process)
                                                            └─ fallback thread, only while the timer is silent
```

When the read fails `LivenessFailureThreshold` times in a row:

```
watch → loss
 ├─ Stop()                        both timers, and the watch epoch is retired
 ├─ DisableAllWithoutExecute()    AddressList.disableAllWithoutExecute()
 │                                + deleteAllRegisteredSymbols()
 ├─ ResetProcessBoundState()      autoAssembler:Reset()
 │                                assemblerCommands.ActivePatches = {}
 │                                trampolines:Reset()
 └─ AutoAttach(processName)       the cycle restarts, unless it has disarmed
```

Cheat Engine hands out PIDs from a cached process list, so a game that has already exited is still
found by name and `openProcess` on its dead PID still reports success — the entry lingers as
`<pid>-???`. That is why the attach is confirmed with a read: without it the handler reattaches to
the corpse, the watch notices immediately, and the table is torn down every few seconds forever.

Losing the same PID `SamePidLossLimit` times in a row, each within `QuickLossSeconds` of attaching,
means the reattach is not recovering anything. The handler then stops restarting itself and reports
once. A longer session resets the count, and `processHandler:AutoAttach(name)` re-arms it.

The watch epoch lives in `_G.__ManifoldProcessHandlerEpoch` and is retired on every `Stop()`. Every
timer and thread carries the epoch it was born under and exits as soon as that epoch is gone. It has
to be shared rather than per-instance: reloading the table builds a new handler while the previous
one's watchers keep running, and only a process-wide epoch can retire those.


### 5.2 Auto Assembler execution

```lua
autoAssembler:AutoAssemble("MyScript", memrec)   -- file from CEA/<Process>/
autoAssembler:AutoAssemble(scriptText, true)     -- raw text, targetSelf
```

`AutoAssemble(fileOrText, memrecOrTargetSelf, targetSelf)` runs:

```
_txBegin()                                    transaction depth +1
  ├─ _validateProcessOrThrow()                process attached? correct process?
  ├─ _checkProcessChangedOrThrow()            PID changed? → reset
  ├─ _loadScriptText()                        raw text (contains \n) OR file / table file
  ├─ _beginTrampolineTransaction()            only when Manifold*Detour appears in the text
  ├─ _stateKey(name, memrec)                  "name#MRID:<id>", stable across runs
  ├─ autoAssembleCheck(text, willEnable, ts)  syntax check up front
  ├─ autoAssemble(text, ts, st.DisableInfo)   toggle: DisableInfo == nil → ENABLE
  ├─ _txRememberEnable(...)                   remember for rollback
  └─ trampolineTx:CommitTransaction()
_txCommit()
```

On failure:

- `trampolineTx:RollbackTransaction(reason)` restores the original bytes of the inject site and
  the relay slot.
- At the top level, `_txRollback()` disables every script enabled in this transaction in reverse
  order.
- With `BreakOnError = true` (the default) the error is re-raised so CE discards the memory
  record's activation.

State lives in `AutoAssembler.States[key]`:

```lua
{
  Key, Name, DisableInfo, Active, TargetSelf,
  Memrec, LastScriptText, LastLogicalName
}
```

`DisableInfo ~= nil` means "active". That is why a single call handles both enabling and
disabling.

### 5.3 Theme application

```
ui:ApplyTheme(themeName [, allowReapply])
  ├─ AcquireThemeApplyLock()      global lock in _G.__ManifoldThemeApplyLock,
  │                               stale timeout 8000 ms
  ├─ GetTheme(themeName)          reloads all themes if needed
  ├─ ApplyThemeToTreeView
  ├─ ApplyThemeToAddressList      including the Header.Canvas.OnChange hook
  ├─ ApplyThemeToMainForm         → whether the slogan label exists
  ├─ ApplyThemeToAddressRecords   colour per record type (GetRecordColor)
  │                               → recoloured, unchanged
  ├─ ApplyThemeToLuaEngine        controls + execute panel (twice, deliberately)
  │                               → whether the window was open
  ├─ ApplyThemeToForms            every control registered through Manifold.Forms
  ├─ ApplyThemeToTeleporter       if the teleporter is loaded → whether it was
  ├─ teleporterMap:OnThemeApplied if the map is loaded → whether its window was open
  ├─ one InfoBlock                the whole apply, reported once
  └─ ReleaseThemeApplyLock()
```

`ApplyTheme` synchronizes itself into the main thread when it is called from anywhere else. The
lock deliberately lives in `_G` rather than on the instance. If the table Lua script is executed
again and a new `UI` instance is created, the lock still applies.

The `ApplyThemeTo*` functions return what they did instead of logging it, so the whole apply is one
entry:

```
[19:48:29] [INFO] [UI] Theme applied
   Theme      : Bearded-Arc
   Memrecs    : 37 recoloured, 3 unchanged
   Lua Engine : themed
   Slogan     : themed
   Teleporter : not open
   Map        : not open
```

`ApplyThemeObject`, which the theme creator uses, emits the same block. A theme applied by name and
a theme applied from the editor therefore read identically in the log.

### 5.4 Theme format

```json
{
  "name": "Dark Aqua",
  "author": "Leunsel",
  "description": "…",
  "tokenColors": [
    { "element": "MainForm.Color", "setting": { "color": "#000a12" } },
    { "element": "TreeView.Font.Color", "setting": { "color": "#00ccff" } }
  ]
}
```

- `name`, `author` and `description` are optional. The bundled `*.Min.json` files in
  `Manifold-Modules/Manifold.Themes/` only contain `tokenColors`, and the display name is derived
  from the file name at runtime.
- Colours are `#RRGGBB` and are converted at load time through `string:bgr()` → `UI:RGB2BGR()`
  into the BGR format the VCL expects.
- Missing tokens are collected into one warning. The affected controls keep their previous colour
  (`theme[token] or control.Color`).

There are 25 tokens. The full list with descriptions lives in `UI.ThemeTokens` and
`UI.TokenDescriptions` and in the [API reference](Manifold-Framework-API.md#manifoldui).

### 5.5 Theme sources and load order

`ui:LoadThemes()` collects from two sources:

1. `%USERPROFILE%\AppData\Local\Manifold\Themes\*.json`, marked as external, so the display name
   gets the suffix `" (External)"`.
2. Embedded table files, discovered through CE's `miTable` menu (every entry whose caption ends in
   `.json`).

Both end up in `UI.ThemeList[themeName] = { [token] = bgrColor, ... }`.

`ui:UpdateThemeSelector()` generates memory records from that. It looks for the record described
as `[— UI : Theme Selector —] ()->`, deletes its children, and creates one `vtAutoAssembler`
record per theme whose `{$lua}` script calls `ui:ApplyTheme(memrec.Description)` and then disables
itself through `utils:AutoDisable(memrec.ID)`.

## 6. Custom Auto Assembler commands

After `assemblerCommands:RegisterCoreCommands()`, ten additional commands are available in every
AA script.

| Command | Signature | Effect |
|---|---|---|
| `ManifoldScanModule` | `(symbol, module, signature [, protection, alignType, alignParam])` | Unique AoB scan. Replaces itself with `define(symbol, module+OFFSET)`. Aborts when the signature is ambiguous. |
| `ManifoldAssert` | `(address, bytePattern)` | Compares the bytes at `address` against the pattern (`??` = wildcard). Reports the first mismatch with a marker but does not stop. |
| `ManifoldPatch` | `(address, bytePattern)` / `(address)` | Writes bytes and remembers the original. Without a second argument: restore. |
| `ManifoldNop` | `(address, count)` / `(address)` | Like `ManifoldPatch` with `90` bytes. Without a count: restore. |
| `ManifoldInstallDetour` | `(name, injectExpr [, destExpr, minSize])` | 5-byte detour through a PE-header relay. Without `destExpr`, `<name>Code` is assumed. |
| `ManifoldEmitOriginal` | `(name)` | Emits the relocated original instructions and jumps back. |
| `ManifoldEmitOriginalNoReturn` | `(name)` | Same, without the automatic return jump. |
| `ManifoldEmitReturn` | `(name)` | Only `jmp <name>_Return`, skipping the original code. |
| `ManifoldDestroyDetour` | `(name)` | Restores inject and relay bytes, unregisters the symbols. |
| `ManifoldResolveStatic` | `(symbol, addrExpr [, dispOffset, instrLen, mode, outputMode])` | Resolves RIP-relative or absolute operands and emits `define(symbol, ...)`. |

### Example: classic hook

```asm
[ENABLE]
ManifoldScanModule(HealthHook, Game.exe, 89 41 34 8B 45 08)
alloc(newmem, $1000, HealthHook)
ManifoldAssert(HealthHook, 89 41 34 8B 45 08)

label(return)
newmem:
  mov [rcx+34], 270F     // 9999
  jmp return

HealthHook:
  jmp newmem
  nop
return:
registersymbol(HealthHook)

[DISABLE]
HealthHook:
  db 89 41 34 8B 45 08
unregistersymbol(*)
dealloc(*)
```

### Example: detour with trampoline

```asm
[ENABLE]

ManifoldScanModule(cWeaponGunAmmoHook,MonsterHunterWilds.exe,48 8B ? ? 48 8B ? ? 48 ? 48 F7 ? ? 49 89 ? 48 89 ? 48 ? 48 F7 ? ? 49 39 ? 0F 9C)
alloc(n_cWeaponGunAmmo,$1000)

ManifoldInstallDetour(cWeaponGunAmmo,cWeaponGunAmmoHook,n_cWeaponGunAmmo)
ManifoldAssert(cWeaponGunAmmoHook,48 8B 46 10 48 8B 4E 20)

label(o_cWeaponGunAmmo)
label(cWeaponGunAmmoPtr)

n_cWeaponGunAmmo:
  mov [cWeaponGunAmmoPtr],rsi
  
o_cWeaponGunAmmo:
  ManifoldEmitOriginal(cWeaponGunAmmo)
 
cWeaponGunAmmoPtr:
  dq 0

registersymbol(cWeaponGunAmmoHook cWeaponGunAmmoPtr)

[DISABLE]

ManifoldDestroyDetour(cWeaponGunAmmo)

unregisterSymbol(*)
dealloc(*)
```

`ManifoldInstallDetour` creates the symbols `cWeaponGunAmmo_Block`, `cWeaponGunAmmo_Relay`,
`cWeaponGunAmmo_Destination`, `cWeaponGunAmmo_Return` and, after `ManifoldEmitOriginal`,
`cWeaponGunAmmo_Original`.

### Why a relay in the PE header?

An absolute jump costs 14 bytes on x64 (`jmp qword ptr [rip+0]` plus an 8-byte target). At compact
hook sites that is often too much. `Manifold.Trampolines` solves it like this:

1. It searches the PE header of the target module for a free slot containing only `0x00` or `0xCC`
   bytes. The search starts at `ModuleBase + 0x500` or at the end of the section headers,
   whichever is higher, and runs to `max(SizeOfHeaders, 0x1000)` clamped to the lowest section
   VirtualAddress, in `0x10` steps. The clamp is what keeps the search out of live code when
   `SectionAlignment` is smaller than `0x1000`, which happens with packers and some system DLLs.
2. That slot receives a `jmp qword ptr [Destination]` plus the 8-byte target pointer, 16 bytes in
   total, rounded up to the alignment.
3. The hook site then only needs a 5-byte `jmp rel32` into that relay.
4. Only whole instructions covering at least 5 bytes are overwritten (`_collectInstructionRange`),
   and the remainder is padded with `nop`.

The original bytes are stored and relocated for `ManifoldEmitOriginal`. Relative jumps
(`_analyzeRelativeControlFlow`) and RIP-relative memory accesses
(`_rewriteAbsoluteMemoryInstruction`) are rewritten to absolute addresses so the original code
runs correctly from its new location. Position-independent control transfers and stack
instructions are copied verbatim rather than wrapped in `push`/`pop`, and the relocation is
bitness-correct on both x86 and x64.

> The relay sits in a module region that is normally not read at runtime. Anti-cheat systems that
> verify module integrity across the whole image range will still see the change.

## 7. State management

```lua
state:SaveTableState("Profile-Easy")
state:LoadTableState("Profile-Easy")
state:RestoreOriginalState()          -- deactivate everything
```

States are written to `%USERPROFILE%\AppData\Local\Manifold\State\Manifold.<Name>.<Process>.State`
as a JSON array. Only records that are active or carry hotkeys are included:

```json
[
  {
    "index": 4,
    "id": 12,
    "description": "Infinite Health",
    "type": "ScriptID",
    "active": true,
    "hotkeys": [
      { "keys": [17, 72], "action": 0, "description": "Toggle", "value": "" }
    ]
  }
]
```

`type` is one of `ScriptID` (`vtAutoAssembler`), `HeaderID` (`IsGroupHeader`) or `MemoryRecord`.
`action` is the numeric index from `HOTKEY_ACTIONS`:

| Value | Constant |
|---|---|
| 0 | `mrhToggleActivation` |
| 1 | `mrhToggleActivationAllowIncrease` |
| 2 | `mrhToggleActivationAllowDecrease` |
| 3 | `mrhActivate` |
| 4 | `mrhDeactivate` |
| 5 | `mrhSetValue` |
| 6 | `mrhIncreaseValue` |
| 7 | `mrhDecreaseValue` |

`RestoreState` is exclusive. Records not listed in the file get deactivated, and matching happens
via `mr.ID` rather than the description. Async records are awaited with a 10,000 ms timeout, and
the result comes back in `stats`:

```lua
local stats = state:LoadTableState("Profile-Easy")
-- stats = { activatedCount, deactivatedCount, unchangedCount, failedCount }
```

Since version 1.0.5 every access to `AddressList`, `MemoryRecord` and hotkeys is routed through
`synchronize()` on the GUI thread, for CE 7.6 compatibility.

## 8. Teleporter

The teleporter reads and writes a position through registered AA symbols. How many components a
position has is not fixed. `Transform.Offsets` decides, so the same module drives a 3D game, a 2D
platformer and a top-down game without a switch anywhere.

### 8.1 Configuration

```lua
CETrequire("Manifold.Teleporter")
teleporter = Teleporter:New({
    Transform = { Symbol = "TransformPtr", Offsets = { 0x30, 0x34, 0x38 }, ValueType = vtSingle },
    Waypoint  = { Symbol = "WaypointPtr",  Offsets = { 0x00, 0x04, 0x08 }, ValueType = vtSingle },
    Symbols   = { Saved = "SavedPositionFlt", Backup = "BackupPositionFlt" },
    Settings  = {
        ValueType             = vtSingle,
        PauseWhileTeleporting = true,
        AdjustYCoordinate     = true,   -- lift the target by AdjustmentAmount
        YCoordinateIndex      = 2,      -- 1 = X, 2 = Y, 3 = Z
        AdjustmentAmount      = 10.0,
    },
    Areas     = { Names = { "Slums", "Old Town", "The Following" } },   -- the game's maps, see 8.6
})
```

| Section | Meaning |
|---|---|
| `Transform` | Current player position. Read as a pointer (`[Symbol]+0` plus offsets). |
| `Waypoint` | Optional waypoint position, also a pointer. |
| `Additional` | Optional second write target (some games require a second set of coordinates to allow for proper teleports). Only used when `Symbol` is set. |
| `Symbols.Saved` / `.Backup` | Two allocated buffers for "last save" and "position before the last jump". Read and written directly, not as pointers. |
| `Areas` | Optional. `Names` declares the game's separate maps for the Teleporter Map; `DeriveFromCategory` (default `true`) lets a save's top category stand in for a missing `Area`. See 8.4 and 8.6. |

Offsets for `Saved`/`Backup` are computed by `CalculateSymbolOffsets()` from `Settings.ValueType`
and the axis count (`vtSingle` in three dimensions → `{0, 4, 8}`, in two → `{0, 4}`).

The required AA scaffolding (example):

```asm
[ENABLE]
alloc(n_Symbols,$1000)
label(SavedPositionFlt BackupPositionFlt)

n_Symbols:
  SavedPositionFlt:
    dd (float)0
    dd (float)0
    dd (float)0
  BackupPositionFlt:
    dd (float)0
    dd (float)0
    dd (float)0

registersymbol(SavedPositionFlt BackupPositionFlt)
```

A two component game allocates two floats per buffer instead of three.

### 8.2 Dimensions

`Transform.Offsets` is the authority on how many components a position has, because it is the one
place the memory layout already had to be written down. A 2D game therefore configures nothing
extra:

```lua
teleporter = Teleporter:New({
    Transform = { Symbol = "TransformPtr", Offsets = { 0x30, 0x34 }, ValueType = vtSingle },
    Symbols   = { Saved = "SavedPositionFlt", Backup = "BackupPositionFlt" },
})
-- teleporter:AxisCount() == 2, teleporter:GetAxes() == { "X", "Y" }
```

Everything downstream follows: the editor grows two coordinate boxes instead of three and the panel
shrinks to fit, the save tree prints two columns, `Saved` and `Backup` get two offsets each, the
generated Auto Assembler script documents two coordinates, and a save file holds `X` and `Y` and no
`Z`.

`Axes` supplies the letters, not the count. It matters when the two components are not the first
two, which is the usual case for a top-down game:

```lua
teleporter.Axes = { "X", "Z" }   -- saves are keyed X and Z, the editor is captioned X and Z
```

Unnamed components fall back to `X`, `Y`, `Z`, `W` and then `A5`, `A6`. A blank or duplicate name is
replaced rather than trusted, because two components sharing a name would collapse into one key in
the save file.

> **The other symbols do not follow automatically.** `Waypoint` and `Additional` carry their own
> offsets, and shortening the `Transform` does not shorten them. That mismatch surfaces the first
> time somebody presses the waypoint button, a long way from the mistake. `ValidateConfiguration()`
> finds it immediately:
>
> ```lua
> teleporter:ValidateConfiguration()
> --> [Teleporter] Offsets do not match the axis count
> -->    Axes     : 2 (X, Y)
> -->    Waypoint : 3 offsets for 'WaypointPtr', expected 2
> ```
>
> A symbol with no name is skipped, which is how a table says it does not use that feature.

`Settings.YCoordinateIndex` stays an index into the position, so the lift-the-target adjustment
works in any number of dimensions. In a 2D platformer where the second component is height, it is
still `2`.

Existing 3D save files need no migration. A save has always stored one key per axis, and the
default axis names are the same three letters those files already use.

### 8.3 Core API

```lua
teleporter:SaveCurrentPosition()   -- Transform → Saved
teleporter:LoadSavedPosition()     -- Saved → Transform (+ Backup = previous position)
teleporter:LoadBackupPosition()    -- Backup → Transform
teleporter:TeleportToWaypoint()    -- Waypoint → Transform
teleporter:TeleportToCoordinates({ x, y, z })
teleporter:TeleportToSave("World / Region / Boss Arena")
teleporter:TeleportToSave("Boss Arena")   -- also fine while the name is unambiguous
```

Every jump runs the same chain: `PauseGame()` → `GetAdjustedTargetPosition()` →
`WritePositionToMemory(Transform)` → optionally `Additional` → `ResumeGame()` → write backup →
`_ReportJump()`.

`_ReportJump` is the whole jump in one entry:

```
[19:48:29] [INFO] [Teleporter] Loaded saved position
   From     : {1204.500, 88.000, -310.250}
   To       : {980.000, 64.000, 1120.750}
   Distance : 1467.318 Units
   Backup   : stored
```

The per-step lines (address resolution, each coordinate write, pause and resume) are behind
`teleporter.Settings.LogVerbose`, off by default. The reasoning is the same as
`Memory.LogSuccessfulOperations`: the log writes the file before it applies the level filter, so a
Debug line on a hot path is a real disk write. Turn it on to trace one jump, not to leave on.

### 8.4 Persistent saves

`teleporter.Saves` is a map of `category path + name → entry`:

```json
{
  "World / Region / Room / Boss Arena": {
    "X": 1024.5, "Y": 64.0, "Z": -320.25,
    "Author": "Leunsel",
    "Name": "Boss Arena",
    "Category": "World / Region / Room",
    "Categories": ["World", "Region", "Room"],
    "Description": "In front of the fog room"
  }
}
```

- The key is the full path, not the name alone (since 1.2.0). Identity therefore includes the
  category, so `"Old Town / Safe House / North West"` and `"Slums / Safe House / North West"` are
  two separate saves. `Name` carries the display name and is what the tree and the memory records
  show; `MakeSaveKey()` and `GetSaveKey()` build the key, `ResolveSaveKey()` reads one back.
- Files written before 1.2.0 used the name as the key and had no `Name` field. They are migrated on
  load: the old key becomes `Name`, the entry is rekeyed to `<path> / <name>`, and the file is
  rewritten once. Rename the entries afterwards to drop the redundancy their old names carry.
- `Categories` (array) is the authoritative form since 1.1.5. `Category` (string) is kept in sync
  for backward compatibility, and older files that only carry `Category` are normalized on load
  through `GetSaveCategoryPath()`.
- `/`, `\`, `>` and `|` are accepted as separators in `Category`, and output always uses `" / "`.
- `Area` (string, optional, since 1.6.0) says which of the game's maps a save is on, for the
  Teleporter Map. It is an attribute, never part of the key, so setting or clearing it rekeys
  nothing and every generated `TeleportToSave('<key>')` record keeps working. A save without one
  belongs to the area its top category names, provided that name is declared in
  `teleporter.Areas.Names` or used explicitly by another save; a top category that is not a
  declared area ("Bosses", "Default") derives nothing. `GetSaveArea(save)` answers with the area
  and whether it was derived, `SetSaveArea(key, area)` sets or clears the field, and
  `AssignDerivedAreas()` writes the derived areas into the file once, for a table that wants the
  file to say what the map shows.
- File: `%USERPROFILE%\AppData\Local\Manifold\Teleporter\Teleporter.<Target>.Saves.txt`.
  `SaveLookup()` tries that file first and falls back to the table file of the same name, which is
  handy for shipped tables with predefined jump targets.

`CreateTeleporterSaves()` turns the data into a tree of memory records underneath the record
`[— Teleporter : Saves —] ()->`:

```
[— Teleporter : Saves —] ()->
└─ [— Leunsel —] ()->                (author, vtGroupHeader)
    └─ [— World —] ()->              (category, nested)
        └─ [— Region —] ()->
            └─ Teleport To: 'Boss Arena' ()->   (vtAutoAssembler, {$lua})
```

### 8.5 Dedicated UI

```lua
teleporter:InitTeleporterUI()
```

Opens a standalone window (1120 × 720) with a menu strip, status bar, a tree view of saves
(grouped by author, then category) and an editor for name, author, category path, one box per
axis and description. Its controls are built through `Manifold.Forms`, so `ui:ApplyTheme(...)`
recolours them automatically (`UI:SetTeleporterControlColors`).

Since 1.6.0 the editor has an Area row. It is empty for a save whose area is derived from its
category, with the derived name as the box's hint, and filled for a save that carries the field.
The Saves menu offers Set Area Of Selected…, Assign Derived Areas and Rename Area…, and the tree's
context menu Set Area…. The Teleporter Map's context menu sets areas too.

Two conventions keep the builder and the theming in step without either one hard coding a list:

* **Every control registers itself into `UiState` under its own name.** A field row registers six
  entries: `<Key>Edit`, `Row`, `Label`, `Border`, `Fill` and `Inner`. So the name box is
  `UiState.NameEdit` and the first coordinate box is `UiState.XEdit`, whatever `X` happens to be
  called.
* **`UiState.IdentityFieldKeys`, `UiState.AxisFieldKeys` and `UiState.ButtonKeys` say what was
  actually built.** The theming walks those rather than a fixed set, which is what lets a 2D
  window have two coordinate rows and what let the Area row appear without a second edit in
  `Manifold.UI`. Each has a fallback for a Teleporter older than its list: `Name`, `Author`,
  `Category` for the identity rows, `X`, `Y`, `Z` for the coordinates.

Adding a toolbar button or a field row is therefore one entry in the spec table inside the
relevant `Create*` function, and nothing else anywhere.

### 8.6 Map

`Manifold.TeleporterMap` draws the saves on a canvas: a grid that rescales with the zoom, one
marker per save, the player's live position with a trail behind it, and a teleport on a single
click. It is a separate module because the Teleporter is already the size it is, and a table that
wants no map pays nothing for it.

```lua
CETrequire("Manifold.TeleporterMap")
teleporterMap = TeleporterMap:New({
    View   = { OneClickTeleport = true },
    Player = { RefreshInterval = 100, TrailBreakDistance = 25 },
})
teleporterMap:Show()
```

It requires `teleporter`, so it is constructed after it. In `Bootstrap.ORDER` it sits between
`teleporter` and `callbacks`. Once it exists the Teleporter window grows a **Map** button and a
**Tools → Open Map** entry, both of which open the map with the selected save focused, switching
to that save's area first. Nothing has to be wired for that; `Teleporter:GetMap()` looks the
instance up when the window is built.

**Which two axes are the map.** A position has as many components as `Transform.Offsets`, and a
map has two. For a 3D game the up axis is left out, and the Teleporter already names it: when
`Settings.AdjustYCoordinate` is on, `Settings.YCoordinateIndex` is the axis the lift applies to,
so that is the one the map does not draw. Off, the second component is assumed. A 2D game draws
both of its components. The rule can be overridden in the configuration or at runtime through
**View → Plane**, which lists every pair the table has:

```lua
teleporterMap.Plane = { Horizontal = 1, Vertical = 3 }   -- X across, Z up the screen
```

A growing vertical value moves **up** the screen, which is what a map reader expects. When the
game's north points the other way, **View → Flip Vertical** (or `Plane.FlipVertical = true`)
turns it around, and **Flip Horizontal** does the same across.

**Areas.** A game with several maps keeps its saves in one file, and their coordinate spaces
overlap, so a marker from Old Town drawn on the Slums is a lie. The window therefore shows one
area at a time: the dropdown in the toolbar, **View → Area** and PageUp/PageDown switch between
All Areas, each area with its count, and (No Area), which appears while any save has none or while
it is the view being shown. Which area a save is in is the Teleporter's answer, see 8.4; the map
never guesses from coordinates, because the spaces overlap by construction. Every area remembers
its own camera per plane, Fit All fits the area, the trail is dropped on a switch, a save made
with Add Save Here is stamped with the area being shown, and with every area drawn at once each
area names itself once, where its saves are. A save without an area is hidden in every single-area
view and lives behind the (No Area) entry, where it can be given one from the context menu's Set
Area submenu. There is no automatic detection of the player's area: that needs a level symbol per
game and engine, so the switch stays manual.

**Height.** The map is flat and a 3D game is not, so a marker carries the height of its save in
its size and its shade at once: the lowest save is the largest disc in the accent itself, the
highest the smallest and the most recessive, in up to four steps of one hue. Both come from one
mirrored number, so size and shade cannot disagree, and the legend in the corner shows the pair
between two rounded heights. "Height" is the component the plane leaves out: the up axis while the
plane does not draw it, otherwise the one remaining component, so switching to the X / Y plane
makes Z the height rather than duplicating what the vertical position already shows.

The ramp is built from the theme's own accent, in OKLab, so it is one hue with lightness steps
that are steps to the eye and not only to the arithmetic. A palette whose accent cannot be held
apart from its surface gets no ramp rather than an unreadable one, and then every marker is the
plain accent at the base radius and there is no legend. **View → Scale Markers By Height** governs
size, shade and the legend together; a 2D table has no height and draws every marker the same.

**Crowds.** Saves sit on top of each other, and a pile of fifteen used to be one blob. Four things
separate them. Every disc is drawn on a ring of the canvas colour, so a marker in front carves its
own gap out of the ones behind it. Discs are painted large to small, which is lowest to highest, so
a small high save is never swallowed by a large low one. A disc is never drawn wider than the room
a save has at this zoom. And a pile the eye still cannot separate carries the number of saves in
it, drawn beside the pile and never over it. Every one of them is still one click away: the badge
has no hit behaviour and nothing about the hit test changed. `Z` zooms into the pile under the
pointer, which is the only thing that really separates it.

**The pointer.** Hovering answers with a card: which save it is on, where that save is, which area
it belongs to, what a click will do, and the names of the other saves under the same pointer. In a
pile that card is the only place those names exist.

**Labels.** A label tries eight places around its disc and takes the first that is clear of the
other marks, the readouts, the labels already placed and the edge of the map. One that fits nowhere
is dropped rather than clipped or painted over a mark, and the map card says how many of the names
a frame managed to place. The selection is placed first, so the save being asked about always gets
its name, and it carries its coordinates on a second row. The save under the pointer gets no label
at all, because the card beside it is already showing the name and the numbers, and the room that
frees goes to its neighbours.

**The window.** A toolbar (Fit All, Player, Follow, zoom, Teleport, an area dropdown and a filter
box), the map card, a details card for the selected save with a Teleport, Editor and Center
button, and a status bar whose right half shows the world coordinates under the cursor, the zoom
and the player's position. The details card can be hidden through **View → Details Panel**.

| Input | Effect |
|---|---|
| Click a marker | Selects it, and teleports when **One-Click Teleport** is on (the default) |
| Double click a marker | Teleports when One-Click Teleport is off |
| Ctrl + click on empty map | Teleports to that point. The height snaps to the nearest shown save within `View.HeightSnapRadius`, and is the player's own when none is in reach. |
| Ctrl + Shift + click | Teleports to the point keeping the player's own height, ignoring the height snap |
| Any teleport from the map | Asks first while **Teleport → Confirm Before Teleport** is on (the default) |
| Drag | Pans. Panning switches Follow off. |
| Wheel | Zooms around the cursor |
| Right click | Teleport To *save*, Teleport Here, Add Save Here…, Rename Save…, Duplicate Save, Delete Save, Set To Player Position, Set Height To Player, Set Area ▸, Copy Coordinates, Center Here, Fit All, Open Selected In Editor |
| `+` / `-` | Zoom in and out |
| Wheel notch | A quarter of the scale, arriving over `View.ZoomAnimationMs` (120 ms) of real time rather than of frames, so a slow frame drops steps instead of stretching the glide. `0` applies it at once. Following the player does not interrupt a notch, but panning, dragging and centring do. |
| `Home` / `Shift+Home` | Fit the saves that sit together / fit every save |
| `Z` | Zoom into the pile under the pointer |
| `End` | Centre on the player |
| `Space` | Follow the player |
| `Enter` | Teleport to the selected save |
| Arrow keys | Pan |
| `G`, `L`, `T` | Grid, labels, trail |
| `PageUp` / `PageDown` | Previous / next area |
| `,` / `.` | Narrow / widen the height band |
| `Delete` / `F2` | Delete / rename the selected save, through the Teleporter's own question or prompt |
| `Ctrl+F`, `Escape` | Focus the filter box; Escape clears the filter while it has focus, otherwise the selection |

The filter box dims every save whose key, name, category, author or description does not contain
the text, and a dimmed save is drawn hollow and cannot be clicked, so a filter makes a crowded area
clickable as well as readable.

**Teleport Here** and **Add Save Here…** need a full position, and the map plane only supplies two
components. The height comes from the nearest shown save within `View.HeightSnapRadius` world units
of the point (25 by default), because a save is a height somebody stood at, and a click from a
rooftop onto a street point would otherwise drop the player from the roof. The question and the
status bar name the save the height came from. With no save in reach, or with Ctrl+Shift+click, the
player's own height is kept. Either way the Teleporter then lifts the target by its own adjustment
as it does for every jump. `View.HeightSnapRadius = 0` switches the snap off.

**Height band.** For a game whose floors share one level, the band is what areas are for a game
with several: **View → Height Band** (Off, ±2, ±5, ±10, ±25, ±50 units; `,` and `.` step through
them) dims every save further than that from the player's height, and a dimmed save cannot be
clicked, exactly like a filter miss. The band follows the player, re-applied once they have moved a
quarter of it up or down, and is remembered with the view. A table with no height axis is told it
has no band to apply.

**Editing from the map.** The context menu on a marker offers Rename Save…, Duplicate Save, Delete
Save, Set To Player Position, Set Height To Player, Set Area ▸ and Copy Coordinates (comma
separated, in axis order). Rename and Delete go through the Teleporter's own prompt and question,
the two moves ask first every time, and the map is told through the save listeners, so the marker
follows. `Delete` and `F2` do the same for the selected save.

**Fitting.** One far-away save used to squeeze every other one into a corner. **Fit All** fits the
saves that sit together and says in the status bar how many far ones it left out. **Fit Every Save**
(Shift+Home) fits those as well. Two rules keep it from throwing the map away instead of an outlier.
An axis where the middle half of the saves share one value has no spread to measure, so that axis
decides nothing and the choice falls to the axis that does spread. And a fit that would leave out
more than a fifth of the saves is measuring the shape of the level rather than an outlier, so it
fits everything instead. What it did leave out is said even when an area switch or the window
opening writes its own status line.

**The player.** The window's timer reads the position every `Player.RefreshInterval` milliseconds
through `Teleporter:PeekCurrentPosition()`, which resolves the pointer without logging.
`GetCurrentPosition` reports an unresolvable pointer as a warning, and every warning is a file
write; a game in its menu has no valid pointer for seconds at a time, and ten reads a second of
that would fill the log with one line. After `Player.FailureBackoff` failed reads in a row the poll
slows to one read per ten ticks and the last known position is painted faint, until a read succeeds
again. The player is drawn as a crosshair with its own word beside it rather than a coloured dot,
because `COLOR_SUCCESS` is the same green as the accent on a theme like Dark-Hacker and shape is
the one difference a theme cannot take away. A move shorter than `Player.TrailMinDistance` adds no
trail point, a jump longer than `Player.TrailBreakDistance` starts a new segment rather than drawing
a line across the map, and a teleport from the map breaks the trail itself. `Player.TrailLength`
caps the points kept.

**Following the saves.** The Teleporter tells its save listeners after every add, update, rename,
duplicate and delete, and after a load, so the map rebuilds its markers the moment a save changes
and never polls for it. `Teleporter:AddSaveListener(fn)` is open to any other view of the saves.

**Theme.** The window is built through `Manifold.Forms`, so `ui:ApplyTheme(...)` recolours its
controls through their roles. The canvas takes its colours from the same design palette: the
background is `COLOR_INPUT`, the grid, the axes and the rulers are `COLOR_MUTED` mixed into the
surface, markers are the accent and its ramp, the selection ring and hover are `COLOR_TEXT`, the
player is `COLOR_SUCCESS`. The grid deliberately does not use `COLOR_BORDER`: in every bundled
theme that token is the accent, so the scenery used to compete with the data. `ApplyTheme` calls
`teleporterMap:OnThemeApplied()` after the Forms pass, which repaints from the new palette.

**Remembered view.** Zoom, centre, plane, flips, the toggles, the shown area with one camera per
area and plane, and the height band are written to
`%LOCALAPPDATA%\Manifold\Teleporter\Teleporter.<Target>.Map.txt` a second after the camera comes
to rest and again when the window closes, and read back the next time it opens. A file written
before cameras were kept per plane keeps them: a camera with no plane is read as the plane the file
was framed on. `Settings.PersistView = false` switches the whole thing off. Without a remembered
view the first open fits the saves that sit together.

## 9. Forms, themeable controls

`Manifold.Forms` is the control factory behind the teleporter UI and the theme creator. Every
control it creates is entered into a registry and carries a role. On a theme change,
`Forms:ApplyTheme()` walks the registry and colours by role.

```lua
local form  = forms:CreateForm({ caption = "Demo", width = 400, height = 260, role = "form" })
local root  = forms:CreatePanel(form, { align = alClient, role = "background" })
local edit  = forms:CreateFieldRow(root, { caption = "Name:", textHint = "…" })
local btn   = forms:CreateButton(root, { caption = "OK", onClick = function() print("ok") end })
```

A window that closes with `caFree` must leave the registry before it does. Its controls are freed
with it, and the next `ApplyTheme` would otherwise read `Visible` on a form that no longer exists
and colour controls that have been destroyed, which is a use after free and an access violation
whenever the memory has been reused. The Teleporter and the map therefore call
`forms:UnregisterRoot(form)` from their `OnClose` before returning `caFree`; a window that only
hides itself, like the theme creator, keeps its entries.

**Menu bars.** A menu made with `createMainMenu` is a plain LCL menu. Cheat Engine's own menus are
its dark mode subclass, which gives the menu and every submenu a dark background the first time a
window shows, and a Lua menu never gets that step. Its dropdowns then have dark entries inside a
light frame, with a light icon column and light separators. `forms:ThemeMenuBar(form)` performs the
same step through the same Windows calls. Call it once the menu is complete, and again after filling
a submenu that did not exist yet, because the background only reaches the submenus that are there
when it is set. It does nothing outside dark mode. The Teleporter and the map call it for their menu
bars.

Available roles and their colour mapping:

| Role | Background | Font |
|---|---|---|
| `form`, `root`, `background`, `body` | `COLOR_BG` | `COLOR_TEXT` |
| `panel`, `toolbar`, `footer` | `COLOR_PANEL` | `COLOR_TEXT` |
| `surface` / `surfaceAlt` | `COLOR_SURFACE` / `COLOR_SURFACE_ALT` | `COLOR_TEXT` |
| `border`, `cardBorder`, `fieldBorder` | `COLOR_BORDER` | - |
| `header` | `COLOR_BTN` | - |
| `inputPanel`, `fieldFill`, `fieldInner`, `memoPanel`, `memoInner` | `COLOR_INPUT` | - |
| `input`, `textbox`, `memo` | `COLOR_INPUT` | `COLOR_INPUT_TEXT` |
| `tree`, `treeview`, `listview` | `COLOR_INPUT` | `COLOR_INPUT_TEXT` |
| `button` | `COLOR_BTN` (hover: `COLOR_BTN_HOVER`) | `COLOR_BTN_TEXT` |
| `label` / `headerLabel` / `mutedLabel` | - | `COLOR_LABEL` / bold / `COLOR_MUTED` |
| `preview`, `swatch` | `opts.color` | - |

`Forms:ResolveTheme(theme)` translates a Manifold token theme into this 17-colour palette. If a
palette is passed instead of a token theme (detected via `COLOR_BG`), it is copied unchanged.

Buttons are not `TButton` but panels with a centred label, which is what makes them freely
colourable, because `TButton` ignores `Color` on Windows. Hover effects go through
`OnMouseEnter`/`OnMouseLeave` → `Forms:SetButtonState`.

With `opts.lockColor = true` a control is left untouched by theme changes, for example the colour
preview swatches in the theme creator.

## 10. Callbacks, locking edits

```lua
CETrequire("Manifold.Callbacks")
callbacks = Callbacks:New()      -- singleton

callbacks:SetDisableDescriptionChange(true)
callbacks:SetDisableAddressChange(true)
callbacks:SetDisableTypeChange(true)
callbacks:SetDisableValueChange(true)
callbacks:SetDisableAutoAssemblerEdits(true)
```

For each of the five options, `Get…`, `Set…` and `Toggle…` are generated at load time.
`ResetConfig()` restores the defaults, which are all `false`.

The module also installs, at load time:

- `onMemRecPreExecute` and `onMemRecPostExecute`, which write a debug log and a warning when
  execution fails.
- `AddressList.OnAutoAssemblerEdit`, which chains the previous handler instead of replacing it.
- `getLuaEngine().OnShow`, which calls the original handler and then applies the active theme
  twice to the Lua engine. The second pass is commented as necessary because CE resets some
  properties when showing the window.

For a release table this is the usual guard against accidental edits. It is not copy protection,
because the callbacks can be switched off from the Lua engine in one line.

## 11. Memory access

`Manifold.Memory` generates three functions for each of six types:

```
SafeRead<Type>(address [, signed])
SafeWrite<Type>(address, value)
SafeAdd<Type>(address, value [, signed])
```

with `<Type>` ∈ `Byte`, `Word`, `Integer`, `QWord`, `Float`, `Double`.
`signed` is only honoured by `Word` and `Integer`.

```lua
local hp = memory:SafeReadFloat("PlayerBase")     -- symbol or number
memory:SafeWriteInteger(0x7FF6A0001234, 9999)
memory:SafeAddInteger("Ammo", 50)
```

Addresses always pass through `memory:SafeGetAddress(addressOrSymbol [, isLocal])`:

- number → unchanged (negative values are rejected)
- string → `getAddressSafe(symbol, isLocal)`
- anything else → `nil` plus an error log entry

Pointer chains are resolved by `memory:ResolvePointerPath`, which moved here from
`Manifold.Utils` in Memory 1.1.0:

```lua
local addr = memory:ResolvePointerPath("Game.exe+1A2B3C4", { 0x10, 0x28, 0x8 })
local addr = memory:ResolvePointerPath("SomePointerSymbol", { 0x10, 0x28, 0x8 })
```

A null pointer mid-chain is a failure rather than an address. The old version computed
`0 + offset` and carried on, so an object the game had not allocated yet produced a
plausible-looking low address that a caller could then write to. On failure the walk it managed
is logged as one line, so "which hop broke" is answerable without a bisect. On success it logs
nothing and returns a single value. `utils:ResolvePointerPath` still exists, forwards here and is
deprecated for removal in 2.0.0.

Successful reads, writes and adds no longer log at all by default. They are `Debug` lines gated
behind `Memory.LogSuccessfulOperations`, which defaults to `false`, because
`Manifold.Logger` writes the log file before it applies the level filter and a value polled every
frame produced one open, write and close per frame regardless of the configured level. Failures
stay at `Error`. See [TODO T11](TODO.md#t11-every-memory-access-emits-an-info-log-line).

## 12. Logging

```lua
logger:SetLevel(logger.Levels.INFO)      -- DEBUG=1 INFO=2 WARNING=3 ERROR=4 CRITICAL=5
logger:SetLogFileName("MyGame")          -- → Manifold.Runtime.MyGame.log
logger:SetOutput(print)                  -- any output function
```

`Logger:New()` starts at `Levels.ERROR`, so raising the level is part of a normal setup.

Each level comes in four variants:

| Form | Example | Behaviour |
|---|---|---|
| `<Level>` | `logger:Info(msg)` | Honours `Level` |
| `<Level>F` | `logger:InfoF("%d hits", n)` | `string.format` |
| `Force<Level>` | `logger:ForceInfo(msg)` | Ignores `Level`, tagged `[FORCED]` |
| `Force<Level>F` | `logger:ForceWarningF("%s", x)` | Both combined |

`logger:Stringify(value)` also serializes nested tables (with `{...}` cycle protection), which is
why tables can be logged directly:

```lua
logger:Info({ hp = 100, pos = { 1, 2, 3 } })
--> { hp = 100, pos = { 1 = 1, 2 = 2, 3 = 3 } }
```

### 12.1 Blocks, and why they are not optional

There is a fifth variant, `<Level>Block`, and inside the framework it is the default for anything
that reports more than one fact:

```lua
logger:InfoBlock(MODULE_PREFIX .. " Themes loaded", {
    { "Table files", 8 },
    { "Data folder", 2 },
    { "Available",   10 },
    failed > 0 and { "Failed", failed } or false,
})
```

```
[19:48:29] [INFO] [UI] Themes loaded
   Table files : 8
   Data folder : 2
   Available   : 10
```

Rows are `{ label, value }` or a plain string. `false` skips a row, a bare `nil` cuts the block
short because the walk is an `ipairs`. `logger:BuildBlock` renders without logging.

This is not only about how it reads. `Logger:_DispatchLog` writes the file **before** it applies the
level filter, deliberately, so that a user's bug report contains everything. The consequence is that
every emitted line is a disk write whatever its level, so N lines is N writes and one block is one.

### 12.2 Conventions

Every module in the framework follows the same five rules.

1. **Every line starts with `MODULE_PREFIX`, concatenated.** `logger:Info(MODULE_PREFIX .. " ...")`
   and `logger:InfoF(MODULE_PREFIX .. " %s", x)`. Not `logger:InfoF("%s ...", MODULE_PREFIX, x)`,
   which used to appear in five modules and shifts every argument position by one.
2. **More than one fact is one block.** A report split over several lines repeats the timestamp and
   the prefix on each, which is most of the line width, and costs a write per line.
3. **A loop reports once, after it.** Collect the interesting items and emit one block naming them.
   One warning per bad token or per skipped file buries whatever else happened.
4. **A failure names its subject and its reason**, as a two row block when either is long:
   `{ "File", path }, { "Reason", err }`. A caller that already reports a failure is not reported
   again by its callee.
5. **Levels mean something.**

   | Level | For |
   |---|---|
   | `Info` | A completed operation and its result. What a user reading their own log wants. |
   | `Debug` | Internal steps and successful housekeeping, for example a created directory. |
   | `Warning` | Something the table has worked around and the user may want to fix. |
   | `Error` | An operation that did not happen. |

   Announcing an operation before doing it is not a level, it is a line to delete. `Loading theme
   X` followed by `Theme X loaded` is one entry's worth of information written twice.

A hot path that genuinely wants per-step detail gets an explicit switch rather than a level:
`Memory.LogSuccessfulOperations` and `Teleporter.Settings.LogVerbose`, both `false` by default.

## 13. Utils

### Window title

```lua
utils:SetTitle()
```

produces

```
<TargetStr> <RegistrySize> V:<GameVersion> — CET V:<Version> — CE <(x64)> V:<CEVersion>
```

from `utils:GetTitleComponents()`. `GameVersion` is `utils.AppVersion` when it is a non-empty
string, otherwise `helper:GetFileVersionStr()`, otherwise the literal `"GameVersion"`. `helper` is
a runtime dependency, so it is reached for through a type check rather than assumed.

### Dialogs

```lua
utils:ShowInfo("…")
utils:ShowWarning("…")
utils:ShowError("…")
if utils:ShowConfirmation("Are you sure?") then … end
```

All four synchronize into the main thread on their own.

### Integrity check

```lua
utils = Utils:New({ VerifyMD5 = true, MD5Hash = "d41d8cd98f00b204e9800998ecf8427e" })
```

`VerifyFileHash()` runs after every successful attach and warns on a mismatch. It does not block,
so the table keeps running.

### CE version check

```lua
utils:EnsureCompatibleCEVersion(7.5, false)   -- true = close CE on mismatch
```

### Custom value types

| Call | Type name | Bytes | Description |
|---|---|---|---|
| `utils:RegisterTimeTypes()` | `Military Hours` | 4 | Float × 24 × 100 → military time (Dying Light) |
| `utils:RegisterDecryptionType()` | `Decrypted` | 16 | `encrypted / multiplier` from two QWords (Monster Hunter Wilds) |
| `utils:RegisterPlaytimeMilitaryType()` | `Playtime Float` | 8 | Ticks → `H.MMSS` (Mewgenics) |

All three check `getCustomType(name)` and register only once.

### Async switching

```lua
utils:SetAllScriptsToAsync()      -- all vtAutoAssembler records to async
utils:SetAllScriptsToNotAsync()
utils:AutoDisable(memrec.ID, 100) -- deactivate the record again after 100 ms
```

`AutoDisable` is the standard pattern for "action" records. A script activates, does something,
and switches itself back off so the checkbox does not stay ticked. Both of its async waits are
bounded by `Utils.AutoDisableWaitTimeout`, which defaults to 5000 ms.

## 14. Reference

The complete function list per module lives in
[Manifold-Framework-API.md](Manifold-Framework-API.md).
