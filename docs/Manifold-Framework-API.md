# Manifold Framework API Reference

Complete function reference for every module in
[`Manifold-Modules/Manifold.Modules/`](../Manifold-Modules/Manifold.Modules/).
Concepts, bootstrapping and flows are covered in [Manifold-Framework.md](Manifold-Framework.md).

Conventions used here:

- Functions with a leading `_` are internal helpers. They are documented because they are exposed
  through `registerLuaFunctionHighlight` and are needed when extending the modules, but they are
  not part of the stable API.
- Almost every module has `New(...)`, `GetModuleInfo()` and `PrintModuleInfo()`. Those three are
  described in detail only for the first module that has them. `Manifold.Trampolines` has no
  `PrintModuleInfo`, and `Manifold.Bootstrap` is a namespace with nothing to instantiate, so it
  has none of the three.
- Every production module declares itself to `Manifold.Bootstrap` when its file executes. Where a
  module still has a `CheckDependencies()` method, that method is now a single call into
  `Bootstrap.Resolve`. It returns `boolean, table`, meaning resolved plus the list of missing
  dependency names, and it loads nothing by itself while `Bootstrap.Settings.AutoLoad` is `false`,
  which is the default.
- A declared dependency comes in three kinds. One marked `required` makes `New()` refuse rather
  than come up half built. One marked `runtime` is documentation only, so it is never looked up
  during construction and never counts as missing. One with neither marker, written as
  `{ "name" }`, is called an optional dependency throughout this reference. It is looked up at
  construction, and a missing one leaves the module degraded but running.

## Contents

