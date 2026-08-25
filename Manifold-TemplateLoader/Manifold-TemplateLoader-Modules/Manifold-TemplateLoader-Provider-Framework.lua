--[[
    Framework provider: what the Manifold Framework currently offers, and
    ready-made Auto Assembler statements that adapt to it.

    The bundled templates use custom Auto Assembler commands that come from
    the framework, not from the loader. Whether they exist depends on what
    the cheat table loaded, which can differ from one generation to the next
    so it is decided per generation, here, rather than baked into the
    templates.

    Detection is the same signal the framework uses on itself.
    Manifold.Bootstrap's Ready() publishes each module under its declared
    global (Manifold.Bootstrap.lua, rawset(_G, mod.global, instance)), so
    "assemblerCommands" and "trampolines" being present means the modules
    were constructed. Cheat Engine has no API to ask whether an Auto
    Assembler command name is registered, so there is nothing more direct to
    check.

    Two of the commands have exact plain-CE equivalents, so the safety they
    provide survives without the framework:

        ManifoldScanModule -> aobScanModule   (both define the symbol)
        ManifoldAssert     -> assert          (Cheat Engine's own command.
                                               NOT identical! ManifoldAssert
                                               logs a warning and continues,
                                               CE's assert raises and the
                                               script does not enable. Both
                                               verify the same bytes. The
                                               plain one is the stricter of
                                               the two.)

    The rest (the detour trio, ManifoldResolveStatic) have none. Templates
    needing those declare a Capability and branch on HasManifoldTrampolines
    or HasManifoldCommands, so a missing framework fails loudly instead of
    silently generating a script that assembles into a no-op.
]]

local Provider = { Name = "Framework" }

local function moduleLoaded(name)
    local instance = rawget(_G, name)
    return type(instance) == "table"
end

function Provider.Register(registry, services)
    local log = services.Log

    return registry:RegisterProvider{
        Name = Provider.Name,
        Variables = {
            HasManifoldCommands = {
                Type = "boolean",
                Description = "True when the Manifold Framework's Auto Assembler commands are loaded",
                Resolve = function()
                    return moduleLoaded("assemblerCommands")
                end
            },
            HasManifoldTrampolines = {
                Type = "boolean",
                Description = "True when the framework's detour/trampoline support is loaded",
                Resolve = function()
                    -- AssemblerCommands declares trampolines as a required
                    -- dependency, so the detour commands need both.
                    return moduleLoaded("assemblerCommands") and moduleLoaded("trampolines")
                end
            },
            ScanModule = {
                Type = "string",
                Description = "Module signature scan, ManifoldScanModule or aobScanModule without the framework",
                DependsOn = { "HookNameParsed", "Module", "AoBStr" },
                Resolve = function(ctx)
                    local arguments = string.format("%s,%s,%s",
                        ctx:Get("HookNameParsed"), ctx:Get("Module"), ctx:Get("AoBStr"))
                    if ctx:Get("HasManifoldCommands") then
                        return "ManifoldScanModule(" .. arguments .. ")"
                    end
                    log:Info("[Framework] Manifold Auto Assembler commands are not loaded. The scan falls back to aobScanModule.")
                    return "aobScanModule(" .. arguments .. ")"
                end
            },
            AssertBytes = {
                Type = "string",
                Description = "Byte-match guard: ManifoldAssert, or Cheat Engine's own assert()",
                DependsOn = { "HookNameParsed", "AoBOffset", "OriginalBytes" },
                Resolve = function(ctx)
                    -- The scan symbol names the START of the signature, while
                    -- OriginalBytes were read at the injection address, which
                    -- is AoBOffset bytes into it. Every other hook-site
                    -- reference in the templates carries the offset, and this
                    -- one must too. getUniqueAOB only returns offset 0 when
                    -- the injection's own bytes are already unique in the
                    -- module, otherwise it grows the pattern backwards. Cheat
                    -- Engine's own generator compensates the same way
                    -- (frmautoinjectunit.pas, symbolName + '+' + offset).
                    -- Without it the guard compares the wrong bytes. A warning
                    -- with ManifoldAssert, and a hard abort with CE's assert.
                    local site = ctx:Get("HookNameParsed") .. ctx:Get("AoBOffset")
                    local originalBytes = ctx:Get("OriginalBytes")
                    if not ctx:Get("HasManifoldCommands") then
                        return string.format("assert(%s,%s)", site, originalBytes)
                    end
                    return string.format("ManifoldAssert(%s,%s)", site, originalBytes)
                end
            },
            FrameworkWarning = {
                Type = "string",
                Description = "Comment block when the Manifold commands are missing, '' otherwise",
                Resolve = function(ctx)
                    if ctx:Get("HasManifoldCommands") then return "" end
                    return table.concat({
                        "{",
                        "   WARNING: this script needs the Manifold Framework, which is not loaded.",
                        "   The Manifold* commands below will not assemble until it is.",
                        "}"
                    }, "\n")
                end
            },
            TrampolineWarning = {
                Type = "string",
                Description = "Comment block when detour support is missing, '' otherwise",
                Resolve = function(ctx)
                    if ctx:Get("HasManifoldTrampolines") then return "" end
                    local missing = ctx:Get("HasManifoldCommands")
                        and "the Manifold Framework's Trampolines module"
                        or "the Manifold Framework"
                    return table.concat({
                        "{",
                        "   WARNING: this script needs " .. missing .. ", which is not loaded.",
                        "   ManifoldInstallDetour / ManifoldEmitOriginal / ManifoldDestroyDetour",
                        "   below will not assemble until it is. There is no plain Cheat Engine",
                        "   equivalent for a trampoline, use a non-trampoline template instead.",
                        "}"
                    }, "\n")
                end
            }
        }
    }
end

return Provider