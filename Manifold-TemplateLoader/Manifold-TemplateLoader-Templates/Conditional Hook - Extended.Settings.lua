return {
    SchemaVersion = 2,
    Id = "manifold.conditional.extended",
    Caption = "Conditional Hook — Extended",
    Description = "Player/entity split with per-side flag bytes controlling the hook.",
    Category = "x86/x64 — Conditional Hooks",
    CategoryOrder = 4,
    Order = 20,
    Tags = { "conditional", "flag", "compare" },
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