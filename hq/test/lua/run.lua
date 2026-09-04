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

test("TaskMan.pickDrone treats a docked drone as free", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D4", role = "miner", status = "docking", fuel = 1200, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone, busy = T.pickDrone("miner", { x = 10, y = 64, z = 0 }, nil, 100)
    truthy(drone, "picked") eq(drone and drone.name, "D4", "the docked drone") eq(busy, nil, "not busy")
end)

test("TaskMan.pickDrone prices work with no site as no trip, so a crafter can afford a craft", function()
    local _, T = taskManWithFleet({
        { id = 2, name = "D4", role = "crafter", status = "docking", fuel = 1200, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone, _, poor, need = T.pickDrone("crafter", nil, nil, 100)
    truthy(drone, "picked: " .. tostring(need)) eq(drone and drone.name, "D4", "the crafter")
    eq(poor, nil, "not reported as poor")
end)

test("TaskMan.anyoneForBuild prices the build for the fallback drone too", function()
    local _, T = taskManWithFleet({
        { id = 3, name = "D39", role = "scout", status = "idle", fuel = 290, fuelFloor = 120, pos = { x = 0, y = 64, z = 0 } },
    })
    local build = { id = 9, name = "tower-L0-p1", work = { build = { origin = { x = 14, y = 64, z = 0 } } } }
    eq(T.anyoneForBuild(build, { x = 14, y = 64, z = 0 }, 300), nil, "a 384-fuel build is not handed to a 290-fuel scout")
    local _, T2 = taskManWithFleet({
        { id = 3, name = "D39", role = "scout", status = "idle", fuel = 1200, fuelFloor = 120, pos = { x = 0, y = 64, z = 0 } },
    })
    local d = T2.anyoneForBuild(build, { x = 14, y = 64, z = 0 }, 300)
    eq(d and d.name, "D39", "a scout that can afford it builds")
end)

test("TaskMan.heldForNothing: a busy drone that has not moved for three minutes is stalled", function()
    local env, T = taskManWithFleet({})
    local d = { id = 58, name = "D40", role = "miner", status = "busy", fuel = 1700, pos = { x = -480, y = 64, z = 65 } }
    eq(T.heldForNothing(d), nil, "first sighting: not stalled")
    env.__world.clock = env.__world.clock + 200                 -- os.epoch follows the stub clock (ms = s * 1000)
    truthy(T.heldForNothing(d), "still there 200 s later: stalled")
    d.pos = { x = -470, y = 64, z = 65 }
    eq(T.heldForNothing(d), nil, "it moved: not stalled")
end)

test("TaskMan: a haul goes to a free scout before a free miner", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1500, pos = { x = -468, y = 64, z = 43 } },
        { id = 2, name = "D9", role = "scout", status = "idle", fuel = 1500, pos = { x = -475, y = 64, z = 50 } },
    })
    env.DATA.tasks = { [7] = { id = 7, name = "haul:-469,64,41", work = { haul = { pos = { x = -469, y = 64, z = 41 } } }, progress = 0, priority = 1 } }
    local ok, r = env.OnStartTask(0, { data = { id = 7 } })
    truthy(ok, "placed: " .. tostring(r and (r.message or r) or "?"))
    eq(env.DATA.tasks[7].assignedTo, 2, "the scout took it, though the miner was nearer")
end)

test("TaskMan: a haul from an underground cache goes to a miner, never a scout", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1500, pos = { x = -480, y = 64, z = 80 } },
        { id = 2, name = "D9", role = "scout", status = "idle", fuel = 1500, pos = { x = -480, y = 64, z = 84 } },
    })
    env.DATA.tasks = { [8] = { id = 8, name = "haul:-480,8,87", work = { haul = { pos = { x = -480, y = 8, z = 87 } } }, progress = 0, priority = 1 } }
    local ok = env.OnStartTask(0, { data = { id = 8 } })
    truthy(ok, "placed")
    eq(env.DATA.tasks[8].assignedTo, 1, "the miner, though the scout was nearer: a scout cannot dig its way out")
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

