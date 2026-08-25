return {
    SchemaVersion = 2,
    Id = "manifold.patch.earlyout.return",
    Caption = "Early Out Hook — Return",
    Description = "Patches the selected function entry with mov al,1 / ret (B0 01 C3).",
    Category = "x86/x64 — Byte Patch Hooks",
    CategoryOrder = 7,
    Order = 30,
    Tags = { "patch", "ret" },

    -- Derived from what the template actually references.
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