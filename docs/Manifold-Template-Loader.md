# Manifold Template Loader

Directory: [`Manifold-TemplateLoader/`](../Manifold-TemplateLoader/)
Version 3.0.0, MIT, by Leunsel and LeFiXER. The version number lives in
`Manifold-TemplateLoader-Version.lua` and nowhere else.

An autorun system that turns `.CEA` templates into finished Auto Assembler scripts. Picking a
template runs a staged pipeline. It validates the template, collects inputs, resolves context
lazily, renders into a buffer, validates the output and only then writes to the Auto Assembler
editor. A failure at any earlier stage leaves the editor untouched.

3.0 is a full recode of the 2.x loader. The template syntax, the bundled templates, the
`.Settings.lua` files, the configuration file and the public globals stay compatible. The
internals became a provider-based context system with lazy resolution, a template engine with
line-mapped errors, declarative inputs, partials, an extension API, structured errors, a log
viewer and diagnostics. The compatibility section near the end lists exactly what changed.

## Installation

Everything belongs in the `autorun` folder.

```
autorun/
├── Manifold-TemplateLoader-Main.lua          entry point
├── Manifold-TemplateLoader-Modules/
│   ├── Manifold-TemplateLoader-Host.lua      persistent, not reloadable
│   ├── Manifold-TemplateLoader-Runtime.lua   service container
│   ├── Manifold-TemplateLoader-Version.lua   the version number
│   ├── Manifold-TemplateLoader-Engine.lua    template engine
│   ├── Manifold-TemplateLoader-Context.lua   context registry and resolution
│   ├── Manifold-TemplateLoader-Provider-*.lua  six built-in providers
│   ├── Manifold-TemplateLoader-Registry.lua  discovery and settings schemas
│   ├── Manifold-TemplateLoader-Generator.lua the generation pipeline
│   ├── Manifold-TemplateLoader-Inputs.lua    declarative input dialogs
│   ├── Manifold-TemplateLoader-Extensions.lua extension registry and hooks
│   ├── Manifold-TemplateLoader-Config.lua    config, schema 4, migrations
│   ├── Manifold-TemplateLoader-Errors.lua    structured error model
│   ├── Manifold-TemplateLoader-Log.lua       TRACE to FATAL, ring buffer
│   ├── Manifold-TemplateLoader-Diagnostics.lua
│   ├── Manifold-TemplateLoader-UI.lua        menus, log viewer, preview
│   ├── Manifold-TemplateLoader-Theme.lua     window styling
│   ├── Manifold-TemplateLoader-CE.lua        defensive Cheat Engine wrappers
│   ├── Manifold-TemplateLoader-File.lua      file system layer
│   ├── Manifold-TemplateLoader-Icons.lua and Manifold-Icons/
│   └── Manifold-TemplateLoader-Json.lua
└── Manifold-TemplateLoader-Templates/        *.CEA and *.Settings.lua
    └── Partials/                             fragments for include()
```

Upgrading from 2.x means replacing the files and restarting Cheat Engine once. The 2.x hot
reload cannot load the 3.0 module set, and its rollback keeps the old version running until the
restart. The configuration is migrated automatically and private templates keep working.

The bundled templates no longer require the Manifold Framework. See the section on the framework
below for how that works.

## Architecture

```
Persistent Host   owns the single registerFormAddNotification, never reloaded
    └── Runtime   one loader generation, replaced wholesale by a full reload
         ├── Config           schema-versioned JSON, migrations, atomic writes
         ├── Log              TRACE to FATAL, ring buffer, file, viewer feed
         ├── File and CE      defensive file system and Cheat Engine layers
         ├── Engine           parser, compiled chunk cache, renderer
         ├── ContextRegistry  providers, variables, dependency graph
         │     └── Providers  Runtime, Process, Instruction, Hook, Framework, Mono
         ├── TemplateRegistry discovery, settings schemas 1 and 2, validation
         ├── Extensions       providers, variables, helpers and hooks from outside
         ├── Generator        the staged pipeline
         ├── Inputs           declarative input dialogs
         ├── Diagnostics      report and self-check
         └── UI               menus, categorization, log viewer, preview
```