test("TaskMan: while the fleet is low, a crafter's job is placeable and a miner's non-fuel job is held", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 300, pos = { x = 0, y = 64, z = 0 } },
        { id = 2, name = "D4", role = "crafter", status = "docking", fuel = 1200, pos = { x = 0, y = 64, z = 0 } },
    }, {})
    falsy(T.notPlaceableNow({ id = 4, name = "craft-stone_bricks", work = { craft = {} } }, "crafter", {}), "a craft costs no fuel anyone else could use")
    truthy(T.notPlaceableNow({ id = 5, name = "dig:stone", work = { mine = { pos = {} } } }, "miner", {}), "a miner's dig waits for fuel work")
    falsy(T.notPlaceableNow({ id = 6, name = "tower-L0-3", work = { build = { origin = {} } } }, "miner", {}), "a build of stocked bricks is placeable; anyoneForBuild hands it on")
end)

test("TaskMan: outside an emergency, a third fuel job waits while two miners already fell or mine", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "working", fuel = 1500, pos = { x = 0, y = 64, z = 0 } },
        { id = 2, name = "D2", role = "miner", status = "working", fuel = 1500, pos = { x = 0, y = 64, z = 0 } },
        { id = 3, name = "D3", role = "miner", status = "idle", fuel = 1500, pos = { x = 0, y = 64, z = 0 } },
    }, { { name = "minecraft:coal", count = 500 } })
    env.DATA.tasks = {
        [1] = { id = 1, name = "lumber:oak_log", work = { lumber = {} }, assignedTo = 1, progress = 0 },
        [2] = { id = 2, name = "gather:coal_ore", work = { gather = {} }, assignedTo = 2, progress = 0 },
    }
    truthy(T.notPlaceableNow({ id = 3, name = "lumber:oak_log", work = { lumber = {} } }, "miner", {}), "third fuel job waits")
    falsy(T.notPlaceableNow({ id = 4, name = "tower-L2-p1", work = { build = { origin = {} } } }, "miner", {}), "the build goes")
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

test("StorageMan.OnDepositPoint spreads seven askers over the roomy chests instead of one", function()
    local env = storageWithChests()
    local picks = {}
    for id = 40, 46 do
        local ok, r = env.OnDepositPoint(id, { data = {} })
        truthy(ok, "asker " .. id .. " got a point")
        local k = r.peripheral or tostring(r.pos.x)
        picks[k] = (picks[k] or 0) + 1
    end
    local distinct = 0
    for _ in pairs(picks) do distinct = distinct + 1 end
    truthy(distinct >= 2, "two networked chests with room, seven askers: both get used (" .. distinct .. ")")
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

test("DroneLogic.FellTrunkAt fells the whole column from the side and climbs it", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000, pos = { x = 0, y = 64, z = 0 } })
    D.setExecuting(true)                                  -- felling happens inside a job
    local t = env.__world.turtle
    -- A trunk: one log in front that disappears when dug, then a column of three above the base.
    -- Height matters: the block overhead is the one at y+1 for the drone's CURRENT y, so digging up
    -- once removes one log and the next is only reachable after moving up -- as in the world.
    local front, y = true, 64
    local column = { [65] = true, [66] = true, [67] = true }
    t.detect = function() return front end
    t.inspect = function() if front then return true, { name = "minecraft:oak_log" } end return false end
    t.dig = function() front = false return true end
    t.detectUp = function() return column[y + 1] == true end
    t.inspectUp = function() if column[y + 1] then return true, { name = "minecraft:oak_log" } end return false end
    t.digUp = function() column[y + 1] = nil return true end
    env.pgps.up = function() y = y + 1 return true end
    env.pgps.down = function() y = y - 1 return true end
    local logs, why = env.FellTrunkAt({ x = 5, y = 64, z = 5 })
    eq(why, nil, "no failure reason")
    eq(logs, 4, "the base log plus three overhead")
