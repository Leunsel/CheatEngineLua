return {
    SchemaVersion = 2,
    Id = "manifold.hook.default",
    Caption = "Default Injection Hook",
    Description = "The standard code-cave injection: scan, allocate, jump, restore.",
    Category = "x86/x64 — Default Hooks",
    CategoryOrder = 8,
    Order = 10,
    Tags = { "injection", "default" },
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
