return {
    SchemaVersion = 2,
    Id = "manifold.conditional.simple.trampoline",
    Caption = "Conditional Hook — Simple — Trampoline",
    Description = "Detour-based flag-controlled hook.",
    Category = "x86/x64 — Conditional Hooks — Trampoline",
    CategoryOrder = 6,
    Order = 10,
    Tags = { "conditional", "flag", "trampoline" },
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