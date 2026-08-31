# Manifold Documentation

Documentation for the six segments of the
[`Leunsel/CheatEngineLua`](https://github.com/Leunsel/CheatEngineLua) repository.

| Segment | Directory | Runs where | Purpose |
|---|---|---|---|
| Manifold CE Utility | `Manifold-CE-Utility/` | Cheat Engine `autorun` | Quality of life menu for the Cheat Engine UI itself |
| Manifold Exception Handler | `Manifold-ExceptionHandler/` | Cheat Engine `autorun` + native DLL | Attributes every exception raised in the process |
| Manifold Framework | `Manifold-Modules/` | Inside a Cheat Table (`luaFiles` or table files) | Modular runtime library for Cheat Tables |
| Manifold Logger | `Manifold-Logger/` | Cheat Engine `autorun` | Canvas-drawn log console any script can side-load |
| Manifold Table Files | `Manifold-TableFiles/` | Cheat Engine `autorun` | Editable window over the files attached to a Cheat Table |
| Manifold Template Loader | `Manifold-TemplateLoader/` | Cheat Engine `autorun` | Template engine for Auto Assembler scripts |

## Entry points

[Manifold CE Utility](Manifold-CE-Utility.md) covers installation, the menu reference and
configuration.

[Manifold Exception Handler](Manifold-ExceptionHandler.md) covers installation, building the
native half, the report anatomy and what is and is not catchable.

[Manifold Framework](Manifold-Framework.md) covers the architecture, bootstrapping, the data
directory and an overview of the modules.

[Manifold Framework API Reference](Manifold-Framework-API.md) is the complete function reference
for every module.

[Manifold Logger](Manifold-Logger.md) covers the record model, channels, the canvas console, the
bridges onto other producers and the log file.

[Manifold Table Files](Manifold-TableFiles.md) covers installation, the window, and the design
framework instance it carries.

[Manifold Template Loader](Manifold-Template-Loader.md) covers the template syntax, context
variables, the menu and hot reload.

[TODO](TODO.md) lists open work items from the code review, ordered by priority.

## Overall architecture

The segments are functionally separate and run at different times. There is no hard coupling
between them. They only share naming conventions and, in part, the data directory.

```
Cheat Engine starts
│
├─ autorun/Manifold-CE-Utility.lua            Segment 1, the "[— Manifold —]" menu
│    └─ hooks into MainForm.Menu
│
├─ autorun/Manifold-ExceptionHandler.lua      Segment 5, the exception recorder
│    └─ package.loadlib → ManifoldExceptionHandler.dll
│         └─ AddVectoredExceptionHandler(first)
│              sees every exception in the process, before Cheat Engine does
│
├─ autorun/Manifold-TableFiles.lua            Segment 4, the Table Files window
│    └─ publishes ManifoldTableFiles, registers no menu of its own
│
├─ autorun/Manifold-Logger.lua                Segment 6, the log console
│    ├─ publishes ManifoldLogger, adds a "Logger" main-menu entry
│    ├─ bridges onto Manifold.Logger and the Template Loader when present
│    └─ hands any script its own channel: ManifoldLogger:Channel("Name")
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
          ├─ Teleporter                        feature module
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

The CE Utility contributes the menu entry that opens Table Files and delegates to the global
`ManifoldTableFiles`, logging where to install it when that global is absent. Neither segment
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
non-owning, so nothing it attaches to notices when the console is closed or was never installed. It carries its own copy of the design framework and reads
`forms.ActiveDesignTheme` read-only, exactly as the Template Loader and Table Files do.

The Exception Handler is coupled to nothing at all, deliberately. It is the segment that has to
keep working when the rest is broken, so it depends on no Manifold module, loads before the
Framework exists, and degrades to a warning if its native half is missing. The Framework may call
`ManifoldExceptionHandler.Note(...)` when the global happens to be there; nothing requires it to
be.

The data directories do not collide. The Framework uses `%LOCALAPPDATA%\Manifold\`, the
Template Loader uses `%LOCALAPPDATA%\Manifold\TemplateLoader\`, and the Exception Handler writes
to `%LOCALAPPDATA%\Manifold\Crashes\`. The Logger shares the Framework's
`%LOCALAPPDATA%\Manifold\Logs\` folder on purpose - one folder to open, one to clean out - and
the file names do not collide: the Framework writes `Manifold.Runtime.<table>.log`, the Logger
writes `Manifold.Console.log` plus its numbered generations.

## License

MIT. See `LICENSE` in the repository root and in `Manifold-Modules/`. `Manifold.Json.lua` is
additionally covered by CC-BY, by Jeffrey Friedl.
