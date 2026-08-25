# Manifold Documentation

Documentation for the three segments of the
[`Leunsel/CheatEngineLua`](https://github.com/Leunsel/CheatEngineLua) repository.

| Segment | Directory | Runs where | Purpose |
|---|---|---|---|
| Manifold CE Utility | `Manifold-CE-Utility/` | Cheat Engine `autorun` | Quality of life menu for the Cheat Engine UI itself |
| Manifold Framework | `Manifold-Modules/` | Inside a Cheat Table (`luaFiles` or table files) | Modular runtime library for Cheat Tables |
| Manifold Template Loader | `Manifold-TemplateLoader/` | Cheat Engine `autorun` | Template engine for Auto Assembler scripts |

## Entry points

[Manifold CE Utility](Manifold-CE-Utility.md) covers installation, the menu reference and
configuration.

[Manifold Framework](Manifold-Framework.md) covers the architecture, bootstrapping, the data
directory and an overview of the modules.

[Manifold Framework API Reference](Manifold-Framework-API.md) is the complete function reference
for every module.

[Manifold Template Loader](Manifold-Template-Loader.md) covers the template syntax, context
variables, the menu and hot reload.

[TODO](TODO.md) lists open work items from the code review, ordered by priority.

## Overall architecture

The three segments are functionally separate and run at different times. There is no hard
coupling between them. They only share naming conventions and, in part, the data directory.

```
Cheat Engine starts
│
├─ autorun/Manifold-CE-Utility.lua            Segment 1, the "[— Manifold —]" menu
│    └─ hooks into MainForm.Menu
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

The data directories do not collide. The Framework uses `%LOCALAPPDATA%\Manifold\` and the
Template Loader uses `%LOCALAPPDATA%\Manifold\TemplateLoader\`.

## License

MIT. See `LICENSE` in the repository root and in `Manifold-Modules/`. `Manifold.Json.lua` is
additionally covered by CC-BY, by Jeffrey Friedl.