`registerFormAddNotification` cannot be unregistered in Cheat Engine. The host registers it once
and forwards to whichever Runtime is active, which is what makes the whole Runtime replaceable
without restarting Cheat Engine. The host also skips the initial form scan on purpose, because
Cheat Engine's own hidden script window is a `TfrmAutoInject` as well and would otherwise be
mistaken for an Auto Assembler window.

### The generation pipeline

```
resolve template          registry lookup by the registered callback
validate template         compile (cached) before any prompt or process access
collect inputs            dialog only if the template declares Inputs
build isolated context    fresh per generation, nothing leaks between runs
resolve requirements      the Requires list, or the legacy prelude
render                    into a buffer, with includes, helpers and lazy context
validate output           loader checks plus the optional autoAssembleCheck
preview                   optional window before anything is applied
commit                    the editor is touched here and only here
```

A cancelled prompt aborts silently. A real failure produces one structured error dialog:

```
Template generation failed

Template:  Pointer Hook
Source:    .../Pointer Hook.CEA
Variable:  BaseAddressRegister
Provider:  Instruction
Reason:    Required context variable 'BaseAddressRegister' could not be resolved.

This template requires a simple memory operand such as:
[rax] / [rax+30] / [rbx-10]
The selected instruction uses:
movss [rax+rcx*4+30],xmm0
Select a compatible instruction or use a template that does not require BaseAddressRegister.
```

## Template syntax

Unchanged from 2.x. `<< expression >>` evaluates a Lua expression and inserts the result, where
`nil` becomes an empty string. `<% lua code %>` executes statements and inserts nothing.

All nodes of one template compile into a single chunk, so a `local` or a loop variable declared
in one `<% %>` block is visible to later blocks and expressions.

```
<% for slot = 1, PointerCount do %>
  << PointerType >> 0 // slot << slot >>
<% end %>
```

New in 3.0:

Errors carry template line numbers. Both syntax errors such as `Unclosed << block` and runtime
errors inside expressions are mapped back to the `.CEA` line.

Partials. `<< include("Name") >>` renders another `.CEA` with the same context. The lookup order
is `Templates/Partials/Name.CEA` and then `Templates/Name.CEA`. Cycles and missing files are
reported with the searched paths. `<< Header >>` still works and is now lazy, so templates that
do not use it do not pay for it.

Helpers. `hex(v)`, `join(sep, ...)`, `default(v, fallback)`, `isEmpty(v)` and `trim(s)`.
Extensions can add more.

Unknown variables warn. A typo like `<< HookNamePased >>` still renders as an empty string, but
it now logs a warning naming the identifier, and *Validate All Templates* flags it statically.

## Settings files

`<Name>.Settings.lua` returns a table and runs in a data sandbox with `ipairs`, `pairs`,
`tonumber`, `tostring` and copies of `math`, `string` and `table`. There is no `io`, no `os`, no
`_G` and no Cheat Engine API. Settings are metadata, not plug-ins. Executable extensions have
their own API.

### Schema 1

Every existing file. All 2.x fields keep working unchanged: `Caption`, `Shortcut`, `InSubMenu`,
`SubMenuName` with its `[n]` sort prefix, `MenuOrder`, `AskForInjectionAddress`,
`AskForHookName`, `AppendToHookName`, `AllocationSize`, `AllocationNear` and `DefaultHookName`.
Legacy templates get a derived stable id of the form `legacy.<file-name>` and keep the
unrestricted 2.x template environment, so globals stay reachable.

### Schema 2

Set `SchemaVersion = 2`. Everything above still applies, with `Category` preferred over
`SubMenuName` and `Order` over `MenuOrder`, plus:

| Field | Meaning |
|---|---|
| `Id` | Stable identity such as `"manifold.pointer.extended"`. Favorites, recent templates, diagnostics and validation key on it |
| `Description`, `Author`, `Version`, `Tags` | Metadata for diagnostics, validation and future browsing |
| `Category`, `CategoryOrder` | `>` nests categories. `CategoryOrder` replaces the `[n]` caption prefix |
| `Requires` | Context contract. Generation aborts with an explanation before rendering |
| `Optional` | Resolved if possible. The template must cope with nil |
| `Inputs` | Declarative typed inputs |
| `Architectures` | `{ "x86" }`, `{ "x64" }` or both. A mismatch is rejected with a clear message |
| `Capabilities` | Declared framework requirements such as `"Manifold.AssemblerCommands"` |
| `AllowUnsafeGlobals` | Schema-2 templates render restricted unless this is true |
| `Memory` | Nested memory overrides. The flat legacy fields are still accepted |

