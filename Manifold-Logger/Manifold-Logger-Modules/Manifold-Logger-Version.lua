--[[
    Manifold Logger version. Single source of truth.

    README, the window caption, the About block and the startup line all read
    from here. Nothing else in the tree carries its own version number. Bump
    the three numbers here and every consumer follows.
]]

local Version = {
    Major = 1,
    Minor = 0,
    Patch = 0,
    Name = "Manifold Logger",
    Author = { "Leunsel", "LeFiXER" }
}

function Version.String()
    return string.format("%d.%d.%d", Version.Major, Version.Minor, Version.Patch)
end

function Version.Full()
    return Version.Name .. " " .. Version.String()
end

function Version.Authors()
    return table.concat(Version.Author, ", ")
end

return Version
