--[[
    Manifold-CE-Fixes.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 1.0.0
    LICENSE : MIT
    CREATED : 2026-09-02
    UPDATED : 2026-09-02

    MIT License:
        Copyright (c) 2026 Leunsel

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    This file is part of the Manifold CE system.

    Workarounds for defects in Cheat Engine itself. Every fix in this file is
    self contained, installs from the autorun folder, survives being executed
    again from the Lua engine, and degrades visibly: when an API it needs is
    missing it prints one line and installs nothing.

    Fix: Structure Dissect access violation on middle click
        TfrmStructures2.tvStructureViewMouseDown copies the value under the
        cursor to the clipboard on a middle click. It finds the column by X
        through getColumnAtXPos, which walks the header sections from index 1.
        Section 0 is the "Offset-description" column, so a middle click on the
        description text, or right of the last column, yields nil, and the
        clipboard branch dereferences it: 0xC0000005 reading address 0x10.
        Present in Cheat Engine 7.5 and still in upstream master (2026-09-02).

        The guard below wraps the tree view's OnMouseDown and routes exactly
        those clicks through the right-button branch of the same handler, which
        is the middle-button branch without the clipboard copy. Every other
        click reaches the original handler untouched.
]]

----------------------------------------
-- CONFIG
----------------------------------------
local RUNTIME_STATE_KEY    = "__MANIFOLD_CE_FIXES_RUNTIME__"
local LOG_PREFIX           = "Manifold-CE-Fixes"
local STRUCTURE_FORM_CLASS = "TfrmStructures2"

-- TMouseButton ordinals and virtual key codes as Cheat Engine hands them to
-- Lua. defines.lua publishes them as globals; the literals are the fallback.
local MB_RIGHT    = rawget(_G, "mbRight")    or 1
local MB_MIDDLE   = rawget(_G, "mbMiddle")   or 2
local KEY_SHIFT   = rawget(_G, "VK_SHIFT")   or 16
local KEY_CONTROL = rawget(_G, "VK_CONTROL") or 17

-- Runtime handles live outside this chunk so that executing the file again
-- can release the previous form notification and recognise tree views that
-- already carry the guard.
local State = rawget(_G, RUNTIME_STATE_KEY)
if type(State) ~= "table" then
    State = {}
    _G[RUNTIME_STATE_KEY] = State
end
State.Wrappers = State.Wrappers or {}

----------------------------------------
-- LOGGING
----------------------------------------

--
--- ∑ Prints one line to the Cheat Engine console.
--- @param tag string # Context of the message.
--- @param msg string # The message.
--- @return nil
--
local function Log(tag, msg)
    local t = os.date("%H:%M:%S") or "??:??:??"
    print(string.format("[%s] [%s] [%s] %s", t, LOG_PREFIX, tostring(tag), tostring(msg)))
end

----------------------------------------
-- HELPERS
----------------------------------------

local function ClassNameOf(object)
    local ok, name = pcall(function() return object.ClassName end)
    if ok and type(name) == "string" then return name end
    return nil
end

--
--- ∑ Stable identity of a Cheat Engine object. Userdata wrappers are created
--- per access, so the object address is the only key that survives a reload.
--- @return number|nil
--
local function PointerKey(object)
    if type(userDataToInteger) ~= "function" then return nil end
    local ok, key = pcall(userDataToInteger, object)
    if ok and type(key) == "number" then return key end
    return nil
end

local function ModifierHeld()
    if type(isKeyPressed) ~= "function" then return false end
    local ok, held = pcall(function()
        return isKeyPressed(KEY_SHIFT) or isKeyPressed(KEY_CONTROL)
    end)
    return ok and held == true
end

--
--- ∑ The click coordinates are the last two numbers of the event arguments.
--- Cheat Engine calls OnMouseDown as (sender, button, x, y); the LCL shape
--- (sender, button, shift, x, y) is accepted as well.
--- @return number|nil, number|nil
--
local function Coordinates(...)
    local n = select("#", ...)
    if n < 2 then return nil, nil end
    local x, y = select(n - 1, ...)
    if type(x) ~= "number" or type(y) ~= "number" then return nil, nil end
    return x, y