`Example - Full Capability.Settings.lua` documents every field inline and is the reference.

### Inputs

```lua
Inputs = {
    { Name = "CompareRegister", Type = "string",  Caption = "Compare Register", Default = "rax" },
    { Name = "UseReadMem",      Type = "boolean", Caption = "Use readMem",      Default = true },
    { Name = "PointerCount",    Type = "integer", Caption = "Pointer Count",    Default = 2, Min = 1, Max = 16 },
    { Name = "RegisterMode",    Type = "enum",    Caption = "Register Mode",
      Values = { "Player", "Entity", "Both" },    Default = "Both" },
}
```

The types are `string`, `boolean`, `integer`, `number` and `enum`. The dialog only appears when a
template declares inputs. Values become plain template variables such as `<< CompareRegister >>`
or `<% if UseReadMem then %>`. Cancelling aborts the generation before anything renders.

## The context system

Templates read variables by plain name. Internally every variable belongs to a provider and is
resolved lazily. Nothing is computed until something asks for it, declared dependencies resolve
first, and every result is memoized for that one generation. Three uses of `<< OriginalBytes >>`
read the target process once. Cycles are detected at registration and again at resolution.
Values that cannot be determined reliably resolve to `nil`, because the loader never guesses.
An unknown value beats a wrong one in generated assembly.

### Variable reference

The registry is the single source of truth. *Diagnostics > Runtime Status* lists the live set,
including extension providers. The built-ins are:

**Runtime provider.** `Version`, `Date`, `Time`, `DateTime`, `Header` (a lazy render of
`Header.CEA`) and `MonoSupportStatus`, kept for 2.x compatibility.

**Process provider.** `Process`, `ProcessBase`, `IsTarget64Bit`, `PointerType` (`dq` or `dd`),
`PointerSize` (8 or 4), `DefaultPointerBytes`, `Module` and `ModuleBase`.

**Instruction provider.** `Address`, `AddressValue`, `Is14ByteJump` (read from the generating
window's toggle), `MinJumpSize`, `JumpType`, `JumpSize` (whole instructions covering at least the
minimum, so no instruction is ever partially overwritten), `SelectionSize`, `OriginalInstruction`,
`OriginalOpcodes`, `OriginalBytes`, `NopPadding`, `NopBytes`, `BaseAddressRegister` and
`BaseAddressOffset`. The last two are `nil` for anything more complex than `[reg]` or
`[reg±off]`, including scaled indexes and `rip`.

**Hook provider.** `HookName`, `HookNameParsed`, `Alloc`, `GlobalAlloc`, `AoBStr`, `AoBOffset`,
`InjectionInfo`, `InjInfoLineCount`, `InjInfoRemoveSpaces`, `InjInfoAddTabs`, `AppendToHookName`,
`AskForHookName`, `AskForInjectionAddress`, `AllocationSize` and `AllocationNear`.

**Framework provider.** `HasManifoldCommands` and `HasManifoldTrampolines` say what the Cheat
Table has loaded right now. `ScanModule` and `AssertBytes` are ready-made statements that use the
Manifold commands when available and Cheat Engine's `aobScanModule` and `assert` otherwise.
`FrameworkWarning` and `TrampolineWarning` produce a comment block for scripts that cannot fall
back, and an empty string when everything is present.

Detection uses the same signal the framework uses on itself. `Manifold.Bootstrap` publishes each
module under its declared global, so `assemblerCommands` and `trampolines` being present means
the modules were constructed. Cheat Engine offers no way to ask whether an Auto Assembler command
name is registered. The same predicate backs the built-in capabilities
`Manifold.AssemblerCommands` and `Manifold.Trampolines`.

