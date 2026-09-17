--[[
    Manifold Logger version. Single source of truth.

    The window caption, the About block, the startup line and the version
    Status reports all read from here, and nothing else in the modules
    carries a number of its own. Bump the three numbers here and every one of
    them follows. The README changelog names each release once, as history.
]]

local Version = {
    Major = 1,
    Minor = 1,
    Patch = 0,
    Name = "Manifold Logger",
    Author = { "Leunsel", "LeFiXER" }
}

--
--- ∑ The version as three numbers joined by dots.
--- @return string # Such as 1.1.0.
--
function Version.String()
    return string.format("%d.%d.%d", Version.Major, Version.Minor, Version.Patch)
end

--
--- ∑ The name and the version together, the way the window caption and the
---   startup line show them.
--- @return string # Such as Manifold Logger 1.1.0.
--
function Version.Full()
    return Version.Name .. " " .. Version.String()
end

--
--- ∑ Everybody who wrote the Logger, in one line for the About block.
--- @return string
--
function Version.Authors()
    return table.concat(Version.Author, ", ")
end

return Version