- [Manifold.Bootstrap](#manifoldbootstrap)
- [Manifold.Json](#manifoldjson)
- [Manifold.Logger](#manifoldlogger)
- [Manifold.CustomIO](#manifoldcustomio)
- [Manifold.Helper](#manifoldhelper)
- [Manifold.Utils](#manifoldutils)
- [Manifold.ProcessHandler](#manifoldprocesshandler)
- [Manifold.Memory](#manifoldmemory)
- [Manifold.State](#manifoldstate)
- [Manifold.AutoAssembler](#manifoldautoassembler)
- [Manifold.Callbacks](#manifoldcallbacks)
- [Manifold.AssemblerCommands](#manifoldassemblercommands)
- [Manifold.Trampolines](#manifoldtrampolines)
- [Manifold.Forms](#manifoldforms)
- [Manifold.UI](#manifoldui)
- [Manifold.Teleporter](#manifoldteleporter)
- [Developer modules](#developer-modules)

## Manifold.Bootstrap

`Bootstrap`, version 1.0.2. It requires nothing and declares nothing, because it is the framework
root and sits below `Manifold.Json`. It is a namespace rather than a class, so its functions are
dot-called and there is no instance to create. The published table lives in the global
`ManifoldBootstrap`.

The registry survives a reload. `CETrequire` re-executes a file on every call, so this module
keeps all of its state in one `_G` slot and mutates the published API table in place instead of
replacing it. A module that captured `local BOOTSTRAP = ...` stays valid after the core is
re-executed.

### Module registry

| Function | Returns | Description |
|---|---|---|
| `Bootstrap.Declare(spec)` | `table` | Called once at chunk scope by every module. `spec` is `{class, global, name, version, author, description, prefix, deps}`. Returns the descriptor that `Resolve` and `Ready` are given later. This is also the collision detector, since it runs on every execution of the module file. |
| `Bootstrap.Resolve(mod)` | `boolean, table` | The single dependency lookup for the whole framework. `required = true` raises out of `New()` with one legible message. `runtime = true` is documentation only and never gates or orders anything. |
| `Bootstrap.Ready(mod, instance)` | `table` | Closes `New()`. Emits exactly one line per module per generation, carrying the name and version. Info when every declared dependency was satisfied, Warning when the module came up degraded. |
| `Bootstrap.Register(key, spec)` | `table\|nil, string?` | Teaches the core about a module that is not in `KNOWN`, for example a `Manifold.Dev` tool or a fork. It never overwrites an existing entry and gets no position in the order of execution. |
| `Bootstrap.Configure(key, config)` | `table` | Stores the constructor config for a module so a lazy bring-up gets the configuration the cheat table intended. Call it before `Bootstrap.Boot()`. Returns `Bootstrap` for chaining. |

### Lookup and construction

| Function | Returns | Description |
|---|---|---|
| `Bootstrap.Require(path, class, force)` | `table\|nil, string?` | The sanctioned replacement for a bare `pcall(CETrequire, path)`. Skips the call entirely when the module table is already present, and turns a path typo into a real error. |
| `Bootstrap.Acquire(key, config)` | `table\|nil, string?` | Guarantees that `key` names a live, usable instance in `_G`, loading and constructing it only when it genuinely is not there. Lazy runtime call sites must use this instead of `Class:New()`. |
| `Bootstrap.Get(key)` | `table\|nil, string?` | The same read-first lookup as `Acquire`, named for the place it is used. |
| `Bootstrap.Contract(key, value, extra)` | `boolean, string?` | The usability half of validation. Does this value answer the calls its consumers make? |
| `Bootstrap.Validate(key, value, extra)` | `boolean, string?` | Contract plus identity. Is this global still a pristine instance of the module table loaded right now? The metatable test detects an instance orphaned by a re-executed chunk. |
| `Bootstrap.Verify(raise)` | `boolean, table` | Proves the order of execution. Every `ORDER` key exists in `KNOWN`, every `KNOWN` key appears in `ORDER` exactly once, and every non-runtime dependency sits earlier in `ORDER`. An order that passes cannot contain a load-time cycle. |
| `Bootstrap.Boot(options)` | `boolean, table` | Walks `Bootstrap.ORDER` and acquires every module. Entirely optional. `options` accepts `config`, `skip`, `only`, `after`, `stopOnError` and `verify` (default `true`). |
| `Bootstrap.Reload(key)` | `table\|nil, string?` | Forces one module through a full reload: drop the globals, re-require, reconstruct. The one supported way to reload during development. |

### Diagnostics

| Function | Returns | Description |
|---|---|---|
| `Bootstrap.Once(key, fn)` | `boolean` | Runs `fn` at most once per session, latched in the registry so a re-executed module file cannot reset it. For load-time side effects that must not stack. |
| `Bootstrap.Flush()` | `integer` | Replays every line queued before a logger existed, oldest first. Safe to call at any time. |
| `Bootstrap.WriteManifest()` | `integer` | Re-writes the manifest of every module that has announced so far into the log file. Call it once, immediately after `logger:ClearLogFile()`, and never at any other point. |
| `Bootstrap.Report()` | `table` | Everything the registry knows. Two rows with the same name and different sources is a collision you can act on. |
| `Bootstrap.PrintReport()` | | Logs the report, one entry per module, through `Logger:BuildBlock`. An on-demand diagnostic, deliberately outside the one-line-per-module rule. Falls back to its own renderer when no logger exists yet. |
| `Bootstrap.GetModuleInfo()` / `PrintModuleInfo()` | `table` / | The usual metadata pair, dot-called. |

### Fields

| Field | Description |
|---|---|
| `Bootstrap.KNOWN` | The single source of truth for how a module is found and built: `path`, `class`, `construct`, an optional `contract` predicate and `rebuild`. |
| `Bootstrap.ORDER` | The order of execution as a linear array. Every load-time edge points strictly backwards in it. |
| `Bootstrap.Settings` | `ReadyLevel` (default `"Info"`), `DegradedLevel` (`"Warning"`), `ReloadLevel` (`"Warning"`), `ConflictLevel` (`"Error"`) and `AutoLoad` (`false`). |
| `Bootstrap.Registry` | The reload-surviving registry table itself. |
| `Bootstrap.SOURCE` | Short source name of the chunk that loaded the core. |

```lua
Bootstrap.ORDER = {
    "json", "logger", "customIO", "helper", "memory", "forms",
    "processHandler", "ui", "utils", "state", "trampolines",
    "assemblerCommands", "autoAssembler", "teleporter", "callbacks",
}
```

Two constraints in that order are hand-injected rather than produced by the topological pass.
`logger` comes before `customIO` because CustomIO's json-miss path indexes the logger unguarded,
and `callbacks` is last because its chunk binds Cheat Engine handlers at load time.

`AutoLoad` is `false` by default, which means `Bootstrap.Resolve` never loads anything. A missing
dependency is reported, and when it is `required` the constructor refuses. The cheat table's Lua
script therefore stays the single source of truth for what is loaded and in what order. Setting
`AutoLoad` to `true` restores the older behaviour where a module silently pulled in whatever it
was missing. The flag gates the implicit path only. `Bootstrap.Acquire` and `Bootstrap.Get` are
explicit lookups and always load.

## Manifold.Json

`Json`, version 1.0.2. Self-contained encoder and decoder written for the framework. It replaced
the vendored Jeffrey Friedl implementation in 1.0.0. The logger is declared as a runtime
dependency, not a load-time one, because this module is position 1 in `Bootstrap.ORDER` and is
built before any logger can exist. Every log site in the file is guarded and resolves the global
at call time.

The global is `Json`, the instance global is `json`, and `JSON` is kept as an alias of `Json` so
call sites written against the previous module keep working.

### Construction and metadata

| Function | Returns | Description |
|---|---|---|
| `Json:New()` | `Json` | Tolerates `Json.New()` as well as `Json:New()`. A missing `self` falls back to the module table instead of producing an orphan without a metatable. |
| `Json:CheckDependencies()` | `boolean, table` | The same single call into `Bootstrap.Resolve` that its siblings make. Records whether diagnostics are live. It can never refuse, because its one declared dependency is the runtime `logger` and a runtime dependency is never looked up here. |
| `Json:GetModuleInfo()` | `table` | `{ name, version, author, description }` |
| `Json:PrintModuleInfo()` | | Prints through `logger:Info` when a logger exists, and through `print` when one does not. |

### Public API

Every entry point is call-style agnostic. `Json.Encode(v)`, `Json:Encode(v)`, `instance:Encode(v)`
and a detached `local f = json.Encode` all behave identically. There is no "must be called in
method format" guard anywhere in the module. An options table is accepted in either the second or
the third argument slot, so the legacy `(value, etc, options)` shape still works.

| Function | Returns | Description |
|---|---|---|
| `Json.Encode(value [, options])` | `string\|nil, string\|nil` | Compact JSON, or `nil` plus the error message. |
| `Json.EncodePretty(value [, options])` | `string\|nil, string\|nil` | Indented, human readable JSON. Used by `CustomIO:WriteToFileAsJson`. |
| `Json.Decode(text [, options])` | `any\|nil, string\|nil` | JSON null becomes `Json.Null` so it survives inside tables. Pass `{ Null = false }` to drop null members instead. |
| `Json.Validate(text [, options])` | `boolean, string\|nil` | Decodes quietly. A rejection is the normal outcome here, so it does not fire the usual failure report. Set `Json.Debug` to see rejections. |
| `Json.Minify(text [, options])` | `string\|nil, string\|nil` | Re-encodes JSON text without whitespace. |
| `Json.Prettify(text [, options])` | `string\|nil, string\|nil` | Re-encodes with indentation. Turns `RecordKeyOrder` on for the decode half unless the caller set it. |
| `Json.NewArray(t)` | `table` | Tags a table so it always encodes as a JSON array, even when empty. |
| `Json.NewObject(t)` | `table` | Tags a table so it always encodes as a JSON object, even when empty. |
| `Json.IsNull(v)` | `boolean` | Is this value the JSON null sentinel? |
| `Json.IsArray(v)` | `boolean` | Does this table carry the explicit array marker? |
| `Json.IsObject(v)` | `boolean` | Does this table carry the explicit object marker? |
| `Json.SetDebug(enabled)` | `boolean` | Enables or disables per-call diagnostics and returns the resulting state. |

### Fields

| Field | Default | Description |
|---|---|---|
| `Json.Debug` | `false` | Opt-in per-call summaries. Off costs one field read per public call. |
| `Json.ExcerptBytes` | `96` | Bytes of the offending input quoted next to a decode failure. `0` quotes nothing. |
| `Json.Null` | | The immutable sentinel used for JSON null. `tostring` gives `"null"`. |
| `Json.Defaults` | | Mutable module-wide defaults, listed below. Per-call options always win. |
| `Json.VERSION` | `"1.0.1"` | |

Option keys are matched case-insensitively and ignore underscores, so `SortKeys`, `sortkeys` and
`sort_keys` all address the same setting.

```lua
Json.Defaults = {
    -- Encoding ------------------------------------------------------------
    Indent             = "  ",     -- string, or a number of spaces
    SortKeys           = nil,      -- nil = sort in pretty mode only
    PreserveOrder      = true,     -- honour a decoded key order when present
    EmptyTable         = "object", -- "object" | "array"
    SparseArray        = "null",   -- "null" | "object" | "error"
    MaxSparseRatio     = 8,        -- fall back to "object" beyond this density
    EscapeUnicode      = false,    -- emit non-ASCII as \uXXXX
    EscapeSlash        = false,    -- emit "/" as "\/"
    InvalidNumber      = "error",  -- NaN/Infinity: "error" | "null" | "string"
    InvalidValue       = "error",  -- functions/userdata: "error" | "null" | "skip"
    InvalidKey         = "error",  -- unusable table keys: "error" | "skip"
    MaxDepth           = 200,
    NullValue          = nil,      -- extra value to treat as null on encode
    -- Decoding ------------------------------------------------------------
    Null               = Null,     -- value produced for JSON null
    MarkTables         = true,     -- tag decoded tables as array/object
    RecordKeyOrder     = false,    -- remember object key order for round-trips
    AllowComments      = false,    -- // line and /* block */ comments
    AllowTrailingComma = false,
    AllowSingleQuotes  = false,
    AllowUnquotedKeys  = false,
    AllowTrailingData  = false,
    AllowDuplicateKeys = true,
    BigIntAsString     = false,    -- integers beyond int64 stay exact as strings
    UnpairedSurrogate  = "replace",-- "replace" | "error" | "raw"
    Lenient            = false,    -- enables the whole Allow* group at once
}
```

### Compatibility layer

| Alias | Target |
|---|---|
| `Json.new` | `Json.New` |
| `Json.encode` | `Json.Encode` |
| `Json.encode_pretty` | `Json.EncodePretty` |
| `Json.decode` | `Json.Decode` |
| `Json.newArray` | `Json.NewArray` |
| `Json.newObject` | `Json.NewObject` |
| `Json.null` | the null sentinel |
| `JSON` | `Json` |

Handle decode failures without raising:

```lua
local value, err = json:decode(text)
if not value then logger:Error(err) end
```

Encoding and decoding no longer verify `self.__index == JSON`, so an instance created before a
module reload keeps working
([TODO T7](TODO.md#t7-json-instances-do-not-survive-a-module-reload), resolved).

## Manifold.Logger

`Logger`, version 1.2.0. A framework leaf with no declared dependencies, and since 1.2.0 that is
true of the file half as well: it reaches `lfs` and `io` directly rather than borrowing `customIO`.
That is what removed the mutual recursion
([TODO T23](TODO.md#t23-logger-and-customio-can-recurse-without-bound), resolved). Without `lfs`
the module degrades to console output only.

### Construction and metadata

| Function | Returns | Description |
|---|---|---|
| `Logger:New()` | `Logger` | Sets `Level = Levels.ERROR`, `Output = print`, `DataDir = %USERPROFILE%\AppData\Local\Manifold`, `LogFileName = "Manifold.Runtime.Unknown.log"` and `FileLogging = true`. |
| `logger:GetModuleInfo()` | `table` | `{ name, version, author, description }` |
| `logger:PrintModuleInfo()` | | One `InfoBlock`. Every module in the framework uses this same shape. |

### Fields

| Field | Default | Description |
|---|---|---|
| `Level` | `Levels.ERROR` (4) | Minimum level for console output |
| `Levels` | `{DEBUG=1, INFO=2, WARNING=3, ERROR=4, CRITICAL=5}` | |
| `LevelNames` | Reverse map of `Levels` | |
| `Output` | `print` | Target function for console output |
| `DataDir` | `%USERPROFILE%\AppData\Local\Manifold` | Its own copy, independent of `customIO.DataDir` |
| `LogFileName` | `Manifold.Runtime.Unknown.log` | Relative to `DataDir\Logs` |
| `FileLogging` | `true` | While `false` nothing touches the disk. A failed write sets it. |
| `FileLogError` | `nil` | Why disk logging was switched off, when it was. |

### Configuration

| Function | Description |
|---|---|
| `logger:SetLevel(level)` | Accepts a number or a name such as `"INFO"`. An unknown name gives `Levels.INFO`. A real change is reported through `ForceInfo`, a no-op change through `Info`. |
| `logger:SetLogFileName(name)` | Produces `Manifold.Runtime.<name>.log`. An empty or `nil` name gives `Manifold.Runtime.Unknown.log`. |
| `logger:SetOutput(fn)` | Passing `nil` restores `print`. |
| `logger:ClearLogFile()` | Truncates the file by opening it with `"w"` and closing it immediately. |

### Disk failures

The file half switches itself off rather than retrying. The first failed write, whether the data
directory cannot be created or the file cannot be opened, sets `FileLogging = false`, records the
reason in `FileLogError` and reports it once through `ForceWarning`. Nothing after that touches the
disk. The console and `Output` keep working.

That matters because the failure case is an end-user machine where
`%USERPROFILE%\AppData\Local\Manifold\Logs` cannot be written. Without the switch every log line
paid for a directory check and an open attempt, and `customIO` reported each failure through this
same logger, which tried to write it to the file that could not be written
([TODO T23](TODO.md#t23-logger-and-customio-can-recurse-without-bound)).

| Function | Returns | Description |
|---|---|---|
| `logger:DisableFileLogging(reason)` | | Switches the disk off for the session and reports it once. |
| `logger:EnableFileLogging()` | | Switches it back on and forgets the cached directory state. |
| `logger:GetFileLoggingState()` | `boolean, string\|nil` | Whether the disk is live, and why it is not. |

One retry sits inside the write itself: an open that fails re-checks the directories once and tries
again, which covers the log folder being deleted while Cheat Engine is running. The second failure
is the one that switches the disk off.

### Output

For each level `Debug`, `Info`, `Warning`, `Error` and `Critical`, four functions are generated at
load time:

| Pattern | Example |
|---|---|
| `logger:<Level>(msg)` | `logger:Info("ready")` |
| `logger:<Level>F(fmt, ...)` | `logger:InfoF("%d/%d", a, b)` |
| `logger:Force<Level>(msg)` | `logger:ForceError("critical")` |
| `logger:Force<Level>F(fmt, ...)` | `logger:ForceWarningF("%s", x)` |
| `logger:<Level>Block(title, rows [, options])` | `logger:InfoBlock(MODULE_PREFIX .. " Scan Result", { { "Status", "OK" } })` |
| `logger:Force<Level>Block(title, rows [, options])` | `logger:ForceWarningBlock(title, rows)` |

The `Force` variants bypass the level filter and tag the line with `[FORCED]`.

| Function | Description |
|---|---|
| `logger:Log(level, message)` | Direct variant, honours `Level`. |
| `logger:ForceLog(level, message)` | Direct variant without filtering. |
| `logger:BuildBlock(title, rows [, options])` | Renders a block without logging it. Pure, so it can be tested and reused. |

### Blocks

A multi-row report written as N separate calls repeats the timestamp and the module prefix on every
row, which is most of the line width. `BuildBlock` renders the whole report as one string, so it
becomes a single log entry with one prefix and labels that align themselves.

```lua
logger:InfoBlock(MODULE_PREFIX .. " InstallDetour OK", {
    { "Name",         entry.Name },
    { "Relay Offset", string.format("%s+%X", moduleName, offset) },
    condition and { "Dest Address", address } or false,
})
```

```
[19:48:29] [INFO] [Trampolines] InstallDetour OK
   Name         : Player
   Relay Offset : gamedll_x64_rwdi.dll+500
```

- Rows are `{ label, value }` pairs, or a plain string for a line without a label.
- Use `false` to skip a row. A bare `nil` cuts the block short, because the walk is an `ipairs` and
  stops at the first hole.
- Values run through `Stringify`, and a value containing newlines hangs under its own label.
- `options`: `indent` (default `"   "`), `separator` (default `" : "`), `align` (default `true`).
| `logger:Stringify(value [, processed])` | Recursive text representation. A cycle becomes `{...}` and a null byte becomes `\0`. |

Format: `[HH:MM:SS] [LEVEL] [FORCED] <message>`

### Internal helpers

| Function | Description |
|---|---|
| `logger:_GetLogsDirectory()` | `DataDir\Logs` |
| `logger:_GetLogFilePath()` | `DataDir\Logs\<LogFileName>` |
| `logger:_EnsureLogDirectories()` | Creates `DataDir` and `Logs` through `lfs`, once. The answer is cached in `_DirReady`, which `SetLogFileName`, `EnableFileLogging` and a failed write clear. |
| `logger:_AppendToLogFile(text)` | The append itself. Raises on failure. |
| `logger:_WriteToLogFile(text)` | Appends one line, guarded by `FileLogging`, the `_InFileWrite` reentrancy latch and a `pcall`. A raise here switches the disk off rather than escaping to the caller. |
| `logger:_ResolveLevel(level)` | Turns a level into `name, id`. |
| `logger:_FormatLogMessage(name, msg, forced)` | Builds the output line. |
| `logger:_DispatchLog(level, msg, forced)` | Central output. It writes to the file first and filters afterwards, so every emitted line costs file access whatever level it carries. That is deliberate ([TODO T10](TODO.md)), and it is the reason a module reports once with a block rather than several times with lines. |

## Manifold.CustomIO

`CustomIO`, version 1.0.5. Dependencies: `logger` and `json`, both required.

| Function | Returns | Description |
|---|---|---|
| `CustomIO:New()` | `CustomIO` | Calls `CheckDependencies()` and sets `DataDir`. |
| `customIO:CheckDependencies()` | `boolean, table` | Reports missing dependencies. It loads nothing. |

### Directories

| Function | Returns | Description |
|---|---|---|
| `customIO:DirectoryExists(dir)` | `boolean` | via `lfs.attributes` |
| `customIO:CreateDirectory(dir)` | `boolean, string?` | `lfs.mkdir`. An already present directory gives `true`. |
| `customIO:EnsureDirectoryExists(path)` | `boolean` | Check and create, not recursive |
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
| `customIO:AppendToFile(path, data)` | `boolean, string?` | Appends and adds `\n` |

### JSON

| Function | Returns | Description |
|---|---|---|
| `customIO:ReadFromFileAsJson(path)` | `table\|nil, string?` | |
| `customIO:WriteToFileAsJson(path, data)` | `boolean, string?` | Uses `json:encode_pretty` |

### CSV

| Function | Returns | Description |
|---|---|---|
| `customIO:ReadCSV(path)` | `table\|nil, string?` | Turns lines into arrays. There is no quoting support, and empty fields are lost. |
| `customIO:WriteCSV(path, data)` | `boolean, string?` | `table.concat(row, ",")` per line, no escaping. |

### Cheat Engine table files

| Function | Returns | Description |
|---|---|---|
| `customIO:ReadFromTableFile(name)` | `string\|nil, string?` | Reads an embedded file. |
| `customIO:WriteToTableFile(name, text)` | `boolean` | Creates it on demand and overwrites completely. |
| `customIO:ReadFromTableFileAsJson(name)` | `table\|nil, string?` | |
| `customIO:WriteToTableFileAsJson(name, data)` | `boolean` | Uses `json:encode`, so the output is compact. |

`ReadFromTableFile` internally uses `string.char(table.unpack(bytes))`. Very large table files can
exceed Lua's stack limits ([TODO T12](TODO.md#t12-reading-table-files-does-not-scale)).

## Manifold.Helper

`Helper`, version 1.1.1. It declares `logger` as an optional dependency. Since 1.1.0 the module is
narrowed to one goal, read-only facts about the target process's main loaded module, and
everything it says is derived from `enumModules()[1]`.

| Function | Returns | Description |
|---|---|---|
| `helper:GetGameModule()` | `table\|nil` | `enumModules()[1]`, guarded, so the module stays loadable outside Cheat Engine |
| `helper:GetGameModuleIs64Bit()` | `boolean\|nil` | `nil` only when there is no module. A 32-bit target gives `false`. |
| `helper:GetGameModuleName()` | `string\|nil` | |
| `helper:GetGameModulePathToFile()` | `string\|nil` | Full path to the executable |
| `helper:GetGameModuleAddress()` | `integer\|nil` | Module base |
| `helper:GetRegistrySizeStr()` | `string` | `"(x64)"` or `"(x32)"` |
| `helper:GetFileVersionStr([path])` | `string\|nil` | `"major.minor.release.build"` read through `getFileVersion`. Defaults to the module's own `PathToFile`. |

### Deprecated

These three describe the Cheat Engine `process` global, which belongs to
`Manifold.ProcessHandler`. All three still answer. `IsProcessAvailable` and `GetProcessTrimmed`
delegate to the process handler when it is loaded and run their original bodies when it is not.
`GetProcess` never delegates, because its whole body is a return of the `process` global. They
will be removed in Helper 2.0.0.

| Function | Returns | Description |
|---|---|---|
| `helper:GetProcess()` | `string` | The CE global `process`. Use `processHandler:GetAttachedProcessName()`. |
| `helper:IsProcessAvailable()` | `boolean` | Use `processHandler:IsProcessAttached()`. |
| `helper:GetProcessTrimmed()` | `string\|nil` | Without `.exe`. Use `processHandler:GetAttachedNameNoExt()`. |

## Manifold.Utils

`Utils`, version 1.1.1. `logger` is required. `customIO`, `helper`, `memory` and `ui` are runtime
dependencies, so a table is entitled not to load them.

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
    AutoDisableWaitTimeout   = 5000,
    IsRelease  = false,
})
```

### Target and title

| Function | Returns | Description |
|---|---|---|
| `utils:GetTarget()` | `string\|nil` | `nil` when `Target` is empty, not merely when it is unset |
| `utils:GetTargetNoExt()` | `string\|nil` | via `customIO:StripExt`, with a plain pattern fallback when CustomIO is absent |
| `utils:GetTitleComponents()` | `table` | `{tableTitle, tableVersion, gameVersion, registrySizeStr, ceRegistrySizeStr, ceVersion}`. `gameVersion` falls back from `AppVersion` to `helper:GetFileVersionStr()`. |
| `utils:FormatTitle(components)` | `string` | `"%s %s V:%s — CET V:%s — CE %s V:%s"` |
| `utils:SetTitle()` | | Sets `getMainForm().Caption`. |
| `utils:InitializeTable()` | | `ui:InitializeForm()` followed by `SetTitle()`. Called by the process handler. |

### Dialogs

| Function | Returns |
|---|---|
| `utils:ShowInfo(msg)` | |
| `utils:ShowWarning(msg)` | |
| `utils:ShowError(msg)` | |
| `utils:ShowConfirmation(msg)` | `boolean` |

All of them synchronize into the main thread on their own.

### Checks

| Function | Returns | Description |
|---|---|---|
| `utils:VerifyFileHash()` | `boolean` | Compares `md5file(helper:GetGameModulePathToFile())` against `MD5Hash` and warns on a mismatch. It does not block. |
| `utils:EnsureCompatibleCEVersion(required, closeOnFail)` | | `required` must be a number and the comparison against `getCEVersion()` is exact. With `closeOnFail = true` a mismatch calls `closeCE()`. |

### Records and scripts

| Function | Description |
|---|---|
| `utils:AutoDisable(id [, interval])` | Deactivates the record with `id` after `interval` ms, defaulting to `AutoDisableTimerInterval`. Both waits for `AsyncProcessing` are bounded by `AutoDisableWaitTimeout`, and a timeout logs a warning and deactivates anyway. |
| `utils:SetAllScriptsToAsync()` | Sets `Async = true` on every `vtAutoAssembler` record. |
| `utils:SetAllScriptsToNotAsync()` | The inverse. |
| `utils:RemoveTableFilesByExtension(ext)` | Opens `miTable` and deletes every table file whose caption contains `ext`, defaulting to `".lua"`. For release builds. |
| `utils:ExecuteTableLuaScript()` | Finds the form `"Lua script: Cheat Table"` and clicks `btnExecute`. |

### Memory

| Function | Returns | Description |
|---|---|---|
| `utils:ResolvePointerPath(base, offsets [, isLocal])` | `integer\|nil` | Deprecated in Utils 1.1.0 and moved to `Manifold.Memory`. It forwards to `memory:ResolvePointerPath` and logs an error when that module is not loaded. It will be removed in 2.0.0. |

### Custom value types

| Function | Type | Bytes |
|---|---|---|
| `utils:RegisterTimeTypes()` | `Military Hours` | 4 |
| `utils:RegisterDecryptionType()` | `Decrypted` | 16 |
| `utils:RegisterPlaytimeMilitaryType()` | `Playtime Float` | 8 |

Each of the three returns early when the type is already registered.

### Miscellaneous

| Function | Description |
|---|---|
| `utils:OpenLuaEngineWindow()` | `getLuaEngine() or createLuaEngine()` followed by `Show()` |

## Manifold.ProcessHandler

`ProcessHandler`, version 2.0.0. `logger` is required and `utils` is a runtime dependency.
`New(config)` copies every key of `config` onto the instance.

The module does four things and nothing else: wait for the process, attach to it, watch it, and
start over when it dies.

### The one true signal

Cheat Engine offers three ways to answer "is the process there", and two of them lie:

| Call | Behaviour |
|---|---|
| `getOpenedProcessID()` | Keeps reporting the PID of a process that has exited |
| `getProcessIDFromProcessName(name)` | Keeps serving that PID from a cached list, so an exited game is still "found" and `openProcess` still succeeds on it |
| `readInteger(process)` | Tracks reality |

So the first two are used only to **find** a candidate; a read is what **confirms** one. An attach is
never reported until the read succeeds, which is what stops the handler from talking to a corpse.

### Fields

| Field | Default | Description |
|---|---|---|
| `ProcessName` | `nil` | Target process |
| `AutoAttachTimerInterval` | `1000` | ms between attach attempts |
| `ProcessWatchTimerInterval` | `1000` | ms between liveness reads |
| `LivenessFailureThreshold` | `2` | Consecutive failed reads before the process counts as gone |
| `SamePidLossLimit` | `3` | Quick losses of the same PID in a row before auto-restart gives up |
| `QuickLossSeconds` | `10` | A session shorter than this counts as a quick loss |
| `AttachedProcessName` / `AttachedProcessID` | `nil` | Set once an attach is confirmed |
| `IsAutoAttaching` / `IsWatchingProcess` | `false` | Which timer is live |
| `Disarmed` | `false` | Set when auto-restart has stopped itself |
| `AutoAttachOptions` | `nil` | The options last passed in |

### Attaching

| Function | Returns | Description |
|---|---|---|
| `processHandler:AutoAttach(name [, options, internalRestart])` | `boolean` | Starts the waiting timer. `options` may be a number, meaning a timeout in seconds, or a table of `{ maxSecs, runPostAttachTasks, onAttached }`; `maxSeconds` and `timeoutSeconds` are aliases of `maxSecs`. `internalRestart` is used by the loss handler and is refused while disarmed, so only an explicit call re-arms recovery. |
| `processHandler:AttachToProcessByName(name)` | `boolean` | Attaches right now, without waiting. Refuses a PID that does not answer a read. |
| `processHandler:AttachToProcess(name [, pid, options])` | `boolean` | The same for a known PID; falls back to the name when `pid` is nil. |
| `processHandler:ResolveProcessName([name])` | `string\|nil` | Falls back to `ProcessName`, then `AttachedProcessName`, and stores the result. |
| `processHandler:Stop()` | | Stops both timers and retires the watch epoch. |

```lua
processHandler:AutoAttach("Game.exe", {
    maxSecs            = 60,        -- 0/nil = unlimited
    runPostAttachTasks = true,      -- false = leave UI/title alone
    onAttached = function(handler, name, pid)
        logger:InfoF("Attached to %s (%d)", name, pid)
    end,
})
```

### Status

| Function | Returns | Description |
|---|---|---|
| `processHandler:IsProcessAttached()` | `boolean` | Did `readInteger(process)` succeed? |
| `processHandler:IsAttachedProcessAvailable()` | `integer\|nil` | The raw probe value |
| `processHandler:GetAttachedProcessName()` | `string\|nil` | |
| `processHandler:GetAttachedNameNoExt()` | `string\|nil` | The attached name without its `.exe` extension |

### Cleanup

| Function | Description |
|---|---|
| `processHandler:DisableAllWithoutExecute()` | `AddressList.disableAllWithoutExecute()` plus `deleteAllRegisteredSymbols()`. The disable scripts cannot run: their process is gone. |
| `processHandler:ResetProcessBoundState(reason)` | `autoAssembler:Reset()`, `assemblerCommands.ActivePatches = {}` and `trampolines:Reset()`, each only when that module is loaded. |
| `processHandler:PerformPostAttachTasks()` | `utils:InitializeTable()` and, when `utils.VerifyMD5` is set, `utils:VerifyFileHash()`. Both guarded, since `utils` is a runtime dependency. |

### Watch epochs

Watch state is keyed by an epoch counter in `_G.__ManifoldProcessHandlerEpoch`, not on the instance.
Reloading a cheat table re-runs the module and builds a new handler, but the timers and threads of
the previous one keep running; a counter on the instance could never retire those, and every
surviving watcher then ran its own cleanup when the game exited. Every timer and thread carries the
epoch it was born under and exits as soon as that epoch is gone. Loading the file opens a new epoch,
and so does `Stop()`.

A background thread backs the watch timer up, for hosts where Cheat Engine stops dispatching TTimer
events. It stays quiet while the timer is demonstrably still ticking, so the two never race, and it
runs the same check.

### Giving up

Losing the same PID `SamePidLossLimit` times in a row, each within `QuickLossSeconds` of attaching,
means the reattach is not recovering anything. The handler stops restarting itself and reports once
rather than tearing the table down every few seconds. A session that lasted longer than
`QuickLossSeconds` was a normal one and resets the count. `processHandler:AutoAttach(name)` re-arms.

### Miscellaneous

| Function | Description |
|---|---|
| `processHandler:CloseProcess()` | Asks for confirmation and terminates the process via `taskkill /PID <pid> /F`. |
| `processHandler:OpenLink(url)` | Asks for confirmation and opens the URL via `ShellExecute`. Used by cheat tables for `steam://run/<appid>`. |


## Manifold.Memory

`Memory`, version 1.1.1. `logger` is required.

`Memory.LogSuccessfulOperations` defaults to `false`. Every read, write and add used to emit an
Info line, and because the logger writes the file before it applies the level filter, a script
polling a value each frame produced file access every frame. Turn the flag on only while
diagnosing a specific access.

### Generated type functions

For `Byte`, `Word`, `Integer`, `QWord`, `Float` and `Double`:

| Function | Returns |
|---|---|
| `memory:SafeRead<Type>(address [, signed])` | `number\|nil` |
| `memory:SafeWrite<Type>(address, value)` | `boolean` |
| `memory:SafeAdd<Type>(address, value [, signed])` | `boolean` |

`signed` only applies to `Word` and `Integer`, which are the two types flagged `supportsSigned`.

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
| `memory:SafeGetAddress(addressOrSymbol [, isLocal])` | `integer\|nil` | A number is returned unchanged, and a negative one gives `nil`. A string goes through `getAddressSafe(s, isLocal)`. An empty string is rejected. |
| `memory:ResolvePointerPath(base, offsets [, isLocal])` | `number\|nil` | Follows the chain, reading a pointer and adding one offset per step. `base` may be a symbol or a number. Moved here from `Manifold.Utils` in Memory 1.1.0. |

`ResolvePointerPath` treats a null pointer mid-chain as a failure rather than an address, so an
object the game has not allocated yet no longer produces a plausible-looking low address. On
failure it logs the chain it walked, so the broken hop is answerable from one log line. On success
it logs nothing. It returns one value deliberately, because a second return would leak into every
multi-value context.

### Internal helpers

| Function | Description |
|---|---|
| `memory:_IsNumber(v)` / `_IsOptionalBoolean(v)` | Type checks, where NaN counts as a non-number |
| `memory:_FormatAddress(addr)` | `"0x%08X"` |
| `memory:_RequireAddress(addr, fnName)` | Resolve and validate |
| `memory:_RequireNumber(v, fnName, param)` | |
| `memory:_RequireSignedFlag(v, fnName)` | |
| `memory:_ReadResolvedValue(addr, typeInfo, signed)` | |
| `memory:_WriteResolvedValue(addr, value, typeInfo)` | |
| `memory:_SafeReadValue` / `_SafeWriteValue` / `_SafeAddValue` | Shared implementation |
| `memory:_LogReadFailure` / `_LogWriteFailure` | Error messages |

## Manifold.State

`State`, version 1.1.1. `logger` and `customIO` are required, and `processHandler` is a runtime
dependency. Since 1.0.5 every Cheat Engine access is main-thread synchronized.

| Function | Returns | Description |
|---|---|---|
| `State:New()` | `State` | Creates `TableStateDir`. |
| `state:EnsureStateDirectory()` | `string\|nil` | `DataDir\State` |
| `state:GetStateFilePath(name)` | `string\|nil` | `…\Manifold.<name>.<Process>.State` |
| `state:GetIndexedAddressList()` | `table, table` | An indexed list and an id-keyed list of all records |
| `state:SaveTableState(name)` | `boolean` | Saves active records and records with hotkeys. With neither present it returns `false` plus a warning. |
| `state:LoadTableState(name)` | `boolean` | Reads the file and calls `RestoreState`. |
| `state:RestoreState(stateData)` | `table` | `{activatedCount, deactivatedCount, unchangedCount, failedCount}`. Exclusive, so records not listed get deactivated. Reports the whole run as one log entry. |
| `state:RestoreOriginalState()` | `table` | Deactivates everything that is active. Reports as one entry too. |
| `state:FormatRestoreReport(stateOutcomes, hotkeyOutcomes, stats [, title])` | `table` | `{ Lines, Summary }`. Pure, so the layout can be tested without the logger. The summary names only the counters present in `stats`, so an operation that cannot activate anything does not report `0 activated`. |

A restore touching forty records used to produce forty log entries, each with its own timestamp and
module prefix, all inside the same second. It is now one entry, grouped by outcome, with the record
ids and the async durations in columns:

```
[13:14:22] [INFO] [State] Restore complete — 36 activated, 0 deactivated, 386 unchanged, 0 failed
   Activated
        47  [— State : Save —]
       106    Manifold.Activation       2360 ms
       475  [— CET : Scripts —]
       751    Manifold.Teleporter       1375 ms
      1503  [— Player : Weapon —]
      1523    Disable : Recoil           391 ms
   Hotkeys
      2118    Manifold.Debug            1 restored
```

Group headers stay flush left and everything else indents under them, so the block mirrors the
address list. Records that did not change are counted in the summary rather than listed; there are
usually hundreds of them. Sections appear only when they have rows, so a clean restore shows
`Activated` and nothing else.
| `state:RestoreOriginalState()` | `table` | Deactivates everything, iterating backwards. Returns `{deactivatedCount, unchangedCount, failedCount}`. |
| `state:SetMemoryRecordState(mr, state [, timeoutMs])` | `boolean` | The default timeout for async records is 10,000 ms. |
| `state:WriteStateFile(path, data)` | `boolean` | |
| `state:ReadStateFile(path)` | `table\|nil` | |
| `state:CheckDependencies()` | `boolean, table` | |

### Internal helpers

| Function | Description |
|---|---|
| `state:_BuildStateRecord(rec)` | Condenses a list entry, returning `nil` when the record is inactive and has no hotkeys. |
| `state:_SetMemoryRecordStateOnMainThread(mr, state, timeoutMs)` | Sets `Active`, waits for `AsyncProcessing` and returns an outcome object. |
| `state:_LogMemoryRecordStateOutcome(outcome)` | Evaluates the outcome object. |
| `state:_RestoreHotkeysOnMainThread(mr, hotkeys)` | Destroys all hotkeys and recreates them. |

Outcome object from `_SetMemoryRecordStateOnMainThread`:

```lua
{ success, changed, state, record, active, async, asyncProcessing,
  asyncWasProcessing, didTimeout, waitedMs }
```

## Manifold.AutoAssembler

`AutoAssembler`, version 2.0.8. `logger` is required, `customIO` is an optional dependency, and
`processHandler` and `trampolines` are runtime dependencies.

| Function | Returns | Description |
|---|---|---|
| `AutoAssembler:GetInstance()` | `AutoAssembler` | The preferred entry point. The singleton lives in `_instance`. |
| `AutoAssembler:New()` | `AutoAssembler` | A fresh instance. |
| `autoAssembler:SetProcessName(name)` | | Sets `RequiredProcess`, so scripts only run against a matching process. |
| `autoAssembler:AutoAssemble(fileOrText [, memrecOrTargetSelf, targetSelf])` | `boolean` | Toggles a script. See below. |
| `autoAssembler:Disable([fileOrKey, memrec])` | `boolean` | Without arguments it disables every active state. |
| `autoAssembler:Reset([reason])` | | Clears `States` and the transaction depth. |
| `autoAssembler:DisableAllWithoutExecute()` | `boolean` | Delegates to the process handler. |
| `autoAssembler:EnsureDirectoriesExist()` | `boolean` | Creates `DataDir/CEA/<Process>`. |
| `autoAssembler:GetFilePath(fileName)` | `string\|nil` | Full path inside the CEA directory. |
| `autoAssembler:FormatFileName(name)` | `string` | Appends `.CEA` when it is missing. |
| `autoAssembler:CheckDependencies()` | `boolean, table` | |

### Fields

| Field | Default | Description |
|---|---|---|
| `RequiredProcess` | `""` | Empty means no check |
| `LocalFilesFolder` | `"CEA"` | Subfolder inside `DataDir` |
| `FileExtension` | `".CEA"` | |
| `BreakOnError` | `true` | With `false` it returns `false` instead of raising |
| `States` | `{}` | Maps a state key to a state table |

### Call variants

```lua
autoAssembler:AutoAssemble("InfiniteHealth")           -- file CEA/<Process>/InfiniteHealth.CEA
autoAssembler:AutoAssemble("InfiniteHealth", memrec)   -- with a stable state key
autoAssembler:AutoAssemble(scriptTextWithNewlines)     -- raw text
autoAssembler:AutoAssemble(scriptText, true)           -- targetSelf: assemble into CE itself
autoAssembler:AutoAssemble("Script", memrec, true)     -- memrec + targetSelf
```

Whether the argument is raw text or a file name is decided solely by the presence of a newline. A
file name is looked up on disk first and then, when that fails, among the Cheat Table's own table
files.

### State keys

`_stateKey(name, memrec)` produces, in order:

1. `"<name>#MRID:<memrec.ID>"`, preferred, stable across runs
2. `"<name>#MRDESC:<memrec.Description>"`
3. `"<name>#MR:<tostring(memrec)>"`
4. `"<name>"` when there is no memory record

### Internal helpers

| Function | Description |
|---|---|
| `autoAssembler:_currentPid()` | `getOpenedProcessID()` wrapped in `pcall` |
| `autoAssembler:_validateProcessOrThrow()` | Is a process attached, and does the name match? |
| `autoAssembler:_checkProcessChangedOrThrow()` | PID comparison against `_lastKnownPid` |
| `autoAssembler:_markProcessChangedAndThrow(old, new)` | Disables everything and resets. It does not raise despite the name, because the `error()` call is commented out. |
| `autoAssembler:_loadScriptText(nameOrText)` | Raw text, or a file, or a table file |
| `autoAssembler:_getOrCreateState(key)` | |
| `autoAssembler:_txBegin()` / `_txCommit()` / `_txRollback()` | Transaction bracket |
| `autoAssembler:_txRememberEnable(key, text, targetSelf, disableInfo, name)` | Rollback entry |
| `autoAssembler:_scriptUsesTrampolines(text)` | Searches for `ManifoldInstallDetour`, `ManifoldDestroyDetour`, `ManifoldEmitOriginal`, `ManifoldEmitOriginalNoReturn` and `ManifoldEmitReturn` |
| `autoAssembler:_getTrampolineApi()` | Loads `Manifold.Trampolines` on demand |
| `autoAssembler:_beginTrampolineTransaction(text)` | Starts the detour transaction only when it is needed |

## Manifold.Callbacks

`Callbacks`, version 1.0.7. It is a singleton, so `Callbacks:New()` always returns the same
instance. `logger` is required and `ui` is a runtime dependency.

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
| `callbacks:ResetConfig()` | `table` | Puts all options back to `false` |

### Hooks installed at module load

| Hook | Behaviour |
|---|---|
| `onMemRecPreExecute(memrec, newstate)` | Debug log |
| `onMemRecPostExecute(memrec, newstate, succeeded)` | Warning only on failure |
| `AddressList.OnDescriptionChange` | `true` blocks the change |
| `AddressList.OnAddressChange` | The same |
| `AddressList.OnTypeChange` | The same |
| `AddressList.OnValueChange` | The same |
| `AddressList.OnAutoAssemblerEdit` | Chains the previous handler |
| `getLuaEngine().OnShow` | Runs the original handler, then applies the theme twice |

## Manifold.AssemblerCommands

`AssemblerCommands`, version 1.2.8. `logger` and `trampolines` are both required.

| Function | Returns | Description |
|---|---|---|
| `AssemblerCommands:New()` | `AssemblerCommands` | |
| `assemblerCommands:RegisterCoreCommands()` | `boolean` | Registers every command in `COMMAND_SPECS`. Returns `false` when `registerAutoAssemblerCommand` is unavailable. |
| `assemblerCommands:CheckDependencies()` | `boolean, table` | |

### Registered commands

| Command | Arguments | Replaced by |
|---|---|---|
| `ManifoldScanModule` | `symbol, module, signature [, protection, alignType, alignParam]` | `define(symbol, module+OFFSET)` |
| `ManifoldAssert` | `address, bytePattern` | *(empty)* |
| `ManifoldPatch` | `address [, bytePattern]` | *(empty)* |
| `ManifoldNop` | `address [, count]` | *(empty)* |
| `ManifoldInstallDetour` | `name, injectExpr [, destExpr, minSize]` | Generated detour script |
| `ManifoldEmitOriginal` | `name` | Relocated original code plus `jmp <name>_Return` |
| `ManifoldEmitOriginalNoReturn` | `name` | Relocated original code without a return |
| `ManifoldEmitReturn` | `name` | `jmp <name>_Return` |
| `ManifoldDestroyDetour` | `name` | `db` restore plus `unregistersymbol(...)` |
| `ManifoldResolveStatic` | `symbol, addrExpr [, dispOffset, instrLen, mode, outputMode]` | `define(symbol, TARGET)` |

### Byte patterns

`_parseBytesPattern` splits the argument on whitespace. Each token is either two hexadecimal
digits or one of the wildcard spellings `?`, `??`, `**`, `?*` and `*?`. A single `*` is not
accepted, and neither are prefixed forms such as `0x7B`.

```
ManifoldAssert(HealthHook, 89 41 ?? 8B 45 08)
ManifoldPatch(HealthHook, 90 90 ?? ?? 90 90)
```

Wildcards are broken, and neither of those two lines does what it looks like it does. The intended
behaviour was positional. A wildcard would be skipped by the comparison in `ManifoldAssert` and
left untouched by the write in `ManifoldPatch`, which is what the consumers were written for.
`_findPatternMismatch` skips a `nil` entry and `_buildPatchedBytes` fills one in from the bytes
already at the address. No `nil` entry ever reaches them. `_parseBytesPattern` records a wildcard
with `bytes[#bytes + 1] = nil`, and assigning `nil` to the slot one past the end of a Lua table
does nothing at all, so a wildcard leaves no hole and does not advance the position. Every byte
written after it moves one position earlier.

`89 41 ?? 8B 45 08` therefore parses to the five bytes `89 41 8B 45 08`. `ManifoldAssert` reads
five bytes from the address and lines `8B` up against the third byte of the instruction, so a
pattern that describes the target correctly still reports a mismatch at index 3, unless the
wildcarded byte happens to be `8B` by chance. `ManifoldPatch(HealthHook, 90 90 ?? ?? 90 90)`
writes four contiguous `90` bytes over the first four bytes at the address, stores those four as
the original for the later restore, and never touches the fifth and sixth. A pattern made of
nothing but wildcards parses to an empty table and is rejected as an empty bytes pattern.

Until `_parseBytesPattern` is fixed, write patterns without wildcards and let the byte count match
what you mean.

### `ManifoldResolveStatic` in detail

| Parameter | Default | Description |
|---|---|---|
| `symbol` | | Output symbol |
| `addrExpr` | | Address of the instruction |
| `dispOffset` | `3` (rip) or `1` (absolute) | Byte offset of the operand within the instruction |
| `instrLen` | `7` (rip) or `5` (absolute) | Total instruction length |
| `mode` | `"auto"` | `"rip"`, `"absolute"` or `"auto"`, detected by `_detectResolveStaticMode` |
| `outputMode` | `"address"` | `"address"` gives the resolved operand address, `"pointer"` gives the pointer stored there |

The trailing options are order-independent. Mode names and output mode names are recognised by
value, and the first two unrecognised numbers become `dispOffset` and `instrLen` in that order.
`_detectResolveStaticMode` reads the opcode byte and picks `"absolute"` for `A0` through `A3`, and
`"rip"` otherwise.

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
| `_splitArgs(parameters)` | Comma-separated and bracket-aware |
| `_requireArg` / `_requireSymbolArg` / `_requireResolvedAddressArg` / `_requireBytesPatternArg` | Validation with an error message |
| `_parseNumber(v)` | Decimal, hex, and the `$`, `0x` and `#` prefixes |
| `_aobScanModuleUnique(module, sig, prot, alignType, alignParam)` | Scan with a uniqueness check |
| `_readBytes` / `_writeBytes` / `_applyBytesAndVerify` | Memory access with read-back |
| `_buildPatchedBytes(actual, patch)` | The effective bytes a patch will leave behind, for the log. It fills a `nil` entry from `actual`, and no `nil` entry ever reaches it |
| `_buildNopBytes(count)` | An array of `0x90` |
| `_findPatternMismatch(expected, actual)` | Index of the first difference. It ignores a `nil` entry in `expected`, and no `nil` entry ever reaches it |
| `_buildMismatchMarker(index)` | Text marker for the log |
| `_storePatch` / `_restoreStoredPatch` / `_applyStoredPatch` / `_executeStoredPatch` | Patch store |
| `_isModuleSuitableForAttachContext(module)` | Verifies via `getAddressSafe` and falls back to `enumModules` |
| `_getTrampolines()` | Returns the live `trampolines` instance, constructing one from the class global when needed |
| `_syntaxDefine(symbol)` | Placeholder `define` during the syntax check |

## Manifold.Trampolines

`Trampolines`, version 1.2.0. It declares `logger` as an optional dependency. Normally it is not
called directly, because `Manifold.AssemblerCommands` is the interface. It is also the one module
without a `PrintModuleInfo`.

### Constants

| Constant | Value | Description |
|---|---|---|
| `HEADER_RELAY_MIN_OFFSET` | `0x500` | Earliest relay offset from the module base |
| `HEADER_RELAY_MAX_OFFSET` | `0x1000` | Lower bound for the end of the search, taken together with `SizeOfHeaders` |
| `HEADER_RELAY_ALIGNMENT` | `0x10` | Slot alignment |

The search window starts at the later of `HEADER_RELAY_MIN_OFFSET` and the end of the section
headers, and it ends at `max(SizeOfHeaders, HEADER_RELAY_MAX_OFFSET)` clamped down to the lowest
section virtual address. The clamp matters because `_isHeaderCaveFree` accepts `0xCC`, which is
exactly MSVC's inter-function padding, so without it a relay could land in `.text`.

### Public API

| Function | Returns | Description |
|---|---|---|
| `trampolines:InstallDetour(name, injectExpr [, destExpr, minSize])` | `entry, script, err` | Finds a relay slot, collects instructions and builds the AA script. It refuses an inject range that overlaps a live detour, and refuses bytes that visibly belong to somebody else's patch, meaning a leading `E9`, `EB` or `FF 25`. |
| `trampolines:EmitOriginal(name)` | `entry, script, err` | Relocated original code with a return jump. |
| `trampolines:EmitOriginalNoReturn(name)` | `entry, script, err` | Without the return jump. |
| `trampolines:EmitReturn(name)` | `entry, script, err` | Only `jmp <name>_Return`. |
| `trampolines:DestroyDetour(name)` | `entry, script, err` | Restore script. |
| `trampolines:Reset()` | | Clears all detour tables. |
| `trampolines:BeginTransaction()` | | Nestable. |
| `trampolines:CommitTransaction()` | | Commits `PendingDetours` and `PendingDestroys`. |
| `trampolines:RollbackTransaction([reason])` | | Writes original and relay bytes back. |
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

`Key` is the detour name lowercased, and it is what the active and pending stores are keyed by.

### Generated symbols

| Symbol | Meaning |
|---|---|
| `<name>_Block` | Start of the relay block |
| `<name>_Relay` | `jmp qword ptr [<name>_Destination]` |
| `<name>_Destination` | 8-byte pointer to the target code, or 4-byte on a 32-bit target |
| `<name>_Return` | First address after the overwritten range |
| `<name>_Original` | Relocated original code, only after `EmitOriginal` |

### Internal helpers (selection)

| Function | Description |
|---|---|
| `_enumModules()` / `_moduleSize(module)` | The loaded module list, and a module's span from `Size` or `getModuleSize` |
| `_findModuleContaining(addr)` | The module whose mapped span contains the address. The highest base at or below it wins, so a nested image is the owner |
| `_resolveModuleForAddress(addr)` | The owning module, from the module list. Parsing `getNameFromAddress` is only a fallback, and the parsed name must resolve to a real module base |
| `_formatCodeAddress(addr)` | `module+offset` for generated Auto Assembler, bare hex outside any module. Never a symbol name |
| `_collectInstructionRange(addr, minSize)` | Collects whole instructions until the total reaches `minSize` |
| `_buildRel32Jump(source, target)` | 5-byte `E9` jump, with a rel32 range check |
| `_getPeHeaderInfo(addr)` | MZ and PE signatures, `SizeOfHeaders`, the end of the section headers and the lowest section RVA. An unreadable header and a wrong signature report separately |
| `_findHeaderRelaySlot(injectAddr, size)` | Searches for a free, aligned slot |
| `_isHeaderCaveFree(addr, size)` | Only `0x00` and `0xCC` count as free |
| `_isHeaderRelaySlotReserved(addr, size)` | Collision with existing detours |
| `_checkInjectRangeFree(addr, size, originalBytes)` | Refuses an overlapping or already patched inject range |
| `_analyzeRelativeControlFlow(addr, bytes, size)` | Detects relative jumps and calls |
| `_rewriteAbsoluteMemoryInstruction(instr)` | Turns RIP-relative access into absolute access. Control transfers and stack instructions are position independent already and are copied verbatim instead. |
| `_emitAbsoluteJump(lines, target)` / `_emitAbsoluteCall(lines, target)` | Bitness-correct raw bytes whose length this module knows |
| `_buildRelocatedInstruction(entry, index, lines)` | Builds one relocated line |
| `_selectTempRegister(instr)` | A free register for the relocation. It rejects a candidate if any spelling of it appears, and returns `nil` rather than guessing when nothing is free. |
| `_restoreBytes(addr, bytes, label)` | Rollback write |
| `_cleanupDetourSymbols(entry)` | `unregistersymbol` for every detour symbol |

## Manifold.Forms

`Forms`, version 1.0.3. It declares `logger` as an optional dependency. `New(config)` copies
recognised keys from `config` onto the instance and warns about the rest.

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
| `forms:CreateButton(parent, opts)` | `button, label` | Panel plus centred label plus hover |
| `forms:CreateMemoFrame(parent, opts)` | `memo, outer, inner` | Memo wrapped in framing panels |
| `forms:CreateCard(parent, opts)` | `outer, inner, header, content, headerLabel` | Titled card |
| `forms:CreateFieldRow(parent, opts)` | `edit, row, label, border, fill, inner, gap` | Labelled input row |

### Common options

`_ApplyCommonOptions` transfers these, in `PascalCase` or in `camelCase`:

`Name`, `Align`, `Alignment`, `Layout`, `BorderStyle`, `Width`, `Height`, `Left`, `Top`,
`Caption`, `Text`, `TextHint`, `AutoSize`, `Visible`, `Transparent`, `ParentColor`, `ScrollBars`,
`WordWrap`, `ReadOnly`, `ViewStyle`, `AutoWidthLastColumn`, `RowSelect`, `FullRowSelect`,
`HideSelection`, `AutoExpand`, `Cursor`, `Position`, `Scaled`, `Hint`, `ShowHint`

Plus: `borderSpacing` (`{Left, Top, Right, Bottom, Around}`), `constraints`, `role`, `color`,
`bevelOuter`, `bevelWidth`, `bevelColor`, `fontSize`, `style`, `lockColor`, `onClick`
(`CreateButton` only), `root` and `isRoot`.

### Theming

| Function | Returns | Description |
|---|---|---|
| `forms:ApplyTheme(theme [, includeHidden])` | `table` | Colours every registered control and returns the normalized palette. |
| `forms:ApplyThemeToControl(entry, designTheme [, includeHidden])` | | A single registry entry. |
| `forms:ResolveTheme(theme)` | `table` | Turns a token theme into the 17-colour palette. If `theme.COLOR_BG` is present, the table is copied as it is. |
| `forms:SetButtonState(button, isHover)` | | Hover or normal state. |
| `forms:RegisterControl(control, role, opts)` | `control` | |
| `forms:RegisterForm(form, opts)` | `form` | `isRoot = true` |
| `forms:SetButtonOnClick(button, handler)` | `button` | Sets the handler on the panel and on the label. |
| `forms:ApplyFont(control, color, size, style)` | | Forces `Consolas`. |
| `forms:SetBorderSpacing(control, spacing)` | | |
| `forms:Repaint(control)` | | |

### Palette

| Key | Default | Token source in `ResolveTheme` |
|---|---|---|
| `COLOR_BG` | `0x202020` | `MainForm.Color` |
| `COLOR_PANEL` | `0x2A2A2A` | `MainForm.Foundlist3.Color` |
| `COLOR_ACCENT` | `0x4A4A4A` | `AddressList.CheckboxActiveColor` |
| `COLOR_TEXT` | `0xEAEAEA` | `Memrec.DefaultForeground.Color`, then `AddressList.Header.Font.Color` |
| `COLOR_LABEL` | `0xC8C8C8` | `Memrec.DefaultForeground.Color`, then `AddressList.Header.Font.Color` |
| `COLOR_BTN` | `0x2A2A2A` | `AddressList.Header.Canvas.Brush.Color` |
| `COLOR_BTN_HOVER` | `0x4A4A4A` | `AddressList.CheckboxActiveColor`, then `AddressList.Header.Canvas.Pen.Color` |
| `COLOR_BTN_TEXT` | `0xEAEAEA` | `= COLOR_LABEL` |
| `COLOR_TAB_ACTIVE` / `COLOR_TAB_INACTIVE` | `0x4A4A4A` / `0x2A2A2A` | *(not mapped)* |
| `COLOR_INPUT` | `0x1B1B1B` | `AddressList.List.BackgroundColor` |
| `COLOR_INPUT_TEXT` | `0xEAEAEA` | `TreeView.Font.Color`, then `AddressList.Header.Font.Color` |
| `COLOR_BORDER` | `0x454545` | `AddressList.Header.Canvas.Pen.Color`, then `MainForm.Panel4.BevelColor` |
| `COLOR_MUTED` | `0x8A8A8A` | `Memrec.GroupHeader.Color` |
| `COLOR_SURFACE` | `0x2F2F2F` | `MainForm.Foundlist3.Color` |
| `COLOR_SURFACE_ALT` | `0x242424` | `MainForm.Color` |
| `COLOR_SUCCESS` | `0x6FD96F` | *(not mapped)* |

## Manifold.UI

`UI`, version 1.1.2. `logger`, `customIO` and `forms` are required, `json` is an optional
dependency, and `teleporter` is a runtime dependency.

### Configuration

```lua
ui = UI:New({
    Theme        = "Manifold.Dark-Aqua.Min",  -- applied during InitializeForm
    SloganStr    = "MANIFOLD",
    SignatureStr = "by Leunsel",
})
```

Further fields: `ThemeList`, `ActiveTheme`, `CompactMode`, `IsApplyingTheme` and
`ThemeApplyLockTimeoutMs`, which defaults to `8000`. The apply lock itself lives in the global
`__ManifoldThemeApplyLock` so it survives a module reload.

### Theme tokens

| Token | Description |
|---|---|
| `TreeView.Color` | *Not used. Use AddressList instead.* |
| `TreeView.Font.Color` | *Not used. Use AddressList instead.* |
| `AddressList.CheckboxColor` | Outline of unchecked boxes |
| `AddressList.CheckboxActiveColor` | Fill of checked boxes |
| `AddressList.CheckboxSelectedColor` | Outline of selected boxes |
| `AddressList.CheckboxActiveSelectedColor` | Fill of checked and selected |
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

`UI.ThemeTokens` holds the list and `UI.TokenDescriptions` holds the text shown in the theme
creator.

### Theme management

| Function | Returns | Description |
|---|---|---|
| `ui:LoadThemes()` | | Loads from the data directory and from table files. |
| `ui:LoadTheme(themeFile, isExternal)` | `boolean` | A single theme. External ones get `" (External)"`. Debug on success, an `ErrorBlock` naming the file and the reason on failure. |
| `ui:LoadJsonThemesFromDataDir(list)` | `number` | Scans `DataDir\Themes` and returns how many usable files it found. Unreadable files are one `WarningBlock`, not one warning each. |
| `ui:GetJsonThemesFromTableMenu()` | `table\|nil` | Reads `.json` entries from `miTable`. |
| `ui:FinalizeThemes(list)` | `number, number` | Loads all collected files. Returns loaded and failed. |
| `ui:GetTheme(name)` | `table\|nil` | Reloads once on a miss. |
| `ui:ProcessThemeData(raw, name)` | `table` | Converts tokens to BGR and collects the missing and invalid ones. |
| `ui:GetThemeTokens()` | `table` | `UI.ThemeTokens` |
| `ui:TokenColor(raw, token)` | `number\|nil` | Looks the token up in `tokenColors`. |
| `ui:TokenSearch(scope, token)` | `boolean` | |
| `ui:GetActiveThemeData()` | `table\|nil` | Token table of the active theme. |
| `ui:UpdateThemeSelector()` | | Rebuilds the theme selector records. |
| `ui:EnsureThemeDirectory()` | `string\|nil` | |

### Theme application

| Function | Returns | Description |
|---|---|---|
| `ui:ApplyTheme(name [, allowReapply])` | `boolean` | Full application under a global lock. |
| `ui:ApplyThemeObject(themeObj)` | `boolean` | For `{Name, Author, Description, Tokens}`, used by the theme creator. |
| `ui:ApplyThemeToTreeView(theme)` | | |
| `ui:ApplyThemeToAddressList(theme)` | | Including `Header.Canvas.OnChange`. |
| `ui:ApplyThemeToMainForm(theme)` | `boolean` | Whether the slogan label was there to colour. |
| `ui:ApplyThemeToAddressRecords(theme)` | `number, number` | One colour per record. Returns recoloured and unchanged. |
| `ui:ApplyThemeToLuaEngine(theme)` | `boolean` | Whether the window was open. Calls the control function twice. |
| `ui:ApplyThemeToLuaEngineControls(le, theme)` | | Sets the caption to `"[Manifold] Logger"`. |
| `ui:CreateOrUpdateLuaEngineExecutePanel(...)` | | Replaces `btnExecute` with a colourable panel. |
| `ui:ApplyThemeToForms(theme, includeHidden)` | `table\|nil` | Delegates to `Manifold.Forms`. |
| `ui:ApplyThemeToTeleporter(teleporter, theme)` | `boolean` | Whether the Teleporter window was open. |
| `ui:SetTeleporterControlColors(uiState, theme)` | | The central place for every teleporter colour. |
| `ui:GetRecordColor(record, theme, str, int, flt)` | `number` | Decision order below. |
| `ui:AcquireThemeApplyLock(name)` | `string\|nil, table` | |
| `ui:ReleaseThemeApplyLock(token)` | | |
| `ui:RGB2BGR(rgb)` / `ui:BGR2RGB(bgr)` | `number` | |

Decision order in `GetRecordColor`:

```
vtAutoAssembler          -> Memrec.AutoAssembler.Color
IsAddressGroupHeader     -> Memrec.AddressGroupHeader.Color
IsGroupHeader            -> Memrec.GroupHeader.Color
OffsetCount == 0 and AddressString is not hex -> Memrec.UserDefined.Color
ShowAsHex                -> Memrec.HexValues.Color
string type              -> Memrec.StringType.Color
integer type             -> Memrec.IntegerType.Color
float type               -> Memrec.FloatType.Color
otherwise                -> Memrec.DefaultForeground.Color
```

The user-defined and hex branches fall back to `Memrec.DefaultForeground.Color` when their own
token is missing, and any branch that produces no colour at all leaves `record.Color` alone.

### CE window tweaks

| Function | Description |
|---|---|
| `ui:InitializeForm()` | Compact mode, bevel off, sorting off, signature controls off, slogan and signature, theme. |
| `ui:EnableCompactMode()` / `DisableCompactMode()` / `ToggleCompactMode()` | `Panel5` and `Splitter1` |
| `ui:SetControlVisibility(name, visible)` / `ToggleControlVisibility(name)` | |
| `ui:HideSignatureControls()` / `ToggleSignatureControls()` | `CommentButton` and `advancedbutton` |
| `ui:DisableDragDrop()` | Removes the tree view's drag handlers. |
| `ui:DisableHeaderSorting()` | Removes `OnSectionClick`. |
| `ui:HideAddresslistBevel()` | `BevelOuter = "bvNone"` |
| `ui:RunInMainThread(fn)` | Wrapper with `pcall` and logging. |
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
| `ui:RevealEffect(text, interval)` | Placeholders turning into characters |
| `ui:GlitchText(text, interval)` | Random character swaps |
| `ui:MatrixReveal(text, interval)` | `#` turning into characters in random order |

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
| `ui:InitializeThemeCreator()` | Opens the `[Manifold] Theme Creator` window, 980 by 620 px. |
| `ui:CreateThemeCreatorForm()` | |
| `ui:CreateThemeInfoPanel(form, opts)` | Name, author and description |
| `ui:CreateListViewControl(form, opts)` | Token list with colour swatches |
| `ui:CreateTokenPreviewPanel(form, opts)` | Preview and copy buttons |
| `ui:CreateButtonPanel(form, opts)` | Apply, Export and Load |
| `ui:CreateThemeCreatorStatusBar(parent)` / `ui:SetThemeCreatorStatus(text)` | |
| `ui:PopulateListView(listView, tokenInputs)` | |
| `ui:RebuildImageList(listView [, colorsAndTokens])` | Redraws the colour swatches |
| `ui:GetColorsAndTokensFromListView(listView)` | |
| `ui:OnListViewDblClick(...)` / `ui:OnListViewSelectItem(...)` | |
| `ui:HandleColorSelection(item, token)` | Colour dialog |
| `ui:UpdateColorLabels(colorNum)` / `ui:UpdateSelectedToken(name)` | |
| `ui:CreateCopyButton(parent, targetLabel, topOffset)` | |
| `ui:SetupApplyButton(...)` / `SetupExportButton(...)` / `SetupLoadButton(...)` | |
| `ui:PromptThemeFile()` | `createOpenDialog` with the filter `*.json` |
| `ui:LoadThemeData(path)` | Turns a file into a table |
| `ui:NormalizeTheme(data)` | `{Name, Author, Description, Tokens}` with defaults |
| `ui:PopulateThemeUI(themeData, tokenInputs, name, author, desc)` | |
| `ui:CreateStyledLabel/Edit/Button(...)` | Thin wrappers around `Manifold.Forms` |
| `ui:SetFormsButtonHandler(button, handler)` | |

## Manifold.Teleporter

`Teleporter`, version 1.4.1. `logger` and `forms` are required, and `memory` and `customIO` are
optional dependencies. `ui` is a runtime dependency. The module also calls `utils` at runtime, for
`GetTargetNoExt` and `AutoDisable`, without declaring it.

### Configuration

| Section | Fields |
|---|---|
| `Transform` | `Symbol = "TransformPtr"`, `Offsets = {0x30, 0x34, 0x38}`, `ValueType = vtSingle` |
| `Waypoint` | `Symbol = "WaypointPtr"`, `Offsets = {0x00, 0x04, 0x08}`, `ValueType = vtSingle` |
| `Additional` | `Symbol = nil`, `Offsets = {0x00, 0x04, 0x08}`, `ValueType = vtSingle` |
| `Symbols` | `Saved = "SavedPositionFlt"`, `Backup = "BackupPositionFlt"` |
| `Settings` | `ValueType`, `PauseWhileTeleporting`, `AdjustYCoordinate`, `YCoordinateIndex`, `AdjustmentAmount`, `LogVerbose` |
| `Axes` | `{ "X", "Y", "Z" }`. Names only. The count comes from `Transform.Offsets`. |
| other | `Saves = {}`, `SaveFileName = "Teleporter.%s.Saves.txt"`, `SaveMemoryRecordName = "[— Teleporter : Saves —] ()->"` |

### Dimensions

A position is as long as `Transform.Offsets`, so a 2D game configures two offsets and nothing else.
See [the framework guide](Manifold-Framework.md#82-dimensions).

| Function | Returns | Description |
|---|---|---|
| `teleporter:AxisCount()` | `number` | How many components a position has. Falls back to `#Axes` before a `Transform` exists. |
| `teleporter:GetAxes()` | `table` | The axis names, in memory order. Cached against the offsets and `Axes`. Missing names fall back to `X`, `Y`, `Z`, `W`; blank or duplicate names are replaced. |
| `teleporter:RefreshAxes()` | | Drops the cache. Only needed when `Axes` is edited in place rather than replaced. |
| `teleporter:SaveToPosition(save)` | `table\|nil` | Reads one key per axis out of a save. `nil` when any is missing. |
| `teleporter:PositionToSave(save, pos)` | `table` | Writes one key per axis, and removes default axis names this table no longer uses. |
| `teleporter:ValidateConfiguration([quiet])` | `boolean, table` | Reports every configured symbol whose offset count disagrees with the axis count. A symbol with no name is skipped. |

### Memory access

| Function | Returns | Description |
|---|---|---|
| `teleporter:ResolveAddress(str, isPointer)` | `integer\|nil` | With `isPointer` set it resolves `[str]+0` |
| `teleporter:ReadPositionFromMemory(symbol, offsets, isPointer, valueType)` | `table\|nil` | One value per offset. |
| `teleporter:WritePositionToMemory(symbol, offsets, pos, isPointer, valueType)` | `boolean` | |
| `teleporter:CalculateSymbolOffsets()` | `table` | One offset per axis, sized from `Settings.ValueType`. `vtSingle` in two dimensions gives `{0, 4}`. |
| `teleporter:SetValueType(vt)` | | Validated against the read and write tables |
| `teleporter:GetCurrentPosition()` | `table\|nil` | |
| `teleporter:GetSavedPosition()` | `table\|nil` | |
| `teleporter:GetBackupPosition()` | `table\|nil` | |

### Movement

| Function | Returns | Description |
|---|---|---|
| `teleporter:SaveCurrentPosition()` | `boolean` | |
| `teleporter:LoadSavedPosition()` | `boolean` | |
| `teleporter:LoadBackupPosition()` | `boolean` | |
| `teleporter:TeleportToCoordinates(position)` | `boolean` | The position must have `AxisCount()` values. |
| `teleporter:TeleportToWaypoint()` | `boolean` | |
| `teleporter:TeleportToSave(keyOrName)` | `boolean` | Full key, or a display name while unambiguous |
| `teleporter:GetAdjustedTargetPosition(pos)` | `table\|nil` | Rejects a position that is not `AxisCount()` long, naming both counts. |
| `teleporter:FormatPosition(position)` | `string` | Three decimals per component, however many there are. `"unknown"` for `nil` or empty. |
| `teleporter:GetDistance(old, new)` | `number\|nil` | Straight line, summed over as many components as the shorter of the two has. |
| `teleporter:_ReportJump(what, from, to, backupStored)` | | One `InfoBlock` for a completed jump. |
| `teleporter:LogDistanceTraveled(old, new)` | | Kept for outside callers. `_ReportJump` puts the distance in the same entry as the destination. |
| `teleporter:PauseGame()` / `ResumeGame()` | | |

### Categories

| Function | Returns | Description |
|---|---|---|
| `teleporter:NormalizeCategoryPath(input)` | `table` | Accepts a table or a string. The separators are `/`, `\`, `>` and `\|` |
| `teleporter:CategoryPathToText(path, includeDefault)` | `string` | Joins with `" / "`. An empty path gives `"Default"` |
| `teleporter:GetSaveCategoryPath(save, includeDefault)` | `table` | Prefers `Categories` and falls back to `Category` |
| `teleporter:SetSaveCategoryPath(save, input)` | | Writes both fields |
| `teleporter:AddSaveToCategoryTree(root, path, key)` | | |
| `teleporter:BuildSaveHierarchy([filterFn])` | `table` | Author, then category path, then save keys |

### Save identity

Saves are keyed by their full category path plus their name, so the same name may exist in several
categories.

| Function | Returns | Description |
|---|---|---|
| `teleporter:MakeSaveKey(categoryInput, name)` | `string\|nil` | Joins path and name with `" / "`. An empty path becomes `"Default"` |
| `teleporter:GetSaveKey(save)` | `string\|nil` | The key a save's own fields imply |
| `teleporter:GetSaveDisplayName(save, fallbackKey)` | `string` | `save.Name`, falling back to the key |
| `teleporter:ResolveSaveKey(input)` | `string\|nil, string\|nil` | Exact key, else a unique display name; otherwise `nil` plus the reason |

### Persistence

| Function | Returns | Description |
|---|---|---|
| `teleporter:EnsureTeleporterDir()` | `string\|nil` | |
| `teleporter:GetSaveFilePath()` | `string, string` | Full path and file name |
| `teleporter:SaveLookup()` | `table\|nil` | The data directory first, then the table file |
| `teleporter:WriteSavesToDataDir()` | `boolean` | |
| `teleporter:WriteSavesToTableFile()` | `boolean` | |
| `teleporter:PersistSaves(preferDataDir)` | | |
| `teleporter:EnsureAuthorsAndCategories()` | `number` | Fills in missing fields, normalizes categories, rekeys legacy entries and returns how many were migrated |
| `teleporter:GetAuthors()` | `table` | Maps a name to an author |
| `teleporter:CountSaves()` | `number` | |
| `teleporter:GetCurrentAuthor()` | `string` | `USERNAME`, then `USER`, then `"Unknown"` |
| `teleporter:FormatSaveTree([options])` | `table` | `{ Lines, Summary, Totals }`. Options: `coordinates`, `descriptions`, `width` (default 92) |
| `teleporter:PrintSaves([options])` | `boolean` | Logs the tree as one forced entry. Options are passed to `FormatSaveTree` |

### Management

| Function | Returns |
|---|---|
| `teleporter:CreateSaveFromCurrentPosition([name, category, description])` | `boolean` |
| `teleporter:AddSave()` | `boolean` |
| `teleporter:DeleteSave([name])` | `boolean` |
| `teleporter:RenameSave(oldName, newName)` | `boolean` |
| `teleporter:DuplicateSelectedSave()` | `boolean` |
| `teleporter:UpdateSelectedSaveFromEditor()` | `boolean` |
| `teleporter:GenerateUniqueCopyName(base, categoryInput)` | `string` |
| `teleporter:CreateTeleporterSaves()` | |
| `teleporter:ClearSubrecords(record)` | |

### User interface

| Function | Description |
|---|---|
| `teleporter:InitTeleporterUI()` | Opens or focuses the window |
| `teleporter:EnsureUiState()` | Creates the UI state table, which `Manifold.UI` uses for theming |
| `teleporter:RefreshUi([preserveSelection])` | Rebuilds the tree view |
| `teleporter:SetStatus(text)` | Status bar |
| `teleporter:ClearEditor()` | |
| `teleporter:LoadSaveIntoEditor(keyOrName)` | |
| `teleporter:GetSelectedSaveName()` / `SetSelectedSaveName(key)` | Holds the save key, not the display name |
| `teleporter:GetAxisEdits()` | The editor's coordinate boxes, in axis order. Skips any that were not built. |
| `teleporter:_CommitSaveChange(key, status)` | Persists, reselects, refreshes and reloads the editor. The shared tail of add, update, rename, duplicate and delete. `key = nil` clears the editor, which is the delete case. |
| `teleporter:TryGetEditorPosition()` | Reads X, Y and Z from the editor fields |
| `teleporter:GetSaveKeyFromTreeNode(node)` | Walks back up to the author node to rebuild the key |
| `teleporter:GetSaveNameFromTreeNode(node)` | Deprecated alias for `GetSaveKeyFromTreeNode` |
| `teleporter:OnThemeApplied(themeData)` | Reaction to a theme change |
| `teleporter:CreateMenuStrip/Header/StatusBar/TreePanel/EditorPanel/TreeContextMenu(...)` | UI construction |

## Developer modules

The directory `Manifold-Modules/Manifold.Modules/Manifold.Dev/` is not part of a normal table
setup and is listed in `.gitignore`, so these files are not published to GitHub. The reference
below documents the local working copy. The directory also holds a second copy of
`Manifold.Json.lua` and the retired `Manifold.Json.Old.lua`. `CETrequire("Manifold.Json")`
resolves the flat one, not the copy in here.

### Manifold.AssemblerLinter

| Function | Description |
|---|---|
| `AssemblerLinter:New()` | |
| `linter:Lint(rawText)` | Runs all five phases and returns a report. |
| `linter:PrintReport(report)` | |
| `linter:Use(plugin)` | A plugin is a function, or a table with `Apply` or `Register`. |
| `linter:RegisterDirective(name, spec)` | |
| `linter:RegisterDirectiveAlias(alias, target)` | |
| `linter:RegisterArgType(typeName, fn)` | |
| `linter:Phase1_Lex(...)` through `Phase5_Gate(...)` | Callable individually. |

Configuration: `UnknownDirectiveAsWarning`, `RequireEnableDisableBlocks`, `BlockOnErrors` and
`WarnOnGlobalStarOps`.

### Manifold.Patcher

| Function | Description |
|---|---|
| `Patcher:New(version)` | |
| `patcher:Start(url)` | Computes the fingerprint and calls `CheckAndApply`. |
| `patcher:CheckAndApply(url [, bypass])` | Server exchange, user confirmation, application and rollback. |
| `patcher:RequestPatches(url)` | `internet.postURL` with `{version, fingerprint}`. |
| `patcher:ApplyPatch(patch)` / `NormalizePatch(patch)` | |
| `patcher:RevertPatches()` | |
| `patcher:ResolveTarget(patch)` | Finds the target record. |
| `patcher:PatchScript(target, value)` | Replaces script text. `DefaultScriptReplaceMode` is `"plain"`, and a patch may ask for `"pattern"`. |
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
`maxClasses`, `maxCOLs`, `maxVtables` and `maxInstances`, where `0` means unlimited.

### Manifold.Testing

`Manifold-Modules/Manifold.Modules/Manifold.Testing/Manifold.UnitTest.lua` is a test runner rather
than a module, so it exposes no API. It loads each module named in its own `MODULE_SPECS` table,
checks the declared exports and runs a behaviour probe where one is safe to run. `TEST_MODE` is
`"safe"` or `"deep"` and gates the probes that touch files or memory. The runner prints to the
console, and `Manifold.UnitTest.Output.txt` next to it is a saved transcript of one such run.