end)

test("DroneLogic.FellTrunkAt reports a trunk that is gone and observes the air", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    D.setExecuting(true)                                  -- felling happens inside a job
    local observed = {}
    env.pgps.noteObservation = function(idx, solid) observed[#observed + 1] = idx .. "=" .. tostring(solid) end
    local logs, why = env.FellTrunkAt({ x = 5, y = 64, z = 5 })
    eq(logs, 0, "nothing felled")
    eq(why, "gone", "reason")
    eq(#observed, 3, "the foot and the two cells above it were recorded as air")
    eq(observed[1], "5:64:5=0", "first observation")
end)

test("DroneLogic.PlantSaplingAt plants on soil from one above, and not on stone", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local t = env.__world.turtle
    t.inv[1] = { name = "minecraft:oak_sapling", count = 4 }
    t.inspectDown = function() return true, { name = "minecraft:grass_block" } end
    local placed = 0
    t.placeDown = function() placed = placed + 1 t.inv[1].count = t.inv[1].count - 1 return true end
    truthy(env.PlantSaplingAt({ x = 3, y = 64, z = 3 }), "planted on grass")
    eq(placed, 1, "one sapling placed")
    t.inspectDown = function() return true, { name = "minecraft:stone" } end
    falsy(env.PlantSaplingAt({ x = 4, y = 64, z = 3 }), "not on stone")
    eq(placed, 1, "nothing more placed")
end)

-- ================================================================================================
-- pgps
-- ================================================================================================
test("pgps loads under the stub world", function()
    local env = loadModule("pgps.lua")
    truthy(env.setLocation, "setLocation defined")
    truthy(env.moveTo, "moveTo defined")
end)

test("pgps.setLocation with no heading keeps the heading it has", function()
    local env = loadModule("pgps.lua")
    env.setLocation(1, 2, 3, "north")
    local x, y, z, d = env.getCachedPosition()
    eq(x, 1, "x") eq(d, env.HEADINGS.north, "heading set")
    local rx, ry, rz, rd = env.setLocation(10, 20, 30, nil)
    eq(rx, 10, "position moved") eq(rd, env.HEADINGS.north, "heading kept")
    local _, _, _, d2 = env.getCachedPosition()
    eq(d2, env.HEADINGS.north, "still north")
end)

test("pgps.verifyPosition adopts a one-block disagreement at once -- there is no GPS noise to filter", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 1, y = 64, z = 0 }
    local ok, drift = env.verifyPosition(true)
    truthy(ok, "fix") eq(drift, 1, "drift")
    eq((env.getCachedPosition()), 1, "adopted on the first fix")
end)

test("pgps.verifyPosition discards a fix taken while something else moved the turtle", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    -- The hosts answer while another coroutine steps us one block south: the race D54 lived in.
    local realLocate = env.gps.locate
    env.gps.locate = function(...) env.noteExternalStep(0, 0, 1) return realLocate(...) end
    local ok, why = env.verifyPosition(true)
    eq(ok, nil, "not a fix") eq(why, "moved during the fix", "and it says so")
    local x, y, z = env.getCachedPosition()
    eq(z, 1, "the step that really happened is kept; the stale fix is not adopted")
    truthy(not env.positionVerified(), "a discarded fix does not count as a fix")
    env.gps.locate = realLocate
    env.__world.gps = { x = 0, y = 64, z = 1 }
    truthy(env.verifyPosition(true), "the next undisturbed fix is accepted")
    truthy(env.positionVerified(), "and counts")
end)

test("pgps.verifyPosition refuses a fix while a move is in flight, whoever asks", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    local inner
    -- turtle.forward() puts the turtle in the next block and only then yields for eight ticks; the
    -- refix loop's fix lands in that window. Here the stub is the window.
    env.turtle.forward = function()
        env.__world.gps = { x = 0, y = 64, z = -1 }
        inner = { env.verifyPosition(true) }
        return true
    end
    truthy(env.forward(), "tracked step")
    eq(inner[1], nil, "the mid-move fix is refused") eq(inner[2], "moving", "and says why")
    local _, _, z = env.getCachedPosition()
    eq(z, -1, "the step is committed once, by the mover")
    local ok, drift = env.verifyPosition(true)
    truthy(ok, "a fix between moves is accepted") eq(drift, 0, "and agrees with the bookkeeping")
end)

test("pgps: a step commits its own delta, so another routine's step in flight is not lost", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    -- While our forward step is in flight, another coroutine commits a step east.
    env.turtle.forward = function() env.noteExternalStep(1, 0, 0) return true end
    truthy(env.forward(), "our step")
    local x, _, z = env.getCachedPosition()
    eq(x, 1, "the other routine's step is kept") eq(z, -1, "and so is ours")
end)

test("pgps: the travel audit does not rotate the heading after a run that turned", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    truthy(env.verifyPosition(true), "anchor the audit")
    env.turtle.forward = function() return true end
    truthy(env.forward(), "one north")                        -- intent (0,0,-1)
    truthy(env.turnRight(), "turn")                           -- now east
    truthy(env.forward(), "one east")                         -- intent (1,0,-1)
    env.__world.gps = { x = 1, y = 64, z = 0 }                -- GPS says the north step never happened
    env.verifyPosition(true)
    local _, _, _, d = env.getCachedPosition()
    eq(d, env.HEADINGS.east, "the heading is kept: a turned run cannot be inverted")
end)

test("pgps.ensureHeading reads the heading from a clean probe step and refuses one disturbed by another mover", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 1, y = 64, z = 0 }                 -- the step out lands one block east
    truthy(env.ensureHeading(true), "clean probe")
    local _, _, _, d = env.getCachedPosition()
    eq(d, env.HEADINGS.east, "heading read from the step")
    local realLocate = env.gps.locate
    env.gps.locate = function(...) env.noteExternalStep(0, 1, 0) return realLocate(...) end
    local ok, why = env.ensureHeading(true)
    eq(ok, false, "disturbed probe refused") eq(why, "moved during the probe", "and it says why")
    local _, _, _, d2 = env.getCachedPosition()
    eq(d2, env.HEADINGS.east, "the heading we had is kept")
end)

