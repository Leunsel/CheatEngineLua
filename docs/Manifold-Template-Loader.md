# Manifold Template Loader

> Directory: [`Manifold-TemplateLoader/`](../Manifold-TemplateLoader/)
> Version: 2.0.0 · License: MIT · Authors: Leunsel, LeFiXER

An autorun system that registers custom **Auto Assembler templates** with Cheat Engine. Picking a
template fills a `.CEA` script with data from the current disassembler selection (address, module,
original bytes, unique AoB signature, jump size, allocation statement, …) and writes the result
into the open Auto Assembler window.

---

## 1. Installation

Both parts belong in the `autorun` folder:

```
autorun/
├── Manifold-TemplateLoader-Main.lua          ← entry point
├── Manifold-TemplateLoader-Modules/          ← 8 Lua modules
│   ├── Manifold-TemplateLoader-Host.lua
│   ├── Manifold-TemplateLoader-Loader.lua
│   ├── Manifold-TemplateLoader-Manager.lua
│   ├── Manifold-TemplateLoader-Memory.lua
│   ├── Manifold-TemplateLoader-UI.lua
│   ├── Manifold-TemplateLoader-File.lua
│   ├── Manifold-TemplateLoader-Log.lua
│   └── Manifold-TemplateLoader-Json.lua
└── Manifold-TemplateLoader-Templates/        ← *.CEA + *.Settings.lua
```

`Manifold-TemplateLoader-Main.lua` extends `package.path` with the module directory, creates the
`Loader` and the `Host`, wires them together and calls `LoadTemplates()`:

```lua
local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Host   = require("Manifold-TemplateLoader-Host")
local Loader = require("Manifold-TemplateLoader-Loader")

local activeLoader = Loader:New()
local host = Host:New()
host:Attach(activeLoader)

_G.ManifoldTemplateLoaderHost = host
_G.ManifoldTemplateLoader     = host.Loader
loader = activeLoader          -- backwards compatibility

host.Loader:LoadTemplates()
```

> **Important:** the bundled templates use `ManifoldScanModule` and `ManifoldAssert`. Those Auto
> Assembler commands come from the **Manifold Framework** (`Manifold.AssemblerCommands`), not from
> the Loader. Without the framework loaded you have to switch the templates to `aobScanModule` —
> `Default Injection Hook.CEA` already ships that line commented out.

---

## 2. Architecture

```
Manifold-TemplateLoader-Main.lua
│
├─ Host          persistent, NOT part of the reload set
│                 └─ owns the single registerFormAddNotification
│
└─ Loader        the swappable implementation
     ├─ Manager   template discovery + settings validation
     ├─ Memory    context from the target process (address, bytes, AoB, …)
     ├─ UI        menu tree + categorization
     ├─ File      defensive file-system wrapper
     ├─ Log       five-level logging
     └─ Json      JSON for the configuration file
```

### Why a host?

`registerFormAddNotification` cannot be unregistered in Cheat Engine. If the Loader registered it
itself, every hot reload would leave behind another dead registration pointing at an old Loader
instance.

The host solves that: it registers the notification **exactly once** and forwards it to
`self.Loader` — that is, to whichever instance is currently active. This is what makes it possible
to replace the Loader entirely without restarting Cheat Engine.

```lua
registerFormAddNotification(function(form)
    if self.Loader and isAutoInjectForm(form) then
        self.Loader:TrackAutoInjectForm(form)
    end
end)
```

The host deliberately skips the initial form scan: Cheat Engine's **"Execute Table Lua Script"**
window is also a `TfrmAutoInject` and would otherwise be mistaken for an Auto Assembler window —
a failure that is practically impossible to track down. Instead it waits for newly opened windows.

---

## 3. Templates

A template always consists of **two files** sharing a base name in
`Manifold-TemplateLoader-Templates/`:

| File | Contents |
|---|---|
| `<Name>.CEA` | The template with placeholders |
| `<Name>.Settings.lua` | Metadata (caption, menu, options) |

There is also a special file `Header.CEA` — it is not registered as a template but included by
every other template through `<< Header >>`.

### 3.1 Settings file

