return {
    SchemaVersion = 2,
    Id = "manifold.pointer.extended.readmem",
    Caption = "Pointer Hook — Extended — Read Memory",
    Description = "Compare-driven player/entity pointer capture using readMem restore.",
    Category = "x86/x64 — Pointer Hooks — ReadMem",
    CategoryOrder = 2,
    Order = 30,
    Tags = { "pointer", "compare", "readmem" },
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