test("TaskMan.noDroneReason survives a fractional fuel need", function()
    local env, T = loadModule("TaskMan.lua")
    local why = T.noDroneReason("miner", nil, { name = "D31", fuel = 190 }, 255.5)
    truthy(why:find("~255"), "the need is reported whole: " .. why)
    truthy(why:find(env.UNAFFORDABLE, 1, true), "and named as unaffordable")
    local far = T.noDroneReason("miner", nil, { name = "D31", fuel = 190 }, math.huge)
    truthy(far:find("unknown", 1, true), "an infinite need (no position) is said in words: " .. far)
    local nan = T.noDroneReason("miner", nil, { name = "D31", fuel = 190 }, 0/0)
    truthy(nan:find("unknown", 1, true), "so is a NaN: " .. nan)
end)

test("DroneLogic.RefuelAtStorage asks storage over the network and does not fly to an empty shelf", function()
    local env = loadModule("DroneLogic.lua", { fuel = 300 })
    env.__world.replies.StorageMan = env.__world.replies.StorageMan or {}
    env.__world.replies.StorageMan.GetStock = { detail = { { name = "minecraft:stone", count = 800 } } }
    env.__world.replies.StorageMan.DepositPoint = { pos = { x = 0, y = 64, z = 0 } }
    local moves = 0
    local counted = function() moves = moves + 1 return true end
    env.pgps.moveTo, env.pgps.flyTo, env.pgps.digTo, env.pgps.forward = counted, counted, counted, counted
    env.RefuelAtStorage()
    eq(moves, 0, "no flight to a shelf the network says is dry")
    truthy(env.StorageKnownDry(nil), "and the shelf is marked dry for the others")
end)

