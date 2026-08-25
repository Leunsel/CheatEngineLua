return {
    SchemaVersion = 2,
    Id = "manifold.resolver.static",
    Caption = "Manifold Static Address Resolver Hook",
    Description = "Resolves a static address from the scanned instruction via ManifoldResolveStatic.",
    Category = "x86/x64 — Static Address Resolver",
    CategoryOrder = 11,
    Order = 10,
    Tags = { "resolver", "static" },
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes"
    },
    -- No plain Cheat Engine equivalent exists for these commands, so the
    -- loader warns up front rather than generating a script that cannot work.
    Capabilities = { "Manifold.AssemblerCommands" },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}