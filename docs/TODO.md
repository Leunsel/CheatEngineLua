# TODO

Open work items from a code review of all three segments (reviewed 2026-08-21 against `main`,
revised 2026-08-23). Every item names the file and line, what goes wrong, and what to do about it.

Resolved items keep their original text with a ✅ note on top, so the reasoning stays readable.

**Priorities**

| Symbol | Meaning |
|---|---|
| 🔴 | Blocks functionality or is security relevant — do first |
| 🟠 | Wrong behaviour under realistic conditions |
| 🟡 | Robustness, maintainability, performance |
| 🔵 | Documentation and consistency |

---

## Checklist

### 🔴 Critical

- [X] **T1** — Edit: No fix required. `Manifold` is supposed to be a Table Lua Script Global.
- [X] **T2** — Resolved 2026-08-23. `Memory:GetRegisterData` now uses two anchored patterns instead of one with a fake optional group, and warns at the call site when no base register can be found.
- [X] **T3** — Edit: No fix required. Patcher has been discontinued.

### 🟠 High

- [X] **T4** — Resolved 2026-08-23 by [R-B](#r-b-shared-dependency-bootstrapping). Every `CheckDependencies` is now three lines forwarding to `Bootstrap.Resolve`, and nothing in `Manifold.Bootstrap` indexes `logger` without a guard, so the class of bug is gone rather than the instance.
- [ ] [**T5** — Callbacks and UI dereference `getLuaEngine()` unguarded](#t5-callbacks-and-ui-dereference-getluaengine-unguarded) · Framework (Context-Specific)
- [ ] [**T6** — Teleporter uses `utils` without declaring the dependency](#t6-teleporter-uses-utils-without-declaring-the-dependency) · Framework (Context-Specific) — *still open; the fix is delicate, see the section*
- [X] **T7** — Resolved 2026-08-23. `Manifold.Json` was rewritten without the `self.__index ~= JSON` guard that caused it; every entry point is call-style agnostic. `Manifold.Bootstrap` additionally reports a re-execution as `RELOAD` instead of letting it corrupt silently.
- [X] **T8** — Resolved 2026-08-23 in Helper 1.1.0. Both halves: the function now exists, and `Utils:GetTitleComponents` does a real emptiness check so the `AppVersion` fallback is actually reachable.
- [ ] [**T9** — State IDs collide with "Normalize Cheat Table IDs"](#t9-state-ids-collide-with-normalize-cheat-table-ids) · cross-segment
- [ ] [**T23** — `Logger` and `CustomIO` can recurse without bound](#t23-logger-and-customio-can-recurse-without-bound) · Framework

### 🟡 Medium

- [X] **T10** — No fix required. By design: the full file output makes it easier to debug inconsistencies or errors a user reports.
- [X] **T11** — Resolved 2026-08-23 in Memory 1.1.0. Success lines are `Debug` and gated behind `Memory.LogSuccessfulOperations`, default `false`.
- [ ] [**T12** — Reading table files does not scale](#t12-reading-table-files-does-not-scale) · Framework
- [ ] [**T13** — The data directory is hard-coded twice](#t13-the-data-directory-is-hard-coded-twice) · Framework
- [ ] [**T14** — `EnsureDirectoryExists` is not recursive](#t14-ensuredirectoryexists-is-not-recursive) · Framework
- [ ] [**T15** — CSV without quoting](#t15-csv-without-quoting) · Framework
- [ ] [**T16** — `OpenDirectory` builds a shell line with `string.format`](#t16-opendirectory-builds-a-shell-line-with-stringformat) · Framework
- [ ] [**T17** — `_markProcessChangedAndThrow` does not throw](#t17-_markprocesschangedandthrow-does-not-throw) · Framework
- [X] **T18** — Deferred. Cheat Engine 7.5 always runs as administrator, so the path is writable today. Potential CE 7.6+ problem; scheduled for review once 7.6 is actively used.
- [X] **T19** — Edit: Backup Instance of Manifold.AssemblerCommands.lua due to automated Trampoline-Implementation attempt. (Success)
- [ ] [**T20** — Callback hooks are chained inconsistently](#t20-callback-hooks-are-chained-inconsistently) · Framework

### 🔵 Documentation and tests

- [ ] [**T21** — Documentation and version drift](#t21-documentation-and-version-drift) · all — *1 of 4 rows fixed: `Manifold.Utils` VERSION now matches its changelog. The other three and the CI check remain.*
- [X] **T22** — No fix required. Unit tests are not relevant in this context.
- [ ] [**T24** — Teleporter assigns to a `for` control variable](#t24-teleporter-assigns-to-a-for-control-variable) · Framework
- [ ] [**T25** — Three game-specific custom types live in Utils](#t25-three-game-specific-custom-types-live-in-utils) · Framework

### Larger refactors

- [ ] [**R-A** — A real namespace](#r-a-a-real-namespace)
- [X] **R-B** — Implemented 2026-08-23 as [`Manifold.Bootstrap.lua`](../Manifold-Modules/Manifold.Modules/Manifold.Bootstrap.lua). See the section for what shipped and how it differs from the sketch.
- [ ] [**R-C** — `CETrequire` with a module cache](#r-c-cetrequire-with-a-module-cache)
- [ ] [**R-D** — Structured logging instead of text lines](#r-d-structured-logging-instead-of-text-lines)
- [ ] [**R-E** — Contract checking for the template context](#r-e-contract-checking-for-the-template-context)
- [ ] [**R-F** — Reproducible release builds](#r-f-reproducible-release-builds)

---

# Framework

## T4. `State:CheckDependencies` uses the logger before it exists

> **✅ Resolved 2026-08-23** — structurally, not locally. [R-B](#r-b-shared-dependency-bootstrapping)
> shipped as `Manifold.Bootstrap`, and every module's `CheckDependencies` is now
> three lines forwarding to `Bootstrap.Resolve`. There is exactly one `_log()` in
> the core and it queues rather than indexing a logger that may not exist, so the
> `ProcessHandler` twin in its `else` branch is closed by the same change.


🟠 [`Manifold.State.lua:118–126`](../Manifold-Modules/Manifold.Modules/Manifold.State.lua)

```lua
for _, dep in ipairs(dependencies) do
    if _G[dep.name] == nil then
        logger:Warning(MODULE_PREFIX .. " '" .. dep.name .. "' dependency not found. …")
        --  ^^^^^^ on the first iteration dep.name == "logger"
```

If `logger` is not loaded yet — exactly the case this function is meant to handle — the warning
line raises `attempt to index a nil value (global 'logger')` before `CETrequire` is even called.

Other modules already do this correctly: `Manifold.UI` and `Manifold.Teleporter` use a local
`depLog` helper with `if logger and logger[level]`, `Manifold.Trampolines` checks
`if logger and logger.Warning`, `Manifold.AutoAssembler` checks `if _G.logger`.

**Fix.** Adopt the same pattern:

```lua
local function depLog(level, message)
    if logger and logger[level] then logger[level](logger, message) end
end
```

Better still: pull all four variants into one shared helper (see
[R-B](#r-b-shared-dependency-bootstrapping)).

`ProcessHandler:CheckDependencies` has the same problem in its `else` branch (`logger:Error` when
loading the logger fails).

---

## T5. Callbacks and UI dereference `getLuaEngine()` unguarded

🟠 [`Manifold.Callbacks.lua:376–378`](../Manifold-Modules/Manifold.Modules/Manifold.Callbacks.lua),
[`Manifold.UI.lua:751`](../Manifold-Modules/Manifold.Modules/Manifold.UI.lua)

```lua
-- Callbacks.lua
local LuaEngine = getLuaEngine()
local o_LuaEngine_OnShow = LuaEngine and LuaEngine.OnShow   -- correctly guarded
LuaEngine.OnShow = function(...)                            -- NOT guarded
```

```lua
-- UI.lua, at module level
local o_LuaEngine_btnExecute_OnClick = getLuaEngine().btnExecute.OnClick
```

The `and` guard on line 377 shows the author expected `nil` — line 378 accesses it unguarded
anyway. That `getLuaEngine()` can return `nil` is confirmed by `Utils:OpenLuaEngineWindow`, which
writes `getLuaEngine() or createLuaEngine()` for exactly that reason.

**Impact.** Both lines run at **module level**, i.e. directly during `CETrequire`. A `nil` aborts
loading the whole module — in the UI case that means no theming, no theme creator, no slogan
labels.

**Fix.**

```lua
-- Callbacks.lua
local LuaEngine = getLuaEngine() or (createLuaEngine and createLuaEngine())
if LuaEngine then
    local o_OnShow = LuaEngine.OnShow
    LuaEngine.OnShow = function(...) … end
end
```

```lua
-- UI.lua: resolve lazily inside ApplyThemeToLuaEngine instead of at module level
function UI:_GetOriginalExecuteHandler()
    if self._o_btnExecute ~= nil then return self._o_btnExecute end
    local le = getLuaEngine()
    self._o_btnExecute = le and le.btnExecute and le.btnExecute.OnClick or false
    return self._o_btnExecute
end
```

---

## T6. Teleporter uses `utils` without declaring the dependency

> **⚠️ Still open, and the obvious fix is not safe.** As of 2026-08-23 the dependency can
> now simply be declared — `{ "utils", runtime = true }` in the module's
> `BOOTSTRAP.Declare` block — which costs nothing and documents the edge. That part
> should just be done.
>
> The fallback proposed below must **not** be applied as written. `GetTargetNoExt()`
> determines the teleport **save file name**. Substituting `helper:GetProcessTrimmed()`
> or `"Unknown"` when `utils` is absent resolves a *different* filename, so a user's
> existing saves are not found and appear to have vanished. Any fallback has to
> either produce the identical string or refuse loudly — it must never quietly
> resolve to a second name.


🟠 [`Manifold.Teleporter.lua:862`](../Manifold-Modules/Manifold.Modules/Manifold.Teleporter.lua)

```lua
local saveFilePath = string.format(self.SaveFileName, utils:GetTargetNoExt())
```

`Teleporter:CheckDependencies` only resolves `logger`, `memory`, `customIO` and `forms`. `utils`
is missing but used in `GetSaveFilePath()` — and therefore indirectly by `SaveLookup`,
`WriteSavesToDataDir`, `WriteSavesToTableFile` and `PersistSaves`.

**Impact.** Loading the teleporter without `Manifold.Utils` produces
`attempt to index a nil value (global 'utils')` on the first save or load. The error surfaces far
from the actual setup and is correspondingly hard to attribute.

**Fix.** Add `utils` to the dependency list:

```lua
{ name = "utils", path = "Manifold.Utils", init = function() utils = Utils:New() end },
```

Also add a fallback so the teleporter stays usable without `Utils`:

```lua
local target = (utils and utils.GetTargetNoExt and utils:GetTargetNoExt())
    or (helper and helper:GetProcessTrimmed())
    or "Unknown"
```

---

## T7. JSON instances do not survive a module reload

> **✅ Resolved 2026-08-23.** `Manifold.Json` was rewritten from scratch without the
> `type(self) ~= 'table' or self.__index ~= JSON` guard that caused this — every entry
> point is call-style agnostic and identifies itself by a stable marker field rather
> than by table identity, so two loads still recognise each other's values.
> `Manifold.Bootstrap` closes the other half: a re-execution is now reported as
> `RELOAD gen N` naming the affected modules, instead of silently orphaning them.
> The underlying cause — `CETrequire` has no cache — is still
> [R-C](#r-c-cetrequire-with-a-module-cache), now visible rather than silent.


🟠 [`Manifold.Json.lua:507`](../Manifold-Modules/Manifold.Modules/Manifold.Json.lua)

```lua
if type(self) ~= 'table' or self.__index ~= JSON then
    local error_message = "JSON:decode must be called in method format"
```

`JSON` is a **global**. `CETrequire("Manifold.Json")` reassigns it. An instance created earlier via
`JSON:new()` still points at the *old* `JSON` through its metatable, while `decode` compares
against the *current* global `JSON`. The comparison fails and `decode`/`encode` abort with the
message above.

This is exactly what happens in the recorded test run
([`Manifold.UnitTest.Output.txt`](../Manifold-Modules/Manifold.Modules/Manifold.Testing/Manifold.UnitTest.Output.txt)):

```
1. [Manifold.State]    Behavior test crashed -> …:191: JSON:decode must be called in method format
2. [Manifold.CustomIO] Behavior test crashed -> …:191: JSON:decode must be called in method format
```

In practice it triggers as soon as a module runs `CustomIO:CheckDependencies` while an older
`json` instance is still in circulation — for example after running the table Lua script more than
once.

**Fix.** In `CustomIO:CheckDependencies` (and everywhere else) check for usability rather than for
`nil`:

```lua
local function jsonIsUsable()
    if type(json) ~= "table" then return false end
    local ok = pcall(function() return json:encode({}) end)
    return ok
end
if jsonIsUsable() then return end
```

The cleaner route is to make `CETrequire` idempotent (see
[R-C](#r-c-cetrequire-with-a-module-cache)) — then `Manifold.Json` is never executed twice in the
first place.

---

## T8. `helper:GetFileVersionStr` does not exist

> **✅ Resolved 2026-08-23** in Helper 1.1.0, both halves as proposed below.
> `Helper:GetFileVersionStr(path)` exists and guards `getFileVersion`,
> `GetGameModule` and a non-table result. `Utils:GetTitleComponents` now tests
> `AppVersion ~= ""` so the fallback is reachable, and no longer indexes `helper`
> unguarded — `helper` is a runtime dependency, and a table without it used to get
> `"Error: Failed to Set Title"` as its window caption.


🟠 [`Manifold.Utils.lua:600`](../Manifold-Modules/Manifold.Modules/Manifold.Utils.lua)

```lua
gameVersion = self.AppVersion or helper:GetFileVersionStr(helper:GetGameModulePathToFile())
    or "GameVersion",
```

`Manifold.Helper` has no `GetFileVersionStr` — the name appears exactly once in the whole
repository, right here.

**Impact.** Currently latent: `Utils.AppVersion` defaults to `""`, and `""` is truthy in Lua. The
fallback is therefore never reached and the title simply shows `V:` with no version. The moment
someone leaves `AppVersion` empty expecting auto-detection, the branch runs and `SetTitle` falls
into its `pcall` error path, setting the window title to `"Error: Failed to Set Title"`.

**Fix.** Address both halves — add the missing function and correct the empty-string check:

```lua
-- Manifold.Helper.lua
function Helper:GetFileVersionStr(path)
    path = path or self:GetGameModulePathToFile()
    if not path or type(getFileVersion) ~= "function" then return nil end
    local ok, _, versionInfo = pcall(getFileVersion, path)
    if not ok or type(versionInfo) ~= "table" then return nil end
    return string.format("%d.%d.%d.%d",
        versionInfo.major or 0, versionInfo.minor or 0,
        versionInfo.release or 0, versionInfo.build or 0)
end
```

```lua
-- Manifold.Utils.lua
local appVersion = (self.AppVersion ~= "" and self.AppVersion) or nil
gameVersion = appVersion or helper:GetFileVersionStr() or "GameVersion",
```

---

## T9. State IDs collide with "Normalize Cheat Table IDs"

🟠 cross-segment:
[`Manifold.State.lua`](../Manifold-Modules/Manifold.Modules/Manifold.State.lua) ×
[`Manifold-CE-Utility.lua`](../Manifold-CE-Utility/Manifold-CE-Utility.lua)

`State:RestoreState` matches saved entries purely by `mr.ID`:

```lua
for _, rec in ipairs(stateData) do stateLookup[rec.id] = rec end
...
local rec = stateLookup[mr.ID]
```

The CE Utility in the same repository offers **Normalize Cheat Table IDs**, which reassigns exactly
those IDs (1..N in tree order).

**Impact.** After a normalization, every previously saved `.State` file no longer matches. And
because `RestoreState` is **exclusive**, loading afterwards activates the *wrong* records and
deactivates the right ones. The same applies to any other renumbering, e.g. inserting new records
in Cheat Engine.

**Fix.**

1. Store a stable secondary key when saving — `description` is already in the record but is not
   consulted during restore:

```lua
local rec = stateLookup[mr.ID]
if not rec then rec = descriptionLookup[mr.Description] end
```

2. Write a `SchemaVersion` and a table identifier (e.g. `utils.Version`) into the state file so
   incompatible files are detected rather than misinterpreted.
3. In the CE Utility, extend the "Normalize Cheat Table IDs" confirmation dialog with a note that
   saved states will become invalid.

---


## T11. Every memory access emits an info log line

> **✅ Resolved 2026-08-23** in Memory 1.1.0, exactly as proposed: success cases are
> `Debug` and gated behind `Memory.LogSuccessfulOperations`, default `false`.
> Failures stay at `Error`. A teleport therefore performs zero log-file writes on
> the success path instead of twelve.


🟡 [`Manifold.Memory.lua:287, 308`](../Manifold-Modules/Manifold.Modules/Manifold.Memory.lua)

```lua
logger:InfoF("%s Successfully read %s from address '%s': " .. typeInfo.format, …)
logger:InfoF("%s Successfully wrote %s " .. typeInfo.format .. " to address '%s'", …)
```

Successful operations log at **INFO**, not DEBUG. Because the logger writes every line to the
file regardless of `Level` (deliberately — see T10), each `SafeReadFloat` triggers a full
open-write-close cycle on disk.

A single teleport reads and writes at least 12 values — 12 file operations per jump. A 100 ms
timer displaying a position produces 30 per second.

**Fix.** Drop success cases to `Debug`; failures stay at `Error`:

```lua
logger:DebugF("%s Read %s @ %s: " .. typeInfo.format, …)
```

Also offer a switch to turn success logging off entirely:

```lua
Memory.LogSuccessfulOperations = false
```

---

## T12. Reading table files does not scale

🟡 [`Manifold.CustomIO.lua:33`](../Manifold-Modules/Manifold.Modules/Manifold.CustomIO.lua)

```lua
local function _readTableFile(tableFile)
    local stream = tableFile.getData()
    local bytes = stream.read(stream.Size)
    return string.char(table.unpack(bytes))
end
```

`table.unpack` pushes **every single byte as a separate argument** onto the Lua stack. Lua caps
that (`LUAI_MAXCSTACK`, in practice a few hundred thousand values) and reports
`too many results to unpack` when exceeded.

**Impact.** This affects everything loaded through `ReadFromTableFile`: embedded themes, teleporter
saves, and — via `AutoAssembler:_loadScriptText` — embedded `.CEA` scripts. Harmless for the
bundled themes (1810 bytes), but well within reach for a larger save file.

**Fix.** Process in chunks:

```lua
local function _readTableFile(tableFile)
    local stream = tableFile.getData()
    local bytes = stream.read(stream.Size)
    local chunks, CHUNK = {}, 4096
    for i = 1, #bytes, CHUNK do
        local stop = math.min(i + CHUNK - 1, #bytes)
        chunks[#chunks + 1] = string.char(table.unpack(bytes, i, stop))
    end
    return table.concat(chunks)
end
```

Where available, `readStringLocal(stream.memory, stream.size)` — which `CETrequire` itself uses —
is the more direct route.

---

## T13. The data directory is hard-coded twice

🟡 [`Manifold.CustomIO.lua:55`](../Manifold-Modules/Manifold.Modules/Manifold.CustomIO.lua),
[`Manifold.Logger.lua:24`](../Manifold-Modules/Manifold.Modules/Manifold.Logger.lua)

```lua
instance.DataDir = os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
```

Two problems:

1. **`USERPROFILE` instead of `LOCALAPPDATA`.** When LocalAppData is redirected (domain profiles,
   folder redirection, portable setups), the path points nowhere. The Template Loader already gets
   this right:

```lua
-- Manifold-TemplateLoader-Loader.lua
local function getDataRoot()
    local localAppData = safeGetEnv("LOCALAPPDATA")
    if localAppData then return localAppData end
    local userProfile = safeGetEnv("USERPROFILE")
    if userProfile then return joinPath(userProfile, "AppData", "Local") end
    return getAutorunPath()
end
```

2. **Two independent copies.** Changing `customIO.DataDir` does not move the log files. That is
   surprising and documented nowhere in the repository.

There is also no `nil` guard: if `USERPROFILE` is unset, the concatenation raises
`attempt to concatenate a nil value`.

**Fix.** One shared resolver in `CustomIO`, with the logger reading from it:

```lua
-- CustomIO
function CustomIO:ResolveDataRoot()
    local root = os.getenv("LOCALAPPDATA")
    if not root or root == "" then
        local profile = os.getenv("USERPROFILE")
        root = profile and (profile .. "\\AppData\\Local") or getAutorunPath()
    end
    return root .. "\\Manifold"
end
function CustomIO:SetDataDir(path) self.DataDir = path end

-- Logger
function Logger:_GetDataDir()
    return (customIO and customIO.DataDir) or self.DataDir
end
```

---

## T14. `EnsureDirectoryExists` is not recursive

🟡 [`Manifold.CustomIO.lua:125–134`](../Manifold-Modules/Manifold.Modules/Manifold.CustomIO.lua)

```lua
function CustomIO:EnsureDirectoryExists(path)
    …
    return self:CreateDirectory(path)   -- lfs.mkdir, one level
end
```

`lfs.mkdir` only creates the **last** level. If a parent directory is missing, the call fails. The
framework works around that by creating each level individually — which works but is fragile and
has to be repeated for every new subdirectory.

The Template Loader already has the recursive variant:

```lua
-- Manifold-TemplateLoader-File.lua
function File:EnsureFolder(path)
    …
    local parent = path:match("^(.*)/[^/]+$")
    if parent and … then self:EnsureFolder(parent) end
    …
end
```

**Fix.** Port that implementation to `CustomIO` (with `\` normalization) and keep
`CreateDirectory` as the single-level primitive.

---

## T15. CSV without quoting

🟡 [`Manifold.CustomIO.lua:340–370`](../Manifold-Modules/Manifold.Modules/Manifold.CustomIO.lua)

```lua
for value in line:gmatch("([^,]+)") do table.insert(row, value) end
...
file:write(table.concat(row, ",") .. "\n")
```

Two ways to lose data:

- **`[^,]+` skips empty fields.** `a,,c` yields `{"a", "c"}` — column 2 disappears and everything
  after it shifts.
- **No quoting on write.** A value containing a comma, a quote or a newline breaks the structure,
  and `ReadCSV` then reads back something different.

A write-read round trip is therefore not lossless.

**Fix.** Either implement it RFC 4180 compliant (quote fields containing `,`, `"` or `\n`, double
inner `"`), or — if CSV is not used by the framework at all (currently no module calls it) —
remove both functions and point to the JSON helpers instead. Half-finished CSV is worse than no
CSV.

---

## T16. `OpenDirectory` builds a shell line with `string.format`

🟡 [`Manifold.CustomIO.lua:197`](../Manifold-Modules/Manifold.Modules/Manifold.CustomIO.lua)

```lua
local success, result = pcall(os.execute, string.format('start /b "" "%s"', dir))
```

If `dir` contains a quote, it escapes the quoting and the remainder is interpreted by `cmd.exe` as
a command. Since `DataDir` lives under `%USERPROFILE%` and Windows disallows quotes in paths, the
practical risk is low — but it is an unnecessary pattern, especially since `dir` can come from the
caller.

`ProcessHandler:CloseProcess` has the same shape with `taskkill /PID %d /F` (there the value is
numeric, so it is harmless). Both also flash up a console window.

**Fix.** Use `ShellExecute` consistently — CE provides it and the CE Utility already uses it:

```lua
local ok, err = pcall(ShellExecute, dir)
```

---

## T17. `_markProcessChangedAndThrow` does not throw

🟡 [`Manifold.AutoAssembler.lua:214–221`](../Manifold-Modules/Manifold.Modules/Manifold.AutoAssembler.lua)

```lua
function AutoAssembler:_markProcessChangedAndThrow(oldPid, newPid)
    local msg = "[Auto-Assembler] The game session changed. …"
    self._processChangedMsg = msg
    …
    self:Reset("Game session changed")
    -- error(msg, 3)          ← commented out
end
```

The name, the doc comment (*"and throws an error"*) and the calling
`_checkProcessChangedOrThrow` all promise an abort. In reality execution continues: after the
`Reset`, `st.DisableInfo == nil`, so the script gets **enabled** — even when the user meant to
disable it.

This may well be deliberate (nicer than an error dialog), but the code says the opposite.
`_processChangedMsg` is assigned and never read — dead state.

**Fix.** Decide and document. If the current behaviour is intended:

```lua
function AutoAssembler:_handleProcessChanged(oldPid, newPid)
    -- After a session change every DisableInfo is stale. Reset and let the current
    -- call proceed as a fresh ENABLE.
    logger:ForceWarningF("[Auto-Assembler] New game session (PID %s -> %s). State reset.",
        tostring(oldPid), tostring(newPid))
    self:DisableAllWithoutExecute()
    self:Reset("Game session changed")
end
```

Rename `_checkProcessChangedOrThrow` to `_checkProcessChanged` accordingly and drop
`_processChangedMsg`.

---

## T23. `Logger` and `CustomIO` can recurse without bound

🟠 [`Manifold.Logger.lua:174`](../Manifold-Modules/Manifold.Modules/Manifold.Logger.lua) and [`Manifold.CustomIO.lua:175`](../Manifold-Modules/Manifold.Modules/Manifold.CustomIO.lua)

```
Logger:_WriteToLogFile -> _EnsureLogDirectories -> customIO:CreateDirectory
                                                        |
                       (on failure)  logger:Error  <----+
                              |
                              +-> Logger:_DispatchLog -> _WriteToLogFile -> ...
```

`Logger:_DispatchLog` writes to the file *before* it applies the level filter (by design — see T10
in the checklist, which records that as deliberate), so every line at every level walks `_EnsureLogDirectories`. That calls
`customIO:CreateDirectory`, which calls `logger:Error` when it fails — and straight back in.

**Impact.** Unbounded mutual recursion, ending in a stack overflow. It triggers on exactly the
machine the logging exists to diagnose: an end-user box where
`%USERPROFILE%\AppData\Local\Manifold\Logs` cannot be created. It affects `CustomIO`, `Patcher`
and `State` equally — `Manifold.Json` and `Manifold.Bootstrap` pcall their own log calls, which
protects their callers but not the cycle itself.

**Fix.** One reentrancy latch in the logger, which is where the cycle closes:

```lua
function Logger:_WriteToLogFile(formattedMessage)
    if self._writingToFile then return end     -- a failure inside the write must not re-enter
    self._writingToFile = true
    if self:_EnsureLogDirectories() then
        customIO:AppendToFile(self:_GetLogFilePath(), formattedMessage)
    end
    self._writingToFile = nil
end
```

Five lines, no new dependency, and it makes the `pcall`s in `Manifold.Json` and
`Manifold.Bootstrap` belt-and-braces rather than load-bearing.

---

## T24. Teleporter assigns to a `for` control variable

🔵 [`Manifold.Teleporter.lua:615`](../Manifold-Modules/Manifold.Modules/Manifold.Teleporter.lua) and [`Manifold-TemplateLoader-UI.lua:57`](../Manifold-TemplateLoader/Manifold-TemplateLoader-Modules/Manifold-TemplateLoader-UI.lua)

```lua
for part in normalized:gmatch("[^/]+") do
    part = trimString(part)
```

Legal in Lua 5.1–5.4, which is what Cheat Engine ships. **Lua 5.5 made generic-`for` control
variables constant**, so this raises `attempt to assign to const variable 'part'` at load time
there. Two files are affected — `Manifold.Teleporter` (both the `categoryInput` table branch and the
string branch) and `Manifold-TemplateLoader-UI` (`gmatch("[^>]+")` over the category path). They
are the only two files in either segment that a 5.5 interpreter cannot parse.

**Impact.** None today. It becomes a hard load failure the day Cheat Engine updates its Lua, and
it already blocks parsing the module with modern tooling.

**Fix.** Use a second local:

```lua
for rawPart in normalized:gmatch("[^/]+") do
    local part = trimString(rawPart)
```

All three occurrences — the two in `Manifold.Teleporter` and the one in
`Manifold-TemplateLoader-UI`.

---

## T25. Three game-specific custom types live in Utils

🔵 [`Manifold.Utils.lua`](../Manifold-Modules/Manifold.Modules/Manifold.Utils.lua) — `RegisterTimeTypes`, `RegisterDecryptionType`, `RegisterPlaytimeMilitaryType`

All three register CE custom types for a *specific game* — the call sites in the shipped table
script name them: Dying Light, Monster Hunter Wilds, Mewgenics. All three have **zero callers
anywhere in the repository**, and in the reference table script all three are commented out.

They are the clearest example of what makes `Manifold.Utils` hard to describe in one sentence:
they are not framework code, they are per-table code that happens to live in the framework.

**Fix.** Not urgent and not obviously worth a module of its own. The options, in order of
increasing effort: leave them and label the block honestly; move them to an opt-in
`Manifold.CustomTypes` that only tables needing them load; or delete them and let each table
register its own, since that is where the knowledge actually belongs.

---

# Template Loader

## T2. `BaseAddressRegister` is always empty in the template context

> **✅ Resolved 2026-08-23**, as proposed, with three additions.
> * The two patterns are anchored (`^%s*...%s*$`) against the extracted `[...]`
>   operand rather than run over the whole instruction, so a scaled index such as
>   `[rax+rcx*4+30]` no longer half-matches.
> * `rip`/`eip` are rejected: `[rip+1234]` parses as a base+offset but
>   `mov [Ptr],rip` does not assemble, and the address it names is already
>   absolute.
> * Anything more complex returns nil rather than a partial answer. A partial
>   answer would silently generate a script capturing the WRONG pointer; nil
>   keeps the existing loud failure for the genuinely ambiguous cases, and the
>   new warning at the call site names the instruction and the affected template
>   families.
>
> Verified empirically before and after: the shipped pattern returned `nil,nil`
> for every real disassembly and matched only `"[rax+30?]"`, confirming the `?`
> was being treated as a literal character.


🔴 [`Manifold-TemplateLoader-Memory.lua:336`](../Manifold-TemplateLoader/Manifold-TemplateLoader-Modules/Manifold-TemplateLoader-Memory.lua)

```lua
local register, offset = instruction:match("%[([%a][%w]*)%s*([+-]%s*[%x]+)?%]")
```

Lua patterns are **not** regular expressions. Quantifiers (`*`, `+`, `-`, `?`) apply to a
**single** character class only, never to a group. The `?` after the closing `)` is therefore
matched as a **literal question mark**. The pattern demands something like `[rax+30?]`, which no
disassembly ever produces.

**Impact.** `GetRegisterData` always returns `nil, nil`. The context then carries
`BaseAddressRegister = ""` and `BaseAddressOffset = "0"`. Every template using
`<< BaseAddressRegister >>` — all **Pointer Hooks**, both **Conditional Hooks — Extended** and the
**Transform Base Address Pointer Hook**, so 11 of the 17 bundled templates — emits lines like:

```asm
mov [MyHookPtr],          ← operand missing, assembly fails
```

**Verify** (Cheat Engine Lua console):

```lua
print(("mov [rax+30],eax"):match("%[([%a][%w]*)%s*([+-]%s*[%x]+)?%]"))  --> nil
print(("mov [rax+30],eax"):match("%[([%a][%w]+)([+-]%x+)%]"))           --> rax  +30
```

**Fix.** Two passes instead of one optional group:

```lua
function Memory:GetRegisterData(instruction)
    if type(instruction) ~= "string" then return nil, nil end
    -- 1) [reg+off] / [reg-off]
    local register, offset = instruction:match("%[%s*([%a][%w]*)%s*([+-]%s*%x+)%s*%]")
    if register then
        offset = offset:gsub("%s+", "")
        if offset:sub(1, 1) == "+" then offset = offset:sub(2) end
        return register, offset
    end
    -- 2) [reg]
    register = instruction:match("%[%s*([%a][%w]*)%s*%]")
    if register then return register, "0" end
    return nil, nil
end
```

Worth adding: log a warning when a template uses `<< BaseAddressRegister >>` but the value is
empty.

---


## T20. Callback hooks are chained inconsistently

🟡 [`Manifold.Callbacks.lua:299–360`](../Manifold-Modules/Manifold.Modules/Manifold.Callbacks.lua)

`OnAutoAssemblerEdit` saves the previous handler and calls it:

```lua
local o_AddressList_OnAutoAssemblerEdit = AddressList.OnAutoAssemblerEdit
AddressList.OnAutoAssemblerEdit = function(addresslist, memrec) … end
```

The other four do **not** — they replace outright:

```lua
AddressList.OnDescriptionChange = function(addresslist, memrec) … end
AddressList.OnAddressChange     = function(addresslist, memrec) … end
AddressList.OnTypeChange        = function(addresslist, memrec) … end
AddressList.OnValueChange       = function(addresslist, memrec) … end
```

If the Cheat Table (or another autorun script) installed its own handler, it is lost when
`Manifold.Callbacks` loads.

**Fix.** One shared installer:

```lua
local function installGuard(eventName, optionName, actionName)
    local previous = AddressList[eventName]
    AddressList[eventName] = function(addresslist, memrec)
        if callbacks:_HandleProtectedChange(optionName, actionName, memrec, eventName) then
            return true
        end
        if previous then
            local ok, blocked = pcall(previous, addresslist, memrec)
            if ok and blocked then return true end
        end
        return false
    end
end

installGuard("OnDescriptionChange", "DisableDescriptionChange", "Description change")
installGuard("OnAddressChange",     "DisableAddressChange",     "Address change")
installGuard("OnTypeChange",        "DisableTypeChange",        "Type change")
installGuard("OnValueChange",       "DisableValueChange",       "Value change")
```

---

## T21. Documentation and version drift

🔵 Four concrete mismatches between code and description:

| Location | Claim | Reality |
|---|---|---|
| [`Manifold-Modules/README.md`](../Manifold-Modules/README.md) | `Manifold.CustomIO.GetDataDir()` | Does not exist — only the field `customIO.DataDir` |
| [`Manifold-CE-Utility/README.md`](../Manifold-CE-Utility/README.md) | Menu "Manifold > Settings" | The entry is called "Session Settings" |
| [`Manifold.Utils.lua:3`](../Manifold-Modules/Manifold.Modules/Manifold.Utils.lua) | `VERSION = "1.0.3"` | The changelog right below already documents `v1.0.5` |
| [`Manifold.AutoAssembler.lua:209`](../Manifold-Modules/Manifold.Modules/Manifold.AutoAssembler.lua) | `@return nil` / "throws an error" | Does not throw ([T17](#t17-_markprocesschangedandthrow-does-not-throw)) |

Also: `ProcessHandler.AutoAttachTimerTickMax` is declared and never read — dead field.

**Fix.** Source the module version from a single place and add a CI check (or a successor to
`codelines.cmd`) verifying that the top changelog entry matches the `VERSION` constant. It is a
five-line script and prevents exactly this class of drift.

---


# Larger refactors

Bigger changes that resolve several items above at once.

## R-A. A real namespace

The framework currently occupies around 30 global names: 15 classes (`Logger`, `CustomIO`, `UI`,
…) and 15 instances (`logger`, `customIO`, `ui`, …), plus `JSON`, `Forms`, `Trampolines`. Every one
of them can collide with another autorun or table script. A namespace table is already assumed in
one place: `Manifold.UI` reads `Manifold.Setup.IsRelease`, which the Cheat Table's own Lua script
is expected to provide.

```lua
-- Manifold.Core.lua (new)
Manifold = rawget(_G, "Manifold") or {
    Version = "2.0.0",
    Setup   = { IsRelease = false },
    Class   = {},     -- Manifold.Class.Logger, …
    Modules = {},     -- Manifold.Modules.logger, …
}

function Manifold.Require(name)
    local short = name:match("Manifold%.(.+)$") or name
    if Manifold.Modules[short] then return Manifold.Modules[short] end
    local class = CETrequire(name)
    …
end
```

The migration can stay backwards compatible by keeping the old globals as aliases:

```lua
for name, instance in pairs(Manifold.Modules) do _G[name] = instance end
```

That also makes `Manifold.Setup.IsRelease` valid without touching line 694.

## R-B. Shared dependency bootstrapping

> **✅ Shipped 2026-08-23** as [`Manifold.Bootstrap.lua`](../Manifold-Modules/Manifold.Modules/Manifold.Bootstrap.lua).
> All fifteen production modules use it. The sketch below is kept for history; what
> actually shipped differs in five ways worth knowing:
>
> * **Refuse and report, not auto-load.** `Bootstrap.Resolve` never loads anything.
>   A missing `required` dependency raises out of `New()` naming the dependency,
>   instead of the module quietly pulling it in. Auto-loading is what made
>   `Manifold.Forms` and `Manifold.Trampolines` appear in tables that never asked
>   for them. `Settings.AutoLoad = true` restores the old behaviour.
> * **Three dependency kinds.** `required` (refuses), plain (counted, survivable)
>   and `runtime` (documented only, never ordered on). The last is what makes the
>   `UI ↔ Teleporter` and `AutoAssembler ↔ ProcessHandler` cycles harmless.
> * **One `Info` line per module** at the end of `New()`, carrying name and version.
>   A second line for the same module is the collision signal.
> * **`Bootstrap.ORDER`** is the order of execution as data, and `Bootstrap.Verify()`
>   proves every load-time dependency sits earlier in it. Because each edge must
>   point strictly backwards in a linear array, an order that verifies cannot
>   contain a load-time cycle.
> * **The registry survives re-execution.** The published API table is created once
>   and mutated in place, so a module's captured `local BOOTSTRAP` stays valid after
>   `CETrequire` runs the core again — which it does, see
>   [R-C](#r-c-cetrequire-with-a-module-cache).
>
> The `validate` field the sketch proposed also shipped, as the `Validate`/`Contract`
> split: `Validate` checks metatable identity *and* usability, `Contract` only
> usability. An instance orphaned by a re-require still answers its calls, so it is
> reported as a collision and **kept**, not silently rebuilt behind live state.


`CheckDependencies` exists in six modules in four slightly different variants — two of them with
the logger bug from [T4](#t4-statecheckdependencies-uses-the-logger-before-it-exists).

```lua
-- Manifold.Bootstrap.lua (new)
local Bootstrap = {}

local function safeLog(level, message)
    local lg = rawget(_G, "logger")
    if lg and lg[level] then lg[level](lg, message) else print(message) end
end

function Bootstrap.Ensure(dependencies)
    for _, dep in ipairs(dependencies) do
        local existing = rawget(_G, dep.name)
        if existing == nil or (dep.validate and not dep.validate(existing)) then
            safeLog("Warning", ("[Bootstrap] Loading '%s'…"):format(dep.name))
            local ok, err = pcall(CETrequire, dep.path)
            if ok and dep.init then
                local initOk, initErr = pcall(dep.init)
                if not initOk then safeLog("Error", tostring(initErr)) end
            elseif not ok then
                safeLog("Error", ("[Bootstrap] '%s' failed: %s"):format(dep.name, tostring(err)))
            end
        end
    end
end

return Bootstrap
```

The `validate` field also resolves [T7](#t7-json-instances-do-not-survive-a-module-reload):

```lua
{ name = "json", path = "Manifold.Json",
  init = function() json = JSON:new() end,
  validate = function(j) return pcall(function() return j:encode({}) end) end }
```

## R-C. `CETrequire` with a module cache

> **Still open, but no longer silent.** As of 2026-08-23 `Manifold.Bootstrap` reports every
> re-execution as `RELOAD gen N` with the affected modules listed, and keeps orphaned-but-working
> instances rather than rebuilding them behind live state. That turns this from a corruption
> into a diagnosable event — the cache is still the actual fix.


`CETrequire` runs `dofile`/`load` on every call. That is the root cause of the JSON instance
invalidation and makes ordering problems needlessly sharp.

```lua
local _manifoldModuleCache = {}

function CETrequire(moduleStr, forceReload)
    if not moduleStr then return end
    if not forceReload and _manifoldModuleCache[moduleStr] ~= nil then
        return _manifoldModuleCache[moduleStr]
    end
    local result = _manifoldLoadModule(moduleStr)   -- existing logic
    if result ~= nil then _manifoldModuleCache[moduleStr] = result end
    return result
end
```

Keep `forceReload` — during development you deliberately want to reload modules. In that case the
matching instance should be recreated too, which is what `Bootstrap.Ensure` with `validate` is
for.

`CETrequire` should also **raise** on an unknown module instead of silently returning `nil`;
otherwise a typo in a module name only surfaces at first use.

## R-D. Structured logging instead of text lines

The logger serializes everything to text. A structured variant would help diagnostics, especially
for `Trampolines:_logInstall`, which emits 13 separate lines:

```lua
logger:Event("trampoline.install", {
    name = entry.Name,
    inject = getNameFromAddress(entry.InjectAddress),
    relay = getNameFromAddress(entry.RelayAddress),
    overwrite = entry.OverwriteSize,
})
```

Written as JSON lines to a file, that becomes machine-analysable — for instance to find out which
hook sites regularly fail to take a detour.

## R-E. Contract checking for the template context

A template writing `<< HookNamePased >>` (typo) produces an empty string through `_safe` and a
silently broken script. `_safe` should report unknown identifiers:

```lua
local KNOWN = { HookName = true, HookNameParsed = true, Module = true, … }

setmetatable(environment, {
    __index = function(t, key)
        if KNOWN[key] == nil and _G[key] == nil then
            log:Warning(("[Loader] Unknown context variable '%s' in template."):format(key))
        end
        return _G[key]
    end
})
```

That would have surfaced [T2](#t2-baseaddressregister-is-always-empty-in-the-template-context)
earlier too — there the variable is known but empty. Complementary:

```lua
environment._safe = function(value)
    if value == nil or value == "" then
        log:Debug("[Loader] Empty value in a << >> block.")
    end
    return value == nil and "" or tostring(value)
end
```

## R-F. Reproducible release builds

Switching between development mode (the `luaFiles` directory) and release mode (embedded table
files) is manual today; `Utils:RemoveTableFilesByExtension` hints at a hand-run procedure.

A small build script that embeds the modules into a `.CT`, stamps version numbers and fills in the
MD5 hash for `Utils.MD5Hash` would make this reproducible — and would prevent the version drift
from [T21](#t21-documentation-and-version-drift) at the same time.

---

# What is already solid

For completeness — several parts are notably well built and should not be "cleaned up":

- **Host/Loader split in the Template Loader.** `registerFormAddNotification` cannot be
  unregistered. Keeping the notification in a persistent host and swapping only the Loader instance
  is the right answer — and the comment about the `TfrmAutoInject` collision with the
  "Execute Table Lua Script" window documents a trap nobody would otherwise rediscover.

- **Transactional ID normalization** in the CE Utility. Going through a collision-free temp range
  is exactly the step a naive implementation omits — and without it, a failure mid-renumbering
  would corrupt the table.

- **Two-stage rollback in the AutoAssembler.** Detour transaction and script transaction are
  separate and interlock; on failure the bytes roll back first, then the scripts.

- **Sandbox for template settings.** Treating settings files as data rather than plugins is the
  right boundary — including the rationale in the file header.

- **Process watch fallback.** Realising that a `readInteger(process)` probe misses a restart under
  the same process name, and that the PID has to be compared as well, is a lesson from practice.
  The generation counter that cleanly terminates stale threads belongs to it.

- **`FindTemporaryIdBase`, `_collectInstructionRange`, `mergeKnown`** — three places where the
  harder correct path was chosen over the obvious one.
