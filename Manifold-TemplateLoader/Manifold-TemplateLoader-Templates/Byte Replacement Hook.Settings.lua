return {
    SchemaVersion = 2,
    Id = "manifold.patch.replace",
    Caption = "Byte Replacement Hook",
    Description = "Re-applies the original bytes at the signature: a patch skeleton to edit.",
    Category = "x86/x64 — Byte Patch Hooks",
    CategoryOrder = 7,
    Order = 10,
    Tags = { "patch", "bytes" },
    Requires = {
        "AddressValue", "Module", "AoBStr",
        "OriginalBytes"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}