**Mono provider.** Facts about the managed method the injection address falls into.
`MonoAvailable` and `MonoIsIl2Cpp` describe the target, `MonoIsJitted` says whether the address
is inside JIT compiled managed code at all, and `MonoNamespace`, `MonoClass`, `MonoClassFullName`,
`MonoMethod` and `MonoImage` name it. `MonoDescriptor` is the `Namespace:Class:Method` form Cheat
Engine's `FINDMONOMETHOD` command parses, `MonoMethodEntry`, `MonoMethodSize` and
`MonoMethodOffset` describe the compiled body, and `MonoHookName` is a sanitized `Class_Method`
suitable as a hook name. `MonoResolve` emits the `USEMONO` and `FINDMONOMETHOD` pair that defines
the hook symbol at assemble time.

One thing to know before writing another provider against Cheat Engine's Mono API. Those getters
return raw qwords, so a lookup that found nothing answers with `0` and never with `nil`, and a
class that is not nested answers `0` as well. Zero is true in Lua, so a handle has to be compared
against zero and never merely tested. Names work the same way, an invalid class gives back an
empty string rather than nothing. Cheat Engine normalizes this itself in `dotnetinfo.lua` before
it trusts a nesting type, and the provider now does too. Getting it wrong is quiet, because the
values still have the right type and flow straight through into a descriptor that looks fine.

A managed hook is anchored by the method name, not by a byte signature. JIT compiled code is
produced fresh on every run, so a signature over it is worthless after a restart and the JIT
address must never be written into a script. `MonoMethodEntry` exists for inspection, not for the
generated text. Nested types resolve to no descriptor at all, because `FINDMONOMETHOD` splits on
the first two colons and a nested full name would mis-split.

**Set by the generator.** `TemplateSettings` carries the normalized settings, the legacy
spellings `SubMenuName` and `MenuOrder`, the flattened memory overrides and any custom fields the
settings file declares. A field like `MyOffset = 0x30` stays reachable as
`TemplateSettings.MyOffset`, exactly as in 2.x. `FinalCompilation` is always false, and every
declared input value is set as well.

### Adding a variable

```lua
ManifoldTemplateLoader:RegisterExtension{
    Name = "MyVariables",
    Variables = {
        InstructionCount = {
            Type = "number",
            DependsOn = { "AddressValue", "JumpSize" },
            Resolve = function(ctx)
                local current, count, total = ctx:Get("AddressValue"), 0, 0
                while total < ctx:Get("JumpSize") do
                    local size = getInstructionSize(current)
                    total, current, count = total + size, current + size, count + 1
                end
                return count
            end
        }
    }
}
```

`<< InstructionCount >>` works immediately, with no loader, compiler or UI change. That is the
core promise of the provider system.

## Menus

Every Auto Assembler window gets two things, 50 ms after it opens.

Under `Template` there are favorites and recent templates, which are plain references and never
duplicate registrations, followed by the categorized template entries. Categories nest with `>`.
`CategoryOrder` in schema 2 or the `[n]` caption prefix in legacy settings controls their order,
and `Order` sorts within a category.

In the menu bar there is the `Template Loader` menu:

```
Template Loader
├── Templates      Reload Templates, Validate All Templates, Open Template Folder,
│                  Template Status, Add Favorite, Remove Favorite
├── Settings       Generation (info lines, spaces, indent, suffix, validate output,
│                  preview before apply), Memory (prompts, near alloc, size,
│                  default hook name), Reset Settings
├── Logging        Log Level, Write Log File, View Logs, Open Log File, Open Log Folder
├── Development    Reload Templates, Reload Providers And Extensions, Full Runtime Reload
├── Diagnostics    Runtime Status, Run Self-Check, Copy Diagnostic Report
└── About
```

All loader-created menu items carry an ownership tag. Rebuilds remove exactly those and never
touch Cheat Engine's own or other extensions' entries.

### Menu icons

`Manifold-Icons/` holds a 25-icon set for the Template Loader menu next to the original six
log-level icons. It follows the style measured from the originals, which is 16 by 16 RGBA with
one RGB value per icon and all shading in the alpha channel. Colors come from the Bearded-Arc
theme and are grouped so a menu section reads as one, with blue for templates, gold for settings,
muted blue for logging, pink for development, green for diagnostics and cyan for about.

The icon list is attached to the root `Template Loader` item only. `TMenuItem.GetImageList` walks
up from an item's parent to the nearest ancestor carrying `SubMenuImages`, so one attach covers
the whole subtree. Attaching it at the main menu would re-index every other top-level menu of the
Auto Assembler window. Inside that subtree entries use `icon = "Name"`. `image` must not be used
there, because the two index different lists.

