# Manifold Template Loader 3.0

The loader registers the `.CEA` templates in `Manifold-TemplateLoader-Templates` with Cheat
Engine and turns them into finished Auto Assembler scripts. Picking a template runs a staged
pipeline:

```
validate template -> collect inputs -> build an isolated context
-> resolve requirements -> render into a buffer -> validate output -> write to the editor
```

The editor is only touched in the last step. If anything fails before that, including a
cancelled prompt, the editor stays exactly as it was. The full documentation is in
[`docs/Manifold-Template-Loader.md`](../docs/Manifold-Template-Loader.md).

## Upgrading from 2.x

Replace the files and restart Cheat Engine once. The configuration is migrated automatically
from schema 3 to schema 4. Existing templates and `.Settings.lua` files keep working unchanged.
The module files `-Loader.lua`, `-Manager.lua` and `-Memory.lua` are gone, but the public
globals `ManifoldTemplateLoaderHost`, `ManifoldTemplateLoader` and `loader` still point at the
runtime.

## Reload levels

**Reload templates** rediscovers templates and settings, validates them before anything is
swapped, and updates the registrations. Open Auto Assembler windows are left alone. New windows
get the updated menus. If validation fails the active set stays fully active.

**Reload providers and extensions** rebuilds the provider modules and the context registry,
replays registered extensions and then reloads the templates.

**Full runtime reload** builds a complete candidate from every module except the persistent
host. Open Auto Assembler windows have to close for the registration swap, so the loader asks
first, because their editors may hold unsaved work. On failure the running generation stays
active and the module cache is rolled back.

The persistent host owns the only form notification. That is what makes the whole runtime
replaceable without restarting Cheat Engine.

## Template settings

`Name.Settings.lua` runs in a data sandbox with no `io`, no `os`, no `_G` and no Cheat Engine
API. Legacy files keep working as they are. New templates use schema 2:

```lua
return {
    SchemaVersion = 2,
    Id = "my.template",
    Caption = "My Hook",
    Category = "Hooks > Pointer",
    CategoryOrder = 1,
    Order = 10,
    Requires = { "AddressValue", "Module", "HookName", "AoBStr", "OriginalBytes" },
    Optional = { "BaseAddressOffset" },
    Inputs = {
        { Name = "UseReadMem", Type = "boolean", Caption = "Use readMem", Default = true }
    },
    Memory = { AskForHookName = true, AllocationNear = true, AllocationSize = "$1000" }
}
```

`Example - Full Capability.Settings.lua` documents every field. The matching
`Example - Full Capability.CEA` is a working reference for the whole template API, covering
expressions, `<% %>` blocks, inputs, partials through `include("...")`, helpers and requirements.

## The Manifold Framework is optional

The bundled templates no longer hard-code the framework's Auto Assembler commands. Instead of
writing `ManifoldScanModule(...)` and `ManifoldAssert(...)` directly they write:

```
<< ScanModule >>
<< Alloc >>

<< AssertBytes >>
```

Those resolve per generation. With the framework loaded they become the Manifold commands.
Without it they become Cheat Engine's own `aobScanModule(...)` and `assert(...)`. `aobScanModule`
defines the same symbol, and `assert(address,aob)` is a built-in Auto Assembler command that
checks the bytes at the symbol. The guard is not lost either way. There is one difference worth
knowing: `ManifoldAssert` only logs a warning on a mismatch, while Cheat Engine's `assert`
refuses to enable the script.

Both address `<< HookNameParsed >><< AoBOffset >>` rather than the bare scan symbol. The symbol
names the start of the signature. `getUniqueAOB` only returns offset 0 when the bytes at the
injection site are already unique in the module, otherwise it extends the pattern backwards.
Without the offset the guard would check the wrong bytes.

Nop and byte patch templates branch explicitly, because their arguments differ:

```
<% if HasManifoldCommands then %>
ManifoldNop(<< HookNameParsed >><< AoBOffset >>,<< JumpSize >>)
<% else %>
<< HookNameParsed >><< AoBOffset >>:
  db << NopBytes >>
<% end %>
```

`ManifoldInstallDetour`, `ManifoldEmitOriginal`, `ManifoldDestroyDetour` and
`ManifoldResolveStatic` have no Cheat Engine equivalent. Those templates keep the commands,
declare a capability and render `<< TrampolineWarning >>` or `<< FrameworkWarning >>`, a comment
block naming what is missing. The script then fails visibly when it is assembled instead of
quietly assembling into a hook that was never installed.

Availability is detected through the globals `assemblerCommands` and `trampolines`, which
`Manifold.Bootstrap` publishes when it constructs the modules. Cheat Engine offers no way to ask
whether an Auto Assembler command is registered, so there is nothing more direct to check.

## Context variables

Variables are registered by providers and resolved lazily. Only what a template actually
references gets computed, every result is cached for that one generation, and dependencies
resolve on their own. Adding a variable is a registration:

```lua
ManifoldTemplateLoader:RegisterExtension{
    Name = "MyStuff",
    Variables = {
        GameName = { Type = "string", Resolve = function() return "MyGame" end }
    }
}
```

After that `<< GameName >>` works in every template, with no changes to the loader, the compiler
or the UI. Anything that cannot be determined reliably resolves to `nil` instead of a guess. A
good example is `BaseAddressRegister` on an instruction like `[rax+rcx*4+30]`. Templates that
list it under `Requires` then stop with a readable explanation before anything is generated.

## Diagnostics

The **Template Loader** menu has a log viewer with a level filter and search, *Validate All
Templates* (syntax, includes, unknown variables and requirements, without touching the active
set), *Run Self-Check* and *Copy Diagnostic Report*. The same core checks also run
headless through the test suite under `Manifold-TemplateLoader-Tests`, which is a
development aid and not part of the published tree.

Capturing and printing are separate. The ring buffer holds the last 500 entries and receives
everything down to `CaptureLevel`, which defaults to TRACE. The log level only decides what goes
to the console and the file. So the viewer can show a full DEBUG trace while the console stays
at ERROR. Lower the filter in the viewer instead of raising the log level and reproducing the
problem. Entries that were never printed are marked and the status line counts them.

## Windows

The loader's own windows (preview, log viewer, diagnostics, input dialogs) use the Manifold
*Bearded-Arc* style with bordered cards, panel buttons with hover and a status line. If the
Cheat Table has a live `Manifold.Forms` instance with an applied theme, the loader reads its
palette. The module itself is deliberately not loaded, to avoid colliding with the Cheat Table's
own lifecycle. Every window is `bsSizeable` and laid out purely by alignment, with the button
bar and status line at the bottom and the content filling the rest.

The preview uses `createSynEdit` with Auto Assembler highlighting. Background and text color are
taken from Cheat Engine's own Auto Assembler editor, because `TSynAASyn` reads its token colors
from the registry or from its dark mode branch and exposes no attributes to Lua. That keeps the
code readable in both modes. `RightEdge = -1` removes the bright block beyond column 80. The
gutter is styled explicitly through `Gutter.Color`, by hiding `SynGutterMarks1`,
`SynGutterChanges1` and `SynGutterSeparator1`, and above all through
`SynGutterLineNumber1.MarkupInfo.Background`, which otherwise paints its own light background
over the gutter color. Memos all go through one helper that turns `ParentColor` off and sets
`Color` explicitly, because a read-only edit on Win32 is painted through `WM_CTLCOLORSTATIC` and
would ignore the color.

Mono and managed runtime support is still not implemented. The provider system is prepared for
it, so a `MonoProvider` can register its variables without any core changes.
