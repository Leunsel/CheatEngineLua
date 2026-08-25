return {
    SchemaVersion = 2,
    Id = "manifold.pointer.multiplier.trampoline",
    Caption = "Pointer Hook — Multiplier — Trampoline",
    Description = "Detour-based pointer capture with a float multiplier.",
    Category = "x86/x64 — Pointer Hooks — Trampoline",
    CategoryOrder = 3,
    Order = 20,
    Tags = { "pointer", "multiplier", "trampoline" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "BaseAddressRegister"
    },
    -- No plain Cheat Engine equivalent exists for these commands, so the
    -- loader warns up front rather than generating a script that cannot work.
    Capabilities = { "Manifold.Trampolines" },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}