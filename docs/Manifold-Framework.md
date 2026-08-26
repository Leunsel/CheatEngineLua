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
15  callbacks          logger required, ui runtime
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
2. `forms` before `ui` and `teleporter`. Both declare `forms` as required and refuse to construct
   without it.
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
│   └── Teleporter.<Process>.Saves.txt → teleporter saves (JSON)
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
| Manifold.Bootstrap | 1.0.0 | Dependency lookup, module registry, order of execution, collision detection |

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
| Manifold.ProcessHandler | 1.2.8 | Auto-attach, process monitoring, cleanup and re-attach |

### Runtime

| Module | Version | Purpose |
|---|---|---|
| Manifold.Memory | 1.1.0 | Type-safe read/write/add wrappers, symbol resolution, pointer paths |
| Manifold.State | 1.0.6 | Saving and restoring activation states and hotkeys |
| Manifold.AutoAssembler | 2.0.7 | Process-aware AA toggling with transactions and rollback |
| Manifold.Callbacks | 1.0.6 | Overrides CE callbacks, locks edits |

### AA language extension

| Module | Version | Purpose |
|---|---|---|
| Manifold.AssemblerCommands | 1.2.7 | Registers 10 custom Auto Assembler commands |
| Manifold.Trampolines | 1.1.0 | 5-byte detours through a relay slot in the PE header |

### Presentation

| Module | Version | Purpose |
|---|---|---|
| Manifold.Forms | 1.0.2 | Role-based, themeable VCL control factory with a registry |
| Manifold.UI | 1.0.6 | Theme system, CE window tweaks, theme creator |

### Feature

| Module | Version | Purpose |
|---|---|---|
| Manifold.Teleporter | 1.1.6 | Save/load 3D positions, own UI, CE record generation |

### Developer modules (`Manifold.Dev/`)

Not part of a normal table setup. They are loaded manually during development.

> `Manifold.Dev/` is listed in `.gitignore`, so these files are not published to GitHub. The
> descriptions below document the local working copy.

| Module | Version | Purpose |
|---|---|---|
| Manifold.AssemblerLinter | 1.0.0 | Five-phase AA script linter (lex → shape → directives → symbols → gate) |
| Manifold.Patcher | 1.1.0 | Snapshot, fingerprint and remote-patch system. Discontinued, see TODO T3 |
| Manifold.RTTI | - | MSVC RTTI scanner: classes, COLs, vtables, instances |
| Manifold.Json (working copy) | 1.0.1 | Development copy of the shipped module |
| Manifold.Json.Old | 20161109.21 | The vendored Jeffrey Friedl implementation the rewrite replaced, CC-BY |

### Tests (`Manifold.Testing/`)

`Manifold.UnitTest.lua` is a standalone runner executed from the CE Lua console. Per module it
checks loadability, metadata (`GetModuleInfo`), the export contract, and an optional behavior
scenario. `Manifold.UnitTest.Output.txt` contains a recorded run.

## 5. Central flows

### 5.1 Process lifecycle

```
processHandler:AutoAttach("Game.exe")
   │  timer every 1000 ms (AutoAttachTimerInterval)
   │  optional timeout via options.maxSecs
   ▼
getProcessIDFromProcessName → openProcess
   ▼
OnProcessAttached(name, pid, options)
   ├─ PerformPostAttachTasks()
   │    ├─ utils:InitializeTable()   → ui:InitializeForm() + utils:SetTitle()
   │    └─ utils:VerifyFileHash()    (only when utils.VerifyMD5)
   ├─ options.onAttached(self, name, pid)     (optional callback)
   └─ StartProcessWatchTimer(name)
        ├─ TTimer, 1000 ms → CheckWatchedProcess()
        └─ StartProcessWatchFallback()  ← createThread fallback for cases where
                                          CE does not dispatch timer events
```

When the process disappears:

```
HandleProcessUnavailable(reason)
 └─ CleanupAndReattach(reason, timer)
     ├─ StopAutoAttachTimer() / StopProcessWatchTimer()
     ├─ DisableAllWithoutExecute()   → AddressList.disableAllWithoutExecute()
     │                                 + deleteAllRegisteredSymbols()
     ├─ ResetProcessBoundState()     → autoAssembler:Reset()
     │                                 assemblerCommands.ActivePatches = {}
     │                                 trampolines:Reset()
     └─ AutoAttach(processName)      → the cycle restarts
```

The fallback thread matters. It periodically compares the PID against the process name and
therefore also catches a game restart under the same name, which a plain `readInteger(process)`
probe would miss.

`ProcessWatchGeneration` is a counter incremented on every stop. The fallback thread terminates
itself as soon as the generation no longer matches its own, so a re-attach leaves no orphaned
threads behind.

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
  ├─ ApplyThemeToMainForm
  ├─ ApplyThemeToAddressRecords   colour per record type (GetRecordColor)
  ├─ ApplyThemeToLuaEngine        controls + execute panel (twice, deliberately)
  ├─ ApplyThemeToForms            every control registered through Manifold.Forms
  ├─ ApplyThemeToTeleporter       if the teleporter is loaded
  └─ ReleaseThemeApplyLock()
```

`ApplyTheme` synchronizes itself into the main thread when it is called from anywhere else. The
lock deliberately lives in `_G` rather than on the instance. If the table Lua script is executed
again and a new `UI` instance is created, the lock still applies.

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

The teleporter reads and writes three floating-point values through registered AA symbols.

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
})
```

| Section | Meaning |
|---|---|
| `Transform` | Current player position. Read as a pointer (`[Symbol]+0` plus offsets). |
| `Waypoint` | Optional waypoint position, also a pointer. |
| `Additional` | Optional second write target (some games require a second set of coordinates to allow for proper teleports). Only used when `Symbol` is set. |
| `Symbols.Saved` / `.Backup` | Two allocated buffers for "last save" and "position before the last jump". Read and written directly, not as pointers. |

Offsets for `Saved`/`Backup` are computed by `CalculateSymbolOffsets()` from `Settings.ValueType`
(`vtSingle` → `{0, 4, 8}`).

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

### 8.2 Core API

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
`WritePositionToMemory(Transform)` → optionally `Additional` → `ResumeGame()` →
`LogDistanceTraveled()` → write backup.

### 8.3 Persistent saves

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

### 8.4 Dedicated UI

```lua
teleporter:InitTeleporterUI()
```

Opens a standalone window (1120 × 720) with a menu strip, status bar, a tree view of saves
(grouped by author, then category) and an editor for name, author, category path, X/Y/Z and
description. Its controls are built through `Manifold.Forms`, so `ui:ApplyTheme(...)` recolours
them automatically (`UI:SetTeleporterControlColors`).

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
