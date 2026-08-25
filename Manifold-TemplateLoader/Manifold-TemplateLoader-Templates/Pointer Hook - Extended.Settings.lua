return {
    SchemaVersion = 2,
    Id = "manifold.pointer.extended",
    Caption = "Pointer Hook — Extended",
    Description = "Captures separate player/entity base pointers behind a user-written compare.",
    Category = "x86/x64 — Pointer Hooks",
    CategoryOrder = 1,
    Order = 20,
    Tags = { "pointer", "injection", "compare" },
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