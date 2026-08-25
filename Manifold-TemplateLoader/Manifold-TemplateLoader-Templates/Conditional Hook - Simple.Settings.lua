return {
    SchemaVersion = 2,
    Id = "manifold.conditional.simple",
    Caption = "Conditional Hook — Simple",
    Description = "Pointer capture with a per-cheat flag byte controlling the hook.",
    Category = "x86/x64 — Conditional Hooks",
    CategoryOrder = 4,
    Order = 10,
    Tags = { "conditional", "flag" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "OriginalOpcodes"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}