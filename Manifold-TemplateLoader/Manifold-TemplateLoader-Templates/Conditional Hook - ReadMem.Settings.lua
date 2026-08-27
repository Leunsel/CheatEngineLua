return {
    SchemaVersion = 2,
    Id = "manifold.conditional.simple.readmem",
    Caption = "Conditional Hook — Read Memory",
    Description = "Flag-controlled hook that restores the original code with readMem. " ..
                  "Capture slots and the multiplier are chosen in the dialog.",
    Category = "x86/x64 — Conditional Hooks",
    CategoryOrder = 5,
    Order = 10,
    Tags = { "conditional", "flag", "readmem" },

    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "JumpSize",
        "BaseAddressRegister", "PointerType", "PointerSize"
    },

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
            Default = 1,
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
            Caption = "Multiplier register",
            Default = "xmm0"
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
