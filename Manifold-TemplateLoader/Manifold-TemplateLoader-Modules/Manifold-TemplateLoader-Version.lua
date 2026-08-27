--[[
    Single source of truth for the Template Loader version.

    README, diagnostics, logs and the << Version >> context variable all read
    from here. Nothing else in the tree carries its own version number.
]]

local Version = {
    Major = 3,
    Minor = 1,
    Patch = 3,
    Name = "Manifold TemplateLoader"
}

function Version.String()
    return string.format("%d.%d.%d", Version.Major, Version.Minor, Version.Patch)
end

function Version.Full()
    return Version.Name .. " " .. Version.String()
end

return Version