test("DroneLogic.CollectFuel: a shelf at or below its reserve gives a working tank, not a full one, and nothing to a full drone", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000, pos = { x = 0, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })
    env.__world.replies.StorageMan = env.__world.replies.StorageMan or {}
    env.__world.replies.StorageMan.GetStock = { detail = { { name = "minecraft:coal", count = 100 } } }
    local got, why = D.collectFuel()
    eq(got, 0, "a drone at 1000 takes nothing") truthy(why:find("reserve", 1, true), "and is told why: " .. why)
    eq(env.ShelfAllowance(100), 0, "allowance 0 at 1000 fuel")
    env.__world.turtle.fuel = 300                            -- above its floor, below a working tank
    eq(env.ShelfAllowance(100), 4, "300 -> 600 is four coal")
    env.__world.turtle.fuel = 50                             -- below the floor: unlimited
    eq(env.ShelfAllowance(100), nil, "survival is not rationed")
    env.__world.turtle.fuel = 1000
    D.setRelieving(true)
    eq(env.ShelfAllowance(100), nil, "a reliever is not rationed")
    D.setRelieving(false)
    eq(env.ShelfAllowance(500), nil, "above the reserve nobody is rationed")
end)

test("DroneLogic: an executing flag with no job and no movement is cleared by the heartbeat", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500 })
    D.setExecuting(true)                                       -- a GoTo that never reached TaskEnd
    env.SendHeartBeat()
    truthy(D.isExecuting(), "first sighting: kept")
    env.__world.clock = env.__world.clock + 400
    env.SendHeartBeat()
    truthy(not D.isExecuting(), "still there 400 s later with no job: cleared")
end)

test("DroneLogic.FetchSkip: fetches search networked chests, never caches", function()
    local env = loadModule("DroneLogic.lua")
    local wantsCoal = function(nm) return nm == "minecraft:coal" end
    truthy(env.FetchSkip({ pos = { x = -480, y = 8, z = 87 } }, wantsCoal), "a cache (no peripheral) is skipped even with unknown contents")
    truthy(env.FetchSkip({ pos = {}, peripheral = "minecraft:chest_0", items = { ["minecraft:stone"] = 64 } }, wantsCoal), "a chest known to hold none is skipped")
    falsy(env.FetchSkip({ pos = {}, peripheral = "minecraft:chest_1" }, wantsCoal), "a networked chest of unknown contents is searched")
    falsy(env.FetchSkip({ pos = {}, peripheral = "minecraft:chest_2", items = { ["minecraft:coal"] = 3 } }, wantsCoal), "a chest known to hold it is searched")
end)

test("DroneLogic.FuelAllowsAnotherTarget: a gather leaves when the tank is the trip home plus one approach", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })                    -- floor 150 here
    truthy(env.FuelAllowsAnotherTarget(), "500 > 150 + 60")
    env.__world.turtle.fuel = 200
    falsy(env.FuelAllowsAnotherTarget(), "200 is not 150 + 60")
end)

test("DroneLogic.FellTargets stops at an abort and when the tank is the trip home", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })                    -- floor 150 here
    local calls = 0
    env.FellTrunkAt = function() calls = calls + 1 return 1 end
    local targets = { { x = 1, y = 64, z = 1 }, { x = 2, y = 64, z = 2 }, { x = 3, y = 64, z = 3 } }
    D.setExecuting(false)
    env.FellTargets(targets)
    eq(calls, 0, "an aborted job fells nothing more")
    D.setExecuting(true)
    env.FellTargets(targets)
    eq(calls, 3, "a live job with fuel works the list")
    env.__world.turtle.fuel = 160                          -- floor 150 + 40 for the next approach: short
    env.FellTargets(targets)
    eq(calls, 3, "the trip-home tank is not spent on another target")
end)

