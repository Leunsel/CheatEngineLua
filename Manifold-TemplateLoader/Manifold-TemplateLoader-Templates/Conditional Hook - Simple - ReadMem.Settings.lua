return {
    SchemaVersion = 2,
    Id = "manifold.conditional.simple.readmem",
    Caption = "Conditional Hook — Simple — ReadMem",
    Description = "Flag-controlled hook using readMem-based restore.",
    Category = "x86/x64 — Conditional Hooks — ReadMem",
    CategoryOrder = 5,
    Order = 10,
    Tags = { "conditional", "flag", "readmem" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "JumpSize"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}