return {
    SchemaVersion = 2,
    Id = "manifold.hook.trampoline",
    Caption = "Hook — Trampoline",
    Description = "Detour-based hook: the original instructions are relocated, not overwritten.",
    Category = "x86/x64 — Hooks — Trampoline",
    CategoryOrder = 9,
    Order = 10,
    Tags = { "trampoline", "detour" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes"
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