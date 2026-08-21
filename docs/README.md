# Manifold — Documentation

Documentation for the three segments of the
[`Leunsel/CheatEngineLua`](https://github.com/Leunsel/CheatEngineLua) repository.

| Segment | Directory | Runs where? | Purpose |
|---|---|---|---|
| **Manifold CE Utility** | `Manifold-CE-Utility/` | Cheat Engine `autorun` | Quality-of-life menu for the Cheat Engine UI itself |
| **Manifold Framework** | `Manifold-Modules/` | Inside a Cheat Table (`luaFiles` / table files) | Modular runtime library for Cheat Tables |
| **Manifold Template Loader** | `Manifold-TemplateLoader/` | Cheat Engine `autorun` | Template engine for Auto Assembler scripts |

## Entry points

- [Manifold CE Utility](Manifold-CE-Utility.md) — installation, menu reference, configuration
- [Manifold Framework](Manifold-Framework.md) — architecture, bootstrapping, data directory, module overview
- [Manifold Framework — API Reference](Manifold-Framework-API.md) — complete function reference for every module
- [Manifold Template Loader](Manifold-Template-Loader.md) — template syntax, context variables, menu, hot reload
- [TODO](TODO.md) — open work items from the code review, ordered by priority

## Overall architecture

The three segments are **functionally separate and run at different times**. There is no hard
coupling between them — they only share naming conventions and (partly) the data directory.

```
Cheat Engine starts
│
├─ autorun/Manifold-CE-Utility.lua            ← Segment 1: the "[— Manifold —]" menu
│    └─ hooks into MainForm.Menu
│
├─ autorun/Manifold-TemplateLoader-Main.lua   ← Segment 3: Template Loader
│    ├─ Host (persistent, survives hot reload)
│    └─ Loader → registerAutoAssemblerTemplate(...)
│         └─ shows up in every Auto Assembler window's menu
│
└─ A Cheat Table is opened
     └─ its table Lua script calls CETrequire("Manifold.<Module>")   ← Segment 2: Framework
          ├─ Logger / CustomIO / Json          (base services)
          ├─ ProcessHandler / Utils            (lifecycle)
          ├─ Memory / State / AutoAssembler    (runtime)
          ├─ Forms / UI                        (presentation + themes)
          ├─ Teleporter                        (feature module)
          └─ AssemblerCommands / Trampolines   (AA language extension)
```

### Where the segments touch

1. **Template Loader → Framework.** The bundled `.CEA` templates emit scripts that call
   `ManifoldScanModule(...)` and `ManifoldAssert(...)`. Those Auto Assembler commands are
   registered by the **Framework** (`Manifold.AssemblerCommands`), not by the Loader. Without the
   Framework loaded, generated scripts fail to assemble.
2. **CE Utility → Framework.** No runtime coupling. The utility only references the framework in
   source comments as a reference implementation.
3. **Data directory.** The Framework uses `%LOCALAPPDATA%\Manifold\`, the Template Loader uses
   `%LOCALAPPDATA%\Manifold\TemplateLoader\`. They do not collide.

## License

MIT (see `LICENSE` in the repository root and in `Manifold-Modules/`).
`Manifold.Json.lua` is additionally covered by CC-BY (Jeffrey Friedl).
