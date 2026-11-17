# Manifold Documentation

Documentation for the eleven segments of the
[`Leunsel/CheatEngineLua`](https://github.com/Leunsel/CheatEngineLua) repository.

| Segment | Directory | Runs where | Purpose |
|---|---|---|---|
| Manifold Address List | `Manifold-AddressList/` | Cheat Engine `autorun` | Bulk editor over a Cheat Table's address list, with an undo history |
| Manifold CE Fixes | `Manifold-CE-Fixes/` | Cheat Engine `autorun` | Workarounds for defects in Cheat Engine itself |
| Manifold CE Utility | `Manifold-CE-Utility/` | Cheat Engine `autorun` | Quality of life menu for the Cheat Engine UI itself |
| Manifold Framework | `Manifold-Modules/` | Inside a Cheat Table (`luaFiles` or table files) | Modular runtime library for Cheat Tables |
| Manifold Godot | `Manifold-Godot/` | Cheat Engine `autorun` | Godot 4 objects, classes and scene tree in Structure Dissect, symbols and a menu |
| Manifold Logger | `Manifold-Logger/` | Cheat Engine `autorun` | Canvas-drawn log console any script can side-load |
| Manifold RTTI | `Manifold-RTTI/` | Cheat Engine `autorun` | C++ class names from MSVC run-time type information in Structure Dissect and symbols |
| Manifold SigMaker | `Manifold-SigMaker/` | Cheat Engine `autorun` | Array-of-bytes signature for the selected instruction, and the search back from one |
| Manifold Table Files | `Manifold-TableFiles/` | Cheat Engine `autorun` | Editable window over the files attached to a Cheat Table |
| Manifold Template Loader | `Manifold-TemplateLoader/` | Cheat Engine `autorun` | Template engine for Auto Assembler scripts |
| Manifold UE | `Manifold-UE/` | Cheat Engine `autorun` | Unreal Engine 4/5 reflection in Structure Dissect, symbols and a type inspector |

## Entry points

[Manifold Address List](Manifold-AddressList.md) covers installation, the window, the commit
funnel and the undo history, what is deliberately outside it, the filter language, find and
replace, the problem checks, the four inspector pages and the Cheat Engine behaviours the whole
segment is built around.

[Manifold CE Fixes](Manifold-CE-Fixes.md) covers installation and, per fix, the symptom, the
cause in Cheat Engine's source, what the workaround changes and how to verify it.

[Manifold CE Utility](Manifold-CE-Utility.md) covers installation, the menu reference and
configuration.

[Manifold Framework](Manifold-Framework.md) covers the architecture, bootstrapping, the data
directory and an overview of the modules.

[Manifold Framework API Reference](Manifold-Framework-API.md) is the complete function reference
for every module.

[Manifold Godot](Manifold-Godot.md) covers installation, how a Godot 4 game is resolved, the
Structure Dissect callbacks, the custom types, the offset, node and method symbols, the menu and
the Lua API.

[Manifold Logger](Manifold-Logger.md) covers the record model, channels, the canvas console, the
bridges onto other producers and the log file.

[Manifold RTTI](Manifold-RTTI.md) covers installation, where the type information comes from, the
Structure Dissect callbacks and labels, the vftable symbols, the menu, the Lua API and the name
decoding.

[Manifold SigMaker](Manifold-SigMaker.md) covers installation, the menu entries and the shortcut,
how a signature is built by probing the disassembler, the masking policy, the output parts, and
the search that reads a signature back in and goes to where it matched.

[Manifold Table Files](Manifold-TableFiles.md) covers installation, the window, and the design
framework instance it carries.

[Manifold Template Loader](Manifold-Template-Loader.md) covers the template syntax, context
variables, the menu and hot reload.

[Manifold UE](Manifold-UE.md) covers installation, how an Unreal Engine game is resolved, the
Structure Dissect callbacks, the custom types, the offset symbols, the menu and the Lua API.

[TODO](TODO.md) lists open work items from the code review, ordered by priority.

## Overall architecture

The segments are functionally separate and run at different times. There is no hard coupling
between them. They only share naming conventions and, in part, the data directory.

```
Cheat Engine starts
│
├─ autorun/Manifold-CE-Utility.lua            Segment 1, the "[— Manifold —]" menu
│    ├─ publishes ManifoldCEUtility, adds the entry to MainForm.Menu
│    └─ logs through ManifoldLogger when present, print otherwise
│
├─ autorun/Manifold-CE-Fixes.lua              Segment 6, workarounds for Cheat Engine defects
│    └─ wraps tvStructureView.OnMouseDown in every Structure Dissect window
│
├─ autorun/Manifold-TableFiles.lua            Segment 4, the Table Files window
│    └─ publishes ManifoldTableFiles, registers no menu of its own
│
├─ autorun/Manifold-SigMaker.lua              Segment 7, signatures in both directions
│    ├─ publishes ManifoldSigMaker, adds two entries to the disassembler context menu
│    └─ carries its shortcut in the memory view's own menu bar
│
├─ autorun/Manifold-AddressList.lua           Segment 8, the address list editor
│    ├─ publishes ManifoldAddressList, registers no menu of its own
│    ├─ polls the address list on a timer, CE has no change event
│    └─ one commit funnel, one journal, undo that Cheat Engine does not have
│
├─ autorun/Manifold-Logger.lua                Segment 5, the log console
│    ├─ publishes ManifoldLogger, adds a "Logger" main-menu entry
│    ├─ bridges onto Manifold.Logger and the Template Loader when present
│    └─ hands any script its own channel: ManifoldLogger:Channel("Name")
│
├─ autorun/Manifold-UE.lua                    Segment 9, Unreal Engine reflection
│    ├─ publishes ManifoldUE, adds an "Unreal Engine" main-menu entry
│    ├─ registers a structure name lookup, a dissect override and a symbol lookup
│    └─ registers the custom types UE FName, UE FString and UE Object Index
│
├─ autorun/Manifold-RTTI.lua                  Segment 10, C++ run-time type information
│    ├─ publishes ManifoldRTTI, adds an "RTTI" main-menu entry
│    ├─ registers a structure name lookup, a dissect override and a symbol lookup
│    └─ registers <Class>::vftable symbols, provides getRTTIClassName where missing
│
├─ autorun/Manifold-Godot.lua                 Segment 11, Godot 4 engine data
│    ├─ publishes ManifoldGodot, adds a "Godot Engine" main-menu entry
│    ├─ registers a structure name lookup, a dissect override and a symbol lookup
│    └─ registers the custom types Godot StringName, Godot String and Godot ObjectID
│
├─ autorun/Manifold-TemplateLoader-Main.lua   Segment 3, the Template Loader
│    ├─ Host (persistent, survives a hot reload)
│    └─ Runtime → registerAutoAssemblerTemplate(...)
│         └─ shows up in every Auto Assembler window's menu
│
└─ A Cheat Table is opened
     └─ its table Lua script calls CETrequire("Manifold.<Module>")   Segment 2, the Framework
          ├─ Logger / CustomIO / Json          base services
          ├─ ProcessHandler / Utils            lifecycle
          ├─ Memory / State / AutoAssembler    runtime
          ├─ Forms / UI                        presentation and themes
          ├─ Teleporter / TeleporterMap        feature modules
          └─ AssemblerCommands / Trampolines   Auto Assembler language extension
```

### Where the segments touch

The Template Loader can use the Framework but does not require it. Its bundled templates emit
`<< ScanModule >>` and `<< AssertBytes >>`, which resolve per generation. With the Framework
loaded they become `ManifoldScanModule` and `ManifoldAssert`. Without it they become Cheat
Engine's own `aobScanModule` and `assert`, which define the same symbol and perform the same byte
check. Only the trampoline templates and the static address resolver genuinely need the
Framework, because `ManifoldInstallDetour`, `ManifoldEmitOriginal`, `ManifoldDestroyDetour` and
`ManifoldResolveStatic` have no Cheat Engine equivalent. Those templates declare a capability and
render a comment block naming what is missing.

The CE Utility has no runtime coupling to the Framework. It only references it in source comments
as a reference implementation.

The CE Fixes script touches no other segment. It registers one form notification, wraps one
event handler per Structure Dissect window, and logs through `print` only.

The CE Utility contributes the menu entries that open Table Files, the Logger console and the
Address List window, delegating to the globals `ManifoldTableFiles`, `ManifoldLogger` and
`ManifoldAddressList` and logging where to install them when a global is absent. Its own lines go
through `ManifoldLogger:Channel("CE Utility")` when the Logger is installed and to `print`
otherwise, resolved on every call so a rebuilt Logger is picked up. Neither segment
requires the other. Table Files reads `forms.ActiveDesignTheme` when a Cheat Table has a live
`Manifold.Forms`, so it follows the table's theme, but it never loads that module: it carries its
own copy of the design framework, exactly as the Template Loader does.

The Logger is coupled to everything optionally and to nothing hard. It publishes `ManifoldLogger`
and hands out a channel to anyone who asks, so a script logs into it with
`ManifoldLogger and ManifoldLogger:Channel("Name")` - nil-safe, no require, no load order. In the
other direction it taps producers that already exist: the framework's `Manifold.Logger` by
shadowing its `_DispatchLog` funnel on the instance, the Template Loader through its listener API,
and `print` on request. Because autorun runs long before any Cheat Table is opened, the framework
tap is polled by a watch that attaches when a table's logger appears, re-attaches when another
table replaces it, and detaches when it goes away. Every tap is idempotent, reversible and
non-owning, so nothing it attaches to notices when the console is closed or was never installed.
It carries its own copy of the design framework and reads `forms.ActiveDesignTheme` read-only,
exactly as the Template Loader and Table Files do.

The Address List is coupled to the Logger and to a table's theme the same optional way the others
are, and it registers no menu, so the CE Utility entry above is the only one that exists. It is
also the one segment with two genuine cross-segment hazards, and both are worth knowing about
before they bite.

The first is `Manifold.Callbacks`. A Cheat Table that loads it replaces
`AddressList.OnDescriptionChange`, `OnAddressChange`, `OnTypeChange`, `OnValueChange` and
`OnAutoAssemblerEdit` with its own protected-change handlers, so switches like
`DisableDescriptionChange` can refuse an edit. Those events fire for an edit made in Cheat
Engine's own list. The Address List writes through the record's properties directly, which is the
only way a bulk edit can work at all, and a property write does not go through them. A table that
protects its records from being renamed in Cheat Engine is therefore **not** protected from being
renamed in this window. Neither segment is wrong. They are two different doors, and the guards are
on one of them.

The second is the CE Utility's **Normalize Cheat Table IDs**, which renumbers every record 1..N in
tree order. The Address List keys its snapshot, its selection, its collapsed set, its problem
markers and every entry in its undo history by record id. It only drops that world when a fresh
snapshot shares **no** id at all with the one before it, which is how a different Cheat Table is
recognised, and a renumbering to 1..N almost always keeps some ids in common. So the tree and the
inspector recover by themselves on the next poll, and the undo history does not: a transaction
written before the normalise still names the ids the records had then, and undoing it afterwards
writes into whichever records now carry those numbers. Normalise before you start editing, not in
the middle of it, and re-execute `Manifold-AddressList.lua` if you have already done both. This is
the same class of problem as [T9](TODO.md#t9-state-ids-collide-with-normalize-cheat-table-ids),
where the framework's `Manifold.State` keys saved state by the same ids.

Manifold RTTI, Manifold UE and Manifold Godot each register a structure name lookup, a dissect
override and a symbol lookup. Hosts ask callbacks in the order they were registered and take the
first answer, so the three keep to one rule each and the load order does not matter:

- **Each engine script answers only in its own engine.** Manifold UE resolves on its own only in a
  process that looks like Unreal (executable name and path, a CoreUObject module, or the
  `/Script/CoreUObject` literal), Manifold Godot only in one whose executable carries the Godot 4
  version literal. Anywhere else each gives up after one scan of the main module and stays quiet
  for the rest of the process.
- **RTTI steps aside.** Unreal and Godot objects carry MSVC run-time type information too. Before
  RTTI names or fills an address it asks `ManifoldUE.claims` and `ManifoldGodot.claims` and leaves
  everything either claims to it, including C++ objects embedded inside their objects. It never
  calls `ManifoldUE.owner`, which resolves with the full search on every call.
- **The symbols cannot meet.** RTTI only answers names that end in `::vftable`. Manifold UE
  answers `<Type>_<Property>` and `GObjects`, `FNamePool`, `GNames`, `GameEngine`. Every Manifold
  Godot symbol starts with `Godot`, apart from the optional engine method names `Class::method`,
  of which none is `vftable`.
- **Symbols stay with their process.** Each of the three unregisters the symbols it registered
  when another process is opened, so the names of one game never label the next one.

This was checked with all three loaded, in both load orders, in an Unreal Engine 4 game (Crab
Champions), a Godot 4 game (Unrailed 2) and a plain C++ process. Unreal builds usually disable
run-time type information, so there RTTI only ever sees the game's non-Unreal C++ objects (the
Steam interfaces, for example); the claim check matters for Unreal games built with it and for
every Godot game built with MSVC or clang-cl.

The data directories do not collide. The Framework uses `%LOCALAPPDATA%\Manifold\` and the
Template Loader uses `%LOCALAPPDATA%\Manifold\TemplateLoader\`. The Logger shares the Framework's
`%LOCALAPPDATA%\Manifold\Logs\` folder on purpose - one folder to open, one to clean out - and
the file names do not collide: the Framework writes `Manifold.Runtime.<table>.log`, the Logger
writes `Manifold.Console.log` plus its numbered generations.

## License

MIT. See `LICENSE` in the repository root and in `Manifold-Modules/`. `Manifold.Json.lua` is
additionally covered by CC-BY, by Jeffrey Friedl.
