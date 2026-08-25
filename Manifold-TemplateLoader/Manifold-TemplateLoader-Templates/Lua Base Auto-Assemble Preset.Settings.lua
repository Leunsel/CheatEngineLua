return {
    SchemaVersion = 2,
    Id = "manifold.lua.base",
    Caption = "Lua Base Auto-Assemble Preset",
    Description = "Lua wrapper that delegates the script body to an external .CEA file.",
    Category = "x86/x64 — Lua Auto-Assemble Presets",
    CategoryOrder = 12,
    Order = 10,
    Tags = { "lua", "preset" },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}