### Windows

Every window the loader opens is built in the Manifold visual language with bordered cards, a
header strip, panel buttons with hover feedback and a status line. The default palette is the
Bearded-Arc theme. When the Cheat Table has a live `Manifold.Forms` instance with an applied
theme, the loader adopts that palette read-only. It never loads `Manifold.Forms` itself, because
that module defines a global class and belongs to the Cheat Table's lifecycle, and a second copy
from autorun is exactly the collision `Manifold.Bootstrap` exists to detect.

All windows are `bsSizeable` and laid out by alignment. The button bar and status line are
`alBottom` and the content card is `alClient`, so resizing works. Captions use title case.

The preview renders in a `createSynEdit` with Auto Assembler highlighting and falls back to a
themed memo when that API is unavailable. Three details govern how it is styled, all verified
against the Cheat Engine and Lazarus sources.

The background is copied from Cheat Engine's own editor. `TSynEdit.Color` defaults to white, and
`TSynAASyn` takes its token colors from the user's registry syntax settings with a dark or light
default set chosen by `ShouldAppsUseDarkMode`. None of that is reachable from Lua. Taking the
background from an open Auto Assembler window's `Assemblescreen`, falling back to the Lua Engine
editor and then to the palette, keeps the tokens readable in both modes. `RightEdge` is set to
`-1` as Cheat Engine does for its own editors, because highlighter attributes only paint up to
the right edge column and leaving it at the default 80 shows a bright block beyond it.

Memos get the same treatment. `TMemo` inherits the window color and a read-only edit control is
painted through `WM_CTLCOLORSTATIC` on Win32, so every memo goes through one helper that turns
`ParentColor` off and sets `Color` explicitly. A memo standing in for a code view takes the editor
colors rather than the palette.

The gutter must be themed explicitly, which is what otherwise leaves a white strip beside a dark
editor. Cheat Engine's SynEdit binding covers `Lines`, `SelStart` and similar only, so the gutter
is reached through Cheat Engine's generic `__index` chain, which tries a published property first
and then `FindComponent` on a `TComponent`. `TSynGutter` publishes `Color`, `Visible`, `Width`
and `Parts`, and the parts list is a component whose children carry the fixed names
`SynGutterMarks1`, `SynGutterLineNumber1`, `SynGutterChanges1`, `SynGutterSeparator1` and
`SynGutterCodeFolding1`. The loader hides the bookmark strip, the change bar and the separator,
sets `Gutter.Color`, and also sets `SynGutterLineNumber1.MarkupInfo.Background` and
`.Foreground`, because the line-number part paints its own background over the gutter color.
`BorderStyle` is set to `bsNone` to drop the sunken 3D frame.

## Configuration

