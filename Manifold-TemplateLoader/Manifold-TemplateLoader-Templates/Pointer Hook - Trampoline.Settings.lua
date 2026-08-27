return {
    SchemaVersion = 2,
    Id = "manifold.pointer.trampoline",
    Caption = "Pointer Hook — Trampoline",
    Description = "Detour-based pointer capture; the original instructions are relocated. " ..
                  "Capture slots and the multiplier are chosen in the dialog.",
    Category = "x86/x64 — Pointer Hooks",
    CategoryOrder = 2,
    Order = 20,
    Tags = { "pointer", "trampoline", "detour" },
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
