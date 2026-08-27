return {
    SchemaVersion = 2,
    Id = "manifold.lua.config",
    Caption = "Lua Config Auto-Assemble Preset",
    Description = "Lua wrapper plus an optional flag and multiplier config block for the cheat table.",
    Category = "x86/x64 — Lua Auto-Assemble Presets",
    CategoryOrder = 12,
    Order = 20,
    Tags = { "lua", "preset", "config" },

    Requires = {
        "HookName"
    },

    Inputs = {
        {
            Name = "UseFlag",
            Type = "boolean",
            Caption = "Flag cell",
            Default = true
        },
        {
            Name = "FlagDefault",
            Type = "integer",
            Caption = "Flag starts at",
            Default = 1,
            Min = 0,
            Max = 255
        },
        {
            Name = "UseMultiplier",
            Type = "boolean",
            Caption = "Multiplier cell",
            Default = true
        },
        {
            Name = "MultiplierValue",
            Type = "string",
            Caption = "Multiplier value",
            Default = "1.0"
        }
    },

    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}