The file is `%LOCALAPPDATA%\Manifold\TemplateLoader\Manifold-TemplateLoader-Config.json` at
schema 4. A 2.x file at schema 3, or an older unversioned one, is migrated in memory and on disk
on first load. The legacy location under `autorun\...\Modules\` is still read once and moved.

Saves are atomic. The loader writes, verifies and then replaces, so a failed save cannot destroy
the only working copy. A file from a newer schema loads read-only and is never overwritten. A
file that fails to parse is preserved as `...Config.json.invalid` and the loader continues with
defaults, still writable. Broken values such as an invalid allocation size or an empty default
hook name are repaired to defaults on load. Log files live under
`%LOCALAPPDATA%\Manifold\TemplateLoader\Logs\`.

Schema 4 adds two sections. `Generation` holds `ValidateOutput`, which is off by default because
`autoAssembleCheck` runs custom Auto Assembler commands during its check, plus
`PreviewBeforeApply` and `WarnDeprecated`. `UI` holds `Favorites`, `Recent` and `RecentLimit`,
which store template ids.

## Extensions

```lua
ManifoldTemplateLoader:RegisterExtension{
    Name = "Mono", Version = "1.0.0",
    Providers = {
        { Name = "Mono", Variables = { MonoClass = { Resolve = function(ctx) ... end } } }
    },
    Variables = { ... },
    Helpers = { comment = function(v) return "// " .. tostring(v) end },
    Capabilities = { ["My.Capability"] = function() return _G.MyFramework ~= nil end },
    Hooks = {
        BeforeTemplateValidation = ..., AfterTemplateValidation = ...,
        BeforeContextResolution = ...,  AfterContextResolution = ...,
        BeforeRender = ...,             AfterRender = ...,
        BeforeApply = ...,              AfterApply = ...
    }
}
```

Hooks run isolated. A broken hook is logged and skipped, never allowed to corrupt the loader.
Only `Before*` hooks may veto by returning `false` and a reason, and a veto aborts the generation
with the editor untouched. Extensions survive *Reload Providers* and full reloads automatically,
because their definitions are replayed. Name collisions with existing variables are rejected at
registration with both owners named.

### A complete custom provider

Drop this into a Cheat Table Lua script or your own autorun file after the loader has run. No
core module is touched.

```lua
local loaderRuntime = _G.ManifoldTemplateLoader
if loaderRuntime and loaderRuntime.RegisterExtension then
    local ok, err = loaderRuntime:RegisterExtension{
        Name = "MyCustomProvider",
        Version = "1.0.0",
        Providers = {
            {
                Name = "Game",
                Variables = {
                    GameName = {
                        Type = "string",
                        Description = "Marketing name of the target game",
                        Resolve = function() return "My Game" end
                    },
                    GameVersion = {
                        Type = "string",
                        Description = "File version of the main module",
                        DependsOn = { "Process" },
                        Resolve = function(ctx)
                            local info = getFileVersion and select(2, getFileVersion(ctx:Get("Process")))
                            return type(info) == "table"
                                and string.format("%d.%d.%d.%d", info.major or 0, info.minor or 0,
                                    info.release or 0, info.build or 0)
                                or nil   -- unknown beats guessed
                        end
                    },
                    BuildTimestamp = {
                        Type = "string",
                        Description = "When this generation ran",
                        Resolve = function() return os.date("%Y-%m-%d %H:%M:%S") end
                    }
                }
            }
        }
    }
    if not ok then print("MyCustomProvider failed: " .. tostring(err)) end
end
```

`<< GameName >>`, `<< GameVersion >>` and `<< BuildTimestamp >>` now work in every template,
appear in *Diagnostics > Runtime Status*, are checked by *Validate All Templates* and can be
listed in a template's `Requires`.

## Reload levels and rollback

| Level | Menu entry | What reloads | What survives |
|---|---|---|---|
| 1 | Reload Templates | Discovery, compile validation, registrations, menus for new windows | Modules, providers, extensions, config, open windows |
| 2 | Reload Providers And Extensions | Provider modules, context registry, extension replay, then level 1 | Core modules, config, open windows |
| 3 | Full Runtime Reload | Every module except the host, as a complete candidate Runtime | The host, tracked window state, extension definitions |

Every level validates before it commits. Candidates are discovered, compiled and planned first,
and the active set is only unregistered after the candidate proved valid. On any failure the
current generation stays active, and if unregistration already happened the previous set is
re-registered. A failed reload is never a reason to restart Cheat Engine.

Level 3 has to close open Auto Assembler windows, because Cheat Engine holds menu references to
the old callbacks. It asks first:

```
Full reload requires closing 3 Auto Assembler window(s).
Their editor contents may contain unsaved changes.
Reload anyway?          [Yes] [No]
```

Cancelling keeps the current runtime and restores the module cache. Stale callbacks from a
replaced generation are guarded, so a template callback only fires when its runtime is still the
host's active one.

## Logging and diagnostics

The levels are TRACE, DEBUG, INFO, WARNING, ERROR and FATAL. CRITICAL is accepted as a legacy
alias of FATAL. Entries carry context such as generation, template, stage, provider and duration.
DEBUG shows a per-stage profile of each generation:

```
[Generator] 'Pointer Hook' generated in 28.4 ms (generation 7)
  Template validation: 0.4 ms
  Inputs: 0.0 ms
  Context resolution: 21.9 ms
  Render: 1.2 ms
  Output validation: 0.1 ms
