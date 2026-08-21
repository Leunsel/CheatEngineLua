# Manifold Framework

> Directory: [`Manifold-Modules/`](../Manifold-Modules/)
> License: MIT · Authors: Leunsel, LeFiXER
> Complete function list: **[Manifold-Framework-API.md](Manifold-Framework-API.md)**

Manifold is a modular Lua library that runs **inside a Cheat Table**. It handles process
attachment, memory access, Auto Assembler management, state persistence, UI theming, and optional
features such as the teleporter.

---

## 1. Core concepts

### 1.1 Module pattern

Every module follows the same shape:

```lua
local NAME        = "Manifold.Xyz.lua"
local AUTHOR      = {"Leunsel", "LeFiXER"}
local VERSION     = "1.0.0"
local DESCRIPTION = "Manifold Framework Xyz"

Xyz = {}                 -- GLOBAL class table
Xyz.__index = Xyz

function Xyz:New(config) -- constructor
    local instance = setmetatable({}, self)
    self:CheckDependencies()          -- optional
    instance.Name = NAME
    for k, v in pairs(config or {}) do
        if self[k] ~= nil then instance[k] = v
        else logger:WarningF("Invalid property: '%s'", k) end
    end
    return instance
end

function Xyz:GetModuleInfo()   ... end
function Xyz:PrintModuleInfo() ... end

registerLuaFunctionHighlight('...')   -- CE syntax highlighting

return Xyz
```

Consequences worth knowing:

- **Class names are global** (`Logger`, `CustomIO`, `UI`, …). There is no namespace encapsulation.
- **Instances are global too**, lowercase by convention (`logger`, `customIO`, `ui`, …). Modules
  reference these globals **directly** rather than through injected references. The names are
  therefore part of the contract and cannot be chosen freely.
- `New(config)` drops unknown keys (`if self[key] ~= nil`). A typo in a config key is only logged
  as a warning, never raised as an error.

### 1.2 Canonical instance names

| Global | Class | Module |
|---|---|---|
| `json` | `JSON` | `Manifold.Json` |
| `logger` | `Logger` | `Manifold.Logger` |
| `customIO` | `CustomIO` | `Manifold.CustomIO` |
| `helper` | `Helper` | `Manifold.Helper` |
| `utils` | `Utils` | `Manifold.Utils` |
| `processHandler` | `ProcessHandler` | `Manifold.ProcessHandler` |
| `memory` | `Memory` | `Manifold.Memory` |
| `state` | `State` | `Manifold.State` |
| `autoAssembler` | `AutoAssembler` | `Manifold.AutoAssembler` |
| `callbacks` | `Callbacks` | `Manifold.Callbacks` |
| `forms` | `Forms` | `Manifold.Forms` |
| `ui` | `UI` | `Manifold.UI` |
| `teleporter` | `Teleporter` | `Manifold.Teleporter` |
| `trampolines` | `Trampolines` | `Manifold.Trampolines` |
| `assemblerCommands` | `AssemblerCommands` | `Manifold.AssemblerCommands` |

> `JSON` uses `JSON:new()` (lowercase `n`), unlike every other module's `:New()`.

### 1.3 Automatic dependency resolution

Most modules implement `CheckDependencies()`. When a required global is missing, the module is
loaded through `CETrequire` and initialized:

```lua
local dependencies = {
    { name = "logger",   path = "Manifold.Logger",   init = function() logger = Logger:New() end },
    { name = "customIO", path = "Manifold.CustomIO", init = function() customIO = CustomIO:New() end },
}
```

Dependency graph (arrow = "requires"):

```
Json ◄── CustomIO ◄── Logger(file output)
             ▲  ▲
             │  └──── State ──► ProcessHandler ──► Utils ──► UI ──► Forms
             │                                                └──► Teleporter ──► Memory
             └──── AutoAssembler ──► ProcessHandler
                          └────────► Trampolines ◄── AssemblerCommands
```

`Manifold.Memory`, `Manifold.Helper`, `Manifold.Callbacks` and `Manifold.Forms` have no
resolution of their own - they expect `logger` to exist already.

---

## 2. Bootstrapping a Cheat Table

### 2.1 The `CETrequire` loader

Manifold modules are not loaded with `require` but through a helper that searches the file system
first and the **table files** embedded in the `.CT` second. This function belongs in the Cheat
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

The dual path is the central idea: during development the modules sit as files next to the `.CT`
(fast editing, no re-import), in a release they are embedded as table files (one distributable
file).

> `CETrequire` returns `nil` silently for a missing module instead of raising. A typo in a module
> name therefore only surfaces later as "attempt to index a nil value".

