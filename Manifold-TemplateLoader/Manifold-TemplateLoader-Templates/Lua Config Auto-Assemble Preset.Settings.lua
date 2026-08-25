return {
    SchemaVersion = 2,
    Id = "manifold.lua.config",
    Caption = "Lua Config Auto-Assemble Preset",
    Description = "Lua wrapper plus a flag/multiplier config block for the cheat table.",
    Category = "x86/x64 — Lua Auto-Assemble Presets",
    CategoryOrder = 12,
    Order = 20,
    Tags = { "lua", "preset", "config" },
    Requires = {
        "HookName"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}