```lua
return {
    Caption                = "Pointer Hook",
    Shortcut               = "",
    InSubMenu              = true,
    SubMenuName            = "[1] Hooks > Pointer",
    MenuOrder              = 10,
    AskForInjectionAddress = true,
    AskForHookName         = true,
    AppendToHookName       = "Hook",
    AllocationSize         = "$1000",
    AllocationNear         = true,
    DefaultHookName        = "Injection"
}
```

| Key | Type | Default | Description |
|---|---|---|---|
| `Caption` | string | file name | Menu text. **Must be unique**; duplicate captions are skipped. |
| `Shortcut` | string | `""` | Keyboard shortcut. Conflicts are reported and the second one is disabled. |
| `InSubMenu` | boolean | `true` | `false` ⇒ entry sits directly in the template root menu |
| `SubMenuName` | string | `"Templates"` | Category path; `>` creates nesting |
| `MenuOrder` | number | `math.huge` | Ordering within the category |
| `AskForInjectionAddress` | boolean | memory default | Prompt for the address instead of using the disassembler selection |
| `AskForHookName` | boolean | memory default | Prompt for the hook name |
| `AppendToHookName` | string | memory default | Suffix for the scan symbol |
| `AllocationSize` | string \| number | memory default | `"$1000"` or a decimal number |
| `AllocationNear` | boolean | memory default | `alloc(n_X, size, HookName)` instead of `alloc(n_X, size)` |
| `DefaultHookName` | string | memory default | Pre-fills the prompt |

Template settings **override** the global memory defaults for that one template
(`Loader:GetMemoryOverrides`).

### 3.2 Sandbox

Settings files are **data, not plugins**. They run in a minimal environment:

```lua
{ ipairs, pairs, tonumber, tostring, math, string, table }
```

No `io`, no `os`, no Cheat Engine API, no `_G`. A settings script can therefore neither read files
nor touch the process. `Manager:ValidateSettings` then checks every type and produces a concrete
error message that lands in the log.

### 3.3 Menu categories

`SubMenuName` is split at `>` into path segments, which become a nested menu:

```
"[1] Hooks > Pointer > ReadMem"
   ↓
Template ▸ Hooks ▸ Pointer ▸ ReadMem ▸ <Caption>
```

A bracketed prefix (`[1]`, `[2]`, …) controls **ordering only** and is not shown in the menu
(`categoryCaption`). The bundled templates use:

| Prefix | Category |
|---|---|
| `[1]` | x86/x64 — Pointer Hooks |
| `[2]` | x86/x64 — Pointer Hooks — ReadMem |
| `[3]` | x86/x64 — Conditional Hooks |
| `[4]` | x86/x64 — Conditional Hooks — ReadMem |
| `[5]` | x86/x64 — Byte Patch Hooks |
| `[6]` | x86/x64 — Default Hooks |
| `[7]` | x86/x64 — Teleporter Hooks |
| `[8]` | x86/x64 — Static Address Resolver |

Ordering within a category: `MenuOrder` ascending, ties broken alphabetically by caption
(case-insensitive).

---

## 4. Template syntax

The template engine knows two tags:

| Tag | Meaning |
|---|---|
| `<< expression >>` | Evaluate a Lua expression and insert it (through `_safe`, `nil` ⇒ `""`) |
| `<% code %>` | Execute Lua statements, insert nothing |

Everything outside the tags is copied verbatim. Compilation turns the template into a Lua chunk:

```lua
local _ret = {}
_ret[#_ret + 1] = "[ENABLE]\n"
_ret[#_ret + 1] = _safe((HookNameParsed))
...
return table.concat(_ret)
```

The chunk runs with the context as its environment; `setmetatable(environment, {__index = _G})`
lets advanced templates still reach global CE functions.

An unclosed block is reported with a line number: `Unclosed << block at line 12`.

### Example with control flow

```
<% if IsTarget64Bit then %>
  mov rax,[<< HookName >>Ptr]
<% else %>
  mov eax,[<< HookName >>Ptr]
<% end %>
```

### Example: a complete template

