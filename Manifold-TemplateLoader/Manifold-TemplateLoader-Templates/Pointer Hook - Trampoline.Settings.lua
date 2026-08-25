return {
    SchemaVersion = 2,
    Id = "manifold.pointer.trampoline",
    Caption = "Pointer Hook — Trampoline",
    Description = "Detour-based pointer capture; the original instructions are relocated.",
    Category = "x86/x64 — Pointer Hooks — Trampoline",
    CategoryOrder = 3,
    Order = 10,
    Tags = { "pointer", "trampoline", "detour" },
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