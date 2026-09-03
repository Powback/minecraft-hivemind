-- Behavioural tests for the in-world Lua, run under a real Lua with a stub ComputerCraft world.
--
--   lua5.4 hq/test/lua/run.lua            (hq/test/lua-behaviour.test.ts drives it)
--
-- Each module is loaded into its own environment (cc_stubs.makeEnv) so its globals do not collide
-- with another module's. Locals worth testing are exported by the module itself through the
-- HiveMindTest hook it fills in when that global exists -- production code never sees it set.
-- Output is one JSON line per test: {"name":..., "ok":..., "msg":...}.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/../../.."
package.path = here .. "/?.lua;" .. package.path
local stubs = require("cc_stubs")

local results = {}
local function report(name, ok, msg)
    results[#results + 1] = { name = name, ok = ok, msg = msg }
    io.write(stubs.toJSON({ name = name, ok = ok, msg = msg }), "\n")
end

local function test(name, fn)
    local ok, err = pcall(fn)
    report(name, ok and true or false, ok and "" or tostring(err))
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(what or "value", tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, what) if not v then error((what or "value") .. " should be truthy, got " .. tostring(v), 2) end end
local function falsy(v, what) if v then error((what or "value") .. " should be falsy, got " .. tostring(v), 2) end end
local function contains(s, sub, what)
    if type(s) ~= "string" or not s:find(sub, 1, true) then
        error(("%s: expected to contain %q, got %s"):format(what or "string", sub, tostring(s)), 2)
    end
end

-- Load a module in a fresh environment and return the env (its globals) plus its test hook.
local function loadModule(path, opts)
    local env = stubs.makeEnv(opts)
    local chunk, err = loadfile(root .. "/lua/" .. path, "t", env)
    if not chunk then error("cannot load " .. path .. ": " .. tostring(err)) end
    local ok, runErr = pcall(chunk)
    if not ok then error(path .. " failed while loading: " .. tostring(runErr)) end
    return env, env.HiveMindTest[path:gsub("%.lua$", "")] or {}
end

-- ================================================================================================
-- TaskMan
-- ================================================================================================
local function taskManWithFleet(drones, storageDetail)
    local env, T = loadModule("TaskMan.lua")
    env.__world.replies.DroneMan = { GetDrones = { drones = drones } }
    env.__world.replies.StorageMan = { GetStock = { detail = storageDetail or {} } }
    return env, T
end

test("TaskMan loads under the stub world", function()
    local env, T = loadModule("TaskMan.lua")
    truthy(env.OnStartTask, "OnStartTask defined")
    truthy(T.jobMinFuel, "test hook exports jobMinFuel")
end)

test("TaskMan.jobMinFuel prices the work plus a margin, per verb", function()
    local _, T = loadModule("TaskMan.lua")
    eq(T.workCost({ work = { lumber = { w = 8, l = 8 } } }), 8 * 8 * 2 + 60, "lumber 8x8 work")
    eq(T.jobMinFuel({ work = { lumber = { w = 8, l = 8 } } }), 8 * 8 * 2 + 60 + 100, "lumber 8x8 minimum")
    eq(T.jobMinFuel({ work = { haul = { pos = { x = 0, y = 64, z = 0 } } } }), 40 + 100, "haul minimum")
    eq(T.jobMinFuel({ work = { plant = { spots = { {}, {}, {}, {} } } } }), 4 * 8 + 40 + 100, "plant of 4 minimum")
    eq(T.jobMinFuel({ work = { rescue = { fuel = true } } }), 300, "a fuel relief keeps the relief floor")
end)

test("TaskMan.workPos knows where every kind of work happens", function()
    local _, T = loadModule("TaskMan.lua")
    eq(T.workPos({ work = { lumber = { start = { x = 1, y = 2, z = 3 } } } }).x, 1, "lumber start")
    eq(T.workPos({ work = { haul = { pos = { x = 4, y = 5, z = 6 } } } }).z, 6, "haul pos")
    eq(T.workPos({ work = { plant = { pos = { x = 7, y = 8, z = 9 } } } }).y, 8, "plant pos")
    eq(T.workPos({ work = { build = { origin = { x = 1, y = 1, z = 1 } } } }).x, 1, "build origin")
    local mid = T.workPos({ work = { dig = { min = { x = 0, y = 0, z = 0 }, max = { x = 10, y = 4, z = 6 } } } })
    eq(mid.x, 5, "dig midpoint x") eq(mid.z, 3, "dig midpoint z")
    eq(T.workPos({ work = { craft = {} } }), nil, "a craft has no site")
end)

test("TaskMan.RoleForWork: planting and hauling need no upgrade", function()
    local env = loadModule("TaskMan.lua")
    eq(env.RoleForWork({ plant = {} }), "any", "plant")
    eq(env.RoleForWork({ haul = {} }), "any", "haul")
    eq(env.RoleForWork({ craft = {} }), "crafter", "craft")
    eq(env.RoleForWork({ lumber = {} }), "miner", "lumber")
end)

test("TaskMan.pickDrone refuses a drone that cannot afford the round trip, and says so", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 400, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone, busy, poor, need = T.pickDrone("miner", { x = 50, y = 64, z = 0 }, nil, 288)
    eq(drone, nil, "no drone picked")
    eq(busy, nil, "nobody is busy")
    truthy(poor, "the idle-but-poor drone is reported")
    eq(need, 288 + 6 * 50, "the need charges the round trip per block")
    local why = T.noDroneReason("miner", busy, poor, need)
    contains(why, "can afford it", "reason")
    contains(why, "588", "reason names the number")
end)

test("TaskMan.pickDrone offers the job to a drone that can afford it", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1000, pos = { x = 0, y = 64, z = 0 } },
        { id = 2, name = "D2", role = "miner", status = "working", fuel = 1000, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone = T.pickDrone("miner", { x = 50, y = 64, z = 0 }, nil, 288)
    truthy(drone, "a drone is picked")
    eq(drone.name, "D1", "the idle one")
end)

test("TaskMan: while the fleet is low, a haul and a plant are still placeable", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 300, pos = { x = 0, y = 64, z = 0 } },
    }, {})
    falsy(T.notPlaceableNow({ id = 1, name = "haul:0,64,0", work = { haul = { pos = {} } } }, "any", {}), "haul")
    falsy(T.notPlaceableNow({ id = 2, name = "plant:grove-01", work = { plant = { spots = {} } } }, "any", {}), "plant")
    falsy(T.notPlaceableNow({ id = 3, name = "lumber:oak_log", work = { lumber = {} } }, "miner", {}), "lumber is fuel work")