```
<< Header >>

[ENABLE]

ManifoldScanModule(<< HookNameParsed >>,<< Module >>,<< AoBStr >>)
<< Alloc >>

ManifoldAssert(<< HookNameParsed >>,<< OriginalBytes >>)

label(o_<< HookName >> r_<< HookName >>)

n_<< HookName >>:

o_<< HookName >>:
<< OriginalOpcodes >>
  jmp r_<< HookName >>

<< HookNameParsed >><< AoBOffset >>:
  << JumpType >> n_<< HookName >>
  << NopPadding >>
r_<< HookName >>:
registersymbol(<< HookNameParsed >>)

[DISABLE]

<< HookNameParsed >><< AoBOffset >>:
  db << OriginalBytes >>

unregisterSymbol(*)
dealloc(*)
```

---

## 5. Context variables

`Memory:GetMemoryInfo(overrides)` builds the environment. Full list:

### Metadata

| Variable | Type | Example |
|---|---|---|
| `Version` | string | `"2.1.0"` |
| `Date` | string | `"2026-08-21"` |
| `Time` | string | `"14:32:05"` |
| `DateTime` | string | `"2026-08-21 14:32:05"` |

### Process and module

| Variable | Type | Description |
|---|---|---|
| `Process` | string | `"Game.exe"` |
| `ProcessBase` | string | Base address of the main module, formatted |
| `Module` | string | Module containing the injection address |
| `ModuleBase` | string | Base address of that module, formatted |
| `IsTarget64Bit` | boolean | |

### Address and signature

| Variable | Type | Description |
|---|---|---|
| `Address` | string | Resolved display name, e.g. `"Game.exe+1255B5B"` |
| `AddressValue` | number | Numeric address |
| `AoBStr` | string | Unique AoB signature (`getUniqueAOB`) |
| `AoBOffset` | string | `"+3F"` or `""` — offset of the address inside the signature |

`AoBStr` and `AoBOffset` belong together: the scan finds the start of the signature, `AoBOffset`
shifts to the actual injection site. That is why templates always write
`<< HookNameParsed >><< AoBOffset >>:`.

### Jump and bytes

| Variable | Type | Description |
|---|---|---|
| `Is14ByteJump` | boolean | State of `mi14ByteJMP` in the AA window |
| `MinJumpSize` | number | `14` or `5` |
| `JumpType` | string | `"jmp far"` or `"jmp"` |
| `JumpSize` | number | Bytes actually overwritten (whole instructions ≥ `MinJumpSize`) |
| `SelectionSize` | number | Size of the **first** instruction only |
| `OriginalInstruction` | string | Disassembled first instruction |
| `OriginalOpcodes` | string | All overwritten instructions, one per line, indented by two spaces |
| `OriginalBytes` | string | `"48 8B 41 34 89 45 08"` |
| `NopPadding` | string | `"db 90 90\n"` or `""` |

### Pointers

| Variable | Type | Description |
|---|---|---|
| `PointerType` | string | `"dq"` (x64) or `"dd"` (x86) |
| `PointerSize` | number | `8` or `4` |
| `DefaultPointerBytes` | number | Identical to `PointerSize` |
| `BaseAddressRegister` | string | Register from `[reg+off]` of the first instruction, otherwise `""` |
| `BaseAddressOffset` | string | The offset from it, otherwise `"0"` |