test("DroneLogic.ApproachFromSide gives up after the fuel cap instead of trying every side", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 0, y = 64, z = 0 } })
    D.setExecuting(true)
    local movers = 0
    local burn = function() movers = movers + 1 env.__world.turtle.fuel = env.__world.turtle.fuel - 30 return false end
    env.pgps.moveTo, env.pgps.flyTo, env.pgps.digTo = burn, burn, burn
    local ok, why = env.ApproachFromSide({ x = 5, y = 70, z = 5 })
    eq(ok, false, "unreachable") eq(why, "too costly", "and it says why")
    truthy(movers <= 6, "one side's movers, not four sides' (" .. movers .. ")")
    truthy(500 - env.__world.turtle.fuel <= 200, "bounded burn")
    D.setExecuting(false)
    movers = 0
    local ok2, why2 = env.ApproachFromSide({ x = 5, y = 70, z = 5 })
    eq(ok2, false, "aborted") eq(why2, "aborted", "an abort ends it before the first mover") eq(movers, 0, "no movers")
end)

test("DroneLogic.ConfirmHeading does not step the turtle while another coroutine owns travel", function()
    local env = loadModule("DroneLogic.lua")
    local probes = 0
    env.pgps.ensureHeading = function() probes = probes + 1 return true end
    env.TravelOwner = coroutine.create(function() coroutine.yield() end)   -- alive, not us
    eq(env.ConfirmHeading(), false, "refused under a traveller")
    eq(probes, 0, "no probe step")
    env.TravelOwner = nil
    env.ConfirmHeading()
    eq(probes, 1, "probes once the drone is ours to move")
end)

-- ================================================================================================
local failed = 0
for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end

-- PowGPSServer: the planner's dig cost
test("PowGPSServer: with digging allowed the planner still walks around a wall it could cut through", function()
    local env = loadModule("PowGPSServer.lua")
    -- A wall on x=1, three tall and seven wide, between the start (0,64,0) and the goal (2,64,0).
    -- Cutting through is 3 steps; going over is about 8. It must go over.
    for z = -3, 3 do for y = 63, 65 do env.cachedWorld["1:" .. y .. ":" .. z] = 1 end end
    local s_Path = env.a_star(0, 64, 0, 2, 64, 0, 1, false, 99, true)
    truthy(type(s_Path) == "table", "a path came back: " .. tostring(s_Path))
    local x, y, z = 0, 64, 0
    local s_Deltas = { [0] = {0, 0, -1}, [1] = {-1, 0, 0}, [2] = {0, 0, 1}, [3] = {1, 0, 0}, [4] = {0, 1, 0}, [5] = {0, -1, 0} }
    local s_Cut = 0
    for _, dir in ipairs(s_Path) do
        local d = s_Deltas[dir]
        x, y, z = x + d[1], y + d[2], z + d[3]
        if env.cachedWorld[x .. ":" .. y .. ":" .. z] == 1 then s_Cut = s_Cut + 1 end
    end
    eq(s_Cut, 0, "no wall cell on the route")
    eq(x .. "," .. y .. "," .. z, "2,64,0", "and it arrives")
end)

test("PowGPSServer: when nothing but rock leads to the goal the planner does dig", function()
    local env = loadModule("PowGPSServer.lua")
    -- Encase the goal completely: the only way in is through a cell of rock.
    for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
        if not (dx == 0 and dy == 0 and dz == 0) then env.cachedWorld[(5 + dx) .. ":" .. (64 + dy) .. ":" .. dz] = 1 end
    end end end
    local s_Path = env.a_star(0, 64, 0, 5, 64, 0, 1, false, 99, true)
    truthy(type(s_Path) == "table", "a digging path came back: " .. tostring(s_Path))
    local s_Blocked = env.a_star(0, 64, 0, 5, 64, 0, 1, false, 99, false)
    truthy(s_Blocked == false or s_Blocked == nil, "without digging there is no route")
end)