end)

-- ================================================================================================
-- StorageMan
-- ================================================================================================
local function storageWithChests()
    local env, S = loadModule("StorageMan.lua")
    local w = env.__world
    -- Two networked chests and a furnace on the wire; one cache chest off it.
    w.addInventory("minecraft:chest_0", "minecraft:chest", { [1] = { name = "minecraft:coal", count = 7 } }, 27)
    w.addInventory("minecraft:chest_1", "minecraft:chest", { [1] = { name = "minecraft:oak_log", count = 5 } }, 27)
    w.addInventory("minecraft:furnace_0", "minecraft:furnace", {}, 3)
    env.DATA.deposits = {
        { pos = { x = -476, y = 64, z = 78 }, peripheral = "minecraft:chest_0" },
        { pos = { x = -476, y = 64, z = 78 } },                                    -- the unbound twin
        { pos = { x = -475, y = 64, z = 78 }, peripheral = "minecraft:chest_1" },
        { pos = { x = -520, y = 63, z = 34 } },                                    -- a field cache
    }
    env.DATA.chestAt = {
        ["-520:63:34"] = { pos = { x = -520, y = 63, z = 34 }, items = {}, used = 0, size = 27 },
    }
    return env, S
end

test("StorageMan loads under the stub world and indexes the wire", function()
    local env = storageWithChests()
    truthy(env.Rescan(), "Rescan succeeds")
    eq(env.m_Index["minecraft:coal"].total, 7, "coal indexed")
    eq(env.m_Free["minecraft:chest_0"], 26, "free slots counted")
end)

