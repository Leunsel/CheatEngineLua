return {
    SchemaVersion = 2,
    Id = "manifold.patch.earlyout",
    Caption = "Early Out Hook",
    Description = "Patches the selected function entry with a ret (C3).",
    Category = "x86/x64 — Byte Patch Hooks",
    CategoryOrder = 7,
    Order = 20,
    Tags = { "patch", "ret" },
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