-- DroneLogic: travel asks for an open route before a digging one
test("DroneLogic: TravelTo never asks for a digging plan when an open route exists", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Calls = {}
    env.pgps.moveTo = function() s_Calls[#s_Calls + 1] = "moveTo" return true end
    env.pgps.digTo = function() s_Calls[#s_Calls + 1] = "digTo" return true end
    local px, py, pz = env.pgps.getCachedPosition()
    truthy(env.TravelToBody(px + 12, py, pz + 5), "arrived")
    eq(table.concat(s_Calls, ","), "moveTo", "one open-route plan, no digging plan")
end)

test("DroneLogic: TravelTo digs only after the open-route plans have failed", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Calls = {}
    env.pgps.moveTo = function() s_Calls[#s_Calls + 1] = "moveTo" return false end
    env.pgps.digTo = function() s_Calls[#s_Calls + 1] = "digTo" return true end
    local px, py, pz = env.pgps.getCachedPosition()
    truthy(env.TravelToBody(px + 12, py, pz + 5), "arrived by digging in the end")
    truthy(s_Calls[1] == "moveTo", "the first ask was for an open route: " .. table.concat(s_Calls, ","))
    local s_FirstDig
    for i, c in ipairs(s_Calls) do if c == "digTo" and s_FirstDig == nil then s_FirstDig = i end end
    truthy(s_FirstDig ~= nil and s_FirstDig > 1, "digging came after the open-route attempts")
end)

-- DroneLogic: the jitter watch
test("DroneLogic: a drone that moves a lot over a few cells gets its trip broken after one window", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Broken = 0
    env.pgps.motionWindow = function() return 22, 4, 3 end
    env.pgps.BreakExec = function() s_Broken = s_Broken + 1 end
    env.executing = false
    -- the module's own start-up already ran one heartbeat, so the window closes within 8 calls
    local s_Fired = false
    for _ = 1, 8 do if env.JitterWatch() then s_Fired = true end end
    truthy(s_Fired, "the window closed on jitter")
    eq(s_Broken, 1, "the trip was broken once")
end)

test("DroneLogic: a drone covering ground is never called jittery", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.pgps.motionWindow = function() return 40, 12, 38 end
    local s_Fired = false
    for _ = 1, 16 do if env.JitterWatch() then s_Fired = true end end
    truthy(not s_Fired, "40 moves over 38 cells is travel")
end)


-- A dry drone does not try
test("pgps.moveTo at zero fuel refuses before turning or asking for a path", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.turtle.fuel = 0
    local s_Turns = 0
    env.turtle.turnLeft = function() s_Turns = s_Turns + 1 return true end
    env.turtle.turnRight = function() s_Turns = s_Turns + 1 return true end
    local ok, why = env.moveTo(5, 64, 5)
    eq(ok, false, "refused")
    eq(why, "out of fuel", "and said why")
    eq(s_Turns, 0, "without a single turn")
end)

test("DroneLogic: RefuelAtStorage at zero fuel raises a distress and makes no trip", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.fuel = 0
    local s_Asked = false
    env.__world.replies.StorageMan = { DepositPoint = function() s_Asked = true return { pos = { x = 0, y = 64, z = 0 } } end }
    local ok = env.RefuelAtStorage()
    eq(ok, false, "no refuel")
    truthy(not s_Asked, "StorageMan was not asked for a deposit point")
end)


test("DroneLogic: a crafter shuttling between the bay's chests is work, not jitter", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.pgps.motionWindow = function() return 255, 6, 6 end
    local s_Broken = 0
    env.pgps.BreakExec = function() s_Broken = s_Broken + 1 end
    env.executing = false
    for _ = 1, 16 do env.JitterWatch() end
    eq(s_Broken, 0, "six cells of chest-hopping is never a loop")
end)

io.stderr:write(("%d test(s), %d failed\n"):format(#results, failed))
os.exit(failed == 0 and 0 or 1)
