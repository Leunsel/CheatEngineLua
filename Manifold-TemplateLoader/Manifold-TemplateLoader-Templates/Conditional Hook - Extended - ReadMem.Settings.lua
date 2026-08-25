return {
    SchemaVersion = 2,
    Id = "manifold.conditional.extended.readmem",
    Caption = "Conditional Hook — Extended — ReadMem",
    Description = "Player/entity flag-controlled hook with readMem restore.",
    Category = "x86/x64 — Conditional Hooks — ReadMem",
    CategoryOrder = 5,
    Order = 20,
    Tags = { "conditional", "flag", "compare", "readmem" },
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