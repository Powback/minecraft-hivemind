-- luacheck for the in-world Lua. Run: luacheck lua  (hq/test/luacheck.test.ts gates it)
--
-- The one warning that matters most here is W113, "accessing undefined variable": a `local`
-- declared BELOW the function that reads it is a nil global at that point, silently, and CLAUDE.md
-- counts nine outages from exactly that shape. luacheck sees it statically; nothing else did.
std = "lua52"

-- Modules define their API as top-level globals (`function TryRefuel()`), deliberately.
allow_defined_top = true

-- What the ComputerCraft runtime provides, and what the modules share with each other by name.
read_globals = {
    -- CC: Tweaked
    "turtle", "peripheral", "rednet", "gps", "fs", "term", "colors", "colours", "textutils",
    "parallel", "shell", "redstone", "rs", "http", "keys", "sleep", "read", "printError", "write",
    "settings", "multishell", "commands", "disk", "paintutils", "vector", "window", "os",
    -- loaded with os.loadAPI or by the bootloader, so they are globals in every module
    "PowNet", "pgps", "PowGPSServer", "MapRender", "VFS", "lama", "egps", "Log", "SetStatus",
}

-- The test seam: hq/test/lua/run.lua sets it and each module fills in its own table; nil in the
-- world. Writable, because the modules assign a field of it.
globals = { "HiveMindTest" }

-- Noise we are not spending the ratchet on yet: unused variables and arguments, whitespace,
-- line length. Everything else -- undefined reads, unreachable code, a numeric-for control
-- variable assigned (a real CC trap), empty branches -- is on.
ignore = { "21[123]", "6.." }

-- Legacy programs that are not deployed to anything.
exclude_files = { "lua/turtleLogic.lua", "lua/DroneTankingBoot.lua", "lua/Template.lua", "lua/ModuleTemplate.lua" }

files["lua/DroneLogic.lua"] = {
    -- Module state that lives in globals ON PURPOSE: the main chunk is at Lua's 200-local limit,
    -- so these could not be `local` without evicting something else. Named here so luacheck can
    -- tell a deliberate global from a typo -- which is the whole point of running it.
    globals = { "TravelOwner", "executing", "m_LastCrash", "m_HostPos", "m_Hosting" },
}

files["lua/TaskMan.lua"] = {
    -- os.loadAPI("ServerTasks/dig.lua") binds `dig` at boot.
    read_globals = { "dig" },
    globals = { "ANY_ROLE", "UNAFFORDABLE" },
}