test("StorageMan.dedupeDeposits drops a bound chest's unbound twin", function()
    local env, S = storageWithChests()
    S.dedupeDeposits()
    eq(#env.DATA.deposits, 3, "one twin dropped, networked and cache entries kept")
    for _, d in ipairs(env.DATA.deposits) do
        if d.pos.x == -476 then truthy(d.peripheral, "the surviving -476 entry is the bound one") end
    end
end)

test("StorageMan.OnDepositPoint: no site -> a networked chest, never the emptier cache", function()
    local env = storageWithChests()
    local ok, r = env.OnDepositPoint(1, { data = {} })
    truthy(ok, "answered")
    truthy(r.peripheral, "a networked chest: " .. stubs.toJSON(r))
end)

test("StorageMan.OnDepositPoint: a site near the cache does not change that", function()
    local env = storageWithChests()
    local ok, r = env.OnDepositPoint(1, { data = { near = { x = -518, y = 64, z = 34 } } })
    truthy(ok, "answered")
    truthy(r.peripheral, "still a networked chest: " .. stubs.toJSON(r))
end)

test("StorageMan.OnWhereIs answers from the wire before any memory", function()
    local env = storageWithChests()
    env.DATA.chestAt["-520:63:34"].items = { ["minecraft:coal"] = 64 }   -- a stale memory of coal far away
    local ok, r = env.OnWhereIs(1, { data = { match = "coal" } })
    truthy(ok, "found")
    eq(r.source, "peripheral", "source")
    eq(r.pos.x, -476, "the networked chest holding the coal")
end)

test("StorageMan: fuel before furniture -- wood smelts while fuel is short", function()
    local env, S = storageWithChests()
    env.Rescan()
    -- 7 coal on the shelf is under SMELT_FUEL_RESERVE (32): the crafting reserve yields.
    eq(S.smeltAllowance("minecraft:oak_log", env.m_Index["minecraft:oak_log"]), 5, "all five logs allowed")
    falsy(S.reservedForCrafting("minecraft:oak_log", env.m_Index["minecraft:oak_log"]), "not reserved")
    -- With plenty of fuel the sixteen-log crafting reserve is back.
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items[1].count = 64
    env.Rescan()
    eq(S.smeltAllowance("minecraft:oak_log", env.m_Index["minecraft:oak_log"]), 0, "5 - 16 reserve -> nothing to smelt")
end)

test("StorageMan.fillFor: the fuel face takes wood when there is no dense fuel", function()
    local env, S = storageWithChests()
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items[1] = nil     -- no coal anywhere
    env.Rescan()
    local e, batch = S.fillFor(false)
    truthy(e, "something to burn")
    eq(e.at[1].where, "minecraft:chest_1", "the logs")
    eq(batch, 2, "two logs, not a stack")
end)

test("StorageMan.fillFor: dense fuel first when it exists", function()
    local env, S = storageWithChests()
    env.Rescan()
    local e, batch = S.fillFor(false)
    eq(e.at[1].where, "minecraft:chest_0", "the coal")
    eq(batch, 16, "a normal batch")
end)

-- ================================================================================================
-- DroneLogic
-- ================================================================================================
test("DroneLogic loads under the stub world", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    truthy(env.TravelTo, "TravelTo defined")
    truthy(env.FuelFloorNow, "FuelFloorNow defined")
    truthy(D.setHome, "test hook exports setHome")
end)

test("DroneLogic: wood families -- logs and planks burn, saplings never", function()
    local env = loadModule("DroneLogic.lua")
    eq(env.WoodFamily("minecraft:birch_sapling"), "sapling", "sapling family")
    truthy(env.IsBurnableWood("minecraft:oak_log"), "log burns")
    truthy(env.IsBurnableWood("minecraft:spruce_planks"), "planks burn")
    falsy(env.IsBurnableWood("minecraft:oak_sapling"), "sapling does not")
    falsy(env.IsBurnableWood("minecraft:coal"), "coal is not wood")
    truthy(env.SameItem("minecraft:oak_sapling", "minecraft:birch_sapling"), "any sapling matches a sapling")
end)

test("DroneLogic.FuelFloorNow is the trip home plus a margin and nothing else", function()
    local env, D = loadModule("DroneLogic.lua", { pos = { x = 30, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })
    eq(env.FuelFloorNow(), 30 * 3 + 120, "30 blocks out")
    env.__world.pos = { x = 0, y = 64, z = 0 }
    eq(env.FuelFloorNow(), 120, "at home")
end)

test("DroneLogic.BurnAboard burns dense fuel up to the target and keeps the rest", function()
    local env = loadModule("DroneLogic.lua", { fuel = 500 })
    env.__world.turtle.inv[1] = { name = "minecraft:coal", count = 20 }
    local gained = env.BurnAboard()
    eq(gained, 14 * 80, "fourteen coal to pass 1,600")
    eq(env.turtle.getFuelLevel(), 500 + 14 * 80, "tank")
    eq(env.turtle.getItemCount(1), 6, "six coal kept for storage")
end)

test("DroneLogic.BurnAboard does not eat wood unless the drone would strand", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })                    -- floor 150: 500 is comfortably above it
    env.__world.turtle.inv[1] = { name = "minecraft:oak_log", count = 20 }
    eq(env.BurnAboard(), 0, "logs kept for the furnace")
    env.__world.turtle.fuel = 100                          -- below the floor: survival
    truthy(env.BurnAboard() > 0, "now it burns")
end)

test("DroneLogic.BurnAboard leaves a relief payload alone above the floor", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 800, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })
    env.__world.turtle.inv[1] = { name = "minecraft:coal", count = 28 }
    D.setRelieving(true)
    eq(env.BurnAboard(), 0, "the payload is not lunch")
    env.__world.turtle.fuel = 50
    truthy(env.BurnAboard() > 0, "but it will not strand itself over it")
end)

test("DroneLogic.TravelTo: one coroutine owns the turtle; the other is told busy", function()
    local env = loadModule("DroneLogic.lua")
    falsy(env.TravelIsBusy(), "nobody travelling")
    -- A coroutine that starts a journey and parks mid-way.
    local owner = coroutine.create(function()
        env.TravelOwner = coroutine.running()
        coroutine.yield()
    end)
    coroutine.resume(owner)
    truthy(env.TravelIsBusy(), "busy from the outside")
    local ok, why = env.TravelTo(1, 64, 1)
    eq(ok, false, "refused")
    eq(why, "travel busy", "reason")
    coroutine.resume(owner)                                -- finish it
    env.TravelOwner = nil
    falsy(env.TravelIsBusy(), "free again")
end)

-- ================================================================================================
local failed = 0
for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end
io.stderr:write(("%d test(s), %d failed\n"):format(#results, failed))
os.exit(failed == 0 and 0 or 1)
