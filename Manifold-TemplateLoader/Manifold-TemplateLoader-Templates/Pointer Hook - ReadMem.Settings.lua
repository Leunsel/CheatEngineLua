return {
    SchemaVersion = 2,
    Id = "manifold.pointer.readmem",
    Caption = "Pointer Hook — Read Memory",
    Description = "Pointer capture that restores the original code with readMem.",
    Category = "x86/x64 — Pointer Hooks — ReadMem",
    CategoryOrder = 2,
    Order = 10,
    Tags = { "pointer", "readmem" },
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