end

----------------------------------------
-- STRUCTURE DISSECT: MIDDLE-CLICK GUARD
----------------------------------------

--
--- ∑ Mirrors TfrmStructures2.getColumnAtXPos(x + tvStructureView.ScrolledLeft).
--- The form walks HeaderControl1's sections from index 1 with inclusive bounds.
--- A section's Left is the sum of the widths before it and a hidden section has
--- width 0, exactly as THeaderSection computes them. The form keeps
--- HeaderControl1.Left at -ScrolledLeft, so x - Left is the header coordinate
--- the form itself would test.
--- @param header userdata # The form's HeaderControl1.
--- @param x number # Client X of the click on the tree view.
--- @return boolean # true when a value column lies under the click.
--
local function HasColumnAt(header, x)
    local sections = header.Sections
    local count = sections.Count
    local hx = x - header.Left
    local left = 0
    for i = 0, count - 1 do
        local width = sections[i].Width
        if i >= 1 and hx >= left and hx <= left + width then return true end
        left = left + width
    end
    return false
end

--
--- ∑ Mirrors TCustomTreeView.GetNodeAtY. The Lua side has no getNodeAt, so
--- this walks the displayed nodes in order, descends only into expanded ones,
--- skips hidden ones and stops as soon as the rows are below y. getDisplayRect
--- is in client coordinates, like y.
--- @param treeView userdata # The form's tvStructureView.
--- @param y number # Client Y of the click.
--- @return userdata|nil # The node under y.
--
local function DisplayedNodeAt(treeView, y)
    local items = treeView.Items
    if items == nil or items.Count == 0 then return nil end
    local function visit(node)
        if not node.Visible then return nil, false end
        local rect = node.getDisplayRect()
        if rect.Top > y then return nil, true end
        if y >= rect.Top and y < rect.Bottom then return node, true end
        if node.Expanded then
            for i = 0, node.Count - 1 do
                local hit, stop = visit(node.Items[i])
                if hit or stop then return hit, stop end
            end
        end
        return nil, false
    end
    local node = items[0]
    while node do
        local hit, stop = visit(node)
        if hit or stop then return hit end
        node = node.getNextSibling()
    end
    return nil
end

--
--- ∑ What the form does for a right or middle click with Shift or Ctrl held:
--- add the row to the selection. It is the same call the form makes.
--
local function AddDisplayedNodeToSelection(treeView, y)
    local node = DisplayedNodeAt(treeView, y)
    if node and not node.Selected and not node.MultiSelected then
        node.Selected = true
    end
end

--
--- ∑ Builds the OnMouseDown replacement for one Structure Dissect window.
--- @param treeView userdata # tvStructureView.
--- @param header userdata # HeaderControl1.
--- @param original function # The handler found on the tree view, callable
---        as (sender, button, x, y).
--- @return function
--
local function BuildGuard(treeView, header, original)
    return function(sender, button, ...)
        local x, y = Coordinates(...)
        if x == nil then return original(sender, button, ...) end
        local middle = (button == MB_MIDDLE)

        if (middle or button == MB_RIGHT) and ModifierHeld() then
            -- The handler adds the clicked row to the selection when Shift or
            -- Ctrl is held, but the Lua bridge calls it with an empty Shift set
            -- and it would select only that row. Add the row first; the handler
            -- then sees it selected and leaves the selection alone.
            local ok, err = pcall(AddDisplayedNodeToSelection, treeView, y)
            if not ok then Log("Guard", "Selection emulation failed: " .. tostring(err)) end
        end

        if middle then
            local ok, hasColumn = pcall(HasColumnAt, header, x)
            if not ok then
                Log("Guard", "Column lookup failed, treating the click as unsafe: " .. tostring(hasColumn))
            end
            if not (ok and hasColumn) then
                -- No column under the cursor: this is the click the form
                -- dereferences nil on. The middle-button branch without the
                -- clipboard copy is exactly the right-button branch, so hand
                -- the click over as a right click.
                return original(sender, MB_RIGHT, x, y)
            end
        end

        return original(sender, button, x, y)
    end