```

Capturing and printing are separate. The bounded ring buffer holds the last 500 entries and
receives everything down to `CaptureLevel`, which defaults to TRACE. The log level only decides
what reaches the console and the file. So the viewer can show a full DEBUG trace of what just
happened while the console stays at ERROR. Lower the filter in the viewer instead of raising the
log level and reproducing the problem. Entries that never printed are flagged and the viewer's
status line names how many there are. Dropping them would save almost nothing anyway, because
call sites build their text with `string.format` before calling in, so the formatting cost is
already paid by the time the level is checked.

*View Logs* opens a native viewer with a level filter, search, clear, copy and shortcuts to the
log file and folder. *Copy Diagnostic Report* puts the loader version, Cheat Engine version,
target, generation, template, provider and extension lists, paths, log level, the last reload and
generation status and the full context variable reference on the clipboard. *Run Self-Check*
verifies that the runtime is initialized, the template folder exists, the config is readable, the
registry is valid, providers have no circular dependencies, there are no duplicate ids, callbacks
are attached and the engine compiles and renders a probe.

The same core checks also run headless. `Manifold-TemplateLoader-Tests/Run.lua` is a development
aid that is not part of the published tree. It executes 71 tests covering the engine, context
resolution, config migration, settings schemas, menu categorization and flattening, window
tracking, gutter styling and window layout, discovery and validation over the real bundled
templates, and full generations against a stubbed Cheat Engine target. It runs on any Lua 5.3,
including Cheat Engine's own `lua53-64.dll`.

## Bundled templates

All bundled templates use schema-2 settings with stable ids, `Category` and `CategoryOrder`,
`Requires` contracts and tags. The `Requires` list of each one is derived from what the template
actually references.

### Mono templates

Three templates sit in the `Mono` category and are anchored by the method name rather than by a
byte signature. `Mono Hook` is the plain code cave. `Mono Hook, Instance Capture` stores an
argument register into a named pointer, which at the prologue of an instance method is the object
in `rcx`. `Mono Byte Patch` overwrites the entry so the method returns straight away.

All three emit `USEMONO` and `FINDMONOMETHOD` through `MonoResolve`, and all three restore with
`readMem` rather than writing back recorded bytes. That is the important part. JIT code is rebuilt
on every run, so bytes captured while the script was generated may not be the bytes that are there
the next time it is enabled, and writing them back would corrupt the method.

The `[DISABLE]` block resolves the method a second time. `FINDMONOMETHOD` returns a `define`,
and a define only lives inside the block that created it. A scan symbol can be registered and
read back later, a define cannot, so the disable has to ask for the address again rather than
carry it over.

They declare the `Mono.Runtime` capability, which checks for Cheat Engine's own Mono support, and
they require `MonoDescriptor` and `MonoResolve`. Requiring those two is what makes a generation on
native code stop with a readable message before anything renders. `MonoIsJitted` is deliberately
not in the list, because it is a boolean and a required check treats only `nil` and the empty
string as missing, so `false` would pass.

### The Manifold Framework is optional

Every template that scans and asserts now writes:

```
<< ScanModule >>
<< Alloc >>

<< AssertBytes >>
```

That renders as `ManifoldScanModule(...)` and `ManifoldAssert(...)` with the framework loaded,
and as `aobScanModule(...)` and `assert(...)` without it. `aobScanModule` defines the same
symbol, and `assert(address,aob)` is Cheat Engine's own Auto Assembler command that reads the
bytes at the symbol and aborts when they differ. The guard survives either way, with one
difference. `ManifoldAssert` only warns on a mismatch, while `assert` refuses to enable the
script.

Both address `<< HookNameParsed >><< AoBOffset >>` rather than the bare scan symbol. The symbol
names the start of the signature, and `getUniqueAOB` returns offset 0 only when the injection's
own bytes are already unique in the module, otherwise it grows the pattern backwards and the hook
site sits `AoBOffset` bytes in. Cheat Engine's own template generator compensates the same way.
Without it the guard compared the wrong bytes, which was a permanent false warning with
`ManifoldAssert` and, once the plain `assert` fallback existed, a script that could never be
enabled.

The Nop and byte patch templates branch explicitly, because their argument shapes differ:

```
<% if HasManifoldCommands then %>
ManifoldNop(<< HookNameParsed >><< AoBOffset >>,<< JumpSize >>)
<% else %>
<< HookNameParsed >><< AoBOffset >>:
  db << NopBytes >>
