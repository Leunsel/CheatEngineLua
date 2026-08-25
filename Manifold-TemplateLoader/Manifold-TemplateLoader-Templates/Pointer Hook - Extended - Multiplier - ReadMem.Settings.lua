return {
    SchemaVersion = 2,
    Id = "manifold.pointer.extended.multiplier.readmem",
    Caption = "Pointer Hook — Extended — Multiplier — Read Memory",
    Description = "Compare-driven pointer capture with multipliers and readMem restore.",
    Category = "x86/x64 — Pointer Hooks — ReadMem",
    CategoryOrder = 2,
    Order = 40,
    Tags = { "pointer", "multiplier", "compare", "readmem" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "JumpSize",
        "BaseAddressRegister"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}