end

--
--- ∑ Wraps tvStructureView.OnMouseDown on one window. Runs from the form's
--- create callback, or directly for windows that are already open when this
--- file is executed again. A tree view that already carries the guard is left
--- alone: reading the event property returns the very function that was
--- assigned, so identity settles it.
--- @param form userdata # A TfrmStructures2.
--- @return boolean # true when the guard is in place.
--
local function InstallStructureDissectGuard(form)
    local ok, err = pcall(function()
        local treeView = form.tvStructureView
        local header   = form.HeaderControl1
        if treeView == nil or header == nil then
            error("tvStructureView or HeaderControl1 was not found on the form")
        end
        local current = treeView.OnMouseDown
        if type(current) ~= "function" then
            error("tvStructureView has no OnMouseDown handler to guard")
        end
        local key = PointerKey(treeView)
        if key and State.Wrappers[key] == current then return end
        local guard = BuildGuard(treeView, header, current)
        treeView.OnMouseDown = guard
        if key then State.Wrappers[key] = guard end
    end)
    if not ok then Log("Install", "Structure Dissect guard not installed: " .. tostring(err)) end
    return ok
end

--
--- ∑ Form notification. It fires from Screen.AddForm inside
--- TCustomForm.CreateNew, before the form's resource is streamed, so the tree
--- view does not exist yet. The create callback runs from DoCreate, after
--- streaming and after FormCreate. It is deliberately not unregistered from
--- inside itself: unregisterCreateCallback frees the caller object that is
--- still executing.
--
local function OnFormAdded(form)
    if ClassNameOf(form) ~= STRUCTURE_FORM_CLASS then return end
    local ok, err = pcall(function()
        if type(form.registerCreateCallback) == "function" then
            form.registerCreateCallback(InstallStructureDissectGuard)
        elseif type(form.registerFirstShowCallback) == "function" then
            form.registerFirstShowCallback(InstallStructureDissectGuard)
        else
            error("neither registerCreateCallback nor registerFirstShowCallback is available")
        end
    end)
    if not ok then Log("FormAdd", "Could not schedule the Structure Dissect guard: " .. tostring(err)) end
end

--
--- ∑ Windows that exist when this file is executed again get the guard
--- directly. The wrapper table is rebuilt from the windows that are still
--- open, so closed windows do not pin their closures.
--
local function PatchOpenWindows()
    if type(getFormCount) ~= "function" or type(getForm) ~= "function" then return end
    local live = {}
    local ok, err = pcall(function()
        for i = 0, getFormCount() - 1 do
            local form = getForm(i)
            if ClassNameOf(form) == STRUCTURE_FORM_CLASS and InstallStructureDissectGuard(form) then
                local key = PointerKey(form.tvStructureView)
                if key then live[key] = State.Wrappers[key] end
            end
        end
    end)
    if ok then
        State.Wrappers = live
    else
        Log("Scan", "Scanning the open windows failed: " .. tostring(err))
    end
end

----------------------------------------
-- MAIN
----------------------------------------

local function Main()
    if type(registerFormAddNotification) ~= "function" then
        Log("Main", "registerFormAddNotification is not available, nothing was installed.")
        return
    end
    if State.FormNotification ~= nil and type(unregisterFormAddNotification) == "function" then
        pcall(unregisterFormAddNotification, State.FormNotification)
        State.FormNotification = nil
    end
    State.FormNotification = registerFormAddNotification(OnFormAdded)
    PatchOpenWindows()
    Log("Main", "Structure Dissect middle-click guard armed.")
end

Main()