<% end %>
```

`NopBytes` from the Instruction provider covers the whole overwritten span, so the fallback nops
exactly what the command would have.

`ManifoldInstallDetour`, `ManifoldEmitOriginal`, `ManifoldDestroyDetour` and
`ManifoldResolveStatic` have no plain Cheat Engine equivalent. Those templates keep the commands,
declare `Capabilities = { "Manifold.Trampolines" }` or `"Manifold.AssemblerCommands"`, and render
`<< TrampolineWarning >>` or `<< FrameworkWarning >>`, a comment block naming what is missing. The
script then fails loudly when it is assembled instead of quietly assembling into a hook that was
never installed.

### Categories

Categories were renumbered so families stay together and each category has a unique order.
Pointer is 1, Pointer ReadMem 2, Pointer Trampoline 3, Conditional 4, Conditional ReadMem 5,
Conditional Trampoline 6, Byte Patch 7, Default 8, Hooks Trampoline 9, Teleporter 10, Static
Resolver 11, Lua Presets 12 and Examples 13.

`Example — Full Capability` is the reference template. It shows the header, includes,
expressions, code blocks, all four input types, `Requires` and `Optional`, helpers, conditional
readMem and db sections, `TemplateSettings` and the framework predicates, using only the public
template API.

## Compatibility with 2.x

Fully compatible:

The template tags `<< expression >>` and `<% code %>`, shared chunk locals and the `nil` to empty
string rule. All documented context variables with their 2.x value formats. Schema 1
`.Settings.lua` files including the `[n]` prefixes and flat overrides. `<< Header >>` and
`Header.CEA`. The globals `_G.ManifoldTemplateLoaderHost`, `_G.ManifoldTemplateLoader` and
`loader`, plus the runtime methods 2.x exposed such as `LoadTemplates`, `ReloadTemplates`,
`GetTemplateScript` and `GetTemplateDefinitions`. Configuration file contents, migrated from 3 to
4 in place, with the legacy path still read once. The template folder location, non-recursive
discovery and the `Header` exclusion. Legacy templates keep access to Lua globals through the
environment.

Compatible through an alias or a migration:

The config value `Logger.Level = "CRITICAL"` maps to FATAL and is accepted forever. Captions
remain unique keys for Cheat Engine registration, while identity for favorites, recent templates
and diagnostics moved to stable ids, derived as `legacy.<file>` for schema-1 templates. The
deprecation mechanism `registry:RegisterAlias(old, new, true)` exists for future renames, and no
built-in variable is deprecated today.

Changed on purpose and visible to the user:

Cancelling a prompt aborts silently where 2.x showed an error dialog. `BaseAddressRegister` and
`BaseAddressOffset` resolve to `nil` instead of an empty string and `"0"` when no simple base
register exists. The rendered output is empty either way, and templates declaring `Requires` now
fail early with an actionable hint. A full runtime reload asks for confirmation before closing
Auto Assembler windows. The log file moved from `autorun\...\Modules\` to
`%LOCALAPPDATA%\Manifold\TemplateLoader\Logs\`. The `Template Loader` menu was restructured.
`TemplateSettings` exposes normalized fields plus the legacy spellings.

Removed:

The module files `Manifold-TemplateLoader-Loader.lua`, `-Manager.lua` and `-Memory.lua`, which
were superseded by Runtime, Registry and the providers. No legacy duplicates remain. Anything
that required those directly has to switch to the public globals.

## Known limits

IL2CPP is detected and reported, not supported. There is no Mono runtime in an IL2CPP build to
ask for a method, so name based resolution cannot work. Support for it needs a separate provider
that reads a metadata dump.

Templates are not discovered recursively. Subfolders are reserved, and `Partials/` is one of
them.

Architecture filtering rejects at generation time rather than hiding menu entries, because menu
state cannot reliably track process attach and detach events.

There is no file watcher. Reloads are manual by design, since Cheat Engine has no reliable native
file watching and a polling loop is not worth its cost.

Output validation is opt-in, because Cheat Engine's `autoAssembleCheck` executes custom Auto
Assembler commands during the check. With the Manifold Framework loaded that means a real
`ManifoldScanModule` scan.