### 2.2 Minimal setup

```lua
-- 1) Base
CETrequire("Manifold.Json")
json = JSON:new()

CETrequire("Manifold.Logger")
logger = Logger:New()
logger:SetLevel(logger.Levels.INFO)

CETrequire("Manifold.CustomIO")
customIO = CustomIO:New()

CETrequire("Manifold.Helper")
helper = Helper:New()

-- 2) Lifecycle
CETrequire("Manifold.Utils")
utils = Utils:New({
    Author     = "YourName",
    Target     = "Game.exe",
    TargetStr  = "Game Title",
    Version    = "1.0.0",
    VerifyMD5  = false,
    IsRelease  = false,
})

CETrequire("Manifold.ProcessHandler")
processHandler = ProcessHandler:New({ ProcessName = "Game.exe" })

-- 3) Presentation
CETrequire("Manifold.Forms")
forms = Forms:New()

CETrequire("Manifold.UI")
ui = UI:New({
    Theme        = "Manifold.Dark-Aqua.Min",
    SloganStr    = "MANIFOLD",
    SignatureStr = "by YourName",
})

-- 4) Runtime
CETrequire("Manifold.Memory");        memory        = Memory:New()
CETrequire("Manifold.State");         state         = State:New()
CETrequire("Manifold.AutoAssembler"); autoAssembler = AutoAssembler:GetInstance()
autoAssembler:SetProcessName("Game.exe")

-- 5) AA language extension
CETrequire("Manifold.Trampolines");       trampolines       = Trampolines:New()
CETrequire("Manifold.AssemblerCommands"); assemblerCommands = AssemblerCommands:New()
assemblerCommands:RegisterCoreCommands()

-- 6) Go
processHandler:AutoAttach("Game.exe")
```

`AutoAttach` starts a timer that waits for the process. Once found, the handler opens it, runs
`PerformPostAttachTasks()` (which in turn calls `utils:InitializeTable()` → `ui:InitializeForm()`
+ `utils:SetTitle()` and optionally verifies the MD5 hash) and starts process monitoring.

### 2.3 Ordering pitfalls

