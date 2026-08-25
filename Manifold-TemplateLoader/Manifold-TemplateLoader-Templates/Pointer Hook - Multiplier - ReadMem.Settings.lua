return {
    SchemaVersion = 2,
    Id = "manifold.pointer.multiplier.readmem",
    Caption = "Pointer Hook — Multiplier — Read Memory",
    Description = "Pointer capture with a multiplier and readMem-based restore.",
    Category = "x86/x64 — Pointer Hooks — ReadMem",
    CategoryOrder = 2,
    Order = 20,
    Tags = { "pointer", "multiplier", "readmem" },
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