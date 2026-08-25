--[[
    Runtime provider: loader metadata, timestamps and the Header partial.

    Header is a context variable for 2.x compatibility (<< Header >> renders
    Header.CEA), resolved lazily so templates without a header never pay for
    one. The generator stores the render environment on the context before
    rendering, which is what makes a nested template render possible from
    inside a resolver.
]]

local Provider = { Name = "Runtime" }

function Provider.Register(registry, services)
    local version = services.Version
    local engine = services.Engine
    local file = services.File
    local log = services.Log
    local templateFolder = services.Paths.TemplateFolder
    return registry:RegisterProvider{
        Name = Provider.Name,
        Variables = {
            Version = {
                Type = "string",
                Description = "Template Loader version",
                Resolve = function() return version.String() end
            },
            Date = {
                Type = "string",
                Description = "Generation date (YYYY-MM-DD)",
                Resolve = function() return os.date("%Y-%m-%d") end
            },
            Time = {
                Type = "string",
                Description = "Generation time (HH:MM:SS)",
                Resolve = function() return os.date("%H:%M:%S") end
            },
            DateTime = {
                Type = "string",
                Description = "Generation date and time",
                Resolve = function() return os.date("%Y-%m-%d %H:%M:%S") end
            },
            MonoSupportStatus = {
                Type = "string",
                Description = "Placeholder until a managed-runtime provider exists",
                Resolve = function()
                    return "Managed Mono metadata is not implemented. A MonoProvider can register these variables without core changes."
                end
            },
            Header = {
                Type = "string",
                Description = "Rendered Header.CEA partial",
                Resolve = function(ctx)
                    local path = file:NormalizePath(templateFolder .. "/Header" .. engine.ScriptExtension)
                    if not path or not file:Exists(path) then
                        log:Warning("[Runtime] Header template not found. Generation continues without it.")
                        return ""
                    end
                    if not ctx.Environment then
                        error("Header cannot render outside a generation (no environment attached)", 0)
                    end
                    local text, err = engine:RenderFile(path, ctx.Environment)
                    if not text then error(err, 0) end
                    return text
                end
            }
        }
    }
end

return Provider