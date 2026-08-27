return {
    SchemaVersion = 2,
    Id = "manifold.pointer.readmem",
    Caption = "Pointer Hook — Read Memory",
    Description = "Pointer capture that restores the original code with readMem. " ..
                  "Capture slots and the multiplier are chosen in the dialog.",
    Category = "x86/x64 — Pointer Hooks",
    CategoryOrder = 2,
    Order = 10,
    Tags = { "pointer", "readmem" },

    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "JumpSize",
        "BaseAddressRegister", "PointerType", "PointerSize"
    },

    Inputs = {
        {
            Name = "CaptureSlots",
            Type = "integer",
            Caption = "Capture slots (1 = single pointer)",
            Default = 1,
            Min = 1,
            Max = 8
        },
        {
            Name = "CompareRegister",
            Type = "string",
            Caption = "Compare register (slots > 1)",
            Default = "rax"
        },
        {
            Name = "UseMultiplier",
            Type = "boolean",
            Caption = "Add a multiplier cell",
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
