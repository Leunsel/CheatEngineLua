# Manifold CE Utility

`Manifold-CE-Utility.lua` is an extension for Cheat Engine that provides quality-of-life helpers, wrapper functions, and utility routines for the Cheat Engine Lua API.  
Once installed, the file is loaded automatically every time Cheat Engine starts.

![Preview](https://i.imgur.com/34oPdGt.png)

## Installation

1. Download **`Manifold-CE-Utility.lua`**.
2. Place the file in the following folder:
`C:\Program Files\Cheat Engine 7.5\autorun`

If you are using a portable CE build or installed Cheat Engine in a different directory, the `autorun` folder may be located elsewhere.

### Find your correct autorun folder

If you don't know where your `autorun` directory is located, you can reveal it directly inside the Cheat Engine Lua Console:

`return getAutorunPath()`

The console will print the full path to your `autorun` directory.  
Place the script in that folder, Cheat Engine will automatically load it the next time it starts.