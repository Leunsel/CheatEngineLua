return {
    SchemaVersion = 2,
    Id = "manifold.pointer.multiplier",
    Caption = "Pointer Hook — Multiplier",
    Description = "Captures a base pointer and multiplies the hooked float value.",
    Category = "x86/x64 — Pointer Hooks",
    CategoryOrder = 1,
    Order = 30,
    Tags = { "pointer", "multiplier" },
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