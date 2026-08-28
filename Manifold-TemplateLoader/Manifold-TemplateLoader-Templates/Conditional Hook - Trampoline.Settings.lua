return {
    SchemaVersion = 2,
    Id = "manifold.conditional.trampoline",
    Caption = "Conditional Hook — Trampoline",
    Description = "Detour-based flag-controlled hook; the original instructions are relocated. " ..
                  "Capture slots and the multiplier are chosen in the dialog.",
    Category = "x86/x64 — Conditional Hooks",
    CategoryOrder = 5,
    Order = 20,
    Tags = { "conditional", "flag", "trampoline", "detour" },

    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "BaseAddressRegister",
        "PointerType", "PointerSize"
    },

    -- No plain Cheat Engine equivalent exists for these commands, so the
    -- loader warns up front rather than generating a script that cannot work.
    Capabilities = { "Manifold.Trampolines" },

    Inputs = {
        {
            Name = "CaptureSlots",
            Type = "integer",
            Caption = "Capture slots",
            Default = 1,
            Min = 1,
            Max = 8
        },
        {
            Name = "CompareRegister",
            Type = "string",
            Caption = "Compare register",
            Default = "rax"
        },
        {
            Name = "FlagDefault",
            Type = "integer",
            Caption = "Flag starts at",
            Default = 2,
            Min = 0,
            Max = 255
        },
        {
            Name = "UseMultiplier",
            Type = "boolean",
            Caption = "Multiplier",
            Default = false
        },
        {
            Name = "MultiplierRegister",
            Type = "string",
            Caption = "Scratch register",
            Default = "xmm1"
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
