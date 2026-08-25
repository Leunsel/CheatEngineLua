return {
    SchemaVersion = 2,
    Id = "manifold.patch.nop",
    Caption = "Byte Replacement Hook — Nop",
    Description = "Nops the overwritten instruction span and restores it on disable.",
    Category = "x86/x64 — Byte Patch Hooks",
    CategoryOrder = 7,
    Order = 40,
    Tags = { "patch", "nop" },
    Requires = {
        "AddressValue", "Module", "AoBStr",
        "OriginalBytes", "JumpSize"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}