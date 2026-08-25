return {
    SchemaVersion = 2,
    Id = "manifold.teleporter.transform",
    Caption = "Transform Pointer Hook",
    Description = "Captures a transform base pointer and reserves saved/backup position storage.",
    Category = "x86/x64 — Teleporter Hooks",
    CategoryOrder = 10,
    Order = 10,
    Tags = { "teleporter", "pointer", "readmem" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "JumpSize",
        "BaseAddressRegister"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}