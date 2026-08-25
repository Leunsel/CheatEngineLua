return {
    SchemaVersion = 2,
    Id = "manifold.pointer.extended.multiplier",
    Caption = "Pointer Hook — Extended — Multiplier",
    Description = "Compare-driven capture with separate increase/decrease multipliers.",
    Category = "x86/x64 — Pointer Hooks",
    CategoryOrder = 1,
    Order = 40,
    Tags = { "pointer", "multiplier", "compare" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "OriginalOpcodes",
        "BaseAddressRegister"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}