# Cheat Engine Lua Modules

This repository is a collection of Lua modules for Cheat Engine that make building and
maintaining Cheat Tables faster. They cover automating repetitive work, managing memory records,
talking to the game process and building interfaces.

Whether you are handling memory records, automating the auto assembly process or managing UI
components, these modules give you the pieces to build more dynamic Cheat Tables.

![Preview](https://i.imgur.com/U0kjEIV.png)

## What is in here

[Manifold Table Modules](https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-Modules)
is the framework that runs inside a Cheat Table.

[Manifold Template Loader](https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-TemplateLoader)
is an autorun script that generates Auto Assembler scripts from templates.

[Manifold CE Utility](https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-CE-Utility)
is an autorun script that adds a quality of life menu to Cheat Engine itself.

[Manifold Table Files](https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-TableFiles)
is an autorun script that puts every file attached to a Cheat Table into one editable window.

[Manifold Logger](https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-Logger)
is an autorun script that gives every script one place to log to, and a canvas-drawn console with
levels, icons, filters and search to read it in.

The documentation for all of them lives in [`docs/`](docs/README.md).

## Credits

Thanks to the following people and resources.

[LeFiXER](https://ko-fi.com/lefixer_), for invaluable guidance and extensive support throughout the development of this
project. He's also the creator of the current icon pack which is included in this repository!

Jeffrey Friedl, for sharing his [`json.lua`](http://regex.info/blog/lua/json), which made my life
a lot easier.

TheyCallMeTim13, for the inspiration of his meticulously crafted Cheat Tables and for creating
the `Module.Helper.lua` module.

## Contributing

Contributions are welcome. If you have ideas for improvements, new features or themes, open an
issue or submit a pull request.