> `BaseAddressRegister` / `BaseAddressOffset` are currently always empty due to a pattern bug —
> see [TODO T2](TODO.md#t2-baseaddressregister-is-always-empty-in-the-template-context).

### Hook and allocation

| Variable | Type | Description |
|---|---|---|
| `HookName` | string | Normalized symbol name (`[%w_]` only, leading digit ⇒ `_` prefix) |
| `HookNameParsed` | string | `HookName .. AppendToHookName`, e.g. `"HealthHook"` |
| `Alloc` | string | `alloc(n_<Hook>, <Size>[, <HookNameParsed>])` |
| `GlobalAlloc` | string | `alloc(n_<Hook>, <Size>)` — never with the near parameter |

### Injection info and options

| Variable | Type | Description |
|---|---|---|
| `InjectionInfo` | string | Surrounding instructions as text (see `Header.CEA`) |
| `InjInfoLineCount` | number | |
| `InjInfoRemoveSpaces` | boolean | |
| `InjInfoAddTabs` | boolean | |
| `AppendToHookName` | string | Effective value |
| `AskForHookName` | boolean | |
| `AskForInjectionAddress` | boolean | |
| `AllocationSize` | string | |
| `AllocationNear` | boolean | |
| `MonoSupportStatus` | string | Placeholder — Mono is not implemented |

### Others

| Variable | Type | Description |
|---|---|---|
| `Header` | string | Compiled `Header.CEA` |
| `TemplateSettings` | table | This template's settings table |
| `FinalCompilation` | boolean | Always `false` |
| `_safe(v)` | function | `nil` ⇒ `""`, otherwise `tostring(v)` |

---

## 6. Menu in the Auto Assembler window

When an Auto Assembler window opens, `Loader:SetupMenu(form)` runs 50 ms later. It builds two
things:

1. **Under `Template`** — the categorized template entries (separated from Cheat Engine's own
   `CheatTablecompliantcodee1` entry by a separator).
2. **In the main menu bar** — the `Template Loader` menu.

### The "Template Loader" menu

| Entry | Sub-entries |
|---|---|
| **Template settings** ▸ | Set info line count… · Remove spaces ☑ · Indent information ☑ · Hook-name suffix… |
| **Memory defaults** ▸ | Ask for hook name ☑ · Ask for injection address ☑ · Allocate near injection ☑ · Set allocation size… · Default hook name… |
| **Logging** ▸ | Log level ▸ (DEBUG/INFO/WARNING/ERROR) · Write log file ☑ · View log file |
| *— separator —* | |
| **Reload templates (new AA windows)** | Rediscover and re-register templates |
| **Hot reload modules and templates** | Full module restart |
| **Open template folder** | Explorer in the template directory |
| **Reset configuration** | Back to defaults (with a prompt) |

Every change is written to the configuration file immediately (`SaveConfig`).

`SetupMenu` also applies a few cosmetic window properties:

```lua
form.Assemblescreen.ScrollBars = "ssAutoBoth"
form.Assemblescreen.RightEdge  = -1
form.Panel2.BorderStyle        = "bsNone"
```

---

## 7. Configuration

File:

```
%LOCALAPPDATA%\Manifold\TemplateLoader\Manifold-TemplateLoader-Config.json
```

An older location (`autorun\Manifold-TemplateLoader-Modules\…-Config.json`) is read at startup and
migrated to the new one automatically.

```json
{
  "SchemaVersion": 3,
  "Logger":        { "Level": "ERROR", "LogToFile": true },
  "InjectionInfo": { "LineCount": 3, "RemoveSpaces": true, "AddTabs": true,
                     "AppendToHookName": "Hook" },
  "Memory":        { "AskForHookName": true, "AskForInjectionAddress": false,
                     "AllocationSize": "$1000", "AllocationNear": true,
                     "DefaultHookName": "Injection" }
}
```

`mergeKnown` only accepts **known keys with a matching type**. Unknown fields or wrong types are
silently replaced by the default, so a corrupted configuration file cannot break the Loader. If
the file cannot be parsed at all, the defaults are used **without** overwriting the file.

`ApplyConfig` pushes every value through the matching `Memory:Set…` setter. If a setter rejects a
value, the field falls back to the default and the corrected value is written back.

---

## 8. Reload behaviour

There are two levels, and the difference matters:

### "Reload templates (new AA windows)" — `Loader:ReloadTemplates()`

```
RefreshTemplates()
 ├─ manager:DiscoverTemplates()          rediscover templates
 ├─ abort when 0 were found              (the existing set stays active)
 ├─ CreateRegistrationPlan()             validate captions/shortcuts
 ├─ UnloadTemplates()                    unregister the old callbacks
 ├─ LoadTemplates(new)                   register the new ones
 │    └─ on failure ⇒ restore the previous set
 └─ TemplateGeneration + 1
```

- Already **open** Auto Assembler windows are left untouched.
- A **new** window gets the current generation and therefore the new menus.
- `SetupMenu` checks `FormTemplateGeneration[form] == TemplateGeneration` and skips windows from
  an older generation.

### "Hot reload modules and templates" — `Host:HotReload()`

```
StageHotReload()
 ├─ LoadCandidate()          reload all 7 modules (clearing package.loaded)
 │                            on failure ⇒ restore the old cache, abort
 ├─ candidate:New()
 ├─ CreateRegistrationPlan() validate the candidate
 └─ timer 50 ms ─────────────────────────────┐
                                             ▼
CommitHotReload()
 ├─ previousLoader:DestroyAutoInjectForms()   closes ALL AA windows ⚠️
 └─ timer 50 ms ─────────────────────────────┐   (TForm.Close is deferred)
                                             ▼
FinishHotReload()
 ├─ previousLoader:UnloadTemplates()
 ├─ candidate:AdoptRuntimeState(previous)
 ├─ candidate:LoadTemplates()
 │    └─ on failure ⇒ restore the old module cache and the old set
 ├─ Host.Loader = candidate
 └─ candidate:AdvanceTemplateGeneration()
```

⚠️ **Unsaved scripts in open Auto Assembler windows are lost.** That is intentional: Cheat Engine
holds menu references to the old template callbacks, which would become invalid on the swap.

The two 50 ms timers are necessary because `TForm.Close` defers destruction until Cheat Engine
returns to its message loop. Without those pauses the registrations would be swapped while CE
still holds menu entries from the old generation.

---

## 9. Module reference

### Manifold-TemplateLoader-Host

Singleton. Not part of the reload set.

| Function | Description |
|---|---|
| `Host:New()` | Singleton |
| `host:Attach(loader)` | Sets `Loader`, updates `_G.ManifoldTemplateLoader`/`_G.loader`, registers the form notification once |
| `host:HotReload()` | Starts the full restart |
| `host:StageHotReload()` | Load and validate the candidate |
| `host:CommitHotReload(...)` | Close the AA windows |
| `host:FinishHotReload(...)` | Swap the registrations |
| `host:LoadCandidate()` | Reloads all 7 modules with cache rollback |
| `host:RestoreModuleCache(candidateSet)` | |
| `host:TrackOpenForms()` | Initial scan (deliberately **not** called) |
| `host:Log(message [, isError])` | Forwards to `Loader:LogReload` |

### Manifold-TemplateLoader-Loader

Singleton, the central controller.

| Area | Functions |
|---|---|
| Configuration | `LoadConfig`, `SaveConfig`, `CreateConfig`, `ResetConfig`, `ApplyConfig` |
| Discovery | `DiscoverTemplates`, `GetTemplateDefinitions`, `CreateRegistrationPlan` |
| Registration | `RegisterTemplate`, `LoadTemplates`, `UnloadTemplates` |
| Reload | `RefreshTemplates`, `ReloadTemplates`, `ReloadDependencies`, `AdvanceTemplateGeneration`, `AdoptRuntimeState`, `QueueHotReloadUIRefresh`, `ScheduleTemplateMenuRebuild` |
| Compilation | `GetEnvironment`, `GetMemoryOverrides`, `Compile`, `CompileFile`, `CompileHeaderTemplate`, `AppendLiteral`, `ApplyCompiledTemplate`, `GetTemplateScript`, `ReportTemplateError` |
| Menu | `GetMenuIndices`, `BuildUICallbacks`, `BuildMenu`, `RemoveOldMenuEntries`, `SetupMenu`, `RebuildOptionsMenu`, `RebuildOptionsMenus`, `CleanupTemplateMenus`, `RebuildTemplateMenus`, `AttachMenuToForm` |
| Forms | `TrackAutoInjectForm`, `GetTrackedForms`, `DestroyAutoInjectForms` |
| Logging | `LogReload` |

### Manifold-TemplateLoader-Manager

Singleton. Discovery and validation.

| Function | Returns | Description |
|---|---|---|
| `manager:DiscoverTemplates()` | `table` | Scans the template folder (non-recursively), skips `Header.CEA`, sorts by `MenuOrder` + caption |
| `manager:LoadSettings(path, name)` | `table\|nil, string` | Loads inside the sandbox and validates |
| `manager:ValidateSettings(name, settings, path)` | `table\|nil, string` | Type checks with a concrete error message |
| `manager:GetSettingsEnvironment()` | `table` | The sandbox |
| `manager:LoadScript(path)` | `string\|nil, string` | |
| `manager:InitTemplate(name)` | `string, table` \| `nil, string` | Script + settings in one call |
| `manager:NormalizePath(path)` | `string\|nil` | `\` → `/`, `//` → `/`, trailing slash removed |
| `manager:GetScriptExtension()` / `GetLuaExtension()` / `GetTemplateFolder()` | `string` | `.CEA` / `.Settings.lua` / folder |

### Manifold-TemplateLoader-Memory

Singleton. Collects context from the target process. It **never raises** — every failure path
returns `nil, message` so that a template is not generated half-way.

| Area | Functions |
|---|---|
| Configuration | `SetInjInfoLineCount`, `SetInjInfoRemoveSpaces`, `SetInjInfoAddTabs`, `SetAppendToHookName`, `SetAskForHookName`, `SetAskForInjectionAddress`, `SetAllocationNear`, `SetAllocationSize`, `SetDefaultHookName`, `NormalizeAllocationSize`, `GetConfig`, `GetOptions` |
| Runtime | `IsTarget64Bit`, `GetDefaultPointerSize`, `Is14ByteJump`, `GetMinJumpSize`, `GetJumpType`, `GetProcessName`, `GetProcessBase`, `GetProcessBaseStr`, `FormatAddress` |
| Selection | `GetSelectionAddress`, `GetSelection`, `GetSelectionSize`, `GetModuleName`, `GetModuleBase`, `GetModuleBaseStr` |
| Instructions | `GetInstructionSize`, `IsValidInstructionSize`, `GetInstructionSpan`, `GetJumpSize`, `GetDisassembledOpcode`, `GetOpcodes`, `GetBytes`, `GetNopPadding`, `GetRegisterData` |
| Template | `NormalizeSymbolName`, `PromptForHookName`, `FormatHookName`, `GetHookNames`, `GetInjectionAddress`, `GetAllocStatement`, `GetGlobalAllocStatement`, `GetAoB`, `GetInjectionInfo`, `GetInjectionInfoStr` |
| Time | `GetCurrentDate`, `GetCurrentTime`, `GetCurrentDateTime` |
| Mono | `GetMonoSupportStatus` — placeholder |
| Context | `GetMemoryInfo(overrides)` |

`GetInstructionSpan` walks at most 64 instructions and only accepts sizes of 1–15 bytes — both
guards against unreadable memory.

### Manifold-TemplateLoader-UI

Singleton. Menu construction.

| Function | Description |
|---|---|
| `ui:GetMainMenuTree(config, indices, callbacks)` | Declarative menu tree |
| `ui:BuildTree(parent, tree)` | Turns the tree into real menu items |
| `ui:RemoveManagedItems(parent)` | Removes everything with the `Manifold` name prefix |
| `ui:FindMenuItem(form, name)` | Recursive lookup (e.g. `"emplate1"`) |
| `ui:AddSeparatorAfter(parentMenu, itemName)` | |
| `ui:CategorizeMenuItems(loader, rootMenu, indices)` | Moves the flat template entries into the category hierarchy |

Menu entries are tables:

```lua
{ caption = "…", name = "ManifoldXyz", image = idx, sub = { … },
  onClick = fn, autoCheck = true, checked = bool, radio = true, separator = true }
```

The `Manifold` name prefix is the ownership marker: `RemoveManagedItems` only deletes entries
carrying it and leaves Cheat Engine's own menu items alone.

### Manifold-TemplateLoader-File

Singleton. Defensive file-system wrapper — every `lfs` call is wrapped in `pcall`.

| Function | Returns |
|---|---|
| `file:Exists(path)` | `boolean` |
| `file:FolderExists(path)` | `boolean` |
| `file:EnsureFolder(path)` | `boolean, string?` — **recursive** |
| `file:Size(path)` | `number` |
| `file:ReadFile(path)` | `string\|nil, string?` — binary mode |
| `file:WriteFile(path, content)` | `boolean, string?` |
| `file:ScanFolder(path [, recursive])` | `table` — sorted, case-insensitive |

### Manifold-TemplateLoader-Log

Singleton, self-contained (independent of `Manifold.Logger`).

| Function | Description |
|---|---|
| `log:SetLogLevel(level)` | `0` (NONE) to `5` (CRITICAL) |
| `log:GetLogLevel()` / `GetLogLevelName()` | |
| `log:Log(level, msg)` / `ForceLog(level, msg)` | |
| `log:<Level>(msg)` / `<Level>F(fmt, …)` / `Force<Level>(…)` | Generated for Debug/Info/Warning/Error/Critical |
| `log:Stringify(tbl)` | |
| `log:ClearLogFile()` | |

Log file: `autorun\Manifold-TemplateLoader-Modules\Manifold-TemplateLoader-Log.txt`
(only when `LogToFile` is enabled). Writing there requires the autorun directory to be writable —
under a default `C:\Program Files` installation that means Cheat Engine has to run elevated, which
CE 7.5 does by default.

### Manifold-TemplateLoader-Json

A private copy of Jeffrey Friedl's `json.lua`, identical to `Manifold.Json` in the framework. Used
only for the configuration file.

---

## 10. Creating your own template

**1. Script file** `Manifold-TemplateLoader-Templates/Health Hook.CEA`:

```
<< Header >>

[ENABLE]

ManifoldScanModule(<< HookNameParsed >>,<< Module >>,<< AoBStr >>)
<< Alloc >>
ManifoldAssert(<< HookNameParsed >>,<< OriginalBytes >>)

label(return_<< HookName >>)

n_<< HookName >>:
  mov [<< BaseAddressRegister >>+<< BaseAddressOffset >>],(int)9999
<< OriginalOpcodes >>
  jmp return_<< HookName >>

<< HookNameParsed >><< AoBOffset >>:
  << JumpType >> n_<< HookName >>
  << NopPadding >>
return_<< HookName >>:
registersymbol(<< HookNameParsed >>)

[DISABLE]

<< HookNameParsed >><< AoBOffset >>:
  db << OriginalBytes >>

unregisterSymbol(*)
dealloc(*)
```

**2. Settings file** `Health Hook.Settings.lua`:

```lua
return {
    Caption                = "Health Hook",
    InSubMenu              = true,
    SubMenuName            = "[9] Custom Hooks",
    MenuOrder              = 10,
    AskForHookName         = true,
    AskForInjectionAddress = false,
    AppendToHookName       = "Hook",
    AllocationSize         = "$1000",
    AllocationNear         = true,
}
```

**3.** In the Auto Assembler window choose **Template Loader → Reload templates**, then open a
**new** Auto Assembler window.

### Troubleshooting checklist

| Symptom | Cause |
|---|---|
| Template does not appear | Duplicate `Caption`, or the settings file is missing / returns no table |
| Template is in the menu but a reload does not show it | Menu belongs to the **old** generation — open a new AA window |
| "No unique AoB was found" | `getUniqueAOB` cannot find a unique signature at that site |
| "Injection address is not inside a loaded module" | The selection is in dynamically allocated memory |
| "Unable to determine instruction size" | The address is not (or no longer) readable |
| Shortcut does not work | Conflict with another template — see the log |
| `ManifoldScanModule is not a valid command` | Manifold Framework not loaded — switch to `aobScanModule` |

---

## 11. Known limits

- **No Mono/managed support.** `Memory:GetMonoSupportStatus()` returns a TODO string; the entry
  point for an implementation is marked as a comment in the memory module. Templates receive
  native x86/x64 context only.
- **Templates are not discovered recursively.** `ScanFolder(folder, false)` — subfolders inside the
  template directory are ignored.
- **No template cache.** Every invocation re-reads `.CEA` and `Header.CEA` from disk and recompiles
  them. At the usual rate (one invocation per menu click) that is harmless.
- Details and further findings: [TODO — Template Loader](TODO.md#template-loader).
