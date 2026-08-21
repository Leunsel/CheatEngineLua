# Manifold Framework — API Reference

Complete function reference for every module in
[`Manifold-Modules/Manifold.Modules/`](../Manifold-Modules/Manifold.Modules/).
Concepts, bootstrapping and flows are covered in [Manifold-Framework.md](Manifold-Framework.md).

**Conventions used here**

- Functions with a leading `_` are internal helpers. They are documented because they are exposed
  through `registerLuaFunctionHighlight` and are needed when extending the modules — but they are
  not part of the stable API.
- Every module has `New(...)`, `GetModuleInfo()` and `PrintModuleInfo()`. These three are only
  described in detail for the first module.

## Contents

| Module | Section |
|---|---|
| Manifold.Json | [→](#manifoldjson) |
| Manifold.Logger | [→](#manifoldlogger) |
| Manifold.CustomIO | [→](#manifoldcustomio) |
| Manifold.Helper | [→](#manifoldhelper) |
| Manifold.Utils | [→](#manifoldutils) |
| Manifold.ProcessHandler | [→](#manifoldprocesshandler) |
| Manifold.Memory | [→](#manifoldmemory) |
| Manifold.State | [→](#manifoldstate) |
| Manifold.AutoAssembler | [→](#manifoldautoassembler) |
| Manifold.Callbacks | [→](#manifoldcallbacks) |
| Manifold.AssemblerCommands | [→](#manifoldassemblercommands) |
| Manifold.Trampolines | [→](#manifoldtrampolines) |
| Manifold.Forms | [→](#manifoldforms) |
| Manifold.UI | [→](#manifoldui) |
| Manifold.Teleporter | [→](#manifoldteleporter) |
| Developer modules | [→](#developer-modules) |

---

## Manifold.Json

`JSON` — Jeffrey Friedl's `json.lua`, version `20161109.21`, CC-BY licensed. Taken unmodified.

| Function | Returns | Description |
|---|---|---|
| `JSON:new(args)` | `JSON` | Creates an instance. **Lowercase `n`** — unlike the rest of the framework. `args` overrides instance fields (e.g. `assert`). |
| `json:decode(text [, etc, options])` | `table\|nil, string` | Parses JSON. On failure returns `nil` plus a message, provided the error handler does not abort. |
| `json:encode(value [, etc, options])` | `string` | Compact JSON. |
| `json:encode_pretty(value [, etc, options])` | `string` | Indented JSON (`indent = "  "`). Used by `CustomIO:WriteToFileAsJson`. |
| `json:newArray(tbl)` | `table` | Marks the table as an array (empty ⇒ `[]` instead of `{}`). |
| `json:newObject(tbl)` | `table` | Marks the table as an object. |
| `json:asNumber(item)` / `forceString(item)` / `forceNumber(item)` | | Type conversion for decoded values. |
| `json:onDecodeError(msg, text, loc, etc)` | | Overridable error handler. Default: `assert(false, …)`. |
| `json:onEncodeError(msg, etc)` | | Same for encoding. |
| `json:onTrailingGarbage(...)` | | Reaction to characters after the JSON document. |

**Handle errors silently instead of raising:**

```lua
json = JSON:new({
    assert = function(ok, msg) if not ok then logger:Error(msg) end end
})
```

> `decode`/`encode` verify `self.__index == JSON`. Reloading `Manifold.Json` replaces the global
> `JSON` and invalidates every instance created earlier
> ([TODO T7](TODO.md#t7-json-instances-do-not-survive-a-module-reload)).

---

## Manifold.Logger

`Logger` — version 1.0.2.

### Construction and metadata

| Function | Returns | Description |
|---|---|---|
| `Logger:New()` | `Logger` | Sets `Level = Levels.ERROR`, `Output = print`, `DataDir = %USERPROFILE%\AppData\Local\Manifold`, `LogFileName = "Manifold.Runtime.Unknown.log"`. |
| `logger:GetModuleInfo()` | `table` | `{ name, version, author, description }` |
| `logger:PrintModuleInfo()` | — | Prints the metadata through `logger:Info`. |

### Fields

| Field | Default | Description |
|---|---|---|
| `Level` | `Levels.ERROR` (4) | Minimum level for **console output** |
| `Levels` | `{DEBUG=1, INFO=2, WARNING=3, ERROR=4, CRITICAL=5}` | |
| `LevelNames` | Reverse map of `Levels` | |
| `Output` | `print` | Target function for console output |
| `DataDir` | `%USERPROFILE%\AppData\Local\Manifold` | **Its own copy**, independent of `customIO.DataDir` |
| `LogFileName` | `Manifold.Runtime.Unknown.log` | Relative to `DataDir\Logs` |

### Configuration

| Function | Description |
|---|---|
| `logger:SetLevel(level)` | Accepts a number or a name (`"INFO"`). Unknown ⇒ `Levels.INFO`. Reports the change via `ForceInfo`. |
| `logger:SetLogFileName(name)` | Produces `Manifold.Runtime.<name>.log`. Empty/`nil` ⇒ `…Unknown.log`. |
| `logger:SetOutput(fn)` | `nil` ⇒ back to `print`. |
| `logger:ClearLogFile()` | Truncates the file (open with `"w"`, close immediately). |

### Output

For each level `Debug`, `Info`, `Warning`, `Error`, `Critical`, four functions are generated at
load time:

| Pattern | Example |
|---|---|
| `logger:<Level>(msg)` | `logger:Info("ready")` |
| `logger:<Level>F(fmt, ...)` | `logger:InfoF("%d/%d", a, b)` |
| `logger:Force<Level>(msg)` | `logger:ForceError("critical")` |
| `logger:Force<Level>F(fmt, ...)` | `logger:ForceWarningF("%s", x)` |

`Force…` bypasses the level filter and tags the line with `[FORCED]`.

| Function | Description |
|---|---|
| `logger:Log(level, message)` | Direct variant, honours `Level`. |
| `logger:ForceLog(level, message)` | Direct variant without filtering. |
| `logger:Stringify(value [, processed])` | Recursive text representation; cycles ⇒ `{...}`, null bytes ⇒ `\0`. |

Format: `[HH:MM:SS] [LEVEL] [FORCED] <message>`

### Internal helpers

| Function | Description |
|---|---|
| `logger:_GetLogsDirectory()` | `DataDir\Logs` |
| `logger:_GetLogFilePath()` | `DataDir\Logs\<LogFileName>` |
| `logger:_EnsureLogDirectories()` | Creates `DataDir` and `Logs` on demand. Requires `customIO`. |
| `logger:_WriteToLogFile(text)` | Appends one line. |
| `logger:_ResolveLevel(level)` | `level` → `name, id` |
| `logger:_FormatLogMessage(name, msg, forced)` | Builds the output line. |
| `logger:_DispatchLog(level, msg, forced)` | Central output. **Writes to the file first, filters afterwards.** |

---

## Manifold.CustomIO

`CustomIO` — version 1.0.3. Dependency: `json`.

| Function | Returns | Description |
|---|---|---|
| `CustomIO:New()` | `CustomIO` | Calls `CheckDependencies()`, sets `DataDir`. |
| `customIO:CheckDependencies()` | — | Loads `Manifold.Json` when `json == nil`. |

### Directories

| Function | Returns | Description |
|---|---|---|
| `customIO:DirectoryExists(dir)` | `boolean` | via `lfs.attributes` |
| `customIO:CreateDirectory(dir)` | `boolean, string?` | `lfs.mkdir`; already present ⇒ `true` |
| `customIO:EnsureDirectoryExists(path)` | `boolean` | Check and create (**not** recursive) |
| `customIO:EnsureDataDirectory()` | `boolean` | Ensures `DataDir` |
| `customIO:OpenDirectory(dir)` | `boolean` | `start /b "" "<dir>"` |
| `customIO:BuildPath(dir, fileName)` | `string\|nil` | Appends `\` if needed |

### Files

| Function | Returns | Description |
|---|---|---|
| `customIO:FileExists(path)` | `boolean` | |
| `customIO:DeleteFile(path)` | `boolean, string?` | |
| `customIO:StripExt(fileName)` | `string\|nil` | Removes the last extension |
| `customIO:ReadFromFile(path)` | `string\|nil, string?` | Text mode (`"r"`) |
| `customIO:WriteToFile(path, data)` | `boolean, string?` | Overwrites |
| `customIO:AppendToFile(path, data)` | `boolean, string?` | Appends, **adds `\n`** |

### JSON

| Function | Returns | Description |
|---|---|---|
| `customIO:ReadFromFileAsJson(path)` | `table\|nil, string?` | |
| `customIO:WriteToFileAsJson(path, data)` | `boolean, string?` | Uses `json:encode_pretty` |

### CSV

| Function | Returns | Description |
|---|---|---|
| `customIO:ReadCSV(path)` | `table\|nil, string?` | Lines → arrays. **No quoting support**; empty fields are lost. |
| `customIO:WriteCSV(path, data)` | `boolean, string?` | `table.concat(row, ",")` per line, no escaping. |

### Cheat Engine table files

| Function | Returns | Description |
|---|---|---|
| `customIO:ReadFromTableFile(name)` | `string\|nil, string?` | Reads an embedded file. |
| `customIO:WriteToTableFile(name, text)` | `boolean` | Creates it on demand, overwrites completely. |
| `customIO:ReadFromTableFileAsJson(name)` | `table\|nil, string?` | |
| `customIO:WriteToTableFileAsJson(name, data)` | `boolean` | Uses `json:encode` (compact). |

> `ReadFromTableFile` internally uses `string.char(table.unpack(bytes))`. Very large table files
> can exceed Lua's stack limits
> ([TODO T12](TODO.md#t12-reading-table-files-does-not-scale)).

---

## Manifold.Helper

`Helper` — version 1.0.2. No dependency resolution; expects `logger`.

| Function | Returns | Description |
|---|---|---|
| `helper:GetProcess()` | `string` | The CE global `process` |
| `helper:IsProcessAvailable()` | `boolean` | `pcall(readInteger, process)` |
| `helper:GetProcessTrimmed()` | `string` | Without `.exe` |
| `helper:GetGameModule()` | `table\|nil` | `enumModules()[1]` |
| `helper:GetGameModuleIs64Bit()` | `boolean\|nil` | |
| `helper:GetGameModuleName()` | `string\|nil` | |
| `helper:GetGameModulePathToFile()` | `string\|nil` | Full path to the executable |
| `helper:GetGameModuleAddress()` | `integer\|nil` | Module base |
| `helper:GetRegistrySizeStr()` | `string` | `"(x64)"` or `"(x32)"` |

---

## Manifold.Utils

`Utils` — `VERSION = "1.0.3"` (the changelog already says 1.0.5).

### Configuration fields

```lua
utils = Utils:New({
    Author     = "",     -- free-form
    Target     = "",     -- process file name, e.g. "Game.exe"
    TargetStr  = "",     -- display name in the window title
    AppID      = "",     -- free-form (e.g. Steam AppID)
    AppVersion = "",     -- game version for the title
    Version    = "",     -- table version for the title
    VerifyMD5  = true,
    MD5Hash    = "",
    AutoDisableTimerInterval = 100,
    IsRelease  = false,
})
```

### Target and title

| Function | Returns | Description |
|---|---|---|
| `utils:GetTarget()` | `string\|nil` | |
| `utils:GetTargetNoExt()` | `string\|nil` | via `customIO:StripExt` |
| `utils:GetTitleComponents()` | `table` | `{tableTitle, tableVersion, gameVersion, registrySizeStr, ceRegistrySizeStr, ceVersion}` |
| `utils:FormatTitle(components)` | `string` | `"%s %s V:%s — CET V:%s — CE %s V:%s"` |
| `utils:SetTitle()` | — | Sets `getMainForm().Caption`. |
| `utils:InitializeTable()` | — | `ui:InitializeForm()` + `SetTitle()`. Called by the process handler. |

### Dialogs

| Function | Returns |
|---|---|
| `utils:ShowInfo(msg)` | — |
| `utils:ShowWarning(msg)` | — |
| `utils:ShowError(msg)` | — |
| `utils:ShowConfirmation(msg)` | `boolean` |

All synchronize into the main thread on their own.

### Checks

| Function | Returns | Description |
|---|---|---|
| `utils:VerifyFileHash()` | `boolean` | Compares `md5file(exe path)` against `MD5Hash`, warns on a mismatch. Does not block. |
| `utils:EnsureCompatibleCEVersion(required, closeOnFail)` | — | Compares against `getCEVersion()`. `closeOnFail = true` ⇒ `closeCE()`. |

### Records and scripts

| Function | Description |
|---|---|
| `utils:AutoDisable(id [, interval])` | Deactivates the record with `id` after `interval` ms (default `AutoDisableTimerInterval`). Waits for `AsyncProcessing`. |
| `utils:SetAllScriptsToAsync()` | `Async = true` on every `vtAutoAssembler` record. |
| `utils:SetAllScriptsToNotAsync()` | The inverse. |
| `utils:RemoveTableFilesByExtension(ext)` | Opens `miTable` and deletes every table file whose caption contains `ext` (default `".lua"`). For release builds. |
| `utils:ExecuteTableLuaScript()` | Finds the form `"Lua script: Cheat Table"` and clicks `btnExecute`. |

### Memory

| Function | Returns | Description |
|---|---|---|
| `utils:ResolvePointerPath(base, offsets)` | `integer\|nil` | Follows the chain: `readPointer(addr) + offset` per step. `base` may be a symbol or a number. |

### Custom value types

| Function | Type | Bytes |
|---|---|---|
| `utils:RegisterTimeTypes()` | `Military Hours` | 4 |
| `utils:RegisterDecryptionType()` | `Decrypted` | 16 |
| `utils:RegisterPlaytimeMilitaryType()` | `Playtime Float` | 8 |

### Miscellaneous

| Function | Description |
|---|---|
| `utils:OpenLuaEngineWindow()` | `getLuaEngine() or createLuaEngine()` and `Show()` |

---

## Manifold.ProcessHandler

`ProcessHandler` — version 1.2.7. Dependencies: `logger`, `utils`.

### Fields

| Field | Default | Description |
|---|---|---|
| `ProcessName` | `nil` | Target process |
| `AutoAttachTimerInterval` | `1000` | ms |
| `ProcessWatchTimerInterval` | `1000` | ms |
| `AttachedProcessName` / `AttachedProcessID` | `nil` | Set after a successful attach |
| `IsAutoAttaching` / `IsWatchingProcess` | `false` | |
| `ProcessWatchGeneration` | `0` | Incremented on every stop; terminates stale fallback threads |
| `AutoAttachOptions` | `nil` | The options last passed in |

### Attaching

| Function | Returns | Description |
|---|---|---|
| `processHandler:AutoAttach(name [, options])` | `boolean` | Starts the waiting timer. `options` may be a number (timeout in seconds) or a table: `{ maxSecs, runPostAttachTasks, onAttached }`. |
| `processHandler:AttachToProcess(name [, pid, options])` | `boolean` | Direct attach with validation. A changed PID ⇒ `ResetProcessBoundState`. |
| `processHandler:AttachToProcessByName(name)` | `boolean` | Resolve the PID + `AttachToProcess`. |
| `processHandler:ResolveProcessName(name)` | `string\|nil` | Falls back to `ProcessName` / `AttachedProcessName` and memoizes the result. |
| `processHandler:OnProcessAttached(name, pid, options)` | — | Post-attach tasks, `onAttached` callback, watch timer. |
| `processHandler:PerformPostAttachTasks()` | — | `utils:InitializeTable()` and (when `utils.VerifyMD5`) `utils:VerifyFileHash()`. |

**Options table:**

```lua
processHandler:AutoAttach("Game.exe", {
    maxSecs            = 60,        -- 0/nil = unlimited
    runPostAttachTasks = true,      -- false = leave UI/title alone
    onAttached = function(handler, name, pid)
        logger:InfoF("Attached to %s (%d)", name, pid)
        state:LoadTableState("Default")
    end,
})
```

### Status

| Function | Returns | Description |
|---|---|---|
| `processHandler:IsProcessAttached()` | `boolean` | Did `readInteger(process)` succeed? |
| `processHandler:IsAttachedProcessAvailable()` | `integer\|nil` | Raw value of the probe read |
| `processHandler:GetAttachedProcessName()` | `string\|nil` | |
| `processHandler:IsAttachedToTarget([name, pid])` | `boolean` | Compares `getOpenedProcessID()` against the expected PID |
| `processHandler:IsTargetProcessValid([name, pid])` | `boolean` | Synonym for `IsProcessAttached` |
| `processHandler:GetProcessWatchStatus()` | `table` | `{isWatching, timer, ticks, lastTick, fallbackTicks, fallbackLastTick}` — useful for diagnostics |

### Monitoring

| Function | Returns | Description |
|---|---|---|
| `processHandler:StartProcessWatchTimer([name])` | `boolean` | TTimer + fallback thread |
| `processHandler:StopProcessWatchTimer([timer])` | `boolean` | Increments `ProcessWatchGeneration` |
| `processHandler:StartProcessWatchFallback(name, pid)` | `boolean` | `createThread` loop comparing PID against process name |
| `processHandler:CheckWatchedProcess(timer)` | `boolean` | Tick handler |
| `processHandler:StopAutoAttachTimer([timer])` | — | |

### Cleanup

| Function | Description |
|---|---|
| `processHandler:HandleProcessUnavailable(reason [, timer])` | Delegates to `CleanupAndReattach`. |
| `processHandler:HandleProcessChanged(oldPid, newPid)` | Same, with PID context in the message. |
| `processHandler:CleanupAndReattach(reason [, timer])` | Stop timers → `DisableAllWithoutExecute` → `ResetProcessBoundState` → `AutoAttach`. |
| `processHandler:DisableAllWithoutExecute()` | `AddressList.disableAllWithoutExecute()` + `deleteAllRegisteredSymbols()`. |
| `processHandler:ResetProcessBoundState(reason)` | `autoAssembler:Reset()`, `assemblerCommands.ActivePatches = {}`, `trampolines:Reset()` — each only when loaded. |

### Miscellaneous

| Function | Description |
|---|---|
| `processHandler:CloseProcess()` | Asks for confirmation and terminates the process via `taskkill /PID <pid> /F`. |
| `processHandler:OpenLink(url)` | Asks for confirmation and opens the URL via `ShellExecute`. |

---

## Manifold.Memory

`Memory` — version 1.0.5. Expects `logger`.

### Generated type functions

For `Byte`, `Word`, `Integer`, `QWord`, `Float`, `Double`:

| Function | Returns |
|---|---|
| `memory:SafeRead<Type>(address [, signed])` | `number\|nil` |
| `memory:SafeWrite<Type>(address, value)` | `boolean` |
| `memory:SafeAdd<Type>(address, value [, signed])` | `boolean` |

`signed` only applies to `Word` and `Integer` (`supportsSigned`).

Underlying CE functions:

| Type | Read | Write |
|---|---|---|
| `Byte` | `readByte` | `writeByte` |
| `Word` | `readSmallInteger` | `writeSmallInteger` |
| `Integer` | `readInteger` | `writeInteger` |
| `QWord` | `readQword` | `writeQword` |
| `Float` | `readFloat` | `writeFloat` |
| `Double` | `readDouble` | `writeDouble` |

### Address resolution

| Function | Returns | Description |
|---|---|---|
| `memory:SafeGetAddress(addressOrSymbol [, isLocal])` | `integer\|nil` | Number ⇒ unchanged (negative ⇒ `nil`); string ⇒ `getAddressSafe(s, isLocal)`. |

### Internal helpers

| Function | Description |
|---|---|
| `memory:_IsNumber(v)` / `_IsOptionalBoolean(v)` | Type checks (NaN counts as a non-number) |
| `memory:_FormatAddress(addr)` | `"0x%08X"` |
| `memory:_RequireAddress(addr, fnName)` | Resolve + validate |
| `memory:_RequireNumber(v, fnName, param)` | |
| `memory:_RequireSignedFlag(v, fnName)` | |
| `memory:_ReadResolvedValue(addr, typeInfo, signed)` | |
| `memory:_WriteResolvedValue(addr, value, typeInfo)` | |
| `memory:_SafeReadValue` / `_SafeWriteValue` / `_SafeAddValue` | Shared implementation |
| `memory:_LogReadFailure` / `_LogWriteFailure` | Error messages |

---

## Manifold.State

`State` — version 1.0.5. Dependencies: `logger`, `customIO`, `processHandler`.
Since 1.0.5 **every** CE access is main-thread synchronized.

| Function | Returns | Description |
|---|---|---|
| `State:New()` | `State` | Creates `TableStateDir`. |
| `state:EnsureStateDirectory()` | `string\|nil` | `DataDir\State` |
| `state:GetStateFilePath(name)` | `string\|nil` | `…\Manifold.<name>.<Process>.State` |
| `state:GetIndexedAddressList()` | `table, table` | An indexed list **and** an id-keyed list of all records |
| `state:SaveTableState(name)` | `boolean` | Saves active records and records with hotkeys. With none of either ⇒ `false` plus a warning. |
| `state:LoadTableState(name)` | `boolean` | Reads the file and calls `RestoreState`. |
| `state:RestoreState(stateData)` | `table` | `{activatedCount, deactivatedCount, unchangedCount, failedCount}`. **Exclusive** — records not listed get deactivated. |
| `state:RestoreOriginalState()` | `table` | Deactivates everything (iterating backwards). |
| `state:SetMemoryRecordState(mr, state [, timeoutMs])` | `boolean` | Default timeout 10,000 ms for async records. |
| `state:WriteStateFile(path, data)` | `boolean` | |
| `state:ReadStateFile(path)` | `table\|nil` | |
| `state:CheckDependencies()` | — | |

### Internal helpers

| Function | Description |
|---|---|
| `state:_BuildStateRecord(rec)` | Condenses a list entry; `nil` when inactive and without hotkeys. |
| `state:_SetMemoryRecordStateOnMainThread(mr, state, timeoutMs)` | Sets `Active`, waits for `AsyncProcessing`, returns an outcome object. |
| `state:_LogMemoryRecordStateOutcome(outcome)` | Evaluates the outcome object. |
| `state:_RestoreHotkeysOnMainThread(mr, hotkeys)` | Destroys all hotkeys and recreates them. |

**Outcome object from `_SetMemoryRecordStateOnMainThread`:**

```lua
{ success, changed, state, record, active, async, asyncProcessing,
  asyncWasProcessing, didTimeout, waitedMs }
```

---

## Manifold.AutoAssembler

`AutoAssembler` — version 2.0.6. Dependencies: `json`, `logger`, `customIO`, `processHandler`.

| Function | Returns | Description |
|---|---|---|
| `AutoAssembler:GetInstance()` | `AutoAssembler` | **Preferred entry point** (singleton in `_instance`). |
| `AutoAssembler:New()` | `AutoAssembler` | A fresh instance. |
| `autoAssembler:SetProcessName(name)` | — | Sets `RequiredProcess`; scripts only run against a matching process. |
| `autoAssembler:AutoAssemble(fileOrText [, memrecOrTargetSelf, targetSelf])` | `boolean` | Toggles a script. See below. |
| `autoAssembler:Disable([fileOrKey, memrec])` | `boolean` | Without arguments: disable every active state. |
| `autoAssembler:Reset([reason])` | — | Clears `States` and the transaction depth. |
| `autoAssembler:DisableAllWithoutExecute()` | `boolean` | Delegates to the process handler. |
| `autoAssembler:EnsureDirectoriesExist()` | `boolean` | Creates `DataDir/CEA/<Process>`. |
| `autoAssembler:GetFilePath(fileName)` | `string\|nil` | Full path inside the CEA directory. |
| `autoAssembler:FormatFileName(name)` | `string` | Appends `.CEA` when missing. |
| `autoAssembler:CheckDependencies()` | — | |

### Fields

| Field | Default | Description |
|---|---|---|
| `RequiredProcess` | `""` | Empty ⇒ no check |
| `LocalFilesFolder` | `"CEA"` | Subfolder inside `DataDir` |
| `FileExtension` | `".CEA"` | |
| `BreakOnError` | `true` | With `false`, returns `false` instead of raising |
| `States` | `{}` | `key → state table` |

### Call variants

```lua
autoAssembler:AutoAssemble("InfiniteHealth")           -- file CEA/<Process>/InfiniteHealth.CEA
autoAssembler:AutoAssemble("InfiniteHealth", memrec)   -- with a stable state key
autoAssembler:AutoAssemble(scriptTextWithNewlines)     -- raw text
autoAssembler:AutoAssemble(scriptText, true)           -- targetSelf: assemble into CE itself
autoAssembler:AutoAssemble("Script", memrec, true)     -- memrec + targetSelf
```

Whether the argument is raw text or a file name is decided solely by the presence of a newline.

### State keys

`_stateKey(name, memrec)` produces, in order:

1. `"<name>#MRID:<memrec.ID>"` — preferred, stable across runs
2. `"<name>#MRDESC:<memrec.Description>"`
3. `"<name>#MR:<tostring(memrec)>"`
4. `"<name>"` — no memory record

### Internal helpers

| Function | Description |
|---|---|
| `_currentPid()` | `getOpenedProcessID()` wrapped in `pcall` |
| `_validateProcessOrThrow()` | Process attached? Name matching? |
| `_checkProcessChangedOrThrow()` | PID comparison against `_lastKnownPid` |
| `_markProcessChangedAndThrow(old, new)` | Disables everything and resets. **Does not raise despite the name** (the `error()` is commented out). |
| `_loadScriptText(nameOrText)` | Raw text or file / table file |
| `_getOrCreateState(key)` | |
| `_txBegin()` / `_txCommit()` / `_txRollback()` | Transaction bracket |
| `_txRememberEnable(key, text, targetSelf, disableInfo, name)` | Rollback entry |
| `_scriptUsesTrampolines(text)` | Searches for `ManifoldInstallDetour`, `ManifoldDestroyDetour`, `ManifoldEmitOriginal`, `ManifoldEmitOriginalNoReturn`, `ManifoldEmitReturn` |
| `_getTrampolineApi()` | Loads `Manifold.Trampolines` on demand |
| `_beginTrampolineTransaction(text)` | Starts the detour transaction only when needed |

---

## Manifold.Callbacks

`Callbacks` — version 1.0.5, a **singleton** (`Callbacks:New()` always returns the same instance).

### Options

| Option | Default | Effect when `true` |
|---|---|---|
| `DisableAutoAssemblerEdits` | `false` | The AA editor is blocked for records |
| `DisableDescriptionChange` | `false` | Description is read-only |
| `DisableAddressChange` | `false` | Address is read-only |
| `DisableTypeChange` | `false` | Type is read-only |
| `DisableValueChange` | `false` | Value is read-only |

### Generated accessors

Per option: `callbacks:Get<Option>()`, `callbacks:Set<Option>(bool)` and
`callbacks:Toggle<Option>()`.

### General API

| Function | Returns | Description |
|---|---|---|
| `callbacks:GetConfigValue(name)` | `boolean\|nil` | |
| `callbacks:SetConfigValue(name, value)` | `boolean` | Requires a boolean |
| `callbacks:ToggleConfigValue(name)` | `boolean\|nil` | |
| `callbacks:ResetConfig()` | `table` | All options back to `false` |

### Hooks installed at module load

| Hook | Behaviour |
|---|---|
| `onMemRecPreExecute(memrec, newstate)` | Debug log |
| `onMemRecPostExecute(memrec, newstate, succeeded)` | Warning only on failure |
| `AddressList.OnDescriptionChange` | `true` = block |
| `AddressList.OnAddressChange` | Same |
| `AddressList.OnTypeChange` | Same |
| `AddressList.OnValueChange` | Same |
| `AddressList.OnAutoAssemblerEdit` | **Chains** the previous handler |
| `getLuaEngine().OnShow` | Original handler, then apply the theme twice |

---

## Manifold.AssemblerCommands

`AssemblerCommands` — version 1.2.5. Dependencies: `logger`, optionally `trampolines`.

| Function | Returns | Description |
|---|---|---|
| `AssemblerCommands:New()` | `AssemblerCommands` | |
| `assemblerCommands:RegisterCoreCommands()` | `boolean` | Registers every command in `COMMAND_SPECS`. |
| `assemblerCommands:CheckDependencies()` | — | |

### Registered commands

| Command | Arguments | Replaced by |
|---|---|---|
| `ManifoldScanModule` | `symbol, module, signature [, protection, alignType, alignParam]` | `define(symbol, module+OFFSET)` |
| `ManifoldAssert` | `address, bytePattern` | *(empty)* |
| `ManifoldPatch` | `address [, bytePattern]` | *(empty)* |
| `ManifoldNop` | `address [, count]` | *(empty)* |
| `ManifoldInstallDetour` | `name, injectExpr [, destExpr, minSize]` | Generated detour script |
| `ManifoldEmitOriginal` | `name` | Relocated original code + `jmp <name>_Return` |
| `ManifoldEmitOriginalNoReturn` | `name` | Relocated original code without a return |
| `ManifoldEmitReturn` | `name` | `jmp <name>_Return` |
| `ManifoldDestroyDetour` | `name` | `db` restore + `unregistersymbol(...)` |
| `ManifoldResolveStatic` | `symbol, addrExpr [, dispOffset, instrLen, mode, outputMode]` | `define(symbol, TARGET)` |

### Byte patterns

`_parseBytesPattern` accepts hex pairs with `??`, `?` or `*` as wildcards:

```
ManifoldAssert(HealthHook, 89 41 ?? 8B 45 08)
ManifoldPatch(HealthHook, 90 90 ?? ?? 90 90)     -- ?? = leave this byte untouched
```

In `ManifoldPatch` a wildcard means "do not overwrite this position", which makes it possible to
change individual bytes inside an instruction.

### `ManifoldResolveStatic` in detail

| Parameter | Default | Description |
|---|---|---|
| `symbol` | — | Output symbol |
| `addrExpr` | — | Address of the instruction |
| `dispOffset` | `3` (rip) / `1` (absolute) | Byte offset of the operand within the instruction |
| `instrLen` | `7` (rip) / `5` (absolute) | Total instruction length |
| `mode` | `"auto"` | `"rip"`, `"absolute"` or `"auto"` (detected by `_detectResolveStaticMode`) |
| `outputMode` | `"address"` | `"address"` = resolved operand address; `"pointer"` = the pointer stored there |

Computation:

```
rip:       target = baseAddr + instrLen + disp32
absolute:  target = abs32
```

### Patch management

Applied patches live in `assemblerCommands.ActivePatches`, keyed by address. A second call without
a byte pattern restores the stored original. `processHandler:ResetProcessBoundState()` clears the
table on a process change.

### Internal helpers (selection)

| Function | Description |
|---|---|
| `_beginCommand(name, parameters, syntaxcheck)` | Builds the context `{Name, Args, Syntaxcheck}` |
| `_splitArgs(parameters)` | Comma-separated, bracket-aware |
| `_requireArg` / `_requireSymbolArg` / `_requireResolvedAddressArg` / `_requireBytesPatternArg` | Validation with an error message |
| `_parseNumber(v)` | Decimal, hex, `$`, `0x` and `#` prefixes |
| `_aobScanModuleUnique(module, sig, prot, alignType, alignParam)` | Scan with a uniqueness check |
| `_readBytes` / `_writeBytes` / `_applyBytesAndVerify` | Memory access with read-back |
| `_findPatternMismatch(expected, actual)` | Index of the first difference |
| `_buildMismatchMarker(index)` | Text marker for the log |
| `_storePatch` / `_restoreStoredPatch` / `_applyStoredPatch` / `_executeStoredPatch` | Patch store |
| `_isModuleSuitableForAttachContext(module)` | Verifies via `getAddressSafe`, falls back to `enumModules` |
| `_syntaxDefine(symbol)` | Placeholder `define` during the syntax check |

---

## Manifold.Trampolines

`Trampolines` — version 1.0.1. Dependency: `logger`.
Normally not called directly — `Manifold.AssemblerCommands` is the interface.

### Constants

| Constant | Value | Description |
|---|---|---|
| `HEADER_RELAY_MIN_OFFSET` | `0x500` | Earliest relay offset from the module base |
| `HEADER_RELAY_MAX_OFFSET` | `0x1000` | Lower bound for the end of the search (together with `SizeOfHeaders`) |
| `HEADER_RELAY_ALIGNMENT` | `0x10` | Slot alignment |

### Public API

| Function | Returns | Description |
|---|---|---|
| `trampolines:InstallDetour(name, injectExpr [, destExpr, minSize])` | `entry, script, err` | Finds a relay slot, collects instructions, builds the AA script. |
| `trampolines:EmitOriginal(name)` | `entry, script, err` | Relocated original code **with** a return jump. |
| `trampolines:EmitOriginalNoReturn(name)` | `entry, script, err` | Without the return jump. |
| `trampolines:EmitReturn(name)` | `entry, script, err` | Only `jmp <name>_Return`. |
| `trampolines:DestroyDetour(name)` | `entry, script, err` | Restore script. |
| `trampolines:Reset()` | — | Clears all detour tables. |
| `trampolines:BeginTransaction()` | — | Nestable. |
| `trampolines:CommitTransaction()` | — | Commits `PendingDetours`/`PendingDestroys`. |
| `trampolines:RollbackTransaction([reason])` | — | Writes original and relay bytes back. |
| `trampolines:BuildSyntaxScript(name)` | `string` | Label scaffolding for `syntaxcheck`. |
| `trampolines:BuildOriginalSyntaxScript(name)` | `string` | |
| `trampolines:BuildReturnSyntaxScript(name)` | `string` | |

### Detour entry

```lua
{
  Name, Key,
  InjectExpression, InjectAddress,
  DestinationExpression, DestinationAddress,
  OverwriteSize, ReturnAddress,
  InstructionCount, InstructionOffsets, InstructionSizes,
  OriginalBytes,
  RelayAddress, RelaySize, RelayModuleName, RelayModuleBase,
  RelayOffset, RelayOriginalBytes,
  InstallMode = "header-relay",
  InstallScript,
  Active, Pending, PendingDestroy, OriginalEmitted
}
```

### Generated symbols

| Symbol | Meaning |
|---|---|
| `<name>_Block` | Start of the relay block |
| `<name>_Relay` | `jmp qword ptr [<name>_Destination]` |
| `<name>_Destination` | 8-byte (or 4-byte) pointer to the target code |
| `<name>_Return` | First address after the overwritten range |
| `<name>_Original` | Relocated original code (only after `EmitOriginal`) |

### Internal helpers (selection)

| Function | Description |
|---|---|
| `_collectInstructionRange(addr, minSize)` | Collects whole instructions until ≥ `minSize` |
| `_buildRel32Jump(source, target)` | 5-byte `E9` jump; checks rel32 range |
| `_getPeHeaderInfo(addr)` | MZ/PE signature, `SizeOfHeaders`, end of the section headers |
| `_findHeaderRelaySlot(injectAddr, size)` | Searches for a free, aligned slot |
| `_isHeaderCaveFree(addr, size)` | Only `0x00`/`0xCC` counts as free |
| `_isHeaderRelaySlotReserved(addr, size)` | Collision with existing detours |
| `_analyzeRelativeControlFlow(addr, bytes, size)` | Detects relative jumps/calls |
| `_rewriteAbsoluteMemoryInstruction(instr)` | RIP-relative access → absolute |
| `_buildRelocatedInstruction(entry, index, lines)` | Builds one relocated line |
| `_selectTempRegister(instr)` | Free register for the relocation |
| `_restoreBytes(addr, bytes, label)` | Rollback write |
| `_cleanupDetourSymbols(entry)` | `unregistersymbol` for every detour symbol |

---

## Manifold.Forms

`Forms` — version 1.0.1.

### Control factory

| Function | Returns | Description |
|---|---|---|
| `forms:CreateForm(opts)` | `form` | `BorderStyle = "bsSizeable"`, registered as a root. |
| `forms:CreatePanel(parent, opts)` | `panel` | |
| `forms:CreateLabel(parent, opts)` | `label` | |
| `forms:CreateTextBox(parent, opts)` | `edit` | |
| `forms:CreateMemo(parent, opts)` | `memo` | |
| `forms:CreateTreeView(parent, opts)` | `tree` | |
| `forms:CreateListView(parent, opts)` | `list` | `BorderStyle = "bsNone"` |
| `forms:CreateButton(parent, opts)` | `button, label` | Panel + centred label + hover |
| `forms:CreateMemoFrame(parent, opts)` | `memo, outer, inner` | Memo wrapped in framing panels |
| `forms:CreateCard(parent, opts)` | `outer, inner, header, content, headerLabel` | Titled card |
| `forms:CreateFieldRow(parent, opts)` | `edit, row, label, border, fill, inner, gap` | Labelled input row |

### Common options

`_ApplyCommonOptions` transfers these (in `PascalCase` **or** `camelCase`):

`Name`, `Align`, `Alignment`, `Layout`, `BorderStyle`, `Width`, `Height`, `Left`, `Top`,
`Caption`, `Text`, `TextHint`, `AutoSize`, `Visible`, `Transparent`, `ParentColor`, `ScrollBars`,
`WordWrap`, `ReadOnly`, `ViewStyle`, `AutoWidthLastColumn`, `RowSelect`, `FullRowSelect`,
`HideSelection`, `AutoExpand`, `Cursor`, `Position`, `Scaled`, `Hint`, `ShowHint`

Plus: `borderSpacing` (`{Left, Top, Right, Bottom, Around}`), `constraints`, `role`, `color`,
`bevelOuter`, `bevelWidth`, `bevelColor`, `fontSize`, `style`, `lockColor`, `onClick`
(`CreateButton` only), `root`, `isRoot`.

### Theming

| Function | Returns | Description |
|---|---|---|
| `forms:ApplyTheme(theme [, includeHidden])` | `table` | Colours every registered control; returns the normalized palette. |
| `forms:ApplyThemeToControl(entry, designTheme [, includeHidden])` | — | A single registry entry. |
| `forms:ResolveTheme(theme)` | `table` | Token theme → 17-colour palette. If `theme.COLOR_BG` is present, the table is copied as-is. |
| `forms:SetButtonState(button, isHover)` | — | Hover/normal state. |
| `forms:RegisterControl(control, role, opts)` | `control` | |
| `forms:RegisterForm(form, opts)` | `form` | `isRoot = true` |
| `forms:SetButtonOnClick(button, handler)` | `button` | Sets the handler on both panel **and** label. |
| `forms:ApplyFont(control, color, size, style)` | — | Forces `Consolas`. |
| `forms:SetBorderSpacing(control, spacing)` | — | |
| `forms:Repaint(control)` | — | |

### Palette

| Key | Default | Token source in `ResolveTheme` |
|---|---|---|
| `COLOR_BG` | `0x202020` | `MainForm.Color` |
| `COLOR_PANEL` | `0x2A2A2A` | `MainForm.Foundlist3.Color` |
| `COLOR_ACCENT` | `0x4A4A4A` | `AddressList.CheckboxActiveColor` |
| `COLOR_TEXT` | `0xEAEAEA` | `Memrec.DefaultForeground.Color` |
| `COLOR_LABEL` | `0xC8C8C8` | `Memrec.DefaultForeground.Color` |
| `COLOR_BTN` | `0x2A2A2A` | `AddressList.Header.Canvas.Brush.Color` |
| `COLOR_BTN_HOVER` | `0x4A4A4A` | `AddressList.CheckboxActiveColor` |
| `COLOR_BTN_TEXT` | `0xEAEAEA` | `= COLOR_LABEL` |
| `COLOR_TAB_ACTIVE` / `COLOR_TAB_INACTIVE` | `0x4A4A4A` / `0x2A2A2A` | *(not mapped)* |
| `COLOR_INPUT` | `0x1B1B1B` | `AddressList.List.BackgroundColor` |
| `COLOR_INPUT_TEXT` | `0xEAEAEA` | `TreeView.Font.Color` |
| `COLOR_BORDER` | `0x454545` | `AddressList.Header.Canvas.Pen.Color` |
| `COLOR_MUTED` | `0x8A8A8A` | `Memrec.GroupHeader.Color` |
| `COLOR_SURFACE` | `0x2F2F2F` | `MainForm.Foundlist3.Color` |
| `COLOR_SURFACE_ALT` | `0x242424` | `MainForm.Color` |
| `COLOR_SUCCESS` | `0x6FD96F` | *(not mapped)* |

---

## Manifold.UI

`UI` — version 1.0.5. Dependencies: `logger`, `json`, `customIO`, **`forms`** (enforced).

### Configuration

```lua
ui = UI:New({
    Theme        = "Manifold.Dark-Aqua.Min",  -- applied during InitializeForm
    SloganStr    = "MANIFOLD",
    SignatureStr = "by Leunsel",
})
```

Further fields: `ThemeList`, `ActiveTheme`, `CompactMode`, `IsApplyingTheme`,
`ThemeApplyLockTimeoutMs` (default `8000`).

### Theme tokens

| Token | Description |
|---|---|
| `TreeView.Color` | *Unused — use AddressList instead* |
| `TreeView.Font.Color` | *Unused* |
| `AddressList.CheckboxColor` | Outline of unchecked boxes |
| `AddressList.CheckboxActiveColor` | Fill of checked boxes |
| `AddressList.CheckboxSelectedColor` | Outline of selected boxes |
| `AddressList.CheckboxActiveSelectedColor` | Fill of checked + selected |
| `AddressList.List.BackgroundColor` | Address list background |
| `AddressList.Header.Font.Color` | List header font |
| `AddressList.Header.Canvas.Brush.Color` | List header background |
| `AddressList.Header.Canvas.Pen.Color` | List header border |
| `MainForm.Color` | Main window background |
| `MainForm.Foundlist3.Color` | Scan result list background |
| `MainForm.Panel4.BevelColor` | Bevel of the bottom panel |
| `MainForm.lblSigned.Font.Color` | Font colour of the signed label |
| `MainForm.Splitter1.Color` | Splitter line colour |
| `MainForm.SLOGAN_STR.Font.Color` | Font colour of the slogan label |
| `Memrec.AutoAssembler.Color` | AA script entries |
| `Memrec.AddressGroupHeader.Color` | Address group header (legacy) |
| `Memrec.GroupHeader.Color` | Group header |
| `Memrec.UserDefined.Color` | User-defined values |
| `Memrec.HexValues.Color` | Hex entries |
| `Memrec.StringType.Color` | String entries |
| `Memrec.IntegerType.Color` | Integer entries |
| `Memrec.FloatType.Color` | Float entries |
| `Memrec.DefaultForeground.Color` | Fallback colour |

### Theme management

| Function | Returns | Description |
|---|---|---|
| `ui:LoadThemes()` | — | Loads from the data directory **and** table files. |
| `ui:LoadTheme(themeFile, isExternal)` | — | A single theme. External ones get `" (External)"`. |
| `ui:LoadJsonThemesFromDataDir(list)` | — | Scans `DataDir\Themes`. |
| `ui:GetJsonThemesFromTableMenu()` | `table\|nil` | Reads `.json` entries from `miTable`. |
| `ui:FinalizeThemes(list)` | — | Loads all collected files. |
| `ui:GetTheme(name)` | `table\|nil` | Reloads once on a miss. |
| `ui:ProcessThemeData(raw, name)` | `table` | Tokens → BGR; collects missing/invalid ones. |
| `ui:GetThemeTokens()` | `table` | `UI.ThemeTokens` |
| `ui:TokenColor(raw, token)` | `number\|nil` | Looks the token up in `tokenColors`. |
| `ui:TokenSearch(scope, token)` | `boolean` | |
| `ui:GetActiveThemeData()` | `table\|nil` | Token table of the active theme. |
| `ui:UpdateThemeSelector()` | — | Rebuilds the theme selector records. |
| `ui:EnsureThemeDirectory()` | `string\|nil` | |

### Theme application

| Function | Returns | Description |
|---|---|---|
| `ui:ApplyTheme(name [, allowReapply])` | `boolean` | Full application under a global lock. |
| `ui:ApplyThemeObject(themeObj)` | `boolean` | For `{Name, Author, Description, Tokens}` (theme creator). |
| `ui:ApplyThemeToTreeView(theme)` | — | |
| `ui:ApplyThemeToAddressList(theme)` | — | Including `Header.Canvas.OnChange`. |
| `ui:ApplyThemeToMainForm(theme)` | — | |
| `ui:ApplyThemeToAddressRecords(theme)` | — | Colour per record. |
| `ui:ApplyThemeToLuaEngine(theme)` | — | Calls the control function **twice**. |
| `ui:ApplyThemeToLuaEngineControls(le, theme)` | — | Sets the caption to `"[Manifold] Logger"`. |
| `ui:CreateOrUpdateLuaEngineExecutePanel(...)` | — | Replaces `btnExecute` with a colourable panel. |
| `ui:ApplyThemeToForms(theme, includeHidden)` | `table\|nil` | Delegates to `Manifold.Forms`. |
| `ui:ApplyThemeToTeleporter(teleporter, theme)` | — | |
| `ui:SetTeleporterControlColors(uiState, theme)` | — | Central place for every teleporter colour. |
| `ui:GetRecordColor(record, theme, str, int, flt)` | `number` | Decision order below. |
| `ui:AcquireThemeApplyLock(name)` | `string\|nil, table` | |
| `ui:ReleaseThemeApplyLock(token)` | — | |
| `ui:RGB2BGR(rgb)` / `ui:BGR2RGB(bgr)` | `number` | |

**Decision order in `GetRecordColor`:**

```
vtAutoAssembler          → Memrec.AutoAssembler.Color
IsAddressGroupHeader     → Memrec.AddressGroupHeader.Color
IsGroupHeader            → Memrec.GroupHeader.Color
OffsetCount == 0 and AddressString is not hex → Memrec.UserDefined.Color
ShowAsHex                → Memrec.HexValues.Color
string type              → Memrec.StringType.Color
integer type             → Memrec.IntegerType.Color
float type               → Memrec.FloatType.Color
otherwise                → Memrec.DefaultForeground.Color
```

### CE window tweaks

| Function | Description |
|---|---|
| `ui:InitializeForm()` | Compact mode, bevel off, sorting off, signature controls off, slogan/signature, theme. |
| `ui:EnableCompactMode()` / `DisableCompactMode()` / `ToggleCompactMode()` | `Panel5` + `Splitter1` |
| `ui:SetControlVisibility(name, visible)` / `ToggleControlVisibility(name)` | |
| `ui:HideSignatureControls()` / `ToggleSignatureControls()` | `CommentButton`, `advancedbutton` |
| `ui:DisableDragDrop()` | Removes the tree view's drag handlers. |
| `ui:DisableHeaderSorting()` | Removes `OnSectionClick`. |
| `ui:HideAddresslistBevel()` | `BevelOuter = "bvNone"` |
| `ui:RunInMainThread(fn)` | Wrapper with `pcall` + logging. |
| `ui:DeleteSubrecords(record)` | Deletes all child records. |
| `ui:InitializeTableMenu()` | Clicks `miTable` so its entries get populated. |

### Labels and text animations

| Function | Description |
|---|---|
| `ui:CreateSloganStr(text)` | Label `SLOGAN_STR`, Consolas 20 bold, centred. |
| `ui:DestroySloganStr()` | |
| `ui:CreateSignatureStr(str)` | Reuses the existing `lblSigned`. |
| `ui:HideSignatureStr()` | |
| `ui:UpdateTextLabel(name, text, props)` | Creates or updates a label on the main form. |
| `ui:DestroyTextLabel(name)` | |
| `ui:CreateOrUpdateLabel(parent, label, props)` | |
| `ui:CreateTimer(interval, callback)` | |
| `ui:StartTextAnimation(text [, config])` | Cycles through several effects. |
| `ui:ScrollText(text, interval, maxTicks)` | Marquee |
| `ui:TypingEffect(text, interval)` | Character by character |
| `ui:RevealEffect(text, interval)` | Placeholders → characters |
| `ui:GlitchText(text, interval)` | Random character swaps |
| `ui:MatrixReveal(text, interval)` | `#` → characters in random order |

`StartTextAnimation` configuration:

```lua
ui:StartTextAnimation("MANIFOLD", {
    animations = { "Typing", "Reveal", "Scrolling", "Matrix" },  -- "Glitch" also available
    interval = 100,
    minDuration = 5000,
    pauseBetweenAnimations = 1000,
})
```

### Theme creator

| Function | Description |
|---|---|
| `ui:InitializeThemeCreator()` | Opens the `[Manifold] Theme Creator` window (980 px wide). |
| `ui:CreateThemeCreatorForm()` | |
| `ui:CreateThemeInfoPanel(form, opts)` | Name/author/description |
| `ui:CreateListViewControl(form, opts)` | Token list with colour swatches |
| `ui:CreateTokenPreviewPanel(form, opts)` | Preview + copy buttons |
| `ui:CreateButtonPanel(form, opts)` | Apply / Export / Load |
| `ui:CreateThemeCreatorStatusBar(parent)` / `ui:SetThemeCreatorStatus(text)` | |
| `ui:PopulateListView(listView, tokenInputs)` | |
| `ui:RebuildImageList(listView [, colorsAndTokens])` | Redraws the colour swatches |
| `ui:GetColorsAndTokensFromListView(listView)` | |
| `ui:OnListViewDblClick(...)` / `ui:OnListViewSelectItem(...)` | |
| `ui:HandleColorSelection(item, token)` | Colour dialog |
| `ui:UpdateColorLabels(colorNum)` / `ui:UpdateSelectedToken(name)` | |
| `ui:CreateCopyButton(parent, targetLabel, topOffset)` | |
| `ui:SetupApplyButton(...)` / `SetupExportButton(...)` / `SetupLoadButton(...)` | |
| `ui:PromptThemeFile()` | `createOpenDialog`, filter `*.json` |
| `ui:LoadThemeData(path)` | File → table |
| `ui:NormalizeTheme(data)` | `{Name, Author, Description, Tokens}` with defaults |
| `ui:PopulateThemeUI(themeData, tokenInputs, name, author, desc)` | |
| `ui:CreateStyledLabel/Edit/Button(...)` | Thin wrappers around `Manifold.Forms` |
| `ui:SetFormsButtonHandler(button, handler)` | |

---

## Manifold.Teleporter

`Teleporter` — version 1.1.5. Dependencies: `logger`, `memory`, `customIO`, **`forms`**
(enforced). Additionally requires `utils` at runtime (for `GetTargetNoExt`).

### Configuration

| Section | Fields |
|---|---|
| `Transform` | `Symbol = "TransformPtr"`, `Offsets = {0x30, 0x34, 0x38}`, `ValueType = vtSingle` |
| `Waypoint` | `Symbol = "WaypointPtr"`, `Offsets = {0x00, 0x04, 0x08}`, `ValueType = vtSingle` |
| `Additional` | `Symbol = nil`, `Offsets = {0x00, 0x04, 0x08}`, `ValueType = vtSingle` |
| `Symbols` | `Saved = "SavedPositionFlt"`, `Backup = "BackupPositionFlt"` |
| `Settings` | `ValueType`, `PauseWhileTeleporting`, `AdjustYCoordinate`, `YCoordinateIndex`, `AdjustmentAmount` |
| other | `Saves = {}`, `SaveFileName = "Teleporter.%s.Saves.txt"`, `SaveMemoryRecordName = "[— Teleporter : Saves —] ()->"` |

### Memory access

| Function | Returns | Description |
|---|---|---|
| `teleporter:ResolveAddress(str, isPointer)` | `integer\|nil` | `isPointer` ⇒ `[str]+0` |
| `teleporter:ReadPositionFromMemory(symbol, offsets, isPointer, valueType)` | `table\|nil` | `{x, y, z}` |
| `teleporter:WritePositionToMemory(symbol, offsets, pos, isPointer, valueType)` | `boolean` | |
| `teleporter:CalculateSymbolOffsets()` | `table` | From `Settings.ValueType` |
| `teleporter:SetValueType(vt)` | — | Validated against the read/write tables |
| `teleporter:GetCurrentPosition()` | `table\|nil` | |
| `teleporter:GetSavedPosition()` | `table\|nil` | |
| `teleporter:GetBackupPosition()` | `table\|nil` | |

### Movement

| Function | Returns |
|---|---|
| `teleporter:SaveCurrentPosition()` | `boolean` |
| `teleporter:LoadSavedPosition()` | `boolean` |
| `teleporter:LoadBackupPosition()` | `boolean` |
| `teleporter:TeleportToCoordinates({x, y, z})` | `boolean` |
| `teleporter:TeleportToWaypoint()` | `boolean` |
| `teleporter:TeleportToSave(name)` | `boolean` |
| `teleporter:GetAdjustedTargetPosition(pos)` | `table\|nil` |
| `teleporter:LogDistanceTraveled(old, new)` | — |
| `teleporter:PauseGame()` / `ResumeGame()` | — |

### Categories

| Function | Returns | Description |
|---|---|---|
| `teleporter:NormalizeCategoryPath(input)` | `table` | Accepts a table or a string; separators `/`, `\`, `>`, `\|` |
| `teleporter:CategoryPathToText(path, includeDefault)` | `string` | Joins with `" / "`; empty ⇒ `"Default"` |
| `teleporter:GetSaveCategoryPath(save, includeDefault)` | `table` | Prefers `Categories`, falls back to `Category` |
| `teleporter:SetSaveCategoryPath(save, input)` | — | Writes both fields |
| `teleporter:AddSaveToCategoryTree(root, path, name)` | — | |
| `teleporter:BuildSaveHierarchy([filterFn])` | `table` | Author → category path → saves |

### Persistence

| Function | Returns | Description |
|---|---|---|
| `teleporter:EnsureTeleporterDir()` | `string\|nil` | |
| `teleporter:GetSaveFilePath()` | `string, string` | Full path and file name |
| `teleporter:SaveLookup()` | `table\|nil` | Data directory first, then the table file |
| `teleporter:WriteSavesToDataDir()` | `boolean` | |
| `teleporter:WriteSavesToTableFile()` | `boolean` | |
| `teleporter:PersistSaves(preferDataDir)` | — | |
| `teleporter:EnsureAuthorsAndCategories()` | — | Fills in missing fields, normalizes categories |
| `teleporter:GetAuthors()` | `table` | `name → author` |
| `teleporter:CountSaves()` | `number` | |
| `teleporter:GetCurrentAuthor()` | `string` | `USERNAME` / `USER` / `"Unknown"` |
| `teleporter:PrintSaves()` | — | Tree output to the log |

### Management

| Function | Returns |
|---|---|
| `teleporter:CreateSaveFromCurrentPosition([name, category, description])` | `boolean` |
| `teleporter:AddSave()` | `boolean` |
| `teleporter:DeleteSave([name])` | `boolean` |
| `teleporter:RenameSave(oldName, newName)` | `boolean` |
| `teleporter:DuplicateSelectedSave()` | `boolean` |
| `teleporter:UpdateSelectedSaveFromEditor()` | `boolean` |
| `teleporter:GenerateUniqueCopyName(base)` | `string` |
| `teleporter:CreateTeleporterSaves()` | — |
| `teleporter:ClearSubrecords(record)` | — |

### User interface

| Function | Description |
|---|---|
| `teleporter:InitTeleporterUI()` | Opens/focuses the window |
| `teleporter:EnsureUiState()` | Creates the UI state table; used by `Manifold.UI` for theming |
| `teleporter:RefreshUi([preserveSelection])` | Rebuilds the tree view |
| `teleporter:SetStatus(text)` | Status bar |
| `teleporter:ClearEditor()` | |
| `teleporter:LoadSaveIntoEditor(name)` | |
| `teleporter:GetSelectedSaveName()` / `SetSelectedSaveName(name)` | |
| `teleporter:TryGetEditorPosition()` | Reads X/Y/Z from the editor fields |
| `teleporter:GetSaveNameFromTreeNode(node)` | |
| `teleporter:OnThemeApplied(themeData)` | Reaction to a theme change |
| `teleporter:CreateMenuStrip/Header/StatusBar/TreePanel/EditorPanel/TreeContextMenu(...)` | UI construction |

---

## Developer modules

Directory `Manifold-Modules/Manifold.Modules/Manifold.Dev/` — not part of a normal table setup,
and listed in `.gitignore`, so these files are **not published to GitHub**. The reference below
documents the local working copy.

### Manifold.AssemblerLinter

| Function | Description |
|---|---|
| `AssemblerLinter:New()` | |
| `linter:Lint(rawText)` | Runs all five phases, returns a report. |
| `linter:PrintReport(report)` | |
| `linter:Use(plugin)` | Plugin: a function or a table with `Apply`/`Register`. |
| `linter:RegisterDirective(name, spec)` | |
| `linter:RegisterDirectiveAlias(alias, target)` | |
| `linter:RegisterArgType(typeName, fn)` | |
| `linter:Phase1_Lex(...)` … `Phase5_Gate(...)` | Callable individually. |

Configuration: `UnknownDirectiveAsWarning`, `RequireEnableDisableBlocks`, `BlockOnErrors`,
`WarnOnGlobalStarOps`.

### Manifold.Patcher

| Function | Description |
|---|---|
| `Patcher:New(version)` | |
| `patcher:Start(url)` | Compute the fingerprint + `CheckAndApply`. |
| `patcher:CheckAndApply(url [, bypass])` | Server exchange, user confirmation, application, rollback. |
| `patcher:RequestPatches(url)` | `internet.postURL` with `{version, fingerprint}`. |
| `patcher:ApplyPatch(patch)` / `NormalizePatch(patch)` | |
| `patcher:RevertPatches()` | |
| `patcher:ResolveTarget(patch)` | Finds the target record. |
| `patcher:PatchScript(target, value)` | Replaces script text (`DefaultScriptReplaceMode = "plain"`). |
| `patcher:CoerceAndSet(target, path, kind, value)` | Type conversion on assignment. |
| `patcher:TakeTableSnapshot(name [, opts])` / `GeneratePatchFromSnapshot(name, meta)` | Patch authoring |
| `patcher:CreateSnapshot(target, path)` / `ClearSnapshots()` | |
| `patcher:SerializeRecord(record)` / `BuildTableFingerprint()` / `GenerateTableHash()` | |
| `patcher:LoadConfig()` / `SaveConfig()` / `ApplyConfig(cfg)` / `GetConfigFilePath()` | `Manifold.Patcher.Config.json` |
| `patcher:TogglePatcher()` / `ToggleStrictTargetResolution()` | |

### Manifold.RTTI

| Function | Description |
|---|---|
| `RTTI:Init(opts)` | Options listed below. |
| `RTTI:DiscoverClasses(s, fl)` | Searches for `.?AV` class names. |
| `RTTI:ResolveVtablesForClass(s, fl, picked)` | |
| `RTTI:ScanInstancesForVtables(s, fl, vtables, picked)` | |
| `RTTI:GetClasses()` / `PrintClasses([moduleFilter])` | |
| `RTTI:FindClasses(query [, usePattern, maxPrint])` | |
| `RTTI:GetInstancesByName(className)` | |
| `RTTI:GetInstancesByAnyName(query [, usePattern])` | |
| `RTTI:DumpInstances(instances [, maxDump])` | |
| `RTTI:PrintInstancesForModule(moduleName [, maxClassesToScan])` | |
| `RTTI:ClearCache()` | |

Options for `Init`: `protection` (default `"*W*X*C"`), `alignment`, `scanAllMin`, `scanAllMax`,
`useDropdown`, `defaultClass`, `moduleFilter`, `cacheEnabled`, `yieldEvery`, `instanceScanMode`
(`"all" | "heap" | "private" | "writable"`), `instanceRangeMin`, `instanceRangeMax`,
`maxClasses`, `maxCOLs`, `maxVtables`, `maxInstances` (`0` = unlimited).