1. **`logger` first.** Practically every module logs inside `New()` already.
   `State:CheckDependencies()` even calls `logger:Warning(...)` *before* it loads the logger -
   without an existing `logger` that raises (see [TODO T4](TODO.md#t4-statecheckdependencies-uses-the-logger-before-it-exists)).
2. **`forms` before `ui` and `teleporter`.** As of UI 1.0.5 / Teleporter 1.1.4 both modules
   require `Manifold.Forms` and abort with `error()` if it is missing.
3. **`Manifold.Callbacks` registers at load time.** On `dofile` it immediately overwrites
   `AddressList.OnDescriptionChange`, `OnAddressChange`, `OnTypeChange`, `OnValueChange`,
   `OnAutoAssemblerEdit` and `getLuaEngine().OnShow`. Load it after `ui` so the `OnShow` hook can
   apply the theme.
4. **`assemblerCommands:RegisterCoreCommands()` before the first AA script** that uses
   `ManifoldScanModule` and friends.

---

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

There is **no** setter API for the location. It can only be changed on the field directly, and it
has to be done in **both** places:

```lua
customIO.DataDir = "D:\\Manifold"
logger.DataDir   = "D:\\Manifold"   -- the logger keeps its own copy!
```

> The segment's `README.md` mentions `Manifold.CustomIO.GetDataDir()`. That function does not
> exist in the code - use `customIO.DataDir`.

---

## 4. Module overview

### Core modules

| Module | Version | Purpose |
|---|---|---|
| **Manifold.Json** | 20161109.21 | JSON encoder/decoder (Jeffrey Friedl, CC-BY) |
| **Manifold.Logger** | 1.0.2 | Five-level logging with file and console output |
| **Manifold.CustomIO** | 1.0.3 | File, JSON, CSV and table-file I/O, directory management |
| **Manifold.Helper** | 1.0.2 | Process and module queries (name, bitness, path, base) |

### Lifecycle

| Module | Version | Purpose |
|---|---|---|
| **Manifold.Utils** | 1.0.3 * | Window title, dialogs, hash check, custom types, pointer paths |
| **Manifold.ProcessHandler** | 1.2.7 | Auto-attach, process monitoring, cleanup and re-attach |

\* The changelog header already says `v1.0.5` while the `VERSION` constant reads `1.0.3`.

### Runtime

| Module | Version | Purpose |
|---|---|---|
| **Manifold.Memory** | 1.0.5 | Type-safe read/write/add wrappers with symbol resolution |
| **Manifold.State** | 1.0.5 | Saving and restoring activation states and hotkeys |
| **Manifold.AutoAssembler** | 2.0.6 | Process-aware AA toggling with transactions and rollback |
| **Manifold.Callbacks** | 1.0.5 | Overrides CE callbacks, locks edits |

### AA language extension

| Module | Version | Purpose |
|---|---|---|
| **Manifold.AssemblerCommands** | 1.2.5 | Registers 10 custom Auto Assembler commands |
| **Manifold.Trampolines** | 1.0.1 | 5-byte detours through a relay slot in the PE header |

### Presentation

| Module | Version | Purpose |
|---|---|---|
| **Manifold.Forms** | 1.0.1 | Role-based, themeable VCL control factory with a registry |
| **Manifold.UI** | 1.0.5 | Theme system, CE window tweaks, theme creator |

### Feature

| Module | Version | Purpose |
|---|---|---|
| **Manifold.Teleporter** | 1.1.5 | Save/load 3D positions, own UI, CE record generation |

### Developer modules (`Manifold.Dev/`)

Not part of a normal table setup. They are loaded manually during development.

| Module | Version | Purpose |
|---|---|---|
| **Manifold.AssemblerLinter** | 1.0.0 | Five-phase AA script linter (lex → shape → directives → symbols → gate) |
| **Manifold.Patcher** | 1.1.0 | Snapshot, fingerprint and remote-patch system for Cheat Tables |
| **Manifold.RTTI** | - | MSVC RTTI scanner: classes, COLs, vtables, instances |
| **Manifold.AssemblerCommands** (copy) | 1.2.0 | Older variant with the detour logic still inside the module |

### Tests (`Manifold.Testing/`)

`Manifold.UnitTest.lua` is a standalone runner executed from the CE Lua console. Per module it
checks loadability, metadata (`GetModuleInfo`), the export contract, and an optional behavior
scenario. `Manifold.UnitTest.Output.txt` contains a recorded run.

---

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

The fallback thread matters: it periodically compares the PID against the process name and
therefore also catches a **game restart under the same name**, which a plain
`readInteger(process)` probe would miss.

`ProcessWatchGeneration` is a counter incremented on every stop. The fallback thread terminates
itself as soon as the generation no longer matches its own - so a re-attach leaves no orphaned
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
  ├─ _stateKey(name, memrec)                  "name#MRID:<id>" - stable across runs
  ├─ autoAssembleCheck(text, willEnable, ts)  syntax check up front
  ├─ autoAssemble(text, ts, st.DisableInfo)   toggle: DisableInfo == nil → ENABLE
  ├─ _txRememberEnable(...)                   remember for rollback
  └─ trampolineTx:CommitTransaction()
_txCommit()
```

On failure:

- `trampolineTx:RollbackTransaction(reason)` restores the original bytes of the inject site and
  the relay slot.
- At the top level, `_txRollback()` disables every script enabled in this transaction **in reverse
  order**.
- With `BreakOnError = true` (the default) the error is re-raised so CE discards the memory
  record's activation.

State lives in `AutoAssembler.States[key]`:

```lua
{
  Key, Name, DisableInfo, Active, TargetSelf,
  Memrec, LastScriptText, LastLogicalName
}
```

`DisableInfo ~= nil` means "active". That is why a single call handles both enabling **and**
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

The lock deliberately lives in `_G` rather than on the instance: if the table Lua script is
executed again and a new `UI` instance is created, the lock still applies.

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

- `name`, `author` and `description` are **optional** - the bundled `*.Min.json` files in
  `Manifold-Modules/Manifold.Themes/` only contain `tokenColors`. The display name is derived
  from the file name at runtime.
- Colours are `#RRGGBB` and are converted at load time through `string:bgr()` → `UI:RGB2BGR()`
  into the BGR format the VCL expects.
- Missing tokens are collected into **one** warning; the affected controls keep their previous
  colour (`theme[token] or control.Color`).

There are 25 tokens; the full list with descriptions lives in `UI.ThemeTokens` /
`UI.TokenDescriptions` and in the [API reference](Manifold-Framework-API.md#manifoldui).

### 5.5 Theme sources and load order

`ui:LoadThemes()` collects from two sources:

1. **`%LOCALAPPDATA%\Manifold\Themes\*.json`** → marked as *external*, the display name gets the
   suffix `" (External)"`.
2. **Embedded table files**, discovered through CE's `miTable` menu (every entry whose caption
   ends in `.json`).

Both end up in `UI.ThemeList[themeName] = { [token] = bgrColor, ... }`.

`ui:UpdateThemeSelector()` generates memory records from that: it looks for the record described
as `[— UI : Theme Selector -] ()->`, deletes its children, and creates one `vtAutoAssembler`
record per theme whose `{$lua}` script calls `ui:ApplyTheme(memrec.Description)` and then disables
itself through `utils:AutoDisable(memrec.ID)`.

---

## 6. Custom Auto Assembler commands

After `assemblerCommands:RegisterCoreCommands()`, ten additional commands are available in
**every** AA script.

| Command | Signature | Effect |
|---|---|---|
| `ManifoldScanModule` | `(symbol, module, signature [, protection, alignType, alignParam])` | Unique AoB scan; replaces itself with `define(symbol, module+OFFSET)`. Aborts when the signature is ambiguous. |
| `ManifoldAssert` | `(address, bytePattern)` | Compares the bytes at `address` against the pattern (`??` = wildcard). Reports the first mismatch with a marker but **does not stop**. |
| `ManifoldPatch` | `(address, bytePattern)` / `(address)` | Writes bytes and remembers the original. Without a second argument: restore. |
| `ManifoldNop` | `(address, count)` / `(address)` | Like `ManifoldPatch` with `90` bytes. Without a count: restore. |
| `ManifoldInstallDetour` | `(name, injectExpr [, destExpr, minSize])` | 5-byte detour through a PE-header relay. Without `destExpr`, `<name>Code` is assumed. |
| `ManifoldEmitOriginal` | `(name)` | Emits the relocated original instructions **and** jumps back. |
| `ManifoldEmitOriginalNoReturn` | `(name)` | Same, without the automatic return jump. |
| `ManifoldEmitReturn` | `(name)` | Only `jmp <name>_Return` - skip the original code. |
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

`ManifoldInstallDetour` creates the symbols `Damage_Block`, `Damage_Relay`, `Damage_Destination`,
`Damage_Return` and - after `ManifoldEmitOriginal` - `Damage_Original`.

### Why a relay in the PE header?

An absolute jump costs 14 bytes on x64 (`jmp qword ptr [rip+0]` plus an 8-byte target). At compact
hook sites that is often too much. `Manifold.Trampolines` solves it like this:

1. It searches the **PE header of the target module** (between `ModuleBase + 0x500` or the end of
   the section headers and `SizeOfHeaders`, aligned to `0x10`) for a free slot containing only
   `0x00` or `0xCC` bytes.
2. That slot receives a `jmp qword ptr [Destination]` plus the 8-byte target pointer - 16 bytes
   in total, rounded up to the alignment.
3. The hook site then only needs a **5-byte `jmp rel32`** into that relay.
4. Only **whole instructions** covering at least 5 bytes are overwritten
   (`_collectInstructionRange`); the remainder is padded with `nop`.

The original bytes are stored and **relocated** for `ManifoldEmitOriginal`: relative jumps
(`_analyzeRelativeControlFlow`) and RIP-relative memory accesses
(`_rewriteAbsoluteMemoryInstruction`) are rewritten to absolute addresses so the original code
runs correctly from its new location.

> The relay sits in a module region that is normally not read at runtime. Anti-cheat systems that
> verify module integrity across the whole image range will still see the change.

---

## 7. State management

```lua
state:SaveTableState("Profile-Easy")
state:LoadTableState("Profile-Easy")
state:RestoreOriginalState()          -- deactivate everything
```

States are written to `%LOCALAPPDATA%\Manifold\State\Manifold.<Name>.<Process>.State` as a JSON
array. Only records that are **active or carry hotkeys** are included:

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

`RestoreState` is **exclusive**: records not listed in the file get deactivated. Matching happens
via `mr.ID`, not the description. Async records are awaited with a 10,000 ms timeout; the result
comes back in `stats`:

```lua
local stats = state:LoadTableState("Profile-Easy")
-- stats = { activatedCount, deactivatedCount, unchangedCount, failedCount }
```

Since version 1.0.5 **every** access to `AddressList`, `MemoryRecord` and hotkeys is routed
through `synchronize()` on the GUI thread (CE 7.6 compatibility).

---

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
| `Transform` | Current player position. Read as a **pointer** (`[Symbol]+0` plus offsets). |
| `Waypoint` | Optional waypoint position, also a pointer. |
| `Additional` | Optional second write target (some games require a second set of coordinates to allow for proper teleports). Only used when `Symbol` is set. |
| `Symbols.Saved` / `.Backup` | Two allocated buffers for "last save" and "position before the last jump". Read/written **directly**, not as pointers. |

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
teleporter:TeleportToSave("Boss Arena")
```

Every jump runs the same chain: `PauseGame()` → `GetAdjustedTargetPosition()` →
`WritePositionToMemory(Transform)` → optionally `Additional` → `ResumeGame()` →
`LogDistanceTraveled()` → write backup.

### 8.3 Persistent saves

`teleporter.Saves` is a map of `name → entry`:

```json
{
  "Boss Arena": {
    "X": 1024.5, "Y": 64.0, "Z": -320.25,
    "Author": "Leunsel",
    "Category": "World / Region / Room",
    "Categories": ["World", "Region", "Room"],
    "Description": "In front of the fog room"
  }
}
```

- **`Categories`** (array) is the authoritative form since 1.1.5. **`Category`** (string) is kept
  in sync for backward compatibility; older files that only carry `Category` are normalized on
  load through `GetSaveCategoryPath()`.
- `/`, `\`, `>` and `|` are accepted as separators in `Category`; output always uses `" / "`.
- File: `%LOCALAPPDATA%\Manifold\Teleporter\Teleporter.<Target>.Saves.txt`.
  `SaveLookup()` tries that file first and falls back to the table file of the same name - handy
  for shipped tables with predefined jump targets.

`CreateTeleporterSaves()` turns the data into a tree of memory records underneath the record
`[— Teleporter : Saves -] ()->`:

```
[— Teleporter : Saves -] ()->
└─ [— Leunsel -] ()->                (author, vtGroupHeader)
    └─ [— World -] ()->              (category, nested)
        └─ [— Region -] ()->
            └─ Teleport To: 'Boss Arena' ()->   (vtAutoAssembler, {$lua})
```

### 8.4 Dedicated UI

```lua
teleporter:InitTeleporterUI()
```

Opens a standalone window (1120 × 720) with a menu strip, status bar, a tree view of saves
(grouped by author → category) and an editor for name, author, category path, X/Y/Z and
description. Its controls are built through `Manifold.Forms`, so `ui:ApplyTheme(...)` recolours
them automatically (`UI:SetTeleporterControlColors`).

---

## 9. Forms - themeable controls

`Manifold.Forms` is the control factory behind the teleporter UI and the theme creator. Every
control it creates is entered into a registry and carries a **role**. On a theme change,
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

Buttons are not `TButton` but **panels with a centred label** - that is what makes them freely
colourable (`TButton` ignores `Color` on Windows). Hover effects go through
`OnMouseEnter`/`OnMouseLeave` → `Forms:SetButtonState`.

With `opts.lockColor = true` a control is left untouched by theme changes (e.g. colour preview
swatches in the theme creator).

---

## 10. Callbacks - locking edits

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
`ResetConfig()` restores the defaults (all `false`).

The module also installs, at load time:

- `onMemRecPreExecute` / `onMemRecPostExecute` - debug log, and a warning when execution fails.
- `AddressList.OnAutoAssemblerEdit` - chains the previous handler instead of replacing it.
- `getLuaEngine().OnShow` - calls the original handler and then applies the active theme
  **twice** to the Lua engine (the second pass is commented as necessary because CE resets some
  properties when showing the window).

For a release table this is the usual guard against accidental edits. It is **not** copy
protection - the callbacks can be switched off from the Lua engine in one line.

---

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

Pointer chains are resolved by `Manifold.Utils`:

```lua
local addr = utils:ResolvePointerPath("Game.exe+1A2B3C4", { 0x10, 0x28, 0x8 })
local addr = utils:ResolvePointerPath("SomePointerSymbol", { 0x10, 0x28, 0x8 })
```

> Caution: every successful read/write writes an **info line** to the log. In loops or timers that
> is a noticeable cost - see [TODO T11](TODO.md#t11-every-memory-access-emits-an-info-log-line).

---

## 12. Logging

```lua
logger:SetLevel(logger.Levels.INFO)      -- DEBUG=1 INFO=2 WARNING=3 ERROR=4 CRITICAL=5
logger:SetLogFileName("MyGame")          -- → Manifold.Runtime.MyGame.log
logger:SetOutput(print)                  -- any output function
```

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

---

## 13. Utils

### Window title

```lua
utils:SetTitle()
```

produces

```
<TargetStr> <(x64)> V:<AppVersion> - CET V:<Version> - CE <(x64)> V:<CEVersion>
```

from `utils:GetTitleComponents()`.

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

`VerifyFileHash()` runs after every successful attach and warns on a mismatch. It **does not
block** - the table keeps running.

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

`AutoDisable` is the standard pattern for "action" records: a script activates, does something,
and switches itself back off so the checkbox does not stay ticked.

---

## 15. Reference

The complete function list per module lives in
**[Manifold-Framework-API.md](Manifold-Framework-API.md)**.