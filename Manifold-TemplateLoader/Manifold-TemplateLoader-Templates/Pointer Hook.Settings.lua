return {
    SchemaVersion = 2,
    Id = "manifold.pointer.basic",
    Caption = "Pointer Hook",
    Description = "Captures the base pointer of the accessed structure from the selected instruction.",
    Category = "x86/x64 — Pointer Hooks",
    CategoryOrder = 1,
    Order = 10,
    Tags = { "pointer", "